# Security

parallel-root gives software real power over a real phone. This page covers
what that power is, who can reach it, how to limit it, and what the agents
are told to do with it.

## What the setup grants

- **Shell uid, through Shizuku.** Anything that can run `rish`, or reach the
  shell daemon's socket, runs commands as uid 2000 on the phone. That is the
  same identity as `adb shell`. It can read every notification, the screen,
  contacts, the calendar, SMS and the call log where the platform allows,
  install packages, change settings, start any activity, and inject input.
  It is not root. It cannot read other apps' private data directories and
  cannot change system partitions.
- **The Termux app's own permissions**, through termux-api: microphone,
  camera, location, clipboard, notifications and whatever else you grant
  Termux:API.
- **The bridge app, if installed**: notification listener access. It can
  read notification content and fire reply and action buttons.

## Who can reach it

| path | who | protection |
|---|---|---|
| Termux's sshd (port 8022) | anyone with a key in `~/.ssh/authorized_keys`, from any network that can route to the phone | keys only; a private network |
| the shell daemon socket (`$PREFIX/tmp/phone-shell.sock`) | the Termux app's uid only | mode 0600, inside Termux's private prefix |
| a forwarded socket on a controller (`$TMPDIR/phone-<device>.sock`) | the controller user who created it | the controller's own file permissions; keep `TMPDIR` private to your user |
| the bridge (device loopback, port 8137) | any app on the phone can connect | the token, which only shell can read |
| `rish` | any process running as the Termux app | Shizuku's per-app authorisation, which you granted to Termux |

Whoever holds an authorised ssh key can run commands as shell on the phone.
**Treat that key like an adb key.**

## Hardening

- **Keys only.** Put `PasswordAuthentication no` and
  `KbdInteractiveAuthentication no` in `$PREFIX/etc/ssh/sshd_config`. Use a
  key with a passphrase, or one held by an agent or a hardware token.
- **Private network only.** Reach sshd over Tailscale or a LAN you control.
  **Never forward port 8022 from a router or expose it publicly.**
- **Tailscale ACLs.** If you use Tailscale, write an ACL that allows only
  your controllers to reach the phone on port 8022.
- **One key per controller**, so a lost laptop can be removed from
  `authorized_keys` without re-keying the others.
- **Shizuku**: authorise only Termux. Shizuku lists the apps it has
  authorised; revoke any you do not recognise.
- **Wireless debugging** is needed only to start Shizuku. You can turn it off
  once Shizuku is running, and Shizuku keeps working until the next reboot.

## The bridge token

Loopback is not a permission boundary: every app on the phone can open
127.0.0.1. The bridge therefore rejects any request without a token. It
creates a random token on first start and stores it in its own external
files directory, `/sdcard/Android/data/parallelroot.bridge/files/token`.
Scoped storage keeps that directory away from other apps, but the shell uid
can read it, which is how `phone` gets it. Tokens are compared in constant
time. If you suspect the token has leaked, delete the file and restart the
bridge, which then creates a new one:

```sh
phone sh 'rm /sdcard/Android/data/parallelroot.bridge/files/token;
  am force-stop parallelroot.bridge;
  cmd notification disallow_listener parallelroot.bridge/.Listener;
  cmd notification allow_listener parallelroot.bridge/.Listener'
```

Then run `phone reply --list`. It reads the token afresh, so an answer means
the bridge came back with a new one. If it reports the bridge unreachable,
the listener has not been bound again yet: reboot the phone, and the system
binds it at startup.

`PHONE_BRIDGE_TOKEN` lets a controller supply the token. Do not put it in a
config file you share.

## The ledger

Every act, and every read of personal data, is appended to
`~/.local/state/parallel-root/actions.jsonl` (`PHONE_LEDGER`) with the
actor, verb, detail, result, duration and exit status. The file is created
with mode 0600 because **it holds message text and contact names**. Each
machine keeps its own half. Treat both as personal data: do not sync them
anywhere you would not sync messages, and do not paste them into bug
reports.

The ledger records what happened. It does not enforce anything: something
with shell access can bypass `phone` entirely and leave no line. Its value
is that agents using `phone` leave a record that `phone log` can read back.

## Rules the agents follow

The skills in `plugin/skills/` tell an agent:

- **Confirm consequential outbound actions first**, in the same turn, saying
  exactly what will be sent and to whom. That covers messages to people,
  anything involving money, and anything that cannot be undone. `phone msg`
  only drafts unless given `--send`. `phone reply` sends immediately.
- **Never read out a one-time code** or 2FA number, aloud or into a message.
- **Never touch** Developer options, wireless debugging, Shizuku, the screen
  lock or accounts. Changing them can cut off the control channel, and only
  someone holding the phone can restore it.
- **Take a lease before acting on a display**, release it afterwards, and
  release any display it created.
- **Verify by observation** and report what was seen, not what was
  attempted.

These rules are instructions, not enforcement. An agent can ignore them. Run
agents you trust, with permission settings that match what you want them to
do.

## Reporting a vulnerability

Please report security issues privately, through **GitHub's private
vulnerability reporting** on this repository: the Security tab, then
"Report a vulnerability". Do not open a public issue for one.

Include what an attacker needs (network position, keys, an app installed on
the phone), what they gain, and the steps to reproduce it. Leave out real
notification content, messages and ledger excerpts.
