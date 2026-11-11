#!/bin/bash
# Claude Remote Control: start Claude Code sessions on your Mac from the Claude app.
#
#   Install / manage (same line every time):
#     curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash
#
#   Shortcuts:
#     ... | bash -s -- status
#     ... | bash -s -- restart
#     ... | bash -s -- uninstall
#     ... | bash -s -- install --folder ~/code --permission acceptEdits --awake charger   (no questions)
#
# What it does: adds a small background service (a macOS LaunchAgent) that runs
# `claude remote-control` whenever you're logged in to your Mac. No sudo, nothing
# outside your home folder, and `uninstall` removes all of it.

# Everything lives in main(), called on the last line, so a half-downloaded
# script never runs.

set -u

LABEL="io.github.a3zooz.claude-remote-control"
SUFFIX=""
# Testing only: run a separate copy (own service, config and logs) next to a real install.
if [ -n "${CRC_TEST_NAME:-}" ]; then SUFFIX="-${CRC_TEST_NAME}"; LABEL="${LABEL}${SUFFIX}"; fi
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/claude-remote-control${SUFFIX}"
CONF_DIR="${HOME}/.config/claude-remote-control${SUFFIX}"
CONF="${CONF_DIR}/config"
WD_LABEL="${LABEL}.watchdog"
WD_PLIST="${HOME}/Library/LaunchAgents/${WD_LABEL}.plist"
WD_SCRIPT="${CONF_DIR}/watchdog.sh"
APPLY_LABEL="${LABEL}.apply"
APPLY_LOG="${HOME}/Library/Logs/claude-remote-control${SUFFIX}-apply.log"
REPO_URL="https://github.com/A3zooz/claude-remote-control"
ONE_LINER="curl -fsSL https://raw.githubusercontent.com/A3zooz/claude-remote-control/main/install.sh | bash"

# ---------- output ----------
if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; D=""; G=""; Y=""; R=""; N=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
err()  { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
die()  { err "$*"; exit 1; }

# ---------- input (works under `curl | bash`, where stdin is the script) ----------
HAVE_TTY=0
if { : </dev/tty; } 2>/dev/null; then HAVE_TTY=1; fi

# ask "Question" "default" -> echoes the answer
ask() {
  local q="$1" def="${2:-}" a=""
  if [ "$HAVE_TTY" = 1 ]; then
    if [ -n "$def" ]; then printf '%s %s[%s]%s ' "$q" "$D" "$def" "$N" >/dev/tty
    else printf '%s ' "$q" >/dev/tty; fi
    IFS= read -r a </dev/tty || a=""
  fi
  [ -z "$a" ] && a="$def"
  printf '%s' "$a"
}

yes_no() { # yes_no "Question" y|n -> exit 0 for yes
  local def=2
  case "$2" in [Yy]*) def=1 ;; esac
  say "$1" >/dev/tty 2>/dev/null || say "$1"
  pick "$def" "Yes" "No"
  [ "$PICKED" = 1 ]
}

# pick DEFAULT "Label<TAB>hint" ... -> PICKED = chosen number (1-based).
# Up/down arrows (or j/k, or the option's number) move, Enter chooses. With no
# keyboard it takes the default. Draws on /dev/tty, so it works under curl | bash.
pick() {
  local def="$1"; shift
  local n=$# sel="$1" i key rest line label hint
  sel="$def"
  if [ "$HAVE_TTY" != 1 ]; then PICKED="$def"; return 0; fi
  local opts=("$@")
  _pick_draw() {
    for ((i = 1; i <= n; i++)); do
      line="${opts[i-1]}"; label="${line%%$'\t'*}"; hint=""
      [ "$line" != "$label" ] && hint="${line#*$'\t'}"
      if [ "$i" = "$sel" ]; then
        printf '\033[2K   %s❯ %d) %-34s%s %s%s%s\n' "$G$B" "$i" "$label" "$N" "$D" "$hint" "$N"
      else
        printf '\033[2K     %d) %-34s %s%s%s\n' "$i" "$label" "$D" "$hint" "$N"
      fi
    done >/dev/tty
  }
  printf '   %s↑/↓ to move, Enter to choose%s\n' "$D" "$N" >/dev/tty
  printf '\033[?25l' >/dev/tty                      # hide the cursor while picking
  trap 'printf "\033[?25h" >/dev/tty; exit 130' INT TERM
  _pick_draw
  while :; do
    IFS= read -rsn1 key </dev/tty || break
    case "$key" in
      $'\033')
        IFS= read -rsn2 -t 1 rest </dev/tty || rest=""
        case "$rest" in
          '[A'|'OA') [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
          '[B'|'OB') [ "$sel" -lt "$n" ] && sel=$((sel + 1)) ;;
        esac ;;
      k) [ "$sel" -gt 1 ] && sel=$((sel - 1)) ;;
      j) [ "$sel" -lt "$n" ] && sel=$((sel + 1)) ;;
      [1-9]) [ "$key" -le "$n" ] && sel="$key" ;;
      '') break ;;
    esac
    printf '\033[%dA' "$n" >/dev/tty                 # back to the first option, redraw
    _pick_draw
  done
  # Collapse the list (and its hint line) into one line showing the choice.
  printf '\033[%dA' "$((n + 1))" >/dev/tty
  for ((i = 0; i <= n; i++)); do printf '\033[2K\n' >/dev/tty; done
  printf '\033[%dA' "$((n + 1))" >/dev/tty
  line="${opts[sel-1]}"
  printf '   %s✓%s %s\n' "$G" "$N" "${line%%$'\t'*}" >/dev/tty
  printf '\033[?25h' >/dev/tty
  trap - INT TERM
  PICKED="$sel"
}

