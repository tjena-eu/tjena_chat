#!/usr/bin/env python3
"""Patch flutter_callkit_incoming so Accept on the lock screen doesn't ask
to unlock the phone.

The plugin's CallkitIncomingActivity.onAcceptClick calls
KeyguardManager.requestDismissKeyguard: Android asks for the PIN before the
app shows. tjena's MainActivity decides instead (handleCallAccept): a WhatsApp
call shows its call screen over the lock screen and returns to it when the
call ends; other calls still ask to unlock.

Usage: callkit_lockscreen_fix.py <plugin root>. Idempotent: an already
patched file is left alone. build_android runs it before every build, so it
survives `flutter pub get`.
"""
import os
import sys

TAG = "// tjena-patch: no dismissKeyguard on accept"
OLD = "        startActivity(acceptIntent)\n\n        dismissKeyguard()\n        finish()"
NEW = f"        startActivity(acceptIntent)\n\n        {TAG}\n        finish()"

root = sys.argv[1]
path = os.path.join(root, "android", "src", "main", "kotlin", "com", "hiennv",
                    "flutter_callkit_incoming", "CallkitIncomingActivity.kt")
src = open(path).read()
if TAG in src:
    print("  callkit: already patched")
elif OLD in src:
    open(path, "w").write(src.replace(OLD, NEW, 1))
    print("  callkit: patched", path)
else:
    sys.exit("  callkit: anchor not found (plugin changed?) in " + path)
