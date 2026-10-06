# parallel-root — design

Status: v0.1, the first open-source cut. This document is the contract the
code, the skills, the tests and the docs are held to.

## What it is

parallel-root turns an ordinary Android phone into a surface that AI agents
can drive — **several of them at once** — without rooting it.

- One CLI, `phone`, that runs on the phone (in Termux) and on any machine
  that can ssh to it. Every verb works identically in both places.
- Shell-uid power through Shizuku: reading system state, firing intents,
  dumping and touching the screen. Root-equivalent for this purpose, with no
  root and no unlocked bootloader — hence the name.
- **Parallel agents.** Each agent can take a trusted virtual display of its
  own: a real second screen with its own focus and input, invisible to the
  person holding the phone. A per-display lease keeps two agents off one
  screen, shell lanes keep them out of each other's command queue, and a
  one-app-one-display guard stops two agents sharing one app's session.
- Skills that teach an agent the method: ask the device before assuming,
  climb down the route ladder (state → intent → screen), verify by
  observation, never guess a coordinate.
- An action ledger: every act, and every read of personal data, recorded with
  who, what, how long and whether it worked.

Who it is for: anyone with an Android phone and a coding agent (Claude Code,
Codex, or anything that can run a shell command) who wants the agent to use
the phone the way a careful person would.

## Success criteria

1. A stranger can go from a stock phone to `phone --device <phone>
   capabilities` answering from their laptop by following `docs/setup.md`.
2. Two agents can each `phone display create`, drive a different app on
   their own display, and release it, while the built-in screen stays
   untouched.
3. `bash tests/run-all.sh` passes on Linux and macOS with no phone attached.
4. Nothing in the repository identifies any particular person, device,
   network or account. Examples use placeholders (`my-phone`, `alice`,
   `<phone-ip>`), never a real address, and test fixtures are synthetic.

## Non-goals (v0.1)

- No root, no Magisk, no custom ROM.
- No Gradle and no Android Studio: the two Android pieces build with the SDK
  command-line tools in a handful of invocations.
- No integrations built on top of the CLI (voice front ends, messaging
  bridges, app automations) and no per-app skills beyond the method. The
  `ask` router hook (below) is the seam for those.
- No cloud service. Everything runs on the phone and on machines you own.

## Layout

```
bin/phone                 the CLI — one file, python3 stdlib only
android/vdisplay/         the display holder: a dex run by app_process as shell
android/bridge/           optional app: notification listener + loopback bridge
plugin/                   the agent plugin (Claude Code and Codex manifests)
  skills/phone/SKILL.md   the method
  skills/phone/map.md     dated findings on a reference device (the territory)
  skills/screens/SKILL.md more than one agent on one phone
.claude-plugin/marketplace.json   Claude Code marketplace entry for plugin/
.agents/plugins/marketplace.json  Codex marketplace entry for plugin/
install/termux-setup.sh   on-device bootstrap, run inside Termux
install/install-controller.sh     put `phone` on PATH on a controller
tests/                    off-device suites; the device half is opt-in
docs/                     setup, architecture, displays, configuration, this file
.github/workflows/ci.yml  tests on Linux + macOS; builds the jar and the APK
```

`bin/phone` stays ONE file on purpose: the phone runs a single deployed copy,
not a checkout, and copying one file is the whole install.

## Names

| thing | value |
|---|---|
| CLI | `phone` (`bin/phone`) |
| environment prefix | `PHONE_*` |
| config file | `$PHONE_CONFIG`, else `${XDG_CONFIG_HOME:-~/.config}/parallel-root/config` |
| ledger | `$PHONE_LEDGER`, else `~/.local/state/parallel-root/actions.jsonl` |
| shell daemon socket (device) | `$PREFIX/tmp/phone-shell.sock` (`phone-shell-<lane>.sock` per lane) |
| forwarded socket (controller) | `$TMPDIR/phone-<device>.sock` (laned the same way) |
| display holder Java package | `parallelroot.vdisplay` (`Main`, `Client`, `FakeContext`) |
| display holder jar on device | `/data/local/tmp/parallel-root-vdisplay.jar` |
| display holder name prefix | `pr-vd-` (`pr-vd-1`, `pr-vd-2`, …) |
| bridge application id | `parallelroot.bridge` |
| bridge port (device loopback) | `8137` |
| bridge token | `/sdcard/Android/data/parallelroot.bridge/files/token` |
| watchdog script | `~/.local/bin/parallel-root-watchdog.sh`, JobScheduler job id `$PHONE_WATCHDOG_JOB_ID` (default `7137`) |
| watchdog log | `~/.local/state/parallel-root/watchdog.log` |
| plugin name | `parallel-root`, skills `phone` and `screens` |

The shell daemon's socket name is fixed rather than derived from the install,
so that any two tools that speak its protocol share one arbiter — and
therefore one set of leases — per phone.

## The CLI contract

The comments in `bin/phone` carry measurements made on a reference device
and the reasons behind each decision. **Keep them.** Edit a comment only to
keep it true after a change.

