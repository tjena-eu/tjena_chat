// Package ffi is the gomobile-bound entry point for the tjena bridge.
// Only gomobile-safe types are used here: primitives, string, []byte, error,
// exported struct pointers, and exported interfaces.
//
// Multi-account: WhatsApp runs one core.Bridge per account. The "default"
// account uses the root data dir (preserving pre-multi-account installs); extra
// accounts live in dataDir/acc_<id>/. Every event is tagged with "account_id"
// so the Dart side can namespace rooms/ghosts per account. Signal remains a
// single account at dataDir/signal.
package ffi

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"tjena.eu/tjena-bridge/internal/core"
	"tjena.eu/tjena-bridge/internal/emitter"
	signalpkg "tjena.eu/tjena-bridge/internal/signal"
)

const defaultAccountID = "default"

// EventListener receives JSON-encoded events from the Go bridge.
// OnEvent is called from Go goroutines; implementations must be goroutine-safe.
type EventListener interface {
	OnEvent(payload string)
}

// account is one WhatsApp login: its own core.Bridge, data dir and emitter.
type account struct {
	id   string
	dir  string
	core *core.Bridge
	em   *emitter.Emitter
}

// Bridge is the gomobile entry point. Create with New; call SetListener before Start.
type Bridge struct {
	mu        sync.Mutex
	listener  EventListener
	em        *emitter.Emitter // untagged: signal + ffi-level events
	accounts  map[string]*account
	order     []string
	signal    *signalpkg.Bridge
	signalErr string
	dataDir   string
}

// New allocates a Bridge for the given data directory.
func New(dataDir string) *Bridge {
	return &Bridge{
		em:       emitter.New(),
		accounts: map[string]*account{},
		dataDir:  dataDir,
	}
}

// SetListener wires the Kotlin/Swift listener. Tags per-account events with the
// account id; signal/ffi-level events go through untagged.
func (b *Bridge) SetListener(l EventListener) {
	b.mu.Lock()
	b.listener = l
	b.em.SetListener(listenerAdapter{l})
	for _, a := range b.accounts {
		a.em.SetListener(tagListener{a.id, l})
	}
	b.mu.Unlock()
}

func (b *Bridge) accountDir(id string) string {
	if id == defaultAccountID {
		return b.dataDir
	}
	return filepath.Join(b.dataDir, id)
}

// startAccountLocked creates and starts a core.Bridge for id. Caller holds mu.
func (b *Bridge) startAccountLocked(id string) (*account, error) {
	if a, ok := b.accounts[id]; ok {
		return a, nil
	}
	dir := b.accountDir(id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	em := emitter.New()
	if b.listener != nil {
		em.SetListener(tagListener{id, b.listener})
	}
	c, err := core.New(dir, em)
	if err != nil {
		return nil, err
	}
	if err := c.Start(context.Background()); err != nil {
		return nil, err
	}
	a := &account{id: id, dir: dir, core: c, em: em}
	b.accounts[id] = a
	return a, nil
}

// Start discovers and starts all accounts ("default" + acc_* dirs) and Signal.
func (b *Bridge) Start() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	ids := []string{defaultAccountID}
	if entries, err := os.ReadDir(b.dataDir); err == nil {
		for _, e := range entries {
			if e.IsDir() && strings.HasPrefix(e.Name(), "acc_") {
				ids = append(ids, e.Name())
			}
		}
	}
	sort.Strings(ids)
	b.order = ids
	for _, id := range ids {
		if _, err := b.startAccountLocked(id); err != nil {
			b.em.Emit(map[string]any{
				"type": "account_error", "account_id": id, "error": err.Error(),
			})
		}
	}

	// Signal (single account) at <dataDir>/signal.
	if b.signal == nil {
		sb, serr := signalpkg.New(b.dataDir+"/signal", b.em)
		if serr == nil {
			serr = sb.Start(context.Background())
		}
		if serr != nil {
			b.signalErr = serr.Error()
		} else {
			b.signal = sb
		}
	}
	return nil
}

// Stop disconnects all accounts and Signal.
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, a := range b.accounts {
		a.core.Stop()
	}
	b.accounts = map[string]*account{}
	if b.signal != nil {
		b.signal.Stop()
		b.signal = nil
	}
}

// --- Account management ---

