package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestReadHistoryLog(t *testing.T) {
	dir := t.TempDir()
	log := `{"level":"info","time":"2026-10-22T09:00:00Z","message":"Sending backfill messages","portal_id":"old","message_count":5}
{"level":"info","time":"2026-10-22T10:00:00Z","message":"Storing history sync","sync_type":"RECENT","chunk_order":2,"progress":45,"conversation_count":30}
{"level":"info","time":"2026-10-22T10:00:01Z","message":"Finished storing history sync","total_saved_count":300}
{"level":"info","time":"2026-10-22T10:06:00Z","message":"Creating portals from history sync","conversation_count":25}
{"level":"info","time":"2026-10-22T10:06:05Z","message":"Sending backfill messages","portal_id":"a","message_count":19}
{"level":"warn","time":"2026-10-22T10:06:06Z","message":"Request failed, retrying","error":"HTTP 429"}
{"level":"error","time":"2026-10-22T10:06:20Z","message":"Failed to send forward backfill","error":"M_LIMIT_EXCEEDED","portal_id":"a"}
not json
`
	if err := os.WriteFile(filepath.Join(dir, "bridge.log"), []byte(log), 0o600); err != nil {
		t.Fatal(err)
	}
	since, _ := time.Parse(time.RFC3339, "2026-10-22T09:59:30Z")
	h := readHistoryLog(dir, since)
	if !h.Found || h.Progress["RECENT"] != 45 || h.Saved != 300 || h.RoomsTarget != 25 || h.RoomsDone {
		t.Fatalf("summary wrong: %+v", h)
	}
	if h.BackfillChats != 1 || h.BackfillMessages != 19 || h.perPortalSent["old"] != 0 {
		t.Fatalf("entries before login must be skipped: %+v", h)
	}
	if h.BackfillFailed != 1 || !h.perPortalFailed["a"] || !h.perPortalRateLimt["a"] || h.RateLimited != 2 {
		t.Fatalf("failure not detected: %+v", h)
	}
	if len(h.RecentErrors) != 1 {
		t.Fatalf("errors: %+v", h.RecentErrors)
	}
}
