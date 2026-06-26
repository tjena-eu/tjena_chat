package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"log"
	"net"
	"net/http"
	"sort"
	"strings"
	"os"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	waevents "go.mau.fi/whatsmeow/types/events"
	walog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	"github.com/skip2/go-qrcode"

	// driver registers the "sqlite3" database/sql driver.
	// embed loads the SQLite WASM binary (required — without it the driver panics).
	_ "github.com/ncruces/go-sqlite3/driver"
	_ "github.com/ncruces/go-sqlite3/embed"

	"tjena.eu/tjena-bridge/internal/emitter"
	"tjena.eu/tjena-bridge/internal/localmatrix"
)

// Bridge is the top-level coordinator. It owns:
//   - a whatsmeow client (P0)
//   - a localmatrix connector (P1/P2)
//   - the event emitter (all phases)
type Bridge struct {
	mu      sync.Mutex
	dataDir string

	emitter *emitter.Emitter
	st      *localmatrix.LocalStore
	conn    *localmatrix.LocalConnector

	waClient  *whatsmeow.Client
	waStore   *sqlstore.Container

	linked    bool
	connected bool
	phone     string
	pushName  string

	cancelQR     context.CancelFunc
	pairingPhone bool // true while phone-link handshake is in progress
	dnsDialer    *dnsCachingDialer

	knownRooms  map[string]bool   // JID room IDs we've already emitted room_created for
	goodNames   map[string]bool   // rooms whose name is a real name (not a bare number)

	// On-demand backfill state. oldestMsg tracks the oldest message info we have
	// per chat (the anchor for the next history request); backfillCutoff is the
	// unix-seconds target a chat is currently backfilling towards (continue
	// requesting older batches until the oldest message predates it).
	oldestMsg      map[string]*types.MessageInfo
	backfillCutoff map[string]int64

	// Last incoming (not own) message per chat, used to send WhatsApp read
	// receipts when the user reads the chat in Tjena.
	lastRecv map[string]*types.MessageInfo

	// On-demand server history requests in flight, keyed by room ID. When a chat
	// is backfilled but the local cache doesn't cover the requested window, we
	// ask WhatsApp's primary device for older messages and keep paginating (on
	// each ON_DEMAND HistorySync reply) until we reach the target or run out.
	pendingHist map[string]*histReq

	logMu  sync.Mutex
	logBuf []string // ring buffer, last 100 lines
}

func (b *Bridge) appendLog(line string) {
	log.Println(line)
	b.logMu.Lock()
	b.logBuf = append(b.logBuf, line)
	if len(b.logBuf) > 100 {
		b.logBuf = b.logBuf[len(b.logBuf)-100:]
	}
	b.logMu.Unlock()
}

// bridgeLogger implements walog.Logger and captures to the ring buffer.
type bridgeLogger struct {
	prefix string
	br     *Bridge
}

func (l *bridgeLogger) Debugf(msg string, args ...any) {
	l.br.appendLog(fmt.Sprintf("[%s DEBUG] "+msg, append([]any{l.prefix}, args...)...))
}
func (l *bridgeLogger) Infof(msg string, args ...any) {
	l.br.appendLog(fmt.Sprintf("[%s INFO] "+msg, append([]any{l.prefix}, args...)...))
}
func (l *bridgeLogger) Warnf(msg string, args ...any) {
	l.br.appendLog(fmt.Sprintf("[%s WARN] "+msg, append([]any{l.prefix}, args...)...))
}
func (l *bridgeLogger) Errorf(msg string, args ...any) {
	l.br.appendLog(fmt.Sprintf("[%s ERROR] "+msg, append([]any{l.prefix}, args...)...))
}

func (l *bridgeLogger) Sub(tag string) walog.Logger {
	return &bridgeLogger{prefix: l.prefix + "/" + tag, br: l.br}
}

// setDeviceProps configures the global whatsmeow client identity to look like a
// standard Chrome desktop WhatsApp Web client, consistent with the PairPhone
// call (PairClientChrome / "Chrome (Linux)"). The whatsmeow store globals are
// read when the registration/client payload is built at connect time, so this
// must run before the client connects.
func setDeviceProps() {
	// Sets DeviceProps.Os and the client UserAgent OsVersion/OsBuildNumber.
	store.SetOSInfo("Chrome", [3]uint32{120, 0, 6099})
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	// Request a LARGE history sync at link time. WhatsApp sends history to a new
	// companion based on these limits, so this is the reliable way to get older
	// messages into the local cache (the on-demand request path isn't supported
	// by all primary devices). Takes effect on the next (re-)link.
	store.DeviceProps.RequireFullSync = proto.Bool(true)
	store.DeviceProps.HistorySyncConfig = &waCompanionReg.DeviceProps_HistorySyncConfig{
		FullSyncDaysLimit:   proto.Uint32(3650),
		FullSyncSizeMbLimit: proto.Uint32(2048),
		StorageQuotaMb:      proto.Uint32(2048),
		// Tell WhatsApp we can take group message history too; without this the
		// initial sync gives groups only a few days.
		SupportGroupHistory: proto.Bool(true),
	}
}

// dnsCachingDialer resolves hostnames and caches the results.
// On subsequent calls, if live DNS fails it falls back to the cached IPs.
// This handles the brief DNS outage Android experiences after a hard TCP abort.
type dnsCachingDialer struct {
	mu    sync.Mutex
	cache map[string][]string // hostname → last-good IPs
}

func newDNSCachingDialer() *dnsCachingDialer {
	return &dnsCachingDialer{cache: make(map[string][]string)}
}

func (d *dnsCachingDialer) dialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}

	ips, dnsErr := net.DefaultResolver.LookupHost(ctx, host)
	if dnsErr == nil && len(ips) > 0 {
		d.mu.Lock()
		d.cache[host] = ips
		d.mu.Unlock()
	} else {
		d.mu.Lock()
		ips = d.cache[host]
		d.mu.Unlock()
		if len(ips) == 0 {
			return nil, dnsErr
		}
		log.Printf("[Bridge WARN] DNS failed for %s, using cached IPs: %v", host, ips)
	}

	dialer := &net.Dialer{}
	var lastErr error
	for _, ip := range ips {
		conn, connErr := dialer.DialContext(ctx, network, net.JoinHostPort(ip, port))
		if connErr == nil {
			return conn, nil
		}
		lastErr = connErr
	}
	return nil, lastErr
}

// newDNSCachingHTTPClient returns an *http.Client whose transport uses the
// caching dialer, cloned from the default transport to preserve TLS settings.
func newDNSCachingHTTPClient(d *dnsCachingDialer) *http.Client {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DialContext = d.dialContext
	return &http.Client{Transport: t}
}

// GetLogs returns the last N bridge log lines as a newline-separated string.
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

// New creates a Bridge for the given data directory.
func New(dataDir string, em *emitter.Emitter) (*Bridge, error) {
	b := &Bridge{
		dataDir: dataDir,
		emitter: em,
	}
	return b, nil
}

// Start opens stores, connects whatsmeow, and starts the bridge.
func (b *Bridge) Start(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if err := os.MkdirAll(b.dataDir, 0o755); err != nil {
		return fmt.Errorf("create data dir: %w", err)
	}

	// Open local event/room store.
	st, err := localmatrix.OpenLocalStore(b.dataDir + "/local.db")
	if err != nil {
		return fmt.Errorf("open local store: %w", err)
	}
	b.st = st

	// Advertise a consistent Chrome-on-desktop companion identity. whatsmeow's
	// defaults (Os "whatsmeow", PlatformType UNKNOWN) are inconsistent with the
	// "Chrome (Linux)" / PairClientChrome identity we present during pairing;
	// mismatched device props are a plausible reason the WA server treats the
	// companion registration differently. This mirrors how mautrix-whatsapp
	// configures the store before connecting.
	setDeviceProps()

	// Open whatsmeow device store.
	storeLog := &bridgeLogger{prefix: "WA-Store", br: b}
	container, err := sqlstore.New(ctx, "sqlite3",
		"file:"+b.dataDir+"/whatsmeow.db?_foreign_keys=on&_journal_mode=WAL", storeLog)
	if err != nil {
		return fmt.Errorf("open whatsmeow store: %w", err)
	}
	b.waStore = container

	// Get or create device. A corrupted store ("database disk image is
	// malformed") makes this fail; recover by wiping the store files so the user
	// can re-link instead of the bridge failing to start entirely.
	deviceStore, err := container.GetFirstDevice(ctx)
	if err != nil {
		b.appendLog("[Bridge] whatsmeow store unusable (" + err.Error() + "); resetting it for a fresh link")
		deviceStore, err = b.freshDevice(ctx)
		if err != nil {
			return fmt.Errorf("get device after store reset: %w", err)
		}
	}
	b.linked = deviceStore.ID != nil

	// Create localmatrix connector.
	b.conn = localmatrix.NewConnector(st, b.emitter)

	// Create whatsmeow client. Use stock whatsmeow networking (no custom
	// pre-login HTTP client) so the on-device socket path is byte-for-byte
	// identical to the server-side mautrix-whatsapp setup that works.
	clientLog := &bridgeLogger{prefix: "WA-Client", br: b}
	b.waClient = whatsmeow.NewClient(deviceStore, clientLog)
	b.waClient.AddEventHandler(b.handleWAEvent)

	// Connect if already linked.
	if b.linked {
		if err := b.waClient.Connect(); err != nil {
			// Non-fatal — bridge is still usable for QR re-link.
			b.emitter.Emit(map[string]any{
				"type":   "state",
				"linked": true, "connected": false,
				"reason": err.Error(),
			})
		}
	}

	return nil
}