// AddAccount creates a new (unlinked) WhatsApp account and returns its id. Link
// it afterwards with RequestQRLink(id).
func (b *Bridge) AddAccount() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	id := fmt.Sprintf("acc_%d", time.Now().UnixNano())
	if _, err := b.startAccountLocked(id); err != nil {
		b.em.Emit(map[string]any{"type": "account_error", "account_id": id, "error": err.Error()})
		return ""
	}
	b.order = append(b.order, id)
	return id
}

// RemoveAccount logs out, stops and (for non-default accounts) deletes an account.
func (b *Bridge) RemoveAccount(accountID string) error {
	b.mu.Lock()
	a := b.accounts[accountID]
	delete(b.accounts, accountID)
	for i, id := range b.order {
		if id == accountID {
			b.order = append(b.order[:i], b.order[i+1:]...)
			break
		}
	}
	b.mu.Unlock()
	if a != nil {
		_ = a.core.Logout()
		a.core.Stop()
	}
	if accountID != defaultAccountID {
		_ = os.RemoveAll(b.accountDir(accountID))
	}
	return nil
}

// ListAccountsJSON returns [{"id","linked","connected","phone","push_name"}].
func (b *Bridge) ListAccountsJSON() string {
	b.mu.Lock()
	ids := append([]string{}, b.order...)
	accs := make(map[string]*account, len(b.accounts))
	for k, v := range b.accounts {
		accs[k] = v
	}
	b.mu.Unlock()

	var sb strings.Builder
	sb.WriteByte('[')
	first := true
	for _, id := range ids {
		a := accs[id]
		if a == nil {
			continue
		}
		st := a.core.GetStateJSON() // {"linked":...}
		if !strings.HasPrefix(st, "{") {
			continue
		}
		if !first {
			sb.WriteByte(',')
		}
		first = false
		sb.WriteString(`{"id":"` + id + `",` + st[1:])
	}
	sb.WriteByte(']')
	return sb.String()
}

func (b *Bridge) coreOf(accountID string) *core.Bridge {
	b.mu.Lock()
	defer b.mu.Unlock()
	if a := b.accounts[accountID]; a != nil {
		return a.core
	}
	return nil
}

func (b *Bridge) withAccount(accountID string, fn func(*core.Bridge) error) error {
	c := b.coreOf(accountID)
	if c == nil {
		return fmt.Errorf("account %q not started", accountID)
	}
	return fn(c)
}

// --- WhatsApp (per account) ---

func (b *Bridge) GetStateJSON(accountID string) string {
	c := b.coreOf(accountID)
	if c == nil {
		return `{"linked":false,"connected":false,"phone":"","push_name":""}`
	}
	return c.GetStateJSON()
}

func (b *Bridge) RequestQRLink(accountID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.RequestQRLink() })
}

func (b *Bridge) RequestPhoneLink(accountID, phone string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.RequestPhoneLink(phone) })
}

func (b *Bridge) SendText(accountID, portalID, msgID, text string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.SendText(portalID, msgID, text) })
}

func (b *Bridge) SendMedia(accountID, portalID, msgID, mimeType string, data []byte) error {
	return b.withAccount(accountID, func(c *core.Bridge) error {
		return c.SendMedia(portalID, msgID, mimeType, data)
	})
}

func (b *Bridge) SendLocation(accountID, portalID string, lat, lon float64) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.SendLocation(portalID, lat, lon) })
}

func (b *Bridge) SendReaction(accountID, portalID, targetEventID, emoji string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error {
		return c.SendReaction(portalID, targetEventID, emoji)
	})
}

func (b *Bridge) SendRedaction(accountID, portalID, targetEventID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error {
		return c.SendRedaction(portalID, targetEventID)
	})
}

func (b *Bridge) MarkRead(accountID, portalID, eventID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.MarkRead(portalID, eventID) })
}

func (b *Bridge) SetTyping(accountID, portalID string, typing bool) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.SetTyping(portalID, typing) })
}

func (b *Bridge) Logout(accountID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.Logout() })
}

func (b *Bridge) ForceReset(accountID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.ForceReset() })
}

func (b *Bridge) RefreshRoom(accountID, roomID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.RefreshRoom(roomID) })
}

func (b *Bridge) RequestBackfill(accountID, roomID string, days int, anchorMsgID string, anchorFromMe bool, anchorTS int64) error {
	return b.withAccount(accountID, func(c *core.Bridge) error {
		return c.RequestBackfill(roomID, days, anchorMsgID, anchorFromMe, anchorTS)
	})
}

func (b *Bridge) BackfillFromCache(accountID, roomID string, days int) error {
	return b.withAccount(accountID, func(c *core.Bridge) error {
		return c.BackfillFromCache(roomID, days)
	})
}

