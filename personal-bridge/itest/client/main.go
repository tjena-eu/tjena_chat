// itest client: plays the bridge owner with a cross-signed, encrypted Matrix
// device, opens the management DM with the personal bridge bot, sends
// commands and prints the bot's (decrypted) replies.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"maunium.net/go/mautrix"
	"maunium.net/go/mautrix/crypto/cryptohelper"
	"maunium.net/go/mautrix/event"
	"maunium.net/go/mautrix/id"
)

type result struct {
	RoomID          string            `json:"room_id"`
	Replies         map[string]string `json:"replies"`
	BotCrossSigned  bool              `json:"bot_cross_signed"`
	BotDevices      int               `json:"bot_devices"`
	ReplyWasEncrypt bool              `json:"reply_was_encrypted"`
}

func main() {
	hs := flag.String("hs", "http://127.0.0.1:18008", "homeserver URL")
	user := flag.String("user", "alice", "localpart")
	pass := flag.String("pass", "", "password")
	bot := flag.String("bot", "", "bot MXID")
	db := flag.String("db", "client.db", "crypto DB path")
	cmds := flag.String("cmds", "help,list-logins", "comma separated commands")
	flag.Parse()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	must := func(err error, what string) {
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL %s: %v\n", what, err)
			os.Exit(1)
		}
	}

	cli, err := mautrix.NewClient(*hs, "", "")
	must(err, "client")
	cli.StateStore = mautrix.NewMemoryStateStore()
	helper, err := cryptohelper.NewCryptoHelper(cli, []byte("itest-pickle-key"), *db)
	must(err, "cryptohelper")
	helper.LoginAs = &mautrix.ReqLogin{
		Type:                     mautrix.AuthTypePassword,
		Identifier:               mautrix.UserIdentifier{Type: mautrix.IdentifierTypeUser, User: *user},
		Password:                 *pass,
		InitialDeviceDisplayName: "itest client",
	}
	must(helper.Init(ctx), "crypto init")
	cli.Crypto = helper
	mach := helper.Machine()

	// The bridge only accepts messages from cross-signed devices (cross-signed-tofu).
	if _, _, err = mach.GenerateAndUploadCrossSigningKeysWithPassword(ctx, *pass, ""); err != nil {
		fmt.Fprintln(os.Stderr, "note: cross-signing upload:", err)
	}
	must(mach.SignOwnDevice(ctx, mach.OwnIdentity()), "sign own device")
	must(mach.SignOwnMasterKey(ctx), "sign own master key")

	var mu sync.Mutex
	replies := make(chan *event.Event, 16)
	syncer := cli.Syncer.(*mautrix.DefaultSyncer)
	syncer.OnEventType(event.EventMessage, func(ctx context.Context, evt *event.Event) {
		if evt.Sender.String() == *bot {
			replies <- evt
		}
	})
	go func() { _ = cli.SyncWithContext(ctx) }()

	botID := id.UserID(*bot)
	resp, err := cli.CreateRoom(ctx, &mautrix.ReqCreateRoom{
		Invite: []id.UserID{botID}, IsDirect: true, Preset: "trusted_private_chat",
		InitialState: []*event.Event{{Type: event.StateEncryption, Content: event.Content{
			Parsed: &event.EncryptionEventContent{Algorithm: id.AlgorithmMegolmV1}}}},
	})
	must(err, "create DM")
	roomID := resp.RoomID

	// Wait for the bot to join.
	deadline := time.Now().Add(60 * time.Second)
	for {
		members, err := cli.JoinedMembers(ctx, roomID)
		if err == nil {
			if _, ok := members.Joined[botID]; ok {
				break
			}
		}
		if time.Now().After(deadline) {
			must(fmt.Errorf("bot did not join"), "wait for bot")
		}
		time.Sleep(time.Second)
	}
	time.Sleep(3 * time.Second) // let sync pick up membership for encryption

	res := result{RoomID: roomID.String(), Replies: map[string]string{}}
	for _, c := range strings.Split(*cmds, ",") {
		_, err = cli.SendText(ctx, roomID, c)
		must(err, "send "+c)
		select {
		case evt := <-replies:
			mu.Lock()
			res.Replies[c] = evt.Content.AsMessage().Body
			res.ReplyWasEncrypt = evt.Mautrix.WasEncrypted
			mu.Unlock()
		case <-time.After(60 * time.Second):
			must(fmt.Errorf("no reply to %q", c), "reply")
		}
	}

	keys, err := cli.QueryKeys(ctx, &mautrix.ReqQueryKeys{DeviceKeys: mautrix.DeviceKeysRequest{botID: {}}})
	must(err, "query bot keys")
	_, res.BotCrossSigned = keys.MasterKeys[botID]
	res.BotDevices = len(keys.DeviceKeys[botID])

	out, _ := json.MarshalIndent(res, "", "  ")
	fmt.Println(string(out))
}
