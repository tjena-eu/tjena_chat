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

let client: MatrixClient | null = null;
let activeCall: MatrixCall | null = null;

async function boot(): Promise<MatrixClient> {
  if (!baseUrl || !accessToken || !userId || !roomId) {
    throw new Error("This call link is invalid or expired.");
  }
  const c = createClient({ baseUrl, accessToken, userId, useAuthorizationHeader: true });
  c.setForceTURN(true); // always relay — reliable behind symmetric NAT/CGNAT
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
}

async function joinCall() {
  joinBtn.disabled = true;
  setStatus("Connecting…");
  try {
    if (!client) client = await boot();
    const call = client.createCall(roomId!);
    if (!call) throw new Error("Could not create call");
    activeCall = call;
    wireMedia(call);
    await call.placeVideoCall();
    overlay.classList.add("hidden");
    controls.classList.remove("hidden");
  } catch (e: any) {
    showError(e?.message ?? "Failed to join the call");
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

// Validate the link up front so an expired/broken link shows an error.
if (!baseUrl || !accessToken || !userId || !roomId) {
  showError("This call link is invalid or expired.");
}
