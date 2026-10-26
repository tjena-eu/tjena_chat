package main

// Audio between WebRTC (the tjena app) and meowcaller (WhatsApp).
//
// meowcaller works with 16 kHz mono float32 frames of 60 ms. On the WebRTC
// side we use G.722 (16 kHz wideband, same rate, no resampling) and fall back
// to G.711 µ-law (8 kHz) if the other side does not offer G.722. Both codecs
// are simple, royalty-free and pure Go, so the daemon needs no C libraries.

import (
	"io"
	"math"
	"sync"

	"github.com/gotranspile/g722"
)

const (
	waRate        = 16000
	waFrame       = 960 // 60 ms at 16 kHz (meowcaller.FrameSamples)
	rtpPacketMS   = 20
	samples16k20  = waRate * rtpPacketMS / 1000 // 320
	maxBufferMS   = 400                         // drop older audio beyond this
	prebufferMS   = 80                          // wait for this much before playing
	maxBufferSamp = waRate * maxBufferMS / 1000
	prebufferSamp = waRate * prebufferMS / 1000
)

type codecKind int

const (
	codecNone codecKind = iota
	codecG722
	codecPCMU
)

func (c codecKind) String() string {
	switch c {
	case codecG722:
		return "G722"
	case codecPCMU:
		return "PCMU"
	}
	return "none"
}

// ---------------------------------------------------------------- conversion

func f32ToS16(in []float32) []int16 {
	out := make([]int16, len(in))
	for i, v := range in {
		v *= 32767
		if v > 32767 {
			v = 32767
		} else if v < -32768 {
			v = -32768
		}
		out[i] = int16(v)
	}
	return out
}

func s16ToF32(in []int16) []float32 {
	out := make([]float32, len(in))
	for i, v := range in {
		out[i] = float32(v) / 32768
	}
	return out
}

// Resampling between 16 and 8 kHz (only for the PCMU fallback) uses a
// windowed-sinc half-band low-pass filter.
const hbTaps = 31

var halfband = func() [hbTaps]float64 {
	var h [hbTaps]float64
	mid := hbTaps / 2
	for i := range h {
		n := float64(i - mid)
		sinc := 0.5
		if n != 0 {
			sinc = math.Sin(math.Pi*n/2) / (math.Pi * n)
		}
		w := 0.54 - 0.46*math.Cos(2*math.Pi*float64(i)/float64(hbTaps-1)) // Hamming
		h[i] = sinc * w
	}
	var sum float64
	for _, v := range h {
		sum += v
	}
	for i := range h {
		h[i] /= sum
	}
	return h
}()

// resampler keeps filter history across calls.
type resampler struct{ hist []float64 }

func (r *resampler) filter(in []float64, step int, gain float64) []float64 {
	if r.hist == nil {
		r.hist = make([]float64, hbTaps-1)
	}
	x := append(r.hist, in...)
	out := make([]float64, 0, len(in)/step+1)
	for i := 0; i+hbTaps <= len(x); i += step {
		var acc float64
		for k, c := range halfband {
			acc += c * x[i+k]
		}
		out = append(out, acc*gain)
	}
	r.hist = append([]float64(nil), x[len(x)-(hbTaps-1):]...)
	return out
}

func clamp16(v float64) int16 {
	if v > 32767 {
		return 32767
	} else if v < -32768 {
		return -32768
	}
	return int16(math.Round(v))
}

// down2 halves the sample rate (16 → 8 kHz). len(in) must be even.
func down2(in []int16, r *resampler) []int16 {
	f := make([]float64, len(in))
	for i, v := range in {
		f[i] = float64(v)
	}
	y := r.filter(f, 2, 1)
	out := make([]int16, len(y))
	for i, v := range y {
		out[i] = clamp16(v)
	}
	return out
}

// up2 doubles the sample rate (8 → 16 kHz): zero-stuff, then low-pass.
func up2(in []int16, r *resampler) []int16 {
	f := make([]float64, 2*len(in))
	for i, v := range in {
		f[2*i] = float64(v)
	}
	y := r.filter(f, 1, 2)
	out := make([]int16, len(y))
	for i, v := range y {
		out[i] = clamp16(v)
	}
	return out
}

// ---------------------------------------------------------------- G.711 µ-law

func ulawEncode(s int16) byte {
	const bias, clip = 0x84, 32635
	v := int32(s)
	sign := byte(0)
	if v < 0 {
		v = -v
		sign = 0x80
	}
	if v > clip {
		v = clip
	}
	v += bias
	exp := byte(7)
	for mask := int32(0x4000); v&mask == 0 && exp > 0; mask >>= 1 {
		exp--
	}
	mant := byte(v>>(uint(exp)+3)) & 0x0F
	return ^(sign | exp<<4 | mant)
}