// Stop disconnects gracefully.
func (b *Bridge) Stop() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancelQR != nil {
		b.cancelQR()
		b.cancelQR = nil
	}
	if b.waClient != nil {
		b.waClient.Disconnect()
	}
	if b.st != nil {
		_ = b.st.Close()
	}
}

// GetStateJSON returns the current bridge state as a JSON string.
func (b *Bridge) GetStateJSON() string {
	b.mu.Lock()
	linked := b.linked
	connected := b.connected
	phone := b.phone
	pushName := b.pushName
	client := b.waClient
	b.mu.Unlock()

	// If we don't have the phone cached yet (linked but not connected this
	// session), derive it from the linked device's JID so the UI can always show
	// which account this is.
	if phone == "" && client != nil && client.Store != nil && client.Store.ID != nil {
		phone = "+" + client.Store.ID.User
	}

	m := map[string]any{
		"linked":    linked,
		"connected": connected,
		"phone":     phone,
		"push_name": pushName,
	}
	data, _ := json.Marshal(m)
	return string(data)
}

// RequestQRLink starts an async QR linking flow.
func (b *Bridge) RequestQRLink() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.waClient == nil {
		return fmt.Errorf("bridge not started")
	}
	if b.linked {
		return fmt.Errorf("already linked")
	}

	// Cancel any previous QR session.
	if b.cancelQR != nil {
		b.cancelQR()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	b.cancelQR = cancel

	qrCh, err := b.waClient.GetQRChannel(ctx)
	if err != nil {
		cancel()
		b.cancelQR = nil
		return err
	}

	// Connect must be called immediately after GetQRChannel so whatsmeow
	// starts the handshake and begins emitting QR codes to the channel.
	if !b.waClient.IsConnected() {
		if err := b.waClient.Connect(); err != nil {
			cancel()
			b.cancelQR = nil
			return err
		}
	}

	go func() {
		defer cancel()
		for evt := range qrCh {
			switch evt.Event {
			case "code":
				png, pngErr := qrcode.Encode(evt.Code, qrcode.Medium, 256)
				if pngErr != nil {
					b.emitter.Emit(map[string]any{
						"type":  "error",
						"error": "QR encode failed: " + pngErr.Error(),
					})
					continue
				}
				b.emitter.Emit(map[string]any{
					"type": "qr",
					"data": base64.StdEncoding.EncodeToString(png),
				})
			case "success":
				// PairSuccess event will follow via handleWAEvent.
			case "timeout":
				b.emitter.Emit(map[string]any{
					"type":  "error",
					"error": "QR timed out — tap refresh to try again",
				})
			}
		}
	}()
	return nil
}

// RequestPhoneLink requests a pairing code for phone-number linking.
func (b *Bridge) RequestPhoneLink(phone string) error {
	b.mu.Lock()
	client := b.waClient
	linked := b.linked
	if b.cancelQR != nil {
		b.cancelQR()
		b.cancelQR = nil
	}
	b.mu.Unlock()

	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	if linked {
		return fmt.Errorf("already linked")
	}

	if !client.IsConnected() {
		if err := client.Connect(); err != nil {
			return err
		}
	}

	b.mu.Lock()
	b.pairingPhone = true
	// Clear any AdvSecretKey left over from a previous pairing attempt so the
	// reconnect logic can tell which stage THIS session reached (an aborted
	// companion_hello vs. an aborted companion_finish) rather than reading a
	// stale value and falsely reporting "pairing lost".
	client.Store.AdvSecretKey = nil
	b.mu.Unlock()

	// PairPhone is a blocking network call — must not hold mu.
	// After returning the code, the WA server intentionally disconnects the companion.
	// The Disconnected handler will reconnect automatically while pairingPhone is true
	// so we can receive the link_code_companion_reg notification.
	code, err := client.PairPhone(context.Background(), phone, true,
		whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		b.mu.Lock()
		b.pairingPhone = false
		b.mu.Unlock()
		return err
	}
	b.emitter.Emit(map[string]any{
		"type": "phone_code",
		"code": code,
	})
	return nil
}

// ConfirmPhoneLink is a no-op — phone linking completes automatically.
func (b *Bridge) ConfirmPhoneLink(_ string) error { return nil }

// SendText sends a text message through WhatsApp.
func (b *Bridge) SendText(portalID, _ string, text string) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return err
	}
	_, err = client.SendMessage(context.Background(), jid,
		&waE2E.Message{Conversation: proto.String(text)})
	return err
}

// SendMedia uploads a file/image/video/audio and sends it through WhatsApp.
func (b *Bridge) SendMedia(portalID, _ string, mimeType string, data []byte) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return err
	}

	var mediaType whatsmeow.MediaType
	switch {
	case strings.HasPrefix(mimeType, "image/"):
		mediaType = whatsmeow.MediaImage
	case strings.HasPrefix(mimeType, "video/"):
		mediaType = whatsmeow.MediaVideo
	case strings.HasPrefix(mimeType, "audio/"):
		mediaType = whatsmeow.MediaAudio
	default:
		mediaType = whatsmeow.MediaDocument
	}

	up, err := client.Upload(context.Background(), data, mediaType)
	if err != nil {
		return fmt.Errorf("upload failed: %w", err)
	}

	var msg *waE2E.Message
	size := uint64(len(data))
	switch mediaType {
	case whatsmeow.MediaImage:
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size),
		}}
	case whatsmeow.MediaVideo:
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size),
		}}
	case whatsmeow.MediaAudio:
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size),
		}}
	default:
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size),
		}}
	}

	_, err = client.SendMessage(context.Background(), jid, msg)
	return err
}

// SendLocation sends a location message through WhatsApp.
func (b *Bridge) SendLocation(portalID string, lat, lon float64) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return err
	}
	_, err = client.SendMessage(context.Background(), jid, &waE2E.Message{
		LocationMessage: &waE2E.LocationMessage{
			DegreesLatitude:  proto.Float64(lat),
			DegreesLongitude: proto.Float64(lon),
			IsLive:           proto.Bool(false),
		},
	})
	return err
}

// SendReaction sends a reaction through WhatsApp.
func (b *Bridge) SendReaction(portalID, targetEventID, emoji string) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return err
	}
	reaction := client.BuildReaction(jid, jid, targetEventID, emoji)
	_, err = client.SendMessage(context.Background(), jid, reaction)
	return err
}

// SendRedaction retracts a message.
func (b *Bridge) SendRedaction(portalID, targetEventID string) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not started")
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return err
	}
	retract := client.BuildRevoke(jid, jid, targetEventID)
	_, err = client.SendMessage(context.Background(), jid, retract)
	return err
}

// MarkRead sends a WhatsApp read receipt for the chat's latest incoming
// message, so the sender sees blue ticks. portalID is the WA chat JID.
func (b *Bridge) MarkRead(portalID, _ string) error {
	b.mu.Lock()
	client := b.waClient
	last := b.lastRecv[portalID]
	b.mu.Unlock()
	if client == nil || last == nil {
		return nil
	}
	sender := last.Sender
	if sender.IsEmpty() {
		sender = last.Chat
	}
	return client.MarkRead(
		context.Background(),
		[]types.MessageID{last.ID},
		time.Now(),
		last.Chat,
		sender,
	)
}

