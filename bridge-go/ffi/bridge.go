// Package ffi is the gomobile-bound entry point for the tjena bridge.
// Only gomobile-safe types are used here: primitives, string, []byte, error,
// exported struct pointers, and exported interfaces.
package ffi

import (
	"context"
	"fmt"
	"sync"

	"tjena.eu/tjena-bridge/internal/core"
	"tjena.eu/tjena-bridge/internal/emitter"
	signalpkg "tjena.eu/tjena-bridge/internal/signal"
)

// EventListener receives JSON-encoded events from the Go bridge.
// The single method OnEvent is called from a Go goroutine;
// implementations must be goroutine-safe.
// The Kotlin implementation forwards events to Flutter's EventChannel.
type EventListener interface {
	OnEvent(payload string)
}

// Bridge is the main entry point exposed to the Flutter plugin via gomobile.
// Create with New; call SetListener before Start.
type Bridge struct {
	mu        sync.Mutex
	em        *emitter.Emitter
	core      *core.Bridge
	signal    *signalpkg.Bridge
	startErr  string // last Start() error message; non-empty means start failed
	signalErr string // last signal Start() error message
	dataDir   string
}

// New allocates a Bridge for the given data directory.
// The directory will be created if it does not exist.
func New(dataDir string) *Bridge {
	return &Bridge{
		em:      emitter.New(),
		dataDir: dataDir,
	}
}

// SetListener wires a Kotlin/Swift EventListener to the Go event emitter.
// Call before Start; may be called again after hot-restart.
func (b *Bridge) SetListener(l EventListener) {
	b.em.SetListener(listenerAdapter{l})
}

// Start opens stores and connects WhatsApp. Idempotent.
func (b *Bridge) Start() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.core != nil {
		return nil // already started
	}
	br, err := core.New(b.dataDir, b.em)
	if err != nil {
		b.startErr = err.Error()
		return err
	}
	if err := br.Start(context.Background()); err != nil {
		b.startErr = err.Error()
		return err
	}
	b.core = br
	b.startErr = ""

	// Start the Signal bridge too, sharing the same event emitter. Failure here
	// is non-fatal: WhatsApp must keep working even if Signal can't start.
	if b.signal == nil {
		sb, serr := signalpkg.New(b.dataDir+"/signal", b.em)
		if serr != nil {
			b.signalErr = serr.Error()
		} else if serr := sb.Start(context.Background()); serr != nil {
			b.signalErr = serr.Error()
		} else {
			b.signal = sb
			b.signalErr = ""
		}
	}
	return nil
}

// Stop disconnects and flushes state.
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.core != nil {
		b.core.Stop()
		b.core = nil
	}
	if b.signal != nil {
		b.signal.Stop()
		b.signal = nil
	}
}

// GetStateJSON returns {"linked":bool,"connected":bool,"phone":"...","push_name":"..."}.
func (b *Bridge) GetStateJSON() string {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c == nil {
		return `{"linked":false,"connected":false,"phone":"","push_name":""}`
	}
	return c.GetStateJSON()
}

// RequestQRLink starts async QR linking.
// QR PNG frames arrive as {"type":"qr","data":"<base64>"} events.
func (b *Bridge) RequestQRLink() error {
	return b.withCore(func(c *core.Bridge) error { return c.RequestQRLink() })
}

// RequestPhoneLink requests a pairing code.
// The code arrives as {"type":"phone_code","code":"xxx-xxx"}.
func (b *Bridge) RequestPhoneLink(phone string) error {
	return b.withCore(func(c *core.Bridge) error { return c.RequestPhoneLink(phone) })
}

// ConfirmPhoneLink is a no-op — pairing completes automatically.
func (b *Bridge) ConfirmPhoneLink(code string) error { return nil }

// SendText sends a text message to a portal.
func (b *Bridge) SendText(portalID, msgID, text string) error {
	return b.withCore(func(c *core.Bridge) error { return c.SendText(portalID, msgID, text) })
}

// SendMedia uploads and sends a file/image/video/audio through WhatsApp.
// mimeType determines the WA message type (image/*, video/*, audio/*, other→document).
func (b *Bridge) SendMedia(portalID, msgID, mimeType string, data []byte) error {
	return b.withCore(func(c *core.Bridge) error {
		return c.SendMedia(portalID, msgID, mimeType, data)
	})
}

// SendLocation sends a location message through WhatsApp.
func (b *Bridge) SendLocation(portalID string, lat, lon float64) error {
	return b.withCore(func(c *core.Bridge) error { return c.SendLocation(portalID, lat, lon) })
}

// SendReaction sends an emoji reaction.
func (b *Bridge) SendReaction(portalID, targetEventID, emoji string) error {
	return b.withCore(func(c *core.Bridge) error {
		return c.SendReaction(portalID, targetEventID, emoji)
	})
}

// SendRedaction retracts a message.
func (b *Bridge) SendRedaction(portalID, targetEventID string) error {
	return b.withCore(func(c *core.Bridge) error {
		return c.SendRedaction(portalID, targetEventID)
	})
}

