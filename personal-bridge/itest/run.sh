#!/usr/bin/env bash
# End-to-end test of the personal bridge stack against a THROWAWAY Synapse in
# Docker (container pb-itest-synapse, 127.0.0.1:18008). Never touches the
# production Synapse.
#
#   unmodified mautrix-whatsapp (linux build of the pinned tag)
#     -> bridge-relay (127.0.0.1)  -> bridge-gateway -> Synapse
#
# Checks: slot activation without per-bridge restart, claim via provisioner,
# bridge start with E2BE (MSC4190 + self_sign), encrypted command round trip
# with a cross-signed client, only m.room.encrypted message events in Synapse's
# DB, provisioning API through the relay, revoke.
#
# Usage: ./run.sh            (keeps WORK dir for inspection; KEEP=1 keeps processes running)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PB="$(cd "$HERE/.." && pwd)"
WORK="${WORK:-$HERE/.work}"
GO="${GO:-$HOME/go/bin/go}"
export GOTOOLCHAIN=auto
TAG="$(grep '^PINNED_TAG=' "$PB/android-binary/build.sh" | cut -d'"' -f2)"
SYN_IMAGE="${SYN_IMAGE:-matrixdotorg/synapse:latest}"
DOCKER_HOST_IP="$(ip -4 addr show docker0 | awk '/inet /{print $2}' | cut -d/ -f1)"
PIDS=()

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

