package main

// security-info: reads the bridge's own database (read-only) and prints the
// public keys and trust state for the bridge app's Security screen. Nothing
// here changes the bridge; it only looks at what the bridge stored.
//
//	librelay.so security-info <bridge.db> <pickle_key> <owner> <bot_mxid> [observed-keys.json]
//
// Matrix side: the bridge device's identity keys come from the pickled Olm
// account (decrypted with the pickle key that never leaves the phone). The
// bridge doesn't store its own cross-signing keys, so the master key comes
// from what the relay saw the bridge upload (observed-keys.json). The owner's
// devices and cross-signing state are what the bridge will trust.
//
// WhatsApp side: the linked device's identity key, the account key of the
// primary phone that approved it, and whether that approval signature checks
// out.

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/libsignal/ecc"
	"golang.org/x/crypto/curve25519"
	"maunium.net/go/mautrix/crypto/goolm/account"
)

type SecurityInfo struct {
	Matrix   MatrixSecurity     `json:"matrix"`
	WhatsApp []WhatsAppSecurity `json:"whatsapp"`
	Errors   []string           `json:"errors,omitempty"`
}

type MatrixSecurity struct {
	BotMXID        string        `json:"bot_mxid"`
	DeviceID       string        `json:"device_id,omitempty"`
	Ed25519        string        `json:"ed25519,omitempty"`
	Curve25519     string        `json:"curve25519,omitempty"`
	KeysShared     bool          `json:"keys_shared"`
	MasterKey      string        `json:"master_key,omitempty"`
	SelfSigningKey string        `json:"self_signing_key,omitempty"`
	Owner          OwnerSecurity `json:"owner"`
}

type OwnerSecurity struct {
	UserID         string        `json:"user_id"`
	MasterKey      string        `json:"master_key,omitempty"`
	FirstSeenKey   string        `json:"first_seen_master_key,omitempty"`
	MasterChanged  bool          `json:"master_key_changed"`
	SelfSigningKey string        `json:"self_signing_key,omitempty"`
	SSKSigned      bool          `json:"self_signing_key_signed"`
	Devices        []OwnerDevice `json:"devices"`
}

type OwnerDevice struct {
	DeviceID    string `json:"device_id"`
	Name        string `json:"name"`
	Ed25519     string `json:"ed25519"`
	CrossSigned bool   `json:"cross_signed"`
	// Manual trust stored by the bridge (id.TrustState): 0 unset, 1 verified… -1 blocked.
	Trust int `json:"trust"`
}

type WhatsAppSecurity struct {
	JID                string `json:"jid"`
	Phone              string `json:"phone"`
	Device             int    `json:"device"`
	PushName           string `json:"push_name,omitempty"`
	Platform           string `json:"platform,omitempty"`
	IdentityKey        string `json:"identity_key"`
	AccountKey         string `json:"account_key"`
	AccountSignatureOK bool   `json:"account_signature_ok"`
	ContactKeysKnown   int    `json:"contact_keys_known"`
}

// ObservedKeys is written by the relay when the bridge uploads its public
// keys (see observe.go).
type ObservedKeys struct {
	DeviceID       string `json:"device_id,omitempty"`
	Ed25519        string `json:"ed25519,omitempty"`
	Curve25519     string `json:"curve25519,omitempty"`
	MasterKey      string `json:"master_key,omitempty"`
	SelfSigningKey string `json:"self_signing_key,omitempty"`
}

func b64(b []byte) string { return base64.RawStdEncoding.EncodeToString(b) }

func runSecurityInfo(args []string) error {
	if len(args) < 4 {
		return errors.New("usage: security-info <bridge.db> <pickle_key> <owner> <bot_mxid> [observed-keys.json]")
	}
	dbPath, pickleKey, owner, bot := args[0], args[1], args[2], args[3]
	var observed ObservedKeys
	if len(args) > 4 {
		if data, err := os.ReadFile(args[4]); err == nil {
			_ = json.Unmarshal(data, &observed)
		}
	}
	info, err := securityInfo(dbPath, pickleKey, owner, bot, observed)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}

