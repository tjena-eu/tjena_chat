package localmatrix

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

// LocalIntent implements bridgev2.MatrixAPI for a single identity
// (ghost, bot, or double-puppet user).
type LocalIntent struct {
	mxid           id.UserID
	isDoublePuppet bool
	conn           *LocalConnector
}

func (i *LocalIntent) GetMXID() id.UserID   { return i.mxid }
func (i *LocalIntent) IsDoublePuppet() bool { return i.isDoublePuppet }

// SendMessage stores the event locally and emits it on the event stream.
func (i *LocalIntent) SendMessage(ctx context.Context, roomID id.RoomID, evtType event.Type, content *event.Content, extra *bridgev2.MatrixSendExtra) (*mautrix.RespSendEvent, error) {
	ts := time.Now()
	if extra != nil && !extra.Timestamp.IsZero() {
		ts = extra.Timestamp
	}

	var rawContent map[string]any
	if content != nil && content.Raw != nil {
		rawContent = content.Raw
	} else if content != nil {
		b, _ := json.Marshal(content.Parsed)
		_ = json.Unmarshal(b, &rawContent)
	}

	eventID := i.conn.GenerateDeterministicEventID(roomID,
		networkPortalKey(roomID), "", networkid.PartID(""))

	contentJSON := "{}"
	if rawContent != nil {
		b, _ := json.Marshal(rawContent)
		contentJSON = string(b)
	}

	isBackfill := extra != nil && !extra.Timestamp.IsZero() && extra.Timestamp.Before(time.Now().Add(-5*time.Minute))
	evt := EventRow{
		EventID:     eventID,
		RoomID:      roomID,
		SenderMXID:  i.mxid,
		EventType:   evtType.Type,
		ContentJSON: contentJSON,
		TS:          ts.UnixMilli(),
		IsBackfill:  isBackfill,
	}
	_ = i.conn.store.InsertEvent(ctx, evt)

	body := extractBody(rawContent)
	i.conn.emitter.Emit(map[string]any{
		"type":    "message",
		"room_id": string(roomID),
		"event": map[string]any{
			"id":          string(eventID),
			"sender":      string(i.mxid),
			"sender_name": string(i.mxid),
			"ts":          ts.UnixMilli(),
			"body":        body,
			"msgtype":     rawMsgtype(rawContent),
			"is_own":      i.isDoublePuppet,
			"is_backfill": isBackfill,
			"media_uri":   rawMediaURI(rawContent),
		},
	})

	return &mautrix.RespSendEvent{EventID: eventID}, nil
}

// SendState handles room state events by updating the local store.
func (i *LocalIntent) SendState(ctx context.Context, roomID id.RoomID, evtType event.Type, stateKey string, content *event.Content, _ time.Time) (*mautrix.RespSendEvent, error) {
	eventID := i.conn.GenerateDeterministicEventID(roomID,
		networkPortalKey(roomID), networkid.MessageID(""), networkid.PartID(evtType.Type+stateKey))

	switch evtType {
	case event.StateRoomName:
		if content != nil {
			if name, ok := content.Raw["name"].(string); ok {
				_ = i.conn.store.UpdatePortalName(ctx, roomID, name)
				i.conn.emitter.Emit(map[string]any{
					"type": "room_updated", "room_id": string(roomID), "name": name,
				})
			}
		}
	case event.StateMember:
		membership := "join"
		displayName := ""
		if content != nil && content.Raw != nil {
			if m, ok := content.Raw["membership"].(string); ok {
				membership = m
			}
			if dn, ok := content.Raw["displayname"].(string); ok {
				displayName = dn
			}
		}
		_ = i.conn.store.UpsertMembership(ctx, MemberRow{
			RoomID:      roomID,
			UserMXID:    id.UserID(stateKey),
			Membership:  membership,
			DisplayName: displayName,
		})
		i.conn.emitter.Emit(map[string]any{
			"type":         "membership",
			"room_id":      string(roomID),
			"user_id":      stateKey,
			"membership":   membership,
			"display_name": displayName,
		})
	case event.StateRoomAvatar:
		if content != nil {
			if url, ok := content.Raw["url"].(string); ok {
				i.conn.emitter.Emit(map[string]any{
					"type": "room_updated", "room_id": string(roomID), "avatar_uri": url,
				})
			}
		}
	case event.StateTopic:
		if content != nil {
			if topic, ok := content.Raw["topic"].(string); ok {
				i.conn.emitter.Emit(map[string]any{
					"type": "room_updated", "room_id": string(roomID), "topic": topic,
				})
			}
		}
	}

	return &mautrix.RespSendEvent{EventID: eventID}, nil
}

