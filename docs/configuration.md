# Configuration

`phone` is configured through environment variables, all named `PHONE_*`,
and an optional config file holding the same variables. Command-line flags
take precedence over both.

## The config file

The file is `$PHONE_CONFIG` if set, otherwise
`${XDG_CONFIG_HOME:-~/.config}/parallel-root/config`. `phone` reads it at
startup, before any flags, using these rules:

- one `KEY=VALUE` per line, with an optional `export ` prefix. There is no
  space between the key and the `=`; whitespace around the value is
  trimmed;
- blank lines and lines starting with `#` are ignored. A comment must be a
  whole line: a `#` after a value is part of the value;
- one layer of matching single or double quotes around the value is
  removed. Nothing else is interpreted: no `$VAR` expansion, no escapes, no
  command substitution;
- only keys starting with `PHONE_` are used. `PHONE_CONFIG` itself is not
  one of them, since the file has already been chosen by the time it is
  read;
- **a variable already in the environment wins**, even when its value is
  empty, so the file only supplies defaults;
- a missing file is silently skipped. An unreadable one produces a warning,
  and `phone` continues.

Everything the file gets wrong (a key that is not a `PHONE_` setting, a
`PHONE_CONFIG` line, a line that is not `KEY=VALUE`, such as `KEY = VALUE`)
is reported in one warning line on stderr, by key and line number, never by
value, and the rest of the file still applies.

`PHONE_CONFIG=/dev/null` turns the file off. The test suites point it at a
temporary path that does not exist, to the same effect, so they never read
a real one.

An example for a controller:

```sh
# ~/.config/parallel-root/config
PHONE_DEVICE=my-phone
PHONE_ACTOR=alice-laptop
export PHONE_ROUTER="claude -p"
```

The phone has its own config file, read by its own copy of `phone`. When a
controller runs a verb on the phone, the phone's copy reads the phone's
file. A controller's `PHONE_DEVICE` never travels with the hop. The hop does
pin where the verb lands: it runs with `PHONE_DEVICE`, `PHONE_LANE`,
`PHONE_SHELL_SOCK` and `PHONE_DISPLAY` set empty (a display other than 0
travels as `--display`, and starting a lane's daemon sets `PHONE_LANE` to
that lane), so those four in the phone's file apply to verbs run on the
phone itself, never to a controller's. Everything else in the
phone's file, `PHONE_NO_LEASE` and `PHONE_NO_DISPLAY_GUARD` included, applies
to both.

The build scripts under `android/` are bash and do not read this file. Set
their variables in the environment.

## Global flags

These are read before the verb, wherever they appear on the command line:

| flag | effect |
|---|---|
| `--device <ssh-host>` | drive that phone from here; overrides `PHONE_DEVICE` |
| `--display <id>` | address that display; overrides `PHONE_DISPLAY` |
| `--print-link` | print the ssh command that forwards the device's shell socket, and exit |
| `--print-plan` | print how the verb would run (locally against the forward, or on the device over ssh), and exit |

## Variables read by `phone`

### Which phone, which screen, who

| variable | default | effect |
|---|---|---|
| `PHONE_DEVICE` | unset: run on this device | The ssh host alias of the phone to drive. It must match `[a-z0-9][a-z0-9._-]{0,62}` (at most 63 characters), so use a short lowercase alias from `~/.ssh/config`. The build scripts' `install` step also uses it, and there it is required. |
| `PHONE_DISPLAY` | `0` | The display that screen verbs address when `--display` is not given. `0` is the built-in screen. |
| `PHONE_ACTOR` | `anon` | Who is acting. Used as the lease holder when `lease` has no `--as`, and recorded in every ledger line. Carried across the ssh hop explicitly, since ssh does not forward it. |
| `PHONE_LANE` | empty: the shared default lane | Gives this driver its own shell daemon (`phone-shell-<lane>.sock`, and a matching forwarded socket on a controller). A short lowercase name: `[a-z0-9][a-z0-9_-]{0,30}`. Leases are per daemon, so drivers in different lanes do not see each other's leases. |

### Files

| variable | default | effect |
|---|---|---|
| `PHONE_CONFIG` | `${XDG_CONFIG_HOME:-~/.config}/parallel-root/config` | The config file. `/dev/null` turns it off. |
| `PHONE_LEDGER` | `~/.local/state/parallel-root/actions.jsonl` | The action ledger. Created with mode 0600. |
| `PHONE_RISH` | `~/rish` | The `rish` launcher exported from Shizuku. |
| `PHONE_SHELL_SOCK` | on the phone: `$PREFIX/tmp/phone-shell.sock` (laned); on a controller with `--device`: `$TMPDIR/phone-<device>.sock` (laned) | The shell daemon's socket. `--device` sets this itself, so you rarely need to. |

### Remote driving

