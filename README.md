# claude-activity-monitor

[![tests](https://github.com/abigailhaddad/claude-activity-monitor/actions/workflows/tests.yml/badge.svg)](https://github.com/abigailhaddad/claude-activity-monitor/actions/workflows/tests.yml)

![The monitor watched, the monitor waited. The monitor's patience has fully deflated. Two hours of coding, no break in between — now close the laptop. Go touch something green.](docs/screenshots/block.jpg)

Makes Claude Code refuse your prompts after you've been at it too
long. It counts how long you've been prompting Claude — across
every session, every chat — and escalates from a funny poem to a
hard block on new prompts until you step away.

Two tiers, both configurable:

- **Nudge** — Claude opens its next reply with a reminder to take a
  break. An OS banner fires too. You can still work.
- **Block** — Claude Code refuses to send your prompt. In this chat,
  in any other chat, in a brand-new session you just opened to sneak
  around it. The block lifts only after a break of whatever length
  you set.

## Everything is customizable

Thresholds, poem instructions, OS banner text, and the break length
all live in `config.yaml`. Swap the poem for a roast, a haiku, a
pirate shanty, a drill-sergeant memo — Claude reads whatever you
put there. Change the break length to 2 minutes or 30. The shipped
defaults are a starting point, not a prescription.

Only the prompts you send to Claude Code count. Walking away from
the keyboard or working in other apps does nothing on its own — a
break is just time spent not prompting Claude.

## Install

```sh
git clone https://github.com/abigailhaddad/claude-activity-monitor.git
cd claude-activity-monitor
./install.sh
```

`install.sh` wires a `UserPromptSubmit` hook into
`~/.claude/settings.json` (idempotent — safe to re-run), installs a
statusLine widget that shows your current streak, and starts a tiny
background helper via launchd (macOS) or a systemd user unit
(Linux).

Open a new Claude Code session and go. The statusline shows your
streak and countdown while you're coding, and flips to a break
countdown once a nudge is active and you pause.

## Platform support

- **macOS** — fully supported.
- **Linux** — works. No X11 tools or system-wide idle primitives
  are needed; activity comes from the Claude Code hook directly.
- **Windows / WSL** — should work anywhere `bash` + Claude Code
  runs; OS banners degrade to silent if none of `osascript` /
  `terminal-notifier` / `notify-send` is available.

## Requirements

- `bash`, `jq`, `awk`, `sed` — all standard. Install `jq` if missing
  (`brew install jq` / `apt install jq`).
- Claude Code.
- **macOS banners**: first-run may trigger a Script Editor
  notification-permission prompt (the tool uses `osascript` by
  default). Allow it and set the alert style to Banners or Alerts.
  If you don't see any banners, run `osascript -e 'display
  notification "test" with title "test"'` from a terminal to confirm
  the backend works at all. `terminal-notifier` (`brew install
  terminal-notifier`) is also supported as a fallback.

## Configuration

Everything is in `config.yaml`. You can override any of it — the
defaults are just one person's preferences.

- **Thresholds** (`nudge_minutes`, `block_minutes`,
  `idle_threshold_minutes`) — when each tier fires, and how long a
  break has to be to count.
- **Nudge text** (`nudge_instructions`, `block_message`) — what
  Claude sees at each tier. Placeholders available: `{mins}`,
  `{idle_min}`, `{nudge_min}`.
- **Banner text** (`nudge_notification_title`/`body`,
  `block_notification_title`/`body`) — the OS banner that fires
  alongside each tier.

After edits, restart the monitor:

```sh
launchctl kickstart -k gui/$(id -u)/com.user.claude-activity-monitor   # macOS
systemctl --user restart claude-activity-monitor                       # Linux
```

## How it works

- `hook.sh` runs on every `UserPromptSubmit`. It (a) touches
  `data/last_prompt.ts` — the monitor's activity signal — and (b)
  reads `stats/nudge.txt` to either inject the reminder as context
  (nudge tier) or exit 2 to refuse the prompt (block tier). It also
  fires an OS banner at each tier.
- `monitor.sh` polls every 30 seconds. It reads the mtime of
  `data/last_prompt.ts`, advances the streak, and writes the
  appropriate nudge once you cross a threshold.
- When you stop prompting for `idle_threshold_minutes`, the streak
  resets. If the prior streak was long enough to trigger any
  nudging, a "break registered" banner fires so you know you're
  clear.
- The block is global across sessions — you can't open a new chat
  to escape it.

## Locked out, or want to reset manually

```sh
rm stats/nudge.txt
```

This is also the hand-wave for "I know, I'm taking a break right
now, reset the clock." The monitor sees the deletion on its next
poll and sets your streak back to zero. The hook also ignores
`nudge.txt` if it's more than 3 minutes stale, so a crashed monitor
won't leave you permanently blocked.

## Uninstall

```sh
./uninstall.sh
```

Stops the daemon, removes the launchd/systemd unit, and strips the
hook + statusLine entries from `~/.claude/settings.json` (only if
the statusLine still points at ours). The repo directory itself is
left alone — `rm -rf` it if you want it gone entirely.

## Files

```
config.yaml            — thresholds, nudge text, banner text
monitor.sh             — background daemon
hook.sh                — UserPromptSubmit hook
statusline.sh          — Claude Code statusLine widget (current streak)
install.sh             — one-shot setup
uninstall.sh           — removes the daemon + hook + statusLine
data/                  — runtime state (gitignored)
stats/activity.log     — history of nudges and break_end events
stats/nudge.txt        — current tier message (empty when inactive)
tests/                 — shell test suite (bash tests/run.sh)
CLAUDE.md              — setup runbook for a Claude Code agent
```

## License

MIT. See [LICENSE](LICENSE).
