package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func dpDB(t *testing.T) (string, string) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bridge.db")
	db, err := sql.Open("sqlite3", path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, q := range []string{
		`CREATE TABLE "user" (bridge_id TEXT, mxid TEXT, management_room TEXT, access_token TEXT)`,
		`CREATE TABLE user_login (bridge_id TEXT, id TEXT, remote_name TEXT, metadata TEXT)`,
		`CREATE TABLE whatsapp_history_sync_notification (user_login_id TEXT)`,
		`INSERT INTO "user" VALUES ('', '@me:x', '!m:x', 'syt_secret')`,
		`INSERT INTO "user" VALUES ('', '@other:x', NULL, NULL)`,
	} {
		if _, err = db.Exec(q); err != nil {
			t.Fatal(q, err)
		}
	}
	return path, filepath.Join(dir, "dp-stash.json")
}

func token(t *testing.T, path, mxid string) string {
	db, _ := sql.Open("sqlite3", path)
	defer db.Close()
	var tok sql.NullString
	if err := db.QueryRow(`SELECT access_token FROM "user" WHERE mxid=?`, mxid).Scan(&tok); err != nil {
		t.Fatal(err)
	}
	return tok.String
}

func dbExec(t *testing.T, path, q string, args ...any) {
	db, _ := sql.Open("sqlite3", path)
	defer db.Close()
	if _, err := db.Exec(q, args...); err != nil {
		t.Fatal(err)
	}
}

func TestDoublePuppetPauseResume(t *testing.T) {
	path, stash := dpDB(t)
	now := time.Unix(1_000_000, 0)
	st, err := dpPause(path, stash, now)
	if err != nil || !st.Paused || st.Users != 1 {
		t.Fatalf("pause: %+v %v", st, err)
	}
	if token(t, path, "@me:x") != "" {
		t.Fatal("token still in db")
	}
	if fi, err := os.Stat(stash); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("stash file: %v %v", fi, err)
	}
	// Pausing twice keeps the stashed token.
	if st, err = dpPause(path, stash, now); err != nil || st.Users != 1 {
		t.Fatalf("second pause: %+v %v", st, err)
	}

	// Not done: nothing linked yet.
	st, _ = dpStatus(path, stash, now.Add(time.Minute))
	if st.Done || st.Pending == "" {
		t.Fatalf("status before link: %+v", st)
	}
	// Linked, chats not created yet.
	dbExec(t, path, `INSERT INTO user_login VALUES ('', 'L1', 'me', '{"logged_in_at":1000010,"history_sync_portals_need_creating":true}')`)
	st, _ = dpStatus(path, stash, now.Add(10*time.Minute))
	if st.Done || st.Logins != 1 {
		t.Fatalf("status while importing: %+v", st)
	}
	// Chats created, but a history piece is still unread.
	dbExec(t, path, `UPDATE user_login SET metadata='{"logged_in_at":1000010,"history_sync_portals_need_creating":false}'`)
	dbExec(t, path, `INSERT INTO whatsapp_history_sync_notification VALUES ('L1')`)
	if st, _ = dpStatus(path, stash, now.Add(20*time.Minute)); st.Done {
		t.Fatalf("done with unread piece: %+v", st)
	}
	dbExec(t, path, `DELETE FROM whatsapp_history_sync_notification`)
	if st, _ = dpStatus(path, stash, now.Add(20*time.Minute)); !st.Done {
		t.Fatalf("should be done: %+v", st)
	}

	st, err = dpResume(path, stash)
	if err != nil || st.Users != 1 || token(t, path, "@me:x") != "syt_secret" {
		t.Fatalf("resume: %+v %v", st, err)
	}
	if _, err = os.Stat(stash); !os.IsNotExist(err) {
		t.Fatal("stash not removed")
	}
	if st, _ = dpStatus(path, stash, now); st.Paused {
		t.Fatal("still paused")
	}
}

func TestDoublePuppetResumeKeepsNewToken(t *testing.T) {
	path, stash := dpDB(t)
	if _, err := dpPause(path, stash, time.Now()); err != nil {
		t.Fatal(err)
	}
	dbExec(t, path, `UPDATE "user" SET access_token='syt_new' WHERE mxid='@me:x'`)
	st, err := dpResume(path, stash)
	if err != nil || st.Users != 0 || token(t, path, "@me:x") != "syt_new" {
		t.Fatalf("resume overwrote: %+v %v", st, err)
	}
}

func TestDoublePuppetTimeouts(t *testing.T) {
	path, stash := dpDB(t)
	now := time.Unix(1_000_000, 0)
	if _, err := dpPause(path, stash, now); err != nil {
		t.Fatal(err)
	}
	if st, _ := dpStatus(path, stash, now.Add(31*time.Minute)); !st.Done || st.Why != "no account linked" {
		t.Fatalf("no-login timeout: %+v", st)
	}
	dbExec(t, path, `INSERT INTO user_login VALUES ('', 'L1', 'me', '{"logged_in_at":1000010,"history_sync_portals_need_creating":true}')`)
	if st, _ := dpStatus(path, stash, now.Add(3*time.Hour)); st.Done {
		t.Fatalf("resumed too early: %+v", st)
	}
	if st, _ := dpStatus(path, stash, now.Add(5*time.Hour)); !st.Done || st.Why != "time limit" {
		t.Fatalf("time limit: %+v", st)
	}
}
