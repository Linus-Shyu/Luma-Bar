# AdventureX 2026 作品提交稿 · Luma Bar

> 下面按提交表 1–11 题直接可粘贴。带「待你填写」的项请在提交前补齐；带「请对照表单选项确认」的项请以现场下拉菜单的正式名称为准。

---

## 1. 作品名称

**Luma Bar**

---

## 2. 一句话的作品简述

围绕 MacBook 摄像头刘海生长的原生 macOS 灵动岛：把音乐、本地 Agent、任务提醒、系统控制与桌面宠物收进同一块缺口界面。

---

## 3. 作品详细描述（支持 Markdown）

可直接粘贴下方 Markdown：

```markdown
# Luma Bar

Luma Bar 是一款原生 macOS 应用，把 MacBook 摄像头两侧的刘海空间做成真正可用的桌面工作区，而不是又一个悬浮小组件。

## 它解决什么问题

写代码、听歌、切全屏、开 Cursor / Codex、查系统状态时，注意力不断被菜单栏、通知中心和一堆独立窗口打断。Luma Bar 把这些高频上下文收进摄像头两侧：默认极简，悬停即展开，全屏时优雅退场，回到桌面再出现。

## 核心能力

- **原生刘海布局**：避开中间摄像头，贴合 MacBook 硬件外形
- **音乐工作台**：本地曲库 + 网易云状态，封面、进度、同步歌词与歌单一屏完成
- **本地 Agent**：基于 OpenAI；可发信息、控播放、调音量亮度、开关 Wi-Fi / 深色模式、锁屏、打开本地应用；支持长期偏好与近期操作记忆
- **Voice Whisper**：`⌘ ⇧ M` 中文语音直达 Agent 输入框
- **Cursor / Codex 感知**：显示上下文窗口用量，单个任务完成时在刘海内提醒（全屏时用独立 toast）
- **系统监控 + 像素宠物**：CPU / 内存 / 磁盘 / 电池 / 网络，并按时间、天气、当前应用主动聊天
- **全屏友好动画**：Space 切换与全屏进出时平滑隐藏 / 恢复，减少闪烁
- **多套主题**：AdventureX 硬件控制台风、玻璃风、像素宠物风

## 为什么值得试

它不是网页壳，也不是单纯 AI 聊天框，而是把「此刻你在干什么」接到刘海 UI 上：听歌时展开音乐，写代码时盯住上下文窗口，Agent 真正能动本机，宠物会根据场景插话。

## 现场可演示

1. 悬停刘海展开 → 切主题 → 看音乐 / 歌词
2. 打开 Cursor Agent → 看 token 环与任务完成提醒
3. 对 Agent 说「下一首 / 发消息给妈妈（需确认）/ 把音量调低」
4. 切到全屏应用看隐藏动画，再切回桌面看恢复
5. 观察像素猫在写代码或阴雨天时的主动气泡

## 分发

公开下载（无源码）：https://github.com/Linus-Shyu/Luma-Bar-Download/releases/latest

源码仓库（私有）：https://github.com/Linus-Shyu/Luma-Bar

`#adventurex2026`
```

---

## 4. 说明你的项目利用了哪些技术

可直接粘贴：

```text
- Swift 6 / SwiftUI / AppKit：原生刘海面板、展开仪表盘、主题与动画
- NSPanel + Core Animation：多段灵动岛窗口、全屏 / Space 切换淡入淡出与形变
- Accessibility API：前台窗口上下文与全屏检测
- SQLite：读取 Cursor / Codex / 网易云本地元数据（只读）
- MediaRemote / AppleScript / JXA：系统播放与音乐控制
- Speech Framework + AVFoundation：Voice Whisper 中文语音转写
- Contacts + Messages Automation：通讯录解析与需确认的发信
- CoreAudio / CoreWLAN / CGSession：音量、Wi-Fi、锁屏等系统控制
- Keychain + UserDefaults：API Key 与本地偏好 / 操作记忆
- OpenAI Responses API：远程模型流式对话与本地工具规划
- Open-Meteo：宠物气泡用的本地天气
- GitHub Releases + universal binary（arm64 / x86_64）：公开 DMG 分发
```

更短版（若字数受限）：

```text
Swift / SwiftUI / AppKit、Accessibility、SQLite、Speech、Keychain、OpenAI API、网易云/Cursor/Codex 本地数据只读集成、Core Animation 全屏动画
```

---

## 5. 上传图片或者视频的轮播图

**要求**：至少 1 张；第一张为封面；**16:9**。

本地已准备好可上传文件（均 `1920×1080`）：

| 顺序 | 建议用途 | 文件路径 |
|------|----------|----------|
| **1（封面）** | Agent 读屏翻译 / 产品主视觉 | `docs/images/adventurex-cover-16x9.png` |
| 2 | AdventureX 主题音乐台 | `docs/images/adventurex-carousel-luma-bar-music-16x9.png` |
| 3 | 系统监控 + 像素猫 | `docs/images/adventurex-carousel-luma-bar-system-pet-16x9.png` |
| 4 | Cursor 上下文接近上限提醒 | `docs/images/adventurex-carousel-luma-bar-context-limit-16x9.png` |

> 若表单还支持视频：建议补一段 20–40 秒录屏（悬停展开 → 音乐 → Cursor 提醒 → 全屏隐藏），封面仍用第 1 张图。

---

## 6. 选择主题（只能选 1 个）

来源：AdventureX 2026 官方主题 A–E（需观看对应视频确认方向）。  
**表单限制：主题只能选 1 个。**

| 选择 | 正式名称 | 为什么只选它 |
|------|----------|--------------|
| **最终勾选** | **E · Reverse 反转** | 最贴 Luma Bar 核心叙事：反转「AI 住在别人的网页标签里」→「AI 住在你的刘海与桌面上」；也反转摄像头缺口是废空间 |

**备选（仅当视频定义与上面不符时再换）：**

| 备选 | 正式名称 | 何时改选 |
|------|----------|----------|
| 2 | D · Kaleidoscope 万花筒 | 视频强调多形态拼贴、万花筒式体验时 |
| 3 | A · 8bit 元境 | 视频强调像素 / 8bit 世界时 |
| 4 | C · .xyz 未知域 | 视频强调未知交互疆域时 |
| 不选 | B · PAWN 弈棋 | 与当前产品叙事较弱 |

**表单直接粘贴：**

```text
E · Reverse 反转
```

> 主题视频未在对话中解析；若现场视频对 E 的定义完全不同，告诉我，我只改这 1 个主题名。

---

## 7. 赛道（最多不超过 6 个）

**官方赛道表：** https://adventurex.feishu.cn/share/base/view/shrcnDtHB7f5NTUAwMeiIJhNnNd  
**解析状态：已根据你粘贴的全文完成匹配。**  
**表单限制：赛道最多 6 个。**

### 最终建议勾选（默认填满 6 个，按优先级）

| # | 正式赛道名 | 匹配度 | 说明 |
|---|------------|--------|------|
| 1 | **02 · Desktop Daemon｜陪你一起创造的桌面常驻精灵**（清闲智能） | ★★★★★ | 最贴：本地常驻、守住创造环境、Agent 不该只活在云端标签页 |
| 2 | **07 · 小红书 · Build in Public 赛道** | ★★★★★ | 提交表本就要求小红书 + `#adventurex`；产品也适合晒构建过程 |
| 3 | **05 · 不做第一，做唯一：做一个只有你能做出来的东西**（智能少年 / 未来火种） | ★★★★☆ | 刘海原生灵动岛 + 桌面宠物 + 开发者上下文，独特性故事强 |
| 4 | **10 · Hack the Rest 重新创造休息**（蓝盒子） | ★★☆☆☆ | 少打断、宠物陪伴、回到桌面恢复节奏；冲创意位 |
| 5 | **08 · 干杯！创造属于你的B站新纪元**（bilibili） | ★★☆☆☆ | **若你不做 B 站直播/产品向演示，可删掉腾名额** |
| 6 | **17 · Superun: Context to Code｜不比代码，比谁离问题最近** | ★★☆☆☆ | **仅当你实际用 Superun 做了主体逻辑再勾；否则删掉** |

