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
	"regexp"
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

	// Optional proxy for all WhatsApp traffic (http://user:pass@host:port or
	// socks5://…). Empty = direct. Persisted in dataDir/proxy.
	proxyURL string

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

	// Serialises forced socket replacements (see reconnectNow). Separate from mu
	// because a reconnect blocks for seconds and must not hold the state lock.
	reconnMu      sync.Mutex
	lastReconnect time.Time

	knownRooms  map[string]bool   // JID room IDs we've already emitted room_created for
	goodNames   map[string]bool   // rooms whose name is a real name (not a bare number)
	goodAvatars map[string]bool   // rooms we've already emitted a profile picture for

	// Group subjects cached from GetJoinedGroups, so a group room gets its real
	// name the moment it is created instead of showing the numeric group id
	// until the first GetGroupInfo round-trip returns.
	groupNames map[string]string

	// Bounded worker queue for room name/avatar fetches. Creating every chat at
	// link time used to spawn one unthrottled goroutine per chat, and WhatsApp
	// rate-limited the burst so most rooms never got a name or an avatar.
	metaCh     chan roomMetaReq
	metaOnce   sync.Once
	metaQueued map[string]bool

	// When true, an incoming attachment is recorded as pending instead of being
	// downloaded straight away; it is fetched when the chat is opened (or when
	// the user taps the preview). Set from Dart, which owns the policy —
	// per-chat setting, Android Data Saver, etc. Default false so behaviour is
	// unchanged until Dart says otherwise.
	deferMedia bool

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

	// Single-worker queue for HistorySync chunks (so the pairing burst is
	// processed sequentially instead of by many concurrent goroutines).
	histCh   chan *waHistorySync.HistorySync
	histOnce sync.Once

	// Cumulative history-sync progress (for the settings UI loading indicator).
	histTotalMsgs int
	histChatSet   map[string]bool

	logMu  sync.Mutex
	logBuf []string // ring buffer, last 100 lines
}

func (b *Bridge) appendLog(line string) {
	// Note: intentionally NOT printed to stdout/logcat — on Android gomobile
	// routes stdout to logcat, and whatsmeow logs frequently, which spammed adb
	// (especially now the bridge keeps running in the background). Logs are kept
	// in the ring buffer below and surfaced via GetLogs()/the in-app viewer.
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
	// Restore a persisted proxy so it applies to the client on Start.
	if data, err := os.ReadFile(dataDir + "/proxy"); err == nil {
		b.proxyURL = strings.TrimSpace(string(data))
	}
	return b, nil
}

// newWAClient creates a whatsmeow client with the configured proxy applied
// (must be done before Connect).
func (b *Bridge) newWAClient(deviceStore *store.Device, log walog.Logger) *whatsmeow.Client {
	c := whatsmeow.NewClient(deviceStore, log)
	if b.proxyURL != "" {
		if err := c.SetProxyAddress(b.proxyURL); err != nil {
			b.appendLog("[Bridge] invalid proxy address: " + err.Error())
		}
	}
	return c
}

// GetProxy returns the configured WhatsApp proxy URL ("" = direct).
func (b *Bridge) GetProxy() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.proxyURL
}

