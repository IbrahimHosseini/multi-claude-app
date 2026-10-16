#!/usr/bin/env bash
#
# claude-multi.sh — run several isolated Claude Desktop instances.
#
# Each profile gets its own Electron data directory (--user-data-dir), so it
# has its own login/account, settings, cache and claude_desktop_config.json
# (MCP servers). The regular Claude app keeps its default data directory, so
# it can stay "account 1" while a profile is "account 2" (or use two profiles).
#
#   macOS    profiles:  ~/Library/Application Support/Claude-Profiles/<name>
#            launchers: ~/Applications/Claude780 (<name>).app
#   Linux    profiles:  ~/.config/Claude-Profiles/<name>
#            launchers: ~/.local/share/applications/claude-multi-<name>.desktop
#   Windows  handled by claude-multi.ps1; this script hands off to it when it
#            runs in Git Bash or WSL.
#
# Run it without arguments for an interactive menu.
# Written for the bash 3.2 that ships with macOS.

set -eo pipefail

VERSION="2.0.0"
REPO_URL="https://github.com/IbrahimHosseini/multi-claude-app"
RAW_URL="${CLAUDE_MULTI_RAW_URL:-https://raw.githubusercontent.com/IbrahimHosseini/multi-claude-app/main}"
UA="claude-multi/$VERSION (+$REPO_URL)"

BUNDLE_ID="com.anthropic.claudefordesktop"
MAC_TEAM_ID="Q6L2SF6YDW"   # Anthropic PBC's Apple Developer ID
MAC_RELEASES_URL="https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
APT_REPO_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
LINUX_COMMUNITY_URL="https://github.com/aaddrick/claude-desktop-debian"

APP_LABEL="${CLAUDE_APP_LABEL:-Claude780}"
INSTALL_DIR="${CLAUDE_MULTI_BIN_DIR:-$HOME/.local/bin}"
ME="$(basename "$0")"
SELF="${BASH_SOURCE[0]:-$0}"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac

PLATFORM=""          # macos | linux | windows
WORK_DIR=""          # private temp dir, removed on exit
STEP_I=0 STEP_N=0 PLAN_T0=0
REPLY_INDEX=0 REPLY_VALUE="" MENU_PROFILE=""

# ------------------------------------------------------------------- UI ---

ui_init() {
  FANCY=0
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_ACCENT=""
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    FANCY=1
    C_RESET=$'\033[0m' C_BOLD=$'\033[1m' C_DIM=$'\033[2m'
    C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m'
    C_ACCENT=$'\033[38;5;173m'   # Claude's terracotta
  fi
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*)
      S_OK="✓" S_FAIL="✗" S_ARROW="❯" S_STAR="✻" S_ON="●" S_OFF="○" S_FULL="█" S_EMPTY="░"
      S_KEYS="↑/↓ move · enter select · q back"
      SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) ;;
    *)
      S_OK="+" S_FAIL="x" S_ARROW=">" S_STAR="*" S_ON="*" S_OFF="-" S_FULL="#" S_EMPTY="."
      S_KEYS="up/down move, enter select, q back"
      SPIN=('|' '/' '-' '\') ;;
  esac
  COLS="$(tput cols 2>/dev/null || echo 80)"
}

die()  { ui_cursor_show; printf '%s%s Error:%s %s\n' "$C_RED$C_BOLD" "$S_FAIL" "$C_RESET" "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
ok()   { printf '  %s%s%s %s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
hint() { printf '  %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

ui_cursor_hide() { if [[ $FANCY -eq 1 && -t 1 ]]; then printf '\033[?25l'; fi; }
ui_cursor_show() { if [[ ${FANCY:-0} -eq 1 && -t 1 ]]; then printf '\033[?25h'; fi; }
ui_clear()       { if [[ $FANCY -eq 1 ]]; then printf '\033[2J\033[H'; fi; }

ui_banner() {
  printf '\n  %s%s Claude Multi%s %sv%s · isolated Claude Desktop profiles%s\n\n' \
    "$C_ACCENT$C_BOLD" "$S_STAR" "$C_RESET" "$C_DIM" "$VERSION" "$C_RESET"
}

ui_pause() {
  if [[ -t 0 ]]; then
    printf '\n  %spress any key to continue%s' "$C_DIM" "$C_RESET"
    IFS= read -rsn1 _ || true
    printf '\n'
  fi
}

ui_bar() {  # ui_bar <percent> <width>  -> ██████░░░░
  local pct="$1" width="$2" fill i a="" b=""
  if (( pct < 0 )); then pct=0; elif (( pct > 100 )); then pct=100; fi
  fill=$(( pct * width / 100 ))
  for (( i = 0; i < fill; i++ )); do a+="$S_FULL"; done
  for (( i = fill; i < width; i++ )); do b+="$S_EMPTY"; done
  printf '%s%s%s%s%s' "$C_ACCENT" "$a" "$C_DIM" "$b" "$C_RESET"
}

human_size() {  # bytes -> "12.3 MB"
  local b="$1"
  if (( b >= 1073741824 )); then printf '%d.%d GB' $(( b / 1073741824 )) $(( b % 1073741824 * 10 / 1073741824 ))
  elif (( b >= 1048576 )); then printf '%d.%d MB' $(( b / 1048576 )) $(( b % 1048576 * 10 / 1048576 ))
  elif (( b >= 1024 )); then printf '%d KB' $(( b / 1024 ))
  else printf '%d B' "$b"
  fi
}

ui_input() {  # ui_input "Prompt" [default]  -> REPLY_VALUE
  local v=""
  printf '  %s?%s %s ' "$C_ACCENT" "$C_RESET" "$1"
  if [[ -n "${2:-}" ]]; then printf '%s(%s)%s ' "$C_DIM" "$2" "$C_RESET"; fi
  IFS= read -r v || v=""
  REPLY_VALUE="${v:-${2:-}}"
}

ui_confirm() {  # ui_confirm "Question" [y|n]  -> succeeds on yes
  local v="" def="${2:-n}" keys="y/N"
  if [[ "$def" == y ]]; then keys="Y/n"; fi
  printf '  %s?%s %s %s[%s]%s ' "$C_ACCENT" "$C_RESET" "$1" "$C_DIM" "$keys" "$C_RESET"
  IFS= read -r v || v=""
  case "${v:-$def}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ui_select "Question" <default index> <option>...  -> REPLY_INDEX (-1 = cancelled)
# Arrow keys (or j/k, or a digit) move, Enter picks. Falls back to a numbered
# prompt when there is no terminal.
ui_select() {
  local title="$1" sel="$2" n i key rest
  shift 2
  local -a opts=("$@")
  n=${#opts[@]}

  if [[ $FANCY -ne 1 || ! -t 0 ]]; then
    printf '  %s\n' "$title"
    for (( i = 0; i < n; i++ )); do printf '    %d) %s\n' $(( i + 1 )) "${opts[i]}"; done
    ui_input "Choose 1-$n" $(( sel + 1 ))
    REPLY_INDEX=-1
    if [[ "$REPLY_VALUE" =~ ^[0-9]+$ ]] && (( REPLY_VALUE >= 1 && REPLY_VALUE <= n )); then
      REPLY_INDEX=$(( REPLY_VALUE - 1 ))
    fi
    return 0
  fi

  printf '  %s?%s %s%s%s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$title" "$C_RESET"
  ui_cursor_hide
  while :; do
    for (( i = 0; i < n; i++ )); do
      if (( i == sel )); then
        printf '\033[K  %s%s %s%s\n' "$C_ACCENT$C_BOLD" "$S_ARROW" "${opts[i]}" "$C_RESET"
      else
        printf '\033[K    %s\n' "${opts[i]}"
      fi
    done
    printf '\033[K  %s%s%s' "$C_DIM" "$S_KEYS" "$C_RESET"
    key=""
    IFS= read -rsn1 key || key=q
    case "$key" in
      $'\033')
        rest=""
        IFS= read -rsn2 -t 1 rest || true
        case "$rest" in
          '[A'|'OA') sel=$(( (sel - 1 + n) % n )) ;;
          '[B'|'OB') sel=$(( (sel + 1) % n )) ;;
          '') sel=-1; break ;;
        esac ;;
      k) sel=$(( (sel - 1 + n) % n )) ;;
      j) sel=$(( (sel + 1) % n )) ;;
      '') break ;;
      q|Q) sel=-1; break ;;
      [1-9]) if (( key <= n )); then sel=$(( key - 1 )); fi ;;
    esac
    printf '\r\033[%dA' "$n"
  done

  # Collapse the list into a one-line answer.
  printf '\r\033[%dA\033[J' $(( n + 1 ))
  if (( sel >= 0 )); then
    printf '  %s%s%s %s %s%s%s\n' "$C_GREEN" "$S_OK" "$C_RESET" "$title" "$C_ACCENT" "${opts[sel]}" "$C_RESET"
  else
    printf '  %s- %s (cancelled)%s\n' "$C_DIM" "$title" "$C_RESET"
  fi
  ui_cursor_show
  REPLY_INDEX=$sel
}