cleanup() {
  if [[ "${KEEP:-0}" == "1" ]]; then echo "KEEP=1: leaving processes and container running"; return; fi
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
  docker rm -f pb-itest-synapse >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "Build"
mkdir -p "$WORK/bin"
(cd "$PB/gateway" && "$GO" build -o "$WORK/bin/gateway" .)
(cd "$PB/relay" && "$GO" build -o "$WORK/bin/relay" .)
(cd "$HERE/client" && CGO_ENABLED=1 "$GO" build -tags goolm -o "$WORK/bin/client" .)
SRC="$PB/android-binary/.work/whatsapp-$TAG"
[[ -d "$SRC" ]] || git clone --quiet --depth 1 --branch "$TAG" https://github.com/mautrix/whatsapp "$SRC"
[[ -z "$(git -C "$SRC" status --porcelain)" ]] || { echo "bridge source modified"; exit 1; }
(cd "$SRC" && CGO_ENABLED=1 "$GO" build -tags goolm -o "$WORK/bin/mautrix-whatsapp" ./cmd/mautrix-whatsapp)
echo "built gateway, relay, client, mautrix-whatsapp $TAG"

log "Fresh throwaway Synapse"
docker rm -f pb-itest-synapse >/dev/null 2>&1 || true
rm -rf "$WORK/synapse" "$WORK/gw" "$WORK/phone" "$WORK/phone2"
mkdir -p "$WORK/synapse" "$WORK/gw" "$WORK/phone"
docker run --rm -v "$WORK/synapse:/data" -e SYNAPSE_SERVER_NAME=pbtest.local -e SYNAPSE_REPORT_STATS=no \
  -e UID="$(id -u)" -e GID="$(id -g)" "$SYN_IMAGE" generate >/dev/null

cat > "$WORK/gw/config.yaml" <<EOF
public_listen: 127.0.0.1:29331
internal_listen: $DOCKER_HOST_IP:29332
public_url: http://127.0.0.1:29331
internal_url: http://host.docker.internal:29332
server_name: pbtest.local
synapse_url: http://127.0.0.1:18008
data_dir: $WORK/gw
registration_dir: $WORK/synapse/pb-reg
registration_dir_in_synapse: /data/pb-reg
slot_prefix: wa
claim_rate_limit_per_hour: 20
EOF
"$WORK/bin/gateway" -config "$WORK/gw/config.yaml" slots-add 3 | tee "$WORK/snippet.txt"

echo >> "$WORK/synapse/homeserver.yaml"
cat >> "$WORK/synapse/homeserver.yaml" <<EOF
$(grep -v '^#\|keep your existing' "$WORK/snippet.txt" | sed -n '/app_service_config_files:/,$p')
enable_registration: false
experimental_features:
  msc2409_to_device_messages_enabled: true
  msc3202_transaction_extensions: true
rc_message: {per_second: 1000, burst_count: 1000}
rc_login:
  address: {per_second: 1000, burst_count: 1000}
  account: {per_second: 1000, burst_count: 1000}
  failed_attempts: {per_second: 1000, burst_count: 1000}
rc_joins:
  local: {per_second: 1000, burst_count: 1000}
EOF
docker run -d --name pb-itest-synapse -p 127.0.0.1:18008:8008 \
  --add-host host.docker.internal:host-gateway \
  -v "$WORK/synapse:/data" -e UID="$(id -u)" -e GID="$(id -g)" "$SYN_IMAGE" >/dev/null
for i in $(seq 60); do curl -sf http://127.0.0.1:18008/health >/dev/null && break; sleep 1; done
curl -sf http://127.0.0.1:18008/health >/dev/null && pass "synapse up ($(docker exec pb-itest-synapse python -c 'import synapse;print(synapse.__version__)'))"
docker exec pb-itest-synapse register_new_matrix_user -c /data/homeserver.yaml -u alice -p alicepass --no-admin http://localhost:8008 >/dev/null
docker exec pb-itest-synapse register_new_matrix_user -c /data/homeserver.yaml -u mallory -p mallorypass --no-admin http://localhost:8008 >/dev/null

log "Gateway"
"$WORK/bin/gateway" -config "$WORK/gw/config.yaml" serve > "$WORK/gw/gateway.log" 2>&1 &
PIDS+=($!)
sleep 1
"$WORK/bin/gateway" -config "$WORK/gw/config.yaml" check-activation | tee "$WORK/slots.txt"
grep -q "wa01 .*free .*true" "$WORK/slots.txt" && pass "slots active after the one-time restart" || fail "slots not active"

login() { curl -sf -X POST http://127.0.0.1:18008/_matrix/client/v3/login \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"$1\"},\"password\":\"$2\",\"initial_device_display_name\":\"$3\"}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["access_token"])'; }
ALICE_BRIDGE_SESSION="$(login alice alicepass 'WhatsApp bridge (home)')"

log "Claim (bridge app: Sign in with tjena -> provisioner)"
curl -sf -X POST -H "Authorization: Bearer $ALICE_BRIDGE_SESSION" http://127.0.0.1:29331/provision/v1/bridge > "$WORK/phone/bundle.json"
python3 - "$WORK/phone/bundle.json" <<'EOF' && pass "claimed slot wa01 for alice" || fail "bad bundle"
import json,sys; b=json.load(open(sys.argv[1]))
assert b["slot"]=="wa01" and b["owner"]=="@alice:pbtest.local" and b["bot_mxid"]=="@wa01bot:pbtest.local", b
EOF
BOT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bot_mxid"])' "$WORK/phone/bundle.json")"
BRIDGE_AS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["as_token"])' "$WORK/phone/bundle.json")"
grep -q "$BRIDGE_AS" "$WORK/synapse/pb-reg/"*.yaml && fail "bridge token appears in Synapse registration" || pass "bridge token differs from real as_token"

log "Phone side: config generation, relay, bridge"
RELAY_PORT=29400
API_SECRET="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
python3 - "$WORK/phone" "$RELAY_PORT" <<'EOF'
import json,sys,secrets
d,port=sys.argv[1],int(sys.argv[2])
json.dump({"data_dir":d,"relay_port":port,"prov_secret":secrets.token_urlsafe(32),
           "pickle_key":secrets.token_urlsafe(32),"extra_users":[]},open(d+"/settings.json","w"))
EOF
"$WORK/bin/mautrix-whatsapp" -e -c "$WORK/phone/example.yaml" >/dev/null
"$WORK/bin/relay" bridge-config "$WORK/phone/example.yaml" "$WORK/phone/bundle.json" "$WORK/phone/settings.json" "$WORK/phone/config.yaml"
PROV_SECRET="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prov_secret"])' "$WORK/phone/settings.json")"
cat > "$WORK/phone/relay.json" <<EOF
{"listen":"127.0.0.1:$RELAY_PORT","upstream":"http://127.0.0.1:29331","as_token":"$BRIDGE_AS",
 "api_secret":"$API_SECRET","prov_secret":"$PROV_SECRET","owner":"@alice:pbtest.local",
 "status_file":"$WORK/phone/relay-status.json","keys_file":"$WORK/phone/observed-keys.json"}
