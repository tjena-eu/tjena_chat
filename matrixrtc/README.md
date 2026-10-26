# MatrixRTC calls (LiveKit) for tjena

tjena 2.11 can make **MatrixRTC calls** (group calls, phone-style incoming
call screen). They need a LiveKit media server (SFU) and a small token
service. Until both are set up, tjena keeps using the **old 1:1 calls**, so
nothing breaks before you switch.

How the app decides: it reads `https://tjena.eu/.well-known/matrix/client`.
If that lists a LiveKit service (`org.matrix.msc4143.rtc_foci`), the call
button starts a MatrixRTC call; otherwise it starts an old 1:1 call (direct
chats only). WhatsApp chats of your own bridge always use WhatsApp calls.

```
tjena app ──(1) openid token──► tjena-lk-jwt (home, behind tunnel) ──checks──► Synapse
          ◄──(2) LiveKit token + wss URL─────┘
          ──(3) media, end-to-end encrypted──► LiveKit Cloud (SFU)
```

## 1. LiveKit Cloud project

1. Sign up at https://cloud.livekit.io (free "Build" plan).
2. Create a project. Choose **EU (Frankfurt)** as data region (can't be
   changed later).
3. Project → Settings → Keys: note the **wss URL**, **API key** and
   **API secret**.
4. If the project settings offer it, turn **automatic room creation off**.
   Then only tjena users can open calls on your quota (the token service
   creates rooms for them); users of other servers can only join.

## 2. Token service (Portainer)

1. Copy `lk-jwt.env.example` to `lk-jwt.env` next to the stack and fill in
   the three LiveKit values. `chmod 600 lk-jwt.env`.
2. Add the `tjena-lk-jwt` service from `docker-compose.yml` to the tjena stack
   (or deploy it as its own stack; it only needs the `docker_local_net`
   network).
3. Check: `docker logs tjena-lk-jwt` shows it listening on `:8080`, and
   `docker inspect --format '{{.State.Health.Status}}' tjena-lk-jwt` says
   `healthy`.

## 3. Public hostname

Cloudflare Zero Trust → Networks → Tunnels → (your tunnel) → Public hostnames
→ Add:

- Subdomain `matrixrtc`, domain `tjena.eu`
- Service: `HTTP` → `tjena-lk-jwt:8080`

Check: `curl https://matrixrtc.tjena.eu/healthz` answers 200.

## 4. Switch tjena to MatrixRTC calls

Replace `static/.well-known/matrix/client` in the **tjena_website** repo with
`well-known-client.json` from this folder (it only adds the
`org.matrix.msc4143.rtc_foci` entry) and deploy the website.

Check: `curl https://tjena.eu/.well-known/matrix/client` shows the
`rtc_foci` entry. Apps pick it up when a chat is opened; no app update.

**Rollback:** put the old `client` file back. The apps fall back to the old
1:1 calls.

## Good to know

- Calls are end-to-end encrypted (keys go device to device over Matrix).
  LiveKit sees who is in a call, IP addresses and timing, not the content.
  Mention LiveKit (US company, EU data region) in the privacy policy.
- Free plan: 5,000 participant-minutes a month (a 1:1 call uses 2 per
  minute), 100 simultaneous connections, 50 GB downstream data.
- Moving to a self-hosted LiveKit later: only `LIVEKIT_URL`, `LIVEKIT_KEY`
  and `LIVEKIT_SECRET` change. The app and `.well-known` stay the same.
- **Switch only when most people run tjena 2.11 or newer.** Older tjena
  versions can't answer MatrixRTC calls; they only know the old 1:1 calls.
- Rooms where members may not send state events (older groups) can't start
  MatrixRTC calls: there the button stays hidden for normal members (direct
  chats fall back to the old 1:1 call). Give the
  `org.matrix.msc3401.call.member` event power level 0 in such groups.
- tjena never uses a third-party LiveKit server: the app's fallback setting
  is empty.
