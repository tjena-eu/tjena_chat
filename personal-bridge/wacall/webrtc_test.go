package main

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/rs/zerolog"
)

// fakeApp is a WebRTC peer like the tjena app: it offers audio with the
// codecs libwebrtc offers (Opus first, then G.722, PCMU), no trickle.
func fakeApp(t *testing.T, codecs []webrtc.RTPCodecParameters) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticSample, string) {
	t.Helper()
	me := &webrtc.MediaEngine{}
	for _, c := range codecs {
		if err := me.RegisterCodec(c, webrtc.RTPCodecTypeAudio); err != nil {
			t.Fatal(err)
		}
	}
	pc, err := webrtc.NewAPI(webrtc.WithMediaEngine(me)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	track, err := webrtc.NewTrackLocalStaticSample(codecs[min(1, len(codecs)-1)].RTPCodecCapability, "mic", "app")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = pc.AddTrack(track); err != nil {
		t.Fatal(err)
	}
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	done := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-done
	return pc, track, pc.LocalDescription().SDP
}

var (
	cOpus = webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeOpus, ClockRate: 48000, Channels: 2}, PayloadType: 111}
	cG722 = webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeG722, ClockRate: 8000}, PayloadType: 9}
	cPCMU = webrtc.RTPCodecParameters{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}, PayloadType: 0}
)

func TestWebRTCBothWays(t *testing.T) {
	for name, codecs := range map[string][]webrtc.RTPCodecParameters{
		"g722": {cOpus, cG722, cPCMU},
		"pcmu": {cOpus, cPCMU},
	} {
		t.Run(name, func(t *testing.T) { testBothWays(t, codecs) })
	}
}

func testBothWays(t *testing.T, codecs []webrtc.RTPCodecParameters) {
	app, appTrack, offer := fakeApp(t, codecs)
	defer app.Close()

	m := newManager(zerolog.Nop())
	m.send = func(Msg) {}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	s, answer, err := m.answerOffer(ctx, "c1", "app1", offer, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.pc.Close()
	want := codecPCMU
	if len(codecs) == 3 {
		want = codecG722
	}
	if s.codec != want {
		t.Fatalf("codec %v, want %v", s.codec, want)
	}

	// What the app hears (from WhatsApp).
	var mu sync.Mutex
	var heard []float32
	app.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		dec := newRTPDecoder()
		for {
			pkt, _, err := tr.ReadRTP()
			if err != nil {
				return
			}
			k := codecG722
			if pkt.PayloadType == ptPCMU {
				k = codecPCMU
			}
			mu.Lock()
			heard = append(heard, dec.decode(k, pkt.Payload)...)
			mu.Unlock()
		}
	})
	if err = app.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
		t.Fatal(err)
	}

	toApp := s.toApp()
	appEnc := newRTPEncoder(want)
	var phase, phase2 float64
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		// WhatsApp → app: one 60 ms frame
		toApp(sine(waFrame, 440, waRate, 0.5, &phase))
		// app → WhatsApp (microphone)
		for _, p := range appEnc.encode(sine(waFrame, 880, waRate, 0.5, &phase2)) {
			_ = appTrack.WriteSample(media.Sample{Data: p, Duration: 20 * time.Millisecond})
		}
		time.Sleep(60 * time.Millisecond)
		mu.Lock()
		got := len(heard)
		mu.Unlock()
		s.src.mu.Lock()
		buffered := len(s.src.buf)
		s.src.mu.Unlock()
		if got > waRate/2 && buffered > prebufferSamp {
			break
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(heard) < waRate/2 {
		t.Fatalf("app heard only %d samples", len(heard))
	}
	if l := level(heard[len(heard)/2:]); l < -15 {
		t.Fatalf("app audio too quiet: %.1f dB", l)
	}
	var f []float32
	for range 3 {
		f, _ = s.src.ReadFrame()
	}
	if l := level(f); l < -15 {
		t.Fatalf("WhatsApp side got no microphone audio: %.1f dB", l)
	}
}

func TestOfferWithoutUsableCodec(t *testing.T) {
	app, _, offer := fakeApp(t, []webrtc.RTPCodecParameters{cOpus})
	defer app.Close()
	m := newManager(zerolog.Nop())
	if _, _, err := m.answerOffer(context.Background(), "c", "a", offer, nil); err == nil {
		t.Fatal("expected an error for an Opus-only offer")
	}
}