// SetTyping sends a typing presence update.
func (b *Bridge) SetTyping(portalID string, typing bool) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return nil
	}
	jid, err := types.ParseJID(portalID)
	if err != nil {
		return nil
	}
	if typing {
		return client.SendChatPresence(context.Background(), jid,
			types.ChatPresenceComposing, types.ChatPresenceMediaText)
	}
	return client.SendChatPresence(context.Background(), jid,
		types.ChatPresencePaused, types.ChatPresenceMediaText)
}

// freshDevice tears down the whatsmeow store by deleting its SQLite files and
// recreating an empty container with a fresh (unregistered) device. Deleting the
// files — rather than using the store API — is what lets us recover from a
// corrupted store ("sqlite3: database disk image is malformed"), where
// GetAllDevices/Delete/GetFirstDevice themselves fail. The caller must hold b.mu
// and should have disconnected any client first; b.waStore is replaced and the
// returned device should be used to build a new client.
func (b *Bridge) freshDevice(ctx context.Context) (*store.Device, error) {
	if b.waStore != nil {
		_ = b.waStore.Close()
		b.waStore = nil
	}
	base := b.dataDir + "/whatsmeow.db"
	// Remove the DB plus its WAL/SHM/journal sidecars.
	for _, suffix := range []string{"", "-wal", "-shm", "-journal"} {
		_ = os.Remove(base + suffix)
	}
	storeLog := &bridgeLogger{prefix: "WA-Store", br: b}
	container, err := sqlstore.New(ctx, "sqlite3",
		"file:"+base+"?_foreign_keys=on&_journal_mode=WAL", storeLog)
	if err != nil {
		return nil, fmt.Errorf("recreate whatsmeow store: %w", err)
	}
	b.waStore = container
	return container.GetFirstDevice(ctx)
}

// ForceReset deletes all local WhatsApp credentials and prepares for fresh linking.
// Use this when the device store has stale or corrupted credentials that prevent
// re-linking (it deletes the store files, so it recovers even from a malformed DB).
func (b *Bridge) ForceReset() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.waClient != nil {
		b.waClient.Disconnect()
	}

	deviceStore, err := b.freshDevice(context.Background())
	if err != nil {
		return fmt.Errorf("reset whatsmeow store: %w", err)
	}
	clientLog := &bridgeLogger{prefix: "WA-Client", br: b}
	b.waClient = whatsmeow.NewClient(deviceStore, clientLog)
	b.waClient.AddEventHandler(b.handleWAEvent)

	b.linked = false
	b.connected = false
	b.phone = ""
	b.pushName = ""

	b.emitter.Emit(map[string]any{
		"type": "state", "linked": false, "connected": false,
	})
	return nil
}

// Logout unlinks the WhatsApp account.
func (b *Bridge) Logout() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.waClient == nil {
		return nil
	}
	err := b.waClient.Logout(context.Background())
	b.linked = false
	b.connected = false
	b.emitter.Emit(map[string]any{
		"type": "disconnected", "reason": "logged_out",
	})
	return err
}

// OnForeground is called when the app returns to foreground.
// If the WebSocket was dropped while in background, reconnect immediately.
func (b *Bridge) OnForeground() {
	b.mu.Lock()
	client := b.waClient
	linked := b.linked
	b.mu.Unlock()
	if client != nil && linked && !client.IsConnected() {
		go func() {
			if err := client.Connect(); err != nil {
				b.appendLog(fmt.Sprintf("[Bridge] foreground reconnect failed: %v", err))
			}
		}()
	}
}

func (b *Bridge) OnBackground() {}

// autoReconnect retries the WebSocket connection with increasing delays
// after an unexpected disconnect (i.e. not during pairing).
func (b *Bridge) autoReconnect(client *whatsmeow.Client) {
	delays := []time.Duration{3, 7, 15, 30, 60}
	for i, d := range delays {
		time.Sleep(d * time.Second)
		b.mu.Lock()
		linked := b.linked
		b.mu.Unlock()
		if !linked {
			return
		}
		if client.IsConnected() {
			return
		}
		if err := client.Connect(); err != nil {
			b.appendLog(fmt.Sprintf("[Bridge] auto-reconnect attempt %d/%d failed: %v", i+1, len(delays), err))
			continue
		}
		return
	}
	b.appendLog("[Bridge] auto-reconnect exhausted all retries")
}

// --- WhatsApp event handler ---

// phonePairingReconnect handles the WA server's disconnect during phone linking.
//
// The companion goes through three states on a single connection:
//
//	companion_hello → (server issues code, may disconnect)        AdvSecretKey == nil, ID == nil
//	primary_hello + companion_finish (sets AdvSecretKey)          AdvSecretKey != nil, ID == nil
//	pair-success → handlePair (sets Store.ID, confirms to server) ID != nil
//
// pair-success can ONLY be received on the same connection that sent
// companion_finish — reconnecting makes the server offer a fresh pair-device
// (QR), wiping the in-progress phone link. So the reconnect strategy depends on
// which state we were in when the socket died.
func (b *Bridge) phonePairingReconnect(client *whatsmeow.Client) {
	b.mu.Lock()
	stillPairing := b.pairingPhone
	b.mu.Unlock()
	if !stillPairing {
		return
	}

	// State 3: handlePair ran (device saved) but the PairSuccess event was lost
	// because the handler queue closed at the same time. Synthesise linked state.
	if client.Store.ID != nil {
		b.appendLog("[Bridge INFO] Phone pairing: pair-success event lost but device saved — emitting linked")
		b.mu.Lock()
		b.pairingPhone = false
		b.linked = true
		b.phone = "+" + client.Store.ID.User
		if client.Store.PushName != "" {
			b.pushName = client.Store.PushName
		}
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type":      "linked",
			"phone":     "+" + client.Store.ID.User,
			"push_name": client.Store.PushName,
		})
		_ = client.Connect()
		return
	}

	// State 2: companion_finish completed (AdvSecretKey set) but the connection
	// aborted before pair-success arrived. Reconnecting is futile — the server
	// has discarded the link_code session and will only offer a fresh QR. The
	// pairing is unrecoverable; report it so the user can retry with a new code.
	if len(client.Store.AdvSecretKey) > 0 {
		b.appendLog("[Bridge WARN] Phone pairing: connection aborted after companion_finish, before pair-success — pairing lost")
		b.mu.Lock()
		b.pairingPhone = false
		// Clear the half-applied pairing state so the next attempt starts clean.
		client.Store.AdvSecretKey = nil
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type":  "pair_error",
			"error": "Connection dropped at the final step. This is usually a brief network glitch — please request a new code and try again.",
		})
		return
	}

	// State 1: still waiting for the primary_hello notification. The server
	// disconnects ~10 s after issuing the code; reconnect to receive it.
	b.appendLog("[Bridge INFO] Phone pairing: reconnecting to receive pairing notification…")
	if err := client.Connect(); err != nil {
		b.appendLog(fmt.Sprintf("[Bridge ERROR] Reconnect failed: %v", err))
		b.mu.Lock()
		b.pairingPhone = false
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type":  "pair_error",
			"error": "Reconnect failed: " + err.Error(),
		})
	}
}

