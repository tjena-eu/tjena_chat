// Signal bridge — wraps go.mau.fi/mautrix-signal/pkg/signalmeow.
// Pure on-device: no homeserver, no appservice, no server contact beyond
// Signal's own CDN/chat servers.
package signal

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-signal/pkg/signalmeow"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/events"
	signalpb "go.mau.fi/mautrix-signal/pkg/signalmeow/protobuf"
	"go.mau.fi/mautrix-signal/pkg/signalmeow/store"
	stypes "go.mau.fi/mautrix-signal/pkg/signalmeow/types"
	"go.mau.fi/util/dbutil"

	// CGo path injection — sets -L flag for libsignal_ffi.a per ABI.
	_ "tjena.eu/tjena-bridge/internal/signalinit"

	// SQLite driver (same as WA bridge).
	_ "github.com/ncruces/go-sqlite3/driver"
	_ "github.com/ncruces/go-sqlite3/embed"

	"tjena.eu/tjena-bridge/internal/emitter"
)

// Bridge coordinates the Signal connection and emits events to Dart.
type Bridge struct {
	mu      sync.Mutex
	dataDir string
	em      *emitter.Emitter

	container *store.Container
	client    *signalmeow.Client

	linked    bool
	connected bool
	phone     string

	cancelConnect context.CancelFunc
	cancelQR      context.CancelFunc

	knownRooms map[string]bool
	roomsMu    sync.Mutex

	logMu  sync.Mutex
	logBuf []string
}

// New creates a Bridge for the given data directory.
func New(dataDir string, em *emitter.Emitter) (*Bridge, error) {
	return &Bridge{
		dataDir:    dataDir,
		em:         em,
		knownRooms: make(map[string]bool),
	}, nil
}

func (b *Bridge) appendLog(line string) {
	log.Println("[Signal] " + line)
	b.logMu.Lock()
	b.logBuf = append(b.logBuf, line)
	if len(b.logBuf) > 100 {
		b.logBuf = b.logBuf[len(b.logBuf)-100:]
	}
	b.logMu.Unlock()
}

// GetLogs returns recent log lines.
func (b *Bridge) GetLogs() string {
	b.logMu.Lock()
	defer b.logMu.Unlock()
	out := make([]byte, 0, 4096)
	for _, l := range b.logBuf {
		out = append(out, l...)
		out = append(out, '\n')
	}
	return string(out)
}

// Start opens the store and connects if a device is already provisioned.
func (b *Bridge) Start(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.container != nil {
		return nil
	}

	if err := os.MkdirAll(b.dataDir, 0o700); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	dbPath := b.dataDir + "/signal.db"
	sqlDB, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return fmt.Errorf("open signal.db: %w", err)
	}
	sqlDB.SetMaxOpenConns(1)

	db, err := dbutil.NewWithDB(sqlDB, "sqlite3")
	if err != nil {
		return fmt.Errorf("dbutil wrap: %w", err)
	}

	logger := zerolog.Nop()
	container := store.NewStore(db, dbutil.ZeroLogger(logger))
	if err := container.Upgrade(ctx); err != nil {
		return fmt.Errorf("db upgrade: %w", err)
	}
	b.container = container

	devices, err := container.GetAllDevices(ctx)
	if err != nil {
		return fmt.Errorf("get devices: %w", err)
	}
	if len(devices) > 0 {
		go b.connectDevice(devices[0])
	}
	return nil
}

// Stop disconnects.
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancelConnect != nil {
		b.cancelConnect()
		b.cancelConnect = nil
	}
	b.client = nil
	b.linked = false
	b.connected = false
}

// GetStateJSON returns the bridge state as JSON.
func (b *Bridge) GetStateJSON() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	m := map[string]any{
		"linked":    b.linked,
		"connected": b.connected,
		"phone":     b.phone,
	}
	data, _ := json.Marshal(m)
	return string(data)
}

