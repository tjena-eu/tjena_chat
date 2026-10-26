package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"maunium.net/go/mautrix/appservice"
	"maunium.net/go/mautrix/event"
)

// fakeSynapse knows the slots' real as_tokens and one normal user token.
type fakeSynapse struct {
	mu        sync.Mutex
	realAS    map[string]string // token -> bot mxid
	lastAuth  string
	pinged    []string
	userToken map[string]string
}

func (f *fakeSynapse) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	switch {
	case r.URL.Path == "/_matrix/client/v3/account/whoami":
		if mx, ok := f.realAS[tok]; ok {
			writeJSON(w, 200, map[string]string{"user_id": mx})
		} else if mx, ok := f.userToken[tok]; ok {
			writeJSON(w, 200, map[string]string{"user_id": mx})
		} else {
			writeError(w, 401, "M_UNKNOWN_TOKEN", "nope")
		}
	case strings.HasPrefix(r.URL.Path, "/_matrix/client/v1/appservice/"):
		f.pinged = append(f.pinged, r.URL.Path)
		writeJSON(w, 200, map[string]any{"duration_ms": 1})
	case r.URL.Path == "/health":
		_, _ = w.Write([]byte("OK"))
	case r.URL.Path == "/_matrix/client/v3/echo":
		f.lastAuth = tok
		writeJSON(w, 200, map[string]string{"ok": "1"})
	default:
		writeError(w, 404, "M_UNRECOGNIZED", "")
	}
}

