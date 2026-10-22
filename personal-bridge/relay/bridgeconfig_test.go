package main

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func exampleConfig(t *testing.T) []byte {
	// Use the real example config if the itest built the bridge, else a minimal one.
	if bin := "../itest/.work/bin/mautrix-whatsapp"; fileExists(bin) {
		dir := t.TempDir()
		if out, err := exec.Command(bin, "-e", "-c", dir+"/ex.yaml").CombinedOutput(); err == nil {
			data, _ := os.ReadFile(dir + "/ex.yaml")
			return data
		} else {
			t.Logf("could not run bridge: %v %s", err, out)
		}
	}
	return []byte("homeserver:\n  address: x\nappservice:\n  id: whatsapp\nencryption:\n  allow: false\nbridge:\n  permissions:\n    \"*\": relay\n")
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestGenerateBridgeConfig(t *testing.T) {
	b := Bundle{Slot: "wa07", AppserviceID: "tjena-wa07", Owner: "@nik:tjena.eu", ServerName: "tjena.eu",
		HomeserverURL: "https://wap.tjena.eu", ASToken: "astok", HSToken: "hstok", BotLocalpart: "wa07bot",
		UsernameTemplate: "wa07_{{.}}"}
	s := Settings{DataDir: "/data/bridge", RelayPort: 4242, ProvSecret: strings.Repeat("p", 32), PickleKey: strings.Repeat("k", 32),
		ExtraUsers: []string{"@friend:tjena.eu"}}
	out, err := generateBridgeConfig(exampleConfig(t), b, s)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err = yaml.Unmarshal(out, &cfg); err != nil {
		t.Fatal(err)
	}
	get := func(keys ...string) any {
		var cur any = cfg
		for _, k := range keys {
			cur = cur.(map[string]any)[k]
		}
		return cur
	}
	checks := map[string]any{
		"homeserver.address":                     "http://127.0.0.1:4242",
		"homeserver.domain":                      "tjena.eu",
		"homeserver.websocket":                   true,
		"appservice.id":                          "tjena-wa07",
		"appservice.as_token":                    "astok",
		"appservice.bot.username":                "wa07bot",
		"appservice.username_template":           "wa07_{{.}}",
		"encryption.require":                     true,
		"encryption.appservice":                  true,
		"encryption.msc4190":                     true,
		"encryption.self_sign":                   true,
		"encryption.delete_keys.delete_outbound_on_ack": false,
		"encryption.delete_keys.ratchet_on_decrypt":     true,
		"encryption.verification_levels.send":    "cross-signed-tofu",
		"bridge.relay.enabled":                   false,
		"provisioning.allow_matrix_auth":         false,
	}
	for path, want := range checks {
		if got := get(strings.Split(path, ".")...); got != want {
			t.Errorf("%s = %v, want %v", path, got, want)
		}
	}
	perms := get("bridge", "permissions").(map[string]any)
	if len(perms) != 2 || perms["@nik:tjena.eu"] != "admin" || perms["@friend:tjena.eu"] != "user" {
		t.Errorf("permissions = %v", perms)
	}
}

func TestRejectsWildcardsAndDomains(t *testing.T) {
	b := Bundle{Slot: "wa07", AppserviceID: "tjena-wa07", Owner: "@nik:tjena.eu", ServerName: "tjena.eu",
		HomeserverURL: "https://wap.tjena.eu", ASToken: "a", HSToken: "h", BotLocalpart: "wa07bot", UsernameTemplate: "wa07_{{.}}"}
	for _, bad := range []string{"*", "tjena.eu", "@*:tjena.eu", "@nik:tjena.eu"} {
		s := Settings{DataDir: "/d", RelayPort: 1, ProvSecret: strings.Repeat("p", 32), PickleKey: strings.Repeat("k", 32), ExtraUsers: []string{bad}}
		if _, err := generateBridgeConfig(exampleConfig(t), b, s); err == nil {
			t.Errorf("extra user %q should be rejected", bad)
		}
	}
}