func (b *Bridge) handleWAEvent(rawEvt any) {
	switch evt := rawEvt.(type) {

	case *waevents.PairSuccess:
		b.mu.Lock()
		b.linked = true
		b.pairingPhone = false
		b.phone = "+" + evt.ID.User
		b.pushName = evt.BusinessName
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type":      "linked",
			"phone":     "+" + evt.ID.User,
			"push_name": evt.BusinessName,
		})

	case *waevents.PairError:
		b.mu.Lock()
		b.pairingPhone = false
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type":  "pair_error",
			"error": evt.Error.Error(),
		})

	case *waevents.Connected:
		b.mu.Lock()
		b.connected = true
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type": "state", "linked": b.linked, "connected": true,
			"phone": b.phone, "push_name": b.pushName,
		})

	case *waevents.Disconnected:
		b.mu.Lock()
		b.connected = false
		pairingPhone := b.pairingPhone
		client := b.waClient
		b.mu.Unlock()
		_ = evt
		b.emitter.Emit(map[string]any{
			"type": "state", "linked": b.linked, "connected": false,
			"reason": "disconnected",
		})
		if pairingPhone && client != nil {
			// Reconnect during phone-link handshake (special retry logic).
			go b.phonePairingReconnect(client)
		} else if client != nil && b.linked {
			// Normal disconnect — reconnect automatically with backoff.
			go b.autoReconnect(client)
		}

	case *waevents.LoggedOut:
		b.mu.Lock()
		b.linked = false
		b.connected = false
		b.pairingPhone = false
		// Automatically purge stale credentials so the next QR attempt starts
		// with a fresh (unregistered) device identity. Without this Connect()
		// reuses the revoked session and WhatsApp immediately closes the
		// WebSocket, killing the QR channel before a code renders. We delete the
		// store files (via freshDevice) rather than using the store API, because
		// a 401 logout often coincides with a corrupted store that the API can't
		// clean up ("failed to delete store after 401 failure: ... malformed").
		if deviceStore, err := b.freshDevice(context.Background()); err == nil {
			clientLog := &bridgeLogger{prefix: "WA-Client", br: b}
			b.waClient = whatsmeow.NewClient(deviceStore, clientLog)
			b.waClient.AddEventHandler(b.handleWAEvent)
		} else {
			b.appendLog("[Bridge] store reset after logout failed: " + err.Error())
		}
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type": "disconnected", "reason": "logged_out",
		})

	case *waevents.Message:
		b.handleWAMessage(evt)

	case *waevents.Receipt:
		b.handleWAReceipt(evt)

	case *waevents.CallOffer:
		b.handleCallOffer(evt)

	case *waevents.Presence:
		b.emitter.Emit(map[string]any{
			"type":      "presence",
			"user_id":   "@wa_" + evt.From.User + ":" + "tjena.local",
			"available": evt.Unavailable == false,
			"last_seen": evt.LastSeen.UnixMilli(),
		})

	case *waevents.ChatPresence:
		typing := evt.State == types.ChatPresenceComposing
		b.emitter.Emit(map[string]any{
			"type":    "typing",
			"room_id": evt.Chat.User + "@" + string(evt.Chat.Server),
			"user_id": "@wa_" + evt.Sender.User + ":tjena.local",
			"typing":  typing,
		})

	case *waevents.PushName:
		// WA sends push-name updates during the initial contact sync. Use them
		// to update any room name that still shows a bare phone number.
		if evt.NewPushName != "" {
			roomID := evt.JID.User + "@" + string(evt.JID.Server)
			b.mu.Lock()
			if b.goodNames == nil {
				b.goodNames = make(map[string]bool)
			}
			b.goodNames[roomID] = true
			b.mu.Unlock()
			b.emitter.Emit(map[string]any{
				"type": "room_updated", "room_id": roomID, "name": evt.NewPushName,
			})
		}

	case *waevents.Contact:
		// Contact list update — refresh name for the matching room.
		name := ""
		if evt.Action != nil {
			if n := evt.Action.GetFullName(); n != "" {
				name = n
			}
		}
		if name != "" {
			roomID := evt.JID.User + "@" + string(evt.JID.Server)
			b.mu.Lock()
			if b.goodNames == nil {
				b.goodNames = make(map[string]bool)
			}
			b.goodNames[roomID] = true
			b.mu.Unlock()
			b.emitter.Emit(map[string]any{
				"type": "room_updated", "room_id": roomID, "name": name,
			})
		}

	case *waevents.AppStateSyncComplete:
		// After regular_low sync completes the local contact DB is fully populated.
		// Scan all contacts and emit room_updated for any room whose name is still
		// a bare phone number (ensureRoom ran before the contacts DB was ready).
		if evt.Name == appstate.WAPatchRegularLow || evt.Name == appstate.WAPatchRegular {
			go b.postConnectNameScan()
		}

	case *waevents.HistorySync:
		go b.handleHistorySync(evt.Data)
	}
}

// postConnectNameScan scans all stored contacts after app-state sync completes
// and emits room_updated for any rooms that still have a bare phone-number name.
// This fixes the case where restart fires ensureRoom before the contacts DB is
// populated, leaving rooms with a phone-number name until the next message.
func (b *Bridge) postConnectNameScan() {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return
	}
	contacts, err := client.Store.Contacts.GetAllContacts(context.Background())
	if err != nil {
		return
	}
	for jid, contact := range contacts {
		if jid.Server != types.DefaultUserServer {
			continue
		}
		var name string
		switch {
		case contact.FullName != "":
			name = contact.FullName
		case contact.PushName != "":
			name = contact.PushName
		case contact.BusinessName != "":
			name = contact.BusinessName
		default:
			continue
		}
		roomID := jid.User + "@" + string(jid.Server)
		b.mu.Lock()
		if b.goodNames == nil {
			b.goodNames = make(map[string]bool)
		}
		alreadyGood := b.goodNames[roomID]
		if !alreadyGood {
			b.goodNames[roomID] = true
		}
		b.mu.Unlock()
		if !alreadyGood {
			b.emitter.Emit(map[string]any{
				"type": "room_updated", "room_id": roomID, "name": name,
			})
		}
	}
}

// callerChatJID maps a call's caller JID to the JID of the contact's existing
// chat room, trying its phone↔LID counterpart, so an incoming-call message
// lands in the existing conversation instead of a new room.
func (b *Bridge) callerChatJID(caller types.JID) types.JID {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()

	cands := []types.JID{caller}
	if client != nil {
		ctx := context.Background()
		switch caller.Server {
		case types.HiddenUserServer: // @lid → add phone number
			if pn, err := client.Store.LIDs.GetPNForLID(ctx, caller); err == nil && !pn.IsEmpty() {
				cands = append(cands, pn)
			}
		case types.DefaultUserServer: // phone → add @lid
			if lid, err := client.Store.LIDs.GetLIDForPN(ctx, caller); err == nil && !lid.IsEmpty() {
				cands = append(cands, lid)
			}
		}
	}

	// Prefer a candidate whose room already exists (the conversation).
	b.mu.Lock()
	for _, c := range cands {
		if b.knownRooms[c.User+"@"+string(c.Server)] {
			b.mu.Unlock()
			return c
		}
	}
	b.mu.Unlock()
	// No existing room — prefer the phone-number JID for a stable room id.
	for _, c := range cands {
		if c.Server == types.DefaultUserServer {
			return c
		}
	}
	return caller
}

// handleCallOffer surfaces an incoming WhatsApp call as a message in the
// caller's chat so Tjena visibly shows that the contact is calling. (We don't
// answer/reject here — this is just so the call is seen.)
func (b *Bridge) handleCallOffer(evt *waevents.CallOffer) {
	rawFrom := evt.From
	if rawFrom.IsEmpty() {
		rawFrom = evt.CallCreator
	}
	if rawFrom.IsEmpty() {
		return
	}
	// Calls usually arrive addressed by LID while the existing chat is keyed by
	// the phone number (or vice versa). Resolve to the JID of the chat that
	// already exists so the "incoming call" message lands in the same room as
	// the conversation, not a new one.
	caller := b.callerChatJID(rawFrom)
	roomID := caller.User + "@" + string(caller.Server)
	b.ensureRoom(caller)
	name := b.senderDisplayName(caller, "")
	ts := evt.Timestamp
	if ts.IsZero() {
		ts = time.Now()
	}
	b.appendLog("[Bridge] incoming WhatsApp call from " + roomID)
	// Visible indicator message in the chat.
	b.emitter.Emit(map[string]any{
		"type":    "message",
		"room_id": roomID,
		"event": map[string]any{
			"id":          "$wacall_" + evt.CallID,
			"sender":      "@wa_" + caller.User + ":tjena.local",
			"sender_name": name,
			"chat_phone":  b.chatPhone(caller),
			"ts":          ts.Unix(),
			"body":        "📞 Incoming WhatsApp call",
			"msgtype":     "m.text",
			"is_own":      false,
			"is_backfill": false,
		},
	})
	// Action event so the app can auto-reply with a call link and/or decline.
	// caller_jid is the raw caller (for RejectCall); room_id is the chat.
	b.emitter.Emit(map[string]any{
		"type":       "wa_call",
		"room_id":    roomID,
		"caller_jid": rawFrom.String(),
		"call_id":    evt.CallID,
	})
}

// RejectCall declines an incoming WhatsApp call so it stops ringing.
func (b *Bridge) RejectCall(callerJID, callID string) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("not connected")
	}
	jid, err := types.ParseJID(callerJID)
	if err != nil {
		return err
	}
	return client.RejectCall(context.Background(), jid, callID)
}