# ---------- helpers ----------
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}

pretty() { # /Users/me/x -> ~/x
  # shellcheck disable=SC2088  # a literal ~ is the point here
  case "$1" in "$HOME") printf '~' ;; "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac
}

expand_path() { # ~ and relative paths -> absolute
  local p="$1"
  # shellcheck disable=SC2088  # matching a literal ~ typed by the user
  case "$p" in
    "~") p="$HOME" ;;
    "~/"*) p="${HOME}/${p#\~/}" ;;
  esac
  case "$p" in /*) ;; *) p="$(pwd)/$p" ;; esac
  printf '%s' "${p%/}"
}

find_claude() {
  local c
  c="$(command -v claude 2>/dev/null || true)"
  if [ -z "$c" ]; then
    for c in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" "$HOME/.claude/local/claude"; do
      [ -x "$c" ] && break
      c=""
    done
  fi
  printf '%s' "$c"
}

is_loaded()  { launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; }
svc_pid()    { launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | awk '/^\tpid = /{print $3; exit}'; }

env_url() { # the claude.ai link the server printed, if any
  [ -f "${LOG_DIR}/out.log" ] || return 0
  sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "${LOG_DIR}/out.log" 2>/dev/null \
    | grep -o 'https://claude\.ai/code?environment=[A-Za-z0-9_]*' | tail -1
}

load_config() {
  FOLDER="" PERMISSION="" AWAKE=""
  if [ -f "$CONF" ]; then
    FOLDER="$(sed -n 's/^FOLDER=//p' "$CONF")"
    PERMISSION="$(sed -n 's/^PERMISSION=//p' "$CONF")"
    AWAKE="$(sed -n 's/^AWAKE=//p' "$CONF")"
  fi
}

permission_label() {
  case "$1" in
    default)           say "Ask before every change (safest)" ;;
    acceptEdits)       say "Edit files freely, ask before running commands" ;;
    auto)              say "Auto: Claude decides, asks only for risky actions" ;;
    bypassPermissions) say "Full access: never asks" ;;
    *)                 say "$1" ;;
  esac
}

# Keep-awake modes: no | charger (caffeinate -s, AC power only) | always
# (caffeinate -is: -i also blocks idle sleep on battery). Old configs say yes = charger.
normalize_awake() {
  case "$1" in
    no|n|false|0|none|off) printf 'no' ;;
    yes|y|true|1|charger|ac|plugged) printf 'charger' ;;
    always|battery|both|charger+battery) printf 'always' ;;
    *) return 1 ;;
  esac
}

awake_label() {
  case "$1" in
    charger) say "on the charger" ;;
    always)  say "always (charger and battery)" ;;
    *)       say "no" ;;
  esac
}

valid_permission() {
  case "$1" in default|acceptEdits|auto|bypassPermissions|plan|dontAsk) return 0 ;; *) return 1 ;; esac
}

# ---------- folder trust ----------
# `claude remote-control` exits with "Workspace not trusted" unless the folder,
# or a folder above it, was trusted in ~/.claude.json (the "Do you trust this
# folder?" prompt). Under launchd there's no terminal to show that prompt, and
# Claude Code never saves trust for the home folder at all, so a fresh install
# needs this done up front. Uses JavaScript for Automation (built into macOS)
# to read and edit the JSON, since jq and python3 aren't on every Mac.
CLAUDE_JSON="${HOME}/.claude.json"

# trusted_root DIR -> prints the trusted folder that covers DIR (DIR or a parent), if any
trusted_root() {
  [ -f "$CLAUDE_JSON" ] || return 0
  osascript -l JavaScript - "$CLAUDE_JSON" "$1" 2>/dev/null <<'JS'
function run(argv) {
  ObjC.import('Foundation');
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  if (s.isNil()) return '';
  var p; try { p = JSON.parse(s.js).projects || {}; } catch (e) { return ''; }
  for (var d = argv[1]; ; d = d.replace(/\/[^\/]*$/, '') || '/') {
    if (p[d] && p[d].hasTrustDialogAccepted === true) return d;
    if (d === '/') return '';
  }
}
JS
}

# save_trust DIR... -> marks each folder trusted, keeping the rest of the file as is
save_trust() {
  local tmp mode
  tmp="$(mktemp "${CLAUDE_JSON}.crc.XXXXXX")" || return 1
  if ! osascript -l JavaScript - "$CLAUDE_JSON" "$tmp" "$@" >/dev/null 2>&1 <<'JS'
function run(argv) {
  ObjC.import('Foundation');
  var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  var c = s.isNil() ? {} : JSON.parse(s.js);   // a broken file throws: better than overwriting it
  c.projects = c.projects || {};
  for (var i = 2; i < argv.length; i++) {
    c.projects[argv[i]] = c.projects[argv[i]] || {};
    c.projects[argv[i]].hasTrustDialogAccepted = true;
  }
  var out = $.NSString.alloc.initWithUTF8String(JSON.stringify(c, null, 2) + '\n');
  if (!out.writeToFileAtomicallyEncodingError(argv[1], false, $.NSUTF8StringEncoding, null)) throw new Error('write failed');
}
JS
  then rm -f "$tmp"; return 1; fi
  mode="$(stat -f '%Lp' "$CLAUDE_JSON" 2>/dev/null || echo 600)"
  chmod "$mode" "$tmp" && mv -f "$tmp" "$CLAUDE_JSON" || { rm -f "$tmp"; return 1; }
}

check_folder_trust() {
  local phys root covered
  phys="$(cd "$FOLDER" 2>/dev/null && pwd -P)" || phys="$FOLDER"
  covered="$(trusted_root "$phys")"
  if [ -n "$covered" ]; then
    ok "Folder is trusted${covered:+ ($(pretty "$covered"))}"
    return 0
  fi

  # Trust inside a git repository counts for the whole repository, like Claude's own prompt.
  root="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null || true)"
  say ""
  warn "Claude Code hasn't been told to trust $(pretty "$phys") yet, and Remote Control won't start without it."
  [ -n "$root" ] && [ "$root" != "$phys" ] && \
    say "   This folder is part of the repository at ${B}$(pretty "$root")${N}; trusting it trusts that whole repository."
  say "   Sessions started here can read, edit and run files, and this folder's project"
  say "   settings (hooks, MCP servers, permission rules) apply to them."
  say "   ${D}Only trust a folder you created or one whose contents you trust.${N}"
  if [ "$ARG_TRUST" = 1 ]; then
    :
  elif [ "$HAVE_TTY" = 1 ]; then
    yes_no "   Trust it?" y || die "Not trusted, so nothing was changed. Run this again and pick a folder you trust."
  else
    die "Folder isn't trusted. Pass --trust-folder to trust $(pretty "$phys"), or pick another folder."
  fi
  if [ -n "$root" ] && [ "$root" != "$phys" ]; then save_trust "$phys" "$root"; else save_trust "$phys"; fi \
    || die "Couldn't save that to ${CLAUDE_JSON}. Run ${B}cd \"$(pretty "$phys")\" && claude${N} once, accept the prompt, then run this again."
  ok "Trusted $(pretty "${root:-$phys}")"
}

# ---------- checks ----------
check_mac() {
  [ "$(uname -s)" = "Darwin" ] || die "This only works on a Mac."
  ok "Mac"
}

check_claude() {
  CLAUDE="$(find_claude)"
  if [ -z "$CLAUDE" ]; then
    warn "Claude Code isn't installed on this Mac yet."
    if [ "$HAVE_TTY" = 1 ] && yes_no "  Install it now with the official installer?" y; then
      local tmp
      tmp="$(mktemp -t claude-install)" || die "Couldn't create a temp file."
      if ! curl -fsSL https://claude.ai/install.sh -o "$tmp" || ! bash "$tmp" </dev/tty; then
        rm -f "$tmp"
        die "Claude Code install failed. Try again, or install it from https://claude.ai/download"
      fi
      rm -f "$tmp"
      CLAUDE="$(find_claude)"
    fi
    [ -n "$CLAUDE" ] || die "Install Claude Code first (https://claude.ai/download), then run this again."
  fi
  ok "Claude Code $("$CLAUDE" --version 2>/dev/null | awk '{print $1}')"

  if ! "$CLAUDE" remote-control --help >/dev/null 2>&1; then
    warn "This version of Claude Code doesn't have Remote Control. Updating..."
    "$CLAUDE" update >/dev/null 2>&1 || true
    "$CLAUDE" remote-control --help >/dev/null 2>&1 || die "Remote Control still isn't available. Run 'claude update' and try again."
  fi
}

check_login() {
  local st
  st="$("$CLAUDE" auth status --json 2>/dev/null || true)"
  if ! printf '%s' "$st" | grep -q '"loggedIn": *true'; then
    warn "You're not signed in to Claude Code."
    if [ "$HAVE_TTY" = 1 ] && yes_no "  Sign in now? (a browser window will open)" y; then
      "$CLAUDE" auth login </dev/tty || die "Sign-in didn't finish. Run this again when you're ready."
      st="$("$CLAUDE" auth status --json 2>/dev/null || true)"
    fi
    printf '%s' "$st" | grep -q '"loggedIn": *true' || die "Sign in first (run: claude auth login), then run this again."
  fi
  if ! printf '%s' "$st" | grep -q '"authMethod": *"claude.ai"'; then
    die "Remote Control needs a claude.ai account login, not an API key. Run: claude auth login --claudeai"
  fi
  local email
  email="$(printf '%s' "$st" | sed -n 's/.*"email": *"\([^"]*\)".*/\1/p' | head -1)"
  ok "Signed in${email:+ as $email}"
}

