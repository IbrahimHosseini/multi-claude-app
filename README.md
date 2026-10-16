# Multi Claude App

Run several isolated **Claude Desktop** instances side by side on **macOS, Linux and Windows**. Each one has its own account, settings, cache and MCP servers.

Every profile gets its own Electron data directory (`--user-data-dir`). The regular Claude app keeps using its default data directory, so it can stay "account 1" while a profile is "account 2". You can also run two or more profiles next to it.

## Features

- **Fully isolated profiles**: separate login, settings, cache and `claude_desktop_config.json` per profile.
- **One tool for three platforms**: `claude-multi.sh` for macOS and Linux, `claude-multi.ps1` for Windows. Both have the same commands and the same menu.
- **Interactive menu**: run it with no arguments, pick your platform, then create, start, stop or remove profiles with the arrow keys.
- **Live progress**: every task is shown as a list of steps with a spinner, a progress bar, and download size and speed. If a step fails, you see why.
- **Launchers**: each profile gets its own launcher that uses Claude's icon. That's an app in `~/Applications` on macOS, an entry in your applications menu on Linux, and a Start menu shortcut on Windows.
- **Installs and updates Claude Desktop**: downloads the latest official build from Anthropic, checks it, and installs it.
- **Installs and updates itself**: puts a `claude-multi` command on your `PATH` and updates it from GitHub.
- No dependencies. It runs on the bash 3.2 that ships with macOS and on Windows PowerShell 5.1.

## Supported platforms

| Platform | Script | Claude Desktop builds it works with |
| --- | --- | --- |
| macOS | `claude-multi.sh` | `Claude.app` from claude.ai |
| Linux | `claude-multi.sh` | Anthropic's official `.deb` (Debian/Ubuntu, amd64 and arm64), plus the community [`claude-desktop-unofficial`](https://github.com/aaddrick/claude-desktop-debian) packages and AppImages |
| Windows 10/11 | `claude-multi.ps1` (or double-click `claude-multi.cmd`) | The Microsoft Store / MSIX build from claude.ai, and the older `AnthropicClaude` installer |

On Windows, running `claude-multi.sh` from Git Bash or WSL hands over to `claude-multi.ps1` automatically.

## Getting started

```bash
git clone https://github.com/IbrahimHosseini/multi-claude-app.git
```

### macOS and Linux

```bash
cd multi-claude-app && chmod +x claude-multi.sh && ./claude-multi.sh
```

To use it from anywhere, install it as `claude-multi` in `~/.local/bin`. The script offers to add that folder to your `PATH`.

```bash
./claude-multi.sh install
```

### Windows

Double-click **`claude-multi.cmd`**, or run this in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\claude-multi.ps1
```

`claude-multi.ps1 install` copies it to `%LOCALAPPDATA%\Programs\claude-multi` and offers to add that folder to your user `PATH`, so `claude-multi` works in any terminal.

## The interactive menu

Run the script with no arguments:

1. **Choose your platform.** The one you're on is preselected and marked *(detected)*.
2. **Check the status.** It shows where Claude is installed, its version, and how many profiles you have and how many are running.
3. **Pick an action:** create, start, stop, list, edit MCP config, remove, install or update Claude Desktop, or install or update claude-multi.

Use **↑/↓** (or `j`/`k`, or a number) to move, **Enter** to choose, and **q** or **Esc** to go back.

A task looks like this while it runs:

```text
  Claude Desktop for macOS

  ✓ Check for the latest version  latest v2.42304.0, installed v2.37337.1
  ⠹ Download Claude v2.42304.0   █████░░░░░  50%  187.3 MB / 372.0 MB  3.6 MB/s
```

and like this when it's done:

```text
  ✓ Download Claude v2.42304.0  372.0 MB
  ✓ Unpack
  ✓ Verify the signature  signed by Anthropic PBC (Q6L2SF6YDW)
  ✓ Install  /Applications/Claude.app
  ✓ Refresh profile launchers  2 launcher(s) updated

  ██████████████████████████████ 100%
  ✓ Claude updated: v2.37337.1 -> v2.42304.0 (99s)
