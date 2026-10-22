package main

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

type Gateway struct {
	cfg        *Config
	log        *slog.Logger
	store      *Store
	client     *http.Client
	adminToken string

	mu sync.RWMutex
	// Indexes rebuilt from the store after every change.
	byBridgeAS map[string]string // bridge as_token -> slot name (assigned slots only)
	byRealHS   map[string]string // real hs_token -> slot name (all slots)
	conns      map[string]*bridgeConn
	lastSeen   map[string]time.Time // slot -> last disconnect

	auditMu sync.Mutex
	rateMu  sync.Mutex
	rate    map[string][]time.Time
	authMu  sync.Mutex
	authC   map[string]authCacheEntry
}

type authCacheEntry struct {
	mxid    string
	expires time.Time
}

func newGateway(cfg *Config, log *slog.Logger) (*Gateway, error) {
	store, err := openStore(cfg.DataDir)
	if err != nil {
		return nil, err
	}
	g := &Gateway{
		cfg: cfg, log: log, store: store,
		client:   &http.Client{Timeout: 30 * time.Second},
		conns:    map[string]*bridgeConn{},
		lastSeen: map[string]time.Time{},
		rate:     map[string][]time.Time{},
		authC:    map[string]authCacheEntry{},
	}
	g.adminToken, err = loadOrCreateSecret(filepath.Join(cfg.DataDir, "admin_token"))
	if err != nil {
		return nil, err
	}
	g.reindex()
	return g, nil
}

func loadOrCreateSecret(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err == nil && len(bytes.TrimSpace(data)) >= 32 {
		return string(bytes.TrimSpace(data)), nil
	}
	tok := randomToken(32)
	return tok, os.WriteFile(path, []byte(tok+"\n"), 0o600)
}

// reindex rebuilds token lookups and drops connections whose tokens are no
// longer valid (revoked or rotated).
func (g *Gateway) reindex() {
	byAS := map[string]string{}
	byHS := map[string]string{}
	g.store.View(func(st *stateFile) {
		for _, s := range st.Slots {
			byHS[s.HSToken] = s.Name
			if s.State == SlotAssigned && s.BridgeASToken != "" {
				byAS[s.BridgeASToken] = s.Name
			}
		}
	})
	g.mu.Lock()
	g.byBridgeAS, g.byRealHS = byAS, byHS
	var drop []*bridgeConn
	for name, c := range g.conns {
		if tok, ok := byAS[c.token]; !ok || tok != name {
			drop = append(drop, c)
			delete(g.conns, name)
		}
	}
	g.mu.Unlock()
	for _, c := range drop {
		g.log.Info("closing connection with revoked token", "slot", c.id)
		c.close(closeRevoked, "revoked")
	}
}

func (g *Gateway) slot(name string) (s Slot, ok bool) {
	g.store.View(func(st *stateFile) {
		if p := st.find(name); p != nil {
			s, ok = *p, true
		}
	})
	return
}

func (g *Gateway) conn(name string) *bridgeConn {
	g.mu.RLock()
	defer g.mu.RUnlock()
	return g.conns[name]
}

func bearer(r *http.Request) string {
	if after, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer "); ok {
		return after
	}
	return r.URL.Query().Get("access_token")
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"errcode": code, "error": msg})
}

