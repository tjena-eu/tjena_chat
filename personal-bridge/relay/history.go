package main

// history-info: how far the WhatsApp history import got, for the bridge
// app's "History import" screen. Reads the bridge database (read-only) and
// its JSON log file. Nothing here changes the bridge.
//
//	librelay.so history-info <bridge.db> <log_dir>
//
// How the import works (mautrix-whatsapp, unmodified):
//  1. The phone sends the history in chunks. Each chunk's messages are stored
//     in whatsapp_history_sync_message.
//  2. Once no chunk arrived for history_sync.dispatch_wait, a room is created
//     for each recent chat and filled from the stored messages, oldest first.
//     Stored messages of that chat are then deleted.
//  3. If one message fails to send (for example Synapse rate-limits your own
//     messages sent through double puppeting), the rest of that chat is
//     skipped and its stored messages stay in the table. Those are counted
//     here as "not copied".

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "github.com/mattn/go-sqlite3"
)

type HistoryInfo struct {
	Logins []HistoryLogin `json:"logins"`
	Log    HistoryLog     `json:"log"`
	Errors []string       `json:"errors,omitempty"`
}

type HistoryLogin struct {
	ID                 string        `json:"id"`
	Name               string        `json:"name"`
	LoggedInAt         int64         `json:"logged_in_at"`
	RoomsPending       bool          `json:"rooms_pending"` // chat rooms not created yet
	PendingChunks      int           `json:"pending_chunks"`
	Conversations      int           `json:"conversations"`       // chats the phone sent history for
	ConversationsRooms int           `json:"conversations_rooms"` // ... that got a room
	StoredMessages     int           `json:"stored_messages"`     // history waiting in the bridge DB
	NotCopied          int           `json:"not_copied"`          // stored, but the chat's room exists
	Fillable           int           `json:"fillable"`            // ... and newer than the room's newest message
	BlockedChats       int           `json:"blocked_chats"`       // chats with not-copied history all older than the room's newest message
	Rooms              int           `json:"rooms"`
	BridgedMessages    int           `json:"bridged_messages"`
	Chats              []HistoryChat `json:"chats"`
}

type HistoryChat struct {
	JID        string `json:"jid"`
	Name       string `json:"name"`
	HasRoom    bool   `json:"has_room"`
	Bridged    int    `json:"bridged"`     // messages in the room
	Stored     int    `json:"stored"`      // history still waiting in the DB
	Backfilled int    `json:"backfilled"`  // messages the bridge tried to copy (log)
	Failed     bool   `json:"failed"`      // copying stopped with an error (log)
	RateLimit  bool   `json:"rate_limit"`  // ... because Synapse said "too many requests"
	LastMsgTS  int64  `json:"last_msg_ts"` // newest message on the phone, unix seconds
	RoomNewest int64  `json:"room_newest"` // newest message in the room, unix seconds
	Fillable   int    `json:"fillable"`    // stored messages newer than RoomNewest (catch-up can add these)
}

type HistoryChunk struct {
	Time          string `json:"time"`
	Type          string `json:"type"`
	Order         int    `json:"order"`
	Progress      int    `json:"progress"`
	Conversations int    `json:"conversations"`
}

type HistoryLog struct {
	Found             bool           `json:"found"`
	Since             string         `json:"since,omitempty"`
	Chunks            []HistoryChunk `json:"chunks"`
	Progress          map[string]int `json:"progress"` // sync type -> last percentage
	Saved             int            `json:"saved"`
	SaveFailed        int            `json:"save_failed"`
	Ignored           int            `json:"ignored"` // message types that are never bridged
	ParseDropped      int            `json:"parse_dropped"`
	RoomsCreating     bool           `json:"rooms_creating"`
	RoomsTarget       int            `json:"rooms_target"`
	RoomsDone         bool           `json:"rooms_done"`
	BackfillChats     int            `json:"backfill_chats"`
	BackfillMessages  int            `json:"backfill_messages"`
	BackfillFailed    int            `json:"backfill_failed"`
	SendFailed        int            `json:"send_failed"`
	RateLimited       int            `json:"rate_limited"`
	RecentErrors      []LogProblem   `json:"recent_errors"`
	perPortalSent     map[string]int
	perPortalFailed   map[string]bool
	perPortalRateLimt map[string]bool
}

type LogProblem struct {
	Time  string `json:"time"`
	Level string `json:"level"`
	Msg   string `json:"msg"`
	Error string `json:"error,omitempty"`
	Chat  string `json:"chat,omitempty"`
}

func runHistoryInfo(args []string) error {
	if len(args) < 2 {
		return errors.New("usage: history-info <bridge.db> <log_dir>")
	}
	info, err := historyInfo(args[0], args[1])
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(info)
}