```

Colors and animations turn off automatically when the output isn't a terminal, or when `NO_COLOR` is set.

## Commands

The same commands work in `claude-multi.sh` and `claude-multi.ps1`. The examples below use the installed `claude-multi` command; you can also call `./claude-multi.sh` or `.\claude-multi.cmd` directly.

| Command | Aliases | What it does |
| --- | --- | --- |
| *(none)* | `menu` | Opens the interactive menu. |
| `create <name> [--copy-config]` | `new` | Creates the profile and its launcher. `--copy-config` copies `claude_desktop_config.json` (MCP servers) from the regular Claude app. An existing profile config is never overwritten. Running it again rebuilds the launcher. |
| `start <name>` | `open`, `run` | Launches Claude with that profile and waits for it to start. If it's already running, brings it to the front. |
| `stop <name>` | `quit` | Quits that profile's instance. |
| `list` | `ls` | Lists all profiles and whether each one is running. |
| `config <name>` | | Opens the profile's `claude_desktop_config.json` in a text editor, creating an empty one if needed. Restart the profile afterwards. |
| `remove <name> [--yes]` | `rm`, `delete` | Stops the instance, then deletes its launcher and **all** of its local data (login, settings, cache, config). Asks first unless `--yes` is given. |
| `install-claude [--force]` | `update-claude` | Installs Claude Desktop, or updates it to the latest version. `--force` reinstalls even when it's up to date. |
| `install` | | Installs claude-multi as a command on your `PATH`. |
| `update [--force]` | `self-update` | Updates claude-multi from GitHub. In a git clone, it offers `git pull --ff-only` instead. |
| `uninstall` | | Removes the installed command. Profiles and launchers are kept. |
| `help`, `version` | | Shows usage or the version. |

`--platform macos|linux|windows` (or `CLAUDE_PLATFORM`) skips the platform question. Profile names may contain letters, digits, `.`, `_` and `-`.

### Examples

```bash
claude-multi create work --copy-config
```

```bash
claude-multi start work
```

```bash
claude-multi list
```

```bash
claude-multi stop work && claude-multi start work
```

```bash
claude-multi remove work --yes
```

## Installing and updating Claude Desktop

`install-claude` always downloads from Anthropic and checks the download before installing it:

| Platform | Source | Check | Install |
| --- | --- | --- | --- |
| macOS | Anthropic's release feed (`downloads.claude.ai`) | Code signature must be valid and from Anthropic PBC (Team ID `Q6L2SF6YDW`) | Replaces `Claude.app` in place, keeping the old copy until the new one is in |
| Linux (Debian/Ubuntu) | Anthropic's official APT repository | SHA-256 from the repository index | `sudo apt-get install` of the `.deb` (it asks for your password) |
| Windows | The MSIX package from claude.ai | Package signature, checked by Windows | `Add-AppxPackage`, per user, no admin rights needed |

If Claude is running, the script asks before closing it. After an update, existing profile launchers are rebuilt to point at the new app.

On other Linux distributions (Fedora, Arch, NixOS and so on), install a [community build](https://github.com/aaddrick/claude-desktop-debian) yourself. claude-multi finds `claude-desktop-unofficial` and AppImages in `~/Applications`, `~/.local/bin` or `~/Downloads`, or you can point `CLAUDE_APP_PATH` at it.

## Where things are stored

| | macOS | Linux | Windows |
| --- | --- | --- | --- |
| Profile data | `~/Library/Application Support/Claude-Profiles/<name>` | `~/.config/Claude-Profiles/<name>` | `%USERPROFILE%\Claude-Profiles\<name>` |
| Launchers | `~/Applications/Claude780 (<name>).app` | `~/.local/share/applications/claude-multi-<name>.desktop` | Start menu → `Claude Multi\Claude780 (<name>)` |
| Installed command | `~/.local/bin/claude-multi` | `~/.local/bin/claude-multi` | `%LOCALAPPDATA%\Programs\claude-multi` |
| Regular Claude data (never touched) | `~/Library/Application Support/Claude` | `~/.config/Claude` | `%APPDATA%\Claude` |

## Configuration

All settings are optional environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_PLATFORM` | detected | `macos`, `linux` or `windows` |
| `CLAUDE_APP_PATH` | auto-detected | `Claude.app` on macOS, the Claude executable on Linux or Windows |
| `CLAUDE_PROFILES_ROOT` | see the table above | Where profile data lives |
| `CLAUDE_LAUNCHERS_DIR` | see the table above | Where launchers are created |
| `CLAUDE_APP_LABEL` | `Claude780` | Name prefix for launchers |
| `CLAUDE_MULTI_BIN_DIR` | see the table above | Where `install` puts the command |
| `NO_COLOR` | unset | Turns off colors and animations |

For example, to name launchers `Claude (<name>)`:

```bash
CLAUDE_APP_LABEL=Claude claude-multi create work
```

Use the same values for every command, otherwise the script won't find profiles or launchers created with different settings.

## How it works

- Claude Desktop is an Electron app, and Electron accepts `--user-data-dir`. Launching Claude with `--user-data-dir=<dir>` starts a separate instance that keeps everything in `<dir>`.
- The script tells whether a profile is running by finding the main Claude process that has `--user-data-dir=<dir>` on its command line, skipping Electron helper processes (`--type=...`). This is how `start`, `stop` and `list` know a profile's state.
- On macOS a launcher is a tiny app bundle with a self-contained shell script, so it keeps working even if you move or delete claude-multi. On Linux it's a `.desktop` file, and on Windows a `.lnk` shortcut.
- On Windows, profiles live in `%USERPROFILE%` rather than `%APPDATA%`, because the MSIX build of Claude redirects writes under AppData to a private per-app folder.
- The script refuses to use the regular Claude data directory as a profile, so your normal Claude app is never affected.

## Notes

- All profiles share one installed Claude, so updating Claude updates every profile.
- **Windows:** closing Claude's window leaves it running in the tray, so `stop` asks it to close and force-closes it after 5 seconds if needed.
- **Linux:** bringing an already-running profile to the front needs `wmctrl`. Without it, `start` just tells you the profile is already running.
- **WSL:** the script defaults to Windows there. Use `--platform linux` to manage a Linux Claude inside WSL.
- To uninstall, run `remove` for each profile, then `uninstall`, and delete the cloned folder.

## License

[MIT](LICENSE)
