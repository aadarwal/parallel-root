# Setup

This takes a stock Android phone to `phone --device my-phone capabilities`
answering from a laptop. It takes about half an hour. Most of that is
installing apps and enabling things on the phone, and the steps that tend to
fail are noted where they come up.

You need:

- an Android phone running Android 11 or later. The reference device is a
  Pixel 10 on Android 16.
- a controller: any macOS or Linux machine with Python 3.8+ and OpenSSH.
- a private network that both can reach: Tailscale on both, or the same LAN.

Nothing needs root, an unlocked bootloader or a USB cable.

## 1. Termux and Termux:API

Install **Termux** and **Termux:API** from
[F-Droid](https://f-droid.org/packages/com.termux/) or from the
[Termux GitHub releases](https://github.com/termux/termux-app/releases).

- **Do not use the Play Store builds.** They are a different line of
  releases, and the package repositories behind them have diverged.
- **Install both apps from the same source.** Android requires the two to
  share a signing key. If one comes from F-Droid and the other from GitHub,
  every `termux-*` command hangs or fails, even though both apps look
  installed.

Open Termux once so it finishes bootstrapping, then:

```sh
pkg update
pkg install -y python openssh termux-api git
```

`termux-api` is the command-line half. The Termux:API app is the other half,
and both are needed. Check that they work with `termux-battery-status`: it
should print JSON within a second or two. If it hangs, the signing keys do
not match (see above).

Allow notifications for Termux. The watchdog's "shell tier down" notice uses
them.

## 2. sshd: key only, port 8022

Termux's `sshd` listens on port 8022 and runs as the Termux app. User names
are ignored: any name logs in as the app.

Put your controller's public key in `~/.ssh/authorized_keys` on the phone.
There are two ways to get it there:

- **Through the clipboard.** Copy the contents of `~/.ssh/id_ed25519.pub` on
  the controller to the phone's clipboard by any means you trust, then in
  Termux:

  ```sh
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  termux-clipboard-get >> ~/.ssh/authorized_keys
  chmod 600 ~/.ssh/authorized_keys
  ```

- **With a password, briefly.** Run `passwd` in Termux, then `sshd`. On the
  controller, run `ssh-copy-id -p 8022 <phone-ip-or-name>`, and then turn
  password logins off.

Then make sshd accept keys only. In `$PREFIX/etc/ssh/sshd_config`:

```
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Restart sshd with `pkill sshd; sshd`. `install/termux-setup.sh` (step 5)
starts sshd and reports whether password logins are still enabled.

## 3. A private network

sshd on this phone gives shell-uid access to the device (see
[SECURITY.md](../SECURITY.md)). **Never expose port 8022 to the internet.**
Use one of these:

- **Tailscale**: install it on the phone and on the controller, signed in to
  the same tailnet, and use the phone's tailnet name or address as
  `HostName`. Tailscale ACLs can limit which machines may reach port 8022.
- **A LAN**: use the phone's address on the local network. It changes when
  the phone joins a different network.

## 4. Shizuku, and rish in the Termux home

Shizuku runs a service at the shell uid that apps can call into. On Android
11 and later it starts from **wireless debugging**, with no computer
involved.

1. Install [Shizuku](https://shizuku.rikka.app/) (Play Store or its GitHub
   releases).
2. Enable Developer options (Settings → About phone → tap Build number seven
   times), then turn on **Wireless debugging**. It needs Wi-Fi.
3. In Shizuku, choose **Start via Wireless debugging** and pair it using the
   code from the wireless debugging screen. Shizuku should then say it is
   running.
4. In Shizuku, open **Use Shizuku in terminal apps** and **Export files**
   into a folder on shared storage. That writes two files, `rish` and
   `rish_shizuku.dex`.
5. Copy both into the Termux home:

   ```sh
   termux-setup-storage            # grant Termux access to shared storage, once
   cp ~/storage/shared/<folder>/rish ~/storage/shared/<folder>/rish_shizuku.dex ~/
   chmod 700 ~/rish
   chmod 400 ~/rish_shizuku.dex
   ```

6. Test it:

   ```sh
   RISH_APPLICATION_ID=com.termux ~/rish -c id
   ```

   The first call makes Shizuku ask whether Termux may use it. Allow it. The
   output should include `uid=2000(shell)`.

`rish` identifies its caller to Shizuku by application id, and for Termux
that is `com.termux`. `phone` sets `RISH_APPLICATION_ID=com.termux` when it
is unset. The setup script exports it in `~/.profile` for interactive use.

**What can fail here.** Shizuku does not survive a reboot on an unrooted
phone. After every restart, open Shizuku and start it again through wireless
debugging. Until then, `phone` loses its shell tier and the screen verbs
exit 3. The watchdog (step 6) notices this and posts a notification. Android
also turns wireless debugging off after a network change. That stops
Shizuku from being *started*, but a Shizuku that is already running keeps
working.

### TMPDIR

An app uid cannot write `/tmp` on Android, even when the directory is mode
0777. SELinux blocks it, not Unix permissions. Termux's own temp directory is
`$PREFIX/tmp`, so `TMPDIR` has to point there in every shell that runs
`phone`. Without it, tools that write a temp file fail in ways that look
unrelated. The setup script adds the export to `~/.profile`.

## 5. Run the setup script

From a clone of this repository on the phone:

```sh
git clone https://github.com/<you>/parallel-root
bash parallel-root/install/termux-setup.sh
```

The script is idempotent and never deletes anything. It:

- installs `python`, `openssh` and `termux-api` if they are missing;
- copies `bin/phone` to `~/.local/bin/phone`, links it into `$PREFIX/bin` so
  that commands run over ssh find it, and keeps the previous copy as
  `phone.prev` when it changes;
- adds `~/.local/bin` to `PATH` and exports `TMPDIR` and
  `RISH_APPLICATION_ID` in `~/.profile`, once, under a marker comment;
- starts `sshd` and prints the port and how to add a key;
- checks for `~/rish` and `~/rish_shizuku.dex` and explains how to export
  them if they are missing;
- runs `phone shelld --start` if `rish` answers;
- with `--watchdog`, registers the watchdog (step 6).

To install a `phone` from somewhere else, pass its path:
`bash termux-setup.sh /path/to/phone`.

Open a new Termux session, or run `. ~/.profile`, then:

```sh
phone shelld --start      # the persistent shell; prints where it listens
phone capabilities        # what this phone can do, asked of the phone
```

`capabilities` reports each probe as yes, no, or "could not check". "Could
not check" is not the same as no, and is usually the shell tier being down.

## 6. The watchdog

Android reaps idle Termux processes. The watchdog is a script registered with
Android's JobScheduler through `termux-job-scheduler`. The OS runs it every
15 minutes, and the registration survives reboots.

```sh
phone watchdog --install          # or: termux-setup.sh --watchdog
phone watchdog --print-only       # show the steps without running them
phone watchdog                    # run the steps once, now
```

Each run holds the Termux wake lock, starts sshd if it is not running, checks
that `rish` still answers (and raises or clears a "shell tier down"
notification), and, when it does, makes sure the shell daemon is running on
the default lane. A daemon that is already up is reused, even in the middle
of someone's command, so the leases it holds survive the run. If
`PHONE_ADB_ADDR` is set, it also reconnects adb. The script is
`~/.local/bin/parallel-root-watchdog.sh`, and it logs to
`~/.local/state/parallel-root/watchdog.log`.

Some vendors kill background jobs aggressively. If the watchdog stops
running, set Termux's battery usage to "Unrestricted" in the app's Android
settings.

## 7. Reach the phone from a controller

On the controller, add a host to `~/.ssh/config`:

```
Host my-phone
    HostName <phone-ip-or-name>
    Port 8022
    IdentityFile ~/.ssh/id_ed25519
```

The alias is what `--device` takes. It must be lowercase letters, digits,
`.`, `_` or `-`, start with a letter or digit, and be at most 63 characters
(`[a-z0-9][a-z0-9._-]{0,62}`). Check that it works with `ssh my-phone true`.
`phone` uses `BatchMode`, so it cannot answer a password or host-key prompt.
Connect once by hand first so the host key is recorded.

Install the CLI:

```sh
git clone https://github.com/<you>/parallel-root
bash parallel-root/install/install-controller.sh     # or --prefix DIR
```

This symlinks `bin/phone` into `~/.local/bin`, so a `git pull` updates it.
Then:

```sh
phone --device my-phone capabilities
```

The first call forwards the phone's shell daemon socket to
`$TMPDIR/phone-my-phone.sock`, and later calls reuse it. To avoid typing
`--device` every time, set `PHONE_DEVICE=my-phone`, in the environment or in
the config file ([configuration.md](configuration.md)).

Keep the phone's copy of `phone` in step with the controller's. Verbs that
run on the phone (`notifs`, `say`, `screen` and others) use the phone's copy,
so a stale one answers `unknown verb`. Re-run `termux-setup.sh` after
pulling.

## 8. The display holder

`phone display create` needs the holder jar at
`/data/local/tmp/parallel-root-vdisplay.jar` on the phone.

**Building it** needs a JDK (11 or later, for `javac`), `zip`, and the
Android SDK command-line tools with a 36.x build-tools and the platform:

```sh
sdkmanager "build-tools;36.0.0" "platforms;android-36"
export ANDROID_HOME=/path/to/android-sdk
android/vdisplay/build.sh                          # build only
PHONE_DEVICE=my-phone android/vdisplay/build.sh install   # build and stage
```

The build writes `android/vdisplay/build/parallel-root-vdisplay.jar`.
`install` copies the jar in two hops. ssh lands as the Termux app, which can
write `/sdcard` but not `/data/local/tmp`. `phone sh` runs as shell, which
can read `/sdcard` and write `/data/local/tmp`. The runtime will not load a
dex from `/sdcard` itself. If this machine has no SDK but one you can ssh
to does, set `VD_BUILD_HOST=<ssh-host>` and the build runs there (the
display holder only; the bridge builds where you run it).

**Without an SDK**, download `parallel-root-vdisplay.jar` from the latest
GitHub release of this repository (each release carries the jar and the
bridge APK, built by CI from the tagged commit) and stage it by hand:

```sh
ssh my-phone 'mkdir -p /sdcard/Download && cat > /sdcard/Download/parallel-root-vdisplay.jar' \
  < parallel-root-vdisplay.jar
phone --device my-phone sh 'cp /sdcard/Download/parallel-root-vdisplay.jar /data/local/tmp/ &&
  chmod 644 /data/local/tmp/parallel-root-vdisplay.jar &&
  rm /sdcard/Download/parallel-root-vdisplay.jar'
```

Then:

```sh
d=$(phone --device my-phone display create)   # about 4 s; prints the id
phone --device my-phone display ls
phone --device my-phone --display "$d" open calculator
phone --device my-phone --display "$d" look
phone --device my-phone display rm "$d"
```

`open` takes a short name only when it matches exactly one installed
package, and refuses an ambiguous one (`settings`, for example, also
matches the settings provider). If `calculator` is not found on your phone,
pass a full package name from `phone --device my-phone sh 'pm list
packages'`.

## 9. The bridge app (optional)

`phone reply` answers a notification through its own reply action, without
opening the app. The shell uid can read every reply action but cannot fire
one, so this needs a small app holding a notification listener. Nothing else
needs it. The app needs Android 12 (SDK 31) or later; on an older phone `pm
install` refuses it with `INSTALL_FAILED_OLDER_SDK`, and everything except
`reply` works without it.

```sh
PHONE_DEVICE=my-phone android/bridge/build.sh install
```

It needs the same JDK and SDK as step 8, plus the JDK's `keytool` and the
build-tools' `aapt2`, `zipalign` and `apksigner`. The build writes
`android/bridge/build/parallel-root-bridge.apk`, signed with a throwaway
debug key that it generates on its first run as
`android/bridge/build/debug.keystore` (never committed). The key is kept
across rebuilds, because Android installs an update only when it is signed
by the same key as the copy already on the phone. Delete `build/` and the
next build has a new key, so uninstall the old copy first (below).

The install step stages the APK through `/sdcard` and `/data/local/tmp` the
same way as the jar, installs it with `pm install`, and enables the
listener:

```sh
phone --device my-phone sh 'cmd notification allow_listener parallelroot.bridge/.Listener'
```

**Without an SDK**, take the APK from the same release and do those steps by
hand:

```sh
ssh my-phone 'mkdir -p /sdcard/Download && cat > /sdcard/Download/parallel-root-bridge.apk' \
  < parallel-root-bridge.apk
phone --device my-phone sh 'cp /sdcard/Download/parallel-root-bridge.apk /data/local/tmp/ &&
  pm install -r /data/local/tmp/parallel-root-bridge.apk;
  rm -f /sdcard/Download/parallel-root-bridge.apk /data/local/tmp/parallel-root-bridge.apk'
phone --device my-phone sh 'cmd notification allow_listener parallelroot.bridge/.Listener'
```

Check it:

```sh
phone --device my-phone reply --list
```

A list of notification keys, or `(nothing on this phone can be replied to
right now)` (exit 1), both mean the bridge answered.

**What can fail here.** An APK from CI is signed with a key generated for
that run, so it will not install over one signed with a different key
(`INSTALL_FAILED_UPDATE_INCOMPATIBLE`). Uninstall the old one first:
`phone --device my-phone sh 'pm uninstall parallelroot.bridge'`. On Android 13 and later,
sideloaded apps hit "Restricted settings" when you enable notification
access from the Settings app. Enabling it with `cmd notification
allow_listener` as shell, as above, avoids that.

## Troubleshooting

| symptom | cause | fix |
|---|---|---|
| exit 3, `no device shell: shizuku is not answering` | Shizuku stopped, usually after a reboot | open Shizuku and start it through wireless debugging; then `phone shelld --start` |
| `forwarded my-phone but its shell never answered` | sshd is reachable but the shell daemon is not running on the phone | on the phone: `phone shelld --start` (the watchdog does this on every run in which Shizuku answers) |
| exit 4, `shelld on ... answers, but its shell does not` | Shizuku stopped while the daemon kept running | start Shizuku; the daemon's next command starts a fresh shell. `phone shelld --stop` replaces the daemon instead, and frees every lease it holds |
| exit 3, `shelld has no shell to keep` | there is no `rish` at `$PHONE_RISH` (default `~/rish`) | step 4. Without `rish` there is no shell daemon: verbs fall back to adb, and nothing holds leases |
| `Permission denied (publickey)` | the controller's key is not in the phone's `authorized_keys` | step 2 |
| `ssh: connect to host ... port 8022: Connection refused` | sshd is not running | `sshd` in Termux, or install the watchdog |
| `Host key verification failed` | `phone` uses `BatchMode`, so it cannot answer the first-connection prompt | run `ssh my-phone true` once by hand |
| `bad device name` | the ssh alias has upper-case letters or other characters | use a lowercase alias in `~/.ssh/config` |
| `no display holder on this phone` from `display create` | the jar is not staged | step 8 |
| `the holder did not come up` | the holder exited while starting; its own error is printed after the message | read that error. On Android older than 13 the shell may not hold `ADD_TRUSTED_DISPLAY`. |
| a screenshot or a display is black | the app sets `FLAG_SECURE`, which renders black on every display except the built-in one | nothing at this level fixes it, and root would not either; use the built-in screen, or report it as unreadable |
| `display N produced no frame` | a virtual display draws only when its content changes, and nothing has been launched there | open something on it first |
| `the phone is asleep, and agent displays sleep with it` from `look`, `ui` or `screen` | agent displays share the person's power group, so they stop drawing when the phone sleeps; apps on them are still resumed | wake the phone, or plug it in and keep it awake while it charges: `phone sh 'svc power stayon true'` (holds only while plugged in; `false` undoes it) |
| `unknown verb` for a verb the docs list | the phone's copy of `phone` is older than the controller's | re-run `termux-setup.sh` on the phone |
| `termux-*` commands hang | Termux and Termux:API come from different sources | reinstall both from the same source |
| exit 3, `the bridge app (parallelroot.bridge) is not reachable` | the bridge is not installed, or its listener is not enabled, so its server never started | step 9 |
| exit 4, `notification listener is not bound` | the listener's grant lapsed, or the system has not bound it yet | as shell: `cmd notification allow_listener parallelroot.bridge/.Listener`; if that does not help, turn the grant off and on, or reboot |
| `reply --list` prints `(nothing on this phone can be replied to right now)` | nothing is wrong: the bridge answered, and no current notification has a reply action | none |
| commands fail writing temporary files on the phone | `TMPDIR` is unset or points at `/tmp` | `. ~/.profile`, or `export TMPDIR=$PREFIX/tmp` |
