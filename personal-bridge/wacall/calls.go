package main

// One bridged call = a WebRTC peer connection to the tjena app plus a
// meowcaller call to WhatsApp, with audio copied between them:
//
//	tjena app ──WebRTC (G.722, DTLS-SRTP)──► this phone ──meowcaller──► WhatsApp
//
// Signalling (offer/answer, call state) goes through the gateway; see
// signal.go. The app always sends the WebRTC offer, with all ICE candidates
// already in it (no trickle), so one message each way sets up the media.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"github.com/polymorfa/hypermeow/types"
	meowcaller "github.com/purpshell/meowcaller"
	"github.com/rs/zerolog"
)

const (
	ptG722 = 9
	ptPCMU = 0
	// Give up on a call that never got media to the app.
	mediaSetupTimeout = 45 * time.Second
	// An unanswered incoming call is forgotten after this.
	ringTimeout = 90 * time.Second
	maxCalls    = 2
)

type ICEServer struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username,omitempty"`
	Credential string   `json:"credential,omitempty"`
}

type session struct {
	id    string // chosen by the app
	app   string // gateway connection of the app that owns it
	peer  string
	pc    *webrtc.PeerConnection
	track *webrtc.TrackLocalStaticSample
	codec codecKind
	src   *liveSource
	call  *meowcaller.Call

	mu      sync.Mutex
	ended   bool
	state   string
	started time.Time
}

type ringing struct {
	call  *meowcaller.Call
	since time.Time
	info  RingInfo
}

type RingInfo struct {
	WACallID string `json:"wa_call_id"`
	Account  string `json:"account"`            // own WhatsApp number (digits) that is called
	Peer     string `json:"peer"`               // WhatsApp JID of the caller
	PeerPN   string `json:"peer_pn,omitempty"`  // phone-number JID, if known
	PeerLID  string `json:"peer_lid,omitempty"` // LID JID, if known
	Video    bool   `json:"video,omitempty"`
}

type Manager struct {
	log  zerolog.Logger
	wa   *WA
	send func(m Msg) // to the apps, through the gateway

	mu       sync.Mutex
	sessions map[string]*session
	ringing  map[string]*ringing
}

func newManager(log zerolog.Logger) *Manager {
	return &Manager{log: log, sessions: map[string]*session{}, ringing: map[string]*ringing{}}
}

func (m *Manager) counts() (active, ring int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sessions), len(m.ringing)
}

// ---------------------------------------------------------------- WebRTC

func offeredCodec(sdp string) codecKind {
	s := strings.ToUpper(sdp)
	switch {
	case strings.Contains(s, "G722/8000"):
		return codecG722
	case strings.Contains(s, "PCMU/8000"):
		return codecPCMU
	}
	return codecNone
}

func newAPI() (*webrtc.API, error) {
	me := &webrtc.MediaEngine{}
	for _, c := range []webrtc.RTPCodecParameters{
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeG722, ClockRate: 8000}, PayloadType: ptG722},
		{RTPCodecCapability: webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypePCMU, ClockRate: 8000}, PayloadType: ptPCMU},
	} {
		if err := me.RegisterCodec(c, webrtc.RTPCodecTypeAudio); err != nil {
			return nil, err
		}
	}
	se := webrtc.SettingEngine{}
	se.SetICEMulticastDNSMode(ice.MulticastDNSModeDisabled)
	se.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6, webrtc.NetworkTypeTCP4})
	return webrtc.NewAPI(webrtc.WithMediaEngine(me), webrtc.WithSettingEngine(se)), nil
}

