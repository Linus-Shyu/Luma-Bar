# 把 Luma Bar 真正卖出去（操作手册）

按 Surge 路径：**官网直销 + 试用 + License**。亲民价 **¥28 / ¥45 / ¥68**。

---

## 今天就能做的 6 步

### 1. 确认 App 里已有售卖骨架（已完成）
- 首次启动自动开始 **14 天全功能试用**
- 菜单栏胶囊 → **许可证…**：激活 / 购买 / 停用
- 试用结束未激活 → Free（刘海等基础可用；微信提醒、任务完成、划词、Agent 锁定）

### 2. 签发一把测试 License
```bash
cd "/Users/linusshyu/Desktop/luma bar"
python3 scripts/issue_license.py --devices 1
```
复制输出的 `LB1....` 密钥，在 App 里「许可证…」→ 粘贴 → 激活。

> 正式开卖前：把 `License.swift` 里的 `hmacKey` 和本机环境变量 `LUMA_LICENSE_HMAC` 改成同一串随机密钥，再重新打包。

### 3. 挂上收款（先用最简单的）
任选其一：
- [Lemon Squeezy](https://lemonsqueezy.com) / [Paddle](https://www.paddle.com) / [Stripe Payment Link](https://stripe.com)
- 或国内：微信收款码 / 小商店（先人工发密钥）

商品建三个 SKU：
| SKU | 价格 | 签发参数 |
|---|---|---|
| Pro 1 台 | ¥28 | `--devices 1` |
| Pro 3 台 | ¥45 | `--devices 3` |
| Pro 5 台 | ¥68 | `--devices 5` |

付款成功后：运行 `issue_license.py`，把密钥发到买家邮箱（可先人工，后自动化）。

然后把 `Sources/LumaBar/License.swift` 里的 `purchaseURL` 改成你的购买页链接，重新打包。

### 4. 打可分发 DMG（关键）
你本机目前只有 **Apple Development** 证书，用户下载会被 Gatekeeper 拦截。

1. 苹果开发者后台创建 **Developer ID Application** 证书并装到钥匙串  
2. 配置公证：
```bash
xcrun notarytool store-credentials "luma-notary" \
  --apple-id "你的AppleID" \
  --team-id "2DZ36MCTK5" \
  --password "app专用密码"
```
3. 打包：
```bash
chmod +x scripts/make_release_dmg.sh
LUMA_BAR_CODESIGN_IDENTITY="Developer ID Application: Faxin Xu (2DZ36MCTK5)" \
LUMA_BAR_NOTARY_PROFILE="luma-notary" \
./scripts/make_release_dmg.sh
```
4. 把 `dist/Luma-Bar-v0.2.0.dmg` 上传到 [Luma-Bar-Download](https://github.com/Linus-Shyu/Luma-Bar-Download) 新建 `v0.2.0` Release

没有 Developer ID 之前：只能「右键打开」内测，**不要正式卖**。

### 5. 落地页最小内容
一页就够：
1. 一句话：并行 AI 工作流刘海中枢  
2. 30–60 秒演示视频  
3. 下载按钮 + 购买按钮（¥28 起）  
4. 「14 天试用 · 为何不上 App Store」各三行  

可先用 GitHub Release 说明顶替官网。

### 6. 找第一批付费用户
- 发到即刻 / V2EX / 小红书 / Twitter：附带试用说明  
- AdventureX / 朋友圈：发 10 个内测码（`--devices 1`）  
- 收集：卡在哪一步、愿不愿意 ¥28  

---

## 钱怎么流转（人工版）

```
用户试用 14 天
  → 点「购买 Pro」打开收款页
  → 付款成功（你收到通知）
  → 你运行 issue_license.py
  → 邮件发密钥
  → 用户在「许可证…」激活
  → Pro 永久可用（本大版本）+ 12 个月维护期
```

自动化（Lemon Squeezy License 或自建小后端）可以第二期再做。

---

## 检查清单（开卖前）

- [ ] 轮换 `hmacKey`（与签发脚本一致）  
- [ ] `purchaseURL` 指向真实购买页  
- [ ] 公开包**不含** DeepSeek 真 Key  
- [ ] Developer ID + 公证 DMG  
- [ ] Release 说明含权限指引（辅助功能等）  
- [ ] 自己走通：试用 → 购买 → 激活 → 微信/完成提醒可用  

---

## 和 Surge 对齐的用户话术

> Luma Bar 完整版因系统能力限制不通过 Mac App Store 分发。  
> 下载后可免费试用 14 天；Pro 买断 ¥28 起，含 12 个月更新。