// SetProxy persists the proxy URL and applies it, reconnecting so it takes
// effect. Pass "" to disable the proxy.
func (b *Bridge) SetProxy(proxyURL string) error {
	proxyURL = strings.TrimSpace(proxyURL)
	b.mu.Lock()
	b.proxyURL = proxyURL
	client := b.waClient
	linked := b.linked
	b.mu.Unlock()

	if err := os.WriteFile(b.dataDir+"/proxy", []byte(proxyURL), 0o600); err != nil {
		return fmt.Errorf("persist proxy: %w", err)
	}
	if client == nil {
		return nil
	}
	// Apply and reconnect so the new proxy takes effect.
	if proxyURL != "" {
		if err := client.SetProxyAddress(proxyURL); err != nil {
			return fmt.Errorf("invalid proxy address: %w", err)
		}
	} else {
		client.SetProxyAddress("")
	}
	if linked {
		client.Disconnect()
		go func() {
			if err := client.Connect(); err != nil {
				b.appendLog("[Bridge] reconnect after proxy change failed: " + err.Error())
			}
		}()
	}
	return nil
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
	b.waClient = b.newWAClient(deviceStore, clientLog)
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

// Send/reconnect timings. A send must fail fast enough that the user sees an
// error marker rather than a frozen composer, but slowly enough to survive an
// ordinary slow mobile round-trip.
const (
	sendAttemptTimeout = 20 * time.Second
	reconnectWait      = 12 * time.Second
	// A burst of network callbacks (a VPN coming up fires several) must not tear
	// down a socket we only just rebuilt.
	reconnectCoalesce = 4 * time.Second
)

// sendMessage sends msg and returns the WhatsApp message ID.
//
// A WhatsApp socket can be silently dead: after a brief Wi-Fi drop or a VPN
// (Twingate) route change the TCP connection is half-open — no FIN ever
// arrives, so IsConnected() keeps reporting true (and the UI keeps showing the
// green dot) while writes vanish. whatsmeow only forces a reconnect after
// KeepAliveMaxFailTime, i.e. three minutes of failing pings, so trusting
// IsConnected() here used to mean a send that hung for its whole deadline.
//
// Instead: send with a short deadline and, if that fails, replace the socket and
// retry exactly once. The retry reuses the same message ID, so if the first
// attempt did reach the server and only its ack was lost, WhatsApp
// de-duplicates it instead of the recipient seeing the message twice.
func (b *Bridge) sendMessage(client *whatsmeow.Client, jid types.JID, msg *waE2E.Message) (string, error) {
	msgID := client.GenerateMessageID()
	id, err := b.trySend(client, jid, msg, msgID)
	if err == nil {
		return id, nil
	}
	b.appendLog("[Bridge] send failed (" + err.Error() + ") — replacing socket and retrying once")
	if !b.reconnectNow(client, reconnectWait, true) {
		return "", fmt.Errorf("no WhatsApp connection: %w", err)
	}
	return b.trySend(client, jid, msg, msgID)
}

// trySend is one send attempt, reconnecting first if the socket is known to be
// down.
func (b *Bridge) trySend(
	client *whatsmeow.Client,
	jid types.JID,
	msg *waE2E.Message,
	msgID types.MessageID,
) (string, error) {
	if !client.IsConnected() && !b.reconnectNow(client, reconnectWait, false) {
		return "", fmt.Errorf("not connected to WhatsApp")
	}
	ctx, cancel := context.WithTimeout(context.Background(), sendAttemptTimeout)
	defer cancel()
	resp, err := client.SendMessage(ctx, jid, msg, whatsmeow.SendRequestExtra{
		ID: msgID,
		// Without this whatsmeow waits its own default 75s for the ack.
		Timeout: sendAttemptTimeout,
	})
	if err != nil {
		return "", err
	}
	return resp.ID, nil
}

// reconnectNow tears down the current socket and builds a fresh one, waiting up
// to d for the login handshake to finish. Returns whether the client is usable
// afterwards.
//
// force replaces even a socket that claims to be connected — that is the whole
// point after a network change, where IsConnected() cannot be trusted. Only one
// reconnect runs at a time; concurrent callers reuse the result.
func (b *Bridge) reconnectNow(client *whatsmeow.Client, d time.Duration, force bool) bool {
	b.reconnMu.Lock()
	defer b.reconnMu.Unlock()

	usable := client.IsConnected() && client.IsLoggedIn()
	// Someone else already rebuilt the socket while we waited for the lock.
	if usable && (!force || time.Since(b.lastReconnect) < reconnectCoalesce) {
		return true
	}

	b.mu.Lock()
	linked := b.linked
	b.mu.Unlock()
	if !linked {
		return false
	}

	client.Disconnect()
	if err := client.Connect(); err != nil {
		b.appendLog("[Bridge] forced reconnect failed: " + err.Error())
		return false
	}
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if client.IsConnected() && client.IsLoggedIn() {
			b.lastReconnect = time.Now()
			return true
		}
		time.Sleep(200 * time.Millisecond)
	}
	return false
}

// OnNetworkChange is called when the device's default network changes — Wi-Fi
// ⇄ mobile, a dropped-and-restored Wi-Fi link, or a VPN such as Twingate coming
// up or going down. The existing socket is bound to the old route and is
// typically half-open, so replace it immediately rather than waiting the three
// minutes whatsmeow's keepalive takes to notice.
func (b *Bridge) OnNetworkChange() {
	b.mu.Lock()
	client := b.waClient
	linked := b.linked
	b.mu.Unlock()
	if client == nil || !linked {
		return
	}
	go func() {
		if b.reconnectNow(client, reconnectWait, true) {
			b.appendLog("[Bridge] reconnected after network change")
			return
		}
		b.appendLog("[Bridge] reconnect after network change incomplete; retrying with backoff")
		b.autoReconnect(client)
	}()
}