warn_other_servers() {
  local f
  for f in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in "${LABEL}".*) continue ;; esac  # ours, incl. the watchdog
    if grep -q "remote-control" "$f" 2>/dev/null && grep -q "claude" "$f" 2>/dev/null; then
      warn "Another Remote Control service is already set up: $(basename "$f")"
      warn "Two services can't share a folder, and this Mac would show up twice in the Claude app."
    fi
  done
}

# Remote Control refuses to start in a folder another server already serves
# ("This folder is already served by ..."), so catch that before changing anything.
check_folder_free() {
  local ours p cwd
  ours="$(svc_pid)"
  for p in $(pgrep -f '(^|/)claude remote-control' 2>/dev/null); do
    [ "$p" = "$ours" ] && continue
    [ -n "$ours" ] && [ "$(ps -o ppid= -p "$p" | tr -d ' ')" = "$ours" ] && continue  # our keep-awake caffeinate helper (its args contain the command)
    cwd="$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [ "$cwd" = "$FOLDER" ] || continue
    err "Another Remote Control server is already running in $(pretty "$FOLDER") (process $p)."
    say "  Only one can serve a folder. Stop that one first (quit it, or remove the"
    say "  service that starts it), or pick a different folder, then run this again."
    exit 1
  done
}

# ---------- questions ----------
DEFAULT_FOLDER="${HOME}/Claude"