// answerOffer sets up the peer connection for the app's offer and returns
// the session plus our SDP answer (with all candidates gathered).
func (m *Manager) answerOffer(ctx context.Context, id, app, offer string, servers []ICEServer) (*session, string, error) {
	codec := offeredCodec(offer)
	if codec == codecNone {
		return nil, "", errors.New("the app offered no supported audio codec (G.722 or PCMU)")
	}
	api, err := newAPI()
	if err != nil {
		return nil, "", err
	}
	cfg := webrtc.Configuration{}
	for _, s := range servers {
		cfg.ICEServers = append(cfg.ICEServers, webrtc.ICEServer{URLs: s.URLs, Username: s.Username, Credential: s.Credential})
	}
	pc, err := api.NewPeerConnection(cfg)
	if err != nil {
		return nil, "", err
	}
	fail := func(err error) (*session, string, error) {
		_ = pc.Close()
		return nil, "", err
	}
	mime := webrtc.MimeTypeG722
	if codec == codecPCMU {
		mime = webrtc.MimeTypePCMU
	}
	track, err := webrtc.NewTrackLocalStaticSample(webrtc.RTPCodecCapability{MimeType: mime, ClockRate: 8000}, "audio", "whatsapp")
	if err != nil {
		return fail(err)
	}
	s := &session{id: id, app: app, pc: pc, track: track, codec: codec, src: newLiveSource(), state: "connecting", started: time.Now()}

	if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: offer}); err != nil {
		return fail(fmt.Errorf("offer: %w", err))
	}
	sender, err := pc.AddTrack(track)
	if err != nil {
		return fail(err)
	}
	go func() { // drain RTCP so the sender keeps working
		buf := make([]byte, 1500)
		for {
			if _, _, err := sender.Read(buf); err != nil {
				return
			}
		}
	}()
	pc.OnTrack(func(tr *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if tr.Kind() != webrtc.RTPCodecTypeAudio {
			return
		}
		dec := newRTPDecoder()
		for {
			pkt, _, err := tr.ReadRTP()
			if err != nil {
				return
			}
			var k codecKind
			switch pkt.PayloadType {
			case ptG722:
				k = codecG722
			case ptPCMU:
				k = codecPCMU
			default:
				continue
			}
			if pcm := dec.decode(k, pkt.Payload); len(pcm) > 0 {
				s.src.push(pcm)
			}
		}
	})
	pc.OnConnectionStateChange(func(st webrtc.PeerConnectionState) {
		m.log.Info().Str("call", id).Str("webrtc", st.String()).Msg("app connection")
		switch st {
		case webrtc.PeerConnectionStateFailed, webrtc.PeerConnectionStateClosed:
			m.end(s, "app_disconnected")
		}
	})

	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return fail(err)
	}
	gathered := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(answer); err != nil {
		return fail(err)
	}
	select {
	case <-gathered:
	case <-time.After(8 * time.Second): // send what we have
	case <-ctx.Done():
		return fail(ctx.Err())
	}
	return s, pc.LocalDescription().SDP, nil
}

// toApp returns a sink that sends WhatsApp audio frames to the app.
func (s *session) toApp() func([]float32) {
	enc := newRTPEncoder(s.codec)
	return func(frame []float32) {
		for _, p := range enc.encode(frame) {
			_ = s.track.WriteSample(media.Sample{Data: p, Duration: rtpPacketMS * time.Millisecond})
		}
	}
}

// attach connects the WhatsApp call to the session's audio.
func (m *Manager) attach(s *session, c *meowcaller.Call) {
	s.call = c
	c.Receive(meowcaller.SinkFunc(s.toApp()))
	c.Play(s.src)
	c.OnStateChange(func(p meowcaller.CallPhase) {
		var st string
		switch p {
		case meowcaller.CallPhaseCalling:
			st = "calling"
		case meowcaller.CallPhaseRinging:
			st = "ringing"
		case meowcaller.CallPhaseConnecting:
			st = "connecting"
		case meowcaller.CallPhaseActive:
			st = "active"
		default:
			return
		}
		m.setState(s, st, "")
	})
	c.OnPeerAccept(func() { m.setState(s, "accepted", "") })
	c.OnEnd(func(reason string) { m.end(s, reasonOr(reason, "ended")) })
	// No media within the setup time: the app never connected.
	go func() {
		time.Sleep(mediaSetupTimeout)
		if s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
			m.end(s, "app_unreachable")
		}
	}()
}

func reasonOr(r, d string) string {
	if r == "" {
		return d
	}
	return r
}

