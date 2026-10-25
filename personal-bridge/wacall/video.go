package main

// Video: H.264 passes through unchanged in both directions. tjena's WebRTC
// encodes and decodes it (hardware on Android); meowcaller carries the frames
// to WhatsApp. This phone never decodes a picture.
//
//	tjena ──RTP H.264──► samplebuilder ──access unit──► call.SendVideo ──► WhatsApp
//	tjena ◄──RTP H.264── track.WriteSample ◄──access unit── ReceiveVideo ◄── WhatsApp
//
// Every call negotiates a video channel (also audio calls), so the camera can
// be switched on mid-call without a new offer through the gateway.

import (
	"sync"
	"time"

	"github.com/pion/rtcp"
	"github.com/pion/rtp/codecs"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/pion/webrtc/v4/pkg/media/samplebuilder"
	meowcaller "github.com/purpshell/meowcaller"
	"github.com/purpshell/meowcaller/signaling"
)

const (
	ptH264First = 102
	// Frames from WhatsApp kept while the app is not connected yet, so the
	// app starts on a keyframe instead of a grey picture.
	maxHeldFrames = 90
	// Keyframe requests to the app are at most this often.
	pliInterval = 400 * time.Millisecond
)

// H.264 profiles we accept from the app (packetization-mode 1 only).
var h264Profiles = []string{"42e01f", "42001f", "4d001f", "640c1f", "64001f"}

func registerVideo(me *webrtc.MediaEngine) error {
	fb := []webrtc.RTCPFeedback{
		{Type: "goog-remb"}, {Type: "ccm", Parameter: "fir"},
		{Type: "nack"}, {Type: "nack", Parameter: "pli"},
	}
	for i, p := range h264Profiles {
		err := me.RegisterCodec(webrtc.RTPCodecParameters{
			RTPCodecCapability: webrtc.RTPCodecCapability{
				MimeType:     webrtc.MimeTypeH264,
				ClockRate:    90000,
				SDPFmtpLine:  "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=" + p,
				RTCPFeedback: fb,
			},
			PayloadType: webrtc.PayloadType(ptH264First + i),
		}, webrtc.RTPCodecTypeVideo)
		if err != nil {
			return err
		}
	}
	return nil
}

func offersH264(sdp string) bool {
	return containsFold(sdp, "H264/90000") && containsFold(sdp, "packetization-mode=1")
}

// videoState is the per-call video bookkeeping.
type videoState struct {
	mu          sync.Mutex
	appSSRC     uint32
	lastPLI     time.Time
	peerVideo   bool
	orientation int
	held        [][]byte
	lastFrame   time.Time
}

// askAppKeyframe asks tjena's encoder for a keyframe (WhatsApp drops video
// until one arrives).
func (s *session) askAppKeyframe() {
	s.v.mu.Lock()
	ssrc := s.v.appSSRC
	if ssrc == 0 || time.Since(s.v.lastPLI) < pliInterval {
		s.v.mu.Unlock()
		return
	}
	s.v.lastPLI = time.Now()
	s.v.mu.Unlock()
	_ = s.pc.WriteRTCP([]rtcp.Packet{&rtcp.PictureLossIndication{MediaSSRC: ssrc}})
}

// askAppKeyframeSoon asks now and again shortly after: the first request can
// arrive before the encoder runs.
func (s *session) askAppKeyframeSoon() {
	s.askAppKeyframe()
	go func() {
		for _, d := range []time.Duration{600 * time.Millisecond, 1500 * time.Millisecond, 3 * time.Second} {
			time.Sleep(d)
			s.askAppKeyframe()
		}
	}()
}

// readAppVideo forwards the app's camera to WhatsApp.
func (m *Manager) readAppVideo(s *session, tr *webrtc.TrackRemote) {
	s.v.mu.Lock()
	s.v.appSSRC = uint32(tr.SSRC())
	s.v.mu.Unlock()
	m.log.Info().Str("call", s.id).Str("codec", tr.Codec().SDPFmtpLine).Msg("app video track")
	sb := samplebuilder.New(512, &codecs.H264Packet{}, 90000, samplebuilder.WithMaxTimeDelay(time.Second))
	var sent, failed int
	for {
		pkt, _, err := tr.ReadRTP()
		if err != nil {
			m.log.Debug().Str("call", s.id).Int("sent", sent).Int("not_sent", failed).Msg("app video ended")
			return
		}
		sb.Push(pkt)
		for smp := sb.Pop(); smp != nil; smp = sb.Pop() {
			s.mu.Lock()
			send := s.sendVideo
			s.mu.Unlock()
			if send == nil || len(smp.Data) == 0 {
				continue
			}
			if err := send(smp.Data, smp.Duration); err != nil {
				failed++ // no video flow on the WhatsApp side (camera off there)
				continue
			}
			sent++
		}
	}
}

// drainVideoRTCP reads the app's feedback for the video we send it, which the
// interceptors need. A keyframe request can't be passed on to WhatsApp
// (meowcaller asks for one by itself on loss).
func drainVideoRTCP(sender *webrtc.RTPSender) {
	for {
		if _, _, err := sender.ReadRTCP(); err != nil {
			return
		}
	}
}