EOF
"$WORK/bin/relay" -config "$WORK/phone/relay.json" > "$WORK/phone/relay.log" 2>&1 &
PIDS+=($!)
sleep 0.5
(cd "$WORK/phone" && exec "$WORK/bin/mautrix-whatsapp" -c config.yaml -n > bridge.out 2>&1) &
PIDS+=($!)
for i in $(seq 60); do
  grep -q '"bridge_connected":true' "$WORK/phone/relay-status.json" 2>/dev/null && break; sleep 1
done
grep -q '"bridge_connected":true' "$WORK/phone/relay-status.json" && pass "bridge connected through relay and gateway" || { fail "bridge did not connect"; tail -30 "$WORK/phone/bridge.out"; exit 1; }
sleep 5

log "Encrypted round trip (cross-signed client <-> bridge bot)"
if "$WORK/bin/client" -hs http://127.0.0.1:18008 -user alice -pass alicepass -bot "$BOT" -db "$WORK/phone/client.db" \
     -cmds "help,list-logins" > "$WORK/client.json" 2> "$WORK/client.err"; then
  cat "$WORK/client.json"
  python3 - "$WORK/client.json" <<'EOF' && pass "bot answered encrypted commands; bot is cross-signed" || fail "client result"
import json,sys; r=json.load(open(sys.argv[1]))
assert r["reply_was_encrypted"], "reply not encrypted"
assert r["bot_cross_signed"], "bot not cross-signed (self_sign)"
assert r["bot_devices"]>=1, "bot has no device (MSC4190)"
assert len(r["replies"])==2
EOF
  ROOM="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["room_id"])' "$WORK/client.json")"
else
  fail "client failed"; cat "$WORK/client.err"; tail -40 "$WORK/phone/bridge.out"; ROOM=""
fi

log "Synapse DB: management room has only encrypted message events"
if [[ -n "$ROOM" ]]; then
  python3 - "$WORK/synapse/homeserver.db" "$ROOM" <<'EOF' && pass "no plaintext m.room.message in Synapse DB" || fail "plaintext found"
import sqlite3,sys
c=sqlite3.connect(f"file:{sys.argv[1]}?mode=ro",uri=True)
rows=c.execute("select type,count(*) from events where room_id=? and state_key is null group by type",(sys.argv[2],)).fetchall()
print("   ",rows)
types=dict(rows)
assert "m.room.message" not in types, types
assert types.get("m.room.encrypted",0)>=4, types
EOF
fi

log "Provisioning API through the relay (stays on the phone)"
FLOWS="$(curl -s -H "Authorization: Bearer $API_SECRET" http://127.0.0.1:$RELAY_PORT/relay/provision/v3/login/flows)"
echo "   $FLOWS" | cut -c1-200
echo "$FLOWS" | grep -q '"phone"' && pass "login flows include phone pairing code" || fail "no phone flow"
START="$(curl -s -X POST -H "Authorization: Bearer $API_SECRET" http://127.0.0.1:$RELAY_PORT/relay/provision/v3/login/start/phone)"
echo "$START" | grep -q '"phone_number"' && pass "phone login step asks for phone_number" || fail "phone login start: $START"
PROC="$(echo "$START" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("login_id",""))' 2>/dev/null || true)"
[[ -n "$PROC" ]] && curl -s -X POST -H "Authorization: Bearer $API_SECRET" "http://127.0.0.1:$RELAY_PORT/relay/provision/v3/login/cancel/$PROC" >/dev/null
CODE="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$RELAY_PORT/relay/provision/v3/login/flows)"
[[ "$CODE" == "401" ]] && pass "relay API rejects calls without the app secret" || fail "relay API open ($CODE)"

