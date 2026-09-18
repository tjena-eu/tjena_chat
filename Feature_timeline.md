# Base

- [] mark as read option in notification
- [] fix  counter for new message marking on Room not increasing (always 1) 

# matrix-based
- [] move calls to new element-calls tech


# Local Bridges

## General
- [] power saving feature for bridge background


## WA
- [] Show all contacts in Group chats
- [] Test and add default local proxy
- [] Per-chat auto-download currently only stops rendering — the Go bridge still
      downloads WA media eagerly. Push the per-chat setting across the FFI to
      actually save data/storage.


## Signal


# Done (build 3706)

- [x] Login field hints `@username:tjena.eu` and says a bare username works
- [x] WA chats sort by real last-activity at sync (room-create timestamp)
- [x] WA chats get contact/group names at sync, not on first remote message
- [x] WA avatars fetched for every chat via a throttled, retrying queue
- [x] Per-chat auto-download media toggle (chat menu) + tap-to-load placeholder
- [x] Stories: auto-download media setting
- [x] WA connection light in the chat app bar (green/orange/red)
- [x] Foreground-service notification now reflects live connection state
      (the service itself already existed)
- [x] Per-space "hide chats from the main list" — already existed
      (`SpaceChildVisibility`, space menu)
