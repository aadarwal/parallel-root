# parallel-root

parallel-root lets your coding agents drive an ordinary Android phone, and
lets several of them do it at the same time, without rooting it. A single
CLI, `phone`, runs on the phone inside Termux and on any machine that can ssh
to it, and every verb behaves the same in both places. Shizuku supplies the
privilege: commands run at the shell uid, the same identity an `adb shell`
has. With it an agent can read system state, fire intents, dump the screen
and touch it. Each agent can also take a trusted virtual display of its own,
a second screen the person holding the phone never sees, so two agents can
work in two apps without getting in each other's way or the person's.

## What you get

- `bin/phone`: one Python 3 file, standard library only. It has verbs for
  state (`notifs`, `media`, `cal`, `contacts`, `battery`, `foreground`,
  `apps`, `capabilities`, `where`, `clip`, `log`, `sh`), intents (`open`,
  `play`, `msg`, `reply`), the screen (`ui`, `look`, `find`, `tap`, `type`,
  `key`, `scroll`, `swipe`, `scan`, `screen`, `photo`, `torch`), the device
  (`say`, `listen`, `notify`, `ask`), and the plumbing that keeps several
  agents apart (`shelld`, `lease`, `display`, `watchdog`).
- `android/vdisplay`: the display holder. It is a dex that runs under
  `app_process` as shell and keeps a trusted virtual display alive for as
  long as an agent needs it.
- `android/bridge`: an optional app, a notification listener with a loopback
  bridge, which is what lets `phone reply` answer a message without touching
  the screen.
- An agent plugin for Claude Code and Codex with two skills: `phone`, which
  teaches the method (ask the device, climb down the routes, verify by
  observation), and `screens`, which covers several agents on one phone.
- An action ledger. Every action, and every read of personal data, is
  recorded with who did it, what it was, how long it took and whether it
  worked.

## How it works

```
controller (laptop, server, CI box)
  phone --device my-phone <verb>
    |
    |  ssh, over a private network (Tailscale or a LAN)
    v
Termux sshd on the phone (port 8022)
    |
    v
phone CLI  ------------------------->  termux-api (speech, location, camera, ...)
    |
    |  unix socket, sentinel protocol
    v
shell daemon (phone shelld)
    |
    v
rish -> Shizuku -> shell uid (2000)
    |
    +-- display 0      the built-in screen, the person's
    +-- display 6      pr-vd-1, agent A's own trusted virtual display
    +-- display 7      pr-vd-2, agent B's
```

On a controller, `--device` does not run an ssh command per verb. It forwards
the shell daemon's unix socket to the controller once and talks to it
directly, which takes a round trip from about 0.45 s to about 0.07 s. Verbs
that need Termux's own tools or return binary data run on the phone over
ssh. [docs/architecture.md](docs/architecture.md) explains both routes.

## Quickstart

On the phone, the full walkthrough is [docs/setup.md](docs/setup.md). The
short version, after installing Termux, Termux:API and Shizuku and exporting
`rish` into the Termux home:

```sh
pkg install -y git
git clone https://github.com/<you>/parallel-root
bash parallel-root/install/termux-setup.sh --watchdog
```

This installs `phone`, starts `sshd` on port 8022, starts the shell daemon,
and registers a watchdog that keeps all of it running.

On the controller:

```sh
git clone https://github.com/<you>/parallel-root
bash parallel-root/install/install-controller.sh
```