// ClearCache wipes an account's cached WhatsApp history (not WhatsApp itself).
func (b *Bridge) ClearCache(accountID string) error {
	return b.withAccount(accountID, func(c *core.Bridge) error { return c.ClearCache() })
}

func (b *Bridge) ListChatsJSON(accountID string) string {
	c := b.coreOf(accountID)
	if c == nil {
		return "[]"
	}
	return c.ListChatsJSON()
}

func (b *Bridge) ListCachedChatsJSON(accountID string) string {
	c := b.coreOf(accountID)
	if c == nil {
		return "[]"
	}
	return c.ListCachedChatsJSON()
}

func (b *Bridge) GetChatAvatarURL(accountID, roomID string) string {
	c := b.coreOf(accountID)
	if c == nil {
		return ""
	}
	return c.GetChatAvatarURL(roomID)
}

func (b *Bridge) GetLogs(accountID string) string {
	c := b.coreOf(accountID)
	if c == nil {
		return "(account not started)"
	}
	return c.GetLogs()
}

// OnForeground / OnBackground apply to every account.
func (b *Bridge) OnForeground() {
	b.mu.Lock()
	accs := make([]*account, 0, len(b.accounts))
	for _, a := range b.accounts {
		accs = append(accs, a)
	}
	b.mu.Unlock()
	for _, a := range accs {
		a.core.OnForeground()
	}
}

func (b *Bridge) OnBackground() {
	b.mu.Lock()
	accs := make([]*account, 0, len(b.accounts))
	for _, a := range b.accounts {
		accs = append(accs, a)
	}
	b.mu.Unlock()
	for _, a := range accs {
		a.core.OnBackground()
	}
}

// --- Signal bridge (single account) ---

func (b *Bridge) StartSignal() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.signal != nil {
		return nil
	}
	sb, err := signalpkg.New(b.dataDir+"/signal", b.em)
	if err != nil {
		b.signalErr = err.Error()
		return err
	}
	if err := sb.Start(context.Background()); err != nil {
		b.signalErr = err.Error()
		return err
	}
	b.signal = sb
	b.signalErr = ""
	return nil
}

func (b *Bridge) StopSignal() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.signal != nil {
		b.signal.Stop()
		b.signal = nil
	}
}

func (b *Bridge) GetSignalStateJSON() string {
	b.mu.Lock()
	s := b.signal
	b.mu.Unlock()
	if s == nil {
		return `{"linked":false,"connected":false,"phone":""}`
	}
	return s.GetStateJSON()
}

func (b *Bridge) RequestSignalQR() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.RequestQRLink() })
}

func (b *Bridge) SignalLogout() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.Logout() })
}

func (b *Bridge) SignalManualSync() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.ManualSync() })
}

func (b *Bridge) SignalSyncRoom(chatID string) error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.SyncRoom(chatID) })
}

func (b *Bridge) ClearSignalRooms() {
	b.mu.Lock()
	s := b.signal
	b.mu.Unlock()
	if s != nil {
		s.ClearPersistedRooms()
	}
}

func (b *Bridge) GetSignalLogs() string {
	b.mu.Lock()
	s := b.signal
	b.mu.Unlock()
	if s == nil {
		return "(signal bridge not started)"
	}
	return s.GetLogs()
}

// --- internal helpers ---

func (b *Bridge) withSignal(fn func(*signalpkg.Bridge) error) error {
	b.mu.Lock()
	s := b.signal
	signalErr := b.signalErr
	b.mu.Unlock()
	if s == nil {
		if signalErr != "" {
			return fmt.Errorf("signal bridge start failed: %s", signalErr)
		}
		return fmt.Errorf("signal bridge not started")
	}
	return fn(s)
}

// listenerAdapter bridges EventListener to emitter.Listener (untagged).
type listenerAdapter struct{ l EventListener }

func (a listenerAdapter) OnEvent(payload string) { a.l.OnEvent(payload) }

// tagListener injects "account_id" into each JSON event object before forwarding.
type tagListener struct {
	id string
	l  EventListener
}

func (t tagListener) OnEvent(payload string) {
	if strings.HasPrefix(payload, "{") {
		if payload == "{}" {
			payload = `{"account_id":"` + t.id + `"}`
		} else {
			payload = `{"account_id":"` + t.id + `",` + payload[1:]
		}
	}
	t.l.OnEvent(payload)
}
