# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MPC Bar is a macOS menu bar application that provides a client interface for the Music Player Daemon (MPD). It's written in Objective-C with C components and uses the libmpdclient library for MPD communication.

## Build System

The project uses a simple Makefile-based build system:

- **Build**: `make`
- **Install**: `make install` (installs to `/usr/local/bin`)
- **Clean**: `make clean`

Dependencies are tracked automatically using `-MMD -MP` flags. The build produces a single `mpc-bar` executable.

## Dependencies

Required libraries (linked via LDFLAGS):
- `libmpdclient`: MPD client library for communication with the Music Player Daemon
- `liblua`: Lua interpreter for optional filter scripts
- Cocoa framework: macOS GUI framework

## Architecture

### Main Components

**mpc-bar.m** (main application):
- `MPDController` class manages the entire application lifecycle
- Runs an update loop in a background thread that polls MPD via `mpd_send_idle()`/`mpd_run_noidle()`
- Updates are pushed to the main thread using `performSelectorOnMainThread:` for UI updates
- Connection management handles automatic reconnection on errors
- Three main update paths:
  - `updateSongMenu`: Rebuilds the "Add to Queue" menu when MPD database changes
  - `updateControlMenu`: Updates play/pause state, button states, and title text
  - `updateStatus`: Updates elapsed time display when a song is playing

**Configuration** (ini.c/ini.h):
- Uses the inih library to parse `~/.mpc-bar.ini` (or fallback `~/.mpcbar`)
- Config handler in mpc-bar.m:57-84 processes connection and display settings
- Supports MPD host, port, password, display format strings, title display options, and Lua filter scripts

**Song Formatting** (mpc/ directory):
- Imported from the MPC project for consistent formatting behavior
- `format_song()` in mpc/song_format.c takes MPD song metadata and a format string
- Format strings use mpc syntax: `%tag%` for metadata fields, `[...]` for conditionals
- Used at mpc-bar.m:269 to format the current song for display

**Lua Filtering** (optional):
- If `lua_filter` config option is set, initializes a Lua state (mpc-bar.m:132-139)
- `runLuaFilterOn:` (mpc-bar.m:140-153) executes the filter script on formatted strings
- Expects a global `filter(string)` function that returns modified string
- Errors are silently ignored (returns original string)
- Useful for shortening verbose radio station metadata

### UI Structure

The menu bar shows:
- Left side: Icon indicating current state
  - When title is shown on bar (`show_title_on_bar = true`, default): pause/single icons only, no icon for normal play or stopped
  - When title is hidden from bar (`show_title_on_bar = false`): always shows an icon (play/pause/single/stop)
- Title text (optional): Formatted song info or idle message, truncated to 96 chars with ellipsis (controlled by `show_title_on_bar` config)
- Optional queue position suffix: `(pos/total)` or `(total)` if no current song

The menu contains:
- Song title (always shown): Formatted song info or idle message, truncated to 96 chars with ellipsis
- Elapsed/duration time (only when playing)
- Play/Pause, Stop, Next Track, Previous Track controls
- "Pause After This Track" toggle (MPD single mode)
- Update Database
- Add to Queue submenu (populated from MPD database, organized by directory)
- Clear Queue
- Quit

### State Management

- `updateLoop` runs in background thread, polls MPD every 0.2 seconds
- Connection errors trigger disconnect/reconnect cycle
- `songMenuNeedsUpdate` flag ensures song menu is rebuilt after first connection
- MPD idle events trigger corresponding UI updates via main thread

## Code Patterns

### Error Handling
- MPD errors generally trigger disconnection and automatic reconnection
- UI is disabled during disconnection, error message shown in menu bar
- Lua errors are silent (original string used)

### Threading
- Background thread for MPD communication (blocking idle/status calls)
- Main thread for all UI updates (enforced via `performSelectorOnMainThread:`)
- No explicit locking (thread communication is one-way via selector calls)

### Memory Management
- Uses ARC (Automatic Reference Counting) via `-fobjc-arc` flag
- C strings from `format_song()` must be manually freed
- MPD objects (status, song, entity) must be freed with libmpdclient functions

## Configuration Format

INI file at `~/.mpc-bar.ini`:

```ini
[connection]
host = localhost
port = 6600
password = <optional>

[display]
format = <mpc format string>
idle_message = No song playing
show_queue = true
show_queue_idle = <defaults to show_queue value>
show_title_on_bar = true  # Show song title on menu bar (default: true)
title_max_length = 96  # Maximum title length before truncation (default: 96)
sleep_interval = 0.2  # Update loop sleep interval in seconds (default: 0.2)
lua_filter = <path to .lua file>
```

The format string follows mpc conventions. See the mpc(1) man page for syntax details.

## Testing & Development

This project has no automated tests. Manual testing workflow:
1. Ensure MPD is running and accessible
2. Build with `make`
3. Run `./mpc-bar` from terminal to see console logs
4. Check menu bar for UI updates
5. Test with/without MPD running to verify reconnection logic

For Homebrew development:
- Formula is at `spnw/formulae/mpc-bar`
- Launch as service: `brew services start spnw/formulae/mpc-bar`
- Check service status: `brew services list`
- View logs: `brew services info mpc-bar`
