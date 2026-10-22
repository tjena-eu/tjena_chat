package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
)

// The bridge uploads its public device keys and cross-signing keys once, through
// the relay. It doesn't store its own cross-signing public keys locally, so the
// relay records them (public keys only) for the Security screen. The request
// itself is passed on unchanged.

const maxObservedBody = 1 << 20

func (r *Relay) observeKeyUploads(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if r.cfg.KeysFile == "" || req.Method != http.MethodPost || req.Body == nil {
			next.ServeHTTP(w, req)
			return
		}
		p := req.URL.Path
		isDevice := strings.HasSuffix(p, "/keys/upload")
		isSigning := strings.HasSuffix(p, "/keys/device_signing/upload")
		if !isDevice && !isSigning {
			next.ServeHTTP(w, req)
			return
		}
		body, err := io.ReadAll(io.LimitReader(req.Body, maxObservedBody+1))
		_ = req.Body.Close()
		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		if err == nil && len(body) <= maxObservedBody {
			r.recordKeys(body, isSigning)
		}
		next.ServeHTTP(w, req)
	})
}

type keyObject struct {
	UserID   string            `json:"user_id"`
	DeviceID string            `json:"device_id"`
	Keys     map[string]string `json:"keys"`
}

func firstKey(k *keyObject, prefix string) string {
	if k == nil {
		return ""
	}
	for name, v := range k.Keys {
		if strings.HasPrefix(name, prefix) {
			return v
		}
	}
	return ""
}

func (r *Relay) recordKeys(body []byte, signing bool) {
	r.keysMu.Lock()
	defer r.keysMu.Unlock()
	var obs ObservedKeys
	if data, err := os.ReadFile(r.cfg.KeysFile); err == nil {
		_ = json.Unmarshal(data, &obs)
	}
	changed := false
	if signing {
		var up struct {
			Master      *keyObject `json:"master_key"`
			SelfSigning *keyObject `json:"self_signing_key"`
		}
		if json.Unmarshal(body, &up) != nil {
			return
		}
		if k := firstKey(up.Master, "ed25519:"); k != "" {
			obs.MasterKey, changed = k, true
		}
		if k := firstKey(up.SelfSigning, "ed25519:"); k != "" {
			obs.SelfSigningKey, changed = k, true
		}
	} else {
		var up struct {
			DeviceKeys *keyObject `json:"device_keys"`
		}
		if json.Unmarshal(body, &up) != nil || up.DeviceKeys == nil {
			return
		}
		dk := up.DeviceKeys
		if dk.DeviceID != obs.DeviceID {
			// New device (e.g. fresh database): old cross-signing keys no longer apply.
			obs = ObservedKeys{DeviceID: dk.DeviceID}
		}
		obs.Ed25519 = firstKey(dk, "ed25519:")
		obs.Curve25519 = firstKey(dk, "curve25519:")
		changed = true
	}
	if !changed {
		return
	}
	data, _ := json.Marshal(obs)
	tmp := r.cfg.KeysFile + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, r.cfg.KeysFile)
	}
	r.log.Info("recorded uploaded public keys", "cross_signing", signing)
}
