package localmatrix

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// LocalStore holds the local SQLite state for portals, ghosts, events, and media.
type LocalStore struct {
	db *sql.DB
}

// PortalRow is the persisted portal (WhatsApp chat ↔ local room).
type PortalRow struct {
	PortalKey   string
	MXID        id.RoomID
	Name        string
	Topic       string
	AvatarURI   string
	IsDM        bool
	OtherUserID string
	CreatedAt   time.Time
}

// GhostRow is a persisted ghost (remote WhatsApp user).
type GhostRow struct {
	NetworkID   string
	MXID        id.UserID
	DisplayName string
	AvatarURI   string
}

// EventRow is a persisted timeline event.
type EventRow struct {
	EventID     id.EventID
	RoomID      id.RoomID
	SenderMXID  id.UserID
	EventType   string
	ContentJSON string
	TS          int64 // Unix milliseconds
	IsBackfill  bool
	RedactedBy  string
}

// MemberRow is a persisted room membership.
type MemberRow struct {
	RoomID      id.RoomID
	UserMXID    id.UserID
	Membership  string
	DisplayName string
}

func newLocalStore(db *sql.DB) *LocalStore {
	return &LocalStore{db: db}
}

// OpenLocalStore opens (or creates) the SQLite store at path and runs migrations.
func OpenLocalStore(path string) (*LocalStore, error) {
	db, err := sql.Open("sqlite3", "file:"+path+"?_foreign_keys=on&_journal_mode=WAL")
	if err != nil {
		return nil, err
	}
	s := newLocalStore(db)
	if err := s.RunMigrations(context.Background()); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

// Close closes the underlying database.
func (s *LocalStore) Close() error { return s.db.Close() }

// RunMigrations creates all local store tables if they don't exist.
func (s *LocalStore) RunMigrations(ctx context.Context) error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS lm_portal (
			portal_key   TEXT PRIMARY KEY,
			mxid         TEXT NOT NULL UNIQUE,
			name         TEXT NOT NULL DEFAULT '',
			topic        TEXT NOT NULL DEFAULT '',
			avatar_uri   TEXT NOT NULL DEFAULT '',
			is_dm        INTEGER NOT NULL DEFAULT 0,
			other_user_id TEXT NOT NULL DEFAULT '',
			created_at   INTEGER NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS lm_ghost (
			network_id   TEXT PRIMARY KEY,
			mxid         TEXT NOT NULL UNIQUE,
			display_name TEXT NOT NULL DEFAULT '',
			avatar_uri   TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE TABLE IF NOT EXISTS lm_event (
			event_id     TEXT PRIMARY KEY,
			room_id      TEXT NOT NULL,
			sender_mxid  TEXT NOT NULL,
			event_type   TEXT NOT NULL,
			content_json TEXT NOT NULL,
			ts           INTEGER NOT NULL,
			is_backfill  INTEGER NOT NULL DEFAULT 0,
			redacted_by  TEXT NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS idx_lm_event_room ON lm_event(room_id, ts)`,
		`CREATE TABLE IF NOT EXISTS lm_reaction (
			reaction_id     TEXT PRIMARY KEY,
			room_id         TEXT NOT NULL,
			target_event_id TEXT NOT NULL,
			sender_mxid     TEXT NOT NULL,
			emoji           TEXT NOT NULL
		)`,
		`CREATE TABLE IF NOT EXISTS lm_receipt (
			room_id   TEXT NOT NULL,
			user_mxid TEXT NOT NULL,
			event_id  TEXT NOT NULL,
			ts        INTEGER,
			PRIMARY KEY (room_id, user_mxid)
		)`,
		`CREATE TABLE IF NOT EXISTS lm_membership (
			room_id      TEXT NOT NULL,
			user_mxid    TEXT NOT NULL,
			membership   TEXT NOT NULL,
			display_name TEXT NOT NULL DEFAULT '',
			PRIMARY KEY (room_id, user_mxid)
		)`,
		`CREATE TABLE IF NOT EXISTS lm_media (
			uri       TEXT PRIMARY KEY,
			mime_type TEXT NOT NULL DEFAULT '',
			file_name TEXT NOT NULL DEFAULT '',
			data      BLOB NOT NULL
		)`,
		// Cached WhatsApp history (from history sync + live messages). Lets us
		// create rooms / backfill from local cache instead of the network.
		`CREATE TABLE IF NOT EXISTS wa_history (
			chat_jid    TEXT NOT NULL,
			msg_id      TEXT NOT NULL,
			sender      TEXT NOT NULL DEFAULT '',
			sender_name TEXT NOT NULL DEFAULT '',
			ts          INTEGER NOT NULL,
			body        TEXT NOT NULL DEFAULT '',
			msgtype     TEXT NOT NULL DEFAULT 'm.text',
			is_own      INTEGER NOT NULL DEFAULT 0,
			PRIMARY KEY (chat_jid, msg_id)
		)`,
		`CREATE INDEX IF NOT EXISTS idx_wa_history_chat ON wa_history(chat_jid, ts)`,
		`CREATE TABLE IF NOT EXISTS wa_chat (
			chat_jid TEXT PRIMARY KEY,
			name     TEXT NOT NULL DEFAULT '',
			is_group INTEGER NOT NULL DEFAULT 0,
			last_ts  INTEGER NOT NULL DEFAULT 0
		)`,
	}
	for _, stmt := range stmts {
		if _, err := s.db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate %q: %w", stmt[:30], err)
		}
	}
	return nil
}

// --- Portals ---

func (s *LocalStore) UpsertPortal(ctx context.Context, p PortalRow) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO lm_portal (portal_key, mxid, name, topic, avatar_uri, is_dm, other_user_id, created_at)
		VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(portal_key) DO UPDATE SET
			mxid=excluded.mxid, name=excluded.name, topic=excluded.topic,
			avatar_uri=excluded.avatar_uri, is_dm=excluded.is_dm, other_user_id=excluded.other_user_id`,
		p.PortalKey, string(p.MXID), p.Name, p.Topic, p.AvatarURI,
		boolInt(p.IsDM), p.OtherUserID, p.CreatedAt.UnixMilli())
	return err
}

func (s *LocalStore) GetPortal(ctx context.Context, portalKey string) (*PortalRow, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT portal_key, mxid, name, topic, avatar_uri, is_dm, other_user_id, created_at FROM lm_portal WHERE portal_key=?`,
		portalKey)
	return scanPortal(row)
}

func (s *LocalStore) GetPortalByMXID(ctx context.Context, mxid id.RoomID) (*PortalRow, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT portal_key, mxid, name, topic, avatar_uri, is_dm, other_user_id, created_at FROM lm_portal WHERE mxid=?`,
		string(mxid))
	return scanPortal(row)
}

func (s *LocalStore) GetAllPortals(ctx context.Context) ([]*PortalRow, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT portal_key, mxid, name, topic, avatar_uri, is_dm, other_user_id, created_at FROM lm_portal ORDER BY created_at DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var portals []*PortalRow
	for rows.Next() {
		p, err := scanPortal(rows)
		if err != nil {
			return nil, err
		}
		portals = append(portals, p)
	}
	return portals, rows.Err()
}

func (s *LocalStore) UpdatePortalName(ctx context.Context, mxid id.RoomID, name string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE lm_portal SET name=? WHERE mxid=?`, name, string(mxid))
	return err
}

func scanPortal(s interface {
	Scan(...any) error
}) (*PortalRow, error) {
	var p PortalRow
	var mxid string
	var isDM int
	var tsMS int64
	if err := s.Scan(&p.PortalKey, &mxid, &p.Name, &p.Topic, &p.AvatarURI, &isDM, &p.OtherUserID, &tsMS); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	p.MXID = id.RoomID(mxid)
	p.IsDM = isDM != 0
	p.CreatedAt = time.UnixMilli(tsMS)
	return &p, nil
}

// --- Ghosts ---

func (s *LocalStore) UpsertGhost(ctx context.Context, g GhostRow) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO lm_ghost (network_id, mxid, display_name, avatar_uri)
		VALUES (?,?,?,?)
		ON CONFLICT(network_id) DO UPDATE SET
			mxid=excluded.mxid, display_name=excluded.display_name, avatar_uri=excluded.avatar_uri`,
		g.NetworkID, string(g.MXID), g.DisplayName, g.AvatarURI)
	return err
}

