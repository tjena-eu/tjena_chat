package localmatrix

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"

	"tjena.eu/tjena-bridge/internal/emitter"
)

const serverName = "tjena.local"
const ghostPrefix = "wa_"

// LocalConnector implements bridgev2.MatrixConnector entirely in-process.
type LocalConnector struct {
	bridge  *bridgev2.Bridge
	store   *LocalStore
	emitter *emitter.Emitter
}

var _ bridgev2.MatrixConnector = (*LocalConnector)(nil)

// NewConnector creates a LocalConnector. Init/Start are called by bridgev2.NewBridge.
func NewConnector(db *LocalStore, em *emitter.Emitter) *LocalConnector {
	return &LocalConnector{store: db, emitter: em}
}

func (c *LocalConnector) Init(br *bridgev2.Bridge) { c.bridge = br }

func (c *LocalConnector) Start(ctx context.Context) error {
	return c.store.RunMigrations(ctx)
}

func (c *LocalConnector) PreStop() {}
func (c *LocalConnector) Stop()    {}

func (c *LocalConnector) GetCapabilities() *bridgev2.MatrixCapabilities {
	return &bridgev2.MatrixCapabilities{
		BatchSending:          true,
		AutoJoinInvites:       true,
		ArbitraryMemberChange: true,
	}
}

func (c *LocalConnector) ServerName() string { return serverName }

func (c *LocalConnector) ParseGhostMXID(userID id.UserID) (networkid.UserID, bool) {
	localpart := userID.Localpart()
	if userID.Homeserver() != serverName {
		return "", false
	}
	if !strings.HasPrefix(localpart, ghostPrefix) {
		return "", false
	}
	return networkid.UserID(localpart[len(ghostPrefix):]), true
}

func (c *LocalConnector) GhostIntent(userID networkid.UserID) bridgev2.MatrixAPI {
	return &LocalIntent{
		mxid: id.NewUserID(ghostPrefix+string(userID), serverName),
		conn: c,
	}
}

func (c *LocalConnector) BotIntent() bridgev2.MatrixAPI {
	return &LocalIntent{mxid: id.NewUserID("tjenabridgebot", serverName), conn: c}
}

func (c *LocalConnector) NewUserIntent(_ context.Context, userID id.UserID, _ string) (bridgev2.MatrixAPI, string, error) {
	return &LocalIntent{mxid: userID, isDoublePuppet: true, conn: c}, "", nil
}

func (c *LocalConnector) SendBridgeStatus(_ context.Context, state *status.BridgeState) error {
	c.emitter.Emit(map[string]any{
		"type":  "bridge_status",
		"state": string(state.StateEvent),
		"error": state.Error,
	})
	return nil
}

func (c *LocalConnector) SendMessageStatus(_ context.Context, st *bridgev2.MessageStatus, info *bridgev2.MessageStatusEventInfo) {
	c.emitter.Emit(map[string]any{
		"type":     "msg_status",
		"event_id": string(info.SourceEventID),
		"status":   string(st.Status),
	})
}

func (c *LocalConnector) GenerateContentURI(_ context.Context, mediaID networkid.MediaID) (id.ContentURIString, error) {
	return id.ContentURIString("local://" + string(mediaID)), nil
}

func (c *LocalConnector) ParseContentURI(_ context.Context, uri id.ContentURIString) (networkid.MediaID, error) {
	s := string(uri)
	if after, ok := strings.CutPrefix(s, "local://"); ok {
		return networkid.MediaID(after), nil
	}
	return networkid.MediaID(s), nil
}

func (c *LocalConnector) GetPowerLevels(_ context.Context, _ id.RoomID) (*event.PowerLevelsEventContent, error) {
	pl := &event.PowerLevelsEventContent{}
	pl.EnsureUserLevel(c.BotIntent().GetMXID(), 100)
	return pl, nil
}

