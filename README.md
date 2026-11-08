# Claude Remote Control for your Mac

Start Claude Code sessions **on your Mac** from the **Claude app on your phone or in your browser**, even when you're away from your desk.

It adds a small background service that keeps your Mac connected to your Claude account. It starts by itself every time you log in.

## Set it up (2 minutes)

1. Open **Terminal** (press `⌘ Space`, type `Terminal`, press Enter).
2. Copy this line, paste it into Terminal, and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash
   ```

3. Answer three quick questions. Pressing Enter picks the default, which is fine for most people.
4. When you see **✅ All set**, open the Claude app, go to **Code**, and pick your Mac.

If Claude Code isn't installed or you're not signed in, the script offers to do that for you first.

## The three questions

**1. Which folder should sessions start in?**
Where Claude starts working. The default is your home folder. Pick your projects folder if you have one.

**2. How much can Claude do without asking you?**

| Choice | What it means |
|---|---|
| **1. Ask before every change** *(default)* | Claude asks you in the app before editing files or running commands. Safest. |
| **2. Edit files freely** | Claude edits files on its own, but asks before running commands. |
| **3. Auto** | Claude decides, and only asks for risky actions. |
| **4. Full access, never asks** | Claude can run *anything* on your Mac without asking. Anyone signed in to your Claude account could use it. You have to type `FULL` to choose this. |

**3. Keep your Mac awake while plugged in?**
A sleeping Mac can't be reached from your phone. Say yes if you want it reachable whenever it's on the charger. Closing a laptop lid still puts it to sleep.

## Check, change or remove it

Run the **same line** again. You'll get a menu:

```
1) Check it's working
2) Restart it
3) Change settings (folder, permissions, stay awake)
4) Remove it
```

Or go straight to one of them:

```
curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash -s -- status
curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash -s -- restart
curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash -s -- uninstall
```

**Remove** deletes everything this script added. Claude Code itself stays installed.

## Something's wrong?

- **My Mac doesn't show up in the app.** Run the line again and pick **Check it's working**. Make sure the Mac is awake and online.
- **It says it didn't come up.** Open Terminal, run `claude` once in the folder you chose, accept any prompt it shows, then run the line again.
- **Still stuck?** Send the output of the **Check it's working** option to whoever shared this with you.

## What it changes on your Mac

Everything stays inside your user account. No admin password needed.

| File | Purpose |
|---|---|
| `~/Library/LaunchAgents/io.github.a3zooz.claude-remote-control.plist` | The background service. It runs `claude remote-control`. |
| `~/Library/LaunchAgents/io.github.a3zooz.claude-remote-control.watchdog.plist` | A small check that runs once a minute (see below) |
| `~/.config/claude-remote-control/config` | Your three answers |
| `~/.config/claude-remote-control/watchdog.sh` | What that check does |
| `~/Library/Logs/claude-remote-control/` | Logs, for troubleshooting |

## The watchdog

A small check runs once a minute and fixes two known problems with running Remote Control in the background:

- **Sessions stuck on "Running…" while you're away.** macOS can freeze the session while nobody is using the Mac, and it stays stuck until someone touches the mouse ([anthropics/claude-code#80827](https://github.com/anthropics/claude-code/issues/80827)). The watchdog wakes frozen sessions back up.
- **New sessions failing after Claude Code updates itself.** The background service keeps using the old version, and once that version is cleaned up every new session fails, while the service still looks fine ([anthropics/claude-code#84817](https://github.com/anthropics/claude-code/issues/84817)). The watchdog restarts the service on the new version when no session is running, or right away if the old version is already gone.

Anything it does is logged in `~/Library/Logs/claude-remote-control/watchdog.log`, and **Check it's working** shows the latest entries.

## For technical folks

Setup without questions (for scripts or device management):

```
curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh \
  | bash -s -- install --folder ~/code --permission acceptEdits --awake no
```

- `--permission` takes `default`, `acceptEdits`, `auto` or `bypassPermissions`. `bypassPermissions` also requires `--yes-full-access`.
- The service uses the absolute path to `claude` and the `PATH` from the Terminal you installed from. If you move Claude Code or add tools to your PATH later, run the line again and pick *Change settings*.
- "Keep awake" wraps the command in `caffeinate -s`.
- The service runs with `ProcessType=Interactive`, the launchd workaround suggested in #80827. The watchdog's `SIGCONT` covers the cases where that isn't enough.
- Not applied: `SHELL=/bin/sh` from [#78903](https://github.com/anthropics/claude-code/issues/78903). It would change the shell Claude's Bash tool uses. Only consider it if sessions hang before the first reply and you have a heavy `~/.zshrc`.