# --------------------------------------------------------- steps & plans ---
#
# A plan is a titled list of steps with an overall progress bar. Each step
# runs in a background subshell (with errexit) while the foreground draws a
# spinner; its output goes to a log that is shown only if it fails. Steps
# hand values back through state files (state_set / state_get).

work_dir_init() {
  if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/claude-multi.XXXXXX")"
  fi
}
state_set()   { printf '%s' "$2" > "$WORK_DIR/state.$1"; }
state_get()   { cat "$WORK_DIR/state.$1" 2>/dev/null || true; }
step_detail() { state_set detail "$*"; }

plan_begin() {  # plan_begin "Title" <steps>
  STEP_I=0 STEP_N="$2" PLAN_T0=$SECONDS
  printf '\n  %s%s%s\n\n' "$C_BOLD" "$1" "$C_RESET"
}
plan_add() { STEP_N=$(( STEP_N + $1 )); }

plan_end() {  # plan_end "Message"
  if [[ $FANCY -eq 1 ]]; then
    printf '\n  %s %s100%%%s' "$(ui_bar 100 30)" "$C_BOLD" "$C_RESET"
  fi
  printf '\n  %s%s %s%s %s(%ss)%s\n' "$C_GREEN$C_BOLD" "$S_OK" "$1" "$C_RESET" \
    "$C_DIM" $(( SECONDS - PLAN_T0 )) "$C_RESET"
}

step_line() {  # step_line <symbol> <label> <percent> <extra>, kept to one terminal row
  local width=10 room
  if (( COLS < 64 )); then width=0; fi
  room=$(( COLS - 35 - (width > 0 ? width + 5 : 0) ))
  if (( room < 0 )); then room=0; fi
  printf '\r\033[K  %s%s%s %-28s ' "$C_ACCENT" "$1" "$C_RESET" "${2:0:28}"
  if (( width > 0 )); then printf '%s %3d%%' "$(ui_bar "$3" "$width")" "$3"; fi
  printf '  %s%s%s' "$C_DIM" "${4:0:$room}" "$C_RESET"
}

step_start() {
  STEP_I=$(( STEP_I + 1 ))
  if (( STEP_N < STEP_I )); then STEP_N=$STEP_I; fi
  rm -f "$WORK_DIR/state.detail"
  STEP_LOG="$WORK_DIR/step.$STEP_I.log"
  : > "$STEP_LOG"
}

step_finish() {  # step_finish <label> <exit code>
  local detail
  detail="$(state_get detail)"
  if [[ $FANCY -eq 1 ]]; then printf '\r\033[K'; fi
  if [[ "$2" -eq 0 ]]; then
    printf '  %s%s%s %s' "$C_GREEN" "$S_OK" "$C_RESET" "$1"
    if [[ -n "$detail" ]]; then printf '  %s%s%s' "$C_DIM" "$detail" "$C_RESET"; fi
    printf '\n'
  else
    printf '  %s%s %s%s\n' "$C_RED$C_BOLD" "$S_FAIL" "$1" "$C_RESET"
    if [[ -s "$STEP_LOG" ]]; then tail -n 12 "$STEP_LOG" | sed 's/^/      /' >&2; fi
  fi
  ui_cursor_show
}

step() {  # step "Label" command [args...]
  local label="$1" pid rc=0 f=0
  shift
  step_start
  ( "$@" ) </dev/null >"$STEP_LOG" 2>&1 &
  pid=$!
  if [[ $FANCY -eq 1 ]]; then
    ui_cursor_hide
    while kill -0 "$pid" 2>/dev/null; do
      step_line "${SPIN[f % ${#SPIN[@]}]}" "$label" $(( ( (STEP_I - 1) * 100 ) / STEP_N )) "[$STEP_I/$STEP_N]"
      f=$(( f + 1 ))
      sleep 0.1
    done
  fi
  wait "$pid" || rc=$?
  step_finish "$label" "$rc"
  return "$rc"
}

