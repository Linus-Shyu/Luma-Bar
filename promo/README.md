# Luma Bar 宣传动画

45 秒、3840×2160、60fps 的产品短片，用来发技术社区 / README / 社交媒体。

## 产物

| 文件 | 规格 | 用途 |
| --- | --- | --- |
| `luma-bar-promo-4k.mp4` | 3840×2160 · 60fps · H.264 CRF16 · 80 MB | 母版 / B 站 4K / X |
| `luma-bar-promo-1080p.mp4` | 1920×1080 · 60fps · H.264 CRF18 · 16 MB | 掘金 / 少数派 / V2EX / 微信 |
| `luma-bar-promo.gif` | 600px · 12fps · 7.3 MB | GitHub README 内嵌（卡在 10MB 限制内）|
| `luma-bar-poster.png` | 3840×2160 | 封面图 |

页面按 1920×1080 排版，渲染时 `deviceScaleFactor = 2`，所以 4K 是真的重新栅格化，文字和 1px 描边都是原生清晰度，不是放大。

片尾淡回黑场，循环播放接得上。

## 节奏

全片踩 **128 BPM / 4拍一小节** 的网格：一拍 0.46875 秒，一小节 1.875 秒，全长 24 小节 = 45.000 秒。所有章节切点、镜头推拉、条的变宽都落在小节线或拍点上，所以配上同 BPM 的音乐就是卡点的。

| 小节 | 时间 | 章节 | 内容 |
| --- | --- | --- | --- |
| 0 | 0.0 | 00 THE BAR | 屏幕顶端摄像头下方，一条从中间长出来 |
| 4 | 7.5 | 01 MUSIC | 封面 / 歌名 / 分段进度 / 播放控制，再展开播放器面板 |
| 8 | 15.0 | 02 TRANSLATE | 选中网页文字 → ⌥ Option → Agent 面板 Reading · Safari → Translating → 中文流式输出 |
| 13 | 24.4 | 03 CURSOR | 条变成 Cursor Agent pill，卡片给出 96% / 9K LEFT / 渐变进度条 |
| 17 | 31.9 | 04 SYSTEM | 系统四宫格 + 像素猫说话 |
| 21 | 39.4 | 05 | 条收回去，App 图标与开源信息升起 |

节奏层：条每拍微弹、每小节扫一道高光，画面左下角四颗点在数拍子，每四小节的乐句开头有一次全屏闪。

## 结构约束

- 全片只有**一条**栏，它不会被切开，只会改宽度和内容（`BARW` 关键帧：900 / 880 / 580 / 620px）。
- 屏幕顶端的摄像头是硬件，一直在，条压在它**下面** 46px 处，不遮挡。
- 界面按 `docs/images/` 里的真实截图复刻：条的深色描边、米纸底纹、面板四角的 `+` 标记、歌词卡与歌单行、Agent 面板的模型行与 TL;DR / Key Points / Explain / Shell、Cursor 卡片的 `• CURSOR CONTEXT` 标签都对得上。

## 改文案 / 改节奏

全部动画在 `luma-bar-promo.html` 单文件里，除 `assets/` 外没有外部依赖。

- 节拍：改 `BPM`，所有时间点用 `M(小节)` / `B(拍)` 表达，会整体跟着变。
- 文案：改 `CH` 数组（每章的 `eb` / `hl` / `sub`）。
- 镜头：改 `CAM` 关键帧，`x,y` 是要对准的画面坐标，`s` 是缩放，`e:"io"` 是缓动、`e:"lin"` 是匀速漂移。
- 条的宽度：改 `BARW`；条内四套内容 `#cMusic` / `#cAgent` / `#cCursor` / `#cSystem` 在 `seek()` 里交叉淡入。
- 动画本身由 `seek(t)` 一次性算出所有属性，只写 `transform` / `opacity` / `filter`，所以可以按任意时间点精确取帧。

预览（需要本地起服务，否则像素字体会被 Chrome 的 file:// 策略拦掉）：

```bash
cd promo && npm run preview   # http://127.0.0.1:8731/luma-bar-promo.html
```

## 重新导出

```bash
cd promo
npm install          # 只装 puppeteer-core，用系统已装的 Chrome
npm run render       # 约 8 分钟，输出 4K + 1080p + gif + poster
```

渲染是逐帧驱动 `window.__seek(t)` 再截图喂给 ffmpeg，不是录屏，所以 60fps 一帧不掉。

抽查单帧构图：

```bash
node check.mjs 3.9 9.4 13.2 20.6 27.5 35.0 42.2   # 输出到 promo/check/
```

## 配音乐

片子本身不带音轨。拿一首 128 BPM 的曲子对上第一个重拍即可：

```bash
ffmpeg -i luma-bar-promo-1080p.mp4 -ss <第一个重拍的秒数> -i <音乐.mp3> \
  -c:v copy -c:a aac -b:a 192k -shortest luma-bar-promo-music.mp4
```

网易云的 `.ncm` 是加密容器，ffmpeg 读不了，要先在客户端导出成 mp3/m4a。公开发布时注意商业曲目的版权。

## 素材来源

- 像素猫：`Support/Assets/PixelCat/`（应用内同一套精灵帧）
- 像素字体：`Support/Fonts/ArkPixel12Mono-*.otf`（OFL，见 `Support/Fonts/OFL-ArkPixel.txt`）
- App 图标：`Support/Assets/Brand/LumaBarAppIcon.png`
- 专辑封面：从 `docs/images/luma-bar-music.png` 截取，仅作界面示意