func (g *Gateway) audit(action, actor, user, slot string, extra map[string]any) {
	rec := map[string]any{"time": time.Now().UTC().Format(time.RFC3339), "action": action, "actor": actor, "user": user, "slot": slot}
	for k, v := range extra {
		rec[k] = v
	}
	line, _ := json.Marshal(rec)
	g.auditMu.Lock()
	defer g.auditMu.Unlock()
	f, err := os.OpenFile(filepath.Join(g.cfg.DataDir, "audit.jsonl"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		g.log.Error("audit log write failed", "err", err)
		return
	}
	defer f.Close()
	_, _ = f.Write(append(line, '\n'))
}

// ---------------------------------------------------------------------------
// Public: bridge websocket

// GET /_matrix/client/unstable/fi.mau.as_sync
func (g *Gateway) handleWebsocket(w http.ResponseWriter, r *http.Request) {
	token := bearer(r)
	g.mu.RLock()
	name, ok := g.byBridgeAS[token]
	g.mu.RUnlock()
	if !ok {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Unknown authorization token")
		return
	}
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		g.log.Warn("websocket upgrade failed", "slot", name, "err", err)
		return
	}
	c := newBridgeConn(name, token, ws)
	g.mu.Lock()
	old := g.conns[name]
	g.conns[name] = c
	g.mu.Unlock()
	if old != nil {
		// Newest connection wins; the old bridge process exits on conn_replaced.
		go old.close(closeConnReplaced, "conn_replaced")
	}
	g.log.Info("bridge connected", "slot", name, "version", r.Header.Get("X-Mautrix-Websocket-Version"))
	_ = c.writeJSON(c.ctx, map[string]string{"command": "connect", "status": "connected"})
	go c.keepalive(time.Duration(g.cfg.KeepaliveInterval)*time.Second, g.log)
	go g.flushSynapseQueue(name)

	err = c.readLoop(g.log)
	c.cancel()
	g.mu.Lock()
	if g.conns[name] == c {
		delete(g.conns, name)
		g.lastSeen[name] = time.Now()
	}
	g.mu.Unlock()
	_ = ws.CloseNow()
	g.log.Info("bridge disconnected", "slot", name, "reason", websocket.CloseStatus(err).String())
}

// flushSynapseQueue pings Synapse as the slot's appservice. A successful ping
// makes Synapse retry queued transactions now instead of after its backoff.
func (g *Gateway) flushSynapseQueue(name string) {
	time.Sleep(2 * time.Second)
	s, ok := g.slot(name)
	if !ok {
		return
	}
	u := fmt.Sprintf("%s/_matrix/client/v1/appservice/%s/ping", g.cfg.SynapseURL, url.PathEscape(s.ASID))
	req, _ := http.NewRequest(http.MethodPost, u, strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer "+s.ASToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := g.client.Do(req)
	if err != nil {
		g.log.Warn("synapse ping failed", "slot", name, "err", err)
		return
	}
	_ = resp.Body.Close()
	g.log.Info("synapse ping", "slot", name, "status", resp.StatusCode)
}

// ---------------------------------------------------------------------------
// Internal: Synapse -> gateway

func (g *Gateway) slotByRealHS(r *http.Request) (Slot, bool) {
	g.mu.RLock()
	name, ok := g.byRealHS[bearer(r)]
	g.mu.RUnlock()
	if !ok {
		return Slot{}, false
	}
	return g.slot(name)
}

// PUT /_matrix/app/v1/transactions/{txnID}
func (g *Gateway) handleTransaction(w http.ResponseWriter, r *http.Request) {
	s, ok := g.slotByRealHS(r)
	if !ok {
		writeError(w, http.StatusForbidden, "M_FORBIDDEN", "Unknown hs_token")
		return
	}
	txnID := r.PathValue("txnID")
	var fields map[string]json.RawMessage
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 100<<20)).Decode(&fields); err != nil || fields == nil {
		writeError(w, http.StatusBadRequest, "M_BAD_JSON", "Failed to decode transaction")
		return
	}
	if s.State != SlotAssigned {
		// Nobody owns this slot (anymore): accept and drop, so Synapse
		// doesn't keep a growing retry queue for it.
		writeJSON(w, http.StatusOK, map[string]any{})
		return
	}
	c := g.conn(s.Name)
	if c == nil {
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_NOT_CONNECTED", "Bridge is not connected")
		return
	}
	fields["command"] = json.RawMessage(`"transaction"`)
	fields["status"] = json.RawMessage(`"ok"`)
	fields["txn_id"], _ = json.Marshal(txnID)
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(g.cfg.TransactionTimeout)*time.Second)
	defer cancel()
	resp, err := c.request(ctx, fields)
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		g.log.Warn("transaction not acknowledged in time", "slot", s.Name, "txn", txnID)
		writeError(w, http.StatusGatewayTimeout, "FI.MAU.WS_TIMEOUT", "Bridge did not acknowledge transaction")
	case err != nil:
		g.log.Warn("transaction delivery failed", "slot", s.Name, "txn", txnID, "err", err)
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_SEND_FAIL", "Failed to deliver transaction")
	case !resp.ok:
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_REJECTED", "Bridge rejected transaction")
	default:
		g.mu.Lock()
		c.lastEvent = time.Now()
		g.mu.Unlock()
		writeJSON(w, http.StatusOK, map[string]any{})
	}
}