step_download() {  # step_download "Label" <url> <dest> [sha256]
  local label="$1" url="$2" dest="$3" sum="${4:-}" total pid rc=0 f=0 got pct extra t0=$SECONDS el actual
  step_start
  total="$(remote_size "$url")"
  rm -f "$dest"
  ( curl -fL -sS --retry 2 --connect-timeout 20 -A "$UA" -o "$dest" "$url" ) </dev/null >"$STEP_LOG" 2>&1 &
  pid=$!
  if [[ $FANCY -eq 1 ]]; then
    ui_cursor_hide
    while kill -0 "$pid" 2>/dev/null; do
      got=0
      if [[ -f "$dest" ]]; then got="$(file_size "$dest")"; fi
      el=$(( SECONDS - t0 ))
      pct=0 extra="$(human_size "$got")"
      if (( total > 0 )); then
        pct=$(( got * 100 / total ))
        extra="$extra / $(human_size "$total")"
      fi
      if (( el > 0 )); then extra="$extra  $(human_size $(( got / el )))/s"; fi
      step_line "${SPIN[f % ${#SPIN[@]}]}" "$label" "$pct" "$extra"
      f=$(( f + 1 ))
      sleep 0.2
    done
  fi
  wait "$pid" || rc=$?
  if [[ $rc -eq 0 && -n "$sum" ]]; then
    actual="$(sha256_of "$dest")"
    if [[ "$actual" != "$sum" ]]; then
      printf 'Checksum mismatch.\n  expected %s\n  got      %s\n' "$sum" "$actual" >> "$STEP_LOG"
      rc=1
    fi
  fi
  if [[ $rc -eq 0 ]]; then
    step_detail "$(human_size "$(file_size "$dest")")${sum:+, SHA-256 verified}"
  fi
  step_finish "$label" "$rc"
  return "$rc"
}

file_size() { wc -c < "$1" | tr -d ' '; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{ print $1 }'
  else shasum -a 256 "$1" | awk '{ print $1 }'; fi
}
remote_size() {  # total size of a download in bytes (0 if unknown)
  curl -sSL -A "$UA" --connect-timeout 15 -r 0-0 -D - -o /dev/null "$1" 2>/dev/null | tr -d '\r' |
    awk 'tolower($1) == "content-range:" { n = split($NF, a, "/"); s = a[n] }
         END { print (s ~ /^[0-9]+$/) ? s : 0 }'
}

version_ge() {  # version_ge <a> <b>  -> succeeds when a >= b
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, /[.-]/); nb = split(b, y, /[.-]/); n = na > nb ? na : nb
    for (i = 1; i <= n; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
    exit 0 }'
}

# ------------------------------------------------------------- platform ---

detect_platform() {
  case "$(uname -s 2>/dev/null)" in
    Darwin) echo macos ;;
    Linux)
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then echo wsl; else echo linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) echo windows ;;
    *) echo unknown ;;
  esac
}
HOST_OS="$(detect_platform)"

platform_name() {
  case "$1" in
    macos) echo macOS ;; linux) echo Linux ;; windows) echo Windows ;;
    wsl) echo "Windows (WSL)" ;; *) echo "$1" ;;
  esac
}

normalize_platform() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    "") echo "" ;;
    mac|macos|osx|darwin) echo macos ;;
    linux) echo linux ;;
    win|windows) echo windows ;;
    *) die "unknown platform '$1' (use macos, linux or windows)" ;;
  esac
}

default_platform() {
  if [[ "$HOST_OS" == wsl ]]; then echo windows; else echo "$HOST_OS"; fi
}

platform_setup() {  # set the paths for $PLATFORM; refuse one this machine can't run
  case "$PLATFORM" in
    macos)
      [[ "$HOST_OS" == macos ]] ||
        die "macOS was selected, but this machine runs $(platform_name "$HOST_OS")."
      DEFAULT_DATA_DIR="$HOME/Library/Application Support/Claude"
      PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/Library/Application Support/Claude-Profiles}"
      LAUNCHERS_DIR="${CLAUDE_LAUNCHERS_DIR:-$HOME/Applications}" ;;
    linux)
      [[ "$HOST_OS" == linux || "$HOST_OS" == wsl ]] ||
        die "Linux was selected, but this machine runs $(platform_name "$HOST_OS")."
      DEFAULT_DATA_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/Claude"
      PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/Claude-Profiles}"
      LAUNCHERS_DIR="${CLAUDE_LAUNCHERS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}" ;;
    *) die "unsupported platform '$PLATFORM' (this machine: $(platform_name "$HOST_OS"))" ;;
  esac
}

# Windows is handled by claude-multi.ps1. From Git Bash or WSL, hand over to it.
run_windows() {
  local ps1 shell="" sh winpath
  [[ "$HOST_OS" == windows || "$HOST_OS" == wsl ]] ||
    die "Windows was selected, but this machine runs $(platform_name "$HOST_OS"). Run claude-multi.ps1 (or claude-multi.cmd) on the Windows PC."
  ps1="$(dirname "$SELF")/claude-multi.ps1"
  if [[ ! -f "$ps1" ]]; then
    info "claude-multi.ps1 is not next to this script; downloading it from GitHub..."
    curl -fsSL -A "$UA" -o "$ps1" "$RAW_URL/claude-multi.ps1" || die "could not download claude-multi.ps1"
  fi
  for sh in powershell.exe pwsh.exe; do
    if command -v "$sh" >/dev/null 2>&1; then shell="$sh"; break; fi
  done
  [[ -n "$shell" ]] || die "PowerShell (powershell.exe) was not found on PATH."
  if command -v cygpath >/dev/null 2>&1; then winpath="$(cygpath -w "$ps1")"
  elif command -v wslpath >/dev/null 2>&1; then winpath="$(wslpath -w "$ps1")"
  else winpath="$ps1"; fi
  exec "$shell" -NoProfile -ExecutionPolicy Bypass -File "$winpath" "$@"
}

# -------------------------------------------------------- the Claude app ---

# Print the Claude app (macOS: the .app bundle, Linux: the executable).
locate_app() {
  local p
  if [[ -n "${CLAUDE_APP_PATH:-}" ]]; then
    if [[ -e "$CLAUDE_APP_PATH" ]]; then printf '%s\n' "$CLAUDE_APP_PATH"; return 0; fi
    return 1
  fi
  if [[ "$PLATFORM" == macos ]]; then
    for p in "/Applications/Claude.app" "$HOME/Applications/Claude.app"; do
      if [[ -d "$p" ]]; then printf '%s\n' "$p"; return 0; fi
    done
    p="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | sed -n 1p || true)"
    if [[ -n "$p" && -d "$p" ]]; then printf '%s\n' "$p"; return 0; fi
    return 1
  fi
  # Linux: Anthropic's official package first, then community builds.
  for p in /usr/bin/claude-desktop /usr/lib/claude-desktop/claude-desktop \
           "$(command -v claude-desktop 2>/dev/null || true)" \
           /usr/bin/claude-desktop-unofficial \
           "$(command -v claude-desktop-unofficial 2>/dev/null || true)" \
           "$HOME"/Applications/claude-desktop*.AppImage \
           "$HOME"/.local/bin/claude-desktop*.AppImage \
           "$HOME"/Downloads/claude-desktop*.AppImage; do
    if [[ -n "$p" && -f "$p" && -x "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
}

find_app() {
  local p
  if p="$(locate_app)"; then printf '%s\n' "$p"; return 0; fi
  if [[ -n "${CLAUDE_APP_PATH:-}" ]]; then die "CLAUDE_APP_PATH not found: $CLAUDE_APP_PATH"; fi
  die "Claude Desktop not found. Install it with '$ME install-claude' or set CLAUDE_APP_PATH."
}

app_version() {  # print the installed version of the given app, if known
  local app="$1" pkg=claude-desktop
  if [[ "$PLATFORM" == macos ]]; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || true
    return 0
  fi
  case "$app" in
    *.AppImage) printf '%s\n' "${app##*/}" | sed -n 's/^claude-desktop[a-z-]*-\([0-9][0-9.]*[0-9]\).*/\1/p'; return 0 ;;
    *unofficial*) pkg=claude-desktop-unofficial ;;
  esac
  dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || rpm -q --qf '%{VERSION}' "$pkg" 2>/dev/null || true
}

