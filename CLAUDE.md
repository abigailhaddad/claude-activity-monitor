# Claude Activity Monitor — setup guide

A break monitor for Claude Code. Tracks how long the user has been actively
prompting (across every session) and nudges them to step away — escalating
from a funny poem to a hard block on new prompts until they actually rest.

You are probably reading this because the user asked you (a Claude Code
agent) to install it on their machine. This file is the runbook.

## What it does

- `hook.sh` is registered globally as a Claude Code `UserPromptSubmit`
  hook in `~/.claude/settings.json`. On every user prompt it (a)
  touches `data/last_prompt.ts` — this is the monitor's activity
  signal — and (b) reads `stats/nudge.txt` and either injects it as
  context (gentle/firm tier), or exits 2 to refuse the prompt
  (hard_block). The hook also fires a small OS banner at each tier so
  the nudge is visible outside the chat.
- `monitor.sh` runs as a background daemon. Every 30s it reads the
  mtime of `data/last_prompt.ts` and updates the streak. Mouse
  movement, typing outside Claude Code, background agents, and
  Claude's own tool use deliberately do NOT count — only real user
  prompts.
- The monitor writes tiered nudges into `stats/nudge.txt` once the
  streak crosses each threshold, and fires an OS banner at the
  transition. Thresholds default to 60 / 90 / 120 min in shipping
  config (editable).
- The hard-block lifts once no prompts have been submitted for
  `idle_threshold_minutes` (default 10) — the monitor's next poll
  will register that as a real break.
- The user can force an immediate reset with `rm stats/nudge.txt`.
  The monitor sees the deletion on its next poll and treats it as
  "I'm taking a break now": streak_start is set to now, and a
  release notification fires if the prior streak was ≥ gentle.

Because `hook.sh` is global, this works across *every* Claude Code
session on the machine, including new ones the user might open to try
to bypass the block.

## Platform support

- **macOS** — fully supported. `osascript` for the notification
  banner; see the notifications section below for the permission
  prompt.
- **Linux** — works. No X11 tools or idle-time primitives needed
  anymore — activity comes from the Claude Code hook directly. Notifications
  use `notify-send` when available.
- **Windows** — should work anywhere bash + Claude Code runs (e.g.
  WSL); notifications degrade to silent if none of osascript /
  terminal-notifier / notify-send is available.

## Requirements

- `bash`, `awk`, `sed`, `jq` (install `jq` if missing)
- Claude Code installed
- **macOS notifications**: the monitor prefers `osascript` (built-in,
  routes through Script Editor) and falls back to `terminal-notifier`
  if osascript is unavailable. First-run may trigger a Script Editor
  notification-permission prompt — the user needs to allow it, and set
  the Script Editor alert style to Banners or Alerts. `terminal-notifier`
  (`brew install terminal-notifier`) is a fine alternative but its
  permission state can silently desync (exit 0 but no banner) on some
  setups, which is why it's the fallback. If the user reports missing
  notifications: grant Script Editor permission; if still broken, try
  `osascript -e 'display notification "test" with title "test"'` from
  a terminal to confirm the backend works at all.

## Install

Run `./install.sh` from the repo. It is idempotent and does both of
the things below; prefer it over doing this by hand.

```
git clone <repo-url> ~/tools/claude-activity-monitor
cd ~/tools/claude-activity-monitor
./install.sh
```

What `install.sh` does:

