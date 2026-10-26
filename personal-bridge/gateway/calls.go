package main

// Call signalling for WhatsApp calls through the personal bridge.
//
//	tjena app ──wss /_tjena/call/v1/app──► gateway ◄──wss /_tjena/call/v1/phone── wacall (bridge phone)
//
// The gateway only switches small JSON messages (call requests, WebRTC
// offer/answer, call state) between a bridge owner's apps and their bridge
// phone. Audio never passes through here: it goes directly (or via TURN)
// between the app and the phone, DTLS-SRTP encrypted.
//
// Auth: the app with the owner's Matrix token (access token or
// "openid:<token>", like the provisioning API); the phone with the slot's
// bridge token. Messages from an app get "from" set to its connection id
// (overwriting whatever the app sent); the phone addresses one app with "to",
// or all of the owner's apps without it.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

const (
	callMsgLimit     = 64 << 10 // an SDP with candidates is a few KB
	callAppsPerOwner = 8
	callMsgsPerMin   = 120
)

type callConn struct {
	id      string
	slot    string
	ws      *websocket.Conn
	writeMu sync.Mutex

	// simple rate limit
	rateMu    sync.Mutex
	rateStart time.Time
	rateN     int
}

func (c *callConn) send(ctx context.Context, data []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, data)
}

func (c *callConn) allow() bool {
	c.rateMu.Lock()
	defer c.rateMu.Unlock()
	if time.Since(c.rateStart) > time.Minute {
		c.rateStart, c.rateN = time.Now(), 0
	}
	c.rateN++
	return c.rateN <= callMsgsPerMin
}

type callHub struct {
	mu     sync.Mutex
	phones map[string]*callConn            // slot -> phone
	apps   map[string]map[string]*callConn // slot -> id -> app
	nextID atomic.Int64
}

func newCallHub() *callHub {
	return &callHub{phones: map[string]*callConn{}, apps: map[string]map[string]*callConn{}}
}

func (h *callHub) appsOf(slot string) []*callConn {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]*callConn, 0, len(h.apps[slot]))
	for _, c := range h.apps[slot] {
		out = append(out, c)
	}
	return out
}

func (h *callHub) phone(slot string) *callConn {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.phones[slot]
}

func phoneNotice(online bool) []byte {
	b, _ := json.Marshal(map[string]any{"type": "phone", "online": online})
	return b
}

// ownedSlot returns the assigned slot of a user, if any.
func (g *Gateway) ownedSlot(mxid string) (string, bool) {
	var name string
	g.store.View(func(st *stateFile) {
		if owned := st.ownedBy(mxid); len(owned) > 0 {
			name = owned[0].Name
		}
	})
	return name, name != ""
}

// stillValid re-checks a connection's credentials before each message, so a
// revoked bridge or a slot that changed owner stops working at once.
func (g *Gateway) callStillValid(c *callConn, token, owner string) bool {
	if owner == "" { // phone
		g.mu.RLock()
		name, ok := g.byBridgeAS[token]
		g.mu.RUnlock()
		return ok && name == c.slot
	}
	s, ok := g.slot(c.slot)
	return ok && s.State == SlotAssigned && s.Owner == owner
}

// GET /_tjena/call/v1/phone
func (g *Gateway) handleCallPhone(w http.ResponseWriter, r *http.Request) {
	token := bearer(r)
	g.mu.RLock()
	slot, ok := g.byBridgeAS[token]
	g.mu.RUnlock()
	if !ok {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Unknown authorization token")
		return
	}
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ws.SetReadLimit(callMsgLimit)
	h := g.calls
	c := &callConn{id: "phone", slot: slot, ws: ws}
	h.mu.Lock()
	old := h.phones[slot]
	h.phones[slot] = c
	h.mu.Unlock()
	if old != nil {
		_ = old.ws.Close(websocket.StatusPolicyViolation, "replaced")
	}
	g.log.Info("call phone connected", "slot", slot)
	for _, a := range h.appsOf(slot) {
		_ = a.send(r.Context(), phoneNotice(true))
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go pingLoop(ctx, ws)

	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			break
		}
		if !g.callStillValid(c, token, "") {
			_ = ws.Close(websocket.StatusPolicyViolation, "revoked")
			break
		}
		if typ != websocket.MessageText || !c.allow() {
			continue
		}
		var m map[string]json.RawMessage
		if json.Unmarshal(data, &m) != nil {
			continue
		}
		var to string
		_ = json.Unmarshal(m["to"], &to)
		delete(m, "to")
		delete(m, "from")
		out, _ := json.Marshal(m)
		for _, a := range h.appsOf(slot) {
			if to == "" || a.id == to {
				_ = a.send(ctx, out)
			}
		}
	}
	h.mu.Lock()
	if h.phones[slot] == c {
		delete(h.phones, slot)
	}
	still := h.phones[slot] != nil
	h.mu.Unlock()
	_ = ws.CloseNow()
	if !still {
		for _, a := range h.appsOf(slot) {
			_ = a.send(context.Background(), phoneNotice(false))
		}
	}
	g.log.Info("call phone disconnected", "slot", slot)
}

// GET /_tjena/call/v1/app
func (g *Gateway) handleCallApp(w http.ResponseWriter, r *http.Request) {
	mxid, err := g.authenticate(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", err.Error())
		return
	}
	slot, ok := g.ownedSlot(mxid)
	if !ok {
		writeError(w, http.StatusNotFound, "M_NOT_FOUND", "You have no personal bridge")
		return
	}
	h := g.calls
	h.mu.Lock()
	if len(h.apps[slot]) >= callAppsPerOwner {
		h.mu.Unlock()
		writeError(w, http.StatusTooManyRequests, "M_LIMIT_EXCEEDED", "Too many call connections")
		return
	}
	h.mu.Unlock()
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	ws.SetReadLimit(callMsgLimit)
	c := &callConn{id: fmt.Sprintf("app%d", h.nextID.Add(1)), slot: slot, ws: ws}
	h.mu.Lock()
	if h.apps[slot] == nil {
		h.apps[slot] = map[string]*callConn{}
	}
	h.apps[slot][c.id] = c
	h.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go pingLoop(ctx, ws)
	_ = c.send(ctx, phoneNotice(h.phone(slot) != nil))

	for {
		typ, data, err := ws.Read(ctx)
		if err != nil {
			break
		}
		if typ != websocket.MessageText || !c.allow() {
			continue
		}
		if !g.callStillValid(c, "", mxid) {
			_ = ws.Close(websocket.StatusPolicyViolation, "revoked")
			break
		}
		var m map[string]json.RawMessage
		if json.Unmarshal(data, &m) != nil {
			continue
		}
		m["from"], _ = json.Marshal(c.id)
		delete(m, "to")
		out, _ := json.Marshal(m)
		if p := h.phone(slot); p != nil {
			_ = p.send(ctx, out)
		} else {
			_ = c.send(ctx, phoneNotice(false))
		}
	}
	h.mu.Lock()
	delete(h.apps[slot], c.id)
	if len(h.apps[slot]) == 0 {
		delete(h.apps, slot)
	}
	h.mu.Unlock()
	_ = ws.CloseNow()
	if p := h.phone(slot); p != nil {
		gone, _ := json.Marshal(map[string]string{"type": "app_gone", "from": c.id})
		_ = p.send(context.Background(), gone)
	}
}

func pingLoop(ctx context.Context, ws *websocket.Conn) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			c, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := ws.Ping(c)
			cancel()
			if err != nil {
				_ = ws.CloseNow()
				return
			}
		}
	}
}