func setup(t *testing.T) (*Gateway, *fakeSynapse, *httptest.Server, *httptest.Server) {
	fs := &fakeSynapse{realAS: map[string]string{}, userToken: map[string]string{
		"alice-token": "@alice:example.com", "bob-token": "@bob:example.com", "ghost-token": "@wa01_123:example.com",
	}}
	syn := httptest.NewServer(fs)
	t.Cleanup(syn.Close)
	dir := t.TempDir()
	cfg := &Config{ServerName: "example.com", SynapseURL: syn.URL, PublicURL: "https://wap.example.com",
		InternalURL: "http://gateway:29332", DataDir: dir, RegistrationDir: dir + "/reg", SlotPrefix: "wa",
		ReservedPrefixes: []string{"whatsapp"}, ClaimRateLimit: 3, MaxSlotsPerUser: 1, TransactionTimeout: 5, KeepaliveInterval: 30}
	g, err := newGateway(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	slots, err := g.addSlots(2)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range slots {
		fs.realAS[s.ASToken] = "@" + s.BotLocalpart() + ":example.com"
	}
	g.checkActivation(context.Background())
	pub := httptest.NewServer(g.publicRoutes())
	internal := httptest.NewServer(g.internalRoutes())
	t.Cleanup(pub.Close)
	t.Cleanup(internal.Close)
	return g, fs, pub, internal
}

func do(t *testing.T, method, u, token, body string) (int, []byte) {
	req, _ := http.NewRequest(method, u, strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, data
}

func connectBridge(t *testing.T, pubURL string, b BridgeBundle) (*appservice.AppService, context.CancelFunc, chan error) {
	as := appservice.Create()
	as.Registration = &appservice.Registration{ID: b.AppserviceID, AppToken: b.ASToken, ServerToken: b.HSToken,
		SenderLocalpart: b.BotLocalpart, EphemeralEvents: true}
	as.HomeserverDomain = "example.com"
	if err := as.SetHomeserverURL(pubURL); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	connected := make(chan struct{})
	done := make(chan error, 1)
	go func() { done <- as.StartWebsocket(ctx, "", func() { close(connected) }) }()
	select {
	case <-connected:
	case err := <-done:
		t.Fatalf("bridge could not connect: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("bridge did not connect")
	}
	time.Sleep(100 * time.Millisecond)
	return as, cancel, done
}

func TestGatewayEndToEnd(t *testing.T) {
	g, fs, pub, internal := setup(t)
	s1, _ := g.slot("wa01")
	if !s1.Active || s1.State != SlotFree {
		t.Fatalf("slot wa01 should be active and free: %+v", s1)
	}
	if !strings.Contains(registrationYAML(g.cfg, &s1), `'^@wa01_.*:example\.com$'`) {
		t.Fatal("registration namespace wrong")
	}

	// Bridge users and unknown tokens can't claim.
	if code, _ := do(t, "POST", pub.URL+"/provision/v1/bridge", "ghost-token", ""); code != 401 {
		t.Fatalf("ghost user claim: expected 401, got %d", code)
	}
	if code, _ := do(t, "POST", pub.URL+"/provision/v1/bridge", "garbage", ""); code != 401 {
		t.Fatalf("bad token claim: expected 401, got %d", code)
	}

	// Alice claims a bridge.
	code, data := do(t, "POST", pub.URL+"/provision/v1/bridge", "alice-token", "")
	if code != 200 {
		t.Fatalf("claim: %d %s", code, data)
	}
	var b BridgeBundle
	_ = json.Unmarshal(data, &b)
	if b.Slot != "wa01" || b.Owner != "@alice:example.com" || b.BotMXID != "@wa01bot:example.com" || b.UsernameTemplate != "wa01_{{.}}" {
		t.Fatalf("unexpected bundle %+v", b)
	}
	if b.ASToken == s1.ASToken || b.HSToken == s1.HSToken {
		t.Fatal("bundle must not contain the real tokens")
	}

	// Synapse -> gateway while the bridge is offline: 502 so Synapse retries.
	if code, _ := do(t, "PUT", internal.URL+"/_matrix/app/v1/transactions/0", s1.HSToken, `{"events":[]}`); code != 502 {
		t.Fatalf("offline transaction: expected 502, got %d", code)
	}

	as, cancel, done := connectBridge(t, pub.URL, b)
	defer cancel()

	// Transaction with to_device + fallback keys arrives intact.
	body := `{"events":[{"type":"m.room.message","room_id":"!r:example.com","event_id":"$e","sender":"@alice:example.com","content":{"body":"hi","msgtype":"m.text"}}],
	 "de.sorunome.msc2409.to_device":[{"type":"m.room.encrypted","sender":"@alice:example.com","to_user_id":"@wa01bot:example.com","to_device_id":"DEV","content":{"algorithm":"m.olm.v1.curve25519-aes-sha2"}}],
	 "org.matrix.msc3202.device_unused_fallback_key_types":{"@wa01bot:example.com":{"DEV":["signed_curve25519"]}}}`
	if code, data := do(t, "PUT", internal.URL+"/_matrix/app/v1/transactions/1", s1.HSToken, body); code != 200 {
		t.Fatalf("transaction: %d %s", code, data)
	}
	expectEvent(t, as.Events, "m.room.message")
	expectEvent(t, as.ToDeviceEvents, "m.room.encrypted")

	// Synapse pinged on connect (flushes its queue).
	time.Sleep(2500 * time.Millisecond)
	fs.mu.Lock()
	if len(fs.pinged) == 0 || !strings.HasSuffix(fs.pinged[0], "/tjena-wa01/ping") {
		t.Fatalf("expected synapse ping for tjena-wa01, got %v", fs.pinged)
	}
	fs.mu.Unlock()

	// Synapse -> bridge ping via http_proxy: bridge checks its own hs_token,
	// so the gateway must have swapped it.
	if code, data := do(t, "POST", internal.URL+"/_matrix/app/v1/ping", s1.HSToken, `{"transaction_id":"x"}`); code != 200 {
		t.Fatalf("ping via http_proxy: %d %s", code, data)
	}

	// Client API: bridge token is swapped for the real as_token.
	do(t, "GET", pub.URL+"/_matrix/client/v3/echo", b.ASToken, "")
	fs.mu.Lock()
	if fs.lastAuth != s1.ASToken {
		t.Fatalf("token not swapped: synapse saw %q", fs.lastAuth)
	}
	fs.mu.Unlock()
	// Other tokens pass through unchanged.
	do(t, "GET", pub.URL+"/_matrix/client/v3/echo", "alice-token", "")
	fs.mu.Lock()
	if fs.lastAuth != "alice-token" {
		t.Fatalf("user token altered: %q", fs.lastAuth)
	}
	fs.mu.Unlock()

	// Status for the owner.
	code, data = do(t, "GET", pub.URL+"/provision/v1/bridge", "alice-token", "")
	if code != 200 || !strings.Contains(string(data), `"connected":true`) {
		t.Fatalf("status: %d %s", code, data)
	}
	if code, _ := do(t, "GET", pub.URL+"/provision/v1/bridge", "bob-token", ""); code != 404 {
		t.Fatalf("bob has no bridge, expected 404, got %d", code)
	}

	// Reclaim (e.g. reinstalled app): same slot, new tokens, old bridge cut off.
	code, data = do(t, "POST", pub.URL+"/provision/v1/bridge", "alice-token", "")
	var b2 BridgeBundle
	_ = json.Unmarshal(data, &b2)
	if code != 200 || b2.Slot != "wa01" || b2.ASToken == b.ASToken {
		t.Fatalf("reclaim: %d %+v", code, b2)
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("old bridge websocket was not closed after reclaim")
	}
	do(t, "GET", pub.URL+"/_matrix/client/v3/echo", b.ASToken, "")
	fs.mu.Lock()
	if fs.lastAuth == s1.ASToken {
		t.Fatal("old bridge token still swapped after reclaim")
	}
	fs.mu.Unlock()

	// Rate limit: alice has used 2 of 3 claims this hour.
	do(t, "POST", pub.URL+"/provision/v1/bridge", "alice-token", "")
	if code, _ := do(t, "POST", pub.URL+"/provision/v1/bridge", "alice-token", ""); code != 429 {
		t.Fatalf("expected rate limit 429, got %d", code)
	}

	// Revoke: slot burned, tokens dead, Synapse traffic accepted and dropped.
	if code, data := do(t, "DELETE", pub.URL+"/provision/v1/bridge", "alice-token", ""); code != 200 {
		t.Fatalf("revoke: %d %s", code, data)
	}
	s1, _ = g.slot("wa01")
	if s1.State != SlotBurned {
		t.Fatalf("slot not burned: %s", s1.State)
	}
	if code, _ := do(t, "PUT", internal.URL+"/_matrix/app/v1/transactions/2", s1.HSToken, `{"events":[]}`); code != 200 {
		t.Fatalf("burned slot transaction should be dropped with 200, got %d", code)
	}
	if code, _ := do(t, "GET", pub.URL+"/_matrix/client/unstable/fi.mau.as_sync", b2.ASToken, ""); code != 401 {
		t.Fatalf("websocket with revoked token: expected 401, got %d", code)
	}

	// Bob gets the next slot; the burned one is never reused.
	code, data = do(t, "POST", pub.URL+"/provision/v1/bridge", "bob-token", "")
	var bb BridgeBundle
	_ = json.Unmarshal(data, &bb)
	if code != 200 || bb.Slot != "wa02" {
		t.Fatalf("bob claim: %d %s", code, data)
	}
	// Pool exhausted.
	fs.userToken["carol-token"] = "@carol:example.com"
	if code, _ := do(t, "POST", pub.URL+"/provision/v1/bridge", "carol-token", ""); code != 503 {
		t.Fatalf("expected 503 when no slots left, got %d", code)
	}

	// Audit log has the events, without tokens.
	audit, err := os.ReadFile(g.cfg.DataDir + "/audit.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"action":"claim"`, `"action":"reclaim"`, `"action":"revoke"`, `"action":"slots_add"`} {
		if !strings.Contains(string(audit), want) {
			t.Fatalf("audit log missing %s:\n%s", want, audit)
		}
	}
	if strings.Contains(string(audit), b.ASToken) || strings.Contains(string(audit), s1.ASToken) {
		t.Fatal("audit log contains a token")
	}
}

func TestStatePersistsAcrossRestart(t *testing.T) {
	g, _, _, _ := setup(t)
	if _, _, err := g.claim("@alice:example.com", "admin"); err != nil {
		t.Fatal(err)
	}
	g2, err := newGateway(g.cfg, g.log)
	if err != nil {
		t.Fatal(err)
	}
	s, _ := g2.slot("wa01")
	if s.Owner != "@alice:example.com" || s.State != SlotAssigned || !s.Active {
		t.Fatalf("state not persisted: %+v", s)
	}
	if g2.adminToken != g.adminToken {
		t.Fatal("admin token not persisted")
	}
}

func expectEvent(t *testing.T, ch chan *event.Event, typ string) {
	select {
	case evt := <-ch:
		if evt.Type.Type != typ {
			t.Fatalf("expected %s, got %s", typ, evt.Type.Type)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("did not receive %s", typ)
	}
}
