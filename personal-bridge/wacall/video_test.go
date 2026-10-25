package main

import (
	"bytes"
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/samplebuilder"
	"github.com/rs/zerolog"
)

var cH264 = webrtc.RTPCodecParameters{
	RTPCodecCapability: webrtc.RTPCodecCapability{
		MimeType: webrtc.MimeTypeH264, ClockRate: 90000,
		SDPFmtpLine:  "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
		RTCPFeedback: []webrtc.RTCPFeedback{{Type: "nack", Parameter: "pli"}},
	},
	PayloadType: 96,
}

// Fake H.264 access units (the payloader doesn't look inside NAL units).
func nal(typ byte, n int) []byte {
	b := append([]byte{0, 0, 0, 1, typ}, bytes.Repeat([]byte{0xab}, n)...)
	return b
}
func idrFrame() []byte { return append(append(nal(0x67, 10), nal(0x68, 4)...), nal(0x65, 3000)...) }
func pFrame() []byte   { return nal(0x41, 800) }

// fakeVideoApp offers G.722 audio and H.264 video, like tjena on Android.
func fakeVideoApp(t *testing.T) (*webrtc.PeerConnection, *webrtc.TrackLocalStaticSample, *webrtc.RTPSender, string) {
	t.Helper()
	me := &webrtc.MediaEngine{}
	if err := me.RegisterCodec(cG722, webrtc.RTPCodecTypeAudio); err != nil {
		t.Fatal(err)
	}
	if err := me.RegisterCodec(cH264, webrtc.RTPCodecTypeVideo); err != nil {
		t.Fatal(err)
	}
	pc, err := webrtc.NewAPI(webrtc.WithMediaEngine(me)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	mic, _ := webrtc.NewTrackLocalStaticSample(cG722.RTPCodecCapability, "mic", "app")
	cam, _ := webrtc.NewTrackLocalStaticSample(cH264.RTPCodecCapability, "cam", "app")
	if _, err = pc.AddTrack(mic); err != nil {
		t.Fatal(err)
	}
	camSender, err := pc.AddTrack(cam)
	if err != nil {
		t.Fatal(err)
	}
	offer, _ := pc.CreateOffer(nil)
	done := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	<-done
	return pc, cam, camSender, pc.LocalDescription().SDP
}

func TestHasIDR(t *testing.T) {
	if !hasIDR(idrFrame()) || hasIDR(pFrame()) || hasIDR(nil) {
		t.Fatal("hasIDR wrong")
	}
}

func TestVideoBothWays(t *testing.T) {
	app, cam, camSender, offer := fakeVideoApp(t)
	defer app.Close()

	var msgMu sync.Mutex
	var msgs []Msg
	m := newManager(zerolog.Nop())
	m.send = func(x Msg) { msgMu.Lock(); msgs = append(msgs, x); msgMu.Unlock() }
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	s, answer, err := m.answerOffer(ctx, "v1", "app1", offer, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.pc.Close()
	if s.vtrack == nil || !strings.Contains(answer, "H264/90000") {
		t.Fatal("no video negotiated")
	}

	// App → WhatsApp: what the phone would pass to meowcaller.
	var sentMu sync.Mutex
	var sent [][]byte
	s.sendVideo = func(au []byte, _ time.Duration) error {
		sentMu.Lock()
		sent = append(sent, append([]byte(nil), au...))
		sentMu.Unlock()
		return nil
	}

	// WhatsApp → app: what the app decodes.
	var gotMu sync.Mutex
	var got [][]byte
	app.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if tr.Kind() != webrtc.RTPCodecTypeVideo {
			return
		}
		sb := samplebuilder.New(512, &codecs.H264Packet{}, 90000)
		for {
			pkt, _, err := tr.ReadRTP()
			if err != nil {
				return
			}
			sb.Push(pkt)
			for smp := sb.Pop(); smp != nil; smp = sb.Pop() {
				gotMu.Lock()
				got = append(got, smp.Data)
				gotMu.Unlock()
			}
		}
	})

	// Frames from WhatsApp before the app is connected: a P frame (useless
	// without a keyframe, dropped), then a keyframe and a P frame (held).
	sink := videoToApp{m: m, s: s}
	_ = sink.WriteVideo(pFrame())
	_ = sink.WriteVideo(idrFrame())
	_ = sink.WriteVideo(pFrame())
	if len(s.v.held) != 2 {
		t.Fatalf("held %d frames, want 2", len(s.v.held))
	}

	if err = app.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
		t.Fatal(err)
	}

	pli := make(chan struct{}, 1)
	go func() {
		for {
			pkts, _, err := camSender.ReadRTCP()
			if err != nil {
				return
			}
			for _, p := range pkts {
				if _, ok := p.(*rtcp.PictureLossIndication); ok {
					select {
					case pli <- struct{}{}:
					default:
					}
				}
			}
		}
	}()

	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if s.pc.ConnectionState() == webrtc.PeerConnectionStateConnected {
			_ = sink.WriteVideo(pFrame())
			s.askAppKeyframe()
		}
		_ = cam.WriteSample(media.Sample{Data: idrFrame(), Duration: 33 * time.Millisecond})
		_ = cam.WriteSample(media.Sample{Data: pFrame(), Duration: 33 * time.Millisecond})
		time.Sleep(40 * time.Millisecond)
		gotMu.Lock()
		g := len(got)
		gotMu.Unlock()
		sentMu.Lock()
		n := len(sent)
		sentMu.Unlock()
		if g >= 4 && n >= 4 && len(pli) > 0 {
			break
		}
	}

	gotMu.Lock()
	if len(got) < 3 {
		t.Fatalf("app got %d video frames", len(got))
	}
	// The held keyframe comes first, so the app can decode from the start.
	if !hasIDR(got[0]) {
		t.Fatal("first frame at the app is not a keyframe")
	}
	gotMu.Unlock()

	sentMu.Lock()
	if len(sent) < 3 {
		t.Fatalf("only %d app frames reached WhatsApp", len(sent))
	}
	idr := 0
	for _, au := range sent {
		if hasIDR(au) {
			idr++
			if !bytes.Contains(au, []byte{0, 0, 0, 1, 0x67}) && !bytes.Contains(au, []byte{0, 0, 1, 0x67}) {
				t.Fatal("keyframe to WhatsApp lost its SPS")
			}
		}
	}
	if idr == 0 {
		t.Fatal("no keyframe reached WhatsApp")
	}
	sentMu.Unlock()

	select {
	case <-pli:
	default:
		t.Fatal("the app got no keyframe request")
	}

	msgMu.Lock()
	defer msgMu.Unlock()
	found := false
	for _, x := range msgs {
		if x.Type == "video_state" && x.PeerVideo != nil && *x.PeerVideo {
			found = true
		}
	}
	if !found {
		t.Fatal("app was not told the peer's video is on")
	}
}

func TestAudioOnlyOfferHasNoVideo(t *testing.T) {
	app, _, offer := fakeApp(t, []webrtc.RTPCodecParameters{cOpus, cG722})
	defer app.Close()
	m := newManager(zerolog.Nop())
	m.send = func(Msg) {}
	s, _, err := m.answerOffer(context.Background(), "a", "b", offer, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer s.pc.Close()
	if s.vtrack != nil {
		t.Fatal("video track without H.264 in the offer")
	}
}