| variable | default | effect |
|---|---|---|
| `PHONE_REMOTE_BIN` | `phone` | The program run on the phone over ssh: termux verbs, binary verbs, the remote half of `log`, and starting a lane's daemon. Set it if `phone` is not on the PATH of a non-interactive ssh session on the phone. Use an absolute path, for example `/data/data/com.termux/files/home/.local/bin/phone`; the value is quoted, so `~` is not expanded. |
| `PHONE_BRIDGE_PORT` | `8137` | The controller's end of the bridge port forward. The phone's end is always 8137. Give each driver on one controller its own port. |
| `PHONE_BRIDGE_TOKEN` | unset: read from the phone | The bridge token (hex, 16 or more characters). When set, `phone` uses it instead of reading `/sdcard/Android/data/parallelroot.bridge/files/token` through the shell. |

### `ask`

| variable | default | effect |
|---|---|---|
| `PHONE_ROUTER` | unset: no router tier | The router command for `ask` when `--router` is not given. It is split with `shlex`, and the brief is appended as one final argument. For example, `codex exec --skip-git-repo-check` or `claude -p`. |

### The watchdog

| variable | default | effect |
|---|---|---|
| `PHONE_WATCHDOG_JOB_ID` | `7137` | The JobScheduler job id that `watchdog --install` registers. Change it if another Termux job already uses 7137. |
| `PHONE_ADB_ADDR` | unset: the `adb` step is skipped | `host:port` of the phone's own wireless debugging endpoint. When set, each watchdog run reconnects adb to it (`adb connect $PHONE_ADB_ADDR`) if no device is attached. Only needed if you use adb as a fallback shell tier. |

### The shell daemon

| variable | default | effect |
|---|---|---|
| `PHONE_SHELL_DEADLINE` | `75` (seconds) | How long the daemon lets one command run before killing its shell. The next command gets a fresh shell. |
| `PHONE_SHELLD_TICK` | `30` (seconds) | How often the daemon checks whether it should still be running. |
| `PHONE_SHELLD_IDLE` | `3600` (seconds) | How long the daemon may go unused before it exits. `0`, or anything below it, means it never exits on its own. |

Every verb reads these three, so a value that is not a usable number of
seconds (not a number, or zero or negative for the deadline or the tick)
gets one warning on stderr and the default is used instead.

### Overrides

Each of these exists so that deliberately bypassing a safeguard is a named
switch, not a workaround someone invents. Any non-empty value turns it on.

| variable | default | effect |
|---|---|---|
| `PHONE_NO_LEASE` | unset | Skip the lease check before mutating verbs. |
| `PHONE_NO_DISPLAY_GUARD` | unset | Let `open` put an app on a display while it is open on another. Doing so moves the app's task away from whoever was driving it. |

### Tests

| variable | default | effect |
|---|---|---|
| `PHONE_TEST_DEVICE` | unset: the device half is skipped | The ssh host of a phone for the device half of `tests/test-displays.sh`. That half releases only the displays it created and never changes display 0. |
| `PHONE_TEST_INTRUSIVE` | unset | With `PHONE_TEST_DEVICE`, also run the two steps that put something on the person's screen: `display move --to 0` and `display create --visible`. |
| `PHONE_NO_DEVICE` | unset | Behave as if no device tools exist (no termux-api, rish or adb). Used by the off-device suites. |
| `PHONE_SHELL_ARGV` | unset: `rish -c sh` | The program the shell daemon keeps alive. The suites point it at a plain `sh` so that the daemon protocol can be tested with no phone. |

## Variables from the platform

| variable | used for |
|---|---|
| `TMPDIR` | On a controller, where forwarded sockets go (`/tmp` if unset). On the phone, it must be `$PREFIX/tmp`, because an app uid cannot write `/tmp` on Android. The checked-read temp file also uses it, falling back to `/data/local/tmp`. |
| `PREFIX` | Termux's prefix. The phone-side daemon socket is `$PREFIX/tmp/phone-shell.sock`. |
| `XDG_CONFIG_HOME` | Where the config file is looked for. |
| `RISH_APPLICATION_ID` | Passed to `rish`. Set to `com.termux` when unset. |

## Variables read by the build scripts

`android/vdisplay/build.sh` and `android/bridge/build.sh`:

| variable | default | effect |
|---|---|---|
| `ANDROID_HOME` | then `ANDROID_SDK_ROOT`, then the usual install locations | The Android SDK. It needs `build-tools` (d8; the bridge also needs aapt2, zipalign and apksigner) and `platforms/android-<API>`. |
| `ANDROID_SDK_ROOT` | | Used when `ANDROID_HOME` is unset. |
| `ANDROID_API` | `36` | The platform to compile against (`platforms/android-<API>/android.jar`), and the bridge's target SDK. |
| `VD_BUILD_HOST` | unset: build locally | Display holder only. An ssh host to build on when there is no SDK here. The sources are sent there and the jar comes back. |
| `PHONE_DEVICE` | none | Required by `install`: the phone to stage onto. |
| `PHONE_BIN` | `bin/phone` in this checkout | The `phone` CLI that `install` uses for the steps that run at shell uid. |

## Variables read by the install scripts

`install/termux-setup.sh` uses `PREFIX` and `HOME` and refuses to run
outside Termux. `install/install-controller.sh` uses `HOME`, and `--prefix
DIR` replaces its default target directory, `~/.local/bin`. Neither reads
`PHONE_*`.
