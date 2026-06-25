// Guest call client. Boots a headless matrix-js-sdk client from the link's
// fragment params, joins the temporary unencrypted call room, and places a
// legacy m.call.* video call on a user gesture. No crypto init (plaintext room).
import {
  createClient,
  ClientEvent,
  SyncState,
  CallEvent,
  type MatrixClient,
} from "matrix-js-sdk";

// In matrix-js-sdk v34 the call enums/classes aren't top-level exports. Derive
// the call type from the client method and use the literal hangup reason value
// (CallErrorCode.UserHangup === "user_hangup") to avoid internal-path imports.
type MatrixCall = NonNullable<ReturnType<MatrixClient["createCall"]>>;
const USER_HANGUP = "user_hangup";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const remoteVideo = $("remote") as HTMLVideoElement;
const localVideo = $("local") as HTMLVideoElement;
const overlay = $("overlay");
const controls = $("controls");
const statusEl = $("status");
const hintEl = $("hint");
const joinBtn = $("join") as HTMLButtonElement;
const micBtn = $("mic") as HTMLButtonElement;
const camBtn = $("cam") as HTMLButtonElement;
const hangupBtn = $("hangup") as HTMLButtonElement;

function setStatus(s: string) { statusEl.textContent = s; }
function showError(msg: string) {
  overlay.classList.remove("hidden");
  hintEl.classList.add("err");
  hintEl.textContent = msg;
  joinBtn.style.display = "none";
}

const p = new URLSearchParams(location.hash.slice(1));
const baseUrl = p.get("hs");
const accessToken = p.get("token");
const userId = p.get("user");
const roomId = p.get("room");
const deviceId = p.get("device") ?? undefined;
const mode = p.get("mode"); // "audio" | "video" (defaults to video)

/// Returns a human list of which required link params are missing, or '' if ok.
function missingParams(): string {
  const miss: string[] = [];
  if (!baseUrl) miss.push("hs");
  if (!roomId) miss.push("room");
  if (!userId) miss.push("user");
  if (!accessToken) miss.push("token");
  return miss.join(", ");
}

let client: MatrixClient | null = null;
let activeCall: MatrixCall | null = null;

// ── Screen wake lock + proximity (best-effort) ───────────────────────────────
// A web page can't turn the device screen off like a native app, but we can keep
// the screen awake during a call and, where the browser exposes a proximity
// sensor, blank the controls with a touch-absorbing overlay near the ear.
let wakeLock: any = null;
let proxStarted = false;

async function acquireWakeLock() {
  try {
    wakeLock = await (navigator as any).wakeLock?.request("screen");
  } catch {
    /* not supported / denied — ignore */
  }
}
function releaseWakeLock() {
  try {
    wakeLock?.release?.();
  } catch {
    /* ignore */
  }
  wakeLock = null;
}
// Wake locks are dropped when the tab is hidden; re-acquire when visible again.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible" && activeCall) acquireWakeLock();
});

function setProx(near: boolean) {
  document.getElementById("prox")?.classList.toggle("hidden", !near);
}

async function startProximity() {
  if (proxStarted) return;
  proxStarted = true;
  // Generic Sensor API (Chrome-experimental). near/distance → blank overlay.
  try {
    const Sensor = (window as any).ProximitySensor;
    if (Sensor) {
      const sensor = new Sensor();
      sensor.addEventListener("reading", () => {
        const near =
          sensor.near === true ||
          (typeof sensor.distance === "number" && sensor.distance < 5);
        setProx(near);
      });
      sensor.addEventListener("error", () => setProx(false));
      sensor.start();
      return;
    }
  } catch {
    /* fall through to legacy */
  }
  // Legacy event (very old Firefox). No-op on modern browsers.
  window.addEventListener("userproximity" as any, (e: any) => setProx(!!e.near));
}