// RequestQRLink starts async provisioning; emits signal_qr events with the URL.
func (b *Bridge) RequestQRLink() error {
	b.mu.Lock()
	container := b.container
	if b.cancelQR != nil {
		b.cancelQR()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	b.cancelQR = cancel
	b.mu.Unlock()

	if container == nil {
		return fmt.Errorf("signal bridge not started")
	}

	go func() {
		defer cancel()
		ch := signalmeow.PerformProvisioning(ctx, container, "Tjena", false)
		for resp := range ch {
			switch resp.State {
			case signalmeow.StateProvisioningURLReceived:
				b.appendLog("Signal QR URL ready")
				b.em.Emit(map[string]any{
					"type":  "signal_qr",
					"url":   resp.ProvisioningURL,
					"error": "",
				})
			case signalmeow.StateProvisioningDataReceived:
				b.appendLog("Signal provisioning complete — saving device")
				if err := container.PutDevice(ctx, resp.ProvisioningData); err != nil {
					b.appendLog("PutDevice error: " + err.Error())
					b.em.Emit(map[string]any{
						"type":  "signal_qr",
						"url":   "",
						"error": err.Error(),
					})
					return
				}
				devices, err := container.GetAllDevices(ctx)
				if err != nil || len(devices) == 0 {
					b.appendLog("GetAllDevices after provision: no device found")
					return
				}
				b.em.Emit(map[string]any{
					"type":  "signal_linked",
					"phone": devices[0].Number,
				})
				go b.connectDevice(devices[0])
			case signalmeow.StateProvisioningError:
				b.appendLog("Provisioning error: " + resp.Err.Error())
				b.em.Emit(map[string]any{
					"type":  "signal_qr",
					"url":   "",
					"error": resp.Err.Error(),
				})
			}
		}
	}()
	return nil
}

func (b *Bridge) connectDevice(device *store.Device) {
	b.mu.Lock()
	if b.cancelConnect != nil {
		b.cancelConnect()
	}
	ctx, cancel := context.WithCancel(context.Background())
	b.cancelConnect = cancel

	logger := zerolog.Nop()
	cli := signalmeow.NewClient(device, logger, b.handleEvent)
	b.client = cli
	b.linked = true
	b.phone = device.Number
	b.mu.Unlock()

	b.appendLog("Connecting to Signal…")
	statusChan, err := cli.StartReceiveLoops(ctx)
	if err != nil {
		b.appendLog("StartReceiveLoops error: " + err.Error())
		b.emitState()
		return
	}

	b.emitState()
	go func() {
		for status := range statusChan {
			switch status.Event {
			case signalmeow.SignalConnectionEventConnected:
				b.appendLog("Signal connected")
				b.mu.Lock()
				b.connected = true
				b.mu.Unlock()
				b.emitState()
				go b.seedContactsOnConnect()
			case signalmeow.SignalConnectionEventDisconnected:
				b.appendLog("Signal disconnected")
				b.mu.Lock()
				b.connected = false
				b.mu.Unlock()
				b.emitState()
			case signalmeow.SignalConnectionEventLoggedOut:
				b.appendLog("Signal logged out")
				b.mu.Lock()
				b.connected = false
				b.linked = false
				b.mu.Unlock()
				b.emitState()
			}
		}
	}()
}

func (b *Bridge) emitState() {
	b.mu.Lock()
	linked := b.linked
	connected := b.connected
	phone := b.phone
	b.mu.Unlock()
	b.em.Emit(map[string]any{
		"type":      "signal_state",
		"linked":    linked,
		"connected": connected,
		"phone":     phone,
	})
}

// Logout unlinks the Signal account.
func (b *Bridge) Logout() error {
	b.mu.Lock()
	cli := b.client
	b.mu.Unlock()
	if cli == nil {
		return fmt.Errorf("not connected")
	}
	if err := cli.Unlink(context.Background()); err != nil {
		return err
	}
	b.Stop()
	b.emitState()
	return nil
}

// ManualSync refreshes contacts from the local store.
func (b *Bridge) ManualSync() error {
	b.mu.Lock()
	connected := b.connected
	b.mu.Unlock()
	if !connected {
		return fmt.Errorf("not connected to Signal")
	}
	go b.seedContactsOnConnect()
	return nil
}

// SyncRoom refreshes name/avatar for a single Signal chat.
func (b *Bridge) SyncRoom(chatID string) error {
	b.mu.Lock()
	cli := b.client
	connected := b.connected
	b.mu.Unlock()
	if !connected || cli == nil {
		return fmt.Errorf("not connected to Signal")
	}
	go b.refreshRoomName(chatID, cli)
	return nil
}

// ClearPersistedRooms deletes signal_rooms.json and resets the room map.
func (b *Bridge) ClearPersistedRooms() {
	b.roomsMu.Lock()
	_ = os.Remove(b.roomsFilePath())
	b.roomsMu.Unlock()
	b.mu.Lock()
	b.knownRooms = make(map[string]bool)
	b.mu.Unlock()
}

// ---- rooms ----

func (b *Bridge) roomsFilePath() string { return b.dataDir + "/signal_rooms.json" }

type persistedRoom struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	IsDM bool   `json:"is_dm"`
}