### Verbs

By kind:

- state: `notifs`, `media`, `cal`, `contacts`, `battery`, `foreground`,
  `apps`, `capabilities`, `where`, `clip`, `log`, `sh`
- intent: `open`, `play`, `msg`, `reply` (needs the bridge app)
- screen: `ui`, `look`, `find`, `tap`, `type`, `key`, `scroll`, `swipe`,
  `scan`, `screen`, `photo`, `torch`
- device: `say`, `listen`, `notify`
- parallelism and plumbing: `shelld`, `lease`, `display`, `watchdog`
- `ask` — below

### `ask`, the router hook

`ask` answers a question through a tier ladder without a microphone:

1. **fast** — built-in regex handlers answer from device verbs (battery,
   time, date, what is playing, notifications, calendar).
2. **router** — optional. `--router CMD` or `$PHONE_ROUTER`. `CMD` is split
   with `shlex` and the brief (a short "answer out loud for someone
   listening … reply ESCALATE if …" prompt, naming this CLI's own path and
   the read-only verbs it may run) is appended as ONE final argument. The
   answer is the last non-empty stdout line that does not start with `[` and
   does not mention "tokens used".
3. otherwise **ESCALATE**.

Exit codes: 0 answered (stdout = answer, stderr = `tier: …`); 4 = escalate
(no tier could answer, or the router answered `ESCALATE`); 5 = the router
itself failed to run. There is no default router; with none configured, a
question the fast tier declines exits 4. `--no-fast` skips tier 1. Docs show
how to point `--router` at Codex or Claude Code in one line each. Answers
from either tier, and a router's ESCALATE, are recorded in the ledger as
reads; a router run that fails is recorded as a failure.

### `say` and `listen`

termux-api only (`termux-tts-speak`, `termux-speech-to-text`). `say` records
`spoken`, or a failure carrying the tool's exit status.

### `shelld`

`shelld --start` reuses a live daemon, busy or idle, and never binds a new
one over it: the leases live only in the daemon's memory, so replacing a
busy one would free every display it holds. A daemon that is mid-command
still completes a connect, which is how busy is told from dead. `--start`
exits 0 once a daemon answers `true` (or is busy answering someone else), 4
when the daemon answers but its shell does not (it is left running, leases
and all), and 3 when there is no shell to keep at all, in which case the
daemon leaves no socket or pidfile behind. `--stop` signals only a pid that
is still a shelld, never whatever process inherited a stale pidfile's
number.

### `watchdog`

Steps, in order; each prints its name, a failing step is marked `!`, and a
step that does not run is printed as `<name>-`:

| step | command | when |
|---|---|---|
| wakelock | `termux-wake-lock` | always |
| sshd | start `sshd` if it is not running | always |
| shizuku | check `rish -c true` answers; raise/clear the tier notification | always |
| shelld | `phone shelld --start` on the default lane; passes when a daemon answers or is busy, and never replaces a live one | only when the shizuku step passed; otherwise printed as `shelld-` |
| adb | `adb connect $PHONE_ADB_ADDR` if no device is attached | only when `PHONE_ADB_ADDR` is set; otherwise printed as `adb-` (skipped) |

A pass in which a step failed writes one ledger row, recorded as a failure
that names the failed steps; a clean pass writes nothing.

`watchdog --install` writes the script above and registers it with
`termux-job-scheduler --job-id $PHONE_WATCHDOG_JOB_ID --persisted true`.

### Remote driving

`--device <ssh-host>` drives that phone. The binary invoked on the far side
is `$PHONE_REMOTE_BIN` (default `phone`) in every place the CLI runs itself
remotely: termux verbs, binary verbs, the remote half of `log`, and starting a
lane's daemon.

