package main

import (
	"database/sql"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func limitedUpstream(limitFirst int, retryMS int) (*httptest.Server, *atomic.Int64, *atomic.Int64) {
	var calls, ok atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		body, _ := io.ReadAll(r.Body)
		if n <= int64(limitFirst) {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte(`{"errcode":"M_LIMIT_EXCEEDED","retry_after_ms":` + itoa(retryMS) + `}`))
			return
		}
		if string(body) != `{"body":"hi"}` {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		ok.Add(1)
		_, _ = w.Write([]byte(`{"event_id":"$e"}`))
	}))
	return srv, &calls, &ok
}

func itoa(i int) string { b, _ := json.Marshal(i); return string(b) }

func proxyTo(t *testing.T, upstream string) (http.Handler, *pacer) {
	r := &Relay{cfg: Config{Upstream: upstream}, pace: newPacer()}
	return r.pace.wrap(r.httpProxy()), r.pace
}

func send(h http.Handler, txn string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPut,
		"/_matrix/client/v3/rooms/!r:x/send/m.room.message/"+txn+"?user_id=@me:x",
		strings.NewReader(`{"body":"hi"}`))
	req.Header.Set("Authorization", "Bearer tok")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func TestPaceRetries429(t *testing.T) {
	srv, calls, ok := limitedUpstream(2, 150)
	defer srv.Close()
	h, p := proxyTo(t, srv.URL)
	start := time.Now()
	rec := send(h, "1")
	if rec.Code != 200 || ok.Load() != 1 || calls.Load() != 3 {
		t.Fatalf("code %d ok %d calls %d", rec.Code, ok.Load(), calls.Load())
	}
	if time.Since(start) < 300*time.Millisecond {
		t.Fatal("did not wait retry_after_ms")
	}
	if s := p.status(); s.RateLimitHits != 2 || s.Retried != 2 || s.HandedBack != 0 {
		t.Fatalf("status %+v", s)
	}
	// Next send of the same sender is spaced out (learned interval).
	start = time.Now()
	if send(h, "2").Code != 200 || time.Since(start) < 100*time.Millisecond {
		t.Fatal("second send not paced")
	}
}

func TestPaceHandsBackWithRetryAfter(t *testing.T) {
	old := paceMaxHold
	paceMaxHold = 100 * time.Millisecond
	defer func() { paceMaxHold = old }()
	srv, _, ok := limitedUpstream(100, 5000)
	defer srv.Close()
	h, p := proxyTo(t, srv.URL)
	rec := send(h, "1")
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") == "" || ok.Load() != 0 {
		t.Fatalf("code %d retry-after %q", rec.Code, rec.Header().Get("Retry-After"))
	}
	if p.status().HandedBack != 1 {
		t.Fatalf("status %+v", p.status())
	}
}

func TestPaceLeavesOtherRequestsAlone(t *testing.T) {
	srv, calls, _ := limitedUpstream(1, 10)
	defer srv.Close()
	h, _ := proxyTo(t, srv.URL)
	req := httptest.NewRequest(http.MethodGet, "/_matrix/client/v3/rooms/!r:x/messages", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusTooManyRequests || calls.Load() != 1 {
		t.Fatalf("GET must pass through unchanged: %d", rec.Code)
	}
}

func TestHistoryCatchup(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bridge.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`CREATE TABLE user_login (bridge_id TEXT, id TEXT, remote_name TEXT, metadata TEXT)`,
		`CREATE TABLE portal (id TEXT, receiver TEXT, mxid TEXT, name TEXT)`,
		`CREATE TABLE user_portal (login_id TEXT, portal_id TEXT, portal_receiver TEXT)`,
		`CREATE TABLE whatsapp_history_sync_conversation (user_login_id TEXT, chat_jid TEXT, synced_login_ts BIGINT, last_message_timestamp BIGINT)`,
		`CREATE TABLE whatsapp_history_sync_message (user_login_id TEXT, chat_jid TEXT)`,
		`INSERT INTO user_login VALUES ('wa','L1','me','{"logged_in_at":100,"history_sync_portals_need_creating":false,"other":1}')`,
		// gap: room + stored messages
		`INSERT INTO portal VALUES ('a@s','L1','!a:x','A')`,
		`INSERT INTO user_portal VALUES ('L1','a@s','L1')`,
		`INSERT INTO whatsapp_history_sync_conversation VALUES ('L1','a@s',100,5)`,
		`INSERT INTO whatsapp_history_sync_message VALUES ('L1','a@s'),('L1','a@s')`,
		// complete: room, nothing stored
		`INSERT INTO portal VALUES ('b@s','L1','!b:x','B')`,
		`INSERT INTO user_portal VALUES ('L1','b@s','L1')`,
		`INSERT INTO whatsapp_history_sync_conversation VALUES ('L1','b@s',100,6)`,
		// no room: left alone
		`INSERT INTO whatsapp_history_sync_conversation VALUES ('L1','c@s',NULL,1)`,
		`INSERT INTO whatsapp_history_sync_message VALUES ('L1','c@s')`,
	} {
		if _, err = db.Exec(q); err != nil {
			t.Fatal(q, err)
		}
	}
	db.Close()
	res, err := historyCatchup(path)
	if err != nil {
		t.Fatal(err)
	}
	if res.Chats != 1 || res.Stored != 2 || res.Logins["L1"] != 1 {
		t.Fatalf("result %+v", res)
	}
	db, _ = sql.Open("sqlite3", path)
	defer db.Close()
	var a, b sql.NullInt64
	_ = db.QueryRow(`SELECT synced_login_ts FROM whatsapp_history_sync_conversation WHERE chat_jid='a@s'`).Scan(&a)
	_ = db.QueryRow(`SELECT synced_login_ts FROM whatsapp_history_sync_conversation WHERE chat_jid='b@s'`).Scan(&b)
	if a.Valid || !b.Valid {
		t.Fatalf("synced marks wrong: a=%v b=%v", a, b)
	}
	var meta string
	_ = db.QueryRow(`SELECT metadata FROM user_login`).Scan(&meta)
	var m map[string]any
	_ = json.Unmarshal([]byte(meta), &m)
	if m["history_sync_portals_need_creating"] != true || m["other"] != float64(1) || m["logged_in_at"] != float64(100) {
		t.Fatalf("metadata %s", meta)
	}
}
