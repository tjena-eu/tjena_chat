// Command call-provisioner backs the "call a WhatsApp contact via a web link"
// feature. It reuses ONE persistent guest user and ONE persistent call room per
// host (looked up by room alias), so repeated calls don't create trash users or
// clutter the host's room list. It holds a @callbot admin token + the
// registration shared secret, and authenticates each request with the calling
// host's own Matrix access token. See README.md.
package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"time"
)

type config struct {
	synapseBase string // internal admin/client base, e.g. http://localhost:8008
	publicHS    string // public homeserver URL the guest browser connects to
	publicWeb   string // public web client base, e.g. https://call.tjena.eu
	adminToken  string // @callbot admin access token
	regSecret   string // registration_shared_secret
	guestUser   string // localpart of the single reused guest user
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

type server struct {
	cfg config
	hc  *http.Client
}

const guestDeviceID = "tjena-call-web" // fixed device so the guest has one device

func main() {
	cfg := config{
		synapseBase: strings.TrimRight(mustEnv("SYNAPSE_BASE_URL"), "/"),
		publicHS:    strings.TrimRight(envOr("PUBLIC_HS_URL", mustEnv("SYNAPSE_BASE_URL")), "/"),
		publicWeb:   strings.TrimRight(mustEnv("PUBLIC_WEB_BASE"), "/"),
		adminToken:  mustEnv("ADMIN_TOKEN"),
		regSecret:   mustEnv("REGISTRATION_SHARED_SECRET"),
		guestUser:   envOr("GUEST_USERNAME", "tjenacall-guest"),
		listen:      envOr("LISTEN_ADDR", ":8090"),
	}
	s := &server{cfg: cfg, hc: &http.Client{Timeout: 20 * time.Second}}

	mux := http.NewServeMux()
	mux.HandleFunc("/api/calls", s.handleCalls) // POST
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("call-provisioner listening on %s (synapse=%s guest=%s)",
		cfg.listen, cfg.synapseBase, cfg.guestUser)
	log.Fatal(http.ListenAndServe(cfg.listen, mux))
}

// ---- HTTP handler ----

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

	// Reuse this host's own guest user (refreshing its token) and the host's
	// single call room (found by alias, created on first use). Both are derived
	// per-host so multiple users on the server stay isolated.
	guestID, guestToken, err := s.ensureGuest(r.Context(), hostID)
	if err != nil {
		log.Printf("ensureGuest: %v", err)
		http.Error(w, "guest setup failed", http.StatusBadGateway)
		return
	}
	roomID, err := s.ensureRoom(r.Context(), hostID, guestID)
	if err != nil {
		log.Printf("ensureRoom: %v", err)
		http.Error(w, "room setup failed", http.StatusBadGateway)
		return
	}

	frag := url.Values{}
	frag.Set("hs", s.cfg.publicHS)
	frag.Set("room", roomID)
	frag.Set("user", guestID)
	frag.Set("token", guestToken)
	frag.Set("device", guestDeviceID)
	link := s.cfg.publicWeb + "/#" + frag.Encode()

	writeJSON(w, http.StatusOK, map[string]any{
		"callId": roomID,
		"room":   roomID,
		"link":   link,
	})
}

// ---- Synapse: identity ----

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

// ---- Synapse: the single reused guest ----

// ensureGuest logs in as THIS host's persistent guest (registering it the first
// time), returning its user id and a fresh access token. The guest is per-host
// so concurrent callers on the same server never share an identity or token.
// A fixed device id keeps each guest to one device; re-login refreshes the token.
func (s *server) ensureGuest(ctx context.Context, hostID string) (userID, token string, err error) {
	user := s.guestUsername(hostID)
	password := guestPassword(s.cfg.regSecret, user)
	userID, token, err = s.login(ctx, user, password)
	if err == nil {
		return userID, token, nil
	}
	// First run for this host (or password mismatch): register, then log in.
	if rerr := s.registerUser(ctx, user, password); rerr != nil {
		return "", "", fmt.Errorf("register guest: %w (login also failed: %v)", rerr, err)
	}
	return s.login(ctx, user, password)
}

// guestUsername derives a per-host guest localpart (e.g. tjenacall-guest-niklas)
// so each host has its own guest and they never collide.
func (s *server) guestUsername(hostID string) string {
	local := aliasSanitize.ReplaceAllString(strings.ToLower(localpart(hostID)), "-")
	return s.cfg.guestUser + "-" + local
}

