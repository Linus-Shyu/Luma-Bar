# App Review Notes — luma bar (macOS)

**Paste the section below into App Store Connect → App Review Information → Notes.**

---

## Review Notes — luma bar (macOS)

**Bundle ID:** `com.lumabar.app`

### What the app is

luma bar is a **third-party** floating companion panel for Mac. It shows music controls, optional lyrics, light system glance info, and an optional AI assistant. It is **not** an Apple system feature and is not affiliated with Apple.

### Why we request Automation / Apple Events temporary exceptions

We request a **temporary exception for Apple Events** (`com.apple.security.temporary-exception.apple-events`) **only** for these two Bundle IDs:

1. **`com.apple.Music`** — read now-playing metadata / playback position and send play, pause, playpause, next, previous, and seek so the panel stays in sync with the Music app the user already uses.
2. **`com.netease.163music`** — the same minimal transport commands for NetEase Cloud Music when the user chooses that library. NetEase does not provide a public Mac SDK for transport control.

**Justification:** Under App Sandbox, cross-application Apple Events are blocked by default. `com.apple.security.automation.apple-events` alone allows the system Automation permission prompt, but does not grant delivery to specific targets. The temporary exception is required so user-approved Apple Events can reach **only** the two listed music apps.

**What we do *not* do in the Mac App Store build:**

- We do **not** link or `dlopen` private `MediaRemote.framework`.
- We do **not** synthesize global media keys (`NX_KEYTYPE_*`) or post HID/`CGEvent` media events for Play/Pause.
- Transport is **targeted by Bundle ID**: before playing one app we pause the other, so two players do not run at once.

### Sandbox / file access

Cursor / Codex / similar usage overlays read data **only after** the user grants a folder via the standard open panel (security-scoped bookmark). The Mac App Store build does **not** silently probe other apps’ containers (including NetEase local SQLite / HTTP cookie stores) without user-granted access.

### Agent / “shell”

The Mac App Store build does **not** execute arbitrary shell scripts (`zsh` / `osascript` / `sqlite3` subprocesses). Confirmed Agent actions are limited to:

- opening apps / URLs
- clipboard copy
- running a user-created Shortcut by name (`shortcuts://`)

### Demo steps for reviewers

1. Install and launch luma bar.
2. Open **Music** (and optionally NetEase Cloud Music), start a track.
3. Grant **Automation** for Music / NetEase when prompted.
4. Use the panel Play/Pause / Next — only the selected player should respond; the other stays paused.
5. Expand the panel to view lyrics (when available) and confirm the highlight follows the playhead.
6. Optional: Agent — use a user-supplied API key; confirm actions stay within open URL / clipboard / Shortcuts.
7. Optional: Agent → Data Access — grant Cursor / Codex folder via the open panel, then observe overlays only after that grant.

### Permissions you may see

| Permission | When |
|------------|------|
| **Automation — Music / NetEase** | Required for playback sync and transport described above |
| **Microphone / Speech** | Only if the user starts Voice Whisper |
| **Screen Recording** | Only if the user asks the Agent to analyze a screenshot |
| **Files / folders** | Only after the user grants a folder via the system open panel |

### Contact

Please contact us via App Store Connect if any entitlement justification needs more detail. We can provide a screen recording of Music + NetEase exclusive control on request.
