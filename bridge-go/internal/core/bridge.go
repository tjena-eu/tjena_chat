package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"os"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
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

	// Get or create device.
	deviceStore, err := container.GetFirstDevice(ctx)
	if err != nil {
		return fmt.Errorf("get device: %w", err)
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
	b.mu.Unlock()

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

// MarkRead sends a read receipt for the given event.
func (b *Bridge) MarkRead(portalID, _ string) error {
	// whatsmeow doesn't expose a direct mark-read; we track locally.
	return nil
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

// ForceReset deletes all local WhatsApp credentials and prepares for fresh linking.
// Use this when the device store has stale credentials that prevent re-linking.
func (b *Bridge) ForceReset() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.waClient != nil {
		b.waClient.Disconnect()
	}

	if b.waStore != nil {
		// Delete all stored devices so we start as a fresh (unlinked) device.
		devices, err := b.waStore.GetAllDevices(context.Background())
		if err == nil {
			for _, dev := range devices {
				_ = dev.Delete(context.Background())
			}
		}

		// Re-create the whatsmeow client with a fresh device store entry.
		deviceStore, err := b.waStore.GetFirstDevice(context.Background())
		if err != nil {
			return fmt.Errorf("get fresh device: %w", err)
		}
		clientLog := &bridgeLogger{prefix: "WA-Client", br: b}
		b.waClient = whatsmeow.NewClient(deviceStore, clientLog)
		b.waClient.AddEventHandler(b.handleWAEvent)
	}

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
		// Automatically purge stale credentials so the next QR attempt
		// starts with a fresh (unregistered) device identity. Without this
		// Connect() reuses the revoked session and WhatsApp immediately
		// closes the WebSocket, killing the QR channel before a code renders.
		if b.waStore != nil {
			devices, _ := b.waStore.GetAllDevices(context.Background())
			for _, dev := range devices {
				_ = dev.Delete(context.Background())
			}
			if deviceStore, err := b.waStore.GetFirstDevice(context.Background()); err == nil {
				clientLog := &bridgeLogger{prefix: "WA-Client", br: b}
				b.waClient = whatsmeow.NewClient(deviceStore, clientLog)
				b.waClient.AddEventHandler(b.handleWAEvent)
			}
		}
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type": "disconnected", "reason": "logged_out",
		})

	case *waevents.Message:
		b.handleWAMessage(evt)

	case *waevents.Receipt:
		b.handleWAReceipt(evt)

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
		if c, err := client.Store.Contacts.GetContact(context.Background(), chat); err == nil {
			switch {
			case c.FullName != "":
				update["name"] = c.FullName
			case c.PushName != "":
				update["name"] = c.PushName
			case c.BusinessName != "":
				update["name"] = c.BusinessName
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

	body := ""
	msgtype := "m.text"
	if c := msg.GetConversation(); c != "" {
		body = c
	} else if ext := msg.GetExtendedTextMessage(); ext != nil {
		body = ext.GetText()
	} else if img := msg.GetImageMessage(); img != nil {
		body = img.GetCaption()
		if body == "" {
			body = "🖼 Image"
		}
		msgtype = "m.image"
	} else if doc := msg.GetDocumentMessage(); doc != nil {
		body = doc.GetFileName()
		msgtype = "m.file"
	} else if vid := msg.GetVideoMessage(); vid != nil {
		body = vid.GetCaption()
		if body == "" {
			body = "📹 Video"
		}
		msgtype = "m.video"
	} else if aud := msg.GetAudioMessage(); aud != nil {
		body = "🎵 Audio"
		msgtype = "m.audio"
	} else if sticker := msg.GetStickerMessage(); sticker != nil {
		body = "🌀 Sticker"
		msgtype = "m.sticker"
	} else if react := msg.GetReactionMessage(); react != nil {
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

	isOwn := evt.Info.IsFromMe
	roomID := evt.Info.Chat.User + "@" + string(evt.Info.Chat.Server)

	// If this is a DM and the room still has only a bare phone-number name,
	// promote it to the sender's push name as soon as we see it.
	if !isOwn && evt.Info.PushName != "" {
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

	b.emitter.Emit(map[string]any{
		"type":    "message",
		"room_id": roomID,
		"event": map[string]any{
			"id":          "$wa_" + evt.Info.ID,
			"sender":      "@wa_" + evt.Info.Sender.User + ":tjena.local",
			"sender_name": evt.Info.PushName,
			"ts":          evt.Info.Timestamp.Unix(),
			"body":        body,
			"msgtype":     msgtype,
			"is_own":      isOwn,
			"is_backfill": false,
		},
	})
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
