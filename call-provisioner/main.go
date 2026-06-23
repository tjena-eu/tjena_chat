// Command call-provisioner mints ephemeral guest users + temporary unencrypted
// Matrix call rooms so a Tjena host can "call" a WhatsApp-bridged contact via a
// shareable web link (legacy m.call.* VoIP, joined by a no-app browser guest).
//
// It holds two server secrets (a @callbot admin token and the registration
// shared secret) and exposes a tiny HTTP API authenticated with the calling
// host's own Matrix access token. See README.md.
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

type config struct {
	synapseBase string // internal admin/client base, e.g. http://localhost:8008
	publicHS    string // public homeserver URL the guest browser connects to
	publicWeb   string // public web client base, e.g. https://call.tjena.eu
	adminToken  string // @callbot admin access token
	regSecret   string // registration_shared_secret
	ttl         time.Duration
	listen      string
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("missing required env %s", k)
	}
	return v
}

type call struct {
	roomID    string
	guestID   string
	createdAt time.Time
}

type server struct {
	cfg   config
	hc    *http.Client
	mu    sync.Mutex
	calls map[string]*call // roomID -> call
}

func main() {
	ttlMin := envOr("CALL_TTL_MINUTES", "30")
	var ttl time.Duration
	if _, err := fmt.Sscanf(ttlMin, "%d", new(int)); err == nil {
		var m int
		fmt.Sscanf(ttlMin, "%d", &m)
		ttl = time.Duration(m) * time.Minute
	} else {
		ttl = 30 * time.Minute
	}
	cfg := config{
		synapseBase: strings.TrimRight(mustEnv("SYNAPSE_BASE_URL"), "/"),
		publicHS:    strings.TrimRight(envOr("PUBLIC_HS_URL", mustEnv("SYNAPSE_BASE_URL")), "/"),
		publicWeb:   strings.TrimRight(mustEnv("PUBLIC_WEB_BASE"), "/"),
		adminToken:  mustEnv("ADMIN_TOKEN"),
		regSecret:   mustEnv("REGISTRATION_SHARED_SECRET"),
		ttl:         ttl,
		listen:      envOr("LISTEN_ADDR", ":8090"),
	}
	s := &server{
		cfg:   cfg,
		hc:    &http.Client{Timeout: 20 * time.Second},
		calls: map[string]*call{},
	}
	go s.sweepLoop()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/calls", s.handleCalls)       // POST
	mux.HandleFunc("/api/calls/", s.handleDeleteCall) // DELETE /api/calls/{roomId}
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("call-provisioner listening on %s (synapse=%s ttl=%s)", cfg.listen, cfg.synapseBase, cfg.ttl)
	log.Fatal(http.ListenAndServe(cfg.listen, mux))
}

// ---- HTTP handlers ----

func (s *server) handleCalls(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	// Auth: the caller proves identity with their own Matrix access token.
	hostToken := bearer(r)
	if hostToken == "" {
		http.Error(w, "missing bearer token", http.StatusUnauthorized)
		return
	}
	hostID, err := s.whoami(r.Context(), hostToken)
	if err != nil || hostID == "" {
		http.Error(w, "invalid token", http.StatusUnauthorized)
		return
	}

	guestID, guestToken, err := s.registerGuest(r.Context())
	if err != nil {
		log.Printf("registerGuest: %v", err)
		http.Error(w, "guest registration failed", http.StatusBadGateway)
		return
	}
	roomID, err := s.createRoom(r.Context(), hostID, guestID)
	if err != nil {
		log.Printf("createRoom: %v", err)
		http.Error(w, "room creation failed", http.StatusBadGateway)
		return
	}
	if err := s.forceJoin(r.Context(), roomID, hostID); err != nil {
		log.Printf("forceJoin host: %v", err)
		// non-fatal: host can still join via invite, but log it
	}

	s.mu.Lock()
	s.calls[roomID] = &call{roomID: roomID, guestID: guestID, createdAt: time.Now()}
	s.mu.Unlock()

	frag := url.Values{}
	frag.Set("hs", s.cfg.publicHS)
	frag.Set("room", roomID)
	frag.Set("user", guestID)
	frag.Set("token", guestToken)
	link := s.cfg.publicWeb + "/#" + frag.Encode()

	writeJSON(w, http.StatusOK, map[string]any{
		"callId":    roomID,
		"room":      roomID,
		"expiresAt": time.Now().Add(s.cfg.ttl).UTC().Format(time.RFC3339),
		"link":      link,
	})
}

func (s *server) handleDeleteCall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	roomID := strings.TrimPrefix(r.URL.Path, "/api/calls/")
	if roomID == "" {
		http.Error(w, "missing room id", http.StatusBadRequest)
		return
	}
	s.teardown(r.Context(), roomID)
	w.WriteHeader(http.StatusNoContent)
}