func (m *Manager) setState(s *session, st, reason string) {
	s.mu.Lock()
	if s.ended || s.state == st {
		s.mu.Unlock()
		return
	}
	s.state = st
	s.mu.Unlock()
	m.log.Info().Str("call", s.id).Str("state", st).Msg("call state")
	m.send(Msg{Type: "state", To: s.app, ID: s.id, State: st, Reason: reason})
}

// end tears down both sides once.
func (m *Manager) end(s *session, reason string) {
	s.mu.Lock()
	if s.ended {
		s.mu.Unlock()
		return
	}
	s.ended = true
	s.state = "ended"
	s.mu.Unlock()
	m.mu.Lock()
	if m.sessions[s.id] == s {
		delete(m.sessions, s.id)
	}
	m.mu.Unlock()
	if s.call != nil {
		if ph := s.call.State(); ph != meowcaller.CallPhaseEnded && ph != meowcaller.CallPhaseIdle {
			if err := s.call.Hangup(); err != nil {
				m.log.Debug().Err(err).Msg("hangup")
			}
		}
	}
	s.src.Close()
	go s.pc.Close()
	m.log.Info().Str("call", s.id).Str("reason", reason).Dur("after", time.Since(s.started)).Msg("call ended")
	m.send(Msg{Type: "state", To: s.app, ID: s.id, State: "ended", Reason: reason})
}

// ---------------------------------------------------------------- requests

