package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

var errNoFreeSlot = errors.New("no free bridge slot; ask the server admin to add more")

// BridgeBundle is everything a bridge app needs to configure the bridge.
type BridgeBundle struct {
	Slot             string `json:"slot"`
	AppserviceID     string `json:"appservice_id"`
	Owner            string `json:"owner"`
	ServerName       string `json:"server_name"`
	HomeserverURL    string `json:"homeserver_url"` // gateway public URL (client API goes through it)
	WebsocketURL     string `json:"websocket_url"`
	ASToken          string `json:"as_token"`
	HSToken          string `json:"hs_token"`
	BotLocalpart     string `json:"bot_localpart"`
	BotMXID          string `json:"bot_mxid"`
	UsernameTemplate string `json:"username_template"`
	Active           bool   `json:"active"`
}

func (g *Gateway) bundle(s *Slot) BridgeBundle {
	return BridgeBundle{
		Slot: s.Name, AppserviceID: s.ASID, Owner: s.Owner, ServerName: g.cfg.ServerName,
		HomeserverURL: g.cfg.PublicURL, WebsocketURL: g.cfg.PublicURL,
		ASToken: s.BridgeASToken, HSToken: s.BridgeHSToken,
		BotLocalpart: s.BotLocalpart(), BotMXID: "@" + s.BotLocalpart() + ":" + g.cfg.ServerName,
		UsernameTemplate: s.UsernameTemplate(), Active: s.Active,
	}
}

// ---------------------------------------------------------------------------
// Authentication of tjena users

