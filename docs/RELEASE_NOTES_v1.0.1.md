# Luma Bar v1.0.1 更新报告

**日期：** 2026-09-01  
**版本：** `1.0.1`（build 10）  
**Git tag：** `v1.0.1`  
**对比基线：** `v1.0.0`

---

## 摘要

正式以 **MIT** 开源；并修复网易云歌单：**新收藏立刻可见**、**未播歌曲也能拉到封面**。

---

## 1. 开源

- `LICENSE` 从专有授权改为 **MIT**。
- README 补充 Stars / License / 贡献入口，下载指向本仓库 Releases。

## 2. 网易云歌单

- 歌单曲目优先走带登录 Cookie 的在线接口，不再被过期的本地 SQLite 挡住新收藏。
- 打开 / 刷新歌单时强制重载当前列表。
- 封面优先使用歌单详情里的 `picUrl` 下载；缺失时改用 `/api/v3/song/detail` + Cookie。

---

## 回滚

```bash
git checkout v1.0.1
# 或上一正式版：
git checkout v1.0.0
```
