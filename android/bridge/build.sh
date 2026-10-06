#!/usr/bin/env bash
# Build, sign and (optionally) install the bridge app.
#
#   ./build.sh                               build and sign -> build/parallel-root-bridge.apk
#   PHONE_DEVICE=my-phone ./build.sh install also install it on the phone and
#                                            enable its notification listener
#
# No Gradle and no Android Studio. The app has no resources and no UI, which
# is what makes that practical: aapt2 link needs only a manifest, javac needs
# only android.jar, and the rest is d8, zipalign and apksigner. Two classes
# and five tool invocations.
#
# Environment:
#   ANDROID_HOME, ANDROID_SDK_ROOT  the SDK, in that order; otherwise the first
#                  of ~/Library/Android/sdk, ~/Android/Sdk,
#                  /opt/homebrew/share/android-commandlinetools and
#                  /usr/lib/android-sdk that has build-tools in it
#   ANDROID_API    platform to compile against and target (default 36)
#   PHONE_DEVICE   ssh host of the phone; required by install, no default
#   PHONE_BIN      the phone CLI (default: this repository's bin/phone)
# Everything else in the environment, PHONE_LANE and PHONE_REMOTE_BIN
# included, passes through to the CLI untouched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
APK="$OUT/parallel-root-bridge.apk"
KS="$OUT/debug.keystore"
PKG="parallelroot.bridge"
LISTENER="$PKG/.Listener"
PORT=8137
API="${ANDROID_API:-36}"
DEVICE="${PHONE_DEVICE:-}"
PHONE_BIN="${PHONE_BIN:-$HERE/../../bin/phone}"

die() { echo "build.sh: $*" >&2; exit 2; }

usage() {
  echo "usage: $0            build and sign $APK"
  echo "       PHONE_DEVICE=<ssh-host> $0 install"
  echo "                     build, install on the phone, enable the listener"
}

case "${1:-}" in
  "") INSTALL=0 ;;
  install) INSTALL=1 ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

case "$API" in
  ''|*[!0-9]*) die "ANDROID_API must be a number, got '$API'" ;;
esac

# Checked before the build, not after it: a missing device is a fact about
# the request, and finding it out only after a full build wastes the build.
if [ "$INSTALL" = 1 ]; then
  [ -n "$DEVICE" ] || die "install needs PHONE_DEVICE, the ssh host of the phone's Termux sshd:
  PHONE_DEVICE=my-phone $0 install"
  case "$DEVICE" in -*) die "PHONE_DEVICE must be an ssh host, got '$DEVICE'" ;; esac
  command -v "$PHONE_BIN" >/dev/null 2>&1 \
    || die "no phone CLI at $PHONE_BIN (set PHONE_BIN to its path)"
fi

# An SDK named in the environment is used as named, even when it turns out
# to be incomplete: building against some other SDK than the one asked for is
# worse than failing with the path that was given.
find_sdk() {
  if [ -n "${ANDROID_HOME:-}" ]; then echo "$ANDROID_HOME"; return 0; fi
  if [ -n "${ANDROID_SDK_ROOT:-}" ]; then echo "$ANDROID_SDK_ROOT"; return 0; fi
  local d
  for d in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" \
           /opt/homebrew/share/android-commandlinetools /usr/lib/android-sdk; do
    if [ -d "$d/build-tools" ]; then echo "$d"; return 0; fi
  done
  return 0
}
SDK="$(find_sdk)"
[ -n "$SDK" ] || { echo "no Android SDK found: set ANDROID_HOME" >&2; exit 1; }

BT="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
PLATFORM="$SDK/platforms/android-$API/android.jar"

need() {
  [ -e "$1" ] || { echo "missing: $1" >&2
                   echo "run: sdkmanager 'build-tools;${API}.0.0' 'platforms;android-${API}'" >&2
                   exit 1; }
}
need "${BT:-$SDK/build-tools/<none installed>}"
need "$BT/aapt2"
need "$BT/d8"
need "$BT/zipalign"
need "$BT/apksigner"
need "$PLATFORM"
{ command -v javac >/dev/null 2>&1 && javac -version >/dev/null 2>&1; } \
  || { echo "no working javac on PATH: a JDK, 11 or newer, is needed" >&2; exit 1; }

