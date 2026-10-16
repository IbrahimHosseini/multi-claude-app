# Multi Claude App

Run several isolated **Claude Desktop** instances side by side on macOS — each with its own account, settings, cache and MCP servers.

`claude-multi.sh` gives every profile its own Electron data directory (`--user-data-dir`). The regular Claude app keeps using its default data directory, so it can stay "account 1" while a profile is "account 2" — or you can run two (or more) profiles alongside it.

## Features

- **Fully isolated profiles** — separate login, settings, cache and `claude_desktop_config.json` per profile.
- **Clickable launchers** — each profile gets a small `.app` in `~/Applications` with Claude's own icon, so you can open it from Launchpad, Spotlight or the Dock.
- **Self-contained launchers** — they keep working even if you move or delete the script.
- **Single instance per profile** — starting a profile that is already running just brings its window to the front.
- **Optional MCP config copy** — start a new profile with the same MCP servers as your regular Claude app.
- Runs on the bash 3.2 that ships with macOS; no dependencies.

## Requirements

- macOS
- [Claude Desktop](https://claude.ai/download) installed. The script looks for it in `/Applications`, then `~/Applications`, then via Spotlight. Set `CLAUDE_APP_PATH` if it lives somewhere else.

## Installation

```bash
git clone https://github.com/IbrahimHosseini/multi-claude-app.git
```

```bash
cd multi-claude-app && chmod +x claude-multi.sh
```

Optionally put it on your `PATH`:

```bash
ln -s "$PWD/claude-multi.sh" /usr/local/bin/claude-multi
```

## Quick start

```bash
./claude-multi.sh create work --copy-config
```

```bash
./claude-multi.sh start work
```

Sign in with your second account in the window that opens. From then on you can also launch it by opening **Claude780 (work)** from Launchpad or `~/Applications`.

## Commands

| Command | Aliases | What it does |
| --- | --- | --- |
| `create <name> [--copy-config]` | | Creates the profile and its launcher app. `--copy-config` copies `claude_desktop_config.json` (MCP servers) from the regular Claude app; an existing profile config is never overwritten. Running it again on an existing profile rebuilds the launcher. |
| `start <name>` | `open`, `run` | Launches Claude with that profile, or brings it to the front if it is already running. |
| `stop <name>` | `quit` | Quits that profile's instance (sends `SIGTERM`, waits up to 5 seconds). |
| `list` | `ls` | Lists all profiles and whether each one is running. |
| `config <name>` | | Opens the profile's `claude_desktop_config.json` in your text editor, creating an empty one if needed. Restart the profile afterwards to apply changes. |
| `remove <name> [--yes]` | `rm`, `delete` | Stops the instance, then deletes its launcher and **all** of its local data (login, settings, cache, config). Asks for confirmation unless `--yes` is given. |
| `help` | `-h`, `--help` | Shows usage. |

Profile names may contain letters, digits, `.`, `_` and `-`.

### Examples

```bash
./claude-multi.sh list
```

```bash
./claude-multi.sh config work
```

```bash
./claude-multi.sh stop work && ./claude-multi.sh start work
```

```bash
./claude-multi.sh remove work --yes
```

## Where things are stored

| What | Default location |
| --- | --- |
| Profile data | `~/Library/Application Support/Claude-Profiles/<name>` |
| Launcher apps | `~/Applications/Claude780 (<name>).app` |
| Regular Claude app data (untouched) | `~/Library/Application Support/Claude` |

## Configuration

All settings are optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_APP_PATH` | auto-detected | Path to `Claude.app` |
| `CLAUDE_PROFILES_ROOT` | `~/Library/Application Support/Claude-Profiles` | Where profile data lives |
| `CLAUDE_LAUNCHERS_DIR` | `~/Applications` | Where launcher apps are created |
| `CLAUDE_APP_LABEL` | `Claude780` | Name prefix for launcher apps |

For example, to name launchers `Claude (<name>)`:

```bash
CLAUDE_APP_LABEL=Claude ./claude-multi.sh create work
```

Use the same values for every command, otherwise the script won't find profiles or launchers created with different settings.

## How it works

- Claude Desktop is an Electron app, and Electron accepts `--user-data-dir`. Launching it with `open -n -a Claude.app --args --user-data-dir=<dir>` starts a new, independent instance that stores everything in `<dir>`.
- Running instances are found by matching the `--user-data-dir=<dir>` argument of the main Claude process in `ps` (helper processes are skipped), which is how `start`, `stop` and `list` know a profile's state.
- A launcher is a minimal app bundle whose executable is a small bash script holding the Claude.app path and the profile directory. It is registered with LaunchServices so it shows up in Launchpad and Spotlight.
- The script refuses to use the default Claude data directory as a profile, so your regular Claude app is never affected.

## Notes

- All profiles share the same installed `Claude.app`, so updating Claude updates every profile.
- If you move `Claude.app`, launchers fall back to finding it through Spotlight; you can also rebuild them with `create <name>`.
- To uninstall, run `remove` for each profile (or delete the profile folder and launcher apps listed above) and delete the script.

## License

[MIT](LICENSE)