**表单可直接粘贴（稳健版，不依赖额外工具，推荐默认就这 3 个）：**

```text
02 Desktop Daemon｜陪你一起创造的桌面常驻精灵
07 小红书 · Build in Public 赛道
05 不做第一，做唯一：做一个只有你能做出来的东西
```

**若要凑满接近 6 个，且未用 Superun、不做 B 站，用这组：**

```text
02 Desktop Daemon｜陪你一起创造的桌面常驻精灵
07 小红书 · Build in Public 赛道
05 不做第一，做唯一：做一个只有你能做出来的东西
10 Hack the Rest 重新创造休息
```

（留 2 个空位也完全没问题；质量优于硬凑。）

若你确认用过 Superun / 会做 B 站直播，再把 17 / 08 追加进去，总数不超过 6。
### 明确不建议勾（容易废材料）

| 赛道 | 原因 |
|------|------|
| **14 阶跃星辰「前端自进化工厂」** | 赛道要求的是无人值守前端生成/验证闭环，与 Luma Bar 不是一类产品 |
| 01 Injective | 必须上链 |
| 03 Qoder / 03 灵光 / 06 Amazon Quick·Kiro / 16 秒哒 | 强制指定开发平台 |
| 09 Dimensional / 12 松灵 / 13 PICO / 20 地瓜 / 21 涂鸦 / 22 viaim / 23 Zilo | 强制指定硬件/SDK |
| 11 WOPC 文化出海 / 15 度小满理财 / 18 PandaAI 交易 / 19 米哈游发行 | 垂直命题不符 |
| 24 Photon | 需 Spectrum 接 iMessage 身份；你现有的是本机 Messages，不是 Photon |

