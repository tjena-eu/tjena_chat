// bridge-relay runs on the bridge phone next to the unmodified
// mautrix-whatsapp binary.
//
//	mautrix-whatsapp --ws--> 127.0.0.1 relay --wss--> gateway (wap.tjena.eu)
//	                              ^
//	                              └── bridge app UI: /relay/status, /relay/provision/...
//
// Why: in websocket mode the bridge serves its provisioning API (WhatsApp
// login, logout) only through http_proxy commands on its websocket, not on a
// local port. The relay passes all frames through unchanged and injects the
// app's provisioning calls as http_proxy commands with its own request-id
// range, so the phone number, pairing code and provisioning secret never
// leave the phone. It also gives the UI exact connection status.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coder/websocket"
)

// Request ids the relay uses for its own commands. The gateway counts up from 1.
const localIDBase = int64(1) << 40

type Config struct {
	Listen     string `json:"listen"`      // 127.0.0.1:port
	Upstream   string `json:"upstream"`    // https://wap.tjena.eu
	ASToken    string `json:"as_token"`    // bridge's as_token (from the gateway)
	APISecret  string `json:"api_secret"`  // protects /relay/* for the app
	ProvSecret string `json:"prov_secret"` // bridge provisioning.shared_secret
	Owner      string `json:"owner"`       // owner MXID, used as user_id for provisioning
	StatusFile string `json:"status_file"` // optional: JSON status written here on change
	KeysFile   string `json:"keys_file"`   // optional: public keys the bridge uploaded (security screen)
}

type frame struct {
	ID      int64  `json:"id,omitempty"`
	Command string `json:"command"`
}

type reply struct {
	ok   bool
	data json.RawMessage
}

type Relay struct {
	cfg Config
	log *slog.Logger

	mu            sync.Mutex
	bridge        *websocket.Conn
	bridgeCtx     context.Context
	bridgeSince   time.Time
	upstreamOK    bool
	upstreamSince time.Time
	upstreamErr   string
	revoked       bool
	lastEvent     time.Time
	lastHTTPOK    bool
	writeMu       sync.Mutex
	keysMu        sync.Mutex

	nextID  atomic.Int64
	waitMu  sync.Mutex
	waiters map[int64]chan reply

	pace *pacer
}

type Status struct {
	BridgeConnected   bool       `json:"bridge_connected"`
	BridgeSince       *time.Time `json:"bridge_since,omitempty"`
	UpstreamConnected bool       `json:"upstream_connected"`
	UpstreamSince     *time.Time `json:"upstream_since,omitempty"`
	UpstreamError     string     `json:"upstream_error,omitempty"`
	Revoked           bool       `json:"revoked"`
	LastEvent         *time.Time `json:"last_event,omitempty"`
	Pace              PaceStatus `json:"pace"`
}

func tp(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

func (r *Relay) status() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	return Status{
		BridgeConnected: r.bridge != nil, BridgeSince: tp(r.bridgeSince),
		UpstreamConnected: r.upstreamOK, UpstreamSince: tp(r.upstreamSince),
		UpstreamError: r.upstreamErr, Revoked: r.revoked, LastEvent: tp(r.lastEvent),
		Pace: r.pace.status(),
	}
}

func (r *Relay) writeStatusFile() {
	if r.cfg.StatusFile == "" {
		return
	}
	data, _ := json.Marshal(r.status())
	tmp := r.cfg.StatusFile + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, r.cfg.StatusFile)
	}
}

func bearer(req *http.Request) string {
	return strings.TrimPrefix(req.Header.Get("Authorization"), "Bearer ")
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"errcode": code, "error": msg})
}

