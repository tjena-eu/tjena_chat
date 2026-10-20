package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/types"
	waevents "go.mau.fi/whatsmeow/types/events"
)

// maxUndecryptablePerChat bounds the per-chat list of failed decrypts.
const maxUndecryptablePerChat = 200

// recordUndecryptable remembers a message that failed to decrypt so "WA fix"
// can ask the phone for it again. Intentionally unavailable messages (view
// once, …) are skipped — the phone won't hand those out either.
func (b *Bridge) recordUndecryptable(evt *waevents.UndecryptableMessage) {
	if evt.UnavailableType != "" {
		return
	}
	roomID := evt.Info.Chat.User + "@" + string(evt.Info.Chat.Server)
	b.appendLog(fmt.Sprintf("[Bridge] undecryptable message %s in %s from %s (unavailable=%v)",
		evt.Info.ID, roomID, evt.Info.Sender, evt.IsUnavailable))
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.undecryptable == nil {
		b.undecryptable = make(map[string][]types.MessageInfo)
	}
	list := b.undecryptable[roomID]
	for _, m := range list {
		if m.ID == evt.Info.ID {
			return
		}
	}
	list = append(list, evt.Info)
	if len(list) > maxUndecryptablePerChat {
		list = list[len(list)-maxUndecryptablePerChat:]
	}
	b.undecryptable[roomID] = list
}

// clearUndecryptable forgets a failed decrypt once the message arrived after all.
func (b *Bridge) clearUndecryptable(roomID string, msgID types.MessageID) {
	b.mu.Lock()
	defer b.mu.Unlock()
	list := b.undecryptable[roomID]
	for i, m := range list {
		if m.ID == msgID {
			b.undecryptable[roomID] = append(list[:i:i], list[i+1:]...)
			return
		}
	}
}

// FixChat is the bridge half of the per-chat "WA fix". It repairs the state
// that makes a chat (usually a group) silently stop working and reports what it
// found as JSON:
//
//   - makes sure the socket is actually alive (reconnects if not),
//   - for groups: re-fetches the group from the server, which refreshes
//     whatsmeow's cached participant list/addressing mode (stale ones make
//     sends go to the wrong devices) and the LID↔phone mappings, and tells us
//     whether we are still a member at all,
//   - asks the phone to resend every message in this chat that failed to
//     decrypt (missing sender key), which then arrive as normal messages,
//   - asks the phone for recent history of this chat, so messages that never
//     reached this device show up.
func (b *Bridge) FixChat(roomID string, days int) string {
	report := map[string]any{"room_id": roomID}
	out := func() string {
		raw, _ := json.Marshal(report)
		b.appendLog("[Bridge] FixChat " + string(raw))
		return string(raw)
	}
	var problems []string

	b.mu.Lock()
	client := b.waClient
	b.mu.Unlock()
	if client == nil {
		report["problems"] = []string{"WhatsApp is not linked/started"}
		return out()
	}
	chat, err := types.ParseJID(roomID)
	if err != nil {
		report["problems"] = []string{"invalid chat id: " + err.Error()}
		return out()
	}

	// 1) Connection.
	connected := client.IsConnected() && client.IsLoggedIn()
	if !connected {
		connected = b.reconnectNow(client, reconnectWait, false)
		report["reconnected"] = connected
	}
	report["connected"] = connected
	if !connected {
		problems = append(problems, "no connection to WhatsApp")
		report["problems"] = problems
		return out()
	}

	// 2) Group state.
	isGroup := chat.Server == types.GroupServer
	report["is_group"] = isGroup
	if isGroup {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		info, err := client.GetGroupInfo(ctx, chat)
		cancel()
		switch {
		case errors.Is(err, whatsmeow.ErrNotInGroup):
			report["member"] = false
			problems = append(problems, "you are no longer a member of this group")
		case errors.Is(err, whatsmeow.ErrGroupNotFound):
			report["member"] = false
			problems = append(problems, "this group no longer exists")
		case err != nil:
			problems = append(problems, "could not load group info: "+err.Error())
		default:
			report["member"] = true
			report["participants"] = len(info.Participants)
			report["addressing_mode"] = string(info.AddressingMode)
			report["announce_only"] = info.IsAnnounce
			if info.Name != "" {
				b.mu.Lock()
				if b.groupNames == nil {
					b.groupNames = make(map[string]string)
				}
				b.groupNames[roomID] = info.Name
				b.mu.Unlock()
			}
			if info.IsAnnounce {
				own := map[types.JID]bool{}
				for _, j := range []types.JID{client.Store.GetJID(), client.Store.GetLID()} {
					if !j.IsEmpty() {
						own[j.ToNonAD()] = true
					}
				}
				isAdmin := false
				for _, p := range info.Participants {
					isMe := own[p.JID.ToNonAD()] ||
						(!p.LID.IsEmpty() && own[p.LID.ToNonAD()]) ||
						(!p.PhoneNumber.IsEmpty() && own[p.PhoneNumber.ToNonAD()])
					if isMe && (p.IsAdmin || p.IsSuperAdmin) {
						isAdmin = true
					}
				}
				if !isAdmin {
					problems = append(problems, "only admins can send messages in this group")
				}
			}
		}
	}

	// 3) Re-request undecryptable messages from the phone.
	b.mu.Lock()
	pending := append([]types.MessageInfo(nil), b.undecryptable[roomID]...)
	lastErr := b.lastSendErr[roomID]
	b.mu.Unlock()
	report["undecryptable"] = len(pending)
	requested := 0
	for _, info := range pending {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		_, err := client.SendPeerMessage(ctx, client.BuildUnavailableMessageRequest(info.Chat, info.Sender, info.ID))
		cancel()
		if err != nil {
			b.appendLog("[Bridge] FixChat re-request " + info.ID + " failed: " + err.Error())
			continue
		}
		requested++
	}
	report["rerequested"] = requested
	if len(pending) > 0 {
		problems = append(problems, fmt.Sprintf(
			"%d message(s) couldn't be decrypted — asked your phone to resend them", len(pending)))
	}
	if lastErr != "" {
		report["last_send_error"] = lastErr
		problems = append(problems, "last send failed: "+lastErr)
	}

	// 4) Recent history from the phone (fills gaps this device never got).
	if days > 0 {
		if err := b.RequestServerHistory(roomID, days); err != nil {
			report["history_request_error"] = err.Error()
		} else {
			report["history_requested"] = true
		}
	}

	if problems == nil {
		problems = []string{}
	}
	report["problems"] = problems
	return out()
}