// ---- Synapse calls ----

func (s *server) whoami(ctx context.Context, token string) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		s.cfg.synapseBase+"/_matrix/client/v3/account/whoami", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	var out struct {
		UserID string `json:"user_id"`
	}
	if err := s.do(req, &out); err != nil {
		return "", err
	}
	return out.UserID, nil
}

func (s *server) registerGuest(ctx context.Context) (userID, token string, err error) {
	// 1. fetch nonce
	nreq, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		s.cfg.synapseBase+"/_synapse/admin/v1/register", nil)
	var nres struct {
		Nonce string `json:"nonce"`
	}
	if err = s.do(nreq, &nres); err != nil {
		return "", "", fmt.Errorf("nonce: %w", err)
	}
	username := "guest-" + randHex(10)
	password := randHex(24)
	// 2. mac = HMAC-SHA1(secret, nonce\0user\0password\0notadmin)
	mac := hmac.New(sha1.New, []byte(s.cfg.regSecret))
	mac.Write([]byte(nres.Nonce + "\x00" + username + "\x00" + password + "\x00notadmin"))
	body, _ := json.Marshal(map[string]any{
		"nonce":    nres.Nonce,
		"username": username,
		"password": password,
		"admin":    false,
		"mac":      hex.EncodeToString(mac.Sum(nil)),
	})
	rreq, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_synapse/admin/v1/register", bytes.NewReader(body))
	rreq.Header.Set("Content-Type", "application/json")
	var rres struct {
		UserID      string `json:"user_id"`
		AccessToken string `json:"access_token"`
	}
	if err = s.do(rreq, &rres); err != nil {
		return "", "", fmt.Errorf("register: %w", err)
	}
	return rres.UserID, rres.AccessToken, nil
}

func (s *server) createRoom(ctx context.Context, hostID, guestID string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"preset":    "trusted_private_chat",
		"is_direct": true,
		"invite":    []string{hostID, guestID},
		"initial_state": []map[string]any{
			{"type": "m.room.guest_access", "state_key": "",
				"content": map[string]any{"guest_access": "can_join"}},
			{"type": "m.room.history_visibility", "state_key": "",
				"content": map[string]any{"history_visibility": "joined"}},
		},
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_matrix/client/v3/createRoom", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
	req.Header.Set("Content-Type", "application/json")
	var out struct {
		RoomID string `json:"room_id"`
	}
	if err := s.do(req, &out); err != nil {
		return "", err
	}
	return out.RoomID, nil
}

func (s *server) forceJoin(ctx context.Context, roomID, userID string) error {
	body, _ := json.Marshal(map[string]any{"user_id": userID})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_synapse/admin/v1/join/"+url.PathEscape(roomID), bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
	req.Header.Set("Content-Type", "application/json")
	return s.do(req, nil)
}

func (s *server) teardown(ctx context.Context, roomID string) {
	s.mu.Lock()
	c := s.calls[roomID]
	delete(s.calls, roomID)
	s.mu.Unlock()
	if c != nil && c.guestID != "" {
		body, _ := json.Marshal(map[string]any{"erase": true})
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
			s.cfg.synapseBase+"/_synapse/admin/v1/deactivate/"+url.PathEscape(c.guestID), bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
		req.Header.Set("Content-Type", "application/json")
		if err := s.do(req, nil); err != nil {
			log.Printf("deactivate %s: %v", c.guestID, err)
		}
	}
	// Purge the room (async on Synapse side).
	body, _ := json.Marshal(map[string]any{"purge": true, "block": true})
	req, _ := http.NewRequestWithContext(ctx, http.MethodDelete,
		s.cfg.synapseBase+"/_synapse/admin/v2/rooms/"+url.PathEscape(roomID), bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
	req.Header.Set("Content-Type", "application/json")
	if err := s.do(req, nil); err != nil {
		log.Printf("purge %s: %v", roomID, err)
	}
}

func (s *server) sweepLoop() {
	t := time.NewTicker(5 * time.Minute)
	defer t.Stop()
	for range t.C {
		now := time.Now()
		s.mu.Lock()
		var expired []string
		for id, c := range s.calls {
			if now.Sub(c.createdAt) > s.cfg.ttl {
				expired = append(expired, id)
			}
		}
		s.mu.Unlock()
		for _, id := range expired {
			log.Printf("sweep: tearing down expired call %s", id)
			s.teardown(context.Background(), id)
		}
	}
}

// ---- helpers ----

func (s *server) do(req *http.Request, out any) error {
	res, err := s.hc.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return fmt.Errorf("%s %s -> %d: %s", req.Method, req.URL.Path, res.StatusCode, string(b))
	}
	if out != nil && len(b) > 0 {
		return json.Unmarshal(b, out)
	}
	return nil
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(strings.ToLower(h), "bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

func randHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}
