package main

// Calls devices: one separate WhatsApp linked device per WhatsApp account of
// the bridge, used only for calls. The bridge (mautrix-whatsapp, unmodified)
// keeps its own linked device for messages; WhatsApp allows several linked
// devices per account, and the same device cannot be connected twice, so
// calls need their own. These devices ignore all messages.
//
// Accounts are keyed by their phone number digits, which is also the
// bridge's login ID and the "fi.mau.receiver" of every DM portal, so tjena
// can tell which account a chat (and so a call) belongs to.

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/polymorfa/hypermeow"
	"github.com/polymorfa/hypermeow/proto/waCompanionReg"
	"github.com/polymorfa/hypermeow/store"
	"github.com/polymorfa/hypermeow/store/sqlstore"
	"github.com/polymorfa/hypermeow/types"
	"github.com/polymorfa/hypermeow/types/events"
	waLog "github.com/polymorfa/hypermeow/util/log"
	meowcaller "github.com/purpshell/meowcaller"
	"github.com/rs/zerolog"
	"google.golang.org/protobuf/proto"

	_ "github.com/mattn/go-sqlite3"
)

// pairing timeout: WhatsApp closes the login socket after ~160 s.
const pairWindow = 160 * time.Second

type PairState struct {
	Method  string    `json:"method"`          // "code" or "qr"
	Phone   string    `json:"phone,omitempty"` // account being linked (code method)
	Code    string    `json:"code,omitempty"`
	QR      string    `json:"qr,omitempty"`
	Error   string    `json:"error,omitempty"`
	Expires time.Time `json:"expires"`
}

type AccountStatus struct {
	Phone     string `json:"phone"` // digits, = bridge login ID
	Connected bool   `json:"connected"`
	LastError string `json:"last_error,omitempty"`
}

type WAStatus struct {
	Accounts  []AccountStatus `json:"accounts"`
	Pairing   *PairState      `json:"pairing,omitempty"`
	LastError string          `json:"last_error,omitempty"`
}

type account struct {
	phone     string
	cli       *whatsmeow.Client
	mc        *meowcaller.Client
	lastError string
}

type pendingLink struct {
	cli   *whatsmeow.Client
	mc    *meowcaller.Client
	state *PairState
	want  string // phone digits we expect, "" for QR
	stop  context.CancelFunc
}

type WA struct {
	log       zerolog.Logger
	container *sqlstore.Container
	onCall    func(account string, c *meowcaller.Call)
	onChange  func()

	mu        sync.Mutex
	accounts  map[string]*account
	pending   *pendingLink
	lastError string
}

func init() {
	// Shown in WhatsApp → Linked devices. meowcaller uses a desktop browser
	// platform; WhatsApp only offers calls to desktop/web companions.
	store.DeviceProps.Os = proto.String("tjena calls")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	store.DeviceProps.RequireFullSync = proto.Bool(false)
	// Ask for as little history as possible; these devices ignore messages.
	if h := store.DeviceProps.HistorySyncConfig; h != nil {
		h.FullSyncDaysLimit = proto.Uint32(1)
		h.FullSyncSizeMbLimit = proto.Uint32(1)
		h.StorageQuotaMb = proto.Uint32(1)
	}
}

func digitsOnly(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, s)
}

func openWA(ctx context.Context, dbPath string, log zerolog.Logger, onCall func(string, *meowcaller.Call), onChange func()) (*WA, error) {
	c, err := sqlstore.New(ctx, "sqlite3",
		"file:"+dbPath+"?_foreign_keys=on&_busy_timeout=5000&_journal_mode=WAL",
		waLog.Zerolog(log.With().Str("component", "store").Logger().Level(zerolog.WarnLevel)))
	if err != nil {
		return nil, fmt.Errorf("open store: %w", err)
	}
	w := &WA{log: log, container: c, onCall: onCall, onChange: onChange, accounts: map[string]*account{}}
	devs, err := c.GetAllDevices(ctx)
	if err != nil {
		return nil, fmt.Errorf("load devices: %w", err)
	}
	for _, dev := range devs {
		if dev.ID == nil {
			continue
		}
		a := w.newAccount(dev)
		if err = a.cli.Connect(); err != nil {
			a.lastError = "connect: " + err.Error()
		}
	}
	return w, nil
}

// newClient builds a whatsmeow client with meowcaller installed (meowcaller
// must be installed before Connect).
func (w *WA) newClient(dev *store.Device, phone func() string) (*whatsmeow.Client, *meowcaller.Client) {
	cli := whatsmeow.NewClient(dev, waLog.Zerolog(w.log.With().Str("component", "wa").Logger().Level(zerolog.WarnLevel)))
	cli.ManualHistorySyncDownload = true // never download message history
	cli.EnableAutoReconnect = true
	mc := meowcaller.NewClient(cli, meowcaller.WithLogger(w.log.With().Str("component", "call").Logger().Level(zerolog.InfoLevel)))
	mc.OnIncomingCall(func(c *meowcaller.Call) { w.onCall(phone(), c) })
	return cli, mc
}