// MarkRead sends a read marker.
func (b *Bridge) MarkRead(portalID, eventID string) error {
	return b.withCore(func(c *core.Bridge) error { return c.MarkRead(portalID, eventID) })
}

// SetTyping sends a typing presence update.
func (b *Bridge) SetTyping(portalID string, typing bool) error {
	return b.withCore(func(c *core.Bridge) error { return c.SetTyping(portalID, typing) })
}

// Logout unlinks the WhatsApp account.
func (b *Bridge) Logout() error {
	return b.withCore(func(c *core.Bridge) error { return c.Logout() })
}

// ForceReset wipes local device credentials and prepares for fresh linking.
// Use when the device store has stale credentials that block re-linking.
func (b *Bridge) ForceReset() error {
	return b.withCore(func(c *core.Bridge) error { return c.ForceReset() })
}

// RefreshRoom re-fetches the name and profile picture for a room (JID string
// like "15551234567@s.whatsapp.net") and emits a room_updated event.
func (b *Bridge) RefreshRoom(roomID string) error {
	return b.withCore(func(c *core.Bridge) error { return c.RefreshRoom(roomID) })
}

// RequestBackfill pulls on-demand message history for a chat (roomID is the WA
// JID) going back `days` days. Messages arrive as backfill `message` events.
// The anchor (oldest message the client has) is supplied by the caller since the
// Go bridge keeps no message history of its own.
func (b *Bridge) RequestBackfill(roomID string, days int, anchorMsgID string, anchorFromMe bool, anchorTS int64) error {
	return b.withCore(func(c *core.Bridge) error {
		return c.RequestBackfill(roomID, days, anchorMsgID, anchorFromMe, anchorTS)
	})
}

// ListChatsJSON returns a JSON array of all known WhatsApp chats (contacts +
// groups) for the chat-picker UI. Returns "[]" if the bridge isn't connected.
func (b *Bridge) ListChatsJSON() string {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c == nil {
		return "[]"
	}
	return c.ListChatsJSON()
}

// GetChatAvatarURL returns the https URL of a chat's profile picture, or "".
func (b *Bridge) GetChatAvatarURL(roomID string) string {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c == nil {
		return ""
	}
	return c.GetChatAvatarURL(roomID)
}

// GetLogs returns recent bridge log lines (up to 100) as a single string.
func (b *Bridge) GetLogs() string {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c == nil {
		return "(bridge not started)"
	}
	return c.GetLogs()
}

// OnForeground notifies the bridge that the app came to the foreground.
func (b *Bridge) OnForeground() {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c != nil {
		c.OnForeground()
	}
}

// OnBackground notifies the bridge that the app moved to the background.
func (b *Bridge) OnBackground() {
	b.mu.Lock()
	c := b.core
	b.mu.Unlock()
	if c != nil {
		c.OnBackground()
	}
}

// --- Signal bridge ---

// StartSignal ensures the Signal bridge is started (it normally auto-starts with
// Start). Idempotent.
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

// StopSignal disconnects the Signal bridge.
func (b *Bridge) StopSignal() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.signal != nil {
		b.signal.Stop()
		b.signal = nil
	}
}

// GetSignalStateJSON returns {"linked":bool,"connected":bool,"phone":"..."}.
func (b *Bridge) GetSignalStateJSON() string {
	b.mu.Lock()
	s := b.signal
	b.mu.Unlock()
	if s == nil {
		return `{"linked":false,"connected":false,"phone":""}`
	}
	return s.GetStateJSON()
}

// RequestSignalQR starts async provisioning; emits signal_qr events with the URL.
func (b *Bridge) RequestSignalQR() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.RequestQRLink() })
}

// SignalLogout unlinks the Signal account.
func (b *Bridge) SignalLogout() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.Logout() })
}

// SignalManualSync triggers a manual contact/room sync.
func (b *Bridge) SignalManualSync() error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.ManualSync() })
}

// SignalSyncRoom re-fetches metadata for a single Signal chat.
func (b *Bridge) SignalSyncRoom(chatID string) error {
	return b.withSignal(func(s *signalpkg.Bridge) error { return s.SyncRoom(chatID) })
}

// ClearSignalRooms wipes the persisted Signal room cache.
func (b *Bridge) ClearSignalRooms() {
	b.mu.Lock()
	s := b.signal
	b.mu.Unlock()
	if s != nil {
		s.ClearPersistedRooms()
	}
}

// GetSignalLogs returns recent Signal bridge log lines.
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

func (b *Bridge) withCore(fn func(*core.Bridge) error) error {
	b.mu.Lock()
	c := b.core
	startErr := b.startErr
	b.mu.Unlock()
	if c == nil {
		if startErr != "" {
			return fmt.Errorf("bridge start failed: %s", startErr)
		}
		return fmt.Errorf("bridge not started")
	}
	return fn(c)
}

// listenerAdapter bridges EventListener to emitter.Listener.
type listenerAdapter struct{ l EventListener }

func (a listenerAdapter) OnEvent(payload string) { a.l.OnEvent(payload) }