// cacheOwnOutgoing stores a message we sent ourselves so it survives a
// backfill/clean-reset (a tjena-sent message otherwise only exists as an
// uncached local echo). Keyed by the real WhatsApp message ID, so a later
// history sync of the same message de-duplicates.
func (b *Bridge) cacheOwnOutgoing(client *whatsmeow.Client, portalID, msgID, body, msgtype string) {
	if b.st == nil || msgID == "" {
		return
	}
	sender := "@wa_me:tjena.local"
	if client.Store.ID != nil {
		sender = "@wa_" + client.Store.ID.User + ":tjena.local"
	}
	_ = b.st.CacheMessage(context.Background(), localmatrix.CachedMessage{
		ChatJID: portalID, MsgID: msgID, Sender: sender,
		TS: time.Now().Unix(), Body: body, MsgType: msgtype, IsOwn: true,
	}, "", strings.HasSuffix(portalID, "@g.us"))
}

// outgoingMentionToken matches the "@<number>" tokens the Dart side rewrites
// composer mentions into (see WaMatrixBridge._rewriteWaMentions) — the same
// wire format WhatsApp itself uses and that formatMentions parses back out of
// *incoming* messages.
var outgoingMentionToken = regexp.MustCompile(`@(\d{5,20})`)

// resolveOutgoingMentions finds which "@<number>" tokens in text actually
// name a participant of chat (group members, or the DM peer itself) and
// returns their full JIDs. WhatsApp only renders a mention as more than
// plain text when the message carries ContextInfo.MentionedJID for it.
func (b *Bridge) resolveOutgoingMentions(client *whatsmeow.Client, chat types.JID, text string) []string {
	matches := outgoingMentionToken.FindAllStringSubmatch(text, -1)
	if len(matches) == 0 {
		return nil
	}
	candidates := map[string]types.JID{}
	if chat.Server == types.GroupServer {
		gi, err := client.GetGroupInfo(context.Background(), chat)
		if err != nil {
			return nil
		}
		for _, p := range gi.Participants {
			if !p.JID.IsEmpty() {
				candidates[p.JID.User] = p.JID
			}
		}
	} else {
		candidates[chat.User] = chat
	}
	seen := map[string]bool{}
	var out []string
	for _, m := range matches {
		user := m[1]
		if seen[user] {
			continue
		}
		if jid, ok := candidates[user]; ok {
			seen[user] = true
			out = append(out, jid.String())
		}
	}
	return out
}

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
	var msg *waE2E.Message
	if mentioned := b.resolveOutgoingMentions(client, jid, text); len(mentioned) > 0 {
		msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: proto.String(text),
			ContextInfo: &waE2E.ContextInfo{
				MentionedJID: mentioned,
			},
		}}
	} else {
		msg = &waE2E.Message{Conversation: proto.String(text)}
	}
	msgID, err := b.sendMessage(client, jid, msg)
	if err != nil {
		return err
	}
	b.cacheOwnOutgoing(client, portalID, msgID, text, "m.text")
	return nil
}