// ensureRoom emits a room_created event (keyed by the chat JID, matching the
// message-receive and SendText paths) the first time a chat is seen, so the
// Flutter store has a room to attach incoming messages to. DM names come from
// the local contact store (no network); group names are fetched asynchronously
// and refined via a follow-up room_updated event.
func (b *Bridge) ensureRoom(chat types.JID) {
	roomID := chat.User + "@" + string(chat.Server)

	b.mu.Lock()
	if b.knownRooms == nil {
		b.knownRooms = make(map[string]bool)
	}
	if b.goodNames == nil {
		b.goodNames = make(map[string]bool)
	}
	if b.knownRooms[roomID] {
		b.mu.Unlock()
		return
	}
	b.knownRooms[roomID] = true
	client := b.waClient
	b.mu.Unlock()

	isDM := chat.Server == types.DefaultUserServer
	name := chat.User
	otherUser := ""
	hasGoodName := false

	if isDM {
		otherUser = "@wa_" + chat.User + ":tjena.local"
		if client != nil {
			if c, err := client.Store.Contacts.GetContact(context.Background(), chat); err == nil {
				switch {
				case c.FullName != "":
					name = c.FullName
					hasGoodName = true
				case c.PushName != "":
					name = c.PushName
					hasGoodName = true
				case c.BusinessName != "":
					name = c.BusinessName
					hasGoodName = true
				}
			}
		}
	}

	if hasGoodName {
		b.mu.Lock()
		b.goodNames[roomID] = true
		b.mu.Unlock()
	}

	b.emitter.Emit(map[string]any{
		"type": "room_created",
		"room": map[string]any{
			"id": roomID, "name": name, "is_dm": isDM, "other_user": otherUser,
		},
	})

	// Fetch profile picture and group name asynchronously.
	if client != nil {
		go b.fetchRoomMeta(chat, roomID, isDM, !isDM && chat.Server == types.GroupServer)
	}
}

// fetchRoomMeta fetches the profile picture (and group name if needed) and
// emits room_updated so the UI can display real avatars and corrected names.
func (b *Bridge) fetchRoomMeta(chat types.JID, roomID string, isDM, fetchGroupName bool) {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return
	}

	update := map[string]any{"type": "room_updated", "room_id": roomID}

	if fetchGroupName {
		gi, err := client.GetGroupInfo(context.Background(), chat)
		if err == nil && gi.Name != "" {
			update["name"] = gi.Name
		}
	} else if isDM {
		// Re-check the local contacts store — it may have been populated since
		// the room was first created (WA contact sync happens asynchronously).
		// For LID chats the contact entry is keyed by the phone number, so
		// resolve LID→PN first and look the contact up under both JIDs.
		lookupJIDs := []types.JID{chat}
		if chat.Server == types.HiddenUserServer {
			if pn, err := client.Store.LIDs.GetPNForLID(context.Background(), chat); err == nil && !pn.IsEmpty() {
				lookupJIDs = append(lookupJIDs, pn)
			}
		}
		for _, lj := range lookupJIDs {
			c, err := client.Store.Contacts.GetContact(context.Background(), lj)
			if err != nil {
				continue
			}
			switch {
			case c.FullName != "":
				update["name"] = c.FullName
			case c.PushName != "":
				update["name"] = c.PushName
			case c.BusinessName != "":
				update["name"] = c.BusinessName
			}
			if _, ok := update["name"]; ok {
				break
			}
		}
	}

	// Profile picture works for both DMs and groups.
	pic, err := client.GetProfilePictureInfo(context.Background(), chat, &whatsmeow.GetProfilePictureParams{Preview: false})
	if err == nil && pic != nil && pic.URL != "" {
		update["avatar_url"] = pic.URL
	}

	// Only emit if there's something to update.
	if _, hasName := update["name"]; hasName {
		b.emitter.Emit(update)
	} else if _, hasAvatar := update["avatar_url"]; hasAvatar {
		b.emitter.Emit(update)
	}
}

// RefreshRoom re-fetches the name and avatar for a room and emits room_updated.
func (b *Bridge) RefreshRoom(roomID string) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("bridge not connected")
	}
	jid, err := types.ParseJID(roomID)
	if err != nil {
		return fmt.Errorf("invalid JID: %w", err)
	}
	isDM := jid.Server == types.DefaultUserServer
	go b.fetchRoomMeta(jid, roomID, isDM, !isDM && jid.Server == types.GroupServer)
	return nil
}

func (b *Bridge) handleWAMessage(evt *waevents.Message) {
	msg := evt.Message
	if msg == nil {
		return
	}

	b.ensureRoom(evt.Info.Chat)

	if react := msg.GetReactionMessage(); react != nil {
		b.emitter.Emit(map[string]any{
			"type":      "reaction",
			"room_id":   evt.Info.Chat.User + "@" + string(evt.Info.Chat.Server),
			"id":        "$wa_react_" + evt.Info.ID,
			"target_id": react.GetKey().GetID(),
			"sender":    "@wa_" + evt.Info.Sender.User + ":tjena.local",
			"emoji":     react.GetText(),
		})
		return
	}
	body, msgtype := messageBodyType(msg)
	// Skip non-renderable messages (protocol/poll/ephemeral/unsupported types):
	// messageBodyType returns an empty body with m.text for those. Injecting them
	// shows "Unknown message format" bubbles and clutters chats (the self-chat is
	// full of such protocol traffic).
	if body == "" && msgtype == "m.text" {
		return
	}

	isOwn := evt.Info.IsFromMe
	roomID := evt.Info.Chat.User + "@" + string(evt.Info.Chat.Server)

	// Track the oldest message we've seen per chat — the anchor for on-demand
	// history requests.
	b.recordOldest(roomID, &evt.Info)

	// Remember the latest incoming message so reading the chat can send a WA
	// read receipt for it.
	if !isOwn {
		b.mu.Lock()
		if b.lastRecv == nil {
			b.lastRecv = make(map[string]*types.MessageInfo)
		}
		cp := evt.Info
		b.lastRecv[roomID] = &cp
		b.mu.Unlock()
	}

	// For DMs only: promote the room name from bare phone number to the
	// sender's push name when we first see it.
	// DMs are addressed either by phone number (s.whatsapp.net) or, increasingly,
	// by LID (lid). Both must count as DMs or LID chats never get their push-name.
	isDMRoom := evt.Info.Chat.Server == types.DefaultUserServer ||
		evt.Info.Chat.Server == types.HiddenUserServer
	if isDMRoom && !isOwn && evt.Info.PushName != "" {
		b.mu.Lock()
		if b.goodNames == nil {
			b.goodNames = make(map[string]bool)
		}
		alreadyGood := b.goodNames[roomID]
		if !alreadyGood {
			b.goodNames[roomID] = true
		}
		b.mu.Unlock()
		if !alreadyGood {
			b.emitter.Emit(map[string]any{
				"type": "room_updated", "room_id": roomID, "name": evt.Info.PushName,
			})
		}
	}

	senderName := b.senderDisplayName(evt.Info.Sender, evt.Info.PushName)
	formattedBody := b.formatMentions(msg, body)
	msgEvent := map[string]any{
		"id":          "$wa_" + evt.Info.ID,
		"sender":      "@wa_" + evt.Info.Sender.User + ":tjena.local",
		"sender_name": senderName,
		"chat_phone":  b.chatPhone(evt.Info.Chat),
		"ts":          evt.Info.Timestamp.Unix(),
		"body":        body,
		"msgtype":     msgtype,
		"is_own":      isOwn,
		"is_backfill": false,
	}
	if formattedBody != "" {
		msgEvent["formatted_body"] = formattedBody
	}
	b.emitter.Emit(map[string]any{
		"type":    "message",
		"room_id": roomID,
		"event":   msgEvent,
	})

	// Cache the live message too so the history cache stays current for future
	// backfills / lazy room creation.
	if b.st != nil {
		// ignore: best-effort cache write
		_ = b.st.CacheMessage(context.Background(), localmatrix.CachedMessage{
			ChatJID:       roomID,
			MsgID:         evt.Info.ID,
			Sender:        "@wa_" + evt.Info.Sender.User + ":tjena.local",
			SenderName:    senderName,
			TS:            evt.Info.Timestamp.Unix(),
			Body:          body,
			MsgType:       msgtype,
			IsOwn:         isOwn,
			FormattedBody: formattedBody,
		}, waChatName(evt.Info.Chat, evt.Info.PushName), evt.Info.Chat.Server == types.GroupServer)
	}

	// For media messages, download asynchronously and emit media_ready.
	if msgtype != "m.text" {
		b.downloadMedia(
			"$wa_"+evt.Info.ID, evt.Info.ID, roomID, msgtype, body,
			"@wa_"+evt.Info.Sender.User+":tjena.local", senderName,
			evt.Info.Timestamp.Unix(), isOwn, msg,
		)
	}
}

