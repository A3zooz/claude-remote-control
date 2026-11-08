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
#     ... | bash -s -- install --folder ~/code --permission acceptEdits --awake yes   (no questions)
#
# What it does: adds a small background service (a macOS LaunchAgent) that runs
# `claude remote-control` whenever you're logged in to your Mac. No sudo, nothing
# outside your home folder, and `uninstall` removes all of it.

# Everything lives in main(), called on the last line, so a half-downloaded
# script never runs.

set -u

LABEL="io.github.a3zooz.claude-remote-control"
UID_NUM="$(id -u)"
DOMAIN="gui/${UID_NUM}"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/claude-remote-control"
CONF_DIR="${HOME}/.config/claude-remote-control"
CONF="${CONF_DIR}/config"
WD_LABEL="${LABEL}.watchdog"
WD_PLIST="${HOME}/Library/LaunchAgents/${WD_LABEL}.plist"
WD_SCRIPT="${CONF_DIR}/watchdog.sh"
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
  local a
  a="$(ask "$1 (y/n)" "$2")"
  case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac
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

valid_permission() {
  case "$1" in default|acceptEdits|auto|bypassPermissions|plan|dontAsk) return 0 ;; *) return 1 ;; esac
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
      warn "Both will work, but this Mac will show up twice in the Claude app."
    fi
  done
}

# ---------- questions ----------
choose_folder() {
  local def="${FOLDER:-$HOME}" a
  say ""
  say "${B}1. Which folder should new sessions start in?${N}"
  say "   ${D}Claude can still work anywhere you point it; this is just where it starts.${N}"
  while :; do
    a="$(ask "   Folder:" "$(pretty "$def")")"
    a="$(expand_path "$a")"
    if [ -d "$a" ]; then FOLDER="$a"; break; fi
    err "That folder doesn't exist: $a"
    [ "$HAVE_TTY" = 1 ] || die "Pass an existing folder with --folder."
  done
}

choose_permission() {
  local cur="${PERMISSION:-default}" def=1 a
  case "$cur" in acceptEdits) def=2 ;; auto) def=3 ;; bypassPermissions) def=4 ;; esac
  say ""
  say "${B}2. How much can Claude do without asking you?${N}"
  say "   1) Ask before every change            ${D}safest, you approve each step in the app${N}"
  say "   2) Edit files freely                  ${D}asks before running commands${N}"
  say "   3) Auto                               ${D}Claude decides, asks only for risky actions${N}"
  say "   4) Full access, never asks            ${D}only if you know what this means${N}"
  while :; do
    a="$(ask "   Choose 1-4:" "$def")"
    case "$a" in
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
        else
          die "Full access can't be chosen without a confirmation. Pass --permission bypassPermissions --yes-full-access."
        fi
        ;;
      *) err "Please type 1, 2, 3 or 4." ; [ "$HAVE_TTY" = 1 ] || die "Invalid choice." ;;
    esac
  done
}

choose_awake() {
  local def="n"
  [ "${AWAKE:-no}" = "yes" ] && def="y"
  say ""
  say "${B}3. Keep this Mac awake while it's plugged in?${N}"
  say "   ${D}A sleeping Mac can't be reached from the app. This only works on the charger;${N}"
  say "   ${D}closing a laptop lid still puts it to sleep.${N}"
  if yes_no "   Keep awake?" "$def"; then AWAKE=yes; else AWAKE=no; fi
}

