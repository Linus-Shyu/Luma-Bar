# Luma Bar — Mac App Store (MAS) 上架全合规评估报告

**评估基准：** Apple《App Store Review Guidelines》（含 2.5 软件要求、5.2.5 知识产权）、macOS App Sandbox 强制规范、Hardened Runtime / Notarization 实务  
**评估对象：** `/Users/linusshyu/Desktop/luma bar`（含 `Sources/LumaBar/**`、`Support/*`、`build_app*.sh`、`Package.swift`、`docs/*`）  
**评估视角：** 苛刻审核员 + 自动化静态扫描（私有 API / entitlements / 沙盒越界）  
**当前版本锚点：** git tag `v0.3.2`；`Info.plist` 仍为 `0.2.2 (5)`（版本号不一致，见风险清单）  
**结论先行：** **当前不可直接提交并通过 MAS。** 工程已有沙盒 entitlements 骨架与 `#if LUMA_APP_STORE` 降级，但存在多项 **必拒** 缺口（Apple Events 临时例外缺失、商店文案商标风险、Info.plist 用途说明不匹配、网易云 MAS 能力被 stub 掉却仍依赖 AppleScript 控制等）。

| 维度 | 判决 | 说明 |
|------|------|------|
| 1. App Sandbox | **FAIL（阻断）** | 缺 `temporary-exception.apple-events`；大量家目录读写需书签/收口 |
| 2. 私有 API / 底层事件 | **CONDITIONAL PASS** | `MediaRemote`/`CGEvent` 亮度在 `LUMA_APP_STORE` 下已剥离；须保证提交物 **永远** 以 `LUMA_APP_STORE=1` 构建 |
| 3. 品牌 / 5.2.5 | **FAIL（元数据）** | README/商店文案含 Dynamic Island / 灵动岛 / MacBook；应用内主题名 Liquid Glass 有风险 |
| 4. 核心业务稳定性 | **PASS（直发版）/ PARTIAL（MAS）** | 直发互斥/歌词/切 Space 修复到位；MAS 下 NetEaseBridge 空实现与产品承诺冲突 |
| 5. 边界与性能 | **WARN** | AppleScript 无超时；主线程 10Hz Timer |
| 6. Review Notes | **需重写** | 现有草稿未覆盖 Temporary Exception 与音乐控制正当性 |

**综合健康度（面向 MAS 上架准备度）：34 / 100**  
**直发 / Developer ID 工程健康度（非本报告主目标）：78 / 100**

---

## 1. 📦 100% App Sandbox 兼容性审计

### 1.1 现状：沙盒开关

| 文件 | 状态 |
|------|------|
| `Support/LumaBar.AppStore.entitlements` | 已声明 `com.apple.security.app-sandbox = true` |
| `Support/LumaBar.entitlements`（直发） | **无** app-sandbox（符合 Developer ID 直发） |
| `build_app_store.sh` | 使用 AppStore entitlements 签名 |
| `Package.swift` | `LUMA_APP_STORE=1` → define `LUMA_APP_STORE` |

### 1.2 AppleScript / 跨进程控制 — **FAIL**

**代码位置：**

- `Sources/LumaBar/main.swift` — `ExclusiveAudioFocus`（约 L28–89）：对 `com.apple.Music` / `com.netease.163music` 同步 `NSAppleScript` `pause` / `play` / `playpause`
- `Sources/LumaBar/AppleMusicService.swift` — `runMusicCommand` / `refreshViaAppleScript`（MAS 路径仍走 AppleScript）
- 非商店 `NetEaseBridge.runNetEaseAppleScript`（约 L10071+）

**问题：**

1. 开启 App Sandbox 后，跨应用 Apple Events **默认拒绝**。仅有 `com.apple.security.automation.apple-events = true` **不够**：它只表示“可以请求自动化权限”，**不能**代替针对目标 Bundle ID 的临时例外。
2. **缺失**审核强相关 entitlement：

```xml
<key>com.apple.security.temporary-exception.apple-events</key>
<array>
  <string>com.apple.Music</string>
  <string>com.netease.163music</string>
</array>
```

3. 现有 `LumaBar.AppStore.entitlements` 只有：

