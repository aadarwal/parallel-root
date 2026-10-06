#!/usr/bin/env bash
# Build the display holder dex, and optionally stage it on the phone.
#
#   ./build.sh                               build -> build/parallel-root-vdisplay.jar
#   PHONE_DEVICE=my-phone ./build.sh install also stage it on the phone, at
#                                            /data/local/tmp/parallel-root-vdisplay.jar
#
# NOT an APK. app_process wants a jar with a classes.dex in it and nothing
# else — no manifest, no resources, no signing. Two tool invocations.
#
# If no Android SDK resolves here and $VD_BUILD_HOST names an ssh host that
# has one, the source is shipped there, built, and the jar comes back. Same
# output either way.
#
# Environment:
#   ANDROID_HOME, ANDROID_SDK_ROOT  the SDK, in that order; otherwise the first
#                    of ~/Library/Android/sdk, ~/Android/Sdk,
#                    /opt/homebrew/share/android-commandlinetools and
#                    /usr/lib/android-sdk that has build-tools in it
#   ANDROID_API      platform to compile against (default 36)
#   VD_BUILD_HOST    ssh host to build on when there is no SDK here (no default)
#   PHONE_DEVICE     ssh host of the phone; required by install, no default
#   PHONE_BIN        the phone CLI (default: this repository's bin/phone)
# Everything else in the environment, PHONE_LANE and PHONE_REMOTE_BIN
# included, passes through to the CLI untouched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
JAR="$OUT/parallel-root-vdisplay.jar"
API="${ANDROID_API:-36}"
BUILD_HOST="${VD_BUILD_HOST:-}"
DEVICE="${PHONE_DEVICE:-}"
PHONE_BIN="${PHONE_BIN:-$HERE/../../bin/phone}"

# The device path is /data/local/tmp, not /sdcard. /sdcard is a fuse mount
# and the runtime will not load a dex from it; /data/local/tmp is shell-owned,
# which is exactly the uid app_process runs the holder as.
STAGE_DIR="/sdcard/.phone"
STAGE_SD="$STAGE_DIR/parallel-root-vdisplay.jar"
STAGE="/data/local/tmp/parallel-root-vdisplay.jar"

die() { echo "build.sh: $*" >&2; exit 2; }

