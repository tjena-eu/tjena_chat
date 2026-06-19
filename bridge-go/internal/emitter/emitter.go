package emitter

import (
	"encoding/json"
	"sync"
)

// Listener receives JSON-encoded events from Go.
// Implementations must be goroutine-safe; OnEvent may be called concurrently.
type Listener interface {
	OnEvent(payload string)
}

// Emitter is a thread-safe JSON event fan-out.
type Emitter struct {
	mu       sync.Mutex
	listener Listener
}

func New() *Emitter { return &Emitter{} }

// SetListener replaces the current listener. Pass nil to silence emissions.
func (e *Emitter) SetListener(l Listener) {
	e.mu.Lock()
	e.listener = l
	e.mu.Unlock()
}

// Emit marshals v to JSON and forwards to the listener. Drops silently on error or nil listener.
func (e *Emitter) Emit(v any) {
	e.mu.Lock()
	l := e.listener
	e.mu.Unlock()
	if l == nil {
		return
	}
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	l.OnEvent(string(data))
}

// EmitRaw forwards a pre-encoded JSON string.
func (e *Emitter) EmitRaw(payload string) {
	e.mu.Lock()
	l := e.listener
	e.mu.Unlock()
	if l == nil {
		return
	}
	l.OnEvent(payload)
}
