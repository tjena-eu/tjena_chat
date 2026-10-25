package main

import (
	"fmt"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

type Config struct {
	// Public listener: websocket for bridges, client-API forwarding, provisioner.
	// Exposed as https://wap.tjena.eu (Cloudflare tunnel / reverse proxy).
	PublicListen string `yaml:"public_listen"`
	// Internal listener: Synapse pushes appservice traffic here. Never expose it.
	InternalListen string `yaml:"internal_listen"`
	// Public base URL of the gateway, handed to bridge apps.
	PublicURL string `yaml:"public_url"`
	// URL Synapse uses to reach InternalListen (goes into the registrations).
	InternalURL string `yaml:"internal_url"`
	// Matrix server name, e.g. tjena.eu.
	ServerName string `yaml:"server_name"`
	// Internal Synapse URL, e.g. http://tjena_matrix:8008.
	SynapseURL string `yaml:"synapse_url"`
	// Directory for state.json and audit.jsonl.
	DataDir string `yaml:"data_dir"`
	// Directory the slot registration files are written to. Synapse must be
	// able to read it (mount it into the Synapse container).
	RegistrationDir string `yaml:"registration_dir"`
	// Path of RegistrationDir as seen from inside the Synapse container, used
	// for the app_service_config_files snippet.
	RegistrationDirInSynapse string `yaml:"registration_dir_in_synapse"`
	// Slot user prefix: slot 7 gets bot @wa07bot and ghosts @wa07_*.
	SlotPrefix string `yaml:"slot_prefix"`
	// User ID prefixes owned by other bridges; slots must never overlap them.
	ReservedPrefixes []string `yaml:"reserved_prefixes"`
	// Optional regexes; if set, only matching MXIDs may claim a bridge.
	AllowedUsers []string `yaml:"allowed_users"`
	// Max claim requests per user per hour.
	ClaimRateLimit int `yaml:"claim_rate_limit_per_hour"`
	// Max slots one user may hold (normally 1).
	MaxSlotsPerUser int `yaml:"max_slots_per_user"`

	TransactionTimeout int `yaml:"transaction_timeout_seconds"`
	KeepaliveInterval  int `yaml:"keepalive_interval_seconds"`
	// If set, GET /_tjena/status on the internal listener requires this bearer token.
	StatusToken string `yaml:"status_token"`
	// Extra services shown on the public status endpoint (Synapse is always
	// checked). Each URL must answer 2xx when the service is up.
	StatusChecks []StatusCheck `yaml:"status_checks"`
	// Warn (log + "low" on /status/v1) when fewer free slots than this remain.
	LowSlotsWarning int `yaml:"low_slots_warning"`

	allowedUsers []*regexp.Regexp
}

type StatusCheck struct {
	Name string `yaml:"name"`
	URL  string `yaml:"url"`
}

var validPrefix = regexp.MustCompile(`^[a-z][a-z0-9]{0,15}$`)

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &Config{}
	if err = yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	setDefault(&cfg.PublicListen, "0.0.0.0:29331")
	setDefault(&cfg.InternalListen, "0.0.0.0:29332")
	setDefault(&cfg.DataDir, "/data")
	setDefault(&cfg.SlotPrefix, "wa")
	if cfg.RegistrationDir == "" {
		cfg.RegistrationDir = cfg.DataDir + "/registrations"
	}
	setDefault(&cfg.RegistrationDirInSynapse, cfg.RegistrationDir)
	if cfg.ReservedPrefixes == nil {
		cfg.ReservedPrefixes = []string{"whatsapp", "signal"}
	}
	if cfg.ClaimRateLimit <= 0 {
		cfg.ClaimRateLimit = 5
	}
	if cfg.MaxSlotsPerUser <= 0 {
		cfg.MaxSlotsPerUser = 1
	}
	if cfg.TransactionTimeout <= 0 {
		cfg.TransactionTimeout = 60
	}
	if cfg.KeepaliveInterval <= 0 {
		cfg.KeepaliveInterval = 30
	}
	if cfg.LowSlotsWarning <= 0 {
		cfg.LowSlotsWarning = 5
	}
	for _, c := range cfg.StatusChecks {
		if c.Name == "" || !strings.HasPrefix(c.URL, "http") {
			return nil, fmt.Errorf("status_checks: name and http(s) url required")
		}
	}
	cfg.PublicURL = strings.TrimRight(cfg.PublicURL, "/")
	cfg.InternalURL = strings.TrimRight(cfg.InternalURL, "/")
	cfg.SynapseURL = strings.TrimRight(cfg.SynapseURL, "/")
	if cfg.ServerName == "" || cfg.SynapseURL == "" || cfg.PublicURL == "" || cfg.InternalURL == "" {
		return nil, fmt.Errorf("server_name, synapse_url, public_url and internal_url are required")
	}
	if !validPrefix.MatchString(cfg.SlotPrefix) {
		return nil, fmt.Errorf("invalid slot_prefix %q", cfg.SlotPrefix)
	}
	for _, r := range cfg.ReservedPrefixes {
		if strings.HasPrefix(cfg.SlotPrefix, r) || strings.HasPrefix(r, cfg.SlotPrefix+"0") {
			return nil, fmt.Errorf("slot_prefix %q overlaps reserved prefix %q", cfg.SlotPrefix, r)
		}
	}
	for _, a := range cfg.AllowedUsers {
		re, err := regexp.Compile(a)
		if err != nil {
			return nil, fmt.Errorf("allowed_users: %w", err)
		}
		cfg.allowedUsers = append(cfg.allowedUsers, re)
	}
	return cfg, nil
}

func setDefault(s *string, def string) {
	if *s == "" {
		*s = def
	}
}

func (cfg *Config) userAllowed(mxid string) bool {
	if !strings.HasSuffix(mxid, ":"+cfg.ServerName) {
		return false
	}
	if len(cfg.allowedUsers) == 0 {
		return true
	}
	for _, re := range cfg.allowedUsers {
		if re.MatchString(mxid) {
			return true
		}
	}
	return false
}
