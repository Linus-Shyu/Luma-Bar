# Luma Bar v1.0.2 更新报告

**日期：** 2026-09-19  
**版本：** `1.0.2`（build 11）  
**Git tag：** `v1.0.2`  
**对比基线：** `v1.0.1`

---

## 摘要

按常见开源库（含 OpenAI 公开仓库）的门面，把 Luma Bar **正式重开为 Apache-2.0 开源项目**：许可证、NOTICE、社区行为准则与贡献指引对齐；**未改动任何 GitHub Actions / 公证流水线文件**。

---

## 1. 许可证

- `LICENSE`：由 MIT 改为 **Apache License 2.0**（含专利授权与商标条款）。
- 新增 `NOTICE`：版权与第三方商标说明。
- 新增 [docs/OPEN_SOURCE.md](OPEN_SOURCE.md)：开源范围、可贡献内容、历史商业文档优先级。

## 2. 社区与文档

- 新增 `CODE_OF_CONDUCT.md`（Contributor Covenant 2.1）。
- 更新 `CONTRIBUTING.md` / `SECURITY.md` / 中英文 README：开源说明、Apache 徽章、禁止改流水线。
- `docs/COMMERCIALIZATION.md` 顶部注明：与许可证冲突时以 `LICENSE` / `NOTICE` 为准。

## 3. 明确不动的部分

- **未修改** `.github/workflows/`（含 `release.yml`）及任何公证 / CI 脚本逻辑。
- Liquid Glass / 岛条视觉冻结规则不变。

---

## 回滚

```bash
git checkout v1.0.1
```