# ---------- service ----------
write_plist() {
  local path_env claude_dir prog
  claude_dir="$(dirname "$CLAUDE")"
  # The PATH from the Terminal running this script, so Claude finds git, node,
  # brew tools etc. the same way it does when you start it by hand.
  path_env="${claude_dir}:${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  prog=""
  if [ "$AWAKE" = "yes" ]; then
    prog="${prog}    <string>/usr/bin/caffeinate</string><string>-s</string>
"
  fi
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
write_watchdog() {
  mkdir -p "$CONF_DIR"
  cat >"$WD_SCRIPT" <<'WATCHDOG'
#!/bin/bash
# Claude Remote Control watchdog (https://github.com/A3zooz/claude-remote-control).
# Started every minute by launchd. Env: RC_LABEL, RC_CLAUDE, RC_LOG, RC_DRY_RUN.
set -u
DOMAIN="gui/$(id -u)"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$RC_LOG"; }
act() { if [ -n "${RC_DRY_RUN:-}" ]; then log "(dry run) would: $*"; else "$@"; fi; }

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
# With "keep awake" the service is caffeinate and the server is its child.
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
running="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
[ -n "$running" ] || exit 0
current="$(resolve "$RC_CLAUDE")"
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
  say ""
  say "  Common fixes:"
  say "   • Open Terminal, run ${B}cd \"$(pretty "$FOLDER")\" && claude${N} once, accept any prompt, then run this again."
  say "   • Remote Control may be turned off for your organization; ask your Claude admin."
  say "   • Run this again and choose ${B}Check it's working${N} for details."
}

# ---------- commands ----------
cmd_install() {
  # Reject bad options before touching anything.
  if [ -n "$ARG_FOLDER" ] && [ ! -d "$(expand_path "$ARG_FOLDER")" ]; then
    die "Folder doesn't exist: $(expand_path "$ARG_FOLDER")"
  fi
  if [ -n "$ARG_PERMISSION" ]; then
    valid_permission "$ARG_PERMISSION" || die "Unknown permission level: $ARG_PERMISSION (use default, acceptEdits, auto or bypassPermissions)"
    if [ "$ARG_PERMISSION" = "bypassPermissions" ] && [ "$ARG_YES_FULL" != 1 ]; then
      die "Full access needs --yes-full-access as well."
    fi
  fi

  step "Checking your Mac"
  check_mac
  check_claude
  check_login
  warn_other_servers

  load_config
  [ -n "$ARG_FOLDER" ] && FOLDER="$(expand_path "$ARG_FOLDER")"
  [ -n "$ARG_PERMISSION" ] && PERMISSION="$ARG_PERMISSION"
  [ -n "$ARG_AWAKE" ] && AWAKE="$ARG_AWAKE"

  [ -n "$ARG_FOLDER" ] || choose_folder
  [ -n "$ARG_PERMISSION" ] || choose_permission
  if [ -n "$ARG_AWAKE" ]; then
    case "$AWAKE" in y|yes|true|1) AWAKE=yes ;; *) AWAKE=no ;; esac
  else
    choose_awake
  fi

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
  say "  Stay awake:    ${AWAKE}"
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
  say "  Stay awake:    ${AWAKE:-no}"
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
  rm -rf "$CONF_DIR" "$LOG_DIR"; ok "Settings and logs removed"
  say ""
  say "  Claude Code itself is still installed. This Mac will drop out of the Claude app"
  say "  within a few minutes."
}

menu() {
  step "Claude Remote Control is already set up on this Mac"
  if [ -n "$(svc_pid)" ]; then ok "Running"; else warn "Installed but not running"; fi
  say ""
  say "   1) Check it's working"
  say "   2) Restart it"
  say "   3) Change settings (folder, permissions, stay awake)"
  say "   4) Remove it"
  say "   5) Nothing, exit"
  local a
  a="$(ask "   Choose 1-5:" "1")"
  case "$a" in
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
  say "                     --awake yes|no  --yes-full-access"
}

main() {
  CMD="" ARG_FOLDER="" ARG_PERMISSION="" ARG_AWAKE="" ARG_YES_FULL=0
  while [ $# -gt 0 ]; do
    case "$1" in
      install|status|restart|uninstall|menu) CMD="$1" ;;
      --folder) ARG_FOLDER="${2:-}"; shift ;;
      --permission) ARG_PERMISSION="${2:-}"; shift ;;
      --awake) ARG_AWAKE="${2:-}"; shift ;;
      --yes-full-access) ARG_YES_FULL=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) die "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done

  if [ -z "$CMD" ]; then
    if [ -f "$PLIST" ] && [ "$HAVE_TTY" = 1 ]; then CMD=menu; else CMD=install; fi
  fi
  if [ "$CMD" = install ] && [ "$HAVE_TTY" = 0 ] && { [ -z "$ARG_FOLDER" ] || [ -z "$ARG_PERMISSION" ]; }; then
    say "  ${D}No keyboard available; using defaults for anything not given as an option.${N}"
  fi

  case "$CMD" in
    install) cmd_install ;;
    status) cmd_status ;;
    restart) cmd_restart ;;
    uninstall) cmd_uninstall ;;
    menu) menu ;;
  esac
}

main "$@"