```5:18:Support/LumaBar.AppStore.entitlements
	<key>com.apple.security.app-sandbox</key>
	<true/>
	...
	<key>com.apple.security.automation.apple-events</key>
	<true/>
	...
	<key>com.apple.security.personal-information.music-library</key>
	<true/>
```

`personal-information.music-library` 面向 **MusicKit / 媒体库 API**，**不能**合法替代对 Music.app 的 Scripting 控制。

**修改方案（必须）：**

```xml
<!-- Support/LumaBar.AppStore.entitlements 追加 -->
<key>com.apple.security.temporary-exception.apple-events</key>
<array>
	<string>com.apple.Music</string>
	<string>com.netease.163music</string>
</array>
```

并在 App Store Connect **Review Notes** 中逐条说明（见第 6 节）。Apple 可能要求缩减例外范围或改用公开 API（MusicKit）；网易云无公开 macOS API，例外是当前唯一路径，但须诚实披露。

### 1.3 文件系统越界 — **FAIL / 高风险**

沙盒下默认禁止读写其他 App 容器与任意家目录。下列路径在商店构建中仍可能被编译进二进制并在运行时触达：

| 区域 | 位置 | 风险 |
|------|------|------|
| 网易云数据 / Cookie | `NetEaseFavorite.swift`、`main.swift` 中 `com.netease.163music` 路径 | 读其他 App 容器 → 沙盒拒绝或拒审 |
| Cursor / Codex / Kiro / CherryStudio | `main.swift` Session readers、`SecurityScopedBookmarks.swift` | 部分已走书签；仍有 `homeDirectoryForCurrentUser` 硬编码探测 |
| 本地音乐扫描 | `FileManager` + 用户目录 | 需 user-selected 或 Music 库 entitlement + 用户授权 |
| `Process` + `/usr/bin/sqlite3` / `openssl` | `main.swift` ~L12876、L13210 | 沙盒下 spawn 受限；商店构建应确认 `#if` 已切断 |

**已有正向措施：**

- `SecurityScopedBookmarks.swift` + `files.bookmarks.app-scope` + `files.user-selected.read-write`
- `docs/APP_STORE.md` 要求用户主动授权 Cursor 文件夹

**修改方案：**

1. 所有非书签路径在 `#if LUMA_APP_STORE` 下改为：无书签则 **不探测、不读、不报错刷屏**。
2. 网易云本地库：商店版改为「仅控制已运行的网易云 + 公开 URL / 用户选文件」，或明确声明功能缩水。
3. 禁止商店构建调用 `Process` 执行 `sqlite3`/`osascript` 子进程（应用内 `NSAppleScript` 除外，且需例外）。

### 1.4 网络

- `com.apple.security.network.client = true`：合理（歌词 lrclib、Agent API、封面）。
- 须在隐私标签披露第三方传输（DeepSeek/OpenAI 等）。

### 1.5 本节判决

**不通过。** 无 `temporary-exception.apple-events` 时，Play/Pause / 歌词同步在沙盒下会静默失败或弹失败；提交前补齐例外 + 收口文件系统。

---

## 2. 🚫 私有 API 与底层事件 — 机器审核红线

### 2.1 MediaRemote.framework（Private Framework）

**位置：** `main.swift` ~L9661–10050（`dlopen` `/System/Library/PrivateFrameworks/MediaRemote.framework`，`MRMediaRemoteGetNowPlayingInfo` / `SendCommand` 等）

**MAS 构建：** 整段位于 `#else`（非 `LUMA_APP_STORE`），商店 stub：

```9610:9659:Sources/LumaBar/main.swift
#if LUMA_APP_STORE
final class NetEaseBridge: ...
    func send(...) -> Bool { false }
    func pauseNetEaseOnly() -> Bool { false }
    ...
#endif
```

**判决：** 在 **保证** 提交二进制由 `LUMA_APP_STORE=1` 编译的前提下，**机器扫描可通过**。  
**残留风险：** 若误用 `build_app.sh`（无宏）上传 → **100% 自动拒审**。

**修改方案：**

- CI / Archive scheme **强制** `LUMA_APP_STORE=1`。
- 可选：把 MediaRemote 拆到独立 target，商店 target 根本不链接该文件。

### 2.2 CGEventPost / HID