// authenticate resolves the caller's Matrix user ID. Accepts either a normal
// access token (checked with /account/whoami) or "openid:<token>" (checked
// with the federation OpenID userinfo endpoint).
func (g *Gateway) authenticate(ctx context.Context, r *http.Request) (string, error) {
	tok := bearer(r)
	if tok == "" {
		return "", errors.New("missing token")
	}
	g.authMu.Lock()
	if e, ok := g.authC[tok]; ok && e.expires.After(time.Now()) {
		g.authMu.Unlock()
		return e.mxid, nil
	}
	g.authMu.Unlock()

	var req *http.Request
	if ot, ok := strings.CutPrefix(tok, "openid:"); ok {
		req, _ = http.NewRequestWithContext(ctx, http.MethodGet,
			g.cfg.SynapseURL+"/_matrix/federation/v1/openid/userinfo?access_token="+url.QueryEscape(ot), nil)
	} else {
		req, _ = http.NewRequestWithContext(ctx, http.MethodGet, g.cfg.SynapseURL+"/_matrix/client/v3/account/whoami", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := g.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("homeserver unreachable: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errors.New("token not accepted by homeserver")
	}
	var body struct {
		UserID  string `json:"user_id"`
		Sub     string `json:"sub"`
		IsGuest bool   `json:"is_guest"`
	}
	if err = json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	mxid := body.UserID
	if mxid == "" {
		mxid = body.Sub
	}
	if mxid == "" || body.IsGuest {
		return "", errors.New("no user")
	}
	if g.isBridgeUser(mxid) {
		return "", errors.New("bridge users cannot own bridges")
	}
	g.authMu.Lock()
	g.authC[tok] = authCacheEntry{mxid: mxid, expires: time.Now().Add(time.Minute)}
	g.authMu.Unlock()
	return mxid, nil
}

func (g *Gateway) isBridgeUser(mxid string) bool {
	local := strings.TrimPrefix(strings.SplitN(mxid, ":", 2)[0], "@")
	if regexp.MustCompile(`^` + regexp.QuoteMeta(g.cfg.SlotPrefix) + `\d+(bot$|_)`).MatchString(local) {
		return true
	}
	for _, p := range g.cfg.ReservedPrefixes {
		if strings.HasPrefix(local, p+"_") || local == p+"bot" {
			return true
		}
	}
	return false
}

func (g *Gateway) rateLimited(mxid string) bool {
	g.rateMu.Lock()
	defer g.rateMu.Unlock()
	cutoff := time.Now().Add(-time.Hour)
	var kept []time.Time
	for _, t := range g.rate[mxid] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= g.cfg.ClaimRateLimit {
		g.rate[mxid] = kept
		return true
	}
	g.rate[mxid] = append(kept, time.Now())
	return false
}

// ---------------------------------------------------------------------------
// Operations (shared by provisioner, admin API and CLI)

// claim gives mxid a bridge: their existing slot with fresh bridge tokens
// (old bridge app is cut off), or a free slot.
func (g *Gateway) claim(mxid, actor string) (BridgeBundle, bool, error) {
	var out BridgeBundle
	reused := false
	err := g.store.Update(func(st *stateFile) error {
		var s *Slot
		if owned := st.ownedBy(mxid); len(owned) > 0 {
			s, reused = owned[0], true
		} else {
			s = st.firstFree()
			if s == nil {
				return errNoFreeSlot
			}
			s.State, s.Owner, s.AssignedAt = SlotAssigned, mxid, time.Now().UTC()
		}
		s.BridgeASToken, s.BridgeHSToken = randomToken(32), randomToken(32)
		out = g.bundle(s)
		return nil
	})
	if err != nil {
		return out, false, err
	}
	g.reindex()
	action := "claim"
	if reused {
		action = "reclaim"
	}
	g.audit(action, actor, mxid, out.Slot, nil)
	return out, reused, nil
}

// assignSlot is the admin variant: a specific slot to a specific user.
func (g *Gateway) assignSlot(name, mxid string) (BridgeBundle, error) {
	var out BridgeBundle
	err := g.store.Update(func(st *stateFile) error {
		s := st.find(name)
		if s == nil {
			return fmt.Errorf("no slot %s", name)
		}
		if s.State == SlotBurned {
			return fmt.Errorf("slot %s is burned", name)
		}
		if s.State == SlotAssigned && s.Owner != mxid {
			return fmt.Errorf("slot %s belongs to %s", name, s.Owner)
		}
		s.State, s.Owner = SlotAssigned, mxid
		if s.AssignedAt.IsZero() {
			s.AssignedAt = time.Now().UTC()
		}
		s.BridgeASToken, s.BridgeHSToken = randomToken(32), randomToken(32)
		out = g.bundle(s)
		return nil
	})
	if err != nil {
		return out, err
	}
	g.reindex()
	g.audit("assign", "admin", mxid, name, nil)
	return out, nil
}

// revoke burns a slot. Its bridge is disconnected and its tokens stop
// working immediately; the slot is never reused.
func (g *Gateway) revoke(name, actor string) (string, error) {
	var owner string
	err := g.store.Update(func(st *stateFile) error {
		s := st.find(name)
		if s == nil {
			return fmt.Errorf("no slot %s", name)
		}
		owner = s.Owner
		s.State, s.BurnedAt = SlotBurned, time.Now().UTC()
		s.BridgeASToken, s.BridgeHSToken = "", ""
		return nil
	})
	if err != nil {
		return "", err
	}
	g.reindex()
	g.audit("revoke", actor, owner, name, nil)
	return owner, nil
}

// addSlots creates n new slots and writes their registrations.
func (g *Gateway) addSlots(n int) ([]*Slot, error) {
	if n < 1 || n > 500 {
		return nil, errors.New("count must be 1..500")
	}
	var created []*Slot
	err := g.store.Update(func(st *stateFile) error {
		base := st.maxSlotNumber()
		for i := 1; i <= n; i++ {
			name := slotName(g.cfg.SlotPrefix, base+i)
			s := &Slot{Name: name, ASID: "tjena-" + name, ASToken: randomToken(32), HSToken: randomToken(32), State: SlotFree}
			if _, err := writeRegistration(g.cfg, s); err != nil {
				return err
			}
			st.Slots = append(st.Slots, s)
			created = append(created, s)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	g.reindex()
	g.audit("slots_add", "admin", "", "", map[string]any{"count": n, "first": created[0].Name, "last": created[len(created)-1].Name})
	return created, nil
}

// ---------------------------------------------------------------------------
// Public provisioner endpoints

func (g *Gateway) authOrFail(w http.ResponseWriter, r *http.Request) (string, bool) {
	mxid, err := g.authenticate(r.Context(), r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "M_UNKNOWN_TOKEN", err.Error())
		return "", false
	}
	if !g.cfg.userAllowed(mxid) {
		writeError(w, http.StatusForbidden, "M_FORBIDDEN", "This account may not use personal bridges")
		return "", false
	}
	return mxid, true
}

// POST /provision/v1/bridge — called by the bridge app after "Sign in with tjena".
func (g *Gateway) handleClaim(w http.ResponseWriter, r *http.Request) {
	mxid, ok := g.authOrFail(w, r)
	if !ok {
		return
	}
	if g.rateLimited(mxid) {
		writeError(w, http.StatusTooManyRequests, "M_LIMIT_EXCEEDED", "Too many bridge setups, try again later")
		return
	}
	b, _, err := g.claim(mxid, "user")
	if errors.Is(err, errNoFreeSlot) {
		writeError(w, http.StatusServiceUnavailable, "EU.TJENA.NO_FREE_SLOT", err.Error())
		return
	} else if err != nil {
		g.log.Error("claim failed", "err", err)
		writeError(w, http.StatusInternalServerError, "M_UNKNOWN", "Claim failed")
		return
	}
	writeJSON(w, http.StatusOK, b)
}

// GET /provision/v1/bridge — status of the caller's own bridge (no secrets).
func (g *Gateway) handleBridgeStatus(w http.ResponseWriter, r *http.Request) {
	mxid, ok := g.authOrFail(w, r)
	if !ok {
		return
	}
	var s *Slot
	g.store.View(func(st *stateFile) {
		if owned := st.ownedBy(mxid); len(owned) > 0 {
			cp := *owned[0]
			s = &cp
		}
	})
	if s == nil {
		writeError(w, http.StatusNotFound, "M_NOT_FOUND", "You have no personal bridge")
		return
	}
	writeJSON(w, http.StatusOK, g.statusOf(*s))
}

// DELETE /provision/v1/bridge — the owner removes their bridge.
func (g *Gateway) handleRevoke(w http.ResponseWriter, r *http.Request) {
	mxid, ok := g.authOrFail(w, r)
	if !ok {
		return
	}
	var names []string
	g.store.View(func(st *stateFile) {
		for _, s := range st.ownedBy(mxid) {
			names = append(names, s.Name)
		}
	})
	if len(names) == 0 {
		writeError(w, http.StatusNotFound, "M_NOT_FOUND", "You have no personal bridge")
		return
	}
	for _, n := range names {
		if _, err := g.revoke(n, "user"); err != nil {
			writeError(w, http.StatusInternalServerError, "M_UNKNOWN", "Revoke failed")
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"revoked": names})
}

// GET /provision/v1/info — unauthenticated: is the service up, any free slots?
func (g *Gateway) handleInfo(w http.ResponseWriter, r *http.Request) {
	free := 0
	g.store.View(func(st *stateFile) {
		for _, s := range st.Slots {
			if s.State == SlotFree && s.Active {
				free++
			}
		}
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"server_name": g.cfg.ServerName, "homeserver_url": g.cfg.PublicURL,
		"slots_available": free > 0, "version": 1,
	})
}

// ---------------------------------------------------------------------------
// Internal admin API (used by the CLI)

func (g *Gateway) handleAdmin(w http.ResponseWriter, r *http.Request) {
	if !g.checkAdmin(w, r) {
		return
	}
	var req struct {
		Count int    `json:"count"`
		Slot  string `json:"slot"`
		User  string `json:"user"`
	}
	_ = json.NewDecoder(r.Body).Decode(&req)
	switch r.PathValue("op") {
	case "slots-add":
		created, err := g.addSlots(req.Count)
		if err != nil {
			writeError(w, http.StatusBadRequest, "M_UNKNOWN", err.Error())
			return
		}
		names := make([]string, 0, len(created))
		for _, s := range created {
			names = append(names, s.Name)
		}
		writeJSON(w, http.StatusOK, map[string]any{"created": names, "synapse_snippet": synapseSnippet(g.cfg, created)})
	case "assign":
		b, err := g.assignSlot(req.Slot, req.User)
		if err != nil {
			writeError(w, http.StatusBadRequest, "M_UNKNOWN", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, b)
	case "claim":
		b, _, err := g.claim(req.User, "admin")
		if err != nil {
			writeError(w, http.StatusBadRequest, "M_UNKNOWN", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, b)
	case "revoke":
		owner, err := g.revoke(req.Slot, "admin")
		if err != nil {
			writeError(w, http.StatusBadRequest, "M_UNKNOWN", err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"revoked": req.Slot, "owner": owner})
	case "check-activation":
		g.checkActivation(r.Context())
		writeJSON(w, http.StatusOK, map[string]any{"slots": g.allStatus()})
	case "snippet":
		var all []*Slot
		g.store.View(func(st *stateFile) {
			for _, s := range st.Slots {
				cp := *s
				all = append(all, &cp)
			}
		})
		writeJSON(w, http.StatusOK, map[string]any{"synapse_snippet": synapseSnippet(g.cfg, all)})
	default:
		writeError(w, http.StatusNotFound, "M_UNRECOGNIZED", "Unknown admin op")
	}
}
