package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func wsDial(t *testing.T, base, path, token string) (*websocket.Conn, *http.Response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return websocket.Dial(ctx, strings.Replace(base, "http://", "ws://", 1)+path, &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
	})
}

func readMsg(t *testing.T, ws *websocket.Conn) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := ws.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var m map[string]any
	_ = json.Unmarshal(data, &m)
	return m
}

func writeMsg(t *testing.T, ws *websocket.Conn, m map[string]any) {
	t.Helper()
	data, _ := json.Marshal(m)
	if err := ws.Write(context.Background(), websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func TestCallSignalling(t *testing.T) {
	g, _, pub, _ := setup(t)
	code, data := do(t, "POST", pub.URL+"/provision/v1/bridge", "alice-token", "")
	if code != 200 {
		t.Fatalf("claim: %d %s", code, data)
	}
	var b BridgeBundle
	_ = json.Unmarshal(data, &b)

	// Unknown tokens and users without a bridge are refused.
	if _, resp, err := wsDial(t, pub.URL, "/_tjena/call/v1/phone", "garbage"); err == nil || resp.StatusCode != 401 {
		t.Fatal("phone with bad token accepted")
	}
	if _, resp, err := wsDial(t, pub.URL, "/_tjena/call/v1/app", "bob-token"); err == nil || resp.StatusCode != 404 {
		t.Fatal("user without a bridge accepted")
	}
	if _, resp, err := wsDial(t, pub.URL, "/_tjena/call/v1/app", "ghost-token"); err == nil || resp.StatusCode != 401 {
		t.Fatal("bridge ghost accepted as app")
	}

	app, _, err := wsDial(t, pub.URL, "/_tjena/call/v1/app", "alice-token")
	if err != nil {
		t.Fatal(err)
	}
	defer app.CloseNow()
	if m := readMsg(t, app); m["type"] != "phone" || m["online"] != false {
		t.Fatalf("expected phone offline notice, got %v", m)
	}

	phone, _, err := wsDial(t, pub.URL, "/_tjena/call/v1/phone", b.ASToken)
	if err != nil {
		t.Fatal(err)
	}
	defer phone.CloseNow()
	if m := readMsg(t, app); m["type"] != "phone" || m["online"] != true {
		t.Fatalf("expected phone online notice, got %v", m)
	}

	// App → phone: "from" is set by the gateway, spoofing is overwritten.
	writeMsg(t, app, map[string]any{"type": "call", "id": "c1", "from": "evil", "to": "x", "sdp": "v=0"})
	m := readMsg(t, phone)
	if m["type"] != "call" || m["from"] == "evil" || m["from"] == nil || m["to"] != nil || m["sdp"] != "v=0" {
		t.Fatalf("phone got %v", m)
	}
	appID := m["from"].(string)

	// A second app of the same owner.
	app2, _, err := wsDial(t, pub.URL, "/_tjena/call/v1/app", "alice-token")
	if err != nil {
		t.Fatal(err)
	}
	defer app2.CloseNow()
	readMsg(t, app2) // online notice

	// Phone → one app with "to"; the other doesn't get it.
	writeMsg(t, phone, map[string]any{"type": "sdp", "to": appID, "id": "c1", "sdp": "answer"})
	if m = readMsg(t, app); m["type"] != "sdp" || m["to"] != nil {
		t.Fatalf("app got %v", m)
	}
	// Broadcast reaches both.
	writeMsg(t, phone, map[string]any{"type": "incoming", "call": map[string]any{"wa_call_id": "w1"}})
	if m = readMsg(t, app); m["type"] != "incoming" {
		t.Fatalf("app got %v", m)
	}
	if m = readMsg(t, app2); m["type"] != "incoming" {
		t.Fatalf("app2 got %v (should not have received the addressed sdp)", m)
	}

	// App leaves: phone is told.
	app2.Close(websocket.StatusNormalClosure, "")
	if m = readMsg(t, phone); m["type"] != "app_gone" {
		t.Fatalf("phone got %v", m)
	}

	// Revoking the bridge cuts the phone off.
	if code, data = do(t, "DELETE", pub.URL+"/provision/v1/bridge", "alice-token", ""); code != 200 {
		t.Fatalf("revoke: %d %s", code, data)
	}
	writeMsg(t, phone, map[string]any{"type": "status"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err = phone.Read(ctx); err != nil {
			break
		}
	}
	if ctx.Err() != nil {
		t.Fatal("phone still connected after revoke")
	}
	_ = g
}
