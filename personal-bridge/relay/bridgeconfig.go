package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// Bundle is what the gateway's provisioner returns (see gateway BridgeBundle).
type Bundle struct {
	Slot             string `json:"slot"`
	AppserviceID     string `json:"appservice_id"`
	Owner            string `json:"owner"`
	ServerName       string `json:"server_name"`
	HomeserverURL    string `json:"homeserver_url"`
	WebsocketURL     string `json:"websocket_url"`
	ASToken          string `json:"as_token"`
	HSToken          string `json:"hs_token"`
	BotLocalpart     string `json:"bot_localpart"`
	BotMXID          string `json:"bot_mxid"`
	UsernameTemplate string `json:"username_template"`
}

// Settings are the phone-local choices.
type Settings struct {
	DataDir    string   `json:"data_dir"`    // bridge.db and logs live here
	RelayPort  int      `json:"relay_port"`  // 127.0.0.1 port of this relay
	ProvSecret string   `json:"prov_secret"` // provisioning shared secret (>= 32 chars)
	PickleKey  string   `json:"pickle_key"`  // encryption pickle key (kept in Android Keystore)
	ExtraUsers []string `json:"extra_users"` // other MXIDs with "user" permission
	LogLevel   string   `json:"log_level"`   // default "info" (no message content)
}

var mxidRe = regexp.MustCompile(`^@[a-z0-9._=/+-]+:[a-zA-Z0-9.-]+(:\d+)?$`)

func (b *Bundle) validate() error {
	for name, v := range map[string]string{"slot": b.Slot, "appservice_id": b.AppserviceID, "owner": b.Owner,
		"server_name": b.ServerName, "homeserver_url": b.HomeserverURL, "as_token": b.ASToken,
		"hs_token": b.HSToken, "bot_localpart": b.BotLocalpart, "username_template": b.UsernameTemplate} {
		if v == "" {
			return fmt.Errorf("bundle: %s missing", name)
		}
	}
	if !mxidRe.MatchString(b.Owner) {
		return fmt.Errorf("bundle: invalid owner %q", b.Owner)
	}
	if !strings.Contains(b.UsernameTemplate, "{{.}}") {
		return errors.New("bundle: username_template must contain {{.}}")
	}
	return nil
}

func (s *Settings) validate(owner string) error {
	if s.DataDir == "" || s.RelayPort <= 0 || len(s.ProvSecret) < 32 || len(s.PickleKey) < 32 {
		return errors.New("settings: data_dir, relay_port, prov_secret (>=32), pickle_key (>=32) required")
	}
	for _, u := range s.ExtraUsers {
		// No wildcards or whole domains: only full MXIDs.
		if !mxidRe.MatchString(u) {
			return fmt.Errorf("settings: extra user %q is not a full Matrix ID (no wildcards/domains)", u)
		}
		if u == owner {
			return errors.New("settings: owner is already admin")
		}
	}
	if s.LogLevel == "" {
		s.LogLevel = "info"
	}
	return nil
}

// --- yaml.Node helpers ---------------------------------------------------

func mapGet(n *yaml.Node, key string) *yaml.Node {
	if n.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(n.Content); i += 2 {
		if n.Content[i].Value == key {
			return n.Content[i+1]
		}
	}
	return nil
}

// path walks/creates nested mappings.
func yamlPath(root *yaml.Node, keys ...string) (*yaml.Node, error) {
	cur := root
	for _, k := range keys {
		next := mapGet(cur, k)
		if next == nil {
			if cur.Kind != yaml.MappingNode {
				return nil, fmt.Errorf("%s is not a mapping", strings.Join(keys, "."))
			}
			next = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			cur.Content = append(cur.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: k}, next)
		}
		cur = next
	}
	return cur, nil
}

func set(root *yaml.Node, value any, keys ...string) error {
	parent, err := yamlPath(root, keys[:len(keys)-1]...)
	if err != nil {
		return err
	}
	var vn yaml.Node
	if err = vn.Encode(value); err != nil {
		return err
	}
	key := keys[len(keys)-1]
	for i := 0; i+1 < len(parent.Content); i += 2 {
		if parent.Content[i].Value == key {
			// keep the comment attached to the old value
			vn.LineComment = parent.Content[i+1].LineComment
			*parent.Content[i+1] = vn
			return nil
		}
	}
	parent.Content = append(parent.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, &vn)
	return nil
}