// formatMentions builds a Matrix HTML formatted_body for a message that
// @-mentions group participants, turning each "@<number>" token into a
// clickable pill that shows the participant's real name. Returns "" when the
// message has no mentions (so the caller can omit formatted_body entirely).
func (b *Bridge) formatMentions(msg *waE2E.Message, body string) string {
	if msg == nil || body == "" {
		return ""
	}
	var ci *waE2E.ContextInfo
	if ext := msg.GetExtendedTextMessage(); ext != nil {
		ci = ext.GetContextInfo()
	}
	if ci == nil {
		return ""
	}
	mentioned := ci.GetMentionedJID()
	if len(mentioned) == 0 {
		return ""
	}
	formatted := html.EscapeString(body)
	changed := false
	for _, mj := range mentioned {
		jid, err := types.ParseJID(mj)
		if err != nil {
			continue
		}
		name := b.senderDisplayName(jid, "")
		if name == "" {
			name = jid.User
		}
		token := "@" + jid.User // WhatsApp encodes mentions as @<user> in text
		ghost := "@wa_" + jid.User + ":tjena.local"
		link := `<a href="https://matrix.to/#/` + ghost + `">` + html.EscapeString(name) + `</a>`
		if strings.Contains(formatted, token) {
			formatted = strings.ReplaceAll(formatted, token, link)
			changed = true
		}
	}
	if !changed {
		return ""
	}
	return formatted
}

// waChatName returns the chat-summary name to cache for a message. For a DM the
// sender is the contact, so their push name is fine; for a GROUP the name is the
// group subject (set from history sync / group info), so we return "" to avoid
// overwriting it with whoever last messaged.
func waChatName(chat types.JID, pushName string) string {
	if chat.Server == types.GroupServer {
		return ""
	}
	return pushName
}

// messageBodyType maps a WhatsApp message to a Matrix body string and msgtype.
// Returns ("", "m.text") for messages with no recognised renderable content.
func messageBodyType(msg *waE2E.Message) (body, msgtype string) {
	msgtype = "m.text"
	switch {
	case msg.GetConversation() != "":
		body = msg.GetConversation()
	case msg.GetExtendedTextMessage() != nil:
		body = msg.GetExtendedTextMessage().GetText()
	case msg.GetImageMessage() != nil:
		body = msg.GetImageMessage().GetCaption()
		if body == "" {
			body = "🖼 Image"
		}
		msgtype = "m.image"
	case msg.GetDocumentMessage() != nil:
		body = msg.GetDocumentMessage().GetFileName()
		msgtype = "m.file"
	case msg.GetVideoMessage() != nil:
		body = msg.GetVideoMessage().GetCaption()
		if body == "" {
			body = "📹 Video"
		}
		msgtype = "m.video"
	case msg.GetAudioMessage() != nil:
		body = "🎵 Audio"
		msgtype = "m.audio"
	case msg.GetStickerMessage() != nil:
		body = "🌀 Sticker"
		msgtype = "m.sticker"
	}
	return body, msgtype
}

// downloadMedia downloads a message's attachment in the background and emits a
// media_ready event carrying the full event payload. Shared by live messages
// and on-demand backfill.
func (b *Bridge) downloadMedia(
	eventID, msgID, roomID, msgtype, body, sender, senderName string,
	ts int64, isOwn bool, msg *waE2E.Message,
) {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return
	}
	go func() {
		data, err := client.DownloadAny(context.Background(), msg)
		if err != nil {
			b.appendLog(fmt.Sprintf("[Bridge] media download failed for %s: %v", eventID, err))
			return
		}
		tmpPath := b.dataDir + "/media_" + msgID
		if werr := os.WriteFile(tmpPath, data, 0600); werr != nil {
			b.appendLog(fmt.Sprintf("[Bridge] media write failed: %v", werr))
			return
		}
		mimeType := ""
		switch {
		case msg.GetImageMessage() != nil:
			mimeType = msg.GetImageMessage().GetMimetype()
		case msg.GetVideoMessage() != nil:
			mimeType = msg.GetVideoMessage().GetMimetype()
		case msg.GetAudioMessage() != nil:
			mimeType = msg.GetAudioMessage().GetMimetype()
		case msg.GetDocumentMessage() != nil:
			mimeType = msg.GetDocumentMessage().GetMimetype()
		case msg.GetStickerMessage() != nil:
			mimeType = msg.GetStickerMessage().GetMimetype()
		}
		if mimeType == "" {
			mimeType = "application/octet-stream"
		}
		b.emitter.Emit(map[string]any{
			"type":        "media_ready",
			"room_id":     roomID,
			"event_id":    eventID,
			"file_path":   tmpPath,
			"mimetype":    mimeType,
			"size":        len(data),
			"msgtype":     msgtype,
			"body":        body,
			"sender":      sender,
			"sender_name": senderName,
			"ts":          ts,
			"is_own":      isOwn,
		})
	}()
}

// ListChatsJSON returns a JSON array of all known WhatsApp chats (saved
// contacts as DMs + joined groups) so the UI can let the user pick which to
// sync. Each entry: {"jid","name","is_group","phone"}.
func (b *Bridge) ListChatsJSON() string {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return "[]"
	}
	ctx := context.Background()
	type chatEntry struct {
		JID     string `json:"jid"`
		Name    string `json:"name"`
		IsGroup bool   `json:"is_group"`
		Phone   string `json:"phone"`
	}
	var out []chatEntry

	// DMs from the contact store.
	if contacts, err := client.Store.Contacts.GetAllContacts(ctx); err == nil {
		for jid, c := range contacts {
			name := c.FullName
			if name == "" {
				name = c.PushName
			}
			if name == "" {
				name = c.BusinessName
			}
			out = append(out, chatEntry{
				JID:     jid.User + "@" + string(jid.Server),
				Name:    name,
				IsGroup: false,
				Phone:   b.chatPhone(jid),
			})
		}
	} else {
		b.appendLog("[Bridge] ListChats: GetAllContacts failed: " + err.Error())
	}

	// Groups.
	if groups, err := client.GetJoinedGroups(ctx); err == nil {
		for _, g := range groups {
			out = append(out, chatEntry{
				JID:     g.JID.User + "@" + string(g.JID.Server),
				Name:    g.Name,
				IsGroup: true,
				Phone:   "",
			})
		}
	} else {
		b.appendLog("[Bridge] ListChats: GetJoinedGroups failed: " + err.Error())
	}

	data, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	b.appendLog(fmt.Sprintf("[Bridge] ListChats: returning %d chats", len(out)))
	return string(data)
}

// GetGroupMembersJSON returns a group's participants as JSON for the member
// list / @-mention autocomplete: [{"jid","user","name","is_admin"}].
func (b *Bridge) GetGroupMembersJSON(roomID string) string {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return "[]"
	}
	jid, err := types.ParseJID(roomID)
	if err != nil || jid.Server != types.GroupServer {
		return "[]"
	}
	gi, err := client.GetGroupInfo(context.Background(), jid)
	if err != nil {
		b.appendLog("[Bridge] GetGroupMembers failed: " + err.Error())
		return "[]"
	}
	type member struct {
		JID     string `json:"jid"`
		User    string `json:"user"`
		Name    string `json:"name"`
		IsAdmin bool   `json:"is_admin"`
	}
	out := make([]member, 0, len(gi.Participants))
	for _, p := range gi.Participants {
		pj := p.JID
		if pj.IsEmpty() {
			continue
		}
		out = append(out, member{
			JID:     pj.User + "@" + string(pj.Server),
			User:    pj.User,
			Name:    b.senderDisplayName(pj, p.DisplayName),
			IsAdmin: p.IsAdmin || p.IsSuperAdmin,
		})
	}
	data, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(data)
}

// GetChatAvatarURL returns the direct https URL of a chat's profile picture
// (small preview), or "" if none/unavailable. Called lazily per list item so the
// chat picker doesn't fetch every avatar up front.
func (b *Bridge) GetChatAvatarURL(roomID string) string {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return ""
	}
	jid, err := types.ParseJID(roomID)
	if err != nil {
		return ""
	}
	pic, err := client.GetProfilePictureInfo(context.Background(), jid,
		&whatsmeow.GetProfilePictureParams{Preview: true})
	if err != nil || pic == nil {
		return ""
	}
	return pic.URL
}

