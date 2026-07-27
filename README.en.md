# Luma Bar

> A living workspace around your MacBook notch.

**English** | [简体中文](README.md)

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111827?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![SwiftUI + AppKit](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-2563EB)](https://developer.apple.com/xcode/swiftui/)
[![AdventureX 2026](https://img.shields.io/badge/AdventureX-2026-F59E0B)](#adventurex-2026)
[![Download](https://img.shields.io/badge/Download-v0.2.0%20Beta-2563EB?logo=github)](https://github.com/Linus-Shyu/Luma-Bar-Download/releases/latest)

Luma Bar is a native macOS Dynamic Island built around the MacBook camera notch. It combines music playback, a context-aware local agent, voice input, task notifications, system controls, and a small desktop pet in one lightweight interface.

<p align="center">
  <img src="docs/images/luma-bar-agent.png" alt="Luma Bar Agent reading and translating the active webpage" width="100%">
</p>
<p align="center">
  <sub>The workspace stays in context: read, translate, act, and notify without leaving the screen.</sub>
</p>

## Highlights

- **Notch-native interface** — uses the areas beside the MacBook camera notch without covering the camera area.
- **Music and lyrics** — scans local audio, reads NetEase Cloud Music playlists, follows live playback, and loads artwork, progress, and synchronized lyrics.
- **Local AI agent** — OpenAI-powered streaming responses, persistent preferences, recent-operation context, and confirmed local actions.
- **Cursor and Codex awareness** — displays context-window usage and shows an in-notch alert when an individual task finishes.
- **Voice Whisper** — press `⌘ ⇧ M` to dictate Chinese text directly into the Agent input.
- **macOS controls** — control playback, volume, brightness, Wi-Fi, appearance, applications, Messages, and screen locking.
- **Contextual desktop pet** — reacts to time, weather, and the active application.
- **Fullscreen friendly** — hides and restores the island and pet around fullscreen Space transitions.
- **Multiple visual themes** — includes AdventureX, glass, and pixel-pet inspired styles.

## Screenshots

### Music becomes part of the notch

Artwork, playlists, playback controls, progress, and synchronized lyrics live in one expanded surface. The AdventureX theme turns the player into a tactile hardware console.

<p align="center">
  <img src="docs/images/luma-bar-music.png" alt="Luma Bar AdventureX music dashboard with lyrics and playlists" width="100%">
</p>

### A system monitor with personality

Live CPU, memory, disk, battery, network, and uptime metrics share the desktop with a context-aware pixel pet.

<p align="center">
  <img src="docs/images/luma-bar-system-pet.png" alt="Luma Bar system dashboard and contextual pixel cat" width="100%">
</p>

### Cursor context at the limit

When Cursor or Codex approaches the context-window ceiling, the notch expands into a live usage gauge and the desktop pet warns you before the session collapses.

<p align="center">
  <img src="docs/images/luma-bar-context-limit.png" alt="Luma Bar Cursor context window at 98% with pixel pet warning" width="100%">
</p>

## Download

Download the ready-to-install DMG from the public [Luma Bar Download repository](https://github.com/Linus-Shyu/Luma-Bar-Download/releases/latest). The binary distribution repository contains no source code.

## Requirements

- macOS 14 or later
- A Mac with Swift 6 toolchain installed
- A MacBook with a camera notch is recommended
- NetEase Cloud Music for NetEase playlist and `.ncm` integration
- An OpenAI API key for remote-model features

## Build and run

Clone the repository and run:

```bash
git clone https://github.com/Linus-Shyu/Luma-Bar.git
cd Luma-Bar
./build_app.sh
open "luma bar.app"
```

For development:

```bash
swift build
./run.sh
```

`build_app.sh` creates and signs a local `luma bar.app` bundle. Generated application bundles, build products, and local working data are excluded from Git.

## Permissions

Luma Bar may request the following macOS permissions depending on the features you use:

- Accessibility, for focused-window context and fullscreen detection
- Microphone and Speech Recognition, for Voice Whisper
- Automation, for controlling Music, Messages, and system appearance
- Contacts, for resolving message recipients
- Full Disk Access, only if Cursor or Codex keep their session data in a protected location

Cursor and Codex completion alerts are drawn inside the notch and do not use Notification Center, so no notification permission is required.

Grant only the permissions needed by the features you intend to use.

## Agent provider

API keys are stored in macOS Keychain and are never committed to the repository.

Supported environment variables:

```bash
export OPENAI_API_KEY="..."
export LUMA_BAR_OPENAI_MODEL="..."
```

You can also save the key from the Agent dashboard.

## How it works

- **SwiftUI** renders the compact bar, expanded dashboards, notifications, and themes.
- **AppKit** manages borderless `NSPanel` windows around the notch and desktop pet.
- **MediaRemote / AVFoundation** provide live playback state and direct local playback.
- **SQLite** reads local Cursor, Codex, and NetEase metadata where available.
- **Accessibility APIs** provide active-window context and reliable fullscreen detection.
- **Keychain** stores model-provider credentials locally.

The compact island uses `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, keeping the center camera area untouched.

## Privacy

Luma Bar is local-first. API keys remain in Keychain, and recent operational context expires automatically. Remote model requests are only sent when you invoke Agent features that require the selected provider.

## AdventureX 2026

Luma Bar is being developed for **AdventureX 2026**.

`#adventurex2026`

## Status

This is an active prototype. macOS APIs, media-player metadata, and third-party application storage formats may change between releases.