func ulawDecode(b byte) int16 {
	b = ^b
	sign := b & 0x80
	exp := (b >> 4) & 0x07
	mant := b & 0x0F
	v := (int32(mant)<<3 + 0x84) << exp
	v -= 0x84
	if sign != 0 {
		return int16(-v)
	}
	return int16(v)
}

// ---------------------------------------------------------------- encoder

// rtpEncoder turns 16 kHz frames into 20 ms RTP payloads.
type rtpEncoder struct {
	kind codecKind
	g722 *g722.Encoder
	rs   resampler
	buf  []int16
}

func newRTPEncoder(k codecKind) *rtpEncoder {
	e := &rtpEncoder{kind: k}
	if k == codecG722 {
		e.g722 = g722.NewEncoder(g722.Rate64000, 0)
	}
	return e
}

// encode returns zero or more 20 ms payloads for the given 16 kHz samples.
func (e *rtpEncoder) encode(frame []float32) [][]byte {
	e.buf = append(e.buf, f32ToS16(frame)...)
	var out [][]byte
	for len(e.buf) >= samples16k20 {
		chunk := e.buf[:samples16k20]
		switch e.kind {
		case codecG722:
			p := make([]byte, samples16k20/2)
			n := e.g722.Encode(p, chunk)
			out = append(out, p[:n])
		case codecPCMU:
			low := down2(chunk, &e.rs)
			p := make([]byte, len(low))
			for i, s := range low {
				p[i] = ulawEncode(s)
			}
			out = append(out, p)
		}
		e.buf = e.buf[samples16k20:]
	}
	return out
}

// ---------------------------------------------------------------- decoder

type rtpDecoder struct {
	g722 *g722.Decoder
	rs   resampler
}

func newRTPDecoder() *rtpDecoder {
	return &rtpDecoder{g722: g722.NewDecoder(g722.Rate64000, 0)}
}

// decode turns one RTP payload (by payload type) into 16 kHz samples.
func (d *rtpDecoder) decode(k codecKind, payload []byte) []float32 {
	switch k {
	case codecG722:
		pcm := make([]int16, 2*len(payload))
		n := d.g722.Decode(pcm, payload)
		return s16ToF32(pcm[:n])
	case codecPCMU:
		low := make([]int16, len(payload))
		for i, b := range payload {
			low[i] = ulawDecode(b)
		}
		return s16ToF32(up2(low, &d.rs))
	}
	return nil
}

// ---------------------------------------------------------------- live source

// liveSource is a meowcaller.AudioSource fed from the network. meowcaller
// pulls one frame every 60 ms; when nothing has arrived yet it gets silence,
// never EOF, so the call keeps going. A short prebuffer smooths out network
// jitter, and audio older than maxBufferMS is dropped to keep latency low.
type liveSource struct {
	mu        sync.Mutex
	buf       []float32
	buffering bool
	closed    bool
}

func newLiveSource() *liveSource { return &liveSource{buffering: true} }

func (s *liveSource) push(samples []float32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.buf = append(s.buf, samples...)
	if over := len(s.buf) - maxBufferSamp; over > 0 {
		s.buf = append(s.buf[:0], s.buf[over:]...)
	}
}

func (s *liveSource) ReadFrame() ([]float32, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, io.EOF
	}
	frame := make([]float32, waFrame)
	if s.buffering {
		if len(s.buf) < prebufferSamp+waFrame {
			return frame, nil
		}
		s.buffering = false
	}
	if len(s.buf) < waFrame {
		// Underrun: play what we have, then build up the buffer again.
		copy(frame, s.buf)
		s.buf = s.buf[:0]
		s.buffering = true
		return frame, nil
	}
	copy(frame, s.buf[:waFrame])
	s.buf = append(s.buf[:0], s.buf[waFrame:]...)
	return frame, nil
}

func (s *liveSource) Close() error {
	s.mu.Lock()
	s.closed = true
	s.buf = nil
	s.mu.Unlock()
	return nil
}

// level returns the RMS of samples in dBFS (for tests and diagnostics).
func level(samples []float32) float64 {
	if len(samples) == 0 {
		return math.Inf(-1)
	}
	var sum float64
	for _, v := range samples {
		sum += float64(v) * float64(v)
	}
	return 10 * math.Log10(sum/float64(len(samples))+1e-20)
}