# Claude Code never saves trust for the home folder, so Remote Control can only
# start there if a folder above it (like /Users) happens to be trusted already.
home_unusable() { [ "$1" = "$HOME" ] && [ -z "$(trusted_root "$HOME")" ]; }

choose_folder() {
  local def="${FOLDER:-$DEFAULT_FOLDER}" a hint="the current setting"
  home_unusable "$def" && def="$DEFAULT_FOLDER"
  [ "$def" = "$DEFAULT_FOLDER" ] && [ "$def" != "${FOLDER:-}" ] && hint="created if it doesn't exist"
  say ""
  say "${B}1. Which folder should new sessions start in?${N}"
  say "   ${D}Claude can still work anywhere you point it; this is just where it starts.${N}"
  say "   ${D}Pick a project folder, or a folder that holds them (like ~/code). Not your home folder.${N}"
  say "   Press ${B}Enter${N} to use ${B}$(pretty "$def")${N} ${D}(${hint})${N}, or type another folder."
  while :; do
    a="$(ask "   Folder:" "$(pretty "$def")")"
    a="$(expand_path "$a")"
    if [ "$a" = "$DEFAULT_FOLDER" ] && [ ! -e "$a" ]; then mkdir -p "$a" || die "Couldn't create $a"; fi
    if home_unusable "$a"; then
      err "Claude Code won't save trust for your home folder, so Remote Control can't start there."
      [ "$HAVE_TTY" = 1 ] || die "Pass a folder other than your home folder with --folder."
      continue
    fi
    if [ -d "$a" ]; then FOLDER="$a"; ok "Sessions will start in $(pretty "$FOLDER")"; break; fi
    err "That folder doesn't exist: $a"
    [ "$HAVE_TTY" = 1 ] || die "Pass an existing folder with --folder."
  done
}

choose_permission() {
  local cur="${PERMISSION:-default}" def=1 a
  case "$cur" in acceptEdits) def=2 ;; auto) def=3 ;; bypassPermissions) def=4 ;; esac
  say ""
  say "${B}2. How much can Claude do without asking you?${N}"
  while :; do
    pick "$def" \
      "Ask before every change"$'\t'"safest, you approve each step in the app" \
      "Edit files freely"$'\t'"asks before running commands" \
      "Auto"$'\t'"Claude decides, asks only for risky actions" \
      "Full access, never asks"$'\t'"only if you know what this means"
    case "$PICKED" in
      1) PERMISSION=default; break ;;
      2) PERMISSION=acceptEdits; break ;;
      3) PERMISSION=auto; break ;;
      4)
        say ""
        warn "${B}Full access${N} means anyone signed in to your Claude account (on your phone,"
        warn "a browser, a shared laptop) can make Claude run ${B}any${N} command on this Mac"
        warn "without you approving it: delete files, push code, use your logins."
        if [ "$HAVE_TTY" = 1 ]; then
          a="$(ask "   Type FULL to confirm, or press Enter to pick again:" "")"
          if [ "$a" = "FULL" ]; then PERMISSION=bypassPermissions; break; fi
          def=3
        else
          die "Full access can't be chosen without a confirmation. Pass --permission bypassPermissions --yes-full-access."
        fi
        ;;
    esac
  done
}

choose_awake() {
  local def=1
  case "$(normalize_awake "${AWAKE:-no}" || echo no)" in charger) def=2 ;; always) def=3 ;; esac
  say ""
  say "${B}3. Keep this Mac awake so the app can reach it?${N}"
  say "   ${D}A sleeping Mac can't be reached. Closing a laptop lid still puts it to sleep.${N}"
  pick "$def" \
    "No"$'\t'"normal sleep" \
    "On the charger"$'\t'"stays awake while plugged in" \
    "Always, charger and battery"$'\t'"also on battery, which drains it faster"
  case "$PICKED" in 2) AWAKE=charger ;; 3) AWAKE=always ;; *) AWAKE=no ;; esac
}

# ---------- service ----------
write_plist() {
  local path_env claude_dir prog
  claude_dir="$(dirname "$CLAUDE")"
  # The PATH from the Terminal running this script, so Claude finds git, node,
  # brew tools etc. the same way it does when you start it by hand.
  path_env="${claude_dir}:${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  prog=""
  case "$AWAKE" in
    charger) prog="${prog}    <string>/usr/bin/caffeinate</string><string>-s</string>