// handleBridge: the bridge's websocket. Dial upstream, then pipe both ways.
func (r *Relay) handleBridge(w http.ResponseWriter, req *http.Request) {
	if bearer(req) != r.cfg.ASToken {
		writeErr(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "Unknown authorization token")
		return
	}
	up, err := url.Parse(r.cfg.Upstream)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "M_UNKNOWN", "bad upstream url")
		return
	}
	up.Path = path.Join(up.Path, "_matrix/client/unstable/fi.mau.as_sync")
	switch up.Scheme {
	case "https":
		up.Scheme = "wss"
	case "http":
		up.Scheme = "ws"
	}
	hdr := http.Header{}
	for _, h := range []string{"Authorization", "User-Agent", "X-Mautrix-Process-Id", "X-Mautrix-Websocket-Version"} {
		if v := req.Header.Get(h); v != "" {
			hdr.Set(h, v)
		}
	}
	dialCtx, cancel := context.WithTimeout(req.Context(), 30*time.Second)
	upConn, resp, err := websocket.Dial(dialCtx, up.String(), &websocket.DialOptions{HTTPHeader: hdr})
	cancel()
	if err != nil {
		msg := err.Error()
		status := http.StatusBadGateway
		if resp != nil && resp.StatusCode >= 400 {
			status = resp.StatusCode
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			msg = fmt.Sprintf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}
		r.mu.Lock()
		r.upstreamOK, r.upstreamErr = false, msg
		r.revoked = status == http.StatusUnauthorized
		r.mu.Unlock()
		r.writeStatusFile()
		r.log.Warn("upstream connect failed", "err", msg)
		writeErr(w, status, "FI.MAU.WS_UPSTREAM", msg)
		return
	}
	upConn.SetReadLimit(50 << 20)

	bridgeConn, err := websocket.Accept(w, req, nil)
	if err != nil {
		_ = upConn.CloseNow()
		return
	}
	bridgeConn.SetReadLimit(50 << 20)
	ctx, stop := context.WithCancel(context.Background())
	defer stop()

	r.mu.Lock()
	if r.bridge != nil {
		_ = r.bridge.Close(websocket.StatusGoingAway, "")
	}
	now := time.Now()
	r.bridge, r.bridgeCtx, r.bridgeSince = bridgeConn, ctx, now
	r.upstreamOK, r.upstreamSince, r.upstreamErr, r.revoked = true, now, "", false
	r.mu.Unlock()
	r.writeStatusFile()
	r.log.Info("bridge and upstream connected")

	errc := make(chan error, 2)
	// upstream -> bridge: verbatim.
	go func() {
		for {
			typ, data, err := upConn.Read(ctx)
			if err != nil {
				errc <- fmt.Errorf("upstream: %w", err)
				return
			}
			r.mu.Lock()
			r.lastEvent = time.Now()
			r.mu.Unlock()
			r.writeMu.Lock()
			err = bridgeConn.Write(ctx, typ, data)
			r.writeMu.Unlock()
			if err != nil {
				errc <- fmt.Errorf("bridge write: %w", err)
				return
			}
		}
	}()
	// bridge -> upstream: verbatim, except replies to the relay's own requests.
	go func() {
		for {
			typ, data, err := bridgeConn.Read(ctx)
			if err != nil {
				errc <- fmt.Errorf("bridge: %w", err)
				return
			}
			var f frame
			if typ == websocket.MessageText && json.Unmarshal(data, &f) == nil &&
				f.ID >= localIDBase && (f.Command == "response" || f.Command == "error") {
				var full struct {
					Data json.RawMessage `json:"data"`
				}
				_ = json.Unmarshal(data, &full)
				r.waitMu.Lock()
				ch := r.waiters[f.ID]
				r.waitMu.Unlock()
				if ch != nil {
					ch <- reply{ok: f.Command == "response", data: full.Data}
				}
				continue
			}
			if err = upConn.Write(ctx, typ, data); err != nil {
				errc <- fmt.Errorf("upstream write: %w", err)
				return
			}
		}
	}()
	err = <-errc
	stop()

	// Pass the upstream close code/reason on so the bridge reacts as it
	// would to the gateway directly (e.g. conn_replaced -> bridge exits).
	code, reason := websocket.StatusGoingAway, ""
	var ce websocket.CloseError
	if errors.As(err, &ce) && strings.HasPrefix(err.Error(), "upstream") {
		code, reason = ce.Code, ce.Reason
	}
	_ = bridgeConn.Close(code, reason)
	_ = upConn.Close(websocket.StatusGoingAway, "")
	r.mu.Lock()
	if r.bridge == bridgeConn {
		r.bridge = nil
		r.upstreamOK = false
		r.upstreamErr = err.Error()
		r.revoked = code == websocket.StatusPolicyViolation
	}
	r.mu.Unlock()
	r.writeStatusFile()
	r.log.Info("connection closed", "err", err)
}

