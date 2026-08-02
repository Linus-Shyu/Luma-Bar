# App Review Notes — luma bar (macOS)

## What the app does

luma bar is a notch / menu-bar companion for music controls, system glance info, and an optional AI Agent. Users pay once on the Mac App Store to download the full app.

## Permissions

- **Accessibility**: focused-window context and optional selection translation. Requested only when the user enables those features.
- **Screen Recording**: only when the user asks the Agent to analyze a game / window screenshot. Not used for continuous background capture.
- **Microphone / Speech**: only when the user starts Voice Whisper.
- **Automation (Apple Events)**: optional music / browser helpers the user explicitly triggers.
- **User-selected folders**: Cursor / Codex monitoring reads data only after the user grants a folder via the standard open panel (security-scoped bookmark). No silent access to other apps’ containers.

## Agent / “shell”

The Mac App Store build does **not** execute arbitrary shell scripts.
Confirmed Agent actions are limited to:

- opening apps / URLs
- clipboard copy
- running a user-created Shortcut by name (`shortcuts://`)

## Demo

1. Launch; grant Accessibility if prompted for notch context.
2. Expand the island → Music → switch Local / NetEase; play a local or NetEase track.
3. Agent: ask a question (user supplies their own API key in settings if required).
4. Optional: Agent → Data Access → Grant Cursor Folder, then observe token overlay while Cursor is active.

## Contact

Please contact the developer via App Store Connect if anything is unclear.
