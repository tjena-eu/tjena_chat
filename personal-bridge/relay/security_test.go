package main

import (
	"crypto/rand"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.mau.fi/libsignal/ecc"
	"golang.org/x/crypto/curve25519"
)

func TestSplitJID(t *testing.T) {
	for in, want := range map[string]struct {
		phone string
		dev   int
	}{
		"491701234567:12@s.whatsapp.net":  {"+491701234567", 12},
		"491701234567@s.whatsapp.net":     {"+491701234567", 0},
		"491701234567.0:3@s.whatsapp.net": {"+491701234567", 3},
	} {
		p, d := splitJID(in)
		if p != want.phone || d != want.dev {
			t.Errorf("%s: got %s %d", in, p, d)
		}
	}
}

func TestVerifyWAAccountSignature(t *testing.T) {
	var accPriv, devPriv [32]byte
	_, _ = rand.Read(accPriv[:])
	_, _ = rand.Read(devPriv[:])
	accPub, _ := curve25519.X25519(accPriv[:], curve25519.Basepoint)
	devPub, _ := curve25519.X25519(devPriv[:], curve25519.Basepoint)
	details := []byte("adv-details")
	msg := append(append([]byte{6, 0}, details...), devPub...)
	sig := ecc.CalculateSignature(ecc.NewDjbECPrivateKey(accPriv), msg)
	if !verifyWAAccountSignature(details, devPub, sig[:], accPub) {
		t.Fatal("valid signature rejected")
	}
	if verifyWAAccountSignature([]byte("other"), devPub, sig[:], accPub) {
		t.Fatal("signature over other details accepted")
	}
	if verifyWAAccountSignature(details, accPub, sig[:], accPub) {
		t.Fatal("signature for other identity accepted")
	}
}

func TestObserveKeyUploads(t *testing.T) {
	dir := t.TempDir()
	keys := filepath.Join(dir, "keys.json")
	r := &Relay{cfg: Config{KeysFile: keys}, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	var got []string
	h := r.observeKeyUploads(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		b, _ := io.ReadAll(req.Body)
		got = append(got, string(b))
	}))
	post := func(path, body string) {
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", path, strings.NewReader(body)))
	}
	dev := `{"device_keys":{"user_id":"@b:x","device_id":"DEV1","keys":{"ed25519:DEV1":"EDKEY","curve25519:DEV1":"CVKEY"}}}`
	post("/_matrix/client/v3/keys/upload", dev)
	post("/_matrix/client/v3/keys/device_signing/upload",
		`{"master_key":{"keys":{"ed25519:MK":"MK"}},"self_signing_key":{"keys":{"ed25519:SSK":"SSK"}}}`)
	post("/_matrix/client/v3/keys/upload", `{"one_time_keys":{}}`) // must not reset anything
	if len(got) != 3 || got[0] != dev {
		t.Fatalf("bodies not passed through unchanged: %q", got)
	}
	var obs ObservedKeys
	data, _ := os.ReadFile(keys)
	_ = json.Unmarshal(data, &obs)
	want := ObservedKeys{DeviceID: "DEV1", Ed25519: "EDKEY", Curve25519: "CVKEY", MasterKey: "MK", SelfSigningKey: "SSK"}
	if obs != want {
		t.Fatalf("got %+v", obs)
	}
	// A new device (fresh database) drops the old cross-signing keys.
	post("/_matrix/client/v3/keys/upload", strings.ReplaceAll(dev, "DEV1", "DEV2"))
	data, _ = os.ReadFile(keys)
	obs = ObservedKeys{}
	_ = json.Unmarshal(data, &obs)
	if obs.DeviceID != "DEV2" || obs.MasterKey != "" {
		t.Fatalf("after new device: %+v", obs)
	}
}