// generateBridgeConfig edits the bridge's own example config (from -e) so new
// upstream options keep their defaults and comments.
func generateBridgeConfig(example []byte, b Bundle, s Settings) ([]byte, error) {
	if err := b.validate(); err != nil {
		return nil, err
	}
	if err := s.validate(b.Owner); err != nil {
		return nil, err
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(example, &doc); err != nil {
		return nil, err
	}
	if len(doc.Content) == 0 {
		return nil, errors.New("empty example config")
	}
	root := doc.Content[0]
	if mapGet(root, "homeserver") == nil || mapGet(root, "appservice") == nil || mapGet(root, "encryption") == nil {
		return nil, errors.New("example config is missing homeserver/appservice/encryption sections")
	}

	perms := map[string]string{b.Owner: "admin"}
	for _, u := range s.ExtraUsers {
		perms[u] = "user"
	}
	edits := []struct {
		value any
		keys  []string
	}{
		{fmt.Sprintf("http://127.0.0.1:%d", s.RelayPort), []string{"homeserver", "address"}},
		{b.ServerName, []string{"homeserver", "domain"}},
		{"standard", []string{"homeserver", "software"}},
		// The relay is the bridge's homeserver: it forwards client-API calls and
		// the websocket to the gateway. (websocket_proxy is dropped by the
		// bridge's config upgrader because the example config lacks it.)
		{true, []string{"homeserver", "websocket"}},
		{30, []string{"homeserver", "ping_interval_seconds"}},

		{b.AppserviceID, []string{"appservice", "id"}},
		{b.ASToken, []string{"appservice", "as_token"}},
		{b.HSToken, []string{"appservice", "hs_token"}},
		{b.BotLocalpart, []string{"appservice", "bot", "username"}},
		{"WhatsApp bridge (home)", []string{"appservice", "bot", "displayname"}},
		{b.UsernameTemplate, []string{"appservice", "username_template"}},
		{true, []string{"appservice", "ephemeral_events"}},
		// Never listen on a network port; everything goes over the websocket.
		{"127.0.0.1", []string{"appservice", "hostname"}},

		{"sqlite3-fk-wal", []string{"database", "type"}},
		{"file:" + s.DataDir + "/bridge.db?_txlock=immediate", []string{"database", "uri"}},

		{perms, []string{"bridge", "permissions"}},
		{false, []string{"bridge", "relay", "enabled"}},

		{s.ProvSecret, []string{"provisioning", "shared_secret"}},
		{false, []string{"provisioning", "allow_matrix_auth"}},
		{false, []string{"provisioning", "debug_endpoints"}},

		{map[string]string{}, []string{"double_puppet", "servers"}},
		{map[string]string{}, []string{"double_puppet", "secrets"}},
		{false, []string{"double_puppet", "allow_discovery"}},

		{true, []string{"encryption", "allow"}},
		{true, []string{"encryption", "default"}},
		{true, []string{"encryption", "require"}},
		// Synapse refuses /sync for appservice users, so encryption data must
		// come through transactions (MSC2409/MSC3202).
		{true, []string{"encryption", "appservice"}},
		{true, []string{"encryption", "msc4190"}},
		{true, []string{"encryption", "self_sign"}},
		{s.PickleKey, []string{"encryption", "pickle_key"}},
		{false, []string{"encryption", "delete_keys", "delete_outbound_on_ack"}},
		{true, []string{"encryption", "delete_keys", "dont_store_outbound"}},
		{true, []string{"encryption", "delete_keys", "ratchet_on_decrypt"}},
		{true, []string{"encryption", "delete_keys", "delete_fully_used_on_decrypt"}},
		{true, []string{"encryption", "delete_keys", "delete_prev_on_new_session"}},
		{true, []string{"encryption", "delete_keys", "delete_on_device_delete"}},
		{true, []string{"encryption", "delete_keys", "periodically_delete_expired"}},
		{true, []string{"encryption", "delete_keys", "delete_outdated_inbound"}},
		{"cross-signed-tofu", []string{"encryption", "verification_levels", "receive"}},
		{"cross-signed-tofu", []string{"encryption", "verification_levels", "send"}},
		{"cross-signed-tofu", []string{"encryption", "verification_levels", "share"}},

		{s.LogLevel, []string{"logging", "min_level"}},
	}
	for _, e := range edits {
		if err := set(root, e.value, e.keys...); err != nil {
			return nil, fmt.Errorf("set %s: %w", strings.Join(e.keys, "."), err)
		}
	}
	// Logging: stdout (captured by the app) + rotated file in the data dir.
	writers := []map[string]any{
		{"type": "stdout", "format": "pretty"},
		{"type": "file", "format": "json", "filename": s.DataDir + "/logs/bridge.log",
			"max_size": 10, "max_backups": 3, "compress": false},
	}
	if err := set(root, writers, "logging", "writers"); err != nil {
		return nil, err
	}
	return yaml.Marshal(&doc)
}

func runBridgeConfig(args []string) error {
	if len(args) != 4 {
		return errors.New("usage: bridge-config <example.yaml> <bundle.json> <settings.json> <out.yaml>")
	}
	example, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	var b Bundle
	var s Settings
	for i, target := range []any{&b, &s} {
		data, err := os.ReadFile(args[1+i])
		if err != nil {
			return err
		}
		if err = json.Unmarshal(data, target); err != nil {
			return fmt.Errorf("%s: %w", args[1+i], err)
		}
	}
	out, err := generateBridgeConfig(example, b, s)
	if err != nil {
		return err
	}
	tmp := args[3] + ".tmp"
	if err = os.WriteFile(tmp, out, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, args[3])
}
