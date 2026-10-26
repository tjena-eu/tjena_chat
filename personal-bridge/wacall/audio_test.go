package main

import (
	"io"
	"math"
	"testing"
)

func sine(n int, freq, rate float64, amp float32, phase *float64) []float32 {
	out := make([]float32, n)
	for i := range out {
		out[i] = amp * float32(math.Sin(*phase))
		*phase += 2 * math.Pi * freq / rate
	}
	return out
}

// snr compares a decoded signal with the original, allowing a codec delay.
func snr(orig, got []float32) float64 {
	best := math.Inf(-1)
	for delay := 0; delay < 64; delay++ {
		var sig, noise float64
		for i := 200; i+delay < len(got) && i < len(orig); i++ {
			d := float64(got[i+delay] - orig[i])
			sig += float64(orig[i]) * float64(orig[i])
			noise += d * d
		}
		if v := 10 * math.Log10(sig/(noise+1e-12)); v > best {
			best = v
		}
	}
	return best
}

func roundTrip(t *testing.T, k codecKind, freq float64) float64 {
	enc := newRTPEncoder(k)
	dec := newRTPDecoder()
	var phase float64
	var orig, got []float32
	for range 20 { // 20 × 60 ms
		f := sine(waFrame, freq, waRate, 0.5, &phase)
		orig = append(orig, f...)
		for _, p := range enc.encode(f) {
			got = append(got, dec.decode(k, p)...)
		}
	}
	if len(got) != len(orig) {
		t.Fatalf("%v: got %d samples, want %d", k, len(got), len(orig))
	}
	return snr(orig, got)
}

func TestG722RoundTrip(t *testing.T) {
	for _, f := range []float64{300, 1000, 3000, 6000} {
		if s := roundTrip(t, codecG722, f); s < 15 {
			t.Errorf("G.722 %v Hz: SNR %.1f dB, want ≥ 15", f, s)
		}
	}
	// 20 ms of G.722 at 64 kbit/s is 160 bytes.
	if p := newRTPEncoder(codecG722).encode(make([]float32, waFrame)); len(p) != 3 || len(p[0]) != 160 {
		t.Fatalf("G.722 packets: %d of %d bytes", len(p), len(p[0]))
	}
}

func TestPCMURoundTrip(t *testing.T) {
	for _, f := range []float64{300, 1000, 3000} {
		if s := roundTrip(t, codecPCMU, f); s < 15 {
			t.Errorf("PCMU %v Hz: SNR %.1f dB, want ≥ 15", f, s)
		}
	}
	if p := newRTPEncoder(codecPCMU).encode(make([]float32, waFrame)); len(p) != 3 || len(p[0]) != 160 {
		t.Fatalf("PCMU packets: %d of %d bytes", len(p), len(p[0]))
	}
}

func TestULawKnownValues(t *testing.T) {
	// G.711 reference points: silence is 0xFF, full scale is 0x80/0x00.
	cases := map[int16]byte{0: 0xFF, 32767: 0x80, -32768: 0x00, 100: 0xF2, -100: 0x72}
	for in, want := range cases {
		if got := ulawEncode(in); got != want {
			t.Errorf("ulawEncode(%d) = %#x, want %#x", in, got, want)
		}
	}
	for v := -32768; v <= 32767; v += 97 {
		d := ulawDecode(ulawEncode(int16(v)))
		if diff := math.Abs(float64(int(d) - v)); diff > math.Max(32, math.Abs(float64(v))/14) {
			t.Fatalf("µ-law %d → %d", v, d)
		}
	}
}

func TestLiveSource(t *testing.T) {
	s := newLiveSource()
	// Nothing yet: silence, not EOF.
	f, err := s.ReadFrame()
	if err != nil || len(f) != waFrame || level(f) > -100 {
		t.Fatalf("empty source: %v %d %.1f", err, len(f), level(f))
	}
	var phase float64
	s.push(sine(prebufferSamp, 440, waRate, 0.5, &phase))
	if f, _ = s.ReadFrame(); level(f) > -100 {
		t.Fatal("played before the prebuffer was full")
	}
	s.push(sine(waFrame, 440, waRate, 0.5, &phase))
	if f, _ = s.ReadFrame(); level(f) < -20 {
		t.Fatal("no audio after prebuffer")
	}
	// Too much buffered: old audio is dropped.
	s.push(make([]float32, 3*maxBufferSamp))
	s.mu.Lock()
	n := len(s.buf)
	s.mu.Unlock()
	if n > maxBufferSamp {
		t.Fatalf("buffer holds %d samples, max %d", n, maxBufferSamp)
	}
	s.Close()
	if _, err = s.ReadFrame(); err != io.EOF {
		t.Fatal("closed source should return EOF")
	}
}
