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
	mu       sync.Mutex
	em       *emitter.Emitter
	core     *core.Bridge
	startErr string // last Start() error message; non-empty means start failed
	dataDir  string
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

// --- internal helpers ---

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
