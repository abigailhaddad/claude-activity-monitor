# Claude Activity Monitor — setup guide

A break monitor for Claude Code. Tracks how long the user has been actively
prompting (across every session) and nudges them to step away — escalating
from a funny poem to a hard block on new prompts until they actually rest.

You are probably reading this because the user asked you (a Claude Code
agent) to install it on their machine. This file is the runbook.

## What it does

- `monitor.sh` runs as a background daemon. Every 30s it reads system-wide
  input idle time (mouse/keyboard) and the frontmost application name.
  If the user has touched the mouse/keyboard recently *while a "coding
  app" was frontmost*, the streak advances. Otherwise the monitor treats
  the user as idle.
- `hook.sh` is registered as a Claude Code `UserPromptSubmit` hook. On
  every user prompt it reads `stats/nudge.txt` and either injects it as
  context (gentle/firm tier) or exits 2 to block the prompt
  (hard_block).
- The monitor writes tiered nudges into `stats/nudge.txt` once the
  streak crosses each threshold (default 30 / 45 / 60 min in the shipped
  config, but editable).
- The block lifts once the user has been idle (no input while in a
  coding app) for `idle_threshold_minutes` (default 5).

Because `hook.sh` is global (registered in `~/.claude/settings.json`),
this works across *every* Claude Code session on the machine, including
new ones the user might open to try to bypass the block.

## Platform support

- **macOS** — fully supported. Uses `ioreg` (HIDIdleTime) for input
  detection and `osascript` for frontmost-app detection. First run of
  the monitor may trigger an Accessibility permission prompt for the
  terminal — the user needs to grant it, or the app-filter falls back
  to "any input counts" (still works, just less precise).
- **Linux X11** — best-effort. Needs `xprintidle` and `xdotool`
  installed. Not extensively tested.
- **Linux Wayland** — not supported (no portable idle-time primitive).
- **Windows** — not supported.

## Requirements

- `bash`, `awk`, `sed`, `jq` (install `jq` if missing)
- Claude Code installed

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
- **The statusline at the bottom of Claude Code shows the current
  streak** (`12m since break · nudge in 18m · blocked in 48m`). As they
  approach thresholds, the readout changes to `NUDGING`, `FIRM NUDGE`,
  or `BLOCKED`.
- **At the gentle threshold**, Claude will open its next reply with a
  poem telling them to take a break. At the firm threshold, the poem
  gets meaner. Past the hard threshold, new prompts are refused
  entirely until they step away from the keyboard for
  `idle_threshold_minutes`.
- **What counts as "coding" vs. "break":** physical input
  (mouse/keyboard) while the frontmost app is in `config.yaml`'s
  `coding_apps` list. Switching to email/Slack/browser counts as a
  break once they spend more than `idle_threshold_minutes` there.
- **To customize** — edit `config.yaml` and restart the monitor. The
  poem instructions, thresholds, notification text, and coding-app
  list are all in there. Replace the poem with a roast, a haiku, a
  song, whatever.
- **If they get locked out** (monitor bug, stale nudge, etc.):
  `rm stats/nudge.txt` clears the current nudge globally.

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
- `coding_apps` — comma-separated list of app names (case-insensitive
  substring match) whose input counts. When the user's frontmost app
  is not in this list, their input does not keep the streak alive.

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

- The activity signal is *physical input while a coding app is
  frontmost*. This means: watching Claude work while in Terminal keeps
  the streak alive (via mouse movement); switching to email or Slack
  pauses it; walking away pauses it. Background `/loop` or agents do
  nothing on their own — the monitor is watching the human, not the
  machine.
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
