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
2. **`com.apple.MobileSMS`** — send a message **only** when the user explicitly asks the Agent to, and confirms it.

**Justification:** Under App Sandbox, cross-application Apple Events are blocked by default. `com.apple.security.automation.apple-events` alone allows the system Automation permission prompt, but does not grant delivery to specific targets. The temporary exception is required so user-approved Apple Events can reach **only** the two listed apps.

### How NetEase Cloud Music is controlled (no Apple Events)

NetEase Cloud Music ships no AppleScript dictionary, so we send it **no Apple Events at all** and request **no exception** for it. Instead:

- **Play / pause** use NetEase's own public `orpheus://` URL scheme via `NSWorkspace` (`resume`, and both `pause` and `pausePlayer`), which needs no entitlement and no permission grant.
- **Songs already downloaded as ordinary audio files** (mp3 / m4a / flac …) are played by our own engine from the **music folder the user grants** through the standard open panel, so play, pause, next, previous, and seek are all fully ours. NetEase's encrypted `.ncm` downloads are **not** decrypted — we never touch that container.
- **Next / previous** play the neighbouring song in the list on screen with the public `orpheus://` command `{"cmd":"play","type":"song","id"}`. Nothing is synthesized or scripted.
- **Seeking** inside a track NetEase owns has no public command. The panel shows that song's timeline read-only, estimated from its start time, and hides it whenever the estimate cannot be trusted. Dragging works only for a granted ordinary download: Luma Bar pauses NetEase and continues that file in its own engine from the chosen position.
- **Starting a specific song** uses that same play command. The bare `orpheus://song/<id>` link is a no-op on current NetEase versions and is not used.
- The current song and playlists come from the **NetEase storage folder the user grants** through the standard open panel. Covers and lyrics use NetEase's public HTTP endpoints. We do not read NetEase cookie jars. NetEase publishes no playback position, so the panel estimates it from the song's start time and suppresses lyric line highlighting whenever that estimate cannot be trusted.

**What we do *not* do in the Mac App Store build:**

- We do **not** link or `dlopen` private `MediaRemote.framework`.
- We do **not** post synthesized keyboard or HID events of any kind. `CGEventPost`, `CGEventCreateKeyboardEvent`, and `CGEventSourceCreate` are absent from the shipped binary's undefined-symbol list.
- We do **not** read any other application's Accessibility tree. `AXUIElementCopyAttributeValue` is likewise absent from the shipped binary.
- We do **not** script `System Events` or perform UI scripting; the only Apple Events targets are the two Bundle IDs above.
- We do **not** send any Apple Event to NetEase Cloud Music.
- Transport is **targeted by Bundle ID**: before playing one app we pause the other, so two players do not run at once.

### Translate-on-copy and the pasteboard

Translation is **off by default**. The user turns it on from the status menu (**Selection Translation**); the first time, a dialog explains that copied text is sent to an AI service (DeepSeek, or OpenAI if the user chose it) and translation stays off unless the user taps **Turn On**. Once on, it is triggered by the user copying the **same** text a second time (Command-C twice). A single copy is left alone so it does not fight paste, and we do not take Option-Command-C (Copy Style). We watch `NSPasteboard.general.changeCount` and read the string **only once per change**, never in a loop over the same contents, and never while our own app owns the pasteboard. The text is sent to that AI provider only while the feature is enabled, and only for the copy that triggered it. We do not archive pasteboard history and we do not read any other pasteboard type.

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
3. Grant **Automation** for Music when prompted. NetEase transport needs no permission. If you switch to the NetEase library tab, grant the storage folder (now playing / playlists) and optionally the Music folder (downloaded mp3 / flac for in-app playback and seeking).
4. Use the panel Play/Pause — only the selected player should respond; the other stays paused. Next / Previous drive Music directly. For NetEase they play the neighbouring song in the list on screen. A song NetEase itself is playing shows a read-only estimated timeline; a granted ordinary download can be dragged.
5. Expand the panel to view lyrics when the track has them. For NetEase, a line is highlighted only while the estimated position is trustworthy.
6. Optional: Agent — use a user-supplied API key; confirm actions stay within open URL / clipboard / Shortcuts.
7. Optional: status menu → **Selection Translation** → **Turn On** in the consent dialog, then copy the same text twice with Command-C.
8. Optional: Agent → Data Access — grant Cursor / Codex folder via the open panel, then observe overlays only after that grant.

### Permissions you may see

| Permission | When |
|------------|------|
| **Automation — Music** | Required for playback sync and transport described above |
| **Microphone / Speech** | Only if the user starts Voice Whisper |
| **Accessibility** | **Never requested.** The sandbox refuses cross-application Accessibility calls, so the build uses none: full-screen detection runs on public `CGWindowList`, and translation is triggered by a second copy of the same text (see below) instead of by reading another app's selection. |
| **Files / folders** | Only after the user grants a folder via the system open panel |

Screen Recording is requested only when the user asks the Agent to analyze a screenshot (ScreenCaptureKit). Contacts and Messages automation are used only when the user asks the Agent to send an iMessage: the address book entitlement looks up a name, and Apple Events go to `com.apple.MobileSMS`. There is no System Events UI scripting and no private MediaRemote.

### Contact

Please contact us via App Store Connect if any entitlement justification needs more detail. We can provide a screen recording of Music + NetEase exclusive control on request.
