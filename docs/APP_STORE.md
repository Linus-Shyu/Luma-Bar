# Mac App Store — 付费单包上架指南

商店包走 **Xcode Archive**（方案 A）。GitHub 上的 Developer ID 公证包不能上传到 App Store。

## 工程侧

| 项 | 路径 / 命令 |
|----|-------------|
| Xcode 工程 | [`LumaBar.xcodeproj`](../LumaBar.xcodeproj)（Scheme：**luma bar**） |
| 沙盒 entitlements | [`Support/LumaBar.AppStore.entitlements`](../Support/LumaBar.AppStore.entitlements) |
| 商店编译宏 | Xcode 已强制 `LUMA_APP_STORE`（Debug / Release 都开） |
| 本地沙盒包（SwiftPM） | `./build_app_store.sh` |
| Archive / 上传 | `./scripts/archive_app_store.sh` 或加 `--upload` |
| 审核备注 | [`APP_REVIEW_NOTES.md`](APP_REVIEW_NOTES.md) |

商店构建行为：

- **无**任意 `zsh`；仅 `open -a/-b`、URL、剪贴板、Shortcuts。
- **无**私有 `MediaRemote`（Archive 有符号守卫，命中即失败）。
- Cursor / Codex 监控需用户在菜单 **Agent → Data Access** 授权文件夹。
- 辅助功能 / 屏幕录制仍按系统弹窗授权。

当前商店版 **网易云控制是 stub**。商店描述里不要写「完整控制网易云」，否则必拒。

---

## 1. App Store Connect（网页，先做完）

1. 用公司 Apple Developer 登录 [App Store Connect](https://appstoreconnect.apple.com)。
2. 新建 App → 平台 **macOS** → Bundle ID **`com.lumabar.app`**（需先在 Certificates, Identifiers & Profiles 创建 Mac App ID，打开 App Sandbox）。
3. Certificates 里准备：
   - **Apple Distribution** / Mac App Distribution（签 .app）
   - **Mac Installer Distribution**（Xcode 上传 pkg 时用）
4. **定价**：付费单包，选价格档。
5. 填写：隐私政策 URL（必须可打开，草稿见 [`PRIVACY_POLICY_STUB.md`](PRIVACY_POLICY_STUB.md)）、截图、描述、分类（Utilities / Productivity）。
6. 银行与税务、出口合规、年龄分级、隐私营养标签。
7. 提交审核时粘贴 [`APP_REVIEW_NOTES.md`](APP_REVIEW_NOTES.md)。

文案不要写 Dynamic Island、灵动岛、Liquid Glass，也不要冒充系统功能。

---

## 2. 用 Xcode Archive 出包（你选的方案 A）

本机已有 Apple Development 证书即可先 Archive；上传前再补 **Apple Distribution**。

### 图形界面

1. 打开 `LumaBar.xcodeproj`（不要打开 Swift 包文件夹当工程）。
2. 顶部 Scheme 选 **luma bar**，目的地选 **My Mac**。
3. Signing & Capabilities 确认 Team 是 **Faxin Xu (2DZ36MCTK5)**，Automatically manage signing。
4. **Product → Archive**。
5. Organizer 里选这份 Archive → **Distribute App** → **App Store Connect** → Upload。
6. 到 Connect → TestFlight（Mac）加内部测试员，通过后再 Submit for Review。

### 命令行

```bash
# 只打 Archive（随后在 Xcode Organizer 里分发）
./scripts/archive_app_store.sh

# Archive 并按 exportOptions 上传到 App Store Connect
./scripts/archive_app_store.sh --upload
```

上传用 [`Support/exportOptions-appstore.plist`](../Support/exportOptions-appstore.plist)（`method = app-store-connect`）。

### 上传前自检

Archive 产物里应满足：

```bash
APP="dist/LumaBar.xcarchive/Products/Applications/luma bar.app"
nm -u "$APP/Contents/MacOS/LumaBar" | grep -i MediaRemote   # 必须无输出
codesign -d --entitlements :- "$APP"                        # 必须有 app-sandbox 和两条 apple-events 例外
```

---

## 3. TestFlight（Mac）

Archive 上传后，在 App Store Connect → TestFlight 添加内部测试员，先装沙盒版验证：

- 刘海 UI / Apple Music 播放暂停与歌词（会要 Automation）
- Agent 对话 + Safe Action（`open -a Safari`）
- 授权 Cursor 文件夹后配额显示
- Voice Whisper 麦克风权限

---

## 4. 隐私营养标签（建议勾选）

- 未做分析就选不收集。
- Agent 使用用户自备 API Key：披露「与第三方 AI 服务共享用户提交的提示内容」；Tracking 关掉。

---

## 5. 和直发版的关系

| | GitHub / `build_app.sh` | 本 Xcode 工程 |
|--|-------------------------|----------------|
| 签名 | Developer ID + 公证 | Apple Distribution + 沙盒 |
| 宏 | 无 `LUMA_APP_STORE` | **强制** `LUMA_APP_STORE` |
| 用途 | 官网 / 内部 DMG | Mac App Store / TestFlight |

两套可以并存。不要把 GitHub Release 的 `.dmg` 传到 Connect。