ps_all() {
  if [[ "$HOST_OS" == macos ]]; then ps -axww -o pid=,command=; else ps -eww -o pid=,args=; fi
}

# Print the PID of the main Claude process using the given data dir (or nothing).
# The needle goes through the environment so awk's own command line can't match.
main_pid() {
  ps_all | NEEDLE="--user-data-dir=$1" PLAT="$PLATFORM" awk '
    found { next }
    {
      n = ENVIRON["NEEDLE"]; i = index($0, n)
      if (i == 0) next
      c = substr($0, i + length(n), 1)          # avoid "work" matching "work2"
      if (c != "" && c != " ") next
      if (index($0, "--type=") > 0) next        # Electron helper processes
      if (ENVIRON["PLAT"] == "macos") {
        if (index($0, "/Contents/Frameworks/") > 0) next
        if (index($0, "/Contents/MacOS/") == 0) next
      } else if ($2 ~ /(^|\/)(ba|da|z)?sh$/) next   # wrapper shell scripts
      print $1; found = 1
    }'
}

running_app_pids() {  # main PIDs of every running Claude instance (any profile)
  ps_all | APP="$1" PLAT="$PLATFORM" awk '
    index($0, "--type=") > 0 { next }
    ENVIRON["PLAT"] == "macos" { if (index($0, ENVIRON["APP"] "/Contents/MacOS/") > 0) print $1; next }
    $2 ~ /(^|\/)claude-desktop(-unofficial)?$/ || index($2, ENVIRON["APP"]) == 1 { print $1 }'
}

focus_pid() {
  local win
  case "$PLATFORM" in
    macos)
      osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" \
        >/dev/null 2>&1 || true ;;
    linux)
      if command -v wmctrl >/dev/null 2>&1; then
        win="$(wmctrl -lp 2>/dev/null | awk -v p="$1" '$3 == p && !w { w = $1 } END { print w }')"
        if [[ -n "$win" ]]; then wmctrl -i -a "$win" >/dev/null 2>&1 || true; fi
      fi ;;
  esac
}

launch_app() {  # launch_app <app> <data dir>
  if [[ "$PLATFORM" == macos ]]; then
    open -n -a "$1" --args "--user-data-dir=$2"
  else
    nohup "$1" "--user-data-dir=$2" >/dev/null 2>&1 &
  fi
  step_detail "$1"
}

open_in_editor() {
  if [[ "$PLATFORM" == macos ]]; then
    open -t "$1"
  elif [[ -t 0 && -n "${VISUAL:-${EDITOR:-}}" ]]; then
    "${VISUAL:-$EDITOR}" "$1"
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1 &
  elif [[ -t 0 ]]; then
    if command -v nano >/dev/null 2>&1; then nano "$1"; else vi "$1"; fi
  fi
}

# ------------------------------------------------------------- launchers ---

validate_name() {
  [[ -n "$1" ]] || die "a profile name is required (see: $ME help)"
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid name '$1' (use letters, digits, . _ -)"
  [[ "$1" != "." && "$1" != ".." ]] || die "invalid name '$1'"
}

profile_dir() { printf '%s/%s\n' "$PROFILES_ROOT" "$1"; }

launcher_path() {
  if [[ "$PLATFORM" == macos ]]; then
    printf '%s/%s (%s).app\n' "$LAUNCHERS_DIR" "$APP_LABEL" "$1"
  else
    printf '%s/claude-multi-%s.desktop\n' "$LAUNCHERS_DIR" "$1"
  fi
}

make_launcher() {  # make_launcher <name> <app> <data dir>
  if [[ "$PLATFORM" == macos ]]; then make_launcher_macos "$@"; else make_launcher_linux "$@"; fi
}

make_launcher_macos() {
  local name="$1" app="$2" dir="$3" bundle icon exe safe_id
  bundle="$(launcher_path "$name")"
  exe="$bundle/Contents/MacOS/launch"
  rm -rf "$bundle"
  mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

  # Reuse Claude's own icon.
  icon="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ -n "$icon" && "$icon" != *.icns ]]; then icon="$icon.icns"; fi
  if [[ -n "$icon" && -f "$app/Contents/Resources/$icon" ]]; then
    cp "$app/Contents/Resources/$icon" "$bundle/Contents/Resources/AppIcon.icns"
  fi

  safe_id="$(printf '%s' "$name" | tr -c 'A-Za-z0-9.-' '-')"
  cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_LABEL ($name)</string>
  <key>CFBundleDisplayName</key><string>$APP_LABEL ($name)</string>
  <key>CFBundleIdentifier</key><string>local.claude-multi.$safe_id</string>
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

  # Self-contained launcher: works even if this script is moved or deleted.
  {
    printf '#!/bin/bash\n'
    printf '# Generated by claude-multi.sh: launches Claude with profile "%s".\n' "$name"
    printf 'APP=%q\n' "$app"
    printf 'DATA=%q\n' "$dir"
    cat <<'EOF'
PID="$(/bin/ps -axww -o pid=,command= | NEEDLE="--user-data-dir=$DATA" /usr/bin/awk '
  found { next }
  { n = ENVIRON["NEEDLE"]; i = index($0, n); if (i == 0) next
    c = substr($0, i + length(n), 1); if (c != "" && c != " ") next
    if (index($0, "--type=") > 0) next
    if (index($0, "/Contents/Frameworks/") > 0) next
    if (index($0, "/Contents/MacOS/") == 0) next
    print $1; found = 1 }')"
if [ -n "$PID" ]; then
  /usr/bin/osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null 2>&1
  exit 0
fi
if [ ! -d "$APP" ]; then
  APP="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" | /usr/bin/head -n1)"
fi
/bin/mkdir -p "$DATA"
exec /usr/bin/open -n -a "$APP" --args "--user-data-dir=$DATA"
EOF
  } > "$exe"
  chmod +x "$exe"

  touch "$bundle"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$bundle" >/dev/null 2>&1 || true
  step_detail "$bundle"
}

desktop_quote() {  # quote one argument for a .desktop Exec= line
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g' -e 's/%/%%/g')"
}