func isGroupChatID(id string) bool {
	_, err := uuid.Parse(id)
	return err != nil // not a UUID → must be a group identifier
}

func (b *Bridge) ensureRoom(roomID, name string, isDM bool) {
	b.mu.Lock()
	already := b.knownRooms[roomID]
	if !already {
		b.knownRooms[roomID] = true
	}
	b.mu.Unlock()

	if already {
		return
	}

	b.em.Emit(map[string]any{
		"type": "signal_room_created",
		"room": map[string]any{
			"id": roomID, "name": name, "is_dm": isDM,
		},
	})
	b.saveRoomToDisk(roomID, name, isDM)
}

func (b *Bridge) saveRoomToDisk(id, name string, isDM bool) {
	b.roomsMu.Lock()
	defer b.roomsMu.Unlock()
	var rooms []persistedRoom
	if data, err := os.ReadFile(b.roomsFilePath()); err == nil {
		_ = json.Unmarshal(data, &rooms)
	}
	for _, r := range rooms {
		if r.ID == id {
			return
		}
	}
	rooms = append(rooms, persistedRoom{ID: id, Name: name, IsDM: isDM})
	data, _ := json.Marshal(rooms)
	_ = os.WriteFile(b.roomsFilePath(), data, 0o644)
}

func (b *Bridge) loadPersistedRooms() {
	b.roomsMu.Lock()
	data, err := os.ReadFile(b.roomsFilePath())
	b.roomsMu.Unlock()
	if err != nil {
		return
	}
	var rooms []persistedRoom
	if err := json.Unmarshal(data, &rooms); err != nil {
		return
	}
	b.mu.Lock()
	cli := b.client
	b.mu.Unlock()
	for _, r := range rooms {
		b.mu.Lock()
		already := b.knownRooms[r.ID]
		if !already {
			b.knownRooms[r.ID] = true
		}
		b.mu.Unlock()
		if already {
			continue
		}
		b.em.Emit(map[string]any{
			"type": "signal_room_created",
			"room": map[string]any{
				"id": r.ID, "name": r.Name, "is_dm": r.IsDM,
			},
		})
		go b.refreshRoomName(r.ID, cli)
	}
}

func (b *Bridge) seedContactsOnConnect() {
	b.loadPersistedRooms()
	b.mu.Lock()
	cli := b.client
	b.mu.Unlock()
	if cli == nil {
		return
	}
	ctx := context.Background()
	contacts, err := cli.Store.RecipientStore.LoadAllContacts(ctx)
	if err != nil {
		b.appendLog("LoadAllContacts error: " + err.Error())
		return
	}
	for _, r := range contacts {
		if r.ACI == uuid.Nil {
			continue
		}
		name := bestName(r)
		if name == "" {
			continue
		}
		b.ensureRoom(r.ACI.String(), name, true)
	}
}

func bestName(r *stypes.Recipient) string {
	if r == nil {
		return ""
	}
	if r.ContactName != "" {
		return r.ContactName
	}
	if r.Nickname != "" {
		return r.Nickname
	}
	if r.Profile.Name != "" {
		return r.Profile.Name
	}
	return r.E164
}

