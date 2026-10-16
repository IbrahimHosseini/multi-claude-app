#!/usr/bin/env bash
#
# claude-multi.sh — run several isolated Claude Desktop instances on macOS.
#
# Each profile gets its own Electron data directory (--user-data-dir), so it
# has its own login/account, settings, cache and claude_desktop_config.json
# (MCP servers). The regular Claude app keeps its default data directory, so
# it can stay "account 1" while a profile is "account 2" (or use two profiles).
#
#   Profiles:  ~/Library/Application Support/Claude-Profiles/<name>
#   Launchers: ~/Applications/Claude780 (<name>).app   (drag to Dock if you like)
#
# Written for the bash 3.2 that ships with macOS.

set -eo pipefail

BUNDLE_ID="com.anthropic.claudefordesktop"
PROFILES_ROOT="${CLAUDE_PROFILES_ROOT:-$HOME/Library/Application Support/Claude-Profiles}"
LAUNCHERS_DIR="${CLAUDE_LAUNCHERS_DIR:-$HOME/Applications}"
DEFAULT_DATA_DIR="$HOME/Library/Application Support/Claude"
APP_LABEL="${CLAUDE_APP_LABEL:-Claude780}"
ME="$(basename "$0")"

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
Usage: $ME <command> [args]

  create <name> [--copy-config]  Create a profile and a clickable launcher app.
                                 --copy-config copies the MCP config from the
                                 regular Claude app into the new profile.
  start  <name>                  Launch Claude with that profile
                                 (brings it to front if already running).
  stop   <name>                  Quit the instance running that profile.
  list                           Show profiles and whether they are running.
  config <name>                  Open that profile's claude_desktop_config.json.
  remove <name> [--yes]          Delete the launcher and the profile's local data.

Environment overrides:
  CLAUDE_APP_PATH       path to Claude.app (auto-detected by default)
  CLAUDE_PROFILES_ROOT  where profile data lives
  CLAUDE_LAUNCHERS_DIR  where launcher apps are created
  CLAUDE_APP_LABEL      launcher app name (default: Claude780)
EOF
}