linux_icon() {
  local f
  for f in /usr/share/icons/hicolor/256x256/apps/claude-desktop.png \
           /usr/share/icons/hicolor/*/apps/claude-desktop*.png \
           /usr/share/pixmaps/claude-desktop*.png \
           "$HOME"/.local/share/icons/hicolor/*/apps/claude-desktop*.png; do
    if [[ -f "$f" ]]; then printf '%s\n' "$f"; return 0; fi
  done
  printf 'claude-desktop\n'
}

make_launcher_linux() {
  local name="$1" app="$2" dir="$3" file
  file="$(launcher_path "$name")"
  mkdir -p "$LAUNCHERS_DIR"
  cat > "$file" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=$APP_LABEL ($name)
Comment=Claude Desktop with the "$name" profile (claude-multi)
Exec=$(desktop_quote "$app") $(desktop_quote "--user-data-dir=$dir")
Icon=$(linux_icon)
Terminal=false
Categories=Office;Utility;
StartupNotify=true
X-Claude-Multi-Profile=$name
EOF
  chmod +x "$file"
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$LAUNCHERS_DIR" >/dev/null 2>&1 || true
  fi
  step_detail "$file"
}

# ----------------------------------------------------------------- tasks ---
# Run through `step`, i.e. in a background subshell with errexit on.

task_find_app() {
  local app ver
  app="$(find_app)"
  ver="$(app_version "$app")"
  state_set app "$app"
  step_detail "$app${ver:+ (v$ver)}"
}

task_make_dir() {
  if [[ -d "$1" ]]; then
    step_detail "already exists"
  else
    mkdir -p "$1"
    step_detail "$1"
  fi
}

task_copy_config() {
  if [[ -f "$1/claude_desktop_config.json" ]]; then
    step_detail "the profile already has a config; kept it"
  elif [[ -f "$DEFAULT_DATA_DIR/claude_desktop_config.json" ]]; then
    cp "$DEFAULT_DATA_DIR/claude_desktop_config.json" "$1/"
    step_detail "from the regular Claude app"
  else
    step_detail "the regular Claude app has no config to copy"
  fi
}

task_wait_running() {  # wait until a profile's main process shows up
  local i pid
  for (( i = 0; i < 60; i++ )); do
    pid="$(main_pid "$1")"
    if [[ -n "$pid" ]]; then step_detail "pid $pid"; return 0; fi
    sleep 0.5
  done
  echo "Claude did not start within 30 seconds." >&2
  return 1
}

task_quit_pids() {  # ask processes to quit, wait up to 15s
  local pid i alive
  kill -TERM "$@" 2>/dev/null || true
  for (( i = 0; i < 30; i++ )); do
    alive=0
    for pid in "$@"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; fi
    done
    if (( alive == 0 )); then step_detail "closed pid $*"; return 0; fi
    sleep 0.5
  done
  echo "Still running after 15s. Quit Claude manually (or: kill -9 $*), then retry." >&2
  return 1
}

task_refresh_launchers() {  # rebuild existing launchers so they point at the app
  local app="$1" d name n=0
  if [[ -d "$PROFILES_ROOT" ]]; then
    for d in "$PROFILES_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      d="${d%/}"
      name="${d##*/}"
      if [[ -e "$(launcher_path "$name")" ]]; then
        make_launcher "$name" "$app" "$d"
        n=$(( n + 1 ))
      fi
    done
  fi
  step_detail "$n launcher(s) updated"
}

# -------------------------------------------------------------- profiles ---

cmd_create() {
  local name="" copy=0 arg app dir
  for arg in "$@"; do
    case "$arg" in
      --copy-config) copy=1 ;;
      -*) die "unknown option '$arg'" ;;
      *) [[ -z "$name" ]] || die "unexpected argument '$arg'"; name="$arg" ;;
    esac
  done
  validate_name "$name"
  dir="$(profile_dir "$name")"
  [[ "$dir" != "$DEFAULT_DATA_DIR" ]] || die "refusing to use the default Claude data directory"

  plan_begin "Creating profile '$name'" $(( 3 + copy ))
  step "Find Claude Desktop" task_find_app
  app="$(state_get app)"
  step "Create profile folder" task_make_dir "$dir"
  if [[ $copy -eq 1 ]]; then
    step "Copy MCP config" task_copy_config "$dir"
  fi
  step "Build launcher" make_launcher "$name" "$app" "$dir"
  plan_end "Profile '$name' is ready"
  hint "Start it with:  $ME start $name"
  if [[ "$PLATFORM" == macos ]]; then
    hint "or open '$APP_LABEL ($name)' from Launchpad / ~/Applications."
  else
    hint "or open '$APP_LABEL ($name)' from your applications menu."
  fi
}

cmd_start() {
  local name="${1:-}" app dir pid
  validate_name "$name"
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || die "profile '$name' does not exist. Run: $ME create $name"
  pid="$(main_pid "$dir")"
  if [[ -n "$pid" ]]; then
    ok "Profile '$name' is already running (pid $pid); bringing it to front."
    focus_pid "$pid"
    return 0
  fi
  plan_begin "Starting profile '$name'" 3
  step "Find Claude Desktop" task_find_app
  app="$(state_get app)"
  step "Launch Claude" launch_app "$app" "$dir"
  step "Wait for it to start" task_wait_running "$dir"
  plan_end "Profile '$name' is running"
}

cmd_stop() {
  local name="${1:-}" dir pid
  validate_name "$name"
  dir="$(profile_dir "$name")"
  pid="$(main_pid "$dir")"
  if [[ -z "$pid" ]]; then
    ok "Profile '$name' is not running."
    return 0
  fi
  plan_begin "Stopping profile '$name'" 1
  step "Quit Claude (pid $pid)" task_quit_pids "$pid"
  plan_end "Stopped profile '$name'"
}

cmd_list() {
  local d name pid found=0
  printf '\n  %sProfiles%s %sin %s%s\n\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$PROFILES_ROOT" "$C_RESET"
  if [[ -d "$PROFILES_ROOT" ]]; then
    for d in "$PROFILES_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      d="${d%/}"
      name="${d##*/}"
      found=1
      pid="$(main_pid "$d")"
      if [[ -n "$pid" ]]; then
        printf '  %s%s%s %-20s %srunning%s %s(pid %s)%s\n' "$C_GREEN" "$S_ON" "$C_RESET" "$name" \
          "$C_GREEN" "$C_RESET" "$C_DIM" "$pid" "$C_RESET"
      else
        printf '  %s%s %-20s stopped%s\n' "$C_DIM" "$S_OFF" "$name" "$C_RESET"
      fi
    done
  fi
  if [[ $found -eq 0 ]]; then
    hint "(none yet; create one with: $ME create <name>)"
  fi
}

