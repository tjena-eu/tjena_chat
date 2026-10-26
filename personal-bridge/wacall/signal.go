package main

// Signalling with the tjena app through the gateway (wap.tjena.eu):
//
//	tjena app ──wss /_tjena/call/v1/app──► gateway ◄──wss /_tjena/call/v1/phone── this daemon
//
// The gateway authenticates the app with the user's Matrix token (only the
// bridge owner gets through) and this daemon with the bridge's token, then
// passes JSON messages between them. It sets "from" on messages from an app;
// "to" on our messages addresses one app, otherwise all of the owner's apps
// get it.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/rs/zerolog"
)

type Msg struct {
	Type string `json:"type"`
	From string `json:"from,omitempty"` // set by the gateway
	To   string `json:"to,omitempty"`

	ID         string      `json:"id,omitempty"` // call id chosen by the app
	Target     string      `json:"target,omitempty"`
	Account    string      `json:"account,omitempty"` // own WhatsApp number (digits) to call from
	WACallID   string      `json:"wa_call_id,omitempty"`
	SDP        string      `json:"sdp,omitempty"`
	ICEServers []ICEServer `json:"ice_servers,omitempty"`
	State      string      `json:"state,omitempty"`
	Reason     string      `json:"reason,omitempty"`
	Error      string      `json:"error,omitempty"`
	Call       *RingInfo   `json:"call,omitempty"`
	Calls      []RingInfo  `json:"calls,omitempty"`
	Online     *bool       `json:"online,omitempty"`

	// Video. App → phone: Video on "call"/"answer" (start with the camera
	// on), On on "video" (camera on/off). Phone → app: Video on "sdp" (the
	// call can carry video), and "video_state" with PeerVideo/Orientation
	// (quarter turns clockwise) or Upgrade (the peer asks to switch to video:
	// "request", or the answer to ours: "accepted"/"rejected"/"cancelled").
	Video       bool   `json:"video,omitempty"`
	On          *bool  `json:"on,omitempty"`
	PeerVideo   *bool  `json:"peer_video,omitempty"`
	Orientation *int   `json:"orientation,omitempty"`
	Upgrade     string `json:"upgrade,omitempty"`
	Status     *WAStatus   `json:"status,omitempty"`
}

type Signal struct {
	log     zerolog.Logger
	url     string
	token   string
	handle  func(Msg)
	writeMu sync.Mutex

	mu        sync.Mutex
	ws        *websocket.Conn
	connected bool
	lastErr   string
}

func newSignal(gateway, token string, log zerolog.Logger, handle func(Msg)) *Signal {
	u := strings.TrimRight(gateway, "/")
	u = strings.Replace(u, "https://", "wss://", 1)
	u = strings.Replace(u, "http://", "ws://", 1)
	return &Signal{log: log, url: u + "/_tjena/call/v1/phone", token: token, handle: handle}
}

func (s *Signal) Status() (bool, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.connected, s.lastErr
}

// Send delivers a message to the app(s). Dropped while disconnected.
func (s *Signal) Send(m Msg) {
	s.mu.Lock()
	ws := s.ws
	s.mu.Unlock()
	if ws == nil {
		return
	}
	data, err := json.Marshal(m)
	if err != nil {
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err = ws.Write(ctx, websocket.MessageText, data); err != nil {
		s.log.Debug().Err(err).Msg("signal write")
	}
}

func (s *Signal) Run(ctx context.Context) {
	backoff := time.Second
	for ctx.Err() == nil {
		start := time.Now()
		err := s.runOnce(ctx)
		s.mu.Lock()
		s.ws, s.connected = nil, false
		if err != nil && ctx.Err() == nil {
			s.lastErr = err.Error()
		}
		s.mu.Unlock()
		if ctx.Err() != nil {
			return
		}
		if time.Since(start) > time.Minute {
			backoff = time.Second
		}
		s.log.Info().Err(err).Dur("retry_in", backoff).Msg("gateway signalling disconnected")
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, time.Minute)
	}
}

func (s *Signal) runOnce(ctx context.Context) error {
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	ws, _, err := websocket.Dial(dctx, s.url, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + s.token}},
	})
	cancel()
	if err != nil {
		return err
	}
	defer ws.CloseNow()
	ws.SetReadLimit(1 << 20)
	s.mu.Lock()
	s.ws, s.connected, s.lastErr = ws, true, ""
	s.mu.Unlock()
	s.log.Info().Msg("gateway signalling connected")

	pctx, stop := context.WithCancel(ctx)
	defer stop()
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-pctx.Done():
				return
			case <-t.C:
				c, cancel := context.WithTimeout(pctx, 15*time.Second)
				err := ws.Ping(c)
				cancel()
				if err != nil {
					ws.CloseNow()
					return
				}
			}
		}
	}()
	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			return err
		}
		if typ != websocket.MessageText {
			continue
		}
		var m Msg
		if json.Unmarshal(data, &m) != nil {
			continue
		}
		go s.handle(m)
	}
}
