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
	Options    Options  `json:"options"`     // user choices from the app's settings screen
}

// Options are the user-facing bridge settings. They map onto the bridge's
// own config keys, so the bridge itself stays unmodified.
type Options struct {
	Backfill *BackfillOptions `json:"backfill,omitempty"` // nil = defaults below
	// WhatsApp status updates (stories): "off" (default), "muted" or "on".
	StatusBroadcast string `json:"status_broadcast,omitempty"`
	// Remove a WhatsApp account's chats from tjena when you log it out
	// (nil = yes). Its space is always removed.
	DeleteChatsOnLogout *bool `json:"delete_chats_on_logout,omitempty"`
}

type BackfillOptions struct {
	Enabled bool `json:"enabled"`
	// Messages to load into a newly created chat.
	MaxInitialMessages int `json:"max_initial_messages"`
	// Messages missed while the bridge was offline, per chat.
	MaxCatchupMessages int `json:"max_catchup_messages"`
	// Chats to create right after linking WhatsApp (-1 = all). Others are
	// created when a message arrives.
	MaxInitialConversations int `json:"max_initial_conversations"`
	// Ask the phone for up to a year of history instead of ~3 months when
	// linking. Only applies when linking WhatsApp.
	RequestFullSync bool `json:"request_full_sync"`
	// Days of history to request with RequestFullSync (0 = WhatsApp default).
	FullSyncDays int `json:"full_sync_days"`
}

// DefaultBackfill: recent history in the most recent chats, without
// flooding tjena with hundreds of rooms after linking.
var DefaultBackfill = BackfillOptions{
	Enabled: true, MaxInitialMessages: 50, MaxCatchupMessages: 500, MaxInitialConversations: 25,
}

func clamp(v, lo, hi int) int { return max(lo, min(hi, v)) }

// optionEdits turns Options into config edits.
func (o Options) edits() ([]configEdit, error) {
	bf := DefaultBackfill
	if o.Backfill != nil {
		bf = *o.Backfill
	}
	if bf.MaxInitialConversations < -1 {
		return nil, errors.New("settings: max_initial_conversations must be -1 or more")
	}
	bf.MaxInitialMessages = clamp(bf.MaxInitialMessages, 0, 10000)
	bf.MaxCatchupMessages = clamp(bf.MaxCatchupMessages, 0, 10000)
	bf.FullSyncDays = clamp(bf.FullSyncDays, 0, 3650)
	var days any // null = WhatsApp default
	if bf.RequestFullSync && bf.FullSyncDays > 0 {
		days = bf.FullSyncDays
	}
	statusOn, statusMuted := false, true
	switch o.StatusBroadcast {
	case "", "off":
	case "muted":
		statusOn = true
	case "on":
		statusOn, statusMuted = true, false
	default:
		return nil, fmt.Errorf("settings: status_broadcast must be off, muted or on, not %q", o.StatusBroadcast)
	}
	var statusTag any // null = no tag
	if statusMuted {
		statusTag = "m.lowpriority"
	}
	// Logging out: "delete" kicks you from the chat and the bot leaves it, so
	// it disappears from tjena. If WhatsApp itself ends the session (bad
	// credentials) chats stay, so linking again continues in the same chats.
	cleanup := "nothing"
	if o.DeleteChatsOnLogout == nil || *o.DeleteChatsOnLogout {
		cleanup = "delete"
	}
	// Each chat gets its history exactly once, when its room is created, from
	// whatever the phone has sent by then. Rooms are created once no history
	// chunk has arrived for dispatch_wait (upstream: 1m). Phones often pause
	// longer between chunks, which left chats with only the first few
	// messages, so wait longer.
	dispatchWait := "5m"
	if bf.RequestFullSync {
		dispatchWait = "10m"
	}
	return []configEdit{
		{true, []string{"bridge", "cleanup_on_logout", "enabled"}},
		{cleanup, []string{"bridge", "cleanup_on_logout", "manual", "private"}},
		{cleanup, []string{"bridge", "cleanup_on_logout", "manual", "relayed"}},
		{cleanup, []string{"bridge", "cleanup_on_logout", "manual", "shared_no_users"}},
		{"nothing", []string{"bridge", "cleanup_on_logout", "manual", "shared_has_users"}},
		{"nothing", []string{"bridge", "cleanup_on_logout", "bad_credentials", "private"}},
		{"nothing", []string{"bridge", "cleanup_on_logout", "bad_credentials", "relayed"}},
		{"nothing", []string{"bridge", "cleanup_on_logout", "bad_credentials", "shared_no_users"}},
		{"nothing", []string{"bridge", "cleanup_on_logout", "bad_credentials", "shared_has_users"}},
		{bf.Enabled, []string{"backfill", "enabled"}},
		{bf.MaxInitialMessages, []string{"backfill", "max_initial_messages"}},
		{bf.MaxCatchupMessages, []string{"backfill", "max_catchup_messages"}},
		{bf.MaxInitialConversations, []string{"network", "history_sync", "max_initial_conversations"}},
		{bf.RequestFullSync, []string{"network", "history_sync", "request_full_sync"}},
		{days, []string{"network", "history_sync", "full_sync_config", "days_limit"}},
		{dispatchWait, []string{"network", "history_sync", "dispatch_wait"}},
		// Standard Synapse can't insert messages into the past, so the
		// backwards backfill queue stays off.
		{false, []string{"backfill", "queue", "enabled"}},

		{statusOn, []string{"network", "enable_status_broadcast"}},
		{statusMuted, []string{"network", "mute_status_broadcast"}},
		{statusTag, []string{"network", "status_broadcast_tag"}},
		{true, []string{"network", "disable_status_broadcast_send"}},
	}, nil
}

type configEdit struct {
	value any
	keys  []string
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
	edits := []configEdit{
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
	optEdits, err := s.Options.edits()
	if err != nil {
		return nil, err
	}
	edits = append(edits, optEdits...)
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