// chatPhone returns a human-friendly phone number for a chat. For LID chats it
// resolves the LID to the underlying phone number; for phone-number chats it
// returns the number directly. Falls back to the raw user part if unresolvable.
func (b *Bridge) chatPhone(chat types.JID) string {
	if chat.Server == types.HiddenUserServer {
		b.mu.Lock()
		client := b.waClient
		b.mu.Unlock()
		if client != nil {
			if pn, err := client.Store.LIDs.GetPNForLID(context.Background(), chat); err == nil && !pn.IsEmpty() {
				return pn.User
			}
		}
	}
	return chat.User
}

// senderDisplayName returns the best display name for a message sender: the
// message's own push name if present, otherwise the contact store (resolving
// LID→PN first). Returns "" when nothing is known.
// senderDisplayName resolves a name for a WhatsApp user, in priority order:
//  1. the name you saved the contact under (contact FullName),
//  2. their WhatsApp nickname (push name — from the message, then the store),
//  3. their phone number (every WA user has one; LIDs are resolved to it).
// It never returns the raw LID/WA-id.
func (b *Bridge) senderDisplayName(sender types.JID, pushName string) string {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if sender.IsEmpty() {
		return pushName
	}
	if client == nil {
		if pushName != "" {
			return pushName
		}
		if sender.Server == types.DefaultUserServer {
			return "+" + sender.User
		}
		return sender.User
	}
	ctx := context.Background()

	// Candidate JIDs (sender + its phone-number counterpart) and the phone JID.
	tryJIDs := []types.JID{sender}
	var phoneJID types.JID
	if sender.Server == types.HiddenUserServer { // @lid → resolve phone number
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, sender); err == nil && !pn.IsEmpty() {
			tryJIDs = append(tryJIDs, pn)
			phoneJID = pn
		}
	} else if sender.Server == types.DefaultUserServer {
		phoneJID = sender
	}

	// 1) Saved contact name.
	for _, j := range tryJIDs {
		if c, err := client.Store.Contacts.GetContact(ctx, j); err == nil && c.FullName != "" {
			return c.FullName
		}
	}
	// 2) WhatsApp nickname (push name): the live one, then the stored one.
	if pushName != "" {
		return pushName
	}
	for _, j := range tryJIDs {
		if c, err := client.Store.Contacts.GetContact(ctx, j); err == nil {
			if c.PushName != "" {
				return c.PushName
			}
			if c.BusinessName != "" {
				return c.BusinessName
			}
		}
	}
	// 3) Phone number.
	if !phoneJID.IsEmpty() {
		return "+" + phoneJID.User
	}
	return sender.User // last resort (unresolvable LID)
}

// recordOldest remembers the oldest MessageInfo seen for a chat, used as the
// anchor for on-demand history requests.
func (b *Bridge) recordOldest(roomID string, info *types.MessageInfo) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.oldestMsg == nil {
		b.oldestMsg = make(map[string]*types.MessageInfo)
	}
	prev := b.oldestMsg[roomID]
	if prev == nil || info.Timestamp.Before(prev.Timestamp) {
		cp := *info
		b.oldestMsg[roomID] = &cp
	}
}

// RequestBackfill populates a chat's room with cached history (last `days` days).
// History is read from the local cache that was filled by the link-time history
// sync — reliable, unlike WhatsApp's flaky on-demand network API. The anchor
// parameters are accepted for FFI compatibility but no longer used.
func (b *Bridge) RequestBackfill(roomID string, days int, anchorMsgID string, anchorFromMe bool, anchorTS int64) error {
	_, err := b.BackfillFromCache(roomID, days)
	return err
}

// histReq tracks an in-flight on-demand history pagination for a chat.
type histReq struct {
	days       int   // window the user asked to display
	cutoff     int64 // target oldest unix-seconds (now - days); stop once reached
	lastOldest int64 // oldest cached ts at the last request (progress detection)
	attempts   int
}

// RequestServerHistory asks WhatsApp's primary device for older messages for a
// chat when the local cache doesn't already cover the requested [days]. Replies
// arrive asynchronously as ON_DEMAND HistorySync events (handled in
// handleHistorySync), which cache the messages, re-display them, and keep
// paginating until the window is covered or the server has no more.
func (b *Bridge) RequestServerHistory(roomID string, days int) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("not connected")
	}
	if days < 1 {
		days = 1
	}
	chat, err := types.ParseJID(roomID)
	if err != nil {
		return err
	}
	cutoff := time.Now().AddDate(0, 0, -days).Unix()

	// If the cache already reaches back past the cutoff, no server round-trip is
	// needed.
	var oldestTS int64
	if b.st != nil {
		if m, err := b.st.GetOldestCachedMessage(context.Background(), roomID); err == nil && m != nil {
			oldestTS = m.TS
		}
	}
	if oldestTS != 0 && oldestTS <= cutoff {
		return nil
	}

	b.mu.Lock()
	if b.pendingHist == nil {
		b.pendingHist = make(map[string]*histReq)
	}
	b.pendingHist[roomID] = &histReq{days: days, cutoff: cutoff, lastOldest: oldestTS}
	b.mu.Unlock()

	return b.sendHistReq(roomID, chat)
}

// sendHistReq sends a single on-demand history request anchored at the oldest
// message we currently have for the chat.
func (b *Bridge) sendHistReq(roomID string, chat types.JID) error {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return fmt.Errorf("not connected")
	}
	anchor := b.oldestAnchor(roomID, chat)
	if anchor == nil {
		b.mu.Lock()
		delete(b.pendingHist, roomID)
		b.mu.Unlock()
		return fmt.Errorf("no anchor message to request history from")
	}
	histMsg := client.BuildHistorySyncRequest(anchor, 50)
	ownID := client.Store.ID.ToNonAD()
	_, err := client.SendMessage(context.Background(), ownID, histMsg,
		whatsmeow.SendRequestExtra{Peer: true})
	if err != nil {
		b.appendLog("[Bridge] history request send failed: " + err.Error())
	}
	return err
}

// oldestAnchor returns the oldest message we know about for the chat (preferring
// the cache, falling back to the live oldest tracker) as a MessageInfo anchor.
func (b *Bridge) oldestAnchor(roomID string, chat types.JID) *types.MessageInfo {
	if b.st != nil {
		if m, err := b.st.GetOldestCachedMessage(context.Background(), roomID); err == nil && m != nil {
			return &types.MessageInfo{
				MessageSource: types.MessageSource{Chat: chat, IsFromMe: m.IsOwn},
				ID:            m.MsgID,
				Timestamp:     time.Unix(m.TS, 0),
			}
		}
	}
	b.mu.Lock()
	mi := b.oldestMsg[roomID]
	b.mu.Unlock()
	return mi
}

// continuePendingHistory is called after a HistorySync is cached: for each chat
// with an in-flight request it re-displays the now-larger cache and, if the
// target window still isn't covered and the server is still returning older
// messages, requests the next page.
func (b *Bridge) continuePendingHistory() {
	b.mu.Lock()
	if len(b.pendingHist) == 0 {
		b.mu.Unlock()
		return
	}
	pending := make(map[string]*histReq, len(b.pendingHist))
	for k, v := range b.pendingHist {
		pending[k] = v
	}
	b.mu.Unlock()

	for roomID, req := range pending {
		var newOldest int64
		if b.st != nil {
			if m, err := b.st.GetOldestCachedMessage(context.Background(), roomID); err == nil && m != nil {
				newOldest = m.TS
			}
		}
		// Re-display what we now have for the requested window.
		_, _ = b.BackfillFromCache(roomID, req.days)

		madeProgress := newOldest != 0 && (req.lastOldest == 0 || newOldest < req.lastOldest)
		reachedTarget := newOldest != 0 && newOldest <= req.cutoff
		req.attempts++
		if reachedTarget || !madeProgress || req.attempts > 30 {
			b.mu.Lock()
			delete(b.pendingHist, roomID)
			b.mu.Unlock()
			continue
		}
		req.lastOldest = newOldest
		b.mu.Lock()
		b.pendingHist[roomID] = req
		b.mu.Unlock()
		if chat, err := types.ParseJID(roomID); err == nil {
			_ = b.sendHistReq(roomID, chat)
		}
	}
}