log "Move to a new phone (fresh DB, same slot) - old phone is cut off"
SESSION2="$(login alice alicepass 'WhatsApp bridge (home 2)')"
mkdir -p "$WORK/phone2"
curl -sf -X POST -H "Authorization: Bearer $SESSION2" http://127.0.0.1:29331/provision/v1/bridge > "$WORK/phone2/bundle.json"
BRIDGE_AS2="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["as_token"])' "$WORK/phone2/bundle.json")"
python3 -c 'import json,sys;b=json.load(open(sys.argv[1]));assert b["slot"]=="wa01",b' "$WORK/phone2/bundle.json" && pass "re-claim keeps slot wa01 with new tokens"
RELAY_PORT2=29401
python3 - "$WORK/phone2" "$RELAY_PORT2" <<'PY'
import json,sys,secrets
d,port=sys.argv[1],int(sys.argv[2])
json.dump({"data_dir":d,"relay_port":port,"prov_secret":secrets.token_urlsafe(32),
           "pickle_key":secrets.token_urlsafe(32),"extra_users":[]},open(d+"/settings.json","w"))
PY
"$WORK/bin/relay" bridge-config "$WORK/phone/example.yaml" "$WORK/phone2/bundle.json" "$WORK/phone2/settings.json" "$WORK/phone2/config.yaml"
PROV2="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prov_secret"])' "$WORK/phone2/settings.json")"
cat > "$WORK/phone2/relay.json" <<EOF2
{"listen":"127.0.0.1:$RELAY_PORT2","upstream":"http://127.0.0.1:29331","as_token":"$BRIDGE_AS2",
 "api_secret":"$API_SECRET","prov_secret":"$PROV2","owner":"@alice:pbtest.local",
 "status_file":"$WORK/phone2/relay-status.json","keys_file":"$WORK/phone2/observed-keys.json"}
EOF2
"$WORK/bin/relay" -config "$WORK/phone2/relay.json" > "$WORK/phone2/relay.log" 2>&1 &
PIDS+=($!)
sleep 0.5
(cd "$WORK/phone2" && exec "$WORK/bin/mautrix-whatsapp" -c config.yaml -n > bridge.out 2>&1) &
PIDS+=($!)
for i in $(seq 60); do
  grep -q '"bridge_connected":true' "$WORK/phone2/relay-status.json" 2>/dev/null && break; sleep 1
done
# A fresh DB finds the bot's old cross-signing keys on the server and stops.
# The bridge app then sets recovery_key=overwrite in the bridge's own DB and
# restarts it (same as BridgeService.kt does).
if grep -q "Server already has cross-signing keys" "$WORK/phone2/bridge.out"; then
  pass "fresh DB detected old cross-signing keys (expected)"
  python3 - "$WORK/phone2/bridge.db" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("INSERT INTO kv_store (bridge_id,key,value) VALUES ('','recovery_key','overwrite') ON CONFLICT (bridge_id,key) DO UPDATE SET value='overwrite'")
c.commit()
PY
  (cd "$WORK/phone2" && exec "$WORK/bin/mautrix-whatsapp" -c config.yaml -n > bridge.out 2>&1) &
  PIDS+=($!)
  for i in $(seq 60); do
    grep -q '"bridge_connected":true' "$WORK/phone2/relay-status.json" 2>/dev/null && \
      grep -q "Generated new recovery key" "$WORK/phone2/bridge.out" && break; sleep 1
  done
  grep -q "Generated new recovery key" "$WORK/phone2/bridge.out" && pass "overwrite: new cross-signing keys accepted by Synapse" || { fail "overwrite failed"; grep -E "FTL|ERR" "$WORK/phone2/bridge.out" | head -5; }
fi
grep -q '"bridge_connected":true' "$WORK/phone2/relay-status.json" && pass "new phone's bridge connected" || { fail "new phone did not connect"; tail -30 "$WORK/phone2/bridge.out"; }
sleep 3
grep -q '"revoked":true' "$WORK/phone/relay-status.json" && pass "old phone reports revoked" || fail "old phone not cut off: $(cat "$WORK/phone/relay-status.json")"
sleep 5
if "$WORK/bin/client" -hs http://127.0.0.1:18008 -user alice -pass alicepass -bot "$BOT" -db "$WORK/phone2/client.db" \
     -cmds "version" > "$WORK/client2.json" 2> "$WORK/client2.err"; then
  python3 - "$WORK/client2.json" <<'PY' && pass "new phone: encrypted round trip works, bot cross-signed" || fail "new phone round trip"
