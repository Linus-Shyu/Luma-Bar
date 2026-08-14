# Luma Bar v1.0.0 更新报告

**日期：** 2026-08-15  
**版本：** `1.0.0`（build 9）  
**Git tag：** `v1.0.0`  
**对比基线：** `v0.5.0-dev.1`

---

## 摘要

这一版把 Luma Bar 从内部预发推到 **1.0 正式版号**，主要做了三件事：**Mac App Store 上架工程化**、**岛条不再遮挡菜单栏图标**、以及一批**打包与构建的稳定性修复**。

---

## 1. 岛条不再挡住菜单栏图标

在**没有刘海**的显示器上（外接屏、合盖使用），岛条原先固定钉在屏幕顶部正中，窗口层级和系统状态项同为 `statusBar`，会直接压住其它 App 的菜单栏图标。

- 新增菜单栏状态项探测：读取 layer 25 的状态项窗口，算出当前屏幕上图标的最左边缘。
- 岛条**保持水平居中**（几何中心锁在 `screen.midX`），只在快要触碰图标时**左右对称收窄**，中线不动。
- 收窄有下限：封面区和播放 / 展开 / 下一首控件始终可用；仍不够时才压缩中间的摄像头缝。
- 图标增减后约 1 秒内自动跟随；只挪位置时轻量重排，宽度变化时才重建内容。
- 有刘海的机器沿用系统提供的刘海两侧安全区，行为不变。

## 2. Mac App Store 上架准备

- 新增 `LumaBar.xcodeproj`：`luma bar` scheme 走 `LUMA_APP_STORE` 编译条件，`MARKETING_VERSION` 与 `Info.plist` 对齐。
- 新增 `Support/Assets.xcassets`：完整 AppIcon 图标集（16 – 1024）。
- 新增 `scripts/archive_app_store.sh`：一键 archive，`--upload` 走 `Support/exportOptions-appstore.plist` 上传 App Store Connect。
- 沙盒授权补 `com.apple.security.personal-information.addressbook`。
- `Info.plist`：版号提到 `1.0.0`，补 `LSUIElement`（纯菜单栏 App）与 `LSApplicationCategoryType`。
- `docs/APP_STORE.md` 重写上架流程。

## 3. 修复与清理

- **关于窗口换行**：本地化里的 `\\n` 被当字面量输出，版本号和版权信息挤成一行；改为解析真实换行，12 个语种同步。
- **品牌资源瘦身**：`LumaBar.icns` 1.1 MB → 403 KB，App Icon / Logo PNG 同步压缩，删掉不再使用的 SVG 源文件。
- **构建告警清理**：消除 Sendable 与多余 `await` 告警（`AppleMusicService`、`main.swift`）。
- **CI**：release workflow 的 Actions 升到 Node 24 运行时。
- `.gitignore` 忽略 `xcuserdata/` 与 `*.xcuserstate`。

---

## 验证要点

1. 外接屏（无刘海）：菜单栏图标很多时，岛条应居中且不压到最左那颗图标；图标增减后约 1 秒自适应。
2. 内建刘海屏：岛条位置与宽度与上一版一致。
3. 关于窗口：版本号、build、版权分三行显示。
4. `./scripts/archive_app_store.sh` 可完成 archive。