func (c *LocalConnector) GetMembers(ctx context.Context, roomID id.RoomID) (map[id.UserID]*event.MemberEventContent, error) {
	return c.store.GetMembers(ctx, roomID)
}

func (c *LocalConnector) GetMemberInfo(ctx context.Context, roomID id.RoomID, userID id.UserID) (*event.MemberEventContent, error) {
	return c.store.GetMemberInfo(ctx, roomID, userID)
}

// BatchSend inserts historical events in one transaction and emits a backfill event.
func (c *LocalConnector) BatchSend(ctx context.Context, roomID id.RoomID, req *mautrix.ReqBeeperBatchSend, _ []*bridgev2.MatrixSendExtra) (*mautrix.RespBeeperBatchSend, error) {
	rows := make([]EventRow, 0, len(req.Events))
	eventIDs := make([]id.EventID, 0, len(req.Events))
	emitEvents := make([]map[string]any, 0, len(req.Events))

	for j, e := range req.Events {
		eid := c.GenerateDeterministicEventID(roomID, networkPortalKey(roomID),
			networkid.MessageID(fmt.Sprintf("batch_fwd%v_%d", req.Forward, j)), "")
		eventIDs = append(eventIDs, eid)

		rawJSON, _ := json.Marshal(e.Content.Raw)
		body := ""
		if e.Content.Raw != nil {
			if b, ok := e.Content.Raw["body"].(string); ok {
				body = b
			}
		}

		rows = append(rows, EventRow{
			EventID:     eid,
			RoomID:      roomID,
			SenderMXID:  e.Sender,
			EventType:   e.Type.Type,
			ContentJSON: string(rawJSON),
			TS:          e.Timestamp,
			IsBackfill:  true,
		})
		emitEvents = append(emitEvents, map[string]any{
			"id":          string(eid),
			"sender":      string(e.Sender),
			"ts":          e.Timestamp,
			"body":        body,
			"is_backfill": true,
		})
	}

	if err := c.store.InsertEventBatch(ctx, rows); err != nil {
		return nil, err
	}
	c.emitter.Emit(map[string]any{
		"type":    "backfill",
		"room_id": string(roomID),
		"events":  emitEvents,
	})
	return &mautrix.RespBeeperBatchSend{EventIDs: eventIDs}, nil
}

func (c *LocalConnector) GenerateDeterministicRoomID(portalKey networkid.PortalKey) id.RoomID {
	h := sha256.Sum256([]byte(string(portalKey.ID) + "|" + string(portalKey.Receiver)))
	return id.RoomID("!local_" + hex.EncodeToString(h[:8]) + ":" + serverName)
}

func (c *LocalConnector) GenerateDeterministicEventID(roomID id.RoomID, _ networkid.PortalKey, messageID networkid.MessageID, partID networkid.PartID) id.EventID {
	h := sha256.Sum256([]byte(string(roomID) + "|" + string(messageID) + "|" + string(partID)))
	return id.EventID("$local_" + hex.EncodeToString(h[:12]))
}

func (c *LocalConnector) GenerateReactionEventID(roomID id.RoomID, targetMessage *database.Message, sender networkid.UserID, emojiID networkid.EmojiID) id.EventID {
	targetID := ""
	if targetMessage != nil {
		targetID = string(targetMessage.MXID)
	}
	h := sha256.Sum256([]byte(string(roomID) + "|" + targetID + "|" + string(sender) + "|" + string(emojiID)))
	return id.EventID("$react_" + hex.EncodeToString(h[:12]))
}

// getPortalKeyForRoom returns a PortalKey suitable for use with deterministic IDs.
func (s *LocalStore) getPortalKeyForRoom(roomID id.RoomID) networkid.PortalKey {
	return networkid.PortalKey{ID: networkid.PortalID(roomID)}
}

func networkPortalKey(roomID id.RoomID) networkid.PortalKey {
	return networkid.PortalKey{ID: networkid.PortalID(roomID)}
}
