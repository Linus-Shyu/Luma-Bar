<p align="center">
  <img src="docs/images/branding/luma-bar-logo-icon.png" alt="Luma Bar" width="128" height="128">
</p>

<h1 align="center">Luma Bar</h1>

<p align="center">
  <strong>A native workspace that grows around the MacBook notch</strong><br>
  Music · local AI agent · voice · task alerts · system controls · desktop pet
</p>

<p align="center">
  <strong>English</strong> ·
  <a href="README.md">简体中文</a> ·
  <a href="https://github.com/Linus-Shyu/Luma-Bar/releases/latest">Download</a> ·
  <a href="#build--run">Build</a> ·
  <a href="#contributing">Contribute</a>
</p>

<p align="center">
  <a href="https://github.com/Linus-Shyu/Luma-Bar/releases/latest"><img src="https://img.shields.io/github/v/release/Linus-Shyu/Luma-Bar?style=flat&label=release&logo=github" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Linus-Shyu/Luma-Bar?style=flat" alt="MIT License"></a>
  <a href="https://www.apple.com/macos/"><img src="https://img.shields.io/badge/macOS-14%2B-111827?style=flat&logo=apple" alt="macOS 14+"></a>
  <a href="https://www.swift.org/"><img src="https://img.shields.io/badge/Swift-6-F05138?style=flat&logo=swift&logoColor=white" alt="Swift 6"></a>
  <a href="https://github.com/Linus-Shyu/Luma-Bar/stargazers"><img src="https://img.shields.io/github/stars/Linus-Shyu/Luma-Bar?style=flat" alt="Stars"></a>
  <a href="https://github.com/Linus-Shyu/Luma-Bar/actions/workflows/release.yml"><img src="https://img.shields.io/github/actions/workflow/status/Linus-Shyu/Luma-Bar/release.yml?branch=main&style=flat&label=release%20CI" alt="Release CI"></a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/AdventureX%202026-Quick%20Quick%20Amazon%20Quick%202nd%20Prize-FF9900?style=for-the-badge&logo=amazonaws&logoColor=white" alt="AdventureX 2026 · Quick Quick Amazon Quick 2nd Prize">
</p>

<p align="center">
  <em>🏆 AdventureX 2026 · 快快快 Quick Quick Amazon Quick track · 2nd Prize</em>
</p>

<br>

<p align="center">
  <img src="docs/images/luma-bar-agent.png" alt="Luma Bar Agent reading and translating the active webpage" width="92%">
</p>
<p align="center">
  <sub>Stay in context: read, translate, act, and notify without leaving the screen.</sub>
</p>

## Why Luma Bar

Most menu-bar tools do one job. Luma Bar turns the **safe areas beside the camera notch** into a real workspace — music, a local agent, Cursor / Codex awareness, and macOS controls — without covering the camera.

| | |
|:--|:--|
| **Notch-native** | Uses `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; camera stays clear |
| **Music & lyrics** | Local audio, NetEase playlists, live artwork / progress / synced lyrics |
| **Local AI agent** | Streaming replies, preferences, recent context, confirmed local actions |
| **Cursor / Codex** | Context-window usage + in-notch completion alerts |
| **Voice Whisper** | `⌘ ⇧ M` dictation into the Agent input |
| **macOS controls** | Playback, volume, brightness, Wi-Fi, appearance, apps, Messages, lock |
| **Desktop pet** | Reacts to time, weather, and the frontmost app |
| **Fullscreen-friendly** | Smooth hide / restore across Spaces and fullscreen |

## Quick start

### Download (recommended)

Get a **notarized** DMG / ZIP from [Releases](https://github.com/Linus-Shyu/Luma-Bar/releases/latest).

If Luma Bar is useful to you, a [★ Star](https://github.com/Linus-Shyu/Luma-Bar) goes a long way.

### Build from source

```bash
git clone https://github.com/Linus-Shyu/Luma-Bar.git
cd Luma-Bar
./build_app.sh
open "luma bar.app"
```

For day-to-day development:

```bash
swift build
./run.sh
```

Requires **macOS 14+** and a Swift 6 toolchain. A notched MacBook is recommended. NetEase / `.ncm` needs NetEase Cloud Music installed; remote models need an OpenAI API key.

## Screenshots

<details open>
<summary><strong>Music in the notch</strong></summary>
<br>
<p align="center">
  <img src="docs/images/luma-bar-music.png" alt="Music dashboard with lyrics and playlists" width="92%">
</p>
</details>

<details>
<summary><strong>A system monitor with personality</strong></summary>
<br>
<p align="center">
  <img src="docs/images/luma-bar-system-pet.png" alt="System dashboard and pixel pet" width="92%">
</p>
</details>

<details>
<summary><strong>When context is nearly full</strong></summary>
<br>
<p align="center">
  <img src="docs/images/luma-bar-context-limit.png" alt="Cursor context usage gauge" width="92%">
</p>
</details>

## Permissions & privacy

Grant only what you use: Accessibility, Microphone / Speech Recognition, Automation, Contacts; Full Disk Access only if Cursor / Codex data lives in a protected location. Completion alerts are drawn in the notch — **no Notification Center permission**.

Luma Bar is **local-first**: API keys stay in Keychain (never in Git); recent operational context expires; remote calls happen only when you invoke Agent features that need them.

```bash
export OPENAI_API_KEY="..."
export LUMA_BAR_OPENAI_MODEL="..."
```

You can also save the key from the Agent panel.

## Stack (short)

- **SwiftUI** — compact bar, expanded panels, themes
- **AppKit** — borderless `NSPanel` (island + pet)
- **MediaRemote / AVFoundation** — playback state and local audio
- **SQLite** — Cursor / Codex / NetEase metadata when available
- **Keychain** — provider credentials

## Recognition

**AdventureX 2026** — **快快快 Quick Quick Amazon Quick track · 2nd Prize**

`#adventurex2026`

## Contributing

Issues and PRs are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md).

Keep diffs focused. **Liquid Glass visuals are frozen** — please don’t restyle them by default.

## License

[MIT](LICENSE) © Luma Bar Core Team

---

<p align="center">
  If Luma Bar made your Mac a little better, consider
  <a href="https://github.com/Linus-Shyu/Luma-Bar">starring the repo</a>.
</p>
