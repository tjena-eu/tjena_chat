# call-provisioner

Mints ephemeral **guest user + temporary unencrypted Matrix call room** so a Tjena
host can "call" a WhatsApp-bridged contact via a shareable web link. The contact
joins from a browser (`call-web/`) and the call runs over **legacy `m.call.*`
VoIP** through your existing coturn — no app, no WhatsApp call.

Single static Go binary, standard library only.

```
go build -o call-provisioner .
```

## API

### `POST /api/calls`
Auth: `Authorization: Bearer <host's Matrix access token>` (the Tjena app sends
its own token). The backend validates it via `/_matrix/client/v3/account/whoami`
and force-joins that user.

Response:
```json
{ "callId": "!room:tjena.eu", "room": "!room:tjena.eu",
  "expiresAt": "2026-06-23T10:00:00Z",
  "link": "https://call.tjena.eu/#hs=...&room=...&user=...&token=..." }
```
All link params live in the URL **fragment** (`#…`) so the bearer token never
reaches web-server access logs.

### `DELETE /api/calls/{roomId}`
Deactivates the guest + purges the room. A 5-minute sweep does this automatically
for calls older than `CALL_TTL_MINUTES`.

## Environment
```
SYNAPSE_BASE_URL=http://localhost:8008        # internal admin/client base
PUBLIC_HS_URL=https://matrix.tjena.eu          # what the guest browser connects to
PUBLIC_WEB_BASE=https://call.tjena.eu          # where call-web is served
ADMIN_TOKEN=<@callbot access token>            # admin service account
REGISTRATION_SHARED_SECRET=<same as homeserver.yaml>
CALL_TTL_MINUTES=30
LISTEN_ADDR=:8090
```

## Synapse setup (`homeserver.yaml`)
```yaml
registration_shared_secret: "<LONG_RANDOM_SECRET>"   # backend only
turn_allow_guests: true                              # guests get your coturn creds
# turn_uris / turn_shared_secret: keep your EXISTING coturn config (reused).
```
Reload Synapse. Then create the admin service account once:
```
register_new_matrix_user -c homeserver.yaml -u callbot -p '<pw>' -a
# log it in once to get @callbot's access token for ADMIN_TOKEN
```
The admin API (`/_synapse/admin/*`) must be reachable from this backend on the
internal network/localhost only — never expose it or the secrets publicly.

## Deploy (Cloudflare Tunnel, HTTP only)
- `call.tjena.eu`        → static `call-web/dist/`
- `call.tjena.eu/api/*`  → this backend (`LISTEN_ADDR`)
- `matrix.tjena.eu`      → Synapse (existing)
- coturn stays **public/direct** (not through the tunnel); media is P2P/relay.

## Notes
- Rooms are intentionally **unencrypted** (no `m.room.encryption`); media is
  still DTLS-SRTP. Signalling is plaintext. Accepted tradeoff for a stopgap.
- The link is a capability — anyone with it can join as that guest. Mitigated by
  short TTL. Keep `CALL_TTL_MINUTES` low.