async function boot(): Promise<MatrixClient> {
  const miss = missingParams();
  if (miss) {
    throw new Error(
      `Call link is incomplete — missing: ${miss}. The link was likely truncated when copied; use the full URL.`,
    );
  }
  // deviceId is required by matrix-js-sdk to place legacy m.call.* calls
  // ("Client must have a device ID to start calls"). It comes in the link; if
  // missing, fall back to whoami so older links still work.
  let dev = deviceId;
  if (!dev) {
    try {
      const who = await fetch(
        `${baseUrl}/_matrix/client/v3/account/whoami`,
        { headers: { Authorization: `Bearer ${accessToken}` } },
      ).then((r) => r.json());
      dev = who.device_id;
    } catch {
      /* ignore — createCall will surface a clear error */
    }
  }
  const c = createClient({
    baseUrl,
    accessToken,
    userId,
    deviceId: dev,
    useAuthorizationHeader: true,
  });
  // Don't force relay-only: forcing TURN makes the call depend entirely on the
  // homeserver's TURN creds working (they currently point at Metered and fail).
  // Allowing host/STUN candidates lets ICE use the same direct path that native
  // Matrix↔Matrix calls already use. (TURN is still used as a fallback if the
  // homeserver vends working creds.)
  // Don't force relay-only: allowing host/STUN candidates lets ICE use the same
  // direct path that native Matrix↔Matrix calls use (TURN is still a fallback).
  c.setForceTURN(false);
  await c.startClient({ initialSyncLimit: 1 });
  await new Promise<void>((res) =>
    c.on(ClientEvent.Sync, (s: SyncState) => { if (s === SyncState.Prepared) res(); }),
  );
  await c.joinRoom(roomId);
  return c;
}

function wireMedia(call: MatrixCall) {
  call.on(CallEvent.FeedsChanged, (feeds) => {
    for (const feed of feeds) {
      const el = feed.isLocal() ? localVideo : remoteVideo;
      if (el.srcObject !== feed.stream) el.srcObject = feed.stream ?? null;
    }
  });
  call.on(CallEvent.State, () => setStatus(call.state));
  call.on(CallEvent.Hangup, () => endUI("Call ended"));
  call.on(CallEvent.Error, (err) => showError(err?.message ?? "Call error"));
}

function endUI(msg: string) {
  setStatus(msg);
  controls.classList.add("hidden");
  overlay.classList.remove("hidden");
  hintEl.textContent = msg;
  joinBtn.textContent = "Re-join";
  joinBtn.style.display = "";
  releaseWakeLock();
  setProx(false);
}

async function joinCall() {
  joinBtn.disabled = true;
  setStatus("Connecting…");
  try {
    if (!client) client = await boot();
    // We place the call; the Tjena host answers with its native incoming-call
    // UI. Placing immediately shows our local video and enables the controls.
    const call = client.createCall(roomId!);
    if (!call) throw new Error("Could not create the call");
    activeCall = call;
    wireMedia(call);
    if (mode === "audio") {
      camBtn.style.display = "none"; // no camera in a voice call
      await call.placeVoiceCall();
      // Voice call → keep screen awake and blank controls near the ear.
      startProximity();
    } else {
      await call.placeVideoCall();
    }
    await acquireWakeLock(); // keep the screen on during the call
    overlay.classList.add("hidden");
    controls.classList.remove("hidden");
  } catch (e: any) {
    showError(e?.message ?? "Failed to start the call");
  } finally {
    joinBtn.disabled = false;
  }
}

joinBtn.addEventListener("click", joinCall);
micBtn.addEventListener("click", () => {
  if (!activeCall) return;
  const muted = !activeCall.isMicrophoneMuted();
  activeCall.setMicrophoneMuted(muted);
  micBtn.classList.toggle("on", muted);
});
camBtn.addEventListener("click", () => {
  if (!activeCall) return;
  const muted = !activeCall.isLocalVideoMuted();
  activeCall.setLocalVideoMuted(muted);
  camBtn.classList.toggle("on", muted);
});
hangupBtn.addEventListener("click", () => {
  activeCall?.hangup(USER_HANGUP as any, false);
});

// Validate the link up front so a broken/truncated link shows a precise error.
if (missingParams()) {
  showError(
    `Call link is incomplete — missing: ${missingParams()}. ` +
        `The link was likely cut off when copied; open the full URL.`,
  );
}
