package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Close codes/reasons understood by mautrix-go's appservice websocket client.
const (
	closeConnReplaced = websocket.StatusCode(4001)
	closeRevoked      = websocket.StatusPolicyViolation
)

var (
	errNotConnected = errors.New("bridge websocket not connected")
	errConnClosed   = errors.New("bridge websocket closed before responding")
)

// wsMessage is the envelope used in both directions (mautrix websocket v3).
type wsMessage struct {
	ID      int64           `json:"id,omitempty"`
	Command string          `json:"command"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type reply struct {
	ok   bool
	data json.RawMessage
}

// bridgeConn is one live websocket from a bridge.
type bridgeConn struct {
	id        string
	token     string // bridge as_token used to connect
	ws        *websocket.Conn
	since     time.Time
	lastEvent time.Time // guarded by Gateway.mu
	writeMu sync.Mutex
	nextID  atomic.Int64
	waitMu  sync.Mutex
	waiters map[int64]chan reply
	ctx     context.Context
	cancel  context.CancelFunc
}

func newBridgeConn(id, token string, ws *websocket.Conn) *bridgeConn {
	ctx, cancel := context.WithCancel(context.Background())
	return &bridgeConn{id: id, token: token, ws: ws, since: time.Now(), waiters: map[int64]chan reply{}, ctx: ctx, cancel: cancel}
}

func (c *bridgeConn) writeRaw(ctx context.Context, data []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return c.ws.Write(ctx, websocket.MessageText, data)
}

func (c *bridgeConn) writeJSON(ctx context.Context, v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.writeRaw(ctx, data)
}

// request sends a command (fields merged into the top-level object, as the
// mautrix protocol puts transaction fields next to "command") and waits for
// the bridge's "response"/"error".
func (c *bridgeConn) request(ctx context.Context, fields map[string]json.RawMessage) (reply, error) {
	reqID := c.nextID.Add(1)
	fields["id"], _ = json.Marshal(reqID)
	data, err := json.Marshal(fields)
	if err != nil {
		return reply{}, err
	}
	ch := make(chan reply, 1)
	c.waitMu.Lock()
	c.waiters[reqID] = ch
	c.waitMu.Unlock()
	defer func() {
		c.waitMu.Lock()
		delete(c.waiters, reqID)
		c.waitMu.Unlock()
	}()
	if err = c.writeRaw(ctx, data); err != nil {
		return reply{}, err
	}
	select {
	case r := <-ch:
		return r, nil
	case <-c.ctx.Done():
		return reply{}, errConnClosed
	case <-ctx.Done():
		return reply{}, ctx.Err()
	}
}

func (c *bridgeConn) close(code websocket.StatusCode, status string) {
	reason, _ := json.Marshal(map[string]string{"command": "disconnect", "status": status})
	_ = c.ws.Close(code, string(reason))
	c.cancel()
}

// readLoop handles messages from the bridge until the connection drops.
func (c *bridgeConn) readLoop(log *slog.Logger) error {
	c.ws.SetReadLimit(50 * 1024 * 1024)
	for {
		typ, data, err := c.ws.Read(c.ctx)
		if err != nil {
			return err
		}
		if typ != websocket.MessageText {
			continue
		}
		var msg wsMessage
		if err = json.Unmarshal(data, &msg); err != nil {
			log.Warn("invalid JSON from bridge", "bridge", c.id)
			continue
		}
		switch msg.Command {
		case "response", "error":
			c.waitMu.Lock()
			ch, ok := c.waiters[msg.ID]
			c.waitMu.Unlock()
			if ok {
				ch <- reply{ok: msg.Command == "response", data: msg.Data}
			}
		case "ping":
			now := time.Now().UnixMilli()
			resp, _ := json.Marshal(map[string]int64{"timestamp": now})
			go func(id int64) {
				if id != 0 {
					_ = c.writeJSON(c.ctx, wsMessage{ID: id, Command: "response", Data: resp})
				}
			}(msg.ID)
		default:
			log.Info("unknown command from bridge", "bridge", c.id, "command", msg.Command)
			if msg.ID != 0 {
				errData, _ := json.Marshal(map[string]string{"message": "unknown command"})
				go func(id int64) { _ = c.writeJSON(c.ctx, wsMessage{ID: id, Command: "error", Data: errData}) }(msg.ID)
			}
		}
	}
}

func (c *bridgeConn) keepalive(interval time.Duration, log *slog.Logger) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(c.ctx, interval/2+5*time.Second)
			err := c.ws.Ping(ctx)
			cancel()
			if err != nil && c.ctx.Err() == nil {
				log.Info("keepalive failed, dropping connection", "bridge", c.id)
				c.close(websocket.StatusGoingAway, "keepalive_timeout")
				return
			}
		}
	}
}