func (m *Manager) reserve(id string) error {
	if id == "" || len(id) > 64 {
		return errors.New("missing call id")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.sessions[id]; ok {
		return errors.New("call id already in use")
	}
	if len(m.sessions) >= maxCalls {
		return errors.New("too many calls at once")
	}
	m.sessions[id] = nil // placeholder until set up
	return nil
}

func (m *Manager) release(id string) {
	m.mu.Lock()
	if s, ok := m.sessions[id]; ok && s == nil {
		delete(m.sessions, id)
	}
	m.mu.Unlock()
}

func (m *Manager) store(s *session) {
	m.mu.Lock()
	m.sessions[s.id] = s
	m.mu.Unlock()
}

func (m *Manager) fail(app, id, msg string) {
	m.log.Warn().Str("call", id).Msg(msg)
	m.send(Msg{Type: "state", To: app, ID: id, State: "ended", Reason: "error", Error: msg})
}

// Dial: the app calls a WhatsApp user.
func (m *Manager) Dial(ctx context.Context, req Msg) {
	if err := m.reserve(req.ID); err != nil {
		m.fail(req.From, req.ID, err.Error())
		return
	}
	_, mc, err := m.wa.Account(req.Account)
	if err != nil {
		m.release(req.ID)
		m.fail(req.From, req.ID, err.Error())
		return
	}
	target := strings.TrimSpace(req.Target)
	if target == "" {
		m.release(req.ID)
		m.fail(req.From, req.ID, "no one to call")
		return
	}
	s, answer, err := m.answerOffer(ctx, req.ID, req.From, req.SDP, req.ICEServers)
	if err != nil {
		m.release(req.ID)
		m.fail(req.From, req.ID, "WebRTC: "+err.Error())
		return
	}
	s.peer = target
	m.store(s)
	m.send(Msg{Type: "sdp", To: req.From, ID: req.ID, SDP: answer})

	c, err := mc.CallWithOptions(ctx, target, meowcaller.CallOptions{})
	if err != nil {
		m.end(s, "error")
		m.send(Msg{Type: "state", To: req.From, ID: req.ID, State: "ended", Reason: "error", Error: "WhatsApp: " + err.Error()})
		return
	}
	m.attach(s, c)
	m.setState(s, "calling", "")
}

// Answer: the app picks up a ringing WhatsApp call.
func (m *Manager) Answer(ctx context.Context, req Msg) {
	m.mu.Lock()
	r := m.ringing[req.WACallID]
	if r == nil && req.WACallID == "" && len(m.ringing) == 1 {
		for _, only := range m.ringing {
			r = only
		}
	}
	if r != nil {
		delete(m.ringing, r.info.WACallID)
	}
	m.mu.Unlock()
	if r == nil {
		m.fail(req.From, req.ID, "That call is no longer ringing.")
		return
	}
	if err := m.reserve(req.ID); err != nil {
		_ = r.call.Reject()
		m.fail(req.From, req.ID, err.Error())
		return
	}
	m.send(Msg{Type: "incoming_gone", WACallID: r.info.WACallID, Reason: "answered"})
	s, answer, err := m.answerOffer(ctx, req.ID, req.From, req.SDP, req.ICEServers)
	if err != nil {
		m.release(req.ID)
		_ = r.call.Reject()
		m.fail(req.From, req.ID, "WebRTC: "+err.Error())
		return
	}
	s.peer = r.info.Peer
	m.store(s)
	m.send(Msg{Type: "sdp", To: req.From, ID: req.ID, SDP: answer})
	m.attach(s, r.call)
	if err = r.call.Answer(); err != nil {
		m.end(s, "error")
		return
	}
	m.setState(s, "connecting", "")
}

func (m *Manager) Reject(req Msg) {
	m.mu.Lock()
	r := m.ringing[req.WACallID]
	delete(m.ringing, req.WACallID)
	m.mu.Unlock()
	if r != nil {
		_ = r.call.Reject()
		m.send(Msg{Type: "incoming_gone", WACallID: req.WACallID, Reason: "rejected"})
	}
}

func (m *Manager) Hangup(req Msg) {
	m.mu.Lock()
	s := m.sessions[req.ID]
	m.mu.Unlock()
	if s != nil {
		m.end(s, "hangup")
	}
}

// AppGone: the app's signalling connection closed. A call that is already
// connected keeps going (media does not use the gateway); one still being set
// up is ended.
func (m *Manager) AppGone(app string) {
	m.mu.Lock()
	var drop []*session
	for _, s := range m.sessions {
		if s != nil && s.app == app && s.pc.ConnectionState() != webrtc.PeerConnectionStateConnected {
			drop = append(drop, s)
		}
	}
	m.mu.Unlock()
	for _, s := range drop {
		m.end(s, "app_disconnected")
	}
}

// Incoming is called by meowcaller for a new WhatsApp call to us.
func (m *Manager) Incoming(acct string, c *meowcaller.Call) {
	peer := c.Peer()
	info := RingInfo{WACallID: c.ID(), Account: acct, Peer: peer.String(), Video: c.IsVideo()}
	if peer.Server == types.HiddenUserServer {
		info.PeerLID = peer.String()
		if pn := m.wa.phoneFor(context.Background(), acct, peer); !pn.IsEmpty() {
			info.PeerPN = pn.String()
		}
	} else {
		info.PeerPN = peer.String()
	}
	if active, _ := m.counts(); active >= maxCalls {
		_ = c.Reject()
		return
	}
	m.mu.Lock()
	m.ringing[info.WACallID] = &ringing{call: c, since: time.Now(), info: info}
	m.mu.Unlock()
	c.OnEnd(func(reason string) {
		m.mu.Lock()
		_, still := m.ringing[info.WACallID]
		delete(m.ringing, info.WACallID)
		m.mu.Unlock()
		if still {
			m.send(Msg{Type: "incoming_gone", WACallID: info.WACallID, Reason: reasonOr(reason, "ended")})
		}
	})
	m.log.Info().Str("wa_call", info.WACallID).Bool("video", info.Video).Msg("incoming WhatsApp call")
	m.send(Msg{Type: "incoming", Call: &info})
	go func() {
		time.Sleep(ringTimeout)
		m.mu.Lock()
		r, still := m.ringing[info.WACallID]
		if still && r.call == c {
			delete(m.ringing, info.WACallID)
		}
		m.mu.Unlock()
		if still {
			m.send(Msg{Type: "incoming_gone", WACallID: info.WACallID, Reason: "timeout"})
		}
	}()
}

func (m *Manager) Ringing() []RingInfo {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]RingInfo, 0, len(m.ringing))
	for _, r := range m.ringing {
		out = append(out, r.info)
	}
	return out
}

// HangupAll ends every call (shutdown).
func (m *Manager) HangupAll() {
	m.mu.Lock()
	var all []*session
	for _, s := range m.sessions {
		if s != nil {
			all = append(all, s)
		}
	}
	m.mu.Unlock()
	for _, s := range all {
		m.end(s, "shutdown")
	}
}