// guestPassword deterministically derives a guest's password from the
// registration shared secret + username, so we never need to store it.
func guestPassword(secret, user string) string {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte("tjena-call-guest:" + user))
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *server) login(ctx context.Context, user, password string) (userID, token string, err error) {
	body, _ := json.Marshal(map[string]any{
		"type":                        "m.login.password",
		"identifier":                  map[string]any{"type": "m.id.user", "user": user},
		"password":                    password,
		"device_id":                   guestDeviceID,
		"initial_device_display_name": "Tjena Call (web)",
	})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_matrix/client/v3/login", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	var out struct {
		UserID      string `json:"user_id"`
		AccessToken string `json:"access_token"`
	}
	if err := s.do(req, &out); err != nil {
		return "", "", err
	}
	return out.UserID, out.AccessToken, nil
}

func (s *server) registerUser(ctx context.Context, user, password string) error {
	nreq, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		s.cfg.synapseBase+"/_synapse/admin/v1/register", nil)
	var nres struct {
		Nonce string `json:"nonce"`
	}
	if err := s.do(nreq, &nres); err != nil {
		return fmt.Errorf("nonce: %w", err)
	}
	mac := hmac.New(sha1.New, []byte(s.cfg.regSecret))
	mac.Write([]byte(nres.Nonce + "\x00" + user + "\x00" + password + "\x00notadmin"))
	body, _ := json.Marshal(map[string]any{
		"nonce":    nres.Nonce,
		"username": user,
		"password": password,
		"admin":    false,
		"mac":      hex.EncodeToString(mac.Sum(nil)),
	})
	rreq, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_synapse/admin/v1/register", bytes.NewReader(body))
	rreq.Header.Set("Content-Type", "application/json")
	return s.do(rreq, nil)
}

// ---- Synapse: the single reused room (per host, via alias) ----

var aliasSanitize = regexp.MustCompile(`[^a-z0-9._-]+`)

func (s *server) ensureRoom(ctx context.Context, hostID, guestID string) (string, error) {
	local := aliasSanitize.ReplaceAllString(strings.ToLower(localpart(hostID)), "-")
	aliasLocal := "tjenacall-" + local
	alias := "#" + aliasLocal + ":" + serverName(hostID)

	// Reuse the existing room if the alias resolves.
	if roomID, err := s.resolveAlias(ctx, alias); err == nil && roomID != "" {
		// Make sure both parties are (re-)invited in case someone left.
		s.invite(ctx, roomID, hostID)
		s.invite(ctx, roomID, guestID)
		return roomID, nil
	}
	// First call for this host: create the room with the canonical alias.
	return s.createRoom(ctx, aliasLocal, hostID, guestID)
}

func (s *server) resolveAlias(ctx context.Context, alias string) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet,
		s.cfg.synapseBase+"/_matrix/client/v3/directory/room/"+url.PathEscape(alias), nil)
	req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
	var out struct {
		RoomID string `json:"room_id"`
	}
	if err := s.do(req, &out); err != nil {
		return "", err
	}
	return out.RoomID, nil
}

func (s *server) createRoom(ctx context.Context, aliasLocal, hostID, guestID string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"name":            "Tjena Call",
		"room_alias_name": aliasLocal,
		"preset":          "trusted_private_chat",
		"invite":          []string{hostID, guestID},
		"initial_state": []map[string]any{
			{"type": "m.room.guest_access", "state_key": "",
				"content": map[string]any{"guest_access": "can_join"}},
			{"type": "m.room.history_visibility", "state_key": "",
				"content": map[string]any{"history_visibility": "shared"}},
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

// invite (re-)invites a user as @callbot; ignores "already in the room" errors.
func (s *server) invite(ctx context.Context, roomID, userID string) {
	body, _ := json.Marshal(map[string]any{"user_id": userID})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost,
		s.cfg.synapseBase+"/_matrix/client/v3/rooms/"+url.PathEscape(roomID)+"/invite",
		bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+s.cfg.adminToken)
	req.Header.Set("Content-Type", "application/json")
	if err := s.do(req, nil); err != nil &&
		!strings.Contains(err.Error(), "already in the room") &&
		!strings.Contains(err.Error(), "already joined") {
		log.Printf("invite %s -> %s: %v", userID, roomID, err)
	}
}

// ---- helpers ----

func localpart(userID string) string {
	u := strings.TrimPrefix(userID, "@")
	if i := strings.IndexByte(u, ':'); i >= 0 {
		return u[:i]
	}
	return u
}

func serverName(userID string) string {
	if i := strings.IndexByte(userID, ':'); i >= 0 {
		return userID[i+1:]
	}
	return ""
}

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

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	// Don't HTML-escape: the call link's "&" separators would otherwise become
	// "&", which breaks the URL if copied from raw output.
	enc.SetEscapeHTML(false)
	enc.Encode(v)
}