usage() {
  echo "usage: $0            build $JAR"
  echo "       PHONE_DEVICE=<ssh-host> $0 install"
  echo "                     build, then stage it at $STAGE"
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
# the request, and finding it out only after a full compile wastes the compile.
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

have_sdk() {
  [ -n "$SDK" ] && [ -d "$SDK/build-tools" ] && command -v javac >/dev/null 2>&1 \
    && javac -version >/dev/null 2>&1
}

build_here() {
  local bt platform
  bt="$(ls -d "$SDK"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
  platform="$SDK/platforms/android-$API/android.jar"
  [ -n "$bt" ] || { echo "no build-tools under $SDK" >&2; exit 1; }
  [ -x "$bt/d8" ] || { echo "missing $bt/d8" >&2; exit 1; }
  [ -f "$platform" ] || { echo "missing $platform" >&2
                          echo "run: sdkmanager 'platforms;android-$API'" >&2
                          exit 1; }

  rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/dex"
  # One quoted path per line: an @argfile splits on whitespace, and a checkout
  # under a directory with a space in its name is an ordinary thing to have.
  # Relative to this directory, with javac run from it, so the argfile never
  # records where the checkout lives; it goes once javac is done with it.
  (cd "$HERE" && find src -name '*.java' | sed 's/.*/"&"/') > "$OUT/sources.txt"
  # android.jar on the CLASSPATH, not -bootclasspath: same reason as
  # bridge/build.sh — modern javac rejects -bootclasspath with a
  # release >= 9.
  (cd "$HERE" && javac -source 11 -target 11 -nowarn -Xlint:-options \
    -classpath "$platform" -d "$OUT/classes" @"$OUT/sources.txt")
  rm -f "$OUT/sources.txt"
  # The classes go to d8 as one jar rather than as a word-split list of
  # paths, for the same space-in-a-directory reason.
  (cd "$OUT/classes" && zip -qr "$OUT/classes.jar" .)
  "$bt/d8" --min-api 31 --lib "$platform" --output "$OUT/dex" "$OUT/classes.jar"
  [ -f "$OUT/dex/classes.dex" ] || { echo "d8 produced no classes.dex" >&2; exit 1; }
  (cd "$OUT/dex" && zip -q "$JAR" classes.dex)
  echo "built: $JAR"
}

build_remote() {
  echo "→ no Android SDK here; building on $BUILD_HOST" >&2
  local remote
  remote="$(ssh -o BatchMode=yes "$BUILD_HOST" \
    'mktemp -d "${TMPDIR:-/tmp}/parallel-root-vdisplay.XXXXXX"')"
  [ -n "$remote" ] || { echo "could not make a build directory on $BUILD_HOST" >&2; exit 1; }
  # The far side runs this script with `bash`, so no exec bit has to survive
  # the trip. COPYFILE_DISABLE because macOS tar otherwise packs extended
  # attributes as ._Main.java beside Main.java, and on a Linux build host
  # javac would be handed those as sources.
  COPYFILE_DISABLE=1 tar -C "$HERE" -cf - src build.sh \
    | ssh -o BatchMode=yes "$BUILD_HOST" "tar -C '$remote' -xf -"
  rm -rf "$OUT"; mkdir -p "$OUT"
  # One round trip builds, returns the jar on stdout and cleans up, whether or
  # not the build worked. VD_BUILD_HOST is cleared there: a build host with no
  # SDK must fail, not pass the job along again.
  if ! ssh -o BatchMode=yes "$BUILD_HOST" \
      "cd '$remote' && VD_BUILD_HOST= ANDROID_API=$API bash build.sh >&2 \
       && cat build/parallel-root-vdisplay.jar; rc=\$?; cd / && rm -rf '$remote'; exit \$rc" \
      > "$JAR.part"; then
    rm -f "$JAR.part"
    echo "the build on $BUILD_HOST failed" >&2
    exit 1
  fi
  mv "$JAR.part" "$JAR"
  [ -s "$JAR" ] || { echo "remote build produced nothing" >&2; exit 1; }
  echo "built: $JAR (on $BUILD_HOST)"
}

if have_sdk; then
  build_here
elif [ -n "$BUILD_HOST" ]; then
  build_remote
else
  if [ -n "$SDK" ]; then
    echo "no usable Android SDK at $SDK (it needs build-tools, and javac on PATH)" >&2
  else
    echo "no Android SDK found: set ANDROID_HOME" >&2
  fi
  echo "or set VD_BUILD_HOST to an ssh host that has one, to build there" >&2
  exit 1
fi

[ "$INSTALL" = 1 ] || exit 0

# ------------------------------------------------------------------ install
# The same two-hop the APK takes, for the same reason: ssh lands as the TERMUX
# app, which cannot write /data/local/tmp; `phone sh` is shell, which can.
# /sdcard is the one place both identities can reach.
echo "→ copying to $DEVICE (as the app)"
ssh -o BatchMode=yes "$DEVICE" "mkdir -p $STAGE_DIR && cat > $STAGE_SD" < "$JAR"

# Into place by rename, not by copying over the old file: a `display create`
# that starts while this runs then loads the old jar or the new one, never
# half of the new one.
echo "→ staging where app_process can load it (as shell)"
"$PHONE_BIN" --device "$DEVICE" sh \
  "cp $STAGE_SD $STAGE.new && chmod 644 $STAGE.new && mv -f $STAGE.new $STAGE && rm -f $STAGE_SD" >/dev/null

"$PHONE_BIN" --device "$DEVICE" sh "ls -l $STAGE"
echo "staged: $STAGE"
