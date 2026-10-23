// wacall: WhatsApp calls for the tjena personal bridge.
//
// Runs on the bridge phone next to the unmodified mautrix-whatsapp. It links
// its own WhatsApp device (calls only), and bridges calls to the tjena app
// over WebRTC. WhatsApp's call protocol comes from meowcaller (MIT,
// github.com/purpshell/meowcaller); see THIRD_PARTY.md.
//
//	libwacall.so < config.json
//
// The config is read from stdin so the bridge token never touches the disk.
// A small HTTP API on 127.0.0.1 lets the bridge app link and check the device.
package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/rs/zerolog"
)

var version = "0.1.0"

type Config struct {
	DataDir   string `json:"data_dir"`
	Listen    string `json:"listen"`     // 127.0.0.1:port
	APISecret string `json:"api_secret"` // protects the local API
	Gateway   string `json:"gateway"`    // https://wap.tjena.eu
	Token     string `json:"token"`      // bridge token; authenticates us at the gateway
	LogLevel  string `json:"log_level"`
}

type Daemon struct {
	cfg Config
	log zerolog.Logger
	wa  *WA
	sig *Signal
	mgr *Manager
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println("wacall", version)
		return
	}
	var cfg Config
	if err := json.NewDecoder(os.Stdin).Decode(&cfg); err != nil {
		fmt.Fprintln(os.Stderr, "read config from stdin:", err)
		os.Exit(2)
	}
	lvl, err := zerolog.ParseLevel(cfg.LogLevel)
	if err != nil || cfg.LogLevel == "" {
		lvl = zerolog.InfoLevel
	}
	log := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr, NoColor: true, TimeFormat: time.TimeOnly}).
		Level(lvl).With().Timestamp().Logger()
	if err = run(cfg, log); err != nil {
		log.Error().Err(err).Msg("wacall stopped")
		os.Exit(1)
	}
}

func run(cfg Config, log zerolog.Logger) error {
	if cfg.DataDir == "" || cfg.Listen == "" || cfg.APISecret == "" {
		return errors.New("config needs data_dir, listen and api_secret")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	d := &Daemon{cfg: cfg, log: log}
	d.mgr = newManager(log)
	wa, err := openWA(ctx, filepath.Join(cfg.DataDir, "wacall.db"), log, d.mgr.Incoming, d.pushStatus)
	if err != nil {
		return err
	}
	d.wa = wa
	d.mgr.wa = wa
	defer wa.Close()

	if cfg.Gateway != "" && cfg.Token != "" {
		d.sig = newSignal(cfg.Gateway, cfg.Token, log, d.onMessage)
		d.mgr.send = d.sig.Send
		go d.sig.Run(ctx)
	} else {
		d.mgr.send = func(Msg) {}
		log.Warn().Msg("no gateway configured; calls from the app are not possible")
	}

	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	srv := &http.Server{Handler: d.api(), ReadHeaderTimeout: 10 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	log.Info().Str("version", version).Str("listen", cfg.Listen).Msg("wacall running")

	<-ctx.Done()
	d.mgr.HangupAll()
	sctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	return nil
}

// onMessage handles a message from an app.
func (d *Daemon) onMessage(m Msg) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	switch m.Type {
	case "hello", "status":
		st := d.wa.Status()
		st.Pairing = nil // pairing codes stay on the phone
		d.sig.Send(Msg{Type: "status", To: m.From, Status: &st, Calls: d.mgr.Ringing()})
	case "call":
		d.mgr.Dial(ctx, m)
	case "answer":
		d.mgr.Answer(ctx, m)
	case "reject":
		d.mgr.Reject(m)
	case "hangup":
		d.mgr.Hangup(m)
	case "app_gone":
		d.mgr.AppGone(m.From)
	case "phone":
		// gateway notice, ignore
	default:
		d.log.Debug().Str("type", m.Type).Msg("unknown message")
	}
}

// pushStatus tells connected apps when the calls device goes on/offline.
func (d *Daemon) pushStatus() {
	if d.sig == nil || d.wa == nil {
		return
	}
	st := d.wa.Status()
	st.Pairing = nil
	d.sig.Send(Msg{Type: "status", Status: &st})
}

// ---------------------------------------------------------------- local API

func (d *Daemon) api() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /status", func(w http.ResponseWriter, r *http.Request) {
		active, ring := d.mgr.counts()
		gw := map[string]any{"configured": d.sig != nil}
		if d.sig != nil {
			ok, e := d.sig.Status()
			gw["connected"], gw["error"] = ok, e
		}
		writeJSON(w, 200, map[string]any{
			"version": version, "whatsapp": d.wa.Status(), "gateway": gw,
			"active_calls": active, "ringing": ring,
		})
	})
	mux.HandleFunc("POST /link", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Phone string `json:"phone"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body)
		ps, err := d.wa.Link(body.Phone)
		if err != nil {
			writeJSON(w, 400, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, 200, ps)
	})
	mux.HandleFunc("POST /link/cancel", func(w http.ResponseWriter, r *http.Request) {
		d.wa.CancelLink()
		writeJSON(w, 200, map[string]any{})
	})
	mux.HandleFunc("POST /unlink", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Phone string `json:"phone"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body)
		if digitsOnly(body.Phone) == "" {
			writeJSON(w, 400, map[string]string{"error": "phone is required"})
			return
		}
		if err := d.wa.Unlink(r.Context(), body.Phone); err != nil {
			writeJSON(w, 500, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, 200, map[string]any{})
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+d.cfg.APISecret)) != 1 {
			writeJSON(w, 401, map[string]string{"error": "unauthorized"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