func (w *WA) newAccount(dev *store.Device) *account {
	a := &account{phone: dev.ID.User}
	a.cli, a.mc = w.newClient(dev, func() string { return a.phone })
	a.cli.AddEventHandler(func(evt any) { w.accountEvent(a, evt) })
	w.mu.Lock()
	w.accounts[a.phone] = a
	w.mu.Unlock()
	return a
}

func (w *WA) changed() {
	if w.onChange != nil {
		go w.onChange()
	}
}

func (w *WA) accountEvent(a *account, evt any) {
	switch e := evt.(type) {
	case *events.Connected:
		w.mu.Lock()
		a.lastError = ""
		w.mu.Unlock()
		w.log.Info().Str("account", redactPhone(a.phone)).Msg("calls device connected to WhatsApp")
		w.changed()
	case *events.Disconnected:
		w.changed()
	case *events.LoggedOut:
		w.log.Warn().Str("account", redactPhone(a.phone)).Str("reason", e.Reason.String()).Msg("calls device was logged out")
		go w.forget(context.Background(), a, "Logged out from WhatsApp ("+e.Reason.String()+")")
	case *events.StreamReplaced:
		w.mu.Lock()
		a.lastError = "another program connected with this calls device"
		w.mu.Unlock()
		w.changed()
	}
}

// redactPhone keeps logs free of full phone numbers.
func redactPhone(p string) string {
	if len(p) <= 4 {
		return "…"
	}
	return "…" + p[len(p)-4:]
}

// Account returns the client and caller for an account. With an empty phone
// and exactly one account, that one.
func (w *WA) Account(phone string) (*whatsmeow.Client, *meowcaller.Client, error) {
	phone = digitsOnly(phone)
	w.mu.Lock()
	defer w.mu.Unlock()
	if phone == "" {
		if len(w.accounts) == 1 {
			for _, a := range w.accounts {
				return a.cli, a.mc, nil
			}
		}
		if len(w.accounts) == 0 {
			return nil, nil, errors.New("Calls are not set up in the bridge app.")
		}
		return nil, nil, errors.New("Which WhatsApp account? (several are linked)")
	}
	a := w.accounts[phone]
	if a == nil {
		return nil, nil, fmt.Errorf("Calls are not set up for the WhatsApp account …%s in the bridge app.", lastDigits(phone))
	}
	if !a.cli.IsLoggedIn() {
		return nil, nil, fmt.Errorf("The calls device for …%s is offline.", lastDigits(phone))
	}
	return a.cli, a.mc, nil
}

func lastDigits(p string) string {
	if len(p) <= 4 {
		return p
	}
	return p[len(p)-4:]
}

func (w *WA) Status() WAStatus {
	w.mu.Lock()
	defer w.mu.Unlock()
	st := WAStatus{LastError: w.lastError, Accounts: []AccountStatus{}}
	for _, a := range w.accounts {
		st.Accounts = append(st.Accounts, AccountStatus{
			Phone: a.phone, Connected: a.cli.IsConnected() && a.cli.IsLoggedIn(), LastError: a.lastError,
		})
	}
	sort.Slice(st.Accounts, func(i, j int) bool { return st.Accounts[i].Phone < st.Accounts[j].Phone })
	if w.pending != nil {
		p := *w.pending.state
		st.Pairing = &p
	}
	return st
}

func (w *WA) setError(e string) {
	w.mu.Lock()
	w.lastError = e
	w.mu.Unlock()
	if e != "" {
		w.log.Warn().Msg(e)
	}
	w.changed()
}