import json,sys; r=json.load(open(sys.argv[1]))
assert r["reply_was_encrypted"] and r["bot_cross_signed"], r
PY
else
  fail "client against new phone failed"; cat "$WORK/client2.err"; tail -30 "$WORK/phone2/bridge.out"
fi

log "Security screen data matches what Synapse publishes"
PICKLE2="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pickle_key"])' "$WORK/phone2/settings.json")"
"$WORK/bin/relay" security-info "$WORK/phone2/bridge.db" "$PICKLE2" "@alice:pbtest.local" "$BOT" \
  "$WORK/phone2/observed-keys.json" > "$WORK/security.json" 2> "$WORK/security.err" || cat "$WORK/security.err"
ALICE_TOK="$(login alice alicepass 'key check')"
curl -sf -X POST -H "Authorization: Bearer $ALICE_TOK" -H 'Content-Type: application/json' \
  -d "{\"device_keys\":{\"$BOT\":[]}}" http://127.0.0.1:18008/_matrix/client/v3/keys/query > "$WORK/keys-query.json"
python3 - "$WORK/security.json" "$WORK/keys-query.json" "$BOT" <<'PY' && pass "security info: bridge keys from the phone match Synapse; owner device trusted" || fail "security info mismatch"
import json,sys
info=json.load(open(sys.argv[1])); q=json.load(open(sys.argv[2])); bot=sys.argv[3]
m=info["matrix"]
devs=q["device_keys"][bot]
dev=devs[m["device_id"]]
assert dev["keys"]["ed25519:"+m["device_id"]]==m["ed25519"], "device key differs"
master=list(q["master_keys"][bot]["keys"].values())[0]
assert m["master_key"]==master, ("master key differs", m.get("master_key"), master)
assert any(d["cross_signed"] for d in m["owner"]["devices"]), "no trusted owner device"
assert not m["owner"]["master_key_changed"]
assert not info.get("errors"), info.get("errors")
PY
python3 -c 'import json,sys;o=json.load(open(sys.argv[1]));assert o.get("master_key") and o.get("ed25519"),o' "$WORK/phone2/observed-keys.json" \
  && pass "relay recorded the keys the bridge uploaded" || fail "observed-keys.json incomplete: $(cat "$WORK/phone2/observed-keys.json" 2>/dev/null)"
BRIDGE_AS="$BRIDGE_AS2"

log "Isolation"
MALLORY="$(login mallory mallorypass test)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $MALLORY" http://127.0.0.1:29331/provision/v1/bridge)"
[[ "$CODE" == "404" ]] && pass "other users can't see alice's bridge" || fail "mallory status $CODE"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $BRIDGE_AS" http://127.0.0.1:29331/_matrix/app/v1/transactions/x -d '{}')"
[[ "$CODE" == "404" ]] && pass "appservice push endpoint not on public listener" || fail "public /_matrix/app reachable ($CODE)"

log "Revoke (no Synapse restart)"
curl -sf -X DELETE -H "Authorization: Bearer $ALICE_BRIDGE_SESSION" http://127.0.0.1:29331/provision/v1/bridge >/dev/null
sleep 3
grep -q '"revoked":true' "$WORK/phone2/relay-status.json" && pass "relay reports revoked" || fail "relay not revoked: $(cat "$WORK/phone2/relay-status.json")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $BRIDGE_AS" http://127.0.0.1:29331/_matrix/client/v3/account/whoami)"
[[ "$CODE" == "401" ]] && pass "revoked bridge token rejected by Synapse" || fail "revoked token still works ($CODE)"

log "Audit log"
cat "$WORK/gw/audit.jsonl"
grep -q "$BRIDGE_AS" "$WORK/gw/audit.jsonl" && fail "token in audit log" || pass "audit log has no tokens"

echo
[[ "$FAILED" == "0" ]] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