func (i *LocalIntent) MarkRead(ctx context.Context, roomID id.RoomID, eventID id.EventID, ts time.Time) error {
	if ts.IsZero() {
		ts = time.Now()
	}
	_ = i.conn.store.UpsertReceipt(ctx, roomID, i.mxid, eventID, ts.UnixMilli())
	i.conn.emitter.Emit(map[string]any{
		"type":     "receipt",
		"room_id":  string(roomID),
		"user_id":  string(i.mxid),
		"event_id": string(eventID),
		"ts":       ts.UnixMilli(),
	})
	return nil
}

func (i *LocalIntent) MarkUnread(_ context.Context, roomID id.RoomID, unread bool) error {
	i.conn.emitter.Emit(map[string]any{
		"type": "unread", "room_id": string(roomID), "user_id": string(i.mxid), "unread": unread,
	})
	return nil
}

func (i *LocalIntent) MarkTyping(_ context.Context, roomID id.RoomID, _ bridgev2.TypingType, timeout time.Duration) error {
	i.conn.emitter.Emit(map[string]any{
		"type":    "typing",
		"room_id": string(roomID),
		"user_id": string(i.mxid),
		"typing":  timeout > 0,
	})
	return nil
}

func (i *LocalIntent) UploadMedia(ctx context.Context, _ id.RoomID, data []byte, fileName, mimeType string) (id.ContentURIString, *event.EncryptedFileInfo, error) {
	uri := fmt.Sprintf("local://media/%s_%d", fileName, time.Now().UnixNano())
	if err := i.conn.store.StoreMedia(ctx, uri, mimeType, fileName, data); err != nil {
		return "", nil, err
	}
	return id.ContentURIString(uri), nil, nil
}