| 用途 | 位置 | MAS |
|------|------|-----|
| 亮度键模拟 | `sendBrightnessKey` ~L16192 | `#if LUMA_APP_STORE` 直接拒绝 — **OK** |
| Cmd+C 复制选区 | 非商店 `AgentContextProvider.copySelectedText` | 商店 stub `completion(nil)` — **OK** |

**判决：** 商店二进制路径下 **无** `NX_KEYTYPE_PLAY` / 全局媒体键；Play/Pause 走 Bundle ID AppleScript。**通过（有条件）。**

### 2.3 Accessibility / ScreenCaptureKit

- 商店 `AgentContextProvider` 大量 AX 能力已 stub；全屏检测改用 `CGWindowListCopyWindowInfo`（公开）。
- `AppStoreDistribution.allowsAccessibilityFeatures = true` 与 stub 并存 —— **文案/菜单勿承诺已 stub 的能力**。
- Screen Recording：仅用户触发截图分析；需 `NSScreenCaptureUsageDescription`（已有）。

### 2.4 本节判决

**有条件通过。** 强制商店宏 + 禁止私有框架进入 Archive。

---

## 3. 🎨 界面与品牌合规（Guideline 5.2.5 & 商标）

### 3.1 Dynamic Island / 灵动岛模仿风险 — **高**

产品形态：摄像头两侧 `NSPanel` + 展开胶囊，高度接近 iPhone Dynamic Island 心智。

**审核关注点（5.2.5）：**

- 是否让用户以为这是 **Apple 系统功能**；
- Metadata / 截图 / 描述是否使用 Apple 产品名作为卖点。

**代码/文档中的高风险用词：**

- `README.md` / `README.zh-CN.md` / `README.en.md`：`Dynamic Island`、`灵动岛`、`MacBook`
- `docs/APP_REVIEW_NOTES.md`：`notch` 描述可保留，避免 “Dynamic Island”
- 主题名 **Liquid Glass**（`IslandTheme.liquidGlass`）：与 Apple 最新视觉品牌撞车，商店列表建议改名（如 “Clear Glass” / “Luma Glass”），应用内可保留实现（UI 冻结规则不阻止商店文案改名）

### 3.2 可接受表述建议（Metadata）

| 避免 | 改用 |
|------|------|
| Dynamic Island / 灵动岛 | menu bar companion / camera-area companion / floating music panel |
| MacBook notch（作为商标堆砌） | “displays beside the camera housing on supported Macs” |
| “Official Apple Music widget” | “Controls the Music app on your Mac” |
| Liquid Glass（商店名） | Clear / Prism / Luma Glass |

**应用名 `luma bar`：** 一般可接受；勿加 “for Dynamic Island”。

### 3.3 本节判决

**元数据 / 营销材料：不通过（提交前必须改文案）。**  
**UI 形态本身：** 有先例类 App，但需 **明确非系统 UI** + 原创 branding；仍有人工拒审主观风险（约 30–40%）。

---

## 4. 🎵 核心业务逻辑与稳定性

### 4.1 Play/Pause 互斥 — **PASS（直发）**

- `ExclusiveAudioFocus`：指定 `application id` Bundle ID，先 pause 对方再 playpause 目标。
- UI `togglePlayback` → `executeTargetedPlayPause`；注释明确禁止 NX_KEYTYPE / 全局 MediaRemote。
- `reconcileExclusiveAudioFocus` 有 1s 节流。

**MAS 注意：** `ExclusiveAudioFocus` **未** 被 `#if LUMA_APP_STORE` 关掉，依赖 Apple Events 例外；`NetEaseBridge` 商店 stub 导致部分路径（`playNetEaseOnly` 等）失效，但 `ExclusiveAudioFocus.playPauseNetEase()` 仍可能工作 —— **行为分裂**，需统一商店策略。

### 4.2 渲染与切 Space — **PASS**

- `VisualEffectBackground` → `LockedClearBackgroundView` 固定 layer 色；剥离 `NSVisualEffectView`。
- `IslandPanel.isRestorable = false`，`animationBehavior = .none`，`canBecomeKey/Main = false`。
- `suppressTransientIslandSurfaces` + `.opacity(0)` / `.clipped()` / `.allowsHitTesting(false)`（展开页 ~L8105、宠物 ~L18976）。
- `hardHideExpandedAndPetForSpaceTransition()` 在 Space 预切换路径调用。