func historyInfo(dbPath, logDir string) (*HistoryInfo, error) {
	if _, err := os.Stat(dbPath); err != nil {
		return nil, fmt.Errorf("bridge database: %w", err)
	}
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?mode=ro&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	defer db.Close()
	info := &HistoryInfo{Logins: []HistoryLogin{}}
	addErr := func(what string, err error) {
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			info.Errors = append(info.Errors, what+": "+err.Error())
		}
	}

	rows, err := db.Query("SELECT id, remote_name, metadata FROM user_login")
	addErr("logins", err)
	if err == nil {
		for rows.Next() {
			var l HistoryLogin
			var meta []byte
			if rows.Scan(&l.ID, &l.Name, &meta) != nil {
				continue
			}
			var m struct {
				LoggedInAt   int64 `json:"logged_in_at"`
				PortalsNeedC bool  `json:"history_sync_portals_need_creating"`
			}
			_ = json.Unmarshal(meta, &m)
			l.LoggedInAt, l.RoomsPending = m.LoggedInAt, m.PortalsNeedC
			l.Chats = []HistoryChat{}
			info.Logins = append(info.Logins, l)
		}
		rows.Close()
	}

	var since time.Time
	for _, l := range info.Logins {
		t := time.Unix(l.LoggedInAt, 0)
		if l.LoggedInAt > 0 && (since.IsZero() || t.Before(since)) {
			since = t
		}
	}
	info.Log = readHistoryLog(logDir, since)

	for i := range info.Logins {
		l := &info.Logins[i]
		count := func(q string, args ...any) int {
			var n int
			addErr("count", db.QueryRow(q, args...).Scan(&n))
			return n
		}
		l.PendingChunks = count("SELECT count(*) FROM whatsapp_history_sync_notification WHERE user_login_id=?", l.ID)

		chats := map[string]*HistoryChat{}
		get := func(jid string) *HistoryChat {
			c := chats[jid]
			if c == nil {
				c = &HistoryChat{JID: jid}
				chats[jid] = c
			}
			return c
		}
		// Rooms of this login, with their bridged message counts.
		rows, err := db.Query(`SELECT p.id, p.name, p.mxid,
				(SELECT count(DISTINCT m.id) FROM message m WHERE m.room_id=p.id AND m.room_receiver=p.receiver)
			FROM portal p JOIN user_portal up ON up.portal_id=p.id AND up.portal_receiver=p.receiver
			WHERE up.login_id=?`, l.ID)
		addErr("rooms", err)
		if err == nil {
			for rows.Next() {
				var jid, name string
				var mxid sql.NullString
				var n int
				if rows.Scan(&jid, &name, &mxid, &n) != nil {
					continue
				}
				c := get(jid)
				c.Name, c.HasRoom, c.Bridged = name, mxid.Valid && mxid.String != "", n
				var newest sql.NullInt64
				_ = db.QueryRow(`SELECT max(timestamp) FROM message WHERE room_id=? AND room_receiver=?`, jid, l.ID).Scan(&newest)
				if !newest.Valid {
					// group portals have an empty receiver
					_ = db.QueryRow(`SELECT max(timestamp) FROM message WHERE room_id=?`, jid).Scan(&newest)
				}
				if newest.Valid {
					c.RoomNewest = newest.Int64 / 1e9
				}
				if c.HasRoom {
					l.Rooms++
					l.BridgedMessages += n
				}
			}
			rows.Close()
		}
		// Chats the phone sent history for.
		rows, err = db.Query(`SELECT chat_jid, coalesce(last_message_timestamp, 0),
				(SELECT count(*) FROM whatsapp_history_sync_message hm
					WHERE hm.user_login_id=hc.user_login_id AND hm.chat_jid=hc.chat_jid)
			FROM whatsapp_history_sync_conversation hc WHERE user_login_id=?`, l.ID)
		addErr("history", err)
		if err == nil {
			for rows.Next() {
				var jid string
				var ts int64
				var stored int
				if rows.Scan(&jid, &ts, &stored) != nil {
					continue
				}
				c := get(jid)
				c.LastMsgTS, c.Stored = ts, stored
				l.Conversations++
				l.StoredMessages += stored
				if c.HasRoom {
					l.ConversationsRooms++
					l.NotCopied += stored
					if stored > 0 {
						// The bridge only catches up when the phone's newest message is newer
						// than the room's, and then only adds messages after the room's newest.
						if ts > c.RoomNewest {
							_ = db.QueryRow(`SELECT count(*) FROM whatsapp_history_sync_message
								WHERE user_login_id=? AND chat_jid=? AND timestamp>?`, l.ID, jid, c.RoomNewest).Scan(&c.Fillable)
						}
						l.Fillable += c.Fillable
						if c.Fillable == 0 {
							l.BlockedChats++
						}
					}
				}
			}
			rows.Close()
		}
		for jid, c := range chats {
			c.Backfilled = info.Log.perPortalSent[jid]
			c.Failed = info.Log.perPortalFailed[jid]
			c.RateLimit = info.Log.perPortalRateLimt[jid]
			l.Chats = append(l.Chats, *c)
		}
		// Problems first, then newest.
		sort.Slice(l.Chats, func(a, b int) bool {
			ca, cb := l.Chats[a], l.Chats[b]
			pa, pb := ca.Failed || (ca.HasRoom && ca.Stored > 0), cb.Failed || (cb.HasRoom && cb.Stored > 0)
			if pa != pb {
				return pa
			}
			return ca.LastMsgTS > cb.LastMsgTS
		})
		if len(l.Chats) > 300 {
			l.Chats = l.Chats[:300]
		}
	}
	return info, nil
}