func (s *LocalStore) GetGhost(ctx context.Context, networkID string) (*GhostRow, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT network_id, mxid, display_name, avatar_uri FROM lm_ghost WHERE network_id=?`, networkID)
	var g GhostRow
	var mxid string
	if err := row.Scan(&g.NetworkID, &mxid, &g.DisplayName, &g.AvatarURI); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	g.MXID = id.UserID(mxid)
	return &g, nil
}

func (s *LocalStore) UpdateGhostDisplayName(ctx context.Context, mxid id.UserID, name string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE lm_ghost SET display_name=? WHERE mxid=?`, name, string(mxid))
	return err
}

func (s *LocalStore) UpdateGhostAvatarURI(ctx context.Context, mxid id.UserID, uri string) error {
	_, err := s.db.ExecContext(ctx, `UPDATE lm_ghost SET avatar_uri=? WHERE mxid=?`, uri, string(mxid))
	return err
}

// --- Events ---

func (s *LocalStore) InsertEvent(ctx context.Context, e EventRow) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR IGNORE INTO lm_event (event_id, room_id, sender_mxid, event_type, content_json, ts, is_backfill, redacted_by)
		VALUES (?,?,?,?,?,?,?,?)`,
		string(e.EventID), string(e.RoomID), string(e.SenderMXID),
		e.EventType, e.ContentJSON, e.TS, boolInt(e.IsBackfill), e.RedactedBy)
	return err
}

func (s *LocalStore) InsertEventBatch(ctx context.Context, events []EventRow) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback() //nolint:errcheck
	stmt, err := tx.PrepareContext(ctx, `
		INSERT OR IGNORE INTO lm_event (event_id, room_id, sender_mxid, event_type, content_json, ts, is_backfill, redacted_by)
		VALUES (?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, e := range events {
		if _, err := stmt.ExecContext(ctx,
			string(e.EventID), string(e.RoomID), string(e.SenderMXID),
			e.EventType, e.ContentJSON, e.TS, boolInt(e.IsBackfill), e.RedactedBy); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func (s *LocalStore) GetEvent(ctx context.Context, eventID id.EventID) (*EventRow, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT event_id, room_id, sender_mxid, event_type, content_json, ts, is_backfill, redacted_by FROM lm_event WHERE event_id=?`,
		string(eventID))
	return scanEvent(row)
}

func (s *LocalStore) GetRoomEvents(ctx context.Context, roomID id.RoomID, limit int) ([]EventRow, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT event_id, room_id, sender_mxid, event_type, content_json, ts, is_backfill, redacted_by
		FROM lm_event WHERE room_id=? ORDER BY ts DESC LIMIT ?`,
		string(roomID), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var evts []EventRow
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, err
		}
		evts = append(evts, *e)
	}
	return evts, rows.Err()
}