cmd_config() {
  local name="${1:-}" dir cfg
  validate_name "$name"
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || die "profile '$name' does not exist. Run: $ME create $name"
  cfg="$dir/claude_desktop_config.json"
  if [[ ! -f "$cfg" ]]; then
    printf '{\n  "mcpServers": {}\n}\n' > "$cfg"
  fi
  open_in_editor "$cfg"
  ok "Editing: $cfg"
  hint "After saving, restart the profile:  $ME stop $name && $ME start $name"
}

cmd_remove() {
  local name="" yes=0 arg dir bundle pid
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) yes=1 ;;
      -*) die "unknown option '$arg'" ;;
      *) [[ -z "$name" ]] || die "unexpected argument '$arg'"; name="$arg" ;;
    esac
  done
  validate_name "$name"
  dir="$(profile_dir "$name")"
  bundle="$(launcher_path "$name")"
  [[ -d "$dir" || -e "$bundle" ]] || die "profile '$name' does not exist"

  if [[ $yes -eq 0 ]]; then
    if ! ui_confirm "Delete the launcher and ALL local data (login, settings, cache, config) for '$name'?" n; then
      info "  Cancelled."
      return 0
    fi
  fi
  pid="$(main_pid "$dir")"
  plan_begin "Removing profile '$name'" 2
  if [[ -n "$pid" ]]; then
    plan_add 1
    step "Quit Claude (pid $pid)" task_quit_pids "$pid"
  fi
  step "Remove launcher" rm -rf "$bundle"
  step "Delete profile data" rm -rf "$dir"
  plan_end "Removed profile '$name'"
}

# --------------------------------------------------------- Claude itself ---

cmd_install_claude() {
  local force=0 arg
  for arg in "$@"; do
    case "$arg" in
      --force|-f) force=1 ;;
      *) die "unknown option '$arg'" ;;
    esac
  done
  if [[ "$PLATFORM" == macos ]]; then install_claude_macos "$force"; else install_claude_linux "$force"; fi
}

task_mac_latest() {  # read Anthropic's release feed
  local json latest url
  json="$(curl -fsSL -A "$UA" --connect-timeout 20 "$MAC_RELEASES_URL")"
  latest="$(printf '%s' "$json" | sed -n 's/.*"currentRelease":"\([^"]*\)".*/\1/p')"
  url="$(printf '%s' "$json" | tr ',' '\n' | sed -n 's/.*"url":"\([^"]*\.zip\)".*/\1/p' |
         awk -v v="/$latest/" 'index($0, v) && !u { u = $0 } END { print u }')"
  if [[ -z "$latest" || -z "$url" ]]; then
    echo "Could not read the release feed: $MAC_RELEASES_URL" >&2
    return 1
  fi
  state_set latest "$latest"
  state_set url "$url"
  step_detail "latest v$latest${1:+, installed v$1}"
}

task_unzip() {  # task_unzip <zip> <dir>
  rm -rf "$2"
  mkdir -p "$2"
  ditto -x -k "$1" "$2"
  [[ -d "$2/Claude.app" ]] || { echo "Claude.app is missing from the download" >&2; return 1; }
  rm -f "$1"
}

task_mac_verify() {
  local app="$1" id team
  codesign --verify --deep --strict "$app"
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [[ "$id" == "$BUNDLE_ID" ]] || { echo "unexpected bundle id: $id" >&2; return 1; }
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team" == "$MAC_TEAM_ID" ]] || { echo "unexpected signer: ${team:-none}" >&2; return 1; }
  step_detail "signed by Anthropic PBC ($team)"
}

task_mac_install() {  # task_mac_install <new app> <destination>
  local src="$1" dst="$2" old="$2.claude-multi-old"
  mkdir -p "$(dirname "$dst")"
  rm -rf "$old"
  if [[ -d "$dst" ]]; then mv "$dst" "$old"; fi
  if ! { mv "$src" "$dst" 2>/dev/null || ditto "$src" "$dst"; }; then
    rm -rf "$dst"
    if [[ -d "$old" ]]; then mv "$old" "$dst"; fi
    echo "Could not write $dst; the previous version was kept." >&2
    return 1
  fi
  rm -rf "$old"
  touch "$dst"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$dst" >/dev/null 2>&1 || true
  step_detail "$dst"
}

quit_running_claude() {  # quit_running_claude <app>: confirm, then close every instance
  local pids
  pids="$(running_app_pids "$1" | tr '\n' ' ')"
  pids="${pids% }"
  if [[ -z "$pids" ]]; then return 0; fi
  warn "Claude is running (pid $pids). It has to quit before it can be updated."
  ui_confirm "Quit every running Claude window now?" y || die "cancelled; nothing was changed"
  plan_add 1
  # shellcheck disable=SC2086
  step "Quit Claude" task_quit_pids $pids
}

install_claude_macos() {
  local force="$1" app current="" latest url target zip
  app="$(locate_app || true)"
  if [[ -n "$app" ]]; then current="$(app_version "$app")"; fi
  target="${app:-/Applications/Claude.app}"
  if [[ -z "$app" && ! -w /Applications ]]; then target="$HOME/Applications/Claude.app"; fi

  plan_begin "Claude Desktop for macOS" 6
  step "Check for the latest version" task_mac_latest "$current"
  latest="$(state_get latest)"
  url="$(state_get url)"
  if [[ -n "$current" && $force -eq 0 ]] && version_ge "$current" "$latest"; then
    plan_end "Claude v$current is up to date"
    return 0
  fi
  zip="$WORK_DIR/Claude-$latest.zip"
  step_download "Download Claude v$latest" "$url" "$zip"
  step "Unpack" task_unzip "$zip" "$WORK_DIR/unpacked"
  step "Verify the signature" task_mac_verify "$WORK_DIR/unpacked/Claude.app"
  quit_running_claude "$target"
  step "Install" task_mac_install "$WORK_DIR/unpacked/Claude.app" "$target"
  step "Refresh profile launchers" task_refresh_launchers "$target"
  if [[ -n "$current" ]]; then
    plan_end "Claude updated: v$current -> v$latest"
  else
    plan_end "Claude v$latest installed"
  fi
}

task_deb_latest() {  # task_deb_latest <arch> [installed version]
  local packages best
  packages="$(curl -fsSL -A "$UA" --connect-timeout 20 "$APT_REPO_URL/dists/stable/main/binary-$1/Packages")"
  best="$(printf '%s\n\n' "$packages" | awk '
    /^Package: /  { p = $2 }  /^Version: / { v = $2 }
    /^Filename: / { f = $2 }  /^SHA256: /  { s = $2 }
    /^$/ { if (p == "claude-desktop" && v != "") print v, f, s; p = v = f = s = "" }' |
    sort -k1,1V | tail -n 1)"
  if [[ -z "$best" ]]; then
    echo "No claude-desktop package for $1 in $APT_REPO_URL" >&2
    return 1
  fi
  # shellcheck disable=SC2086
  set -- $best "${2:-}"
  state_set latest "$1"
  state_set file "$2"
  state_set sha "$3"
  step_detail "latest v$1${4:+, installed v$4}"
}

task_apt_install() {
  local sudo=""
  if [[ $EUID -ne 0 ]]; then sudo="sudo -n"; fi
  $sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
  step_detail "$(dpkg-query -W -f='claude-desktop ${Version}' claude-desktop 2>/dev/null || true)"
}

install_claude_linux() {
  local force="$1" arch current latest deb
  if ! command -v dpkg >/dev/null 2>&1 || ! command -v apt-get >/dev/null 2>&1; then
    warn "Automatic install needs Debian or Ubuntu (dpkg + apt)."
    hint "Anthropic ships an official .deb. For Fedora, Arch, AppImage and other"
    hint "distros, use the community builds: $LINUX_COMMUNITY_URL"
    return 1
  fi
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) die "there is no Claude Desktop build for '$arch' (only amd64 and arm64)" ;;
  esac
  current="$(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || true)"

  plan_begin "Claude Desktop for Linux" 4
  step "Check for the latest version" task_deb_latest "$arch" "$current"
  latest="$(state_get latest)"
  if [[ -n "$current" && $force -eq 0 ]] && version_ge "$current" "$latest"; then
    plan_end "Claude v$current is up to date"
    return 0
  fi
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "sudo is needed to install packages"
    hint "Administrator rights are needed to install the package:"
    sudo -v || die "sudo authentication failed"
  fi
  deb="$WORK_DIR/$(basename "$(state_get file)")"
  step_download "Download Claude v$latest" "$APT_REPO_URL/$(state_get file)" "$deb" "$(state_get sha)"
  quit_running_claude "/usr/lib/claude-desktop/claude-desktop"
  step "Install the package (apt)" task_apt_install "$deb"
  step "Refresh profile launchers" task_refresh_launchers "$(locate_app || echo /usr/bin/claude-desktop)"
  if [[ -n "$current" ]]; then
    plan_end "Claude updated: v$current -> v$latest"
  else
    plan_end "Claude v$latest installed"
  fi
}

# ------------------------------------------------------------- this tool ---

shell_rc_file() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [[ "$HOST_OS" == macos ]]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    fish) echo "" ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

