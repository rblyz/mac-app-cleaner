# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

hygi is a macOS app uninstaller bash script that removes applications and their leftover files (caches, preferences, containers, launch agents, etc.). Named after Hygieia, the Greek goddess of cleanliness.

## Running the Script

```bash
# Interactive mode - select app from list
./hygi.sh

# List all installed applications
./hygi.sh --list

# Scan for leftovers without removing (dry run)
./hygi.sh --scan "App Name"

# Uninstall specific app
./hygi.sh "App Name"
```

## Architecture

Single bash script (`hygi.sh`) with these main functions:

- `scan_applications()` - Lists apps from /Applications and ~/Applications
- `get_bundle_id()` - Extracts CFBundleIdentifier from app's Info.plist using PlistBuddy
- `find_leftovers()` - Searches SEARCH_PATHS array for files matching bundle ID, app name, or vendor prefix
- `select_app()` - Interactive numbered menu for app selection
- `uninstall_app()` - Main deletion flow with confirmation prompt
- `scan_app()` - Dry-run mode showing what would be removed

## Key Constraints

- **bash 3.2 compatible** - Must work with macOS stock bash (no associative arrays, no `${var,,}` lowercase syntax)
- **Zero dependencies** - Uses only macOS built-in tools (PlistBuddy, find, du, tr)
- **Single file** - Everything in hygi.sh, no external modules

## Git Commits

Commit footer format (one line only):
```
Co-Authored-By: Claude Code (Opus 4.5)
```

Do NOT add promotional links or emoji to commits.