func (r *Relay) httpProxy() http.Handler {
	target, err := url.Parse(r.cfg.Upstream)
	if err != nil {
		panic(err)
	}
	return &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = target.Host
		},
		FlushInterval: -1,
		ModifyResponse: func(resp *http.Response) error {
			r.mu.Lock()
			r.lastHTTPOK = resp.StatusCode < 500
			if resp.StatusCode == http.StatusUnauthorized && resp.Request.Header.Get("Authorization") == "Bearer "+r.cfg.ASToken {
				r.revoked = true
			}
			r.mu.Unlock()
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, req *http.Request, err error) {
			r.mu.Lock()
			r.lastHTTPOK = false
			r.mu.Unlock()
			writeErr(w, http.StatusBadGateway, "M_UNKNOWN", "upstream unreachable")
		},
	}
}

// request sends a command to the bridge and waits for its reply.
func (r *Relay) request(ctx context.Context, cmd string, data any) (reply, error) {
	r.mu.Lock()
	conn, cctx := r.bridge, r.bridgeCtx
	r.mu.Unlock()
	if conn == nil {
		return reply{}, errors.New("bridge not connected")
	}
	id := localIDBase + r.nextID.Add(1)
	payload, _ := json.Marshal(map[string]any{"id": id, "command": cmd, "data": data})
	ch := make(chan reply, 1)
	r.waitMu.Lock()
	r.waiters[id] = ch
	r.waitMu.Unlock()
	defer func() {
		r.waitMu.Lock()
		delete(r.waiters, id)
		r.waitMu.Unlock()
	}()
	r.writeMu.Lock()
	err := conn.Write(ctx, websocket.MessageText, payload)
	r.writeMu.Unlock()
	if err != nil {
		return reply{}, err
	}
	select {
	case rep := <-ch:
		return rep, nil
	case <-cctx.Done():
		return reply{}, errors.New("bridge disconnected")
	case <-ctx.Done():
		return reply{}, ctx.Err()
	}
}

// /relay/provision/<path> -> bridge /_matrix/provision/<path> via http_proxy.
func (r *Relay) handleProvision(w http.ResponseWriter, req *http.Request) {
	sub := strings.TrimPrefix(req.URL.EscapedPath(), "/relay/provision")
	if !strings.HasPrefix(sub, "/v3/") {
		writeErr(w, http.StatusNotFound, "M_UNRECOGNIZED", "only /v3/ provisioning endpoints")
		return
	}
	body, err := io.ReadAll(io.LimitReader(req.Body, 1<<20))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "M_BAD_JSON", "read error")
		return
	}
	if len(body) > 0 && !json.Valid(body) {
		writeErr(w, http.StatusBadRequest, "M_NOT_JSON", "body must be JSON")
		return
	}
	q := req.URL.Query()
	q.Set("user_id", r.cfg.Owner) // the owner is the only user the UI acts for
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+r.cfg.ProvSecret)
	hdr.Set("Content-Type", "application/json")
	data := map[string]any{
		"method": req.Method, "path": "/_matrix/provision" + sub, "escaped_path": true,
		"query": q.Encode(), "headers": hdr,
	}
	if len(body) > 0 {
		data["body"] = json.RawMessage(body)
	}
	// display_and_wait long-polls until the user finishes on WhatsApp.
	ctx, cancel := context.WithTimeout(req.Context(), 10*time.Minute)
	defer cancel()
	rep, err := r.request(ctx, "http_proxy", data)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "EU.TJENA.BRIDGE_UNAVAILABLE", err.Error())
		return
	}
	if !rep.ok {
		writeErr(w, http.StatusBadGateway, "EU.TJENA.BRIDGE_ERROR", string(rep.data))
		return
	}
	var pr struct {
		Status  int             `json:"status"`
		Headers http.Header     `json:"headers"`
		Body    json.RawMessage `json:"body"`
	}
	if err = json.Unmarshal(rep.data, &pr); err != nil || pr.Status == 0 {
		writeErr(w, http.StatusBadGateway, "EU.TJENA.BRIDGE_ERROR", "bad proxy response")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(pr.Status)
	_, _ = w.Write(pr.Body)
}