# Everything in build/ but the keystore: the rest is scratch, the key is not
# (step 4 says why).
rm -rf "$OUT/classes" "$OUT/dex" "$OUT/sources.txt" "$OUT/classes.jar" \
       "$OUT/base.apk" "$OUT/aligned.apk" "$APK" "$APK.idsig"
mkdir -p "$OUT/classes" "$OUT/dex"

# 1. Manifest -> a resource-less APK skeleton. No res/ dir at all: aapt2 link
#    is happy without one, and every resource we do not have is a build step,
#    an ID space and a compat library we do not have to carry.
#
#    minSdk 31 is Android 12, and it is the floor README and docs/setup.md
#    state for the bridge. Nothing in the two classes needs more than API 24,
#    but nothing older than the reference device's Android 16 has been tried,
#    so it is not lowered on reading alone.
"$BT/aapt2" link \
  -I "$PLATFORM" \
  --manifest "$HERE/AndroidManifest.xml" \
  --min-sdk-version 31 --target-sdk-version "$API" \
  -o "$OUT/base.apk"

# 2. Compile against android.jar on the CLASSPATH.
#
#    Not -bootclasspath: JDK 12 removed it for -source >= 9, and JDK 21
#    rejects it outright ("option --boot-class-path not allowed with target
#    11"). android.jar on the classpath supplies android.*; java.* comes from
#    the JDK, which is fine for code this small but does mean the compiler
#    will happily accept a java.* API that Android lacks. d8 --min-api is the
#    net under that.
#
#    NO `|| true` here. Piping javac through grep swallows its exit status:
#    a compile error prints one line and the build carries on to zip a dex
#    that does not exist — reporting a zip problem for a Java problem. A
#    build step that cannot fail is not a build step.
#
#    One quoted path per line in the @argfile, which splits on whitespace: a
#    checkout under a directory with a space in its name is ordinary. The
#    paths are relative to this directory and javac runs from it, so the
#    argfile never records where the checkout lives; it is scratch, and goes
#    as soon as javac is done with it.
(cd "$HERE" && find src -name '*.java' | sed 's/.*/"&"/') > "$OUT/sources.txt"
(cd "$HERE" && javac -source 11 -target 11 -nowarn -Xlint:-options \
  -classpath "$PLATFORM" \
  -d "$OUT/classes" \
  @"$OUT/sources.txt")
rm -f "$OUT/sources.txt"

# 3. Dex. The classes go in as one jar rather than as a word-split list of
#    paths, for the same space-in-a-directory reason.
(cd "$OUT/classes" && zip -qr "$OUT/classes.jar" .)
"$BT/d8" --min-api 31 --lib "$PLATFORM" --output "$OUT/dex" "$OUT/classes.jar"
[ -f "$OUT/dex/classes.dex" ] || { echo "d8 produced no classes.dex" >&2; exit 1; }

# 4. Fold the dex in, align, sign. A debug keystore is generated on first run
#    — this app is built and sideloaded by the person whose phone it runs on,
#    never published to a store, so a throwaway key is the honest amount of
#    ceremony. It goes in build/, which is never committed, and it is KEPT
#    across rebuilds: Android installs an update only when it is signed by
#    the same key as the copy already on the phone, so a new key per build
#    would turn every reinstall into a refusal.
(cd "$OUT/dex" && zip -q "$OUT/base.apk" classes.dex)
if [ ! -f "$KS" ]; then
  echo "→ generating a debug keystore: $KS"
  keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=parallel-root debug" >/dev/null 2>&1 \
    || { rm -f "$KS"; echo "keytool could not generate $KS" >&2; exit 1; }
fi
"$BT/zipalign" -f -p 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign \
  --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$APK" "$OUT/aligned.apk"
rm -f "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" verify "$APK" >/dev/null

echo "built: $APK"

[ "$INSTALL" = 1 ] || exit 0

# ---------------------------------------------------------------- install
# TWO different identities on the phone, and the install crosses between them:
#
#   ssh lands as the TERMUX APP (uid 10xxx). It can write /sdcard. It cannot
#   write /data/local/tmp, which is shell-owned ("Permission denied").
#   `phone sh` runs at SHELL uid (2000) through Shizuku. It can run pm and
#   cmd. It can read /sdcard.
#
# So the APK travels through /sdcard, the one place both can reach.
STAGE_DIR="/sdcard/.phone"
STAGE_SD="$STAGE_DIR/parallel-root-bridge.apk"
STAGE="/data/local/tmp/parallel-root-bridge.apk"

