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
		"homeserver.address":                            "http://127.0.0.1:4242",
		"homeserver.domain":                             "tjena.eu",
		"homeserver.websocket":                          true,
		"appservice.id":                                 "tjena-wa07",
		"appservice.as_token":                           "astok",
		"appservice.bot.username":                       "wa07bot",
		"appservice.username_template":                  "wa07_{{.}}",
		"encryption.require":                            true,
		"encryption.appservice":                         true,
		"encryption.msc4190":                            true,
		"encryption.self_sign":                          true,
		"encryption.delete_keys.delete_outbound_on_ack": false,
		"encryption.delete_keys.ratchet_on_decrypt":     true,
		"encryption.verification_levels.send":           "cross-signed-tofu",
		"bridge.relay.enabled":                          false,
		"provisioning.allow_matrix_auth":                false,
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

func TestBridgeConfigOptions(t *testing.T) {
	b := Bundle{Slot: "wa07", AppserviceID: "tjena-wa07", Owner: "@nik:tjena.eu", ServerName: "tjena.eu",
		HomeserverURL: "https://wap.tjena.eu", ASToken: "astok", HSToken: "hstok", BotLocalpart: "wa07bot",
		UsernameTemplate: "wa07_{{.}}"}
	base := Settings{DataDir: "/d", RelayPort: 1, ProvSecret: strings.Repeat("p", 32), PickleKey: strings.Repeat("k", 32)}
	gen := func(o Options) map[string]any {
		t.Helper()
		s := base
		s.Options = o
		out, err := generateBridgeConfig(exampleConfig(t), b, s)
		if err != nil {
			t.Fatal(err)
		}
		var cfg map[string]any
		if err = yaml.Unmarshal(out, &cfg); err != nil {
			t.Fatal(err)
		}
		return cfg
	}
	get := func(cfg map[string]any, keys ...string) any {
		var cur any = cfg
		for _, k := range keys {
			cur = cur.(map[string]any)[k]
		}
		return cur
	}

	// Defaults: backfill on with limits, status updates off.
	cfg := gen(Options{})
	for path, want := range map[string]any{
		"backfill.enabled":                                 true,
		"backfill.max_initial_messages":                    50,
		"network.history_sync.max_initial_conversations":   25,
		"network.history_sync.request_full_sync":           false,
		"network.history_sync.dispatch_wait":               "5m",
		"network.enable_status_broadcast":                  false,
		"network.disable_status_broadcast_send":            true,
		"network.displayname_template":                     displaynameTemplate,
		"backfill.queue.enabled":                           false,
		"bridge.cleanup_on_logout.enabled":                 true,
		"bridge.cleanup_on_logout.manual.private":          "delete",
		"bridge.cleanup_on_logout.bad_credentials.private": "nothing",
	} {
		if got := get(cfg, strings.Split(path, ".")...); got != want {
			t.Errorf("default %s = %v, want %v", path, got, want)
		}
	}

	cfg = gen(Options{
		Backfill: &BackfillOptions{Enabled: true, MaxInitialMessages: 1000, MaxCatchupMessages: 99999,
			MaxInitialConversations: -1, RequestFullSync: true, FullSyncDays: 365},
		StatusBroadcast: "on",
	})
	for path, want := range map[string]any{
		"backfill.max_initial_messages":                    1000,
		"backfill.max_catchup_messages":                    10000, // clamped
		"network.history_sync.max_initial_conversations":   -1,
		"network.history_sync.request_full_sync":           true,
		"network.history_sync.full_sync_config.days_limit": 365,
		"network.history_sync.dispatch_wait":               "10m",
		"network.enable_status_broadcast":                  true,
		"network.mute_status_broadcast":                    false,
	} {
		if got := get(cfg, strings.Split(path, ".")...); got != want {
			t.Errorf("custom %s = %v, want %v", path, got, want)
		}
	}
	if tag := get(cfg, "network", "status_broadcast_tag"); tag != nil {
		t.Errorf("unmuted status room still tagged %v", tag)
	}

	cfg = gen(Options{StatusBroadcast: "muted", Backfill: &BackfillOptions{Enabled: false}})
	if get(cfg, "network", "status_broadcast_tag") != "m.lowpriority" || get(cfg, "backfill", "enabled") != false {
		t.Error("muted/backfill-off not applied")
	}

	keep := false
	cfg = gen(Options{DeleteChatsOnLogout: &keep})
	if get(cfg, "bridge", "cleanup_on_logout", "manual", "private") != "nothing" {
		t.Error("keep chats on logout not applied")
	}

	s := base
	s.Options = Options{StatusBroadcast: "loud"}
	if _, err := generateBridgeConfig(exampleConfig(t), b, s); err == nil {
		t.Error("invalid status_broadcast accepted")
	}
}
