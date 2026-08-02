# Mac App Store — 付费单包上架指南

## 工程侧（已具备）

| 项 | 路径 / 命令 |
|----|-------------|
| 沙盒 entitlements | [`Support/LumaBar.AppStore.entitlements`](../Support/LumaBar.AppStore.entitlements) |
| 商店编译宏 | `LUMA_APP_STORE=1`（见 `Package.swift`） |
| 本地沙盒包 | `./build_app_store.sh` |
| 安全 Agent | [`SafeAgentActions.swift`](../Sources/LumaBar/SafeAgentActions.swift) |
| 目录授权 | [`SecurityScopedBookmarks.swift`](../Sources/LumaBar/SecurityScopedBookmarks.swift) |

商店构建行为：

- **无**任意 `zsh`；仅 `open -a/-b`、URL、剪贴板、Shortcuts。
- Cursor / Codex 监控需用户在菜单 **Agent → Data Access** 授权文件夹。
- 辅助功能 / 屏幕录制仍按系统弹窗授权。
## App Store Connect（你要在网页完成）

1. 用**公司** Apple Developer 登录 [App Store Connect](https://appstoreconnect.apple.com)。
2. 新建 App → 平台 **macOS** → Bundle ID `com.lumabar.app`（需先在 Certificates, Identifiers & Profiles 创建）。
3. **定价**：设为付费 App（购买后才能下载），选一个价格档。
4. 填写：隐私政策 URL（建议 `https://linusshyu.dev/privacy`）、截图、描述、分类（Utilities / Productivity）。
5. 银行与税务信息、出口合规问卷。
6. 用 Xcode **Product → Archive**（需把本 SPM 工程导入 Xcode 或用 `xcodebuild` + App Store 证书）→ Distribute → App Store Connect。
7. 提交审核时粘贴 [`APP_REVIEW_NOTES.md`](APP_REVIEW_NOTES.md)。

## TestFlight（Mac）

Archive 上传后，在 App Store Connect → TestFlight 添加内部测试员，先装沙盒版验证：

- 刘海 UI / 音乐
- Agent 对话 + Safe Action（`open -a Safari`）
- 授权 Cursor 文件夹后配额显示
- Voice Whisper 麦克风权限

## 隐私营养标签（建议勾选）

- Product Interaction（可选分析，若你未做则选不收集）
- 若 Agent 使用用户自备 API Key：披露「与第三方 AI 服务共享用户提交的提示内容」；数据不用于追踪则关掉 Tracking。