**残留：** 极端多屏 + 外接显示器辅助区域 API 缺失时走 `fallbackCameraGap`（~L8898），布局可接受；非拒审项。

### 4.3 歌词区间与播放态绑定 — **PASS**

```22583:22597:Sources/LumaBar/main.swift
// currentTime >= start && currentTime < end
```

- `displayedIsPlaying`（Apple Music）→ `AppleMusicService.shared.playerState == .playing`
- tick 中强制同步 `isPlaying`；playpause 后 `refresh` 校验，避免纯本地乐观翻转

### 4.4 本节判决

**直发：通过。**  
**MAS：部分通过** —— 须解决沙盒例外 + 统一网易云商店能力说明（功能保留则修 stub；不保留则 Metadata 删除网易云卖点）。

---

## 5. ⚠️ 进程边界与异常捕获

### 5.1 目标 App 未启动时的 AppleScript — **WARN / 潜在卡顿**

```28:39:Sources/LumaBar/main.swift
NSAppleScript(source: script)?.executeAndReturnError(&error)
```

- 多数调用在 `DispatchQueue.global` —— **未直接堵死主线程**（优点）。
- **无超时**：Music/网易云未安装或首次启动时，Apple Events 可能触发启动或长时间等待 → 后台线程堆积、UI 状态长时间“错位”。
- 未检测 `NSWorkspace.shared.runningApplications` 是否已包含目标 Bundle。

**建议修复片段：**

```swift
nonisolated static func pauseApplication(bundleIdentifier: String) {
    let running = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == bundleIdentifier
    }
    guard running else { return } // 或：仅 openApplication，不 sync script

    // 可选：NSAppleScript 放到带超时的 Process/osascript，
    // 或 DispatchGroup.wait(wallTimeout:)
    ...
}
```

### 5.2 主线程 Timer — **WARN**

```10575:10580:Sources/LumaBar/main.swift
timer = Timer.scheduledTimer(timeInterval: 0.1, ...)  // 10 Hz
```

- 用于进度插值、歌词跟随、指标刷新 —— 审核员可能问「后台常驻为何 10Hz」。
- Combine：`AppDelegate.cancellables` 有 `store(in:)` —— 基本健康；注意闭包 `[weak self]`（多数已有）。

**建议：** 暂停且无展开时降到 1–2 Hz；播放中再升到 10 Hz。

### 5.3 版本号不一致 — **拒审/运营风险**

| 来源 | 版本 |
|------|------|
| git tag | `v0.3.2` |
| `Support/Info.plist` | `CFBundleShortVersionString = 0.2.2`，`CFBundleVersion = 5` |

**必须**在 Archive 前对齐（例如 0.3.2 / build 6+）。

### 5.4 本节判决

**有条件通过**（补超时/进程检测 + 降频 + 版本对齐）。

---

## 6. 📝 App Store Connect — Review Notes 草稿（可直接粘贴）

> **Review Notes — luma bar (macOS)**  
> Bundle ID: `com.lumabar.app`

### What the app is

luma bar is a **third-party** floating companion panel for Mac. It shows music controls, optional lyrics, light system glance info, and an optional AI assistant. It is **not** an Apple system feature and is not affiliated with Apple.

### Why we request Automation / Apple Events temporary exceptions

We request a **temporary exception for Apple Events** only for:

1. **`com.apple.Music`** — read now-playing metadata / position and send play, pause, playpause, next, previous, and seek so the panel stays in sync with the Music app the user already uses.  
2. **`com.netease.163music`** — the same minimal transport commands for NetEase Cloud Music when the user chooses that library. NetEase does not provide a public Mac SDK for transport control.

We do **not** use private MediaRemote APIs or synthesized global media keys (`NX_KEYTYPE_*` / HID posts) in the Mac App Store build. Transport is **targeted** by Bundle ID: before playing one app we pause the other, so two players do not run at once.

`com.apple.security.automation.apple-events` is enabled so macOS can show the standard Automation permission prompt. The temporary exception is required under App Sandbox so those user-approved Apple Events can reach only the two listed music apps.

### Demo account / steps

