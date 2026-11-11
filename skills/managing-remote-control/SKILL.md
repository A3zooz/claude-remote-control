---
name: managing-remote-control
description: Use when someone wants to start Claude Code sessions on their Mac from the Claude app, their phone or claude.ai/code, or asks to install, check, restart, change, fix or remove Claude Remote Control (the background `claude remote-control` service), including "my Mac doesn't show up in the app" and "stop asking me to approve things on my phone".
---

# Managing Remote Control

`install.sh` from github.com/A3zooz/claude-remote-control does the work: a launchd service running `claude remote-control`, plus a watchdog. macOS only.

Your shell has no keyboard, so the script's own questions silently take defaults. Ask in chat instead and pass every choice as a flag.

## 1. Fetch the script and look

```bash
RC="${TMPDIR:-/tmp}/claude-rc-install.sh"   # fixed path: set RC the same way in later commands
curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh -o "$RC"
bash "$RC" status
```

`status` shows the current folder, permission level, keep-awake and the last background change. If it reports a problem, fix that first. Don't reinstall blindly.

## 2. Ask, with AskUserQuestion

Ask only about what changes. Keep the current values for everything else.

| Flag | Choices |
|---|---|
| `--folder` | where sessions start (default `~/Claude`; not `~`, Claude Code never saves trust for the home folder) |
| `--trust-folder` | trust that folder in Claude Code if it isn't yet. Only after the user says yes to trusting it: sessions there can read, edit and run files, and its hooks and MCP servers apply |
| `--permission` | `default` (asks every time), `acceptEdits`, `auto`, `bypassPermissions` |
| `--awake` | `no`, `charger` (awake only while plugged in), `always` (also on battery, which drains it faster). `pmset -g batt` shows which it's on now |

Full access (`bypassPermissions`) gets its own question first: anyone signed in to their Claude account could run any command on this Mac with no approval. Add `--yes-full-access` only after an explicit yes to that question.

## 3. Is this chat running through the service?

`install` (when already installed), `restart` and `uninstall` stop the service, which ends every session it hosts:

```bash
p=$PPID; while [ "${p:-1}" -gt 1 ]; do ps -o args= -p "$p" | grep -qE '^[^ ]*claude remote-control' && { echo HOSTED; break; }; p=$(ps -o ppid= -p "$p" | tr -d ' '); done
```

| Result | Run |
|---|---|
| nothing printed | `bash "$RC" install --folder … --permission … --awake …`, then `bash "$RC" status` |
| `HOSTED`, and status shows it installed | Tell the user this chat will end, and get a yes. Then run the same command with `--detach` added. |
| `HOSTED`, but status says "Not installed" | The chat runs through a `claude remote-control` someone started by hand. The installer refuses that server's folder, so offer a different folder. Otherwise the user has to stop that server at the Mac. |

`--detach` hands the change to launchd, waits 10 seconds, applies it, and puts the previous settings back if the change fails. Tell the user: wait a minute, start a new session from the app (Code, then their Mac), and ask it to check Remote Control. That session runs step 1, and `status` shows the outcome.

`nohup … &` is not a substitute. The session's processes die with it, and a change cut off midway leaves the Mac offline with nothing to restart it.

## Errors the user has to fix

| Message | Tell the user |
|---|---|
| not signed in / needs claude.ai login | run `! claude auth login` |
| `Folder isn't trusted` / `Workspace not trusted` | ask whether they trust that folder; if yes, rerun with `--trust-folder`. For the home folder, pick another folder instead |
| `already served` / another server in folder | stop the other `claude remote-control`, or pick another folder |
