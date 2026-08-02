# Luma Bar v0.3.3 更新报告

**日期：** 2026-08-03  
**版本：** `0.3.3`（build `7`）  
**Git tag：** `v0.3.3`

---

## 摘要

本版重点修复多源音乐控制的两大体验问题：**切源幽灵自动播放**、**双源叠音延迟冲突**；并同步推进 Mac App Store 合规材料与沙盒构建护栏。

---

## 1. 多源音乐控制（核心）

### 纯净切源（Source Selection Only）

- 频道切换按钮（网易云 ↔ Apple Music ↔ Local）**只切换视觉焦点**：封面、歌词、列表与控制路由。
- **禁止**在切源时发送任何 `play` / `pause` / `resume`。
- 旧 App 后台状态完全保持：正在播就继续播，已暂停就保持暂停。

### 强互斥抢占（Exclusive Audio Focus）

- **唯一**能改变播放状态的入口：主播放/暂停按钮、点选具体曲目、切歌等显式操作。
- 当用户对目标 App 发出显式 `play` 时：
  1. **先阻塞式**向旧源发送 `pause`（切断音频独占）
  2. **再立即**向新源发送 `play`
- 去掉「先播再等几秒才停旧源」的延迟窗口，避免双源同时出声。

### 网易云暂停兜底修正

- 根因：AppleScript `pause` 失败后用 **Space** 兜底；Space 是**切换键**，在已暂停时会误触发播放（幽灵播放）。
- 修复：仅在确认网易云「很可能正在播放」时才允许 Space；已暂停则不再乱按 Space。

---

## 2. Mac App Store / 合规

- `Support/LumaBar.AppStore.entitlements`：补充 `temporary-exception.apple-events`（仅 `com.apple.Music` + `com.netease.163music`）。
- `build_app_store.sh`：强制 `LUMA_APP_STORE=1`，并增加 MediaRemote 符号 / 路径守卫。
- `Support/Info.plist`：更新 Apple Events 用途说明；版本对齐至 `0.3.3 (7)`。
- `docs/APP_REVIEW_NOTES.md`：重写审核备注（Temporary Exception 正当性、Demo 步骤）。
- `docs/MAS_COMPLIANCE_AUDIT.md`：上架合规评估底稿（评估时点快照，后续可按修复进度修订结论）。

---

## 3. 其它相关修复（同批入库）

- Apple Music 安全播放：有当前曲目才 `play`，空队列不强行唤醒。
- 悬停展开 / Liquid Glass 交互稳定性相关修正（同批 `main.swift` 改动）。
- 网易云收藏相关小改动（`NetEaseFavorite.swift`）。

---

## 4. 建议自测清单

1. 网易云正在播放 → 只点切到 Apple Music：**不应**自动播 Music；网易云后台继续播。
2. 再点 Luma Bar 主播放（Apple Music 频道）：Music 开始播，网易云应**立刻**静音。
3. 反过来：Music 在播 → 切到网易云频道：只换 UI；点播放后 Music 立刻暂停、网易云起播。
4. 空队列 / 无可播曲目时点播放：不弹错、不强行报错。
5. （可选）`./build_app_store.sh` 构建通过，且无 MediaRemote 守卫报错。

---

## 5. 回滚

```bash
git checkout v0.3.3
# 或回到上一版：
git checkout v0.3.2
```