// readHistoryLog summarises the bridge's JSON log since [since] (the first
// login). Only counts, ids and error texts; no message content is logged.
func readHistoryLog(dir string, since time.Time) HistoryLog {
	out := HistoryLog{
		Chunks: []HistoryChunk{}, Progress: map[string]int{}, RecentErrors: []LogProblem{},
		perPortalSent: map[string]int{}, perPortalFailed: map[string]bool{}, perPortalRateLimt: map[string]bool{},
	}
	files, _ := filepath.Glob(filepath.Join(dir, "bridge*.log"))
	sort.Slice(files, func(i, j int) bool { // rotated backups first, current file last
		ci, cj := filepath.Base(files[i]) == "bridge.log", filepath.Base(files[j]) == "bridge.log"
		if ci != cj {
			return cj
		}
		return files[i] < files[j]
	})
	if !since.IsZero() {
		out.Since = since.UTC().Format(time.RFC3339)
		since = since.Add(-time.Minute)
	}
	for _, f := range files {
		fh, err := os.Open(f)
		if err != nil {
			continue
		}
		out.Found = true
		sc := bufio.NewScanner(fh)
		sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
		for sc.Scan() {
			line := sc.Bytes()
			var e map[string]any
			if json.Unmarshal(line, &e) != nil {
				continue
			}
			ts, _ := e["time"].(string)
			if !since.IsZero() {
				if t, err := time.Parse(time.RFC3339Nano, ts); err == nil && t.Before(since) {
					continue
				}
			}
			out.add(e, ts)
		}
		fh.Close()
	}
	if len(out.Chunks) > 60 {
		out.Chunks = out.Chunks[len(out.Chunks)-60:]
	}
	if len(out.RecentErrors) > 40 {
		out.RecentErrors = out.RecentErrors[len(out.RecentErrors)-40:]
	}
	return out
}

func num(e map[string]any, k string) int {
	if v, ok := e[k].(float64); ok {
		return int(v)
	}
	return 0
}

func str(e map[string]any, k string) string {
	s, _ := e[k].(string)
	return s
}

func isRateLimit(s string) bool {
	return strings.Contains(s, "M_LIMIT_EXCEEDED") || strings.Contains(s, "HTTP 429") || strings.Contains(s, "Too Many Requests")
}

func (out *HistoryLog) add(e map[string]any, ts string) {
	msg, level, errText := str(e, "message"), str(e, "level"), str(e, "error")
	portal := str(e, "portal_id")
	switch msg {
	case "Storing history sync":
		t := strings.TrimPrefix(str(e, "sync_type"), "HistorySync_")
		out.Chunks = append(out.Chunks, HistoryChunk{
			Time: ts, Type: t, Order: num(e, "chunk_order"), Progress: num(e, "progress"),
			Conversations: num(e, "conversation_count"),
		})
		out.Progress[t] = num(e, "progress")
	case "Finished storing history sync":
		out.Saved += num(e, "total_saved_count")
		out.SaveFailed += num(e, "total_failed_count")
	case "Collected messages to save from history sync conversation":
		out.Ignored += num(e, "ignored_msg_type_count")
	case "Dropping historical message due to parse error":
		out.ParseDropped++
	case "Creating portals from history sync":
		out.RoomsCreating, out.RoomsDone = true, false
		out.RoomsTarget = num(e, "conversation_count")
	case "Finished processing all history sync chat resync events":
		out.RoomsDone = true
	case "Sending backfill messages":
		out.BackfillChats++
		out.BackfillMessages += num(e, "message_count")
		if portal != "" {
			out.perPortalSent[portal] += num(e, "message_count")
		}
	case "Failed to send forward backfill", "Failed to send backfill messages":
		out.BackfillFailed++
		if portal != "" {
			out.perPortalFailed[portal] = true
			if isRateLimit(errText) {
				out.perPortalRateLimt[portal] = true
			}
		}
	case "Failed to send message part to Matrix":
		out.SendFailed++
	}
	if isRateLimit(errText) || (level == "warn" && isRateLimit(msg)) {
		out.RateLimited++
		if portal != "" {
			out.perPortalRateLimt[portal] = true
		}
	}
	if level == "error" || level == "fatal" {
		if len(errText) > 300 {
			errText = errText[:300] + "…"
		}
		out.RecentErrors = append(out.RecentErrors, LogProblem{Time: ts, Level: level, Msg: msg, Error: errText, Chat: portal})
	}
}