func (r *Relay) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /_matrix/client/unstable/fi.mau.as_sync", r.handleBridge)
	// Everything else the bridge sends (client API, media) goes to the gateway,
	// which swaps the bridge token for the real one.
	mux.Handle("/_matrix/", r.observeKeyUploads(r.pace.wrap(r.httpProxy())))
	api := func(h http.HandlerFunc) http.HandlerFunc {
		return func(w http.ResponseWriter, req *http.Request) {
			if r.cfg.APISecret == "" || bearer(req) != r.cfg.APISecret {
				writeErr(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", "bad api secret")
				return
			}
			h(w, req)
		}
	}
	mux.HandleFunc("GET /relay/status", api(func(w http.ResponseWriter, req *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(r.status())
	}))
	mux.HandleFunc("/relay/provision/", api(r.handleProvision))
	return mux
}

func main() {
	// Subcommand: generate the bridge config (used by the bridge app).
	if len(os.Args) > 1 && os.Args[1] == "bridge-config" {
		if err := runBridgeConfig(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "bridge-config:", err)
			os.Exit(1)
		}
		return
	}
	// Subcommand: read-only key/trust summary for the app's Security screen.
	if len(os.Args) > 1 && os.Args[1] == "security-info" {
		if err := runSecurityInfo(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "security-info:", err)
			os.Exit(1)
		}
		return
	}
	// Subcommand: read-only history import summary for the app.
	if len(os.Args) > 1 && os.Args[1] == "history-info" {
		if err := runHistoryInfo(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "history-info:", err)
			os.Exit(1)
		}
		return
	}
	// Subcommand: let the bridge finish stopped history imports (bridge stopped).
	if len(os.Args) > 1 && os.Args[1] == "history-catchup" {
		if err := runHistoryCatchup(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "history-catchup:", err)
			os.Exit(1)
		}
		return
	}
	// Subcommand: pause/resume double puppeting for a fast history import (bridge stopped).
	if len(os.Args) > 1 && os.Args[1] == "double-puppet" {
		if err := runDoublePuppet(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, "double-puppet:", err)
			os.Exit(1)
		}
		return
	}
	cfgPath := flag.String("config", "relay.json", "relay config (JSON)")
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stdout, nil))
	data, err := os.ReadFile(*cfgPath)
	if err != nil {
		log.Error("read config", "err", err)
		os.Exit(1)
	}
	var cfg Config
	if err = json.Unmarshal(data, &cfg); err != nil {
		log.Error("parse config", "err", err)
		os.Exit(1)
	}
	if !strings.HasPrefix(cfg.Listen, "127.0.0.1:") {
		log.Error("listen must be on 127.0.0.1")
		os.Exit(1)
	}
	r := &Relay{cfg: cfg, log: log, waiters: map[int64]chan reply{}, pace: newPacer()}
	r.writeStatusFile()
	// Keep the app's view of send pacing current.
	go func() {
		var last PaceStatus
		for range time.Tick(5 * time.Second) {
			if s := r.pace.status(); s.RateLimitHits != last.RateLimitHits || s.SendsWaiting != last.SendsWaiting || s.HandedBack != last.HandedBack {
				last = s
				r.writeStatusFile()
			}
		}
	}()
	srv := &http.Server{Addr: cfg.Listen, Handler: r.routes(), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		log.Info("relay listening", "addr", cfg.Listen, "upstream", cfg.Upstream)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
}