// Link links a calls device for a WhatsApp account. With a phone number it
// returns a pairing code to type into WhatsApp on that phone; without, QR
// codes appear in Status(). One link at a time.
func (w *WA) Link(phone string) (*PairState, error) {
	digits := digitsOnly(phone)
	w.mu.Lock()
	if digits != "" && w.accounts[digits] != nil {
		w.mu.Unlock()
		return nil, errors.New("calls are already set up for this account")
	}
	w.mu.Unlock()
	w.CancelLink()

	ctx, cancel := context.WithTimeout(context.Background(), pairWindow)
	p := &pendingLink{want: digits, stop: cancel, state: &PairState{Phone: digits, Expires: time.Now().Add(pairWindow)}}
	dev := w.container.NewDevice()
	p.cli, p.mc = w.newClient(dev, func() string {
		if p.cli.Store.ID != nil {
			return p.cli.Store.ID.User
		}
		return ""
	})
	p.cli.AddEventHandler(func(evt any) { w.pendingEvent(p, evt) })
	w.mu.Lock()
	w.pending = p
	w.lastError = ""
	w.mu.Unlock()
	fail := func(err error) (*PairState, error) {
		cancel()
		p.cli.Disconnect()
		w.mu.Lock()
		if w.pending == p {
			w.pending = nil
		}
		w.mu.Unlock()
		return nil, err
	}

	if digits == "" {
		p.state.Method = "qr"
		qr, err := p.cli.GetQRChannel(ctx)
		if err != nil {
			return fail(err)
		}
		if err = p.cli.Connect(); err != nil {
			return fail(err)
		}
		first := make(chan struct{})
		go func() {
			var once sync.Once
			defer once.Do(func() { close(first) })
			for item := range qr {
				w.mu.Lock()
				switch item.Event {
				case "code":
					p.state.QR = item.Code
				case "success":
				default:
					p.state.Error = "Linking ended: " + item.Event
				}
				w.mu.Unlock()
				once.Do(func() { close(first) })
				w.changed()
			}
		}()
		select {
		case <-first:
		case <-time.After(15 * time.Second):
		}
		return w.Status().Pairing, nil
	}

	p.state.Method = "code"
	if err := p.cli.Connect(); err != nil {
		return fail(err)
	}
	// The login socket needs a moment before it accepts the pairing request.
	time.Sleep(time.Second)
	code, err := p.cli.PairPhone(ctx, digits, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
	if err != nil {
		return fail(err)
	}
	w.mu.Lock()
	p.state.Code = code
	w.mu.Unlock()
	go func() {
		<-ctx.Done()
		w.mu.Lock()
		stale := w.pending == p
		if stale {
			w.pending = nil
		}
		w.mu.Unlock()
		if stale && p.cli.Store.ID == nil {
			p.cli.Disconnect()
			w.setError("The pairing code expired. Start linking again.")
		}
	}()
	w.changed()
	s := *p.state
	return &s, nil
}

func (w *WA) pendingEvent(p *pendingLink, evt any) {
	switch e := evt.(type) {
	case *events.PairSuccess:
		phone := e.ID.User
		w.mu.Lock()
		if w.pending == p {
			w.pending = nil
		}
		w.mu.Unlock()
		p.stop()
		if p.want != "" && phone != p.want {
			w.log.Warn().Msg("linked a different WhatsApp account than requested; unlinking it")
			go func() {
				_ = p.cli.Logout(context.Background())
				w.setError(fmt.Sprintf("That was the WhatsApp account …%s, not …%s. Link again on the right phone.", lastDigits(phone), lastDigits(p.want)))
			}()
			return
		}
		w.mu.Lock()
		if old := w.accounts[phone]; old != nil && old.cli != p.cli {
			go old.cli.Disconnect()
		}
		a := &account{phone: phone, cli: p.cli, mc: p.mc}
		w.accounts[phone] = a
		w.lastError = ""
		w.mu.Unlock()
		// From now on events go to the account handler.
		p.cli.AddEventHandler(func(evt any) { w.accountEvent(a, evt) })
		w.log.Info().Str("account", redactPhone(phone)).Msg("calls device linked")
		w.changed()
	case *events.PairError:
		w.mu.Lock()
		if w.pending == p {
			p.state.Error = "Linking failed: " + e.Error.Error()
		}
		w.mu.Unlock()
		w.changed()
	}
}

func (w *WA) CancelLink() {
	w.mu.Lock()
	p := w.pending
	w.pending = nil
	w.mu.Unlock()
	if p == nil {
		return
	}
	p.stop()
	if p.cli.Store.ID == nil {
		p.cli.Disconnect()
	}
	w.changed()
}

// Unlink logs an account's calls device out of WhatsApp and forgets it.
func (w *WA) Unlink(ctx context.Context, phone string) error {
	phone = digitsOnly(phone)
	w.mu.Lock()
	a := w.accounts[phone]
	w.mu.Unlock()
	if a == nil {
		return nil
	}
	if err := a.cli.Logout(ctx); err != nil {
		w.log.Warn().Err(err).Msg("logout failed, deleting the device locally")
	}
	return w.forget(ctx, a, "")
}

func (w *WA) forget(ctx context.Context, a *account, why string) error {
	a.cli.Disconnect()
	w.mu.Lock()
	if w.accounts[a.phone] == a {
		delete(w.accounts, a.phone)
	}
	w.mu.Unlock()
	var err error
	if a.cli.Store.ID != nil {
		err = a.cli.Store.Delete(ctx)
	}
	w.setError(why)
	return err
}

func (w *WA) Close() {
	w.CancelLink()
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, a := range w.accounts {
		a.cli.Disconnect()
	}
}

// phoneFor returns the phone-number JID for a LID, if the account knows it.
func (w *WA) phoneFor(ctx context.Context, acct string, jid types.JID) types.JID {
	if jid.Server != types.HiddenUserServer {
		return jid
	}
	w.mu.Lock()
	a := w.accounts[acct]
	w.mu.Unlock()
	if a == nil {
		return types.EmptyJID
	}
	pn, err := a.cli.Store.LIDs.GetPNForLID(ctx, jid)
	if err != nil || pn.IsEmpty() {
		return types.EmptyJID
	}
	return pn
}