The hop pins where the verb lands. The far side runs with `PHONE_DEVICE`,
`PHONE_LANE`, `PHONE_SHELL_SOCK` and `PHONE_DISPLAY` set empty (starting a
lane's daemon sets `PHONE_LANE` to that lane instead), and a display other
than 0 travels as `--display N`, so the phone's own config file can neither
send the verb onward nor point its lease check or its screen anywhere else.
`PHONE_ACTOR` travels when it is set.
`PHONE_NO_LEASE` and `PHONE_NO_DISPLAY_GUARD` are left to the phone: they
are named switches, and one set in the phone's file applies to every driver
of that phone.

### Configuration

At startup, before global flags are read, `phone` loads the config file if
it exists: `KEY=VALUE` lines, `#` comments and blank lines ignored, one layer
of matching single or double quotes stripped, `export ` prefix allowed. Only
keys that start with `PHONE_` are honoured; anything else is warned about
once on stderr and ignored. A value already present in the environment always
wins. A missing file is silent; an unreadable one is a warning, never an
exit. `PHONE_CONFIG=/dev/null` disables it (the test suites get the same
effect by pointing it at a temporary path that does not exist).

The shell daemon's timings, `PHONE_SHELL_DEADLINE`, `PHONE_SHELLD_TICK` and
`PHONE_SHELLD_IDLE`, are read by every verb as seconds. A value that is not
a positive finite number is warned about once on stderr and replaced by its
default, never an exit; for `PHONE_SHELLD_IDLE`, zero or less means the
daemon never exits on its own.

### Everything else

Exit codes: 1 the verb ran and the answer is no (nothing matched, nothing was
heard, nothing can be replied to) or an act could not be confirmed, 2 usage,
3 no device / no shell tier, 4 failed or not found (including an act that was
watched and did not happen), 5 refused (held lease, one-app-one-display,
unverifiable read). A verb `phone` does not have fails with `phone: unknown
verb …`, exit 2, before any ssh hop or forward. Python 3.8+ stdlib only. Messages name roles (`the controller`,
`the phone`) or placeholders, never a machine.

## Android

### vdisplay (required for `display create`)

A dex, not an APK: `app_process` runs it as shell (uid 2000), which holds
`ADD_TRUSTED_DISPLAY`, so the display it creates is TRUSTED — own focus, own
IME, system decorations. It holds the display for as long as it lives and
answers `info`, `cap <path>` and `bye` on an abstract-namespace socket named
after the display. `build.sh` compiles with `javac` against
`platforms/android-<API>/android.jar` and `d8`; `build.sh install` copies the
jar to the device in two hops (ssh as the Termux app → `/sdcard`, then
`phone sh` as shell → `/data/local/tmp`). The SDK is found through
`$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, or the usual install locations; a build
on another machine is opt-in through `$VD_BUILD_HOST`. No default device and
no default build host.

### bridge (optional, for `reply`)

Shell can read every notification and every reply action, but it cannot fire
one: a PendingIntent is a live Binder token that only a bound
NotificationListenerService receives. The bridge app is that listener plus a
line-of-JSON server on device loopback, reached through the same ssh forward
idiom as the shell daemon, gated by a token only shell can read.

The app is the listener and the bridge server, with ops `ping`, `list`,
`reply`, `action`, `dismiss`, and nothing else: no activity, no UI, no
resources. The manifest asks only for INTERNET (the loopback socket) and
declares the listener service. `ping` answers whether or not the listener is
bound, and says which (`"bound"`, true or false right now); the other four
refuse while it is not. No launcher activity is needed; the listener is
enabled with `cmd notification allow_listener parallelroot.bridge/.Listener`,
and `build.sh install` also allows the app's restricted settings (`cmd appops
set parallelroot.bridge ACCESS_RESTRICTED_SETTINGS allow`, best effort), so
that the grant can later be switched off and on again from Settings.
`build.sh` uses aapt2, javac, d8, zipalign and apksigner, and generates a
throwaway debug keystore on first run (never committed).

## The skills

`plugin/skills/phone/SKILL.md` is the method; `map.md` beside it is the
territory — dated findings, each established by trying it on a reference
device (a Pixel 10, Android 16, SDK 36). Entries that only make sense for one
person's phone, accounts, contacts or apps do not belong in the public map;
neither does anything that quotes real notification, message, note or
location content. The map's own rule stands: the device is more current than
any document, so `phone capabilities` comes first.

`screens` teaches the parallel model: most work needs no display; take one,
work, give it back; one app, one display; leases per display; lanes for shell
throughput; what a display does not multiply (microphone, speaker,
notification shade, the person); FLAG_SECURE renders black off the built-in
screen.

Skills never teach a verb the CLI does not have — `tests/check-skill-verbs.py`
enforces it.

## Tests

- `tests/test-phone.sh` — parsing, routing, the ledger, the lease, the shell
  daemon protocol, remote-hop argv construction, config loading, the router
  hook, unknown verbs. Runs against fixtures and a local `sh` standing in for
  the device shell.
- `tests/test-displays.sh` — tree merging, the device-side filter, flag
  threading, per-display leases, lanes. Its device half runs only with
  `PHONE_TEST_DEVICE=<ssh-host>`, releases only the displays it created, and
  never touches display 0 beyond reading it. The two steps that would put
  something on the person's own screen — `display move --to 0` and `display
  create --visible` — run only with `PHONE_TEST_INTRUSIVE=1`.
- `tests/check-skill-verbs.py` — the skills and the CLI agree.
- `tests/run-all.sh` — all three; non-zero if any fails.

Every fixture is synthetic: invented names, invented messages, invented
packages where a real one is not the point. The suites set `PHONE_LEDGER` and
`PHONE_CONFIG` to temporary paths so they never read or write a real one.

## Safety model

Documented in `SECURITY.md`. In short: whoever can ssh into Termux can run
commands as shell on the phone — treat that key like an adb key. sshd should
accept keys only and be reachable only over a private network. The bridge
token separates "has shell" from "is any app on the phone". The ledger is the
accountability record and is written with mode 0600. The skills require an
agent to confirm consequential outbound actions with the person first, never
to read out one-time codes, and never to touch developer options, wireless
debugging, Shizuku, the screen lock or accounts.
