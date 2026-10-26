package main

// double-puppet: "fast history import". Pauses double puppeting while a
// WhatsApp account is linked and its history imported, and turns it back on
// afterwards. Run it only while the bridge is stopped.
//
//	librelay.so double-puppet <bridge.db> <stash.json> pause|resume|status
//
// Why: with double puppeting your own WhatsApp messages are sent with your
// tjena account, which Synapse rate-limits (default ~1 message / 5 s). Without
// it, bridgev2 sends them as your WhatsApp contact (a bridge user), which is
// not rate-limited, so the import is fast. Those old messages then show as
// sent by "you on WhatsApp" instead of you. New messages after the import
// are double puppeted again.
//
// How: the bridge keeps the double-puppet token in "user".access_token. Its
// own logout-matrix command just clears that column; the session stays valid
// on the server. pause moves the token into the stash file (app-private, like
// the database itself), resume puts it back unless a new one was set in the
// meantime. Nothing on the server changes.

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"
)

type dpStash struct {
	PausedAt int64             `json:"paused_at"`
	Tokens   map[string]string `json:"tokens"`
}

type DPStatus struct {
	Paused   bool   `json:"paused"`
	PausedAt int64  `json:"paused_at,omitempty"`
	Users    int    `json:"users"`             // double-puppet sessions paused / restored
	Done     bool   `json:"import_done"`       // time to resume
	Why      string `json:"why,omitempty"`     // why Done is true
	Pending  string `json:"pending,omitempty"` // what the import still does
	Logins   int    `json:"new_logins"`        // accounts linked since the pause
}

// Resume after this long even if the import looks unfinished.
const dpMaxPause = 4 * time.Hour

// Resume if no account was linked this long after pausing (linking cancelled).
const dpNoLoginTimeout = 30 * time.Minute

func runDoublePuppet(args []string) error {
	if len(args) < 3 {
		return errors.New("usage: double-puppet <bridge.db> <stash.json> pause|resume|status")
	}
	var st *DPStatus
	var err error
	switch args[2] {
	case "pause":
		st, err = dpPause(args[0], args[1], time.Now())
	case "resume":
		st, err = dpResume(args[0], args[1])
	case "status":
		st, err = dpStatus(args[0], args[1], time.Now())
	default:
		err = fmt.Errorf("unknown action %q", args[2])
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(st)
}

func readStash(path string) (*dpStash, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	var s dpStash
	if err = json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("stash: %w", err)
	}
	return &s, nil
}

func writeStash(path string, s *dpStash) error {
	data, _ := json.Marshal(s)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func openRW(dbPath string) (*sql.DB, error) {
	if _, err := os.Stat(dbPath); err != nil {
		return nil, fmt.Errorf("bridge database: %w", err)
	}
	return sql.Open("sqlite3", "file:"+dbPath+"?_busy_timeout=5000&_txlock=immediate")
}

func dpPause(dbPath, stashPath string, now time.Time) (*DPStatus, error) {
	stash, err := readStash(stashPath)
	if err != nil {
		return nil, err
	}
	if stash == nil {
		stash = &dpStash{Tokens: map[string]string{}}
	}
	stash.PausedAt = now.Unix()
	db, err := openRW(dbPath)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT mxid, access_token FROM "user" WHERE access_token IS NOT NULL AND access_token<>''`)
	if err != nil {
		return nil, fmt.Errorf("read users: %w", err)
	}
	found := map[string]string{}
	for rows.Next() {
		var mxid, tok string
		if err = rows.Scan(&mxid, &tok); err != nil {
			rows.Close()
			return nil, err
		}
		found[mxid] = tok
	}
	rows.Close()
	for mxid, tok := range found {
		stash.Tokens[mxid] = tok
	}
	// Write the stash first: if this fails, the token stays in the database.
	if err = writeStash(stashPath, stash); err != nil {
		return nil, fmt.Errorf("write stash: %w", err)
	}
	for mxid := range found {
		if _, err = tx.Exec(`UPDATE "user" SET access_token=NULL WHERE mxid=?`, mxid); err != nil {
			return nil, err
		}
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	return &DPStatus{Paused: true, PausedAt: stash.PausedAt, Users: len(stash.Tokens)}, nil
}

func dpResume(dbPath, stashPath string) (*DPStatus, error) {
	stash, err := readStash(stashPath)
	if err != nil {
		return nil, err
	}
	if stash == nil {
		return &DPStatus{}, nil
	}
	db, err := openRW(dbPath)
	if err != nil {
		return nil, err
	}
	defer db.Close()
	tx, err := db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	restored := 0
	for mxid, tok := range stash.Tokens {
		// Keep a token set in the meantime ("Enable double puppeting" again).
		res, err := tx.Exec(`UPDATE "user" SET access_token=? WHERE mxid=? AND (access_token IS NULL OR access_token='')`, tok, mxid)
		if err != nil {
			return nil, err
		}
		if n, _ := res.RowsAffected(); n > 0 {
			restored++
		}
	}
	if err = tx.Commit(); err != nil {
		return nil, err
	}
	if err = os.Remove(stashPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	return &DPStatus{Users: restored}, nil
}

// dpStatus says whether the import that started after the pause is finished:
// every account linked since then has created its chats from history (the
// bridge's own history_sync_portals_need_creating flag is cleared only after
// every chat was created and filled) and has no unread history pieces.
func dpStatus(dbPath, stashPath string, now time.Time) (*DPStatus, error) {
	stash, err := readStash(stashPath)
	if err != nil || stash == nil {
		return &DPStatus{}, err
	}
	st := &DPStatus{Paused: true, PausedAt: stash.PausedAt, Users: len(stash.Tokens)}
	paused := time.Unix(stash.PausedAt, 0)
	if now.Sub(paused) > dpMaxPause {
		st.Done, st.Why = true, "time limit"
		return st, nil
	}
	db, err := sql.Open("sqlite3", "file:"+dbPath+"?mode=ro&_busy_timeout=5000")
	if err != nil {
		return nil, err
	}
	defer db.Close()
	rows, err := db.Query(`SELECT id, metadata FROM user_login`)
	if err != nil {
		return nil, err
	}
	type login struct {
		id      string
		pending bool
	}
	var fresh []login
	for rows.Next() {
		var id string
		var raw []byte
		if rows.Scan(&id, &raw) != nil {
			continue
		}
		var m struct {
			LoggedInAt   int64 `json:"logged_in_at"`
			PortalsNeedC bool  `json:"history_sync_portals_need_creating"`
		}
		_ = json.Unmarshal(raw, &m)
		if m.LoggedInAt >= stash.PausedAt-60 {
			fresh = append(fresh, login{id, m.PortalsNeedC})
		}
	}
	rows.Close()
	st.Logins = len(fresh)
	if len(fresh) == 0 {
		if now.Sub(paused) > dpNoLoginTimeout {
			st.Done, st.Why = true, "no account linked"
		} else {
			st.Pending = "waiting for you to link WhatsApp"
		}
		return st, nil
	}
	for _, l := range fresh {
		var chunks int
		_ = db.QueryRow(`SELECT count(*) FROM whatsapp_history_sync_notification WHERE user_login_id=?`, l.id).Scan(&chunks)
		if chunks > 0 || l.pending {
			st.Pending = "importing history"
			return st, nil
		}
	}
	st.Done, st.Why = true, "import finished"
	return st, nil
}