### 各推荐赛道一句话答辩草稿

**02 Desktop Daemon**  
Luma Bar 是住在 MacBook 刘海里的桌面常驻精灵：本地 Agent、音乐、系统状态与像素猫 24h 贴着你的屏幕，关掉浏览器也不会消失；它守住的是「少打断、连续专注」的创造环境。

**07 小红书 Build in Public**  
我们把刘海产品从 0 到 1 的过程公开构建：权限坑、全屏动画、Cursor 提醒、网易云兼容，用笔记持续晒出来，让社区看见原生 macOS Agent 桌面形态。

**05 不做第一，做唯一**  
痴迷点是 Mac 硬件缺口本身；优势是原生 Swift/AppKit 深水区；真实需求是写代码/听歌/切全屏时的连续上下文——这块只有贴着摄像头两侧的灵动岛做得出来。

### 全表速查（01–24 + 主题 A–E）

| ID | 主办 | 正式名称 | 与 Luma Bar |
|----|------|----------|-------------|
| 01 | Injective | Injective Blockchain x AI 创新赛道 | 不匹配 |
| **02** | **清闲智能** | **Desktop Daemon｜陪你一起创造的桌面常驻精灵** | **首选** |
| 03 | 灵光 | 「见自己」——先为自己 Vibe | 需用灵光产品 |
| 03 | Qoder | Qoder 小团队高效开发赛道 | 需用 Qoder |
| **05** | **智能少年** | **不做第一，做唯一** | **推荐** |
| 06 | 亚马逊云科技 | 快快快 Quick Quick Amazon Quick | 需 Quick/Kiro |
| **07** | **小红书-科技** | **小红书 · Build in Public 赛道** | **推荐** |
| 08 | bilibili | 干杯！创造属于你的B站新纪元 | 可选 |
| 09 | Dimensional | Agents 触碰真实世界 | 需机器狗/机械臂 |
| 10 | 蓝盒子 | Hack the Rest 重新创造休息 | 弱相关可选 |
| 11 | 超级合子 WOPC | 新国货出海 / 福建老酒 | 不匹配 |
| 12 | 松灵机器人 | 教会机器人新技能 | 需机器人 |
| 13 | PICO | Escape the Rectangle / PICO OS 6 | 需 PICO |
| 14 | 阶跃星辰 | 无人值守的前端自进化工厂 | 赛道命题不符，勿选 |
| 15 | 度小满 | Money Whisperer AI native 理财 | 不匹配 |
| 16 | 百度秒哒 | 秒哒·应用美学赛道 | 需秒哒平台 |
| 17 | 有赞+superun | Context to Code | 仅用了 Superun 才勾 |
| 18 | PandaAI | Build the Next AI Trader | 不匹配 |
| 19 | 米哈游 | 发行二周目 | 不匹配 |
| 20 | 地瓜机器人 | Give AI a Body / RDK | 需 RDK |
| 21 | 涂鸦智能 | 破界者：用AI重写生活脚本 | 需涂鸦硬件 |
| 22 | viaim | 耳边的好AI / AI Agent 耳机 | 需耳机 SDK |
| 23 | 弦指科技 | 从指尖出发 / Zilo Whisper 戒指 | 需戒指 |
| 24 | Photon | 消息即界面：给 Agent 一个手机号 | 需 Photon Spectrum |
| A–E | AdventureX | 8bit 元境 / PAWN / .xyz / 万花筒 / Reverse | 见第 6 节 |
---