// handleHistorySync caches every message from a HistorySync (the bulk dump WA
// sends at link time, plus any on-demand responses) into the local DB. It does
// NOT create rooms or emit messages — that happens later via BackfillFromCache
// when the user chooses which chats to sync. This is the "load all data silently
// into the database" step.
func (b *Bridge) handleHistorySync(data *waHistorySync.HistorySync) {
	if data == nil || b.st == nil {
		return
	}
	ctx := context.Background()
	cached := 0
	for _, conv := range data.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		roomID := jid.User + "@" + string(jid.Server)
		isGroup := jid.Server == types.GroupServer
		chatName := conv.GetName()
		for _, hm := range conv.GetMessages() {
			if b.cacheHistoricalMessage(ctx, roomID, jid, isGroup, chatName, hm.GetMessage()) {
				cached++
			}
		}
	}
	b.appendLog(fmt.Sprintf("[Bridge] handleHistorySync type=%s convs=%d cached=%d",
		data.GetSyncType().String(), len(data.GetConversations()), cached))
	// Tell Dart fresh history landed so it can (re)run an auto-sync if configured.
	b.emitter.Emit(map[string]any{"type": "history_cached", "count": cached})
	// Re-display and keep paginating any chats with an on-demand request in flight.
	b.continuePendingHistory()
}

// cacheHistoricalMessage parses one WebMessageInfo and stores it in the cache.
// Returns true if it was cached (false for reactions/empty/unsupported).
func (b *Bridge) cacheHistoricalMessage(ctx context.Context, roomID string, chat types.JID, isGroup bool, chatName string, wmi *waWeb.WebMessageInfo) bool {
	if wmi == nil {
		return false
	}
	key := wmi.GetKey()
	msg := wmi.GetMessage()
	if key == nil || msg == nil || msg.GetReactionMessage() != nil {
		return false
	}
	body, msgtype := messageBodyType(msg)
	if body == "" && msgtype == "m.text" {
		return false
	}
	msgID := key.GetID()
	if msgID == "" {
		return false
	}
	// Resolve the sender. In groups the participant identifies who sent it; it
	// lives on the key or (for history sync) on the WebMessageInfo. Falling back
	// to chat.User would wrongly attribute every group message to the group id.
	senderUser := chat.User
	senderJID := chat
	part := key.GetParticipant()
	if part == "" {
		part = wmi.GetParticipant()
	}
	if part != "" {
		if pj, perr := types.ParseJID(part); perr == nil {
			senderUser = pj.User
			senderJID = pj
		}
	}
	_ = b.st.CacheMessage(ctx, localmatrix.CachedMessage{
		ChatJID:       roomID,
		MsgID:         msgID,
		Sender:        "@wa_" + senderUser + ":tjena.local",
		SenderName:    b.senderDisplayName(senderJID, wmi.GetPushName()),
		TS:            int64(wmi.GetMessageTimestamp()),
		Body:          body,
		MsgType:       msgtype,
		IsOwn:         key.GetFromMe(),
		FormattedBody: b.formatMentions(msg, body),
	}, chatName, isGroup)
	return true
}

// ClearCache wipes this account's cached WhatsApp history so a re-link can
// repopulate it cleanly. Does not touch WhatsApp itself.
func (b *Bridge) ClearCache() error {
	if b.st == nil {
		return nil
	}
	b.appendLog("[Bridge] clearing local history cache")
	return b.st.ClearHistoryCache(context.Background())
}

// BackfillFromCache emits cached messages for a chat (last `days` days) as
// backfill events, so the Dart side can populate the room. Reliable — reads the
// local DB rather than the flaky on-demand network.
// altCacheJIDs returns the room's JID plus its phone-number↔LID counterpart, so
// cache lookups find messages regardless of which addressing they were stored
// under.
func (b *Bridge) altCacheJIDs(roomID string) []string {
	out := []string{roomID}
	jid, err := types.ParseJID(roomID)
	if err != nil {
		return out
	}
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return out
	}
	ctx := context.Background()
	switch jid.Server {
	case types.HiddenUserServer:
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, jid); err == nil && !pn.IsEmpty() {
			out = append(out, pn.User+"@"+string(pn.Server))
		}
	case types.DefaultUserServer:
		if lid, err := client.Store.LIDs.GetLIDForPN(ctx, jid); err == nil && !lid.IsEmpty() {
			out = append(out, lid.User+"@"+string(lid.Server))
		}
	}
	return out
}

// BackfillFromCache emits cached messages for the chat and returns how many it
// found (so the UI can report "loaded N" / "none found").
func (b *Bridge) BackfillFromCache(roomID string, days int) (int, error) {
	if b.st == nil {
		return 0, fmt.Errorf("no store")
	}
	if days < 1 {
		days = 1
	}
	since := time.Now().AddDate(0, 0, -days).Unix()
	// Messages may have been cached under either the phone-number JID or the LID
	// for the same contact. Query both and merge so a room keyed by one address
	// still finds messages cached under the other (the "no messages cached even
	// though there are messages" bug).
	ctx := context.Background()
	var msgs []localmatrix.CachedMessage
	seen := map[string]bool{}
	for _, jid := range b.altCacheJIDs(roomID) {
		ms, err := b.st.GetCachedMessages(ctx, jid, since)
		if err != nil {
			continue
		}
		for _, m := range ms {
			if seen[m.MsgID] {
				continue
			}
			seen[m.MsgID] = true
			msgs = append(msgs, m)
		}
	}
	sort.Slice(msgs, func(i, j int) bool { return msgs[i].TS < msgs[j].TS })
	b.appendLog(fmt.Sprintf("[Bridge] BackfillFromCache %s days=%d -> %d msgs", roomID, days, len(msgs)))
	// GetCachedMessages returns oldest-first; emit in that order. The Dart side
	// clears the room timeline and re-injects these as normal timeline events
	// (oldest-first → chronological), so everything is visible without server
	// pagination. Send them as ONE batched "backfill" event so the Dart side can
	// inject with periodic yields (no UI freeze) instead of a flood of events.
	events := make([]map[string]any, 0, len(msgs))
	for _, m := range msgs {
		ev := map[string]any{
			"id":          "$wa_" + m.MsgID,
			"sender":      m.Sender,
			"sender_name": m.SenderName,
			"ts":          m.TS,
			"body":        m.Body,
			"msgtype":     m.MsgType,
			"is_own":      m.IsOwn,
			"is_backfill": true,
		}
		if m.FormattedBody != "" {
			ev["formatted_body"] = m.FormattedBody
		}
		events = append(events, ev)
	}
	// Emit in chunks. A single huge event (a large window can be thousands of
	// messages) risks an oversized payload across the platform channel, which
	// drops the tail (the most recent messages, since events are oldest-first).
	// The first chunk carries clear=true so the Dart side wipes the timeline
	// once, then appends each chunk in order.
	const chunkSize = 200
	if len(events) == 0 {
		b.emitter.Emit(map[string]any{
			"type": "backfill", "room_id": roomID, "events": []any{}, "clear": true,
		})
		return 0, nil
	}
	for i := 0; i < len(events); i += chunkSize {
		end := i + chunkSize
		if end > len(events) {
			end = len(events)
		}
		b.emitter.Emit(map[string]any{
			"type":    "backfill",
			"room_id": roomID,
			"events":  events[i:end],
			"clear":   i == 0,
		})
	}
	return len(events), nil
}

// ListCachedChatsJSON returns all cached chats (from the history cache) as JSON,
// newest activity first. Used by the chat picker — instant and includes last
// activity for every chat (so "recent" sort works for unsynced chats too).
func (b *Bridge) ListCachedChatsJSON() string {
	if b.st == nil {
		return "[]"
	}
	chats, err := b.st.ListCachedChats(context.Background())
	if err != nil {
		return "[]"
	}
	type entry struct {
		JID     string `json:"jid"`
		Name    string `json:"name"`
		IsGroup bool   `json:"is_group"`
		LastTS  int64  `json:"last_ts"`
		Phone   string `json:"phone"`
	}
	out := make([]entry, 0, len(chats))
	for _, c := range chats {
		jid, _ := types.ParseJID(c.ChatJID)
		out = append(out, entry{
			JID:     c.ChatJID,
			Name:    c.Name,
			IsGroup: c.IsGroup,
			LastTS:  c.LastTS,
			Phone:   b.chatPhone(jid),
		})
	}
	data, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(data)
}

func (b *Bridge) handleWAReceipt(evt *waevents.Receipt) {
	if evt.Type != types.ReceiptTypeRead {
		return
	}
	for _, msgID := range evt.MessageIDs {
		b.emitter.Emit(map[string]any{
			"type":     "receipt",
			"room_id":  evt.Chat.User + "@" + string(evt.Chat.Server),
			"user_id":  "@wa_" + evt.Sender.User + ":tjena.local",
			"event_id": "$wa_" + msgID,
			"ts":       time.Now().UnixMilli(),
		})
	}
}