func securityInfo(dbPath, pickleKey, owner, bot string, observed ObservedKeys) (*SecurityInfo, error) {
	if _, err := os.Stat(dbPath); err != nil {
		return nil, fmt.Errorf("bridge database: %w", err)
	}
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?mode=ro&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	defer db.Close()

	info := &SecurityInfo{WhatsApp: []WhatsAppSecurity{}}
	addErr := func(what string, err error) {
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			info.Errors = append(info.Errors, what+": "+err.Error())
		}
	}

	// --- Matrix: the bridge's own device
	m := &info.Matrix
	m.BotMXID = bot
	var pickled []byte
	err = db.QueryRow("SELECT device_id, shared, account FROM crypto_account LIMIT 1").Scan(&m.DeviceID, &m.KeysShared, &pickled)
	if err == nil {
		acc := &account.Account{}
		if err = acc.Unpickle(pickled, []byte(pickleKey)); err == nil {
			ed, curve, _ := acc.IdentityKeys()
			m.Ed25519, m.Curve25519 = string(ed), string(curve)
		}
	}
	addErr("bridge device", err)
	if observed.DeviceID == "" || observed.DeviceID == m.DeviceID {
		m.MasterKey, m.SelfSigningKey = observed.MasterKey, observed.SelfSigningKey
	}
	// If the bridge ever stored its own cross-signing keys, prefer those.
	var usage, key string
	rows, err := db.Query("SELECT usage, key FROM crypto_cross_signing_keys WHERE user_id = ?", bot)
	if err == nil {
		for rows.Next() {
			if rows.Scan(&usage, &key) == nil {
				switch usage {
				case "master":
					m.MasterKey = key
				case "self_signing":
					m.SelfSigningKey = key
				}
			}
		}
		rows.Close()
	}

	// --- Matrix: the owner's keys as the bridge sees (and trusts) them
	o := &m.Owner
	o.UserID = owner
	o.Devices = []OwnerDevice{}
	rows, err = db.Query("SELECT usage, key, first_seen_key FROM crypto_cross_signing_keys WHERE user_id = ?", owner)
	addErr("owner cross-signing keys", err)
	if err == nil {
		for rows.Next() {
			var first string
			if rows.Scan(&usage, &key, &first) != nil {
				continue
			}
			switch usage {
			case "master":
				o.MasterKey, o.FirstSeenKey = key, first
				o.MasterChanged = first != "" && first != key
			case "self_signing":
				o.SelfSigningKey = key
			}
		}
		rows.Close()
	}
	signed := func(signedKey, signerKey string) bool {
		if signedKey == "" || signerKey == "" {
			return false
		}
		var n int
		_ = db.QueryRow(`SELECT count(*) FROM crypto_cross_signing_signatures
			WHERE signed_user_id = ? AND signed_key = ? AND signer_user_id = ? AND signer_key = ?`,
			owner, signedKey, owner, signerKey).Scan(&n)
		return n > 0
	}
	o.SSKSigned = signed(o.SelfSigningKey, o.MasterKey)
	rows, err = db.Query("SELECT device_id, name, signing_key, trust FROM crypto_device WHERE user_id = ? AND deleted = false ORDER BY name", owner)
	addErr("owner devices", err)
	if err == nil {
		for rows.Next() {
			var d OwnerDevice
			if rows.Scan(&d.DeviceID, &d.Name, &d.Ed25519, &d.Trust) != nil {
				continue
			}
			d.CrossSigned = o.SSKSigned && signed(d.Ed25519, o.SelfSigningKey)
			o.Devices = append(o.Devices, d)
		}
		rows.Close()
	}

	// --- WhatsApp: each linked account
	rows, err = db.Query(`SELECT jid, push_name, platform, identity_key, adv_details, adv_account_sig, adv_account_sig_key
		FROM whatsmeow_device`)
	addErr("whatsapp devices", err)
	if err == nil {
		for rows.Next() {
			var w WhatsAppSecurity
			var priv, details, sig, accKey []byte
			if err := rows.Scan(&w.JID, &w.PushName, &w.Platform, &priv, &details, &sig, &accKey); err != nil {
				addErr("whatsapp device", err)
				continue
			}
			w.Phone, w.Device = splitJID(w.JID)
			pub, err := curve25519.X25519(priv, curve25519.Basepoint)
			if err != nil {
				addErr("whatsapp identity", err)
				continue
			}
			w.IdentityKey, w.AccountKey = b64(pub), b64(accKey)
			w.AccountSignatureOK = verifyWAAccountSignature(details, pub, sig, accKey)
			info.WhatsApp = append(info.WhatsApp, w)
		}
		rows.Close()
	}
	for i := range info.WhatsApp {
		_ = db.QueryRow("SELECT count(*) FROM whatsmeow_identity_keys WHERE our_jid = ?", info.WhatsApp[i].JID).
			Scan(&info.WhatsApp[i].ContactKeysKnown)
	}
	return info, nil
}

// splitJID turns "491701234567:12@s.whatsapp.net" into ("+491701234567", 12).
func splitJID(jid string) (string, int) {
	user, _, _ := strings.Cut(jid, "@")
	user, devStr, _ := strings.Cut(user, ":")
	user, _, _ = strings.Cut(user, ".")
	dev, _ := strconv.Atoi(devStr)
	return "+" + user, dev
}

// verifyWAAccountSignature checks that the primary phone (account key) signed
// this linked device's identity, exactly as whatsmeow does when pairing.
func verifyWAAccountSignature(details, identityPub, sig, accKey []byte) bool {
	if len(accKey) != 32 || len(sig) != 64 || len(identityPub) != 32 {
		return false
	}
	key := ecc.NewDjbECPublicKey([32]byte(accKey))
	for _, prefix := range [][]byte{{6, 0}, {6, 5}} { // normal, hosted account
		msg := append(append(append([]byte{}, prefix...), details...), identityPub...)
		if ecc.VerifySignature(key, msg, [64]byte(sig)) {
			return true
		}
	}
	return false
}