// SendMedia uploads a file/image/video/audio and sends it through WhatsApp.
func (b *Bridge) SendMedia(portalID, _ string, mimeType string, data []byte, caption string, thumbnail []byte, width, height int) error {
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
	var cap *string
	if caption != "" {
		cap = proto.String(caption)
	}
	var w, h *uint32
	if width > 0 {
		w = proto.Uint32(uint32(width))
	}
	if height > 0 {
		h = proto.Uint32(uint32(height))
	}
	switch mediaType {
	case whatsmeow.MediaImage:
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size), Caption: cap,
			JPEGThumbnail: thumbnail, Width: w, Height: h,
		}}
	case whatsmeow.MediaVideo:
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			Mimetype: proto.String(mimeType), URL: proto.String(up.URL),
			DirectPath: proto.String(up.DirectPath), MediaKey: up.MediaKey,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256,
			FileLength: proto.Uint64(size), Caption: cap,
			JPEGThumbnail: thumbnail, Width: w, Height: h,
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
			FileLength: proto.Uint64(size), Caption: cap,
		}}
	}

	_, err = b.sendMessage(client, jid, msg)
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
	b.waClient = b.newWAClient(deviceStore, clientLog)
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
		// Cache group subjects up front so group rooms created from the chat
		// list (link mode "all") are named immediately, instead of showing the
		// numeric group id until GetGroupInfo answers per chat.
		go b.cacheGroupNames()

	case *waevents.KeepAliveTimeout:
		// Pings are failing, so the socket is dead even though IsConnected()
		// still says otherwise. whatsmeow would sit on it for
		// KeepAliveMaxFailTime (3 minutes) before reconnecting, during which the
		// UI shows a green dot and every send black-holes. Replace it after the
		// second consecutive failure (~1 minute) and report the truth in the
		// meantime.
		// One missed ping can be a hiccup, so don't flicker the dot for it; from
		// the second failure on, the socket is genuinely gone and saying
		// "connected" would be the lie that made sends look like they worked.
		if evt.ErrorCount < 2 {
			b.appendLog(fmt.Sprintf("[Bridge] keepalive timed out (%d)", evt.ErrorCount))
			return
		}
		b.mu.Lock()
		b.connected = false
		client := b.waClient
		linked := b.linked
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type": "state", "linked": linked, "connected": false,
			"reason": "keepalive_timeout",
		})
		if client != nil && linked {
			b.appendLog(fmt.Sprintf(
				"[Bridge] %d keepalives failed (last success %s) — replacing socket",
				evt.ErrorCount, evt.LastSuccess.Format(time.RFC3339)))
			go b.OnNetworkChange()
		}

	case *waevents.KeepAliveRestored:
		b.mu.Lock()
		b.connected = true
		linked := b.linked
		b.mu.Unlock()
		b.emitter.Emit(map[string]any{
			"type": "state", "linked": linked, "connected": true,
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
			b.waClient = b.newWAClient(deviceStore, clientLog)
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
		// Process history-sync chunks one at a time on a single worker, so the
		// burst at pairing doesn't run many concurrent writers (which used to
		// drop messages). Don't block the whatsmeow event loop.
		b.enqueueHistorySync(evt.Data)
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

	b.cacheGroupNames()
	b.queueMissingAvatars()
}

// cacheGroupNames pulls every joined group's subject in one round-trip and
// caches it, so group rooms are named the moment they're created (and existing
// group rooms showing a numeric id get corrected right away).
func (b *Bridge) cacheGroupNames() {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return
	}
	groups, err := client.GetJoinedGroups(context.Background())
	if err != nil {
		b.appendLog("[Bridge] cacheGroupNames: GetJoinedGroups failed: " + err.Error())
		return
	}
	for _, g := range groups {
		if g.Name == "" {
			continue
		}
		roomID := g.JID.User + "@" + string(g.JID.Server)
		b.mu.Lock()
		if b.groupNames == nil {
			b.groupNames = make(map[string]string)
		}
		b.groupNames[roomID] = g.Name
		if b.goodNames == nil {
			b.goodNames = make(map[string]bool)
		}
		known := b.knownRooms[roomID]
		alreadyGood := b.goodNames[roomID]
		b.goodNames[roomID] = true
		b.mu.Unlock()

		if known && !alreadyGood {
			b.emitter.Emit(map[string]any{
				"type": "room_updated", "room_id": roomID, "name": g.Name,
			})
		}
	}
}

// queueMissingAvatars schedules an avatar fetch for every room we know about
// that hasn't produced a profile picture yet. Runs after the contact/group scan
// so freshly linked accounts end up with avatars everywhere, not just on the
// chats that happened to receive a message.
func (b *Bridge) queueMissingAvatars() {
	b.mu.Lock()
	rooms := make([]string, 0, len(b.knownRooms))
	for roomID := range b.knownRooms {
		if b.goodAvatars[roomID] {
			continue
		}
		rooms = append(rooms, roomID)
	}
	b.mu.Unlock()

	for _, roomID := range rooms {
		jid, err := types.ParseJID(roomID)
		if err != nil {
			continue
		}
		isDM := jid.Server == types.DefaultUserServer
		b.queueRoomMeta(jid, roomID, isDM, false)
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
// altRoomJID returns the LID↔phone-number counterpart room id for a chat, or ""
// if there is none. Used so an incoming reply addressed by LID can be matched to
// an existing phone-number room (and vice versa) instead of making a duplicate.
func (b *Bridge) altRoomJID(chat types.JID) string {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return ""
	}
	ctx := context.Background()
	switch chat.Server {
	case types.HiddenUserServer:
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, chat); err == nil && !pn.IsEmpty() {
			return pn.User + "@" + string(pn.Server)
		}
	case types.DefaultUserServer:
		if lid, err := client.Store.LIDs.GetLIDForPN(ctx, chat); err == nil && !lid.IsEmpty() {
			return lid.User + "@" + string(lid.Server)
		}
	}
	return ""
}

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
	groupName := b.groupNames[roomID]
	b.mu.Unlock()

	isDM := chat.Server == types.DefaultUserServer
	name := chat.User
	otherUser := ""
	hasGoodName := false

	// Groups: use the subject cached from GetJoinedGroups so the room is named
	// on creation rather than after the async GetGroupInfo round-trip.
	if !isDM && groupName != "" {
		name = groupName
		hasGoodName = true
	}

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
			"alt_id": b.altRoomJID(chat),
		},
	})

	// Fetch profile picture (and group name, if still unknown) in the background,
	// through the throttled queue.
	if client != nil {
		b.queueRoomMeta(chat, roomID, isDM, !isDM && chat.Server == types.GroupServer && groupName == "")
	}
}

