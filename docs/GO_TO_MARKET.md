# 上架与分发说明

自建收款 / License / Stripe / 虎皮椒相关方案已移除。

当前方向：**Mac App Store 付费单包**（沙盒合规）。详见：

- [APP_STORE.md](APP_STORE.md) — 构建与 Connect 步骤  
- [APP_REVIEW_NOTES.md](APP_REVIEW_NOTES.md) — 审核备注  
- [PRIVACY_POLICY_STUB.md](PRIVACY_POLICY_STUB.md) — 隐私政策草稿  

本地商店向构建（SwiftPM 沙盒包，仅自测）：

```bash
./build_app_store.sh
```

提交商店请打开 `LumaBar.xcodeproj`，Scheme **luma bar**，**Product → Archive**。步骤见 [APP_STORE.md](APP_STORE.md)。