// history-catchup: lets the bridge finish chats whose history import stopped
// early. Run it only while the bridge is stopped.
//
//	librelay.so history-catchup <bridge.db>
//
// It uses the bridge's own mechanism, nothing new: for each chat that has a
// room but still has stored history, the "already created" mark on the
// conversation is cleared, and the login's history_sync_portals_need_creating
// flag is set again. On the next start the bridge re-runs "create portals
// from history sync" for those chats. Their rooms exist, so it sends a chat
// resync, and bridgev2 forward-fills every message newer than the last one in
// the room from the stored history (up to backfill.max_catchup_messages).
// Messages that are older than a message already in the room can't be put
// in between afterwards; those stay missing.
type CatchupResult struct {
	Chats  int            `json:"chats"`
	Stored int            `json:"stored"`
	Logins map[string]int `json:"logins"`
}

func runHistoryCatchup(args []string) error {
	if len(args) < 1 {
		return errors.New("usage: history-catchup <bridge.db>")
	}
	res, err := historyCatchup(args[0])
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(res)
}

func historyCatchup(dbPath string) (*CatchupResult, error) {
	if _, err := os.Stat(dbPath); err != nil {
		return nil, fmt.Errorf("bridge database: %w", err)
	}
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?_busy_timeout=5000&_txlock=immediate")
	if err != nil {
		return nil, err
	}
	defer db.Close()
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	type chat struct {
		login, jid string
		stored     int
	}
	var chats []chat
	rows, err := tx.Query(`SELECT hc.user_login_id, hc.chat_jid,
			(SELECT count(*) FROM whatsapp_history_sync_message hm
				WHERE hm.user_login_id=hc.user_login_id AND hm.chat_jid=hc.chat_jid) AS stored
		FROM whatsapp_history_sync_conversation hc
		WHERE EXISTS (SELECT 1 FROM portal p JOIN user_portal up
				ON up.portal_id=p.id AND up.portal_receiver=p.receiver
			WHERE up.login_id=hc.user_login_id AND p.id=hc.chat_jid
				AND p.mxid IS NOT NULL AND p.mxid<>'')`)
	if err != nil {
		return nil, fmt.Errorf("find chats: %w", err)
	}
	for rows.Next() {
		var c chat
		if err = rows.Scan(&c.login, &c.jid, &c.stored); err != nil {
			rows.Close()
			return nil, err
		}
		if c.stored > 0 {
			chats = append(chats, c)
		}
	}
	rows.Close()

	res := &CatchupResult{Logins: map[string]int{}}
	for _, c := range chats {
		if _, err = tx.Exec(`UPDATE whatsapp_history_sync_conversation SET synced_login_ts=NULL
			WHERE user_login_id=? AND chat_jid=?`, c.login, c.jid); err != nil {
			return nil, fmt.Errorf("reset chat: %w", err)
		}
		res.Chats++
		res.Stored += c.stored
		res.Logins[c.login]++
	}
	for login := range res.Logins {
		var raw []byte
		if err = tx.QueryRow(`SELECT metadata FROM user_login WHERE id=?`, login).Scan(&raw); err != nil {
			return nil, fmt.Errorf("read login: %w", err)
		}
		meta := map[string]any{}
		if len(raw) > 0 {
			if err = json.Unmarshal(raw, &meta); err != nil {
				return nil, fmt.Errorf("login metadata: %w", err)
			}
		}
		meta["history_sync_portals_need_creating"] = true
		raw, _ = json.Marshal(meta)
		if _, err = tx.Exec(`UPDATE user_login SET metadata=? WHERE id=?`, string(raw), login); err != nil {
			return nil, fmt.Errorf("update login: %w", err)
		}
	}
	return res, tx.Commit()
}