find_app() {
  local p
  if [[ -n "${CLAUDE_APP_PATH:-}" ]]; then
    if [[ -d "$CLAUDE_APP_PATH" ]]; then printf '%s\n' "$CLAUDE_APP_PATH"; return 0; fi
    die "CLAUDE_APP_PATH not found: $CLAUDE_APP_PATH"
  fi
  for p in "/Applications/Claude.app" "$HOME/Applications/Claude.app"; do
    if [[ -d "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  done
  p="$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | head -n1 || true)"
  if [[ -n "$p" && -d "$p" ]]; then printf '%s\n' "$p"; return 0; fi
  die "Claude.app not found. Install it or set CLAUDE_APP_PATH=/path/to/Claude.app"
}

validate_name() {
  [[ -n "$1" ]] || die "a profile name is required (see: $ME help)"
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid name '$1' (use letters, digits, . _ -)"
  [[ "$1" != "." && "$1" != ".." ]] || die "invalid name '$1'"
}

profile_dir()   { printf '%s/%s\n' "$PROFILES_ROOT" "$1"; }
launcher_path() { printf '%s/%s (%s).app\n' "$LAUNCHERS_DIR" "$APP_LABEL" "$1"; }

# Print the PID of the main Claude process using the given data dir (or nothing).
# The needle goes through the environment so awk's own command line can't match.
main_pid() {
  ps -axww -o pid=,command= | NEEDLE="--user-data-dir=$1" awk '
    {
      n = ENVIRON["NEEDLE"]; i = index($0, n)
      if (i == 0) next
      c = substr($0, i + length(n), 1)          # avoid "work" matching "work2"
      if (c != "" && c != " ") next
      if (index($0, "/Contents/Frameworks/") > 0) next   # skip helper processes
      if (index($0, "/Contents/MacOS/") == 0) next
      print $1; exit
    }'
}

focus_pid() {
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $1) to true" \
    >/dev/null 2>&1 || true
}

make_launcher() {
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
  { n = ENVIRON["NEEDLE"]; i = index($0, n); if (i == 0) next
    c = substr($0, i + length(n), 1); if (c != "" && c != " ") next
    if (index($0, "/Contents/Frameworks/") > 0) next
    if (index($0, "/Contents/MacOS/") == 0) next
    print $1; exit }')"
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
  info "Launcher: $bundle"
}

cmd_create() {
  local name="${1:-}" opt="${2:-}" app dir
  validate_name "$name"
  app="$(find_app)"
  dir="$(profile_dir "$name")"
  [[ "$dir" != "$DEFAULT_DATA_DIR" ]] || die "refusing to use the default Claude data directory"

  if [[ -d "$dir" ]]; then
    info "Profile '$name' already exists: $dir"
  else
    mkdir -p "$dir"
    info "Created profile: $dir"
  fi

  if [[ "$opt" == "--copy-config" ]]; then
    if [[ -f "$dir/claude_desktop_config.json" ]]; then
      info "Profile already has a config; not overwriting it."
    elif [[ -f "$DEFAULT_DATA_DIR/claude_desktop_config.json" ]]; then
      cp "$DEFAULT_DATA_DIR/claude_desktop_config.json" "$dir/"
      info "Copied MCP config from the regular Claude app."
    else
      info "No config found in the regular Claude app to copy."
    fi
  elif [[ -n "$opt" ]]; then
    die "unknown option '$opt'"
  fi

  make_launcher "$name" "$app" "$dir"
  info ""
  info "Start it with:  $ME start $name"
  info "or open '$APP_LABEL ($name)' from Launchpad / ~/Applications."
}

cmd_start() {
  local name="${1:-}" app dir pid
  validate_name "$name"
  dir="$(profile_dir "$name")"
  [[ -d "$dir" ]] || die "profile '$name' does not exist. Run: $ME create $name"
  pid="$(main_pid "$dir")"
  if [[ -n "$pid" ]]; then
    info "Profile '$name' is already running (pid $pid); bringing it to front."
    focus_pid "$pid"
    return 0
  fi
  app="$(find_app)"
  open -n -a "$app" --args "--user-data-dir=$dir"
  info "Started Claude with profile '$name'."
}

cmd_stop() {
  local name="${1:-}" dir pid _
  validate_name "$name"
  dir="$(profile_dir "$name")"
  pid="$(main_pid "$dir")"
  if [[ -z "$pid" ]]; then
    info "Profile '$name' is not running."
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
      info "Stopped profile '$name'."
      return 0
    fi
  done
  printf "Profile '%s' is still running after 5s. Force it with: kill -9 %s\n" "$name" "$pid" >&2
  return 1
}

cmd_list() {
  local d name pid found=0
  info "Profiles in: $PROFILES_ROOT"
  if [[ -d "$PROFILES_ROOT" ]]; then
    for d in "$PROFILES_ROOT"/*/; do
      [[ -d "$d" ]] || continue
      d="${d%/}"
      name="${d##*/}"
      found=1
      pid="$(main_pid "$d")"
      if [[ -n "$pid" ]]; then
        printf '  %-20s running (pid %s)\n' "$name" "$pid"
      else
        printf '  %-20s stopped\n' "$name"
      fi
    done
  fi
  if [[ $found -eq 0 ]]; then
    info "  (none yet; create one with: $ME create <name>)"
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
  open -t "$cfg"
  info "Editing: $cfg"
  info "After saving, restart the profile:  $ME stop $name && $ME start $name"
}

cmd_remove() {
  local name="${1:-}" opt="${2:-}" dir bundle ans
  validate_name "$name"
  dir="$(profile_dir "$name")"
  bundle="$(launcher_path "$name")"
  [[ -d "$dir" || -d "$bundle" ]] || die "profile '$name' does not exist"

  cmd_stop "$name" || die "quit the '$name' instance first, then retry"

  if [[ "$opt" != "--yes" ]]; then
    read -r -p "Delete the launcher and ALL local data (login, settings, cache, config) for '$name'? [y/N] " ans
    case "$ans" in
      [yY]*) ;;
      *) info "Cancelled."; return 0 ;;
    esac
  fi
  rm -rf "$bundle"
  rm -rf "$dir"
  info "Removed profile '$name'."
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "this script only works on macOS"
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    create)             cmd_create "$@" ;;
    start|open|run)     cmd_start "$@" ;;
    stop|quit)          cmd_stop "$@" ;;
    list|ls)            cmd_list ;;
    config)             cmd_config "$@" ;;
    remove|rm|delete)   cmd_remove "$@" ;;
    help|-h|--help)     usage ;;
    *)                  usage >&2; exit 1 ;;
  esac
}

main "$@"