" ;;
    always) prog="${prog}    <string>/usr/bin/caffeinate</string><string>-is</string>
" ;;
  esac
  prog="${prog}    <string>$(xml_escape "$CLAUDE")</string>
    <string>remote-control</string>
    <string>--permission-mode</string><string>${PERMISSION}</string>"

  mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Created by ${REPO_URL} . Remove with: ${ONE_LINER} -s -- uninstall -->
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
${prog}
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$FOLDER")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml_escape "$path_env")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardInPath</key><string>/dev/null</string>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR")/out.log</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR")/err.log</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || die "Couldn't write a valid service file ($PLIST)."

  mkdir -p "$CONF_DIR"
  printf 'FOLDER=%s\nPERMISSION=%s\nAWAKE=%s\n' "$FOLDER" "$PERMISSION" "$AWAKE" >"$CONF"
}

# The watchdog runs once a minute and fixes two known Remote Control problems
# that a plain launchd service can't:
#  1. macOS can freeze session processes while nobody is using the Mac; they
#     stay stuck on "Running..." until someone touches the mouse. A SIGCONT
#     un-freezes them. https://github.com/anthropics/claude-code/issues/80827
#  2. After Claude Code auto-updates, the running server keeps spawning
#     sessions from the old version's file. Once that file is cleaned up,
#     every new session fails while the server still looks fine. The
#     watchdog restarts the server onto the new version when no session is
#     running (or right away if the old file is already gone).
#     https://github.com/anthropics/claude-code/issues/84817
#  3. The server redraws its status screen into out.log, which grows by tens
#     of MB a day. launchd opens the log in append mode, so trimming it in
#     place is safe; the claude.ai link is reprinted on every redraw, so the
#     tail still has it.
write_watchdog() {
  mkdir -p "$CONF_DIR"
  cat >"$WD_SCRIPT" <<'WATCHDOG'
#!/bin/bash
# Claude Remote Control watchdog (https://github.com/A3zooz/claude-remote-control).
# Started every minute by launchd. Env: RC_LABEL, RC_CLAUDE, RC_LOG, RC_LOG_DIR, RC_DRY_RUN.
set -u
DOMAIN="gui/$(id -u)"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$RC_LOG"; }
act() { if [ -n "${RC_DRY_RUN:-}" ]; then log "(dry run) would: $*"; else "$@"; fi; }

# 0. Keep logs small: past 5 MB, keep the last 512 KB. Rewrite in place
#    (cat >) rather than replacing the file, so launchd's open handle stays valid.
trim() {
  local f="$1" size
  [ -f "$f" ] || return 0
  size="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  [ "$size" -gt 5242880 ] || return 0
  tail -c 524288 "$f" >"$f.trim" && cat "$f.trim" >"$f"
  rm -f "$f.trim"
}
if [ -z "${RC_DRY_RUN:-}" ]; then
  for f in "${RC_LOG_DIR:-/nonexistent}/out.log" "${RC_LOG_DIR:-/nonexistent}/err.log" "$RC_LOG"; do trim "$f"; done
fi

resolve() { # follow symlinks to the real file
  local p="$1" l n=0
  while [ -L "$p" ] && [ $n -lt 10 ]; do
    l="$(readlink "$p")"
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
    n=$((n + 1))
  done
  printf '%s/%s' "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" "$(basename "$p")"
}

pid="$(launchctl print "${DOMAIN}/${RC_LABEL}" 2>/dev/null | awk '/^\tpid = /{print $3; exit}')"
[ -n "$pid" ] || exit 0
# caffeinate given a command forks: launchd's pid becomes the server and a
# caffeinate child holds the sleep assertions. Older versions may differ, so
# if the service pid is caffeinate itself, use its child.
if [ "$(ps -o comm= -p "$pid")" = "/usr/bin/caffeinate" ]; then
  pid="$(pgrep -P "$pid" | head -1)"
  [ -n "$pid" ] || exit 0
fi
workers="$(pgrep -P "$pid" -f -- '--sdk-url' || true)"

# 1. Un-freeze session processes macOS suspended.
for w in $workers; do
  case "$(ps -o stat= -p "$w" 2>/dev/null)" in
    *T*) act kill -CONT "$w" && log "resumed a frozen session (process $w)" ;;
  esac
done

# 2. Move the server onto a new Claude Code version.
#    Only for the native installer's binary. An npm install is a node script:
#    the running executable is `node`, which would never match, and npm
#    updates in place, so the bug this works around doesn't apply.
current="$(resolve "$RC_CLAUDE")"
case "$(file -b "$current" 2>/dev/null)" in *Mach-O*) ;; *) exit 0 ;; esac
running="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
[ -n "$running" ] || exit 0
case "$(basename "$running")" in node|bun) exit 0 ;; esac
[ "$(resolve "$running")" = "$current" ] && exit 0
if [ ! -e "$running" ]; then
  log "server's Claude Code version was removed by an update; restarting on $(basename "$current")"
  act launchctl kickstart -k "${DOMAIN}/${RC_LABEL}"
elif [ -z "$workers" ]; then
  log "Claude Code updated ($(basename "$running") -> $(basename "$current")), no sessions running; restarting"
  act launchctl kickstart -k "${DOMAIN}/${RC_LABEL}"
