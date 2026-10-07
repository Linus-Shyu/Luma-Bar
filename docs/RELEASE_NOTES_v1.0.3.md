# Luma Bar v1.0.3 更新报告

**日期：** 2026-09-30  
**版本：** `1.0.3`（build 12）  
**Git tag：** `v1.0.3`  
**对比基线：** `v1.0.2`

---

## 摘要

面向 **Mac App Store 提交** 的整理版：商店构建（`LUMA_APP_STORE`）不再触碰 entitlements 之外的 Apple Events 目标，去掉未使用的 entitlements，修复 Xcode Archive 漏掉像素宠物资源的问题，并同步版本号与文档。视觉（Liquid Glass / 岛条）与直发版行为不变。

---

## 1. 商店构建收口（仅影响 `LUMA_APP_STORE`）

- **网易云 Space 兜底**：`ExclusiveAudioFocus.sendNetEaseSpaceKeyViaSystemEvents` 在商店构建直接返回 `false`。`com.apple.systemevents` 不在 `temporary-exception.apple-events` 里，沙盒下该脚本本就无法投递，且 UI 脚本与审核备注「仅按 Bundle ID 控制播放」冲突。
- **Automation 权限探测**：`PermissionOnboarding.probeAutomation` 商店构建只探测 `com.apple.Music`，不再对 System Events 发 `AEDeterminePermissionToAutomateTarget`。
- **屏幕录制**：商店版使用公开的 ScreenCaptureKit，只在用户要求截图分析时申请屏幕录制权限。

## 2. Entitlements

`Support/LumaBar.AppStore.entitlements` 移除：

- `com.apple.security.personal-information.music-library`（工程未使用 MediaPlayer / MusicKit）

保留并补回：app-sandbox、network.client、user-selected 读写 + app-scope 书签、automation.apple-events，临时例外只有 `com.apple.Music` 和 `com.apple.MobileSMS`（没有网易云），addressbook（仅用户主动发信息时查联系人）、audio-input。

## 3. Xcode 工程 / 打包

- 「Copy pixel fonts」脚本阶段改为 **「Copy pixel fonts and sprites」**：额外把 `Support/Assets/PixelCat|PixelDog|PixelPanda` 拷入 `Contents/Resources/`。此前 Archive 只带字体，商店包里像素宠物是空的。
- `MARKETING_VERSION = 1.0.3`、`CURRENT_PROJECT_VERSION = 12`，与 `Support/Info.plist` 一致。
- `Info.plist` 新增 `ITSAppUsesNonExemptEncryption = false`。

## 4. 仓库整理

- `.gitignore` 新增 `document/`（个人文件），去掉重复的 `*.xcuserstate`。
- `docs/APP_STORE.md` / `docs/APP_REVIEW_NOTES.md` 与实际商店行为对齐；`docs/MAS_COMPLIANCE_AUDIT.md` 标注为历史快照。

## 5. 未改动

- Liquid Glass / 岛条视觉。
- 直发（Developer ID）路径：MediaRemote、`CGEvent.postToPid`、Messages、截图等能力保持原样。
- `.github/workflows/` 与公证脚本。

---

## 提交前仍需人工完成

1. 上传需要 **Mac Installer Distribution** 证书（Xcode → Settings → Accounts → Manage Certificates 里创建）。本机已有 Apple Distribution。
2. 把 `docs/PRIVACY_POLICY_STUB.md` 托管到可公开访问的 URL，填入 App Store Connect。
3. Connect 上补齐截图、描述（不得出现 Dynamic Island / 灵动岛 / Liquid Glass 字样）、定价、隐私营养标签。
4. `./scripts/archive_app_store.sh --upload` 或在 Organizer 上传，随后 TestFlight 验证一轮。

## 回滚

```bash
git checkout v1.0.2
```