// videoToApp is the meowcaller sink for the WhatsApp peer's video.
type videoToApp struct {
	m *Manager
	s *session
}

func (v videoToApp) WriteVideo(au []byte) error {
	s := v.s
	if s.vtrack == nil || len(au) == 0 {
		return nil
	}
	now := time.Now()
	s.v.mu.Lock()
	d := 33 * time.Millisecond
	if !s.v.lastFrame.IsZero() {
		d = min(max(now.Sub(s.v.lastFrame), 5*time.Millisecond), 200*time.Millisecond)
	}
	s.v.lastFrame = now
	// Not connected to the app yet: keep the frames since the last keyframe.
	if s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
		if hasIDR(au) {
			s.v.held = s.v.held[:0]
		}
		if len(s.v.held) < maxHeldFrames && (len(s.v.held) > 0 || hasIDR(au)) {
			s.v.held = append(s.v.held, append([]byte(nil), au...))
		}
		s.v.mu.Unlock()
		return nil
	}
	held := s.v.held
	s.v.held = nil
	s.v.mu.Unlock()
	for _, f := range held {
		_ = s.vtrack.WriteSample(media.Sample{Data: f, Duration: 33 * time.Millisecond})
	}
	err := s.vtrack.WriteSample(media.Sample{Data: au, Duration: d})
	v.m.setPeerVideo(s, true, -1)
	return err
}

func (v videoToApp) Close() error { return nil }

// SetOrientation: rotation from the frame metadata (quarter turns clockwise).
func (v videoToApp) SetOrientation(o int) { v.m.setPeerVideo(v.s, true, o) }

var _ meowcaller.VideoOrientationSink = videoToApp{}

// hasIDR reports whether an Annex-B access unit contains an IDR slice.
func hasIDR(au []byte) bool {
	for i := 0; i+3 < len(au); i++ {
		if au[i] == 0 && au[i+1] == 0 && au[i+2] == 1 {
			if au[i+3]&0x1f == 5 {
				return true
			}
			i += 2
		}
	}
	return false
}

// setPeerVideo tells the app when the peer's camera goes on/off or turns
// (orientation < 0 keeps the current one).
func (m *Manager) setPeerVideo(s *session, on bool, orientation int) {
	s.v.mu.Lock()
	changed := s.v.peerVideo != on
	s.v.peerVideo = on
	if orientation >= 0 && orientation != s.v.orientation {
		s.v.orientation = orientation & 3
		changed = true
	}
	o := s.v.orientation
	s.v.mu.Unlock()
	if changed {
		m.send(Msg{Type: "video_state", To: s.app, ID: s.id, PeerVideo: &on, Orientation: &o})
	}
}

// watchVideo hooks the WhatsApp call's video events to the session.
func (m *Manager) watchVideo(s *session, c *meowcaller.Call) {
	if s.vtrack != nil {
		c.ReceiveVideo(videoToApp{m: m, s: s})
	}
	c.OnVideoKeyframeRequest(s.askAppKeyframe)
	c.OnVideoState(func(v meowcaller.VideoState) {
		m.log.Info().Str("call", s.id).Int("state", v.Raw).Int("orientation", v.Orientation).Msg("peer video state")
		switch v.Raw {
		case signaling.VideoStateUpgradeRequest, signaling.VideoStateUpgradeRequestV2:
			m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Upgrade: "request"})
		case signaling.VideoStateUpgradeReject:
			m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Upgrade: "rejected"})
		case signaling.VideoStateUpgradeCancel:
			m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Upgrade: "cancelled"})
		case signaling.VideoStateUpgradeAccept:
			m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Upgrade: "accepted"})
			s.askAppKeyframeSoon()
		case signaling.VideoStateEnabled:
			m.setPeerVideo(s, true, v.Orientation)
			s.askAppKeyframe()
		case signaling.VideoStateDisabled, signaling.VideoStateStopped:
			m.setPeerVideo(s, false, -1)
		}
	})
}

// Video: the app turned its camera on or off.
func (m *Manager) Video(req Msg) {
	s := m.session(req.ID, req.From)
	if s == nil || s.call == nil || req.On == nil {
		return
	}
	c := s.call
	var err error
	switch {
	case !*req.On:
		err = c.SetVideoEnabled(false)
	case c.IsVideo():
		err = c.SetVideoEnabled(true)
		s.askAppKeyframeSoon()
	default: // audio call: ask the peer to switch to video
		err = c.StartVideo()
		s.askAppKeyframeSoon()
	}
	if err != nil {
		m.log.Warn().Err(err).Str("call", s.id).Bool("on", *req.On).Msg("video change")
		m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Error: err.Error()})
	}
}

// VideoAccept: the app accepts the peer's request to switch to video.
func (m *Manager) VideoAccept(req Msg) {
	s := m.session(req.ID, req.From)
	if s == nil || s.call == nil {
		return
	}
	if err := s.call.AcceptVideo(); err != nil {
		m.log.Warn().Err(err).Str("call", s.id).Msg("accept video")
		m.send(Msg{Type: "video_state", To: s.app, ID: s.id, Error: err.Error()})
	}
}