echo "→ copying to $DEVICE (as the app)"
ssh -o BatchMode=yes "$DEVICE" "mkdir -p $STAGE_DIR && cat > $STAGE_SD" < "$APK"

# THEN a second hop, shell-side, because /sdcard is a fuse mount and
# system_server is not allowed to read it:
#
#   avc: denied { read } scontext=u:r:system_server:s0 tcontext=u:object_r:fuse:s0
#   Error: Unable to open file: /sdcard/.phone/parallel-root-bridge.apk
#   Consider using a file under /data/local/tmp/
#
# The installer runs inside system_server, so handing it a /sdcard path fails
# no matter which UID typed the command. Shell can read /sdcard AND write
# /data/local/tmp, so it is the only identity that can move it across.
echo "→ staging where the installer can read it (as shell)"
"$PHONE_BIN" --device "$DEVICE" sh \
  "cp $STAGE_SD $STAGE && chmod 644 $STAGE" >/dev/null

# Captured rather than piped through tail: what to do next depends on what pm
# said, and the staged copies are removed whichever way it went.
echo "→ installing (as shell)"
got="$("$PHONE_BIN" --device "$DEVICE" sh "pm install -r $STAGE" 2>&1)" || true
"$PHONE_BIN" --device "$DEVICE" sh "rm -f $STAGE_SD $STAGE" >/dev/null 2>&1 || true
printf '%s\n' "$got" | tail -2
case "$got" in
  *Success*) ;;
  *INSTALL_FAILED_UPDATE_INCOMPATIBLE*)
    echo "the bridge already on the phone is signed by a different key: a fresh" >&2
    echo "build/ makes a fresh debug key. Remove the old one and run this again" >&2
    echo "(the rerun grants the listener again; the new copy mints a new token):" >&2
    echo "  phone --device $DEVICE sh 'pm uninstall $PKG'" >&2
    exit 1 ;;
  *INSTALL_FAILED_OLDER_SDK*)
    echo "this phone's Android is older than the bridge allows: it needs" >&2
    echo "Android 12 (SDK 31) or later. Nothing else in parallel-root needs the" >&2
    echo "bridge; only \`phone reply\` does." >&2
    exit 1 ;;
  *)
    echo "the install did not succeed" >&2
    exit 1 ;;
esac

echo "→ enabling the notification listener (as shell)"
"$PHONE_BIN" --device "$DEVICE" sh "cmd notification allow_listener $LISTENER" | tail -1
# Best effort, and not needed for the grant above. Android 13 and later can
# treat a sideloaded app's notification-access switch in the Settings app as
# a "restricted setting" and refuse to turn it on. Allowing the app's
# restricted settings here keeps that switch usable, so the grant can later be
# turned off and on from Settings — the remedy the bridge's own "not bound"
# error points to — without another trip through a shell.
"$PHONE_BIN" --device "$DEVICE" sh "cmd appops set $PKG ACCESS_RESTRICTED_SETTINGS allow" \
  >/dev/null 2>&1 || true

# Read first and searched second, so a phone that could not be asked is not
# reported as a grant that did not take.
listeners="$("$PHONE_BIN" --device "$DEVICE" sh \
  "settings get secure enabled_notification_listeners")"
echo "→ enabled listeners now:"
if printf '%s\n' "$listeners" | tr ':' '\n' | grep -F "$PKG/"; then
  :
else
  echo "   $PKG is NOT in the list — the grant did not take" >&2
  exit 1
fi

echo
echo "The system binds the listener by itself, and the bridge starts with it."
echo "Check it end to end (the CLI opens the ssh forward to port $PORT itself):"
echo "  phone --device $DEVICE reply --list"
echo "A list, or \"nothing on this phone can be replied to\", both mean it answered."
echo
echo "Or by hand: forward the port, then send one line of JSON carrying the token"
echo "in /sdcard/Android/data/$PKG/files/token (shell can read it):"
echo "  ssh -N -L $PORT:127.0.0.1:$PORT $DEVICE"
echo "  {\"op\":\"ping\",\"token\":\"<token>\"}  ->  {\"ok\":true,\"bound\":true}"