type httpProxyRequest struct {
	Method      string          `json:"method"`
	Path        string          `json:"path"`
	Query       string          `json:"query"`
	Headers     http.Header     `json:"headers"`
	Body        json.RawMessage `json:"body,omitempty"`
	EscapedPath bool            `json:"escaped_path,omitempty"`
}

type httpProxyResponse struct {
	Status  int             `json:"status"`
	Headers http.Header     `json:"headers"`
	Body    json.RawMessage `json:"body"`
}

// Other /_matrix/app/* calls from Synapse (ping, user/room queries) are
// forwarded to the bridge via http_proxy, with the hs_token swapped for the
// bridge's own one.
func (g *Gateway) handleAppAPI(w http.ResponseWriter, r *http.Request) {
	s, ok := g.slotByRealHS(r)
	if !ok {
		writeError(w, http.StatusForbidden, "M_FORBIDDEN", "Unknown hs_token")
		return
	}
	c := g.conn(s.Name)
	if s.State != SlotAssigned || c == nil {
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_NOT_CONNECTED", "Bridge is not connected")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "M_BAD_JSON", "Failed to read body")
		return
	}
	body = bytes.TrimSpace(body)
	if len(body) > 0 && !json.Valid(body) {
		writeError(w, http.StatusBadRequest, "M_NOT_JSON", "Body must be JSON")
		return
	}
	headers := r.Header.Clone()
	headers.Set("Authorization", "Bearer "+s.BridgeHSToken)
	q := r.URL.Query()
	q.Del("access_token")
	data, _ := json.Marshal(httpProxyRequest{
		Method: r.Method, Path: r.URL.EscapedPath(), EscapedPath: true,
		Query: q.Encode(), Headers: headers, Body: body,
	})
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	resp, err := c.request(ctx, map[string]json.RawMessage{
		"command": json.RawMessage(`"http_proxy"`),
		"data":    data,
	})
	if err != nil || !resp.ok {
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_SEND_FAIL", "Bridge did not answer")
		return
	}
	var pr httpProxyResponse
	if err = json.Unmarshal(resp.data, &pr); err != nil || pr.Status == 0 {
		writeError(w, http.StatusBadGateway, "FI.MAU.WS_BAD_RESPONSE", "Invalid proxy response from bridge")
		return
	}
	if ct := pr.Headers.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(pr.Status)
	_, _ = w.Write(pr.Body)
}

// ---------------------------------------------------------------------------
// Background: notice when Synapse has loaded a slot's registration.

func (g *Gateway) activationLoop(ctx context.Context) {
	for {
		g.checkActivation(ctx)
		select {
		case <-ctx.Done():
			return
		case <-time.After(60 * time.Second):
		}
	}
}

func (g *Gateway) checkActivation(ctx context.Context) {
	var pending []Slot
	g.store.View(func(st *stateFile) {
		for _, s := range st.Slots {
			if !s.Active && s.State != SlotBurned {
				pending = append(pending, *s)
			}
		}
	})
	for _, s := range pending {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, g.cfg.SynapseURL+"/_matrix/client/v3/account/whoami", nil)
		req.Header.Set("Authorization", "Bearer "+s.ASToken)
		resp, err := g.client.Do(req)
		if err != nil {
			g.log.Warn("activation check failed", "err", err)
			return
		}
		_ = resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			_ = g.store.Update(func(st *stateFile) error {
				if p := st.find(s.Name); p != nil {
					p.Active = true
				}
				return nil
			})
			g.log.Info("slot active in Synapse", "slot", s.Name)
		}
	}
}