// roomMetaReq is one queued name/avatar fetch for a chat.
type roomMetaReq struct {
	chat           types.JID
	roomID         string
	isDM           bool
	fetchGroupName bool
	attempt        int
}

// metaWorkers is how many room name/avatar fetches may be in flight at once.
// WhatsApp rate-limits profile-picture queries, so this stays deliberately low;
// the queue drains in the background over the first minutes after linking.
const metaWorkers = 3

// queueRoomMeta schedules a name/avatar fetch for a chat, de-duplicated by room
// id so the same chat is never queued twice concurrently. Non-blocking: if the
// queue is full the request is dropped (a later refresh will pick it up).
func (b *Bridge) queueRoomMeta(chat types.JID, roomID string, isDM, fetchGroupName bool) {
	b.metaOnce.Do(func() {
		b.mu.Lock()
		b.metaCh = make(chan roomMetaReq, 2048)
		b.metaQueued = make(map[string]bool)
		ch := b.metaCh
		b.mu.Unlock()
		for i := 0; i < metaWorkers; i++ {
			go b.metaWorker(ch)
		}
	})

	b.mu.Lock()
	ch := b.metaCh
	if b.metaQueued == nil {
		b.metaQueued = make(map[string]bool)
	}
	if b.metaQueued[roomID] {
		b.mu.Unlock()
		return
	}
	b.metaQueued[roomID] = true
	b.mu.Unlock()

	select {
	case ch <- roomMetaReq{chat: chat, roomID: roomID, isDM: isDM, fetchGroupName: fetchGroupName}:
	default:
		b.mu.Lock()
		delete(b.metaQueued, roomID)
		b.mu.Unlock()
		b.appendLog("[Bridge] room meta queue full, dropped " + roomID)
	}
}

// metaWorker drains the room-meta queue. A request that came back with neither
// a name nor an avatar is retried a couple of times with a growing delay —
// right after linking, the contact store and the profile-picture endpoint both
// need a moment before they answer.
func (b *Bridge) metaWorker(ch chan roomMetaReq) {
	for req := range ch {
		ok := b.fetchRoomMeta(req.chat, req.roomID, req.isDM, req.fetchGroupName)

		b.mu.Lock()
		delete(b.metaQueued, req.roomID)
		b.mu.Unlock()

		if !ok && req.attempt < 2 {
			req.attempt++
			delay := time.Duration(req.attempt*15) * time.Second
			go func(r roomMetaReq) {
				time.Sleep(delay)
				b.queueRoomMeta(r.chat, r.roomID, r.isDM, r.fetchGroupName)
			}(req)
		}
		// Space the fetches out a little so a large backlog doesn't look like a
		// burst of requests to WhatsApp.
		time.Sleep(250 * time.Millisecond)
	}
}