fi
WATCHDOG
  chmod 755 "$WD_SCRIPT"

  cat >"$WD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Created by ${REPO_URL} . Remove with: ${ONE_LINER} -s -- uninstall -->
<plist version="1.0">
<dict>
  <key>Label</key><string>${WD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string><string>$(xml_escape "$WD_SCRIPT")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>RC_LABEL</key><string>${LABEL}</string>
    <key>RC_CLAUDE</key><string>$(xml_escape "$CLAUDE")</string>
    <key>RC_LOG</key><string>$(xml_escape "$LOG_DIR")/watchdog.log</string>
    <key>RC_LOG_DIR</key><string>$(xml_escape "$LOG_DIR")</string>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardInPath</key><string>/dev/null</string>
  <key>StandardOutPath</key><string>$(xml_escape "$LOG_DIR")/watchdog.log</string>
  <key>StandardErrorPath</key><string>$(xml_escape "$LOG_DIR")/watchdog.log</string>
</dict>
</plist>
EOF
  plutil -lint "$WD_PLIST" >/dev/null || die "Couldn't write a valid watchdog file ($WD_PLIST)."
}

stop_service() {
  launchctl bootout "${DOMAIN}/${WD_LABEL}" >/dev/null 2>&1 || true
  launchctl bootout "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  local i=0
  while is_loaded && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
}

start_service() {
  : >"${LOG_DIR}/out.log"; : >"${LOG_DIR}/err.log"
  launchctl enable "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl kickstart -k "${DOMAIN}/${LABEL}" >/dev/null 2>&1 \
    || die "macOS refused to start the service. Details: launchctl print ${DOMAIN}/${LABEL}"
  if [ -f "$WD_PLIST" ]; then
    launchctl enable "${DOMAIN}/${WD_LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "$DOMAIN" "$WD_PLIST" >/dev/null 2>&1 || warn "The watchdog didn't start; Remote Control still works without it."
  fi
}

wait_ready() { # up to ~45s for the server to register with claude.ai
  local i=0
  printf '  waiting for Claude to connect'
  while [ $i -lt 45 ]; do
    if [ -n "$(env_url)" ]; then printf '\n'; return 0; fi
    if [ -s "${LOG_DIR}/err.log" ] && [ $i -gt 5 ] && [ -z "$(svc_pid)" ]; then break; fi
    printf '.'; sleep 1; i=$((i + 1))
  done
  printf '\n'
  return 1
}

show_failure() {
  err "Remote Control didn't come up."
  if [ -s "${LOG_DIR}/err.log" ]; then
    say "  ${D}Last lines of ${LOG_DIR}/err.log:${N}"
    tail -8 "${LOG_DIR}/err.log" | sed 's/^/    /'
  fi
  if grep -q "Workspace not trusted" "${LOG_DIR}/err.log" 2>/dev/null; then
    say ""
    say "  Claude Code doesn't trust $(pretty "$FOLDER"). Run this again and pick a project"
    say "  folder (not your home folder); it will offer to trust it."
    stop_service  # otherwise launchd retries it every 30 seconds
    return
  fi
  if grep -q "already served" "${LOG_DIR}/err.log" 2>/dev/null; then
    say ""
    say "  Another Remote Control server is using $(pretty "$FOLDER"). Stop it, or run this"
    say "  again and pick a different folder."
    stop_service  # otherwise launchd retries it every 30 seconds
    return
  fi
  say ""
  say "  Common fixes:"
  say "   • Open Terminal, run ${B}cd \"$(pretty "$FOLDER")\" && claude${N} once, accept any prompt, then run this again."
  say "   • Remote Control may be turned off for your organization; ask your Claude admin."
  say "   • Run this again and choose ${B}Check it's working${N} for details."
}

# ---------- commands ----------
validate_args() { # reject bad options before touching anything
  if [ -n "$ARG_FOLDER" ] && [ ! -d "$(expand_path "$ARG_FOLDER")" ]; then
    die "Folder doesn't exist: $(expand_path "$ARG_FOLDER")"
  fi
  if [ -n "$ARG_FOLDER" ] && home_unusable "$(expand_path "$ARG_FOLDER")"; then
    die "Claude Code won't save trust for your home folder, so Remote Control can't start there. Pass another --folder."
  fi
  if [ -n "$ARG_AWAKE" ] && ! normalize_awake "$ARG_AWAKE" >/dev/null; then
    die "Unknown keep-awake setting: $ARG_AWAKE (use no, charger or always)"
  fi
  if [ -n "$ARG_PERMISSION" ]; then
    valid_permission "$ARG_PERMISSION" || die "Unknown permission level: $ARG_PERMISSION (use default, acceptEdits, auto or bypassPermissions)"
    if [ "$ARG_PERMISSION" = "bypassPermissions" ] && [ "$ARG_YES_FULL" != 1 ]; then
      die "Full access needs --yes-full-access as well."
    fi
  fi
}