func (b *Bridge) refreshRoomName(chatID string, cli *signalmeow.Client) {
	if cli == nil {
		return
	}
	ctx := context.Background()
	aci, err := uuid.Parse(chatID)
	if err != nil {
		return // groups handled separately
	}
	r, err := cli.Store.RecipientStore.LoadAndUpdateRecipient(ctx, aci, uuid.Nil, nil)
	if err != nil || r == nil {
		return
	}
	name := bestName(r)
	if name != "" {
		b.em.Emit(map[string]any{"type": "signal_room_updated", "room_id": chatID, "name": name})
		b.updateRoomNameOnDisk(chatID, name)
	}
	if r.Profile.AvatarPath != "" {
		go func() {
			data, err := cli.DownloadUserAvatar(ctx, r.Profile.AvatarPath, r.Profile.Key)
			if err == nil && len(data) > 0 {
				b.em.Emit(map[string]any{
					"type":         "signal_room_updated",
					"room_id":      chatID,
					"avatar_bytes": data,
				})
			}
		}()
	}
}

func (b *Bridge) updateRoomNameOnDisk(id, name string) {
	b.roomsMu.Lock()
	defer b.roomsMu.Unlock()
	data, err := os.ReadFile(b.roomsFilePath())
	if err != nil {
		return
	}
	var rooms []persistedRoom
	if err := json.Unmarshal(data, &rooms); err != nil {
		return
	}
	for i, r := range rooms {
		if r.ID == id {
			rooms[i].Name = name
			data, _ = json.Marshal(rooms)
			_ = os.WriteFile(b.roomsFilePath(), data, 0o644)
			return
		}
	}
}

// ---- event handler ----

func (b *Bridge) handleEvent(evt events.SignalEvent) bool {
	switch e := evt.(type) {
	case *events.ChatEvent:
		b.handleChatEvent(e)
	case *events.ContactList:
		go b.handleContactList(e)
	case *events.LoggedOut:
		msg := "unknown"
		if e.Error != nil {
			msg = e.Error.Error()
		}
		b.appendLog("Signal logged out: " + msg)
		b.mu.Lock()
		b.linked = false
		b.connected = false
		b.mu.Unlock()
		b.emitState()
	case *events.Receipt:
		// Ignored for now.
	case *events.QueueEmpty:
		b.appendLog("Signal initial sync done")
	}
	return true
}

func (b *Bridge) handleContactList(e *events.ContactList) {
	b.mu.Lock()
	cli := b.client
	b.mu.Unlock()
	for _, r := range e.Contacts {
		if r.ACI == uuid.Nil {
			continue
		}
		name := bestName(r)
		if name == "" {
			name = r.E164
		}
		if name == "" {
			continue
		}
		roomID := r.ACI.String()
		b.ensureRoom(roomID, name, true)
		go b.refreshRoomName(roomID, cli)
	}
}

func (b *Bridge) handleChatEvent(e *events.ChatEvent) {
	senderID := e.Info.Sender.String()
	chatID := e.Info.ChatID
	if chatID == "" {
		chatID = senderID
	}
	ts := e.Info.ServerTimestamp
	if ts == 0 {
		ts = uint64(time.Now().UnixMilli())
	}

	switch msg := e.Event.(type) {
	case *signalpb.DataMessage:
		isGroup := isGroupChatID(chatID)
		b.handleDataMessage(chatID, senderID, ts, msg, isGroup)
	case *signalpb.TypingMessage:
		b.em.Emit(map[string]any{
			"type":    "signal_typing",
			"room_id": chatID,
			"sender":  senderID,
			"typing":  msg.GetAction() == signalpb.TypingMessage_STARTED,
		})
	case *signalpb.EditMessage:
		if dm := msg.GetDataMessage(); dm != nil {
			b.em.Emit(map[string]any{
				"type":      "signal_edit",
				"room_id":   chatID,
				"sender":    senderID,
				"ts":        ts,
				"target_ts": msg.GetTargetSentTimestamp(),
				"body":      dm.GetBody(),
			})
		}
	}
}