// fetchRoomMeta fetches the profile picture (and group name if needed) and
// emits room_updated so the UI can display real avatars and corrected names.
// Returns true when it resolved everything it was asked for (a name where one
// was missing, and an avatar), so the caller can decide whether to retry.
func (b *Bridge) fetchRoomMeta(chat types.JID, roomID string, isDM, fetchGroupName bool) bool {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		return false
	}

	update := map[string]any{"type": "room_updated", "room_id": roomID}

	if fetchGroupName {
		gi, err := client.GetGroupInfo(context.Background(), chat)
		if err == nil && gi.Name != "" {
			update["name"] = gi.Name
			b.mu.Lock()
			if b.groupNames == nil {
				b.groupNames = make(map[string]string)
			}
			b.groupNames[roomID] = gi.Name
			b.mu.Unlock()
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

	name, hasName := update["name"]
	_, hasAvatar := update["avatar_url"]

	// Only emit if there's something to update.
	if hasName || hasAvatar {
		b.emitter.Emit(update)
	}

	b.mu.Lock()
	if b.goodNames == nil {
		b.goodNames = make(map[string]bool)
	}
	if b.goodAvatars == nil {
		b.goodAvatars = make(map[string]bool)
	}
	if hasName && name != "" {
		b.goodNames[roomID] = true
	}
	if hasAvatar {
		b.goodAvatars[roomID] = true
	}
	nameOK := b.goodNames[roomID]
	avatarOK := b.goodAvatars[roomID]
	b.mu.Unlock()

	// "Resolved" = we know a real name and have an avatar. A chat genuinely
	// without a profile picture keeps retrying twice and then settles, which is
	// cheap compared to leaving every such chat blank.
	return nameOK && avatarOK
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
	b.queueRoomMeta(jid, roomID, isDM, !isDM && jid.Server == types.GroupServer)
	return nil
}

func (b *Bridge) handleWAMessage(evt *waevents.Message) {
	msg := evt.Message
	if msg == nil {
		return
	}

	// NOTE: deliberately no ensureRoom() here. Creating the room before we know
	// the message is renderable spawned empty "phantom" chats: when someone you
	// have never messaged shows up in a group, WhatsApp sends protocol traffic
	// (sender-key distribution, device sync, …) addressed to a DM chat with that
	// person. The message itself was correctly dropped by the renderable check
	// below, but the room had already been created — leaving a private chat with
	// no messages, stuck on "loading messages", sorted to the top of the list.
	// The room is created further down, once the message is known to be real.

	if react := msg.GetReactionMessage(); react != nil {
		// No ensureRoom: a reaction targets a message we must already have
		// injected, so the room exists. If it doesn't, the reaction has nothing
		// to attach to and Dart drops it — creating a room here would only
		// resurrect the phantom-chat bug via a reaction in a group.
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

	// The message is real and will be injected, so it's safe to materialise the
	// chat now (see the note at the top of this function).
	b.ensureRoom(evt.Info.Chat)

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
		"type":        "message",
		"room_id":     roomID,
		"alt_room_id": b.altRoomJID(evt.Info.Chat),
		"event":       msgEvent,
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
	case msg.GetLocationMessage() != nil:
		loc := msg.GetLocationMessage()
		name := loc.GetName()
		if name == "" {
			name = loc.GetAddress()
		}
		label := "📍 Location"
		if name != "" {
			label = "📍 " + name
		}
		body = fmt.Sprintf("%s\nhttps://www.google.com/maps/search/?api=1&query=%.6f,%.6f",
			label, loc.GetDegreesLatitude(), loc.GetDegreesLongitude())
	case msg.GetLiveLocationMessage() != nil:
		loc := msg.GetLiveLocationMessage()
		body = fmt.Sprintf("📍 Live location\nhttps://www.google.com/maps/search/?api=1&query=%.6f,%.6f",
			loc.GetDegreesLatitude(), loc.GetDegreesLongitude())
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
	// Resolve mimetype and the embedded preview thumbnail up front — both live in
	// the message itself (no download needed). Emitting the thumbnail immediately
	// lets the chat show a real video/image preview right away, even before the
	// (possibly large/slow) full attachment finishes downloading, or if it fails.
	mimeType := ""
	var thumbData []byte
	var thumbW, thumbH uint32
	switch {
	case msg.GetImageMessage() != nil:
		im := msg.GetImageMessage()
		mimeType = im.GetMimetype()
		thumbData = im.GetJPEGThumbnail()
		thumbW, thumbH = im.GetWidth(), im.GetHeight()
	case msg.GetVideoMessage() != nil:
		vm := msg.GetVideoMessage()
		mimeType = vm.GetMimetype()
		thumbData = vm.GetJPEGThumbnail()
		thumbW, thumbH = vm.GetWidth(), vm.GetHeight()
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
	if len(thumbData) > 0 {
		thumbPath := b.dataDir + "/thumb_" + msgID
		if werr := os.WriteFile(thumbPath, thumbData, 0600); werr == nil {
			b.emitter.Emit(map[string]any{
				"type":        "media_ready",
				"room_id":     roomID,
				"event_id":    eventID,
				"file_path":   "", // thumbnail-only update (no full attachment yet)
				"thumb_path":  thumbPath,
				"thumb_w":     thumbW,
				"thumb_h":     thumbH,
				"mimetype":    mimeType,
				"size":        0,
				"msgtype":     msgtype,
				"body":        body,
				"sender":      sender,
				"sender_name": senderName,
				"ts":          ts,
				"is_own":      isOwn,
			})
		}
	}
	// Deferred mode: record enough to fetch this attachment later and stop here.
	// The embedded thumbnail was already emitted above, so the chat shows a real
	// preview — the user just taps it (or opens the chat) to pull the full file.
	b.mu.Lock()
	defer_ := b.deferMedia
	b.mu.Unlock()
	if defer_ && b.st != nil {
		raw, merr := proto.Marshal(msg)
		if merr != nil {
			b.appendLog("[Bridge] pending media marshal failed: " + merr.Error())
		} else {
			if aerr := b.st.AddPendingMedia(context.Background(), localmatrix.PendingMedia{
				ChatJID: roomID, MsgID: msgID, EventID: eventID, MsgType: msgtype,
				Body: body, Sender: sender, SenderName: senderName, TS: ts,
				IsOwn: isOwn, Mimetype: mimeType, Proto: raw,
			}); aerr != nil {
				b.appendLog("[Bridge] AddPendingMedia failed: " + aerr.Error())
			} else {
				b.emitter.Emit(map[string]any{
					"type": "media_pending", "room_id": roomID, "event_id": eventID,
					"msg_id": msgID, "mimetype": mimeType, "msgtype": msgtype,
				})
				return
			}
		}
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
		// Record the attachment on the cached message so a later backfill /
		// "WA sync" re-injects the media instead of dropping it to text.
		if b.st != nil {
			if uerr := b.st.UpdateMessageMedia(context.Background(), roomID, msgID, mimeType, int64(len(data))); uerr != nil {
				b.appendLog("[Bridge] UpdateMessageMedia failed: " + uerr.Error())
			}
		}
		b.emitter.Emit(map[string]any{
			"type":        "media_ready",
			"room_id":     roomID,
			"event_id":    eventID,
			"file_path":   tmpPath,
			"thumb_path":  "", // already sent above
			"thumb_w":     thumbW,
			"thumb_h":     thumbH,
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

// SetDeferMedia controls whether incoming attachments are downloaded on arrival
// (false, the original behaviour) or recorded as pending and fetched when the
// chat is opened / the preview is tapped (true). Dart owns the policy, since it
// knows the per-chat setting and the Android Data Saver state.
func (b *Bridge) SetDeferMedia(defer_ bool) {
	b.mu.Lock()
	b.deferMedia = defer_
	b.mu.Unlock()
}

// fetchPending downloads one pending attachment, emits media_ready, and clears
// the pending row. Returns false if it could not be fetched (left pending so a
// later attempt can retry).
func (b *Bridge) fetchPending(p localmatrix.PendingMedia) bool {
	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil || b.st == nil {
		return false
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(p.Proto, &msg); err != nil {
		b.appendLog("[Bridge] pending media unmarshal failed: " + err.Error())
		// Undecodable — drop it, retrying can never help.
		_ = b.st.DeletePendingMedia(context.Background(), p.ChatJID, p.MsgID)
		return false
	}
	data, err := client.DownloadAny(context.Background(), &msg)
	if err != nil {
		b.appendLog(fmt.Sprintf("[Bridge] pending media download failed for %s: %v", p.EventID, err))
		return false
	}
	tmpPath := b.dataDir + "/media_" + p.MsgID
	if werr := os.WriteFile(tmpPath, data, 0600); werr != nil {
		b.appendLog("[Bridge] pending media write failed: " + werr.Error())
		return false
	}
	if uerr := b.st.UpdateMessageMedia(context.Background(), p.ChatJID, p.MsgID, p.Mimetype, int64(len(data))); uerr != nil {
		b.appendLog("[Bridge] UpdateMessageMedia failed: " + uerr.Error())
	}
	_ = b.st.DeletePendingMedia(context.Background(), p.ChatJID, p.MsgID)
	b.emitter.Emit(map[string]any{
		"type":        "media_ready",
		"room_id":     p.ChatJID,
		"event_id":    p.EventID,
		"file_path":   tmpPath,
		"thumb_path":  "",
		"mimetype":    p.Mimetype,
		"size":        len(data),
		"msgtype":     p.MsgType,
		"body":        p.Body,
		"sender":      p.Sender,
		"sender_name": p.SenderName,
		"ts":          p.TS,
		"is_own":      p.IsOwn,
	})
	return true
}

// DownloadPendingForChat fetches attachments that were deferred in a chat,
// newest-first up to limit (0 = all). Called when a chat is opened. Runs in the
// background; progress arrives as media_ready events.
func (b *Bridge) DownloadPendingForChat(roomID string, limit int) error {
	if b.st == nil {
		return fmt.Errorf("store not ready")
	}
	pending, err := b.st.ListPendingMedia(context.Background(), roomID, 0)
	if err != nil {
		return err
	}
	if len(pending) == 0 {
		return nil
	}
	// Newest first — those are the messages the user is looking at.
	for i, j := 0, len(pending)-1; i < j; i, j = i+1, j-1 {
		pending[i], pending[j] = pending[j], pending[i]
	}
	if limit > 0 && len(pending) > limit {
		pending = pending[:limit]
	}
	go func() {
		for _, p := range pending {
			b.fetchPending(p)
		}
	}()
	return nil
}

// DownloadPendingMedia fetches one specific deferred attachment — the
// tap-the-preview path. Synchronous so the UI can show a spinner and report
// failure; the resulting media_ready still arrives as an event.
func (b *Bridge) DownloadPendingMedia(roomID, msgID string) error {
	if b.st == nil {
		return fmt.Errorf("store not ready")
	}
	p, err := b.st.GetPendingMedia(context.Background(), roomID, msgID)
	if err != nil {
		return err
	}
	if p == nil {
		// Already downloaded (or never deferred) — nothing to do, not an error.
		return nil
	}
	if !b.fetchPending(*p) {
		return fmt.Errorf("download failed")
	}
	return nil
}

// CountPendingMedia returns how many attachments are still deferred in a chat.
func (b *Bridge) CountPendingMedia(roomID string) int {
	if b.st == nil {
		return 0
	}
	n, err := b.st.CountPendingMedia(context.Background(), roomID)
	if err != nil {
		return 0
	}
	return n
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

// enqueueHistorySync hands a HistorySync chunk to the single background worker
// (started lazily) so chunks are cached one at a time. If the queue is full it
// falls back to processing inline (safe now that the cache DB serializes writes).
func (b *Bridge) enqueueHistorySync(data *waHistorySync.HistorySync) {
	b.histOnce.Do(func() {
		b.histCh = make(chan *waHistorySync.HistorySync, 256)
		go func() {
			for d := range b.histCh {
				b.handleHistorySync(d)
			}
		}()
	})
	select {
	case b.histCh <- data:
	default:
		go b.handleHistorySync(data)
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
	chatIDs := make([]string, 0, len(data.GetConversations()))
	for _, conv := range data.GetConversations() {
		jid, err := types.ParseJID(conv.GetID())
		if err != nil {
			continue
		}
		// Skip status updates / broadcast lists / newsletters — they're not real
		// chats and would inflate the chat count and clutter the cache.
		if jid.Server == types.BroadcastServer || jid.Server == types.NewsletterServer {
			continue
		}
		roomID := jid.User + "@" + string(jid.Server)
		chatIDs = append(chatIDs, roomID)
		isGroup := jid.Server == types.GroupServer
		chatName := conv.GetName()
		for _, hm := range conv.GetMessages() {
			if b.cacheHistoricalMessage(ctx, roomID, jid, isGroup, chatName, hm.GetMessage()) {
				cached++
			}
		}
	}
	// Update cumulative progress (distinct chats + total messages cached).
	b.mu.Lock()
	if b.histChatSet == nil {
		b.histChatSet = make(map[string]bool)
	}
	b.histTotalMsgs += cached
	for _, id := range chatIDs {
		b.histChatSet[id] = true
	}
	totalMsgs := b.histTotalMsgs
	totalChats := len(b.histChatSet)
	b.mu.Unlock()

	b.appendLog(fmt.Sprintf("[Bridge] handleHistorySync type=%s progress=%d%% convs=%d cached=%d (total %d msgs / %d chats)",
		data.GetSyncType().String(), data.GetProgress(), len(data.GetConversations()), cached, totalMsgs, totalChats))
	// Progress for the settings loading indicator. Progress is WhatsApp's own
	// 0–100 history-sync percentage (100 = done).
	b.emitter.Emit(map[string]any{
		"type":      "history_progress",
		"chats":     totalChats,
		"messages":  totalMsgs,
		"progress":  data.GetProgress(),
		"sync_type": data.GetSyncType().String(),
	})
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
	if err := b.st.CacheMessage(ctx, localmatrix.CachedMessage{
		ChatJID:       roomID,
		MsgID:         msgID,
		Sender:        "@wa_" + senderUser + ":tjena.local",
		SenderName:    b.senderDisplayName(senderJID, wmi.GetPushName()),
		TS:            int64(wmi.GetMessageTimestamp()),
		Body:          body,
		MsgType:       msgtype,
		IsOwn:         key.GetFromMe(),
		FormattedBody: b.formatMentions(msg, body),
	}, chatName, isGroup); err != nil {
		b.appendLog("[Bridge] cache history message failed: " + err.Error())
		return false
	}
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
		// If the attachment was downloaded once, its bytes are still in the app's
		// media cache under mxc://wa-media/wa_<msgID>; pass the mimetype/size so
		// the Dart side re-injects it as media instead of plain text.
		if m.MediaMime != "" {
			ev["media_mime"] = m.MediaMime
			ev["media_size"] = m.MediaSize
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