cmd_install() {
  validate_args

  step "Checking your Mac"
  check_mac
  check_claude
  check_login
  warn_other_servers

  load_config
  [ -n "$ARG_FOLDER" ] && FOLDER="$(expand_path "$ARG_FOLDER")"
  [ -n "$ARG_PERMISSION" ] && PERMISSION="$ARG_PERMISSION"
  [ -n "$ARG_AWAKE" ] && AWAKE="$(normalize_awake "$ARG_AWAKE")"
  AWAKE="$(normalize_awake "${AWAKE:-no}" || echo no)"

  [ -n "$ARG_FOLDER" ] || choose_folder
  # With no keyboard, keep the saved level (already confirmed once) instead of asking.
  if [ -z "$ARG_PERMISSION" ] && { [ "$HAVE_TTY" = 1 ] || [ -z "$PERMISSION" ]; }; then choose_permission; fi
  # With no keyboard, keep the saved setting instead of asking.
  if [ -z "$ARG_AWAKE" ] && { [ "$HAVE_TTY" = 1 ] || [ ! -f "$CONF" ]; }; then choose_awake; fi

  check_folder_free
  check_folder_trust

  step "Setting it up"
  stop_service
  write_plist
  write_watchdog
  ok "Background service saved"
  start_service
  ok "Started"
  if wait_ready; then
    ok "Connected to Claude"
    print_done
  else
    show_failure
    exit 1
  fi
}

print_done() {
  local url
  url="$(env_url)"
  say ""
  say "${G}${B}✅ All set.${N} This Mac now shows up in the Claude app."
  say ""
  say "  Start a session from your phone or browser:"
  say "   • Claude app → ${B}Code${N} → pick ${B}$(scutil --get ComputerName 2>/dev/null || hostname)${N}"
  [ -n "$url" ] && say "   • or open ${url}"
  say ""
  say "  Starts in:     $(pretty "$FOLDER")"
  say "  Permissions:   $(permission_label "$PERMISSION")"
  say "  Stay awake:    $(awake_label "$AWAKE")"
  say ""
  say "  ${D}It starts by itself whenever you log in to this Mac. To change settings,${N}"
  say "  ${D}check on it or remove it, run the same command again.${N}"
}

cmd_status() {
  load_config
  step "Claude Remote Control"
  if [ ! -f "$PLIST" ]; then warn "Not installed on this Mac."; return 1; fi
  local pid url rc=0
  pid="$(svc_pid)"
  if [ -n "$pid" ]; then ok "Running (process $pid)"; else err "Not running"; rc=1; fi
  url="$(env_url)"
  if [ -n "$url" ]; then ok "Connected: $url"; elif [ -n "$pid" ]; then warn "Running but hasn't connected to Claude yet"; rc=1; fi
  say "  Starts in:     $(pretty "$FOLDER")"
  say "  Permissions:   $(permission_label "${PERMISSION:-default}")"
  say "  Stay awake:    $(awake_label "$(normalize_awake "${AWAKE:-no}" || echo no)")"
  if launchctl print "${DOMAIN}/${WD_LABEL}" >/dev/null 2>&1; then
    say "  Watchdog:      on ${D}(un-freezes stuck sessions, restarts after Claude updates)${N}"
  else
    say "  Watchdog:      ${Y}off${N} ${D}(run again and choose Change settings to add it)${N}"
  fi
  say "  Logs:          $(pretty "$LOG_DIR")"
  if [ -s "${LOG_DIR}/watchdog.log" ]; then
    say ""
    say "  ${D}Recent watchdog actions:${N}"
    tail -3 "${LOG_DIR}/watchdog.log" | sed 's/^/    /'
  fi
  if [ -s "$APPLY_LOG" ]; then
    say ""
    say "  ${D}Last background change ($(pretty "$APPLY_LOG")):${N}"
    grep -E '^=== |exit=|✓|✗|previous settings' "$APPLY_LOG" | tail -6 | sed 's/^/    /'
  fi
  if [ -s "${LOG_DIR}/err.log" ]; then
    say ""
    say "  ${D}Recent errors:${N}"
    tail -5 "${LOG_DIR}/err.log" | sed 's/^/    /'
  fi
  return $rc
}

cmd_restart() {
  [ -f "$PLIST" ] || die "Not installed yet. Run: ${ONE_LINER}"
  load_config
  step "Restarting"
  stop_service
  start_service
  if wait_ready; then ok "Connected to Claude"; else show_failure; exit 1; fi
}

cmd_uninstall() {
  step "Removing Claude Remote Control"
  stop_service
  rm -f "$PLIST" "$WD_PLIST"; ok "Background service removed"
  rm -rf "$CONF_DIR" "$LOG_DIR"
  [ "${DETACHED:-0}" = 1 ] || rm -f "$APPLY_LOG"  # a detached uninstall is still writing to it
  ok "Settings and logs removed"
  say ""
  say "  Claude Code itself is still installed. This Mac will drop out of the Claude app"
  say "  within a few minutes."
}