func (b *Bridge) handleDataMessage(chatID, senderID string, ts uint64, msg *signalpb.DataMessage, isGroup bool) {
	// Resolve display name.
	name := senderID
	b.mu.Lock()
	cli := b.client
	b.mu.Unlock()
	if !isGroup {
		if aci, err := uuid.Parse(senderID); err == nil && cli != nil {
			if r, err := cli.Store.RecipientStore.LoadAndUpdateRecipient(context.Background(), aci, uuid.Nil, nil); err == nil && r != nil {
				if n := bestName(r); n != "" {
					name = n
				}
			}
		}
	}

	b.ensureRoom(chatID, name, !isGroup)
	if isGroup && senderID != chatID {
		b.ensureRoom(senderID, senderID, true)
	}

	// Reaction.
	if react := msg.GetReaction(); react != nil {
		b.em.Emit(map[string]any{
			"type":      "signal_reaction",
			"room_id":   chatID,
			"sender":    senderID,
			"ts":        ts,
			"emoji":     react.GetEmoji(),
			"target_ts": react.GetTargetSentTimestamp(),
		})
		return
	}

	// Delete.
	if del := msg.GetDelete(); del != nil {
		b.em.Emit(map[string]any{
			"type":      "signal_redaction",
			"room_id":   chatID,
			"sender":    senderID,
			"ts":        ts,
			"target_ts": del.GetTargetSentTimestamp(),
		})
		return
	}

	// Quote (reply).
	quoteID := ""
	if q := msg.GetQuote(); q != nil {
		quoteID = fmt.Sprintf("%d", q.GetId())
	}

	body := msg.GetBody()
	msgtype := "m.text"
	var mediaPtr *signalpb.AttachmentPointer

	if len(msg.GetAttachments()) > 0 {
		att := msg.GetAttachments()[0]
		ct := att.GetContentType()
		switch {
		case len(ct) > 6 && ct[:6] == "image/":
			msgtype = "m.image"
		case len(ct) > 6 && ct[:6] == "video/":
			msgtype = "m.video"
		case len(ct) > 6 && ct[:6] == "audio/":
			msgtype = "m.audio"
		default:
			msgtype = "m.file"
		}
		if body == "" {
			body = att.GetFileName()
			if body == "" {
				body = msgtype[2:]
			}
		}
		mediaPtr = att
	}

	if body == "" && msgtype == "m.text" {
		return
	}

	eventID := fmt.Sprintf("$sig-%d-%s", ts, senderID)
	if len(eventID) > 50 {
		eventID = eventID[:50]
	}
	evt := map[string]any{
		"type":     "signal_message",
		"room_id":  chatID,
		"event_id": eventID,
		"sender":   senderID,
		"ts":       ts,
		"body":     body,
		"msgtype":  msgtype,
		"is_group": isGroup,
		"quote_id": quoteID,
	}
	if mediaPtr == nil {
		b.em.Emit(evt)
	} else {
		go func(ptr *signalpb.AttachmentPointer) {
			ctx := context.Background()
			data, err := signalmeow.DownloadAttachmentWithPointer(ctx, ptr, nil, nil)
			if err != nil {
				b.appendLog(fmt.Sprintf("attachment download error: %v", err))
				b.em.Emit(evt)
				return
			}
			ext := extForMime(ptr.GetContentType())
			_ = os.MkdirAll(b.dataDir+"/signal_media", 0o700)
			mediaPath := b.dataDir + "/signal_media/" + eventID[1:] + ext
			if werr := os.WriteFile(mediaPath, data, 0o644); werr != nil {
				b.em.Emit(evt)
				return
			}
			b.em.Emit(map[string]any{
				"type":      "signal_media_ready",
				"room_id":   chatID,
				"event_id":  eventID,
				"file_path": mediaPath,
				"mime_type": ptr.GetContentType(),
				"size":      len(data),
			})
		}(mediaPtr)
	}
}

func extForMime(ct string) string {
	switch ct {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/gif":
		return ".gif"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "audio/aac":
		return ".aac"
	case "audio/ogg", "audio/ogg; codecs=opus":
		return ".ogg"
	case "audio/mpeg":
		return ".mp3"
	default:
		return ".bin"
	}
}