1. Merges a `UserPromptSubmit` hook entry for this repo's `hook.sh`
   into `~/.claude/settings.json` (via `jq`; won't duplicate).
2. Registers a `statusLine` entry pointing at `statusline.sh`, so the
   user sees their current streak (e.g. `break: 23m`) at the bottom
   of every Claude Code session. If a `statusLine` is already set, it
   is left alone and a note is printed.
3. Installs a launchd agent (macOS) or systemd user unit (Linux) so
   `monitor.sh` runs at login and is restarted if it dies.

### Manual install (if `install.sh` isn't available)

Edit `~/.claude/settings.json` — add the hook and the statusline:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "/absolute/path/to/claude-activity-monitor/hook.sh" } ] }
    ]
  },
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude-activity-monitor/statusline.sh"
  }
}
```

Back up the file before editing. If `statusLine` already exists, ask
the user whether to replace it — don't silently overwrite.

Start the monitor: `nohup ./monitor.sh >/dev/null 2>&1 & disown`.

## How the user actually uses it

After install, tell the user:

- **Nothing to do** — the monitor runs in the background; every Claude
  Code session will enforce it automatically.
- **The statusline** shows two modes:
  - Coding (just prompted): `Nm since break · blocked in Xm`, or
    `BLOCKED · take a break` past the hard threshold.
  - Break (no prompts for a while): `break: Xm left` — a countdown
    toward `idle_threshold_minutes`. If they prompt Claude again, the
    statusline snaps back to coding mode, making the reset visible.
- **At the gentle threshold** Claude opens its next reply with a poem
  telling them to take a break + an OS banner fires. Firm threshold
  is meaner. Past hard_block, new prompts are refused entirely — they
  must stop prompting for `idle_threshold_minutes` to unblock.
- **What counts as activity:** *only* Claude Code `UserPromptSubmit`
  events. Mouse movement, typing in the terminal, other apps, and
  Claude's own tool use do NOT count.
- **To customize** — edit `config.yaml` and restart the monitor.
  Thresholds, poem instructions, and notification text live there.
- **Manual reset:** `rm stats/nudge.txt`. The monitor detects this
  on its next poll and sets `streak_start` to now — statusline flips
  back to "0m since break", and a release notification fires if the
  prior streak was long enough to matter.

## Verify

Open a new Claude Code session. Check:

```
./statusline.sh </dev/null       # should print e.g. "3m since break · nudge in 27m · blocked in 57m"
pgrep -fl monitor.sh             # should show the running process
tail -f stats/activity.log       # watch nudge/break_end events
cat data/state.json              # current streak state
```

To force-test the nudge path without waiting 30 min, temporarily set
`streak_limit_minutes: 1` in `config.yaml`, restart the monitor, wait
90 seconds, send a prompt — Claude should open with a poem. Reset
afterward.

## Configuration

Everything user-visible lives in `config.yaml`:

- Thresholds (`idle_threshold_minutes`, `streak_limit_minutes`,
  `firm_nudge_minutes`, `hard_block_minutes`).
- Nudge instructions (`gentle_nudge`, `firm_nudge`, `hard_block_message`).
  These are the text Claude sees at each tier — replace the poem with a
  roast, a haiku, a song, a drill-sergeant memo. Placeholders available:
  `{mins}`, `{idle_min}`, `{streak_limit_min}`.
- OS notification title/body (`{tier}_notification_title/body`).

After editing, restart the monitor so it picks up changes:

```
pkill -f monitor.sh; sleep 1; nohup ./monitor.sh >/dev/null 2>&1 & disown
```

## Files

```
config.yaml                 — user-editable config (thresholds + nudge text)
monitor.sh                  — background daemon
hook.sh                     — Claude Code UserPromptSubmit hook
statusline.sh               — Claude Code statusLine widget (current streak)
install.sh                  — one-shot installer (hook + statusline + daemon)
data/state.json             — current streak state (gitignored)
data/monitor.log            — private debug log (gitignored)
stats/nudge.txt             — current tier message (empty when inactive)
stats/activity.log          — break/nudge event history (shareable)
```

## Gotchas

- The activity signal is *only* Claude Code user prompt submissions.
  Watching Claude work on a long tool call, reading docs, or typing
  in a different terminal tab do NOT count as activity. Background
  `/loop` or agents do nothing on their own — the monitor is
  watching *you* prompting Claude, not the machine.
- If the monitor dies, `stats/nudge.txt` goes stale. `hook.sh` ignores
  nudges older than 180s, so a dead monitor does not permanently lock
  the user out. Manual escape: `rm stats/nudge.txt`.
- Block across sessions relies on Claude Code reading the same
  `settings.json` hook in every session. Do not register the hook
  per-project — it must be global.
- On macOS, the AppleScript call to get the frontmost app needs
  Accessibility permission for the terminal. If the user hasn't
  granted it, `frontmost_app` returns empty and the filter defaults to
  "count any input" — safe fallback, but the email/Slack exclusion
  won't work until they grant it.