## 8. 您的队友（最多 3 个，不含自己）

**暂无（独立参赛）**

若有队友，按表单格式填写姓名 / 昵称即可，例如：

```text
（待填）队友 A
（待填）队友 B
```

---

## 9. 作品的 GitHub 仓库链接

**公开下载仓库（推荐填给评委，可直接下载体验）：**

https://github.com/Linus-Shyu/Luma-Bar-Download

**源码仓库（私有）：**

https://github.com/Linus-Shyu/Luma-Bar

> 若表单只允许填一个：填 **Luma-Bar-Download**。若评委需要看源码，再单独开临时 Collaborator 或现场演示源码。

---

## 10. 小红书发布帖子的链接

**待你填写**

要求：图文或视频笔记均可，正文需带 **`#adventurex`**（建议同时加 `#adventurex2026` `#LumaBar`）。

发帖可用文案草稿：

```text
把 MacBook 刘海做成真正能干活的灵动岛。

Luma Bar：音乐、本地 Agent、Cursor/Codex 提醒、系统监控和像素猫，都长在摄像头两侧。
悬停展开，全屏自动退场，回到桌面再出现。

下载：GitHub Luma-Bar-Download
#adventurex #adventurex2026 #LumaBar #macOS #灵动岛
```

发完把笔记链接贴回这里替换本项。

---

## 11. 项目尝试链接（可选）

https://github.com/Linus-Shyu/Luma-Bar-Download/releases/latest

安装提示（可写在备注里）：

1. 下载 DMG → 拖入「应用程序」
2. 首次启动请 **右键 → 打开**（当前为 Development 签名，尚未公证）
3. 按需授权：辅助功能、麦克风 / 语音识别、自动化、通讯录；网易云 / Cursor 深度能力可能需要完全磁盘访问
4. Agent 远程模型需自行配置 OpenAI API Key

---

## 提交前自检

- [ ] 封面已用 `adventurex-cover-16x9.png`（16:9）
- [x] 主题已定为 **仅 1 个**：`E · Reverse 反转`
- [x] 赛道建议已写入第 7 节（默认稳健 3 个：02 + 07 + 05；最多不超过 6）
- [ ] 若使用 Superun / 做 B 站直播，再决定是否追加 17 / 08
- [ ] 小红书链接已补上且含 `#adventurex`（同时服务第 10 题与赛道 07）
- [ ] GitHub 链接评委可打开（至少 Download 仓库公开）
- [ ] 若有队友，已不超过 3 人且不含自己

`#adventurex2026`
