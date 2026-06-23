# call-web

Static guest call client for Tjena WhatsApp call links. Vite + matrix-js-sdk +
TypeScript. The guest opens the link in any browser (no app, no Matrix account),
joins a temporary unencrypted room and places a legacy `m.call.*` video call;
the Tjena host's existing call UI rings and answers.

No crypto is initialised (the room is plaintext). TURN/STUN are auto-fetched
from your homeserver (`/_matrix/client/v3/voip/turnServer`) and forced on with
`setForceTURN(true)`, so it reuses your existing coturn.

## Develop / build
Requires **Node 18+** (matrix-js-sdk + Vite). On a machine with a modern Node:
```
npm install
npm run dev      # local dev (proxies /api -> http://localhost:8090)
npm run build    # -> dist/  (serve at call.tjena.eu)
```

## Link format
```
https://call.tjena.eu/#hs=<public hs url>&room=<roomId>&user=<guestUserId>&token=<guestToken>
```
Params ride in the URL **fragment** so the bearer token never hits server logs.
Minted by `call-provisioner` (`POST /api/calls`).
