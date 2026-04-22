# Claude Activity Monitor — setup guide

A break monitor for Claude Code. Tracks how long the user has been actively
prompting (across every session) and nudges them to step away — escalating
from a funny poem to a hard block on new prompts until they actually rest.

You are probably reading this because the user asked you (a Claude Code
agent) to install it on their machine. This file is the runbook.

## What it does

Two processes, clean split of responsibilities:

- `hook.sh` is registered globally as a Claude Code hook in
  `~/.claude/settings.json` for `UserPromptSubmit` only. (An earlier
  version also registered `Stop` to catch interjections as activity;
  that was removed because it meant a user who walked away while
  Claude was streaming still counted as engaged. Only real user
  prompts count now.) The hook:
  - Touches `data/last_prompt.ts` — the monitor's activity signal —
    *unless* the current tier is `block`. Refused prompts must not
    reset the idle clock or the user could never unblock.
  - On nudge tier: injects `stats/active.txt`'s body into the chat
    (Claude writes a poem in response) ONCE per tier-epoch, gated
    by `data/last_injected.ts`. First prompt in any chat during a
    nudge epoch fires; every other prompt everywhere stays silent
    until the monitor flips tier again.
  - On block tier: refuses the prompt with exit 2 and prints the
    block message to stderr. Every attempt, no gating.
- `monitor.sh` runs as a background daemon. Every 30s it reads the
  mtime of `data/last_prompt.ts` and updates the streak. Mouse
  movement, typing outside Claude Code, background agents, and
  Claude's own tool use do NOT count — only real user prompts.
- Two tiers: `nudge` and `block`. The monitor writes the active
  tier into `stats/active.txt` *only on tier transitions*. Rewriting
  every poll would make each chat see a different `{mins}` value
  depending on when its hook ran, so the poem number is frozen at
  the moment the tier flipped. Threshold *values* live in
  `config.yaml` — do not quote specific minute numbers anywhere
  else, they will drift.
- OS banners and audio are the monitor's job, not the hook's.
  The hook never rings.
- The block lifts once no prompts have been submitted for
  `idle_threshold_minutes`. A release notification + sound fires
  at the moment the idle timer crosses (not on the next prompt),
  and *only* if the prior tier was `block` — nudge-tier idle
  crossings are silent. The monitor fires this from the main loop
  when it detects the idle transition, so the user hears the "you
  can prompt again" signal while they're still away from the keyboard.
- The user can force an immediate reset with `rm stats/active.txt`.
  The monitor sees the deletion on its next poll and treats it as
  "I'm taking a break now": streak_start is set to now, and a
  release notification fires if the prior tier was `block`.

Because `hook.sh` is global, this works across *every* Claude Code
session on the machine, including new ones the user might open to try
to bypass the block.

## Platform support

macOS only. The live menubar readout is a SwiftBar plugin (Mac
app), so the whole project is gated on macOS — `install.sh` hard
fails on non-Darwin.

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
3. Installs a launchd agent so `monitor.sh` runs at login and is
   restarted if it dies.

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
    `BLOCKED · take a break` past the block threshold.
  - Break (no prompts for a while): `break: Xm left` — a countdown
    toward `idle_threshold_minutes`. If they prompt Claude again,
    the statusline snaps back to coding mode, making the reset
    visible.
- **At the nudge threshold** Claude opens *one* reply with a
  reminder to take a break (once per tier-epoch, across all open
  chats), and an OS banner fires. Past the block threshold, new
  prompts are refused entirely — the user must stop prompting for
  `idle_threshold_minutes` to unblock. Refused prompts do not
  count as activity, so the idle clock keeps running.
- **What counts as activity:** *only* Claude Code `UserPromptSubmit`
  events, and only when not currently blocked. Response-end
  (`Stop`), mouse movement, typing in the terminal, other apps,
  Claude's own tool use, and background `/loop` or agents all
  do NOT count.
- **Release sound fires only on block lift**, not on nudge-tier
  idle crossings, and fires at the moment the idle timer crosses
  the threshold (not on the user's next prompt).
- **To customize** — edit `config.yaml` and restart the monitor.
  Thresholds, poem instructions, and notification text live there.
- **Manual reset:** `rm stats/active.txt`. The monitor detects this
  on its next poll and sets `streak_start` to now — statusline flips
  back to "0m since break", and a release notification fires only
  if the prior tier was `block`.

## Verify

Open a new Claude Code session. Check:

```
./statusline.sh </dev/null       # should print e.g. "3m since break · blocked in Xm"
pgrep -fl monitor.sh             # should show the running process
tail -f stats/activity.log       # watch nudge/break_end events
cat data/state.json              # current streak state
cat stats/active.txt             # current active tier + message (empty when inactive)
```

To force-test the nudge path without waiting on real thresholds,
temporarily set `nudge_minutes: 1` in `config.yaml`, restart the
monitor, wait 90 seconds, send a prompt — Claude should open with a
reminder. Reset afterward.

## Configuration

Everything user-visible lives in `config.yaml`:

- Thresholds (`idle_threshold_minutes`, `nudge_minutes`,
  `block_minutes`).
- Instructions to Claude (`nudge_instructions`, `block_message`) —
  the text Claude sees at each tier. Replace the poem with a roast,
  a haiku, a song, a drill-sergeant memo. Placeholders available:
  `{mins}`, `{idle_min}`, `{nudge_min}`.
- OS notification title/body (`nudge_notification_*`,
  `block_notification_*`).
- Optional audio clips per tier (`nudge_audio_file`,
  `block_audio_file`, `release_audio_file`) — empty = silent.
  Played via `afplay` / `paplay` / `aplay` in the background.

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
uninstall.sh                — removes launchd agent, hook, statusLine, SwiftBar symlink
tests/                      — shell test suite (bash tests/run.sh)
.github/workflows/tests.yml — CI running the test suite on push/PR
data/state.json             — current streak state (gitignored)
data/monitor.log            — private debug log (gitignored)
data/last_prompt.ts         — mtime = timestamp of last UserPromptSubmit (gitignored)
data/last_injected.ts       — gate: nudge injects only when active.txt is newer (gitignored)
stats/active.txt            — current tier message (empty when inactive)
stats/activity.log          — break/nudge event history (shareable)
```

## Gotchas

- The activity signal is *only* Claude Code user prompt submissions.
  Watching Claude work on a long tool call, reading docs, or typing
  in a different terminal tab do NOT count as activity. Background
  `/loop` or agents do nothing on their own — the monitor is
  watching *you* prompting Claude, not the machine.
- If the monitor dies, `stats/active.txt` goes stale. `hook.sh` ignores
  tiers older than 180s, so a dead monitor does not permanently lock
  the user out. Manual escape: `rm stats/active.txt`.
- Block across sessions relies on Claude Code reading the same
  `settings.json` hook in every session. Do not register the hook
  per-project — it must be global.
- On macOS, the OS banner uses `osascript` by default, which routes
  through Script Editor and needs notification permission granted
  once (System Settings → Notifications → Script Editor → Allow,
  Banners or Alerts). If the user says banners don't appear, have
  them run `osascript -e 'display notification "test" with title
  "test"'` — if that shows nothing, the permission is the issue.
  `terminal-notifier` is a supported fallback but its permission
  state can silently desync (exit 0, no banner) on some setups.