Add an ssh host for the phone (`Host my-phone`, `Port 8022`; see
[docs/setup.md](docs/setup.md#7-reach-the-phone-from-a-controller)), then
try these three commands:

```sh
phone --device my-phone capabilities     # what this phone can do, asked of the phone
phone --device my-phone notifs           # every app's notifications
phone --device my-phone look             # the screen, summarised as text
```

Then take a second screen. This step needs the display holder staged on the
phone first ([docs/setup.md](docs/setup.md#8-the-display-holder)):

```sh
export PHONE_DEVICE=my-phone
d=$(phone display create)                # prints the new display's id
phone --display "$d" open calculator
phone --display "$d" look
phone --display "$d" screen --out vd.png
phone display rm "$d"
```

The person's screen does not change at any point.

## Running several agents at once

A phone has one screen, and two agents on one screen means one agent typing
into the other's chat. parallel-root handles this in layers. Each layer is
opt-in, and most work needs none of them.

**Reads need nothing.** State and intent work (`content query`, `dumpsys`,
`settings`, `am start`) goes through binder to system services that handle
concurrent callers all day. Reads are never gated on any display: `look`,
`find`, `ui`, `notifs`, `screen` and `foreground` keep working while someone
else is driving.

**Displays.** `phone display create` starts a holder at shell uid that owns a
trusted virtual display, with its own focus, its own input method and its
own resumed activity. `--display N` is a global flag, like `--device`. Every
verb after it addresses that screen, and nothing done there reaches display
0. `phone display ls` lists every screen and what is on it, so agents read
it before creating anything. Release the displays you created, by id:
`phone display rm N`. `phone display rm --all` puts the phone back to one
screen, so keep it for a phone no other agent is using; it leaves any
display another agent holds a lease on, and names it.

**Leases, per display.** A mutating verb (`tap`, `type`, `key`, `open`,
`msg`, `reply` and the rest) refuses with exit 5, naming the holder, when
another actor holds the lease on that display. What counts as mutating is
read from the arguments: `scan --tap` is gated and `scan` is not, `media`
only with a transport action, `clip` only for `set`. `display rm` and
`display move` check the lease of every display they touch. Leases carry a
TTL (300 s by default), so an agent that crashes cannot hold a screen
forever.

```sh
phone --display "$d" lease acquire --as agent-a
phone --display "$d" lease release --as agent-a
```

**Lanes.** The shell daemon runs one command at a time. `PHONE_LANE=<name>`
gives a driver its own daemon, so another agent's three-second `uiautomator
dump` does not block your `settings get`. Measured on the reference device:
two four-second commands took 8.6 s through the shared daemon and 4.3 s in
two lanes. Leases live inside a daemon, so drivers in different lanes do not
see each other's leases. Use lanes for throughput and displays for
separation.

**One app, one display.** `am start --display` on an app that already has a
task somewhere else does not make a copy. It moves the task, and the agent
driving it loses the app mid-turn with no error. `phone open` therefore
refuses an app that is open on another display (exit 5). `phone display move
<app> --to N` is the way to move one on purpose.

**What is not multiplied.** A display multiplies screens and nothing else.
Behind each app there is still one process, one signed-in account and one
notification stream. The microphone, the speaker, the notification shade and
the person are single, whatever `--display` says. Content marked
`FLAG_SECURE` (banking apps, DRM video) renders black on every display
except the built-in one. And an agent's display sleeps when the phone does: it
shares the person's power group, so reading its pixels needs the phone awake.

The details are in [docs/displays.md](docs/displays.md).

## Safety, in short

Anyone who can ssh into Termux can run commands as shell on the phone, so
treat that ssh key like an adb key. Accept keys only, and reach sshd only
over a private network. Every action is written to the ledger (mode 0600; it
holds message text), and `phone log` reads it back. Leases and the
one-app-one-display guard keep agents off each other's screens. The skills
require an agent to confirm consequential outbound actions with the person
before taking them, never to read out one-time codes, and never to touch
developer options, wireless debugging, Shizuku, the screen lock or accounts.
[SECURITY.md](SECURITY.md) has the full model.

## The agent plugin

The plugin lives in `plugin/` and has two skills, `phone` and `screens`.

In Claude Code, add the clone as a marketplace (a local path or the git URL),
then install the plugin:

```
/plugin marketplace add /path/to/parallel-root
/plugin install parallel-root@parallel-root
```

`/plugin marketplace add https://github.com/<you>/parallel-root` works for
an unpublished fork too.

In Codex:

```sh
codex plugin marketplace add /path/to/parallel-root
codex plugin add parallel-root@parallel-root
```

Start a new session afterwards so the skills load. The skills assume `phone`
is on `PATH` and that `PHONE_DEVICE`, or a `--device` flag, names the phone.

## Layout

```
bin/phone                 the CLI: one file, python3 stdlib only
android/vdisplay/         the display holder: a dex run by app_process as shell
android/bridge/           optional app: notification listener + loopback bridge
plugin/                   the agent plugin (Claude Code and Codex manifests)
  skills/phone/SKILL.md   the method
  skills/phone/map.md     dated findings on a reference device
  skills/screens/SKILL.md more than one agent on one phone
install/termux-setup.sh   on-device bootstrap, run inside Termux
install/install-controller.sh   put `phone` on PATH on a controller
tests/                    off-device suites; the device half is opt-in
docs/                     setup, architecture, displays, configuration, design
```

## Compatibility

| | |
|---|---|
| reference device | Pixel 10. `map.md` was measured on Android 16 (SDK 36); the display tests were re-run on Android 17 (SDK 37), and `map.md` records what 17 changed. |
| minimum Android | 11, for wireless debugging, which is how Shizuku starts without a computer |
| trusted displays | need a shell that holds `ADD_TRUSTED_DISPLAY`. `com.android.shell` does on recent Android (13 and later). |
| the bridge app | Android 12 (SDK 31) or later. Only `phone reply` needs it. |
| phone side | Termux and Termux:API from F-Droid or GitHub releases, Shizuku, Python 3 |
| controller | macOS or Linux with Python 3.8+ and OpenSSH |
| building the Android pieces | a JDK (11 or later), `zip`, and the Android SDK command-line tools (build-tools 36.x, platform 36), or the CI artifacts |

Other phones should work. Where one differs, `phone capabilities` will show
it before an agent assumes anything.

## Licence

MIT. See [LICENSE](LICENSE).