task_copy_self() {  # copy this script to <dest> without touching a running copy in place
  if [[ "$SELF" -ef "$1" ]]; then
    step_detail "already installed here"
    return 0
  fi
  cp "$SELF" "$1.new.$$"
  chmod 755 "$1.new.$$"
  mv -f "$1.new.$$" "$1"
  step_detail "$1"
}

cmd_install_self() {
  local dest="$INSTALL_DIR/claude-multi" rc
  plan_begin "Installing claude-multi" 2
  step "Create $INSTALL_DIR" mkdir -p "$INSTALL_DIR"
  if [[ -f "$SELF" ]]; then
    step "Copy the script" task_copy_self "$dest"
  else
    step_download "Download the script" "$RAW_URL/claude-multi.sh" "$dest"
    chmod 755 "$dest"
  fi
  plan_end "Installed $dest"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) hint "Run it from anywhere with: claude-multi" ;;
    *)
      warn "$INSTALL_DIR is not on your PATH."
      rc="$(shell_rc_file)"
      if [[ -n "$rc" ]] && ui_confirm "Add it to $rc?" y; then
        printf '\n# Added by claude-multi\nexport PATH="%s:$PATH"\n' "$INSTALL_DIR" >> "$rc"
        ok "Updated $rc. Open a new terminal, then run: claude-multi"
      else
        hint "Add it yourself, e.g.: export PATH=\"$INSTALL_DIR:\$PATH\""
      fi ;;
  esac
}

task_check_script() {
  local v
  bash -n "$1"
  v="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$1" | sed -n 1p)"
  [[ -n "$v" ]] || { echo "The download does not look like claude-multi.sh" >&2; return 1; }
  state_set remote_version "$v"
  step_detail "v$v"
}

task_replace_self() {  # write a new file and rename it, so the running copy isn't modified
  cp "$1" "$SELF.new.$$"
  chmod 755 "$SELF.new.$$"
  mv -f "$SELF.new.$$" "$SELF"
  step_detail "$SELF"
}

cmd_update_self() {
  local force=0 arg dir remote tmp
  for arg in "$@"; do
    case "$arg" in
      --force|-f) force=1 ;;
      *) die "unknown option '$arg'" ;;
    esac
  done
  [[ -f "$SELF" && -w "$SELF" ]] || die "can't update $SELF in place"
  dir="$(dirname "$SELF")"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "This copy is inside a git checkout ($dir)."
    if ui_confirm "Update it with 'git pull --ff-only'?" y; then
      plan_begin "Updating claude-multi" 1
      step "git pull" git -C "$dir" pull --ff-only
      plan_end "Repository is up to date"
    fi
    return 0
  fi

  tmp="$WORK_DIR/claude-multi.sh.new"
  plan_begin "Updating claude-multi" 3
  step_download "Download the latest version" "$RAW_URL/claude-multi.sh" "$tmp"
  step "Check the download" task_check_script "$tmp"
  remote="$(state_get remote_version)"
  if [[ "$remote" == "$VERSION" && $force -eq 0 ]]; then
    plan_end "claude-multi v$VERSION is up to date"
    return 0
  fi
  step "Replace $SELF" task_replace_self "$tmp"
  plan_end "claude-multi updated: v$VERSION -> v$remote"
}

cmd_uninstall_self() {
  local dest="$INSTALL_DIR/claude-multi"
  if [[ ! -e "$dest" ]]; then
    ok "claude-multi is not installed in $INSTALL_DIR."
    return 0
  fi
  rm -f "$dest"
  ok "Removed $dest (profiles and launchers were kept)."
}

# ------------------------------------------------------------------ menu ---

ui_status() {
  local app ver d n=0 r=0
  app="$(locate_app 2>/dev/null || true)"
  if [[ -n "$app" ]]; then ver="$(app_version "$app")"; fi
  if [[ -d "$PROFILES_ROOT" ]]; then
    for d in "$PROFILES_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      n=$(( n + 1 ))
      if [[ -n "$(main_pid "${d%/}")" ]]; then r=$(( r + 1 )); fi
    done
  fi
  printf '  %sPlatform%s  %s\n' "$C_DIM" "$C_RESET" "$(platform_name "$PLATFORM")"
  if [[ -n "$app" ]]; then
    printf '  %sClaude  %s  %s%s\n' "$C_DIM" "$C_RESET" "$app" "${ver:+ (v$ver)}"
  else
    printf '  %sClaude  %s  %snot installed%s\n' "$C_DIM" "$C_RESET" "$C_YELLOW" "$C_RESET"
  fi
  printf '  %sProfiles%s  %d (%d running)\n\n' "$C_DIM" "$C_RESET" "$n" "$r"
}