func (i *LocalIntent) UploadMediaStream(ctx context.Context, roomID id.RoomID, _ int64, _ bool, cb bridgev2.FileStreamCallback) (id.ContentURIString, *event.EncryptedFileInfo, error) {
	f, err := os.CreateTemp("", "tjena_media_*")
	if err != nil {
		return "", nil, err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err := cb(f); err != nil {
		return "", nil, err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return "", nil, err
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return "", nil, err
	}
	return i.UploadMedia(ctx, roomID, data, "media", "application/octet-stream")
}

func (i *LocalIntent) DownloadMedia(ctx context.Context, uri id.ContentURIString, _ *event.EncryptedFileInfo) ([]byte, error) {
	data, _, err := i.conn.store.LoadMedia(ctx, string(uri))
	if err != nil {
		return nil, err
	}
	return data, nil
}

func (i *LocalIntent) DownloadMediaToFile(ctx context.Context, uri id.ContentURIString, _ *event.EncryptedFileInfo, _ bool, cb func(*os.File) error) error {
	data, _, err := i.conn.store.LoadMedia(ctx, string(uri))
	if err != nil {
		return err
	}
	f, err := os.CreateTemp("", "tjena_dl_*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return err
	}
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return cb(f)
}

func (i *LocalIntent) SetDisplayName(ctx context.Context, name string) error {
	return i.conn.store.UpdateGhostDisplayName(ctx, i.mxid, name)
}

func (i *LocalIntent) SetAvatarURL(ctx context.Context, avatarURL id.ContentURIString) error {
	return i.conn.store.UpdateGhostAvatarURI(ctx, i.mxid, string(avatarURL))
}

func (i *LocalIntent) SetExtraProfileMeta(_ context.Context, _ any) error { return nil }
func (i *LocalIntent) SetProfile(_ context.Context, _ any) error          { return nil }

func (i *LocalIntent) CreateRoom(ctx context.Context, req *mautrix.ReqCreateRoom) (id.RoomID, error) {
	pkey := networkPortalKeyFromReq(req)
	roomID := i.conn.GenerateDeterministicRoomID(pkey)

	name := ""
	isDM := req.IsDirect
	otherUser := ""
	if req.Name != "" {
		name = req.Name
	}
	if len(req.Invite) == 1 && isDM {
		otherUser = string(req.Invite[0])
	}

	if err := i.conn.store.UpsertPortal(ctx, PortalRow{
		PortalKey:   string(pkey.ID),
		MXID:        roomID,
		Name:        name,
		IsDM:        isDM,
		OtherUserID: otherUser,
		CreatedAt:   time.Now(),
	}); err != nil {
		return "", err
	}
	_ = i.conn.store.UpsertMembership(ctx, MemberRow{
		RoomID:    roomID,
		UserMXID:  i.mxid,
		Membership: "join",
	})

	i.conn.emitter.Emit(map[string]any{
		"type": "room_created",
		"room": map[string]any{
			"id": string(roomID), "name": name, "is_dm": isDM, "other_user": otherUser,
		},
	})
	return roomID, nil
}

func (i *LocalIntent) DeleteRoom(_ context.Context, roomID id.RoomID, _ bool) error {
	i.conn.emitter.Emit(map[string]any{"type": "room_deleted", "room_id": string(roomID)})
	return nil
}

func (i *LocalIntent) EnsureJoined(ctx context.Context, roomID id.RoomID, _ ...bridgev2.EnsureJoinedParams) error {
	return i.conn.store.UpsertMembership(ctx, MemberRow{
		RoomID:    roomID,
		UserMXID:  i.mxid,
		Membership: "join",
	})
}

func (i *LocalIntent) EnsureInvited(ctx context.Context, roomID id.RoomID, userID id.UserID) error {
	return i.conn.store.UpsertMembership(ctx, MemberRow{
		RoomID:    roomID,
		UserMXID:  userID,
		Membership: "invite",
	})
}

func (i *LocalIntent) TagRoom(_ context.Context, roomID id.RoomID, tag event.RoomTag, isTagged bool) error {
	i.conn.emitter.Emit(map[string]any{
		"type": "room_tag", "room_id": string(roomID), "tag": string(tag), "tagged": isTagged,
	})
	return nil
}

func (i *LocalIntent) MuteRoom(_ context.Context, roomID id.RoomID, until time.Time) error {
	i.conn.emitter.Emit(map[string]any{
		"type": "room_muted", "room_id": string(roomID), "until": until.UnixMilli(),
	})
	return nil
}

func (i *LocalIntent) GetEvent(ctx context.Context, roomID id.RoomID, eventID id.EventID) (*event.Event, error) {
	e, err := i.conn.store.GetEvent(ctx, eventID)
	if err != nil || e == nil {
		return nil, err
	}
	return &event.Event{
		ID:        eventID,
		RoomID:    roomID,
		Sender:    e.SenderMXID,
		Timestamp: e.TS,
		Type:      event.NewEventType(e.EventType),
		Content:   event.Content{VeryRaw: json.RawMessage(e.ContentJSON)},
	}, nil
}

// --- helpers ---

func extractBody(raw map[string]any) string {
	if raw == nil {
		return ""
	}
	if b, ok := raw["body"].(string); ok {
		return b
	}
	return ""
}

func rawMsgtype(raw map[string]any) string {
	if raw == nil {
		return "m.text"
	}
	if mt, ok := raw["msgtype"].(string); ok {
		return mt
	}
	return "m.text"
}

func rawMediaURI(raw map[string]any) string {
	if raw == nil {
		return ""
	}
	if u, ok := raw["url"].(string); ok {
		return u
	}
	return ""
}

func networkPortalKeyFromReq(req *mautrix.ReqCreateRoom) networkid.PortalKey {
	if req == nil {
		return networkid.PortalKey{}
	}
	return networkid.PortalKey{ID: networkid.PortalID(req.Name)}
}
