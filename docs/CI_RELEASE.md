# GitHub Actions — Developer ID 签名 + 公证发版

本仓库是 **SwiftPM**（`Package.swift`），**没有** `.xcodeproj` / `.xcworkspace`，因此 CI **不走** `xcodebuild archive`，而是：

`swift build` → `build_app.sh` 组 `.app` → Developer ID `codesign` → `notarytool` → `stapler`

这与官网直发 / Gatekeeper 路径一致。`Support/exportOptions.plist` 留给以后若迁到 Xcode 工程时用。

---

## 1. 文件放在哪

| 文件 | 作用 |
|------|------|
| `Support/exportOptions.plist` | 将来 Xcode `exportArchive` 用（method=`developer-id`） |
| `scripts/ci_release.sh` | 本地 / CI 共用的签名公证脚本 |
| `.github/workflows/release.yml` | Tag `v*` 触发的流水线 |

---

## 2. 你需要配置的 GitHub Secrets

在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret | 说明 | 如何生成 |
|--------|------|----------|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application 的 `.p12`（Base64） | `base64 -i Certificates.p12 \| pbcopy` |
| `P12_PASSWORD` | 导出该 p12 时设的密码 | — |
| `KEYCHAIN_PASSWORD` | CI 临时 keychain 密码（任意长随机串） | `openssl rand -base64 24` |
| `APPLE_ID` | Apple ID 邮箱 | 开发者账号登录邮箱 |
| `APPLE_APP_SPECIFIC_PASSWORD` | App 专用密码 | [appleid.apple.com](https://appleid.apple.com) → 登录与安全 → App 专用密码 |
| `APPLE_TEAM_ID` | 10 位 Team ID | 如 `2DZ36MCTK5`（证书括号内） |
| `APPLE_API_KEY_ID` | （备选）ASC API Key ID | Users and Access → Integrations → Keys |
| `APPLE_API_ISSUER` | （备选）Issuer UUID | 同上页顶部 |
| `APPLE_API_KEY_BASE64` | （备选）`AuthKey_XXX.p8` Base64 | `base64 -i AuthKey_XXX.p8 \| pbcopy` |
| `LUMA_BAR_DEEPSEEK_API_KEY` | （可选）构建时注入 Agent Key | 不设则不注入 |

> 三套 Apple ID secrets 齐备时优先用它公证；否则回退 API Key。若 API Key 在 ASC 页面正确仍 401，改用 Apple ID 路径。

---

## 3. YAML 里要不要改「工程名 / Scheme」？

| 常见 xcodebuild 参数 | 本仓库现状 |
|---------------------|------------|
| Workspace / Project | **无** — 不用填 |
| Scheme | **无** — 不用填 |
| Bundle ID | 已在 `Support/Info.plist`：`com.lumabar.app` |
| App 显示名 | `luma bar.app`（workflow 里 `APP_DISPLAY_NAME`） |
| Entitlements | `Support/LumaBar.entitlements` |
| 签名身份 | Secret 证书导入后自动找 `Developer ID Application:`；也可在 workflow `env.CODESIGN_IDENTITY` 写死完整字符串 |

若你以后生成了 Xcode 工程，再改用：

```bash
xcodebuild archive -scheme LumaBar -archivePath build/LumaBar.xcarchive
xcodebuild -exportArchive \
  -archivePath build/LumaBar.xcarchive \
  -exportPath dist \
  -exportOptionsPlist Support/exportOptions.plist
```

并把 `Support/exportOptions.plist` 里的 `YOUR_TEAM_ID` 换成你的 10 位 Team ID。

---

## 4. 版本命名（内部 vs 对外）

Tag 必须匹配 `v*`，且营销版本形如 `X.Y.Z`（可带后缀）：

| 阶段 | Tag 示例 | GitHub Release |
|------|----------|----------------|
| 内部开发 | `v0.5.0-dev.1`、`v0.5.0-dev.2` | **Pre-release**（标题带 Internal） |
| 临近公开 | `v1.0.0-rc.1` | **Pre-release** |
| 正式对外 | `v1.0.0`（无 `-` 后缀） | 正式 Latest |

规则：tag 名里只要有 `-`（`-dev` / `-rc` 等），流水线自动标 prerelease。正式公众版只用纯 `vX.Y.Z`。

不要用连续的 `v0.4.0`…`v0.4.5` 这类 tag 去「重试 CI」——改 Secrets / 修脚本后，对**同一个**内部 tag 用 `gh workflow run` 不适用（本 workflow 只听 tag push）；应推下一个 `-dev.N`，或修完后再打新 tag。

有意义的回滚基线（勿随便删）：`v0.3.0`（Liquid Glass）、当前内部公证通的 `v0.4.6` 等。

---

## 5. 触发方式

```bash
# 内部开发包
git tag -a v0.5.0-dev.1 -m "internal: ..."
git push origin v0.5.0-dev.1

# 正式对外（公开日）
git tag -a v1.0.0 -m "public launch"
git push origin v1.0.0
```

流水线会：

1. 用 tag 写入 `CFBundleShortVersionString`，用 `github.run_number` 写 `CFBundleVersion`
2. 导入证书到临时 keychain
3. 跑 `scripts/ci_release.sh`（universal 构建 + 签名 + 公证 + staple）
4. 产出 `.zip` / `.dmg` / `.app`，并创建 GitHub Release（带 `-` 则为 pre-release）

---

## 6. 本地试跑（有证书时）

```bash
export LUMA_BAR_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# Prefer Apple ID auth:
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="2DZ36MCTK5"
# Or API key auth:
# export APPLE_API_KEY_PATH="$HOME/AuthKey_XXX.p8"
# export APPLE_API_KEY_ID="XXXXXXXXXX"
# export APPLE_API_ISSUER="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export LUMA_BAR_MAKE_DMG=1
./scripts/ci_release.sh
```

---

## 7. 常见失败

| 现象 | 处理 |
|------|------|
| `no identity found` | p12 不是 **Developer ID Application**，或 `KEYCHAIN_PASSWORD` / partition-list 失败 |
| `notarytool` 401（API Key） | ASC 页面正确仍可能 401；改用 `APPLE_ID` + App 专用密码 + `APPLE_TEAM_ID` |
| `notarytool` 401（Apple ID） | 必须用 **App 专用密码**，不是 Apple ID 登录密码；Team ID 要与证书一致 |
| Gatekeeper 仍拦 | 确认 staple 成功；用户下载的是 **stapled 后的 zip/dmg** |
| SPM 资源缺失 | `build_app.sh` 已拷 `LumaBar_LumaBar.bundle`；看 CI 日志是否有 `Bundled localization` |