# --detach: hand install/restart/uninstall to launchd as a one-off job and return.
# Those commands stop the service, which ends every session it hosts, including
# a Claude session that is itself running the command from the Claude app. A
# launchd job isn't part of that session, so it survives and finishes the change.
detach() {
  case "$CMD" in install|restart|uninstall) ;; *) die "--detach works with install, restart or uninstall." ;; esac
  [ "$CMD" = install ] && validate_args
  [ "$CMD" = restart ] && { [ -f "$PLIST" ] || die "Not installed yet."; }
  local self="${BASH_SOURCE[0]:-}" copy
  [ -f "$self" ] || die "--detach needs the script saved to a file first (curl -fsSL ... -o install.sh, then bash install.sh ...)."
  copy="${TMPDIR:-/tmp}"; copy="${copy%/}/claude-remote-control${SUFFIX}-apply.sh"
  cp "$self" "$copy" || die "Couldn't copy the script to $copy."
  : >"$APPLY_LOG"
  launchctl remove "$APPLY_LABEL" >/dev/null 2>&1 || true
  launchctl submit -l "$APPLY_LABEL" -- /usr/bin/env PATH="$PATH" ${CRC_TEST_NAME:+CRC_TEST_NAME="$CRC_TEST_NAME"} /bin/bash "$copy" __detached "$@" \
    || die "launchd refused the job."
  ok "Handed to launchd. The $CMD starts in about 10 seconds."
  say "  Sessions running through Remote Control end when it does, this one too if it"
  say "  came from the Claude app. Afterwards, start a new session and check the result:"
  say "    bash \"$copy\" status       ${D}(log: $(pretty "$APPLY_LOG"))${N}"
}

run_detached() {
  exec >>"$APPLY_LOG" 2>&1 </dev/null
  say "=== $(date '+%Y-%m-%d %H:%M:%S') $CMD"
  sleep 10
  load_config
  local had_conf=0 old_f="$FOLDER" old_p="$PERMISSION" old_a="$AWAKE" rc
  [ -f "$CONF" ] && had_conf=1
  ( dispatch ); rc=$?
  say "exit=$rc"
  if [ "$rc" -ne 0 ] && [ "$CMD" = install ] && [ "$had_conf" = 1 ]; then
    say "Putting the previous settings back"
    ( ARG_FOLDER="$old_f"; ARG_PERMISSION="$old_p"; ARG_AWAKE="$old_a"; ARG_YES_FULL=1; cmd_install )
    say "exit=$? (previous settings)"
  fi
  say "=== $(date '+%Y-%m-%d %H:%M:%S') done"
  launchctl remove "$APPLY_LABEL"  # last: this stops the job, and launchd would rerun it otherwise
}

dispatch() {
  case "$CMD" in
    install) cmd_install ;;
    status) cmd_status ;;
    restart) cmd_restart ;;
    uninstall) cmd_uninstall ;;
    menu) menu ;;
  esac
}

menu() {
  step "Claude Remote Control is already set up on this Mac"
  if [ -n "$(svc_pid)" ]; then ok "Running"; else warn "Installed but not running"; fi
  say ""
  pick 1 "Check it's working" "Restart it" "Change settings"$'\t'"folder, permissions, stay awake" "Remove it" "Nothing, exit"
  case "$PICKED" in
    1) cmd_status ;;
    2) cmd_restart ;;
    3) cmd_install ;;
    4) if yes_no "   Remove Remote Control from this Mac?" n; then cmd_uninstall; fi ;;
    *) say "  Bye." ;;
  esac
}

usage() {
  say "Claude Remote Control: start Claude Code sessions on this Mac from the Claude app."
  say ""
  say "  ${ONE_LINER}                    install, or manage if already installed"
  say "  ${ONE_LINER} -s -- status       is it running?"
  say "  ${ONE_LINER} -s -- restart"
  say "  ${ONE_LINER} -s -- uninstall"
  say ""
  say "Options for install: --folder PATH  --permission default|acceptEdits|auto|bypassPermissions"
  say "                     --awake no|charger|always  --yes-full-access"
  say "                     --trust-folder  trust the folder in Claude Code if it isn't yet"
  say "Any change: --detach  run it as a one-off launchd job (survives this session ending)"
}

main() {
  CMD="" ARG_FOLDER="" ARG_PERMISSION="" ARG_AWAKE="" ARG_YES_FULL=0 ARG_TRUST=0 ARG_DETACH=0 DETACHED=0
  local pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --detach) ARG_DETACH=1; shift; continue ;;
      __detached) DETACHED=1; shift; continue ;;
    esac
    pass+=("$1")
    case "$1" in
      install|status|restart|uninstall|menu) CMD="$1" ;;
      --folder) ARG_FOLDER="${2:-}"; pass+=("${2:-}"); shift ;;
      --permission) ARG_PERMISSION="${2:-}"; pass+=("${2:-}"); shift ;;
      --awake) ARG_AWAKE="${2:-}"; pass+=("${2:-}"); shift ;;
      --yes-full-access) ARG_YES_FULL=1 ;;
      --trust-folder) ARG_TRUST=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done

  if [ -z "$CMD" ]; then
    if [ -f "$PLIST" ] && [ "$HAVE_TTY" = 1 ]; then CMD=menu; else CMD=install; fi
  fi
  if [ "$DETACHED" = 1 ]; then run_detached; exit 0; fi
  if [ "$ARG_DETACH" = 1 ]; then detach ${pass[@]+"${pass[@]}"}; exit 0; fi
  if [ "$CMD" = install ] && [ "$HAVE_TTY" = 0 ] && { [ -z "$ARG_FOLDER" ] || [ -z "$ARG_PERMISSION" ]; }; then
    say "  ${D}No keyboard available; using saved settings, or defaults, for anything not given as an option.${N}"
  fi

  dispatch
}

main "$@"