1. Install and launch luma bar.  
2. Open **Music** (and optionally NetEase Cloud Music), start a track.  
3. Use the panel Play/Pause / Next — only the selected player should respond; the other stays paused.  
4. Expand the panel to view lyrics (when available) and confirm the highlight follows the playhead.  
5. Optional: Agent — use a user-supplied API key; MAS build does **not** run arbitrary shell (`zsh`); confirmed actions are open app/URL, clipboard, or Shortcuts.

### Permissions you may see

- **Automation — Music / NetEase**：required for the sync described above.  
- **Microphone / Speech**：only if the user starts Voice Whisper.  
- **Screen Recording**：only if the user asks the Agent to analyze a screenshot.  
- **Files / folders**：Cursor/Codex usage overlays only after the user grants a folder via the system open panel (security-scoped bookmark). We do not silently read other apps’ data in the MAS build beyond what the user grants.

### Contact

Please contact us via App Store Connect if any entitlement justification needs more detail. We can provide a screen recording of Music + NetEase exclusive control on request.

---

## 已完美解决的技术亮点（可写进对内复盘）

1. **废弃 NSVisualEffectView 失焦变灰路径**，改为 `LockedClearBackgroundView` 固定 CALayer 填充。  
2. **Space 闪烁**：`isRestorable = false` + `suppressTransientIslandSurfaces` + opacity/clipped/hitTesting + hard `orderOut`。  
3. **双播放器互斥**与禁止全局媒体键（直发路径清晰）。  
4. **歌词闭区间**与 **Music.app `playerState` 绑定**。  
5. **商店宏**已剥离 MediaRemote / 亮度 CGEvent / 危险 AgentContext AX 复制路径。  
6. **SafeAgentActions** 限制商店版 Agent 执行面。

---

## 仍需修复的潜在漏洞 / 风险清单（上架前 P0–P2）

### P0 — 不修必拒 / 功能空洞

1. **补齐** `temporary-exception.apple-events`（Music + NetEase），并在 ASC 勾选对应能力。  
2. **统一商店网易云策略**：恢复沙盒安全的 AppleScript 控制，或 Metadata **删除**网易云卖点（当前 stub 会导致“宣传有、商店包无”）。  
3. **Archive 强制** `LUMA_APP_STORE=1`，防止 MediaRemote 混入。  
4. **对齐** `Info.plist` 版本到 `0.3.2`+。  
5. **重写** `NSAppleEventsUsageDescription`，明确 Music / 网易云控制（当前文案只提 Agent/浏览器，审核会抓不一致）：

```xml
<key>NSAppleEventsUsageDescription</key>
<string>luma bar uses Automation to control the Music app and NetEase Cloud Music for play/pause and lyrics sync when you use those features. It does not control other apps unless you explicitly confirm an Agent action.</string>
```

### P1 — 高概率追问 / 拒审

6. 商店 Metadata / 截图 / 描述：**删除** Dynamic Island、灵动岛、MacBook 商标堆砌；主题对外改名避开 Liquid Glass。  
7. AppleScript：**进程未运行则跳过** + 超时，避免卡顿投诉。  
8. 收口 `homeDirectoryForCurrentUser` 探测；商店仅书签路径。  
9. 主线程 Timer 空闲降频。  
10. 更新 `docs/APP_REVIEW_NOTES.md` 为第 6 节正文。

### P2 — 体验 / 体验

11. 多屏 / 无 auxiliaryTopArea 机型的 fallback 布局 QA。  
12. Hardened Runtime：商店分发用 Apple Distribution + App Store profile；`build_app_store.sh` 本地 ad-hoc 仅开发用。  
13. 隐私营养标签：披露 AI 提示词发往第三方。

---

## 推荐上架路线图（最短路径）

1. 修 P0 entitlements + Info.plist 文案 + 版本号。  
2. 决定网易云：例外 + AppleScript **或** 砍功能。  
3. 用 Xcode Archive（`LUMA_APP_STORE=1`）出包，`codesign -d --entitlements :-` 人工核对无 MediaRemote 符号：  
   `nm -u "luma bar.app/Contents/MacOS/LumaBar" | grep -i MediaRemote` 应为空。  
4. Metadata 按第 3 节清洗后提交，粘贴第 6 节 Review Notes。  
5. 预备申诉材料：互斥播放录屏、Automation 权限截图。

---

*本报告基于仓库静态审计，不替代 Apple 最终审核结果。Temporary Exception 是否获批以审核员裁量为准。*