func scanEvent(s interface{ Scan(...any) error }) (*EventRow, error) {
	var e EventRow
	var eventID, roomID, senderMXID string
	var isBackfill int
	if err := s.Scan(&eventID, &roomID, &senderMXID, &e.EventType, &e.ContentJSON, &e.TS, &isBackfill, &e.RedactedBy); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	e.EventID = id.EventID(eventID)
	e.RoomID = id.RoomID(roomID)
	e.SenderMXID = id.UserID(senderMXID)
	e.IsBackfill = isBackfill != 0
	return &e, nil
}

// --- Memberships ---

func (s *LocalStore) UpsertMembership(ctx context.Context, m MemberRow) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO lm_membership (room_id, user_mxid, membership, display_name)
		VALUES (?,?,?,?)
		ON CONFLICT(room_id, user_mxid) DO UPDATE SET membership=excluded.membership, display_name=excluded.display_name`,
		string(m.RoomID), string(m.UserMXID), m.Membership, m.DisplayName)
	return err
}

func (s *LocalStore) GetMembers(ctx context.Context, roomID id.RoomID) (map[id.UserID]*event.MemberEventContent, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT user_mxid, membership, display_name FROM lm_membership WHERE room_id=?`, string(roomID))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	members := make(map[id.UserID]*event.MemberEventContent)
	for rows.Next() {
		var mxid, membership, displayName string
		if err := rows.Scan(&mxid, &membership, &displayName); err != nil {
			return nil, err
		}
		members[id.UserID(mxid)] = &event.MemberEventContent{
			Membership:  event.Membership(membership),
			Displayname: displayName,
		}
	}
	return members, rows.Err()
}

func (s *LocalStore) GetMemberInfo(ctx context.Context, roomID id.RoomID, userID id.UserID) (*event.MemberEventContent, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT membership, display_name FROM lm_membership WHERE room_id=? AND user_mxid=?`,
		string(roomID), string(userID))
	var membership, displayName string
	if err := row.Scan(&membership, &displayName); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, err
	}
	return &event.MemberEventContent{
		Membership:  event.Membership(membership),
		Displayname: displayName,
	}, nil
}

// --- Reactions ---

func (s *LocalStore) InsertReaction(ctx context.Context, reactionID, roomID, targetEventID, senderMXID, emoji string) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR REPLACE INTO lm_reaction (reaction_id, room_id, target_event_id, sender_mxid, emoji)
		VALUES (?,?,?,?,?)`, reactionID, roomID, targetEventID, senderMXID, emoji)
	return err
}

func (s *LocalStore) RemoveReaction(ctx context.Context, roomID, targetEventID, senderMXID string) error {
	_, err := s.db.ExecContext(ctx,
		`DELETE FROM lm_reaction WHERE room_id=? AND target_event_id=? AND sender_mxid=?`,
		roomID, targetEventID, senderMXID)
	return err
}

// --- Receipts ---