// ---------------------------------------------------------------------------
// Internal: status and admin API

type slotStatus struct {
	Slot           string     `json:"slot"`
	State          string     `json:"state"`
	Active         bool       `json:"active"`
	Owner          string     `json:"owner,omitempty"`
	BotMXID        string     `json:"bot_mxid"`
	Connected      bool       `json:"connected"`
	ConnectedSince *time.Time `json:"connected_since,omitempty"`
	LastEvent      *time.Time `json:"last_event,omitempty"`
	LastSeen       *time.Time `json:"last_seen,omitempty"`
}

func (g *Gateway) statusOf(s Slot) slotStatus {
	out := slotStatus{Slot: s.Name, State: s.State, Active: s.Active, Owner: s.Owner,
		BotMXID: "@" + s.BotLocalpart() + ":" + g.cfg.ServerName}
	g.mu.RLock()
	defer g.mu.RUnlock()
	if c := g.conns[s.Name]; c != nil {
		since := c.since
		out.Connected, out.ConnectedSince = true, &since
		if !c.lastEvent.IsZero() {
			le := c.lastEvent
			out.LastEvent = &le
		}
	}
	if t, ok := g.lastSeen[s.Name]; ok {
		out.LastSeen = &t
	}
	return out
}

func (g *Gateway) allStatus() []slotStatus {
	var slots []Slot
	g.store.View(func(st *stateFile) {
		for _, s := range st.Slots {
			slots = append(slots, *s)
		}
	})
	out := make([]slotStatus, 0, len(slots))
	for _, s := range slots {
		out = append(out, g.statusOf(s))
	}
	return out
}

func (g *Gateway) checkAdmin(w http.ResponseWriter, r *http.Request) bool {
	if subtle.ConstantTimeCompare([]byte(bearer(r)), []byte(g.adminToken)) != 1 {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Bad admin token")
		return false
	}
	return true
}

func (g *Gateway) handleStatus(w http.ResponseWriter, r *http.Request) {
	if g.cfg.StatusToken != "" && subtle.ConstantTimeCompare([]byte(bearer(r)), []byte(g.cfg.StatusToken)) != 1 &&
		subtle.ConstantTimeCompare([]byte(bearer(r)), []byte(g.adminToken)) != 1 {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Bad status token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"slots": g.allStatus()})
}

func (g *Gateway) internalRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("PUT /_matrix/app/v1/transactions/{txnID}", g.handleTransaction)
	mux.HandleFunc("PUT /transactions/{txnID}", g.handleTransaction)
	mux.HandleFunc("/_matrix/app/", g.handleAppAPI)
	mux.HandleFunc("GET /_tjena/status", g.handleStatus)
	mux.HandleFunc("POST /_tjena/admin/{op}", g.handleAdmin)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "M_UNRECOGNIZED", "Unrecognized endpoint")
	})
	return mux
}

func (g *Gateway) publicRoutes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /_matrix/client/unstable/fi.mau.as_sync", g.handleWebsocket)
	cp := g.clientProxy()
	mux.Handle("/_matrix/client/", cp)
	mux.Handle("/_matrix/media/", cp)
	mux.HandleFunc("POST /provision/v1/bridge", g.handleClaim)
	mux.HandleFunc("GET /provision/v1/bridge", g.handleBridgeStatus)
	mux.HandleFunc("DELETE /provision/v1/bridge", g.handleRevoke)
	mux.HandleFunc("GET /provision/v1/info", g.handleInfo)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "M_UNRECOGNIZED", "Unrecognized endpoint")
	})
	return withCORS(mux)
}

// withCORS allows the provisioner to be called from tjena web too.
func withCORS(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/provision/") {
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}
		h.ServeHTTP(w, r)
	})
}
