// bridge-gateway connects personal mautrix bridges (running on phones at
// home, behind NAT) to Synapse without restarting Synapse per bridge.
//
//   - Slot pool: a batch of appservice registrations is installed in Synapse
//     once. Each slot has its own namespace (@wa07bot, @wa07_*) and real
//     tokens that never leave the gateway.
//   - Provisioner: a tjena user signs in from the bridge app and is assigned a
//     free slot. The app gets per-bridge tokens, which the gateway swaps for
//     the real ones. Revoking a bridge = deleting its tokens (instant).
//   - Relay: Synapse pushes transactions to the internal listener; they go
//     down the bridge's websocket verbatim (mautrix appservice websocket v3).
//     The bridge's client-API calls come back through the public listener.
//
// Usage:
//
//	bridge-gateway -config config.yaml serve
//	bridge-gateway -config config.yaml slots-add 20
//	bridge-gateway -config config.yaml slots-list
//	bridge-gateway -config config.yaml snippet
//	bridge-gateway -config config.yaml claim @user:tjena.eu       (prints bridge bundle)
//	bridge-gateway -config config.yaml assign wa03 @user:tjena.eu
//	bridge-gateway -config config.yaml revoke wa03
//	bridge-gateway -config config.yaml check-activation
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/coder/websocket"
)

func main() {
	configPath := flag.String("config", "/data/config.yaml", "path to config file")
	debug := flag.Bool("debug", false, "debug logging")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: bridge-gateway [-config path] <serve|slots-add N|slots-list|snippet|claim MXID|assign SLOT MXID|revoke SLOT|check-activation>")
		flag.PrintDefaults()
	}
	flag.Parse()
	level := slog.LevelInfo
	if *debug {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	cfg, err := loadConfig(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	args := flag.Args()
	if len(args) == 0 {
		flag.Usage()
		os.Exit(2)
	}
	if args[0] == "serve" {
		serve(cfg, log)
		return
	}
	if err = runCLI(cfg, log, args); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func serve(cfg *Config, log *slog.Logger) {
	g, err := newGateway(cfg, log)
	if err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go g.activationLoop(ctx)

	public := &http.Server{Addr: cfg.PublicListen, Handler: g.publicRoutes(), ReadHeaderTimeout: 15 * time.Second}
	internal := &http.Server{Addr: cfg.InternalListen, Handler: g.internalRoutes(), ReadHeaderTimeout: 15 * time.Second}
	for _, s := range []*http.Server{public, internal} {
		go func(s *http.Server) {
			log.Info("listening", "addr", s.Addr)
			if err := s.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
				log.Error("listener failed", "addr", s.Addr, "err", err)
				os.Exit(1)
			}
		}(s)
	}
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
	g.mu.RLock()
	for _, c := range g.conns {
		c.close(websocket.StatusServiceRestart, "server_shutting_down")
	}
	g.mu.RUnlock()
	sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer scancel()
	_ = public.Shutdown(sctx)
	_ = internal.Shutdown(sctx)
}

// runCLI sends admin commands to the running gateway (internal listener). If
// none is running, it works on the state file directly.
func runCLI(cfg *Config, log *slog.Logger, args []string) error {
	var op string
	body := map[string]any{}
	switch args[0] {
	case "slots-add":
		if len(args) != 2 {
			return errors.New("usage: slots-add N")
		}
		n, err := strconv.Atoi(args[1])
		if err != nil {
			return err
		}
		op, body["count"] = "slots-add", n
	case "assign":
		if len(args) != 3 {
			return errors.New("usage: assign SLOT MXID")
		}
		op, body["slot"], body["user"] = "assign", args[1], args[2]
	case "claim":
		if len(args) != 2 {
			return errors.New("usage: claim MXID")
		}
		op, body["user"] = "claim", args[1]
	case "revoke":
		if len(args) != 2 {
			return errors.New("usage: revoke SLOT")
		}
		op, body["slot"] = "revoke", args[1]
	case "snippet", "check-activation":
		op = args[0]
	case "slots-list":
		op = "check-activation"
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}

	resp, err := callRunning(cfg, op, body)
	if err != nil {
		// Not running: do it offline on the state file.
		g, gerr := newGateway(cfg, log)
		if gerr != nil {
			return gerr
		}
		rec := &recorder{header: http.Header{}}
		data, _ := json.Marshal(body)
		req, _ := http.NewRequest(http.MethodPost, "/_tjena/admin/"+op, bytes.NewReader(data))
		req.Header.Set("Authorization", "Bearer "+g.adminToken)
		req.SetPathValue("op", op)
		g.handleAdmin(rec, req)
		resp = rec.buf.Bytes()
		if rec.status >= 400 {
			return errors.New(string(resp))
		}
	}
	return printResult(args[0], resp)
}

func callRunning(cfg *Config, op string, body map[string]any) ([]byte, error) {
	tok, err := os.ReadFile(cfg.DataDir + "/admin_token")
	if err != nil {
		return nil, err
	}
	host, port, _ := net.SplitHostPort(cfg.InternalListen)
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, "http://"+net.JoinHostPort(host, port)+"/_tjena/admin/"+op, bytes.NewReader(data))
	req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(tok)))
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("gateway: %s", out)
	}
	return out, nil
}

func printResult(cmd string, data []byte) error {
	switch cmd {
	case "slots-list", "check-activation":
		var res struct{ Slots []slotStatus }
		if err := json.Unmarshal(data, &res); err != nil {
			return err
		}
		tw := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(tw, "SLOT\tSTATE\tACTIVE\tOWNER\tCONNECTED\tLAST SEEN")
		for _, s := range res.Slots {
			last := ""
			if s.LastSeen != nil {
				last = s.LastSeen.Format(time.RFC3339)
			}
			fmt.Fprintf(tw, "%s\t%s\t%v\t%s\t%v\t%s\n", s.Slot, s.State, s.Active, s.Owner, s.Connected, last)
		}
		return tw.Flush()
	case "slots-add", "snippet":
		var res map[string]any
		if err := json.Unmarshal(data, &res); err != nil {
			return err
		}
		if c, ok := res["created"]; ok {
			fmt.Println("Created slots:", c)
			fmt.Println("Registration files were written to registration_dir. Add them to homeserver.yaml and restart Synapse once:")
		}
		fmt.Println(res["synapse_snippet"])
		return nil
	default:
		var pretty bytes.Buffer
		_ = json.Indent(&pretty, data, "", "  ")
		fmt.Println(pretty.String())
		return nil
	}
}

type recorder struct {
	header http.Header
	status int
	buf    bytes.Buffer
}

func (r *recorder) Header() http.Header         { return r.header }
func (r *recorder) Write(b []byte) (int, error) { return r.buf.Write(b) }
func (r *recorder) WriteHeader(s int)           { r.status = s }