func (s *LocalStore) UpsertReceipt(ctx context.Context, roomID id.RoomID, userMXID id.UserID, eventID id.EventID, ts int64) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO lm_receipt (room_id, user_mxid, event_id, ts)
		VALUES (?,?,?,?)
		ON CONFLICT(room_id, user_mxid) DO UPDATE SET event_id=excluded.event_id, ts=excluded.ts`,
		string(roomID), string(userMXID), string(eventID), ts)
	return err
}

// --- Media ---

func (s *LocalStore) StoreMedia(ctx context.Context, uri, mimeType, fileName string, data []byte) error {
	_, err := s.db.ExecContext(ctx, `
		INSERT OR REPLACE INTO lm_media (uri, mime_type, file_name, data) VALUES (?,?,?,?)`,
		uri, mimeType, fileName, data)
	return err
}

func (s *LocalStore) LoadMedia(ctx context.Context, uri string) (data []byte, mimeType string, err error) {
	row := s.db.QueryRowContext(ctx, `SELECT data, mime_type FROM lm_media WHERE uri=?`, uri)
	if err = row.Scan(&data, &mimeType); err != nil {
		if err == sql.ErrNoRows {
			return nil, "", fmt.Errorf("media not found: %s", uri)
		}
		return nil, "", err
	}
	return data, mimeType, nil
}

// --- Helpers ---

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// marshalContent serializes event.Content to JSON.
func marshalContent(c *event.Content) string {
	data, err := json.Marshal(c)
	if err != nil {
		return "{}"
	}
	return string(data)
}

// unmarshalContent deserializes JSON into event.Content.
func unmarshalContent(s string) *event.Content {
	var c event.Content
	_ = json.Unmarshal([]byte(s), &c)
	return &c
}

// --- WhatsApp history cache ---

// CachedMessage is one cached WhatsApp message.
type CachedMessage struct {
	ChatJID    string
	MsgID      string
	Sender     string
	SenderName string
	TS         int64 // unix seconds
	Body       string
	MsgType    string
	IsOwn      bool
}

// CachedChat is a chat summary from the cache (for the picker).
type CachedChat struct {
	ChatJID string
	Name    string
	IsGroup bool
	LastTS  int64 // unix seconds of newest cached message
}

// CacheMessage stores (or ignores if already present) a single message and keeps
// the chat summary's name/last_ts up to date.
func (s *LocalStore) CacheMessage(ctx context.Context, m CachedMessage, chatName string, isGroup bool) error {
	if _, err := s.db.ExecContext(ctx, `
		INSERT INTO wa_history (chat_jid, msg_id, sender, sender_name, ts, body, msgtype, is_own)
		VALUES (?,?,?,?,?,?,?,?)
		ON CONFLICT(chat_jid, msg_id) DO NOTHING`,
		m.ChatJID, m.MsgID, m.Sender, m.SenderName, m.TS, m.Body, m.MsgType, boolInt(m.IsOwn)); err != nil {
		return err
	}
	// Upsert chat summary: bump last_ts, set name if we have a better one.
	_, err := s.db.ExecContext(ctx, `
		INSERT INTO wa_chat (chat_jid, name, is_group, last_ts)
		VALUES (?,?,?,?)
		ON CONFLICT(chat_jid) DO UPDATE SET
			last_ts = MAX(last_ts, excluded.last_ts),
			name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
			is_group = excluded.is_group`,
		m.ChatJID, chatName, boolInt(isGroup), m.TS)
	return err
}

// GetCachedMessages returns cached messages for a chat newer than sinceUnix,
// oldest first (ready to inject as backfill).
func (s *LocalStore) GetCachedMessages(ctx context.Context, chatJID string, sinceUnix int64) ([]CachedMessage, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT chat_jid, msg_id, sender, sender_name, ts, body, msgtype, is_own
		FROM wa_history WHERE chat_jid=? AND ts>=? ORDER BY ts ASC`,
		chatJID, sinceUnix)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CachedMessage
	for rows.Next() {
		var m CachedMessage
		var isOwn int
		if err := rows.Scan(&m.ChatJID, &m.MsgID, &m.Sender, &m.SenderName, &m.TS, &m.Body, &m.MsgType, &isOwn); err != nil {
			return nil, err
		}
		m.IsOwn = isOwn != 0
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListCachedChats returns all cached chat summaries, newest activity first.
func (s *LocalStore) ListCachedChats(ctx context.Context) ([]CachedChat, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT chat_jid, name, is_group, last_ts FROM wa_chat ORDER BY last_ts DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CachedChat
	for rows.Next() {
		var c CachedChat
		var isGroup int
		if err := rows.Scan(&c.ChatJID, &c.Name, &isGroup, &c.LastTS); err != nil {
			return nil, err
		}
		c.IsGroup = isGroup != 0
		out = append(out, c)
	}
	return out, rows.Err()
}

// ClearHistoryCache wipes all cached WhatsApp messages and chat summaries so a
// fresh history sync can repopulate them cleanly.
func (s *LocalStore) ClearHistoryCache(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM wa_history`); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `DELETE FROM wa_chat`)
	return err
}