choose_platform() {
  local idx=0
  local -a opts=("macOS" "Linux" "Windows")
  case "$(default_platform)" in linux) idx=1 ;; windows) idx=2 ;; esac
  opts[idx]="${opts[idx]}  (detected)"
  ui_select "Which platform are you setting up?" "$idx" "${opts[@]}"
  case "$REPLY_INDEX" in
    0) PLATFORM=macos ;; 1) PLATFORM=linux ;; 2) PLATFORM=windows ;;
    *) exit 0 ;;
  esac
}

menu_pick() {  # menu_pick "Question" -> MENU_PROFILE
  local d name
  local -a names=() labels=()
  if [[ -d "$PROFILES_ROOT" ]]; then
    for d in "$PROFILES_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      d="${d%/}"
      name="${d##*/}"
      names+=("$name")
      if [[ -n "$(main_pid "$d")" ]]; then labels+=("$name  (running)"); else labels+=("$name"); fi
    done
  fi
  if [[ ${#names[@]} -eq 0 ]]; then
    warn "No profiles yet. Create one first."
    return 1
  fi
  ui_select "$1" 0 "${labels[@]}"
  if (( REPLY_INDEX < 0 )); then return 1; fi
  MENU_PROFILE="${names[REPLY_INDEX]}"
}

menu_create() {
  ui_input "Profile name (letters, digits, . _ -)"
  validate_name "$REPLY_VALUE"
  if ui_confirm "Copy the MCP servers from your regular Claude app?" y; then
    cmd_create "$REPLY_VALUE" --copy-config
  else
    cmd_create "$REPLY_VALUE"
  fi
}
menu_start()  { menu_pick "Start which profile?";  cmd_start "$MENU_PROFILE"; }
menu_stop()   { menu_pick "Stop which profile?";   cmd_stop "$MENU_PROFILE"; }
menu_config() { menu_pick "Edit which profile's MCP config?"; cmd_config "$MENU_PROFILE"; }
menu_remove() { menu_pick "Remove which profile?"; cmd_remove "$MENU_PROFILE"; }
menu_self() {
  ui_select "claude-multi" 0 "Install to $INSTALL_DIR (run 'claude-multi' anywhere)" "Update from GitHub" "Back"
  case "$REPLY_INDEX" in
    0) cmd_install_self ;;
    1) cmd_update_self ;;
  esac
}

menu_run() {  # run an action in a subshell so a failure returns to the menu
  set +e
  ( set -e; "$@" )
  set -e
  ui_pause
}

cmd_menu() {
  if [[ ! -t 0 || ! -t 1 ]]; then usage; return 0; fi
  if [[ -z "$PLATFORM" ]]; then
    ui_clear
    ui_banner
    choose_platform
  fi
  if [[ "$PLATFORM" == windows ]]; then run_windows --platform windows; fi
  platform_setup
  while :; do
    ui_clear
    ui_banner
    ui_status
    ui_select "What would you like to do?" 0 \
      "Create a profile" "Start a profile" "Stop a profile" "List profiles" \
      "Edit a profile's MCP config" "Remove a profile" \
      "Install / update Claude Desktop" "Install / update claude-multi" "Quit"
    case "$REPLY_INDEX" in
      0) menu_run menu_create ;;
      1) menu_run menu_start ;;
      2) menu_run menu_stop ;;
      3) menu_run cmd_list ;;
      4) menu_run menu_config ;;
      5) menu_run menu_remove ;;
      6) menu_run cmd_install_claude ;;
      7) menu_run menu_self ;;
      *) printf '\n'; return 0 ;;
    esac
  done
}

# ------------------------------------------------------------------ main ---

usage() {
  cat <<EOF
claude-multi v$VERSION: isolated Claude Desktop profiles for macOS, Linux and Windows

Usage: $ME [--platform macos|linux|windows] [command] [args]

Run it without a command for the interactive menu.

Profiles
  create <name> [--copy-config]  Create a profile and a launcher. --copy-config
                                 copies the MCP config from the regular Claude app.
  start  <name>                  Launch Claude with that profile
                                 (brings it to front if already running).
  stop   <name>                  Quit the instance running that profile.
  list                           Show profiles and whether they are running.
  config <name>                  Open that profile's claude_desktop_config.json.
  remove <name> [--yes]          Delete the launcher and the profile's local data.

Claude Desktop
  install-claude [--force]       Install or update Claude Desktop
                                 (macOS, and Debian/Ubuntu on Linux).

This tool
  install                        Install claude-multi into $INSTALL_DIR.
  update [--force]               Update claude-multi from GitHub.
  uninstall                      Remove that installed copy (profiles are kept).
  version                        Print the version.

On Windows, use claude-multi.ps1 / claude-multi.cmd. From Git Bash or WSL this
script hands over to it automatically.

Environment overrides:
  CLAUDE_PLATFORM       macos, linux or windows (default: detected)
  CLAUDE_APP_PATH       Claude.app (macOS) or the Claude executable (Linux)
  CLAUDE_PROFILES_ROOT  where profile data lives
  CLAUDE_LAUNCHERS_DIR  where launchers are created
  CLAUDE_APP_LABEL      launcher name (default: Claude780)
  CLAUDE_MULTI_BIN_DIR  where 'install' puts the script (default: ~/.local/bin)
  NO_COLOR              turn off colors and animations
EOF
}

cleanup() {
  ui_cursor_show
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}

main() {
  local cmd
  local -a args=()
  PLATFORM="${CLAUDE_PLATFORM:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --platform) [[ $# -ge 2 ]] || die "--platform needs a value"; PLATFORM="$2"; shift 2 ;;
      --platform=*) PLATFORM="${1#*=}"; shift ;;
      *) args+=("$1"); shift ;;
    esac
  done
  PLATFORM="$(normalize_platform "$PLATFORM")"
  cmd="${args[0]:-}"

  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
    version|--version|-v) echo "claude-multi $VERSION"; return 0 ;;
    "") cmd_menu; return 0 ;;
  esac

  if [[ -z "$PLATFORM" ]]; then PLATFORM="$(default_platform)"; fi
  if [[ "$PLATFORM" == windows ]]; then run_windows "${args[@]}"; fi
  platform_setup
  set -- "${args[@]}"
  shift
  case "$cmd" in
    menu)                         cmd_menu ;;
    create|new)                   cmd_create "$@" ;;
    start|open|run)               cmd_start "$@" ;;
    stop|quit)                    cmd_stop "$@" ;;
    list|ls)                      cmd_list ;;
    config)                       cmd_config "$@" ;;
    remove|rm|delete)             cmd_remove "$@" ;;
    install-claude|update-claude) cmd_install_claude "$@" ;;
    install)                      cmd_install_self ;;
    update|self-update)           cmd_update_self "$@" ;;
    uninstall)                    cmd_uninstall_self ;;
    *)                            usage >&2; exit 1 ;;
  esac
}

ui_init
trap cleanup EXIT
trap 'printf "\n"; exit 130' INT TERM
work_dir_init
main "$@"; exit $?
