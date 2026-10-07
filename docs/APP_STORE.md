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
- **无** `System Events` / UI 脚本；Apple Events 目标只有 `com.apple.Music` 和用户主动发信息时的 `com.apple.MobileSMS`。网易云没有脚本字典，商店包不向它发任何 Apple Event，也不申请对应例外。
- 屏幕录制只在用户要求截图分析时申请（ScreenCaptureKit）。通讯录只在用户要求按姓名发信息时申请。
- Cursor / Codex 监控需用户在菜单 **Agent → Data Access** 授权文件夹。
- 商店版不申请辅助功能。划词翻译默认关闭，用户在状态栏菜单「划词翻译」里打开，第一次会弹窗说明复制的文字会发给 AI 服务（DeepSeek 或用户选的 OpenAI），点「开启」才生效；开启后连按两下 ⌘C 触发（第一次只复制，第二次才翻译）。全屏判断用公开的窗口列表。
- 像素宠物（PixelCat / PixelDog / PixelPanda）由 Xcode 脚本阶段拷入 `Resources/`，与字体同一阶段。

商店版网易云只走审核允许的公开能力：

- **播放 / 暂停**：公开 `orpheus://`（`{"cmd":"resume"}`，暂停同时发 `{"cmd":"pause"}` 和 `{"cmd":"pausePlayer"}`）。不需要 entitlement，也不会抢焦点。
- **点歌 / 上一首 / 下一首**：同一条公开命令 `{"cmd":"play","type":"song","id":"<数字id>"}`（键顺序不能变）。
- **歌单 / 正在播放**：用户用系统打开面板授权网易云 storage 文件夹后，只读其中的 SQLite；封面和歌词走 `music.163.com` 的公开 HTTP 接口。不静默探测其他 App 的容器或 Cookie。
- **已下载的普通音频**（mp3 / m4a / flac …）：用户再授权音乐文件夹后，由 Luma Bar 自己解码播放，进度条、拖动、逐行歌词都可用。加密的 `.ncm` 容器不解、不碰，仍交给网易云客户端。
- **网易云自己在播的歌**没有公开进度接口：商店版按开始时间估算，估算可信时画只读进度条，不可信时隐藏；歌词同样只在可信时高亮。拖动只对已下载的普通音频生效：Luma Bar 暂停网易云，用自己的播放器从拖到的位置接着放。

商店描述里不要写「完整控制网易云」或「灵动岛」。

Info.plist 已声明 `ITSAppUsesNonExemptEncryption = false`（只用 HTTPS，属豁免），Connect 上传后不再追问出口合规。

---

## 1. App Store Connect（网页，先做完）

1. 用公司 Apple Developer 登录 [App Store Connect](https://appstoreconnect.apple.com)。
2. 新建 App → 平台 **macOS** → Bundle ID **`com.lumabar.app`**（需先在 Certificates, Identifiers & Profiles 创建 Mac App ID，打开 App Sandbox）。
3. Certificates 里准备：
   - **Apple Distribution** / Mac App Distribution（签 .app）
   - **Mac Installer Distribution**（Xcode 上传 pkg 时用）
4. **定价**：付费单包，选价格档。
5. 填写：隐私政策 URL **https://linusshyu.dev/privacy/**（草稿见 [`PRIVACY_POLICY_STUB.md`](PRIVACY_POLICY_STUB.md)）、截图、描述、分类（Utilities / Productivity）。
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
codesign -d --entitlements - --xml "$APP" | plutil -p -      # 必须有 app-sandbox；apple-events 只含 Music、MobileSMS（不应有 NetEase）；
                                                              # 有 addressbook（仅信息查找）；不应出现 music-library
plutil -p "$APP/Contents/Info.plist" | grep -E 'Version|Encryption'
ls "$APP/Contents/Resources" | grep -E 'Pixel(Cat|Dog|Panda)|Fonts'   # 三个宠物目录 + Fonts 都要在
```

### 上传前证书

本机只有 **Apple Development** 与 **Developer ID Application** 时，`--upload` / Organizer 分发会要求 **Apple Distribution** + **Mac Installer Distribution**。在 Xcode → Settings → Accounts → Manage Certificates 里点 “+” 创建即可，自动签名会自行选用。

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
