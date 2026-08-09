# `aged_newsroom_v1` 生成记录

## 记录摘要

- 生成日期：2026-08-09（Asia/Shanghai）。
- 工具：内置 `image_gen`（默认图像模型路径为 `gpt-image-2`；生成 PNG 元数据标记为 `gpt-image` `c2.0`）。
- 输入图片：无。三次请求均为从零生成；没有引用项目概念样张、照片、商标或第三方素材。
- 色键：请求使用纯色 `#ff00ff`。模型输出的色键区域实际带有柔和渐变，因此没有直接把源图当运行时图，而是用一次性本地处理脚本进行几何软遮罩、去色键偏色和预乘 alpha 缩放。
- 许可：本组位图为本项目通过 OpenAI 图像生成工具委托生成的原创项目素材；不含第三方图片、字体、商标或可读文字。按项目仓库许可策略及适用的 OpenAI 服务条款使用。
- 源图仅用于溯源，不由运行时加载：`source_generated/`。
- 运行时只引用 `runtime/` 中的 6 张 RGBA PNG。

## 生成请求与默认输出路径

### 面板

- 源文件：`source_generated/panel_backdrop_source.png`
- image_gen 默认输出：`C:\Users\32402\.codex\generated_images\019fe523-685e-7341-96b9-09d7a167056c\exec-f36c264a-943f-45f1-a2f7-0d7004dd77cd.png`
- 原始尺寸：1774×887 RGB；运行时尺寸：512×256 RGBA。
- 完整提示词：

```text
Use case: stylized-concept. Asset type: game UI raster texture, final runtime panel backdrop. Primary request: a quiet, low-contrast aged newsroom panel surface for a 2D psychological-horror game set in a believable 1999 local radio newsroom. Create a wide 2:1 rectangle of warm yellowed old paper blended with matte aged ABS plastic, softly mottled and lightly fibrous, with the center calm and clean for NinePatch stretching. The surface should fade naturally at all edges so no hard border is visible; only an extremely weak inner shadow and barely perceptible 1–2% fine grain. Keep generous clean padding around the outer edges. Use restrained muted tones close to old paper warm gray and yellowed cream, never saturated. No frame, no bevel, no screws, no badges, no icon, no symbols, no readable text, no logo, no watermark, no objects, no cast shadow. Place the entire subject on a perfectly flat solid #ff00ff chroma-key background for background removal. The #ff00ff background must be absolutely uniform with no gradient, texture, reflections, floor plane, or lighting variation, and #ff00ff must not appear in the panel surface. Composition/framing: centered, edge-softened panel with clean central field. Lighting/mood: diffuse, subdued, tactile, calm but slightly worn. Materials/textures: yellowed paper, matte plastic, sparse micrograin. Constraints: no readable marks of any kind; no explicit geometric border; no high contrast; suitable for 512x256 output after crop/resize.
```

### 对话框

- 源文件：`source_generated/dialogue_backdrop_source.png`
- image_gen 默认输出：`C:\Users\32402\.codex\generated_images\019fe523-685e-7341-96b9-09d7a167056c\exec-331c48f1-5bd2-4d36-a56b-1da1a7b8f4ca.png`
- 原始尺寸：2048×768 RGB；运行时尺寸：1024×384 RGBA。
- 完整提示词：

```text
Use case: stylized-concept. Asset type: game UI raster texture, final runtime dialogue backdrop. Primary request: a quiet, low-contrast aged newsroom dialogue surface for a 2D psychological-horror game set in a believable 1999 local radio newsroom. Create a wide 8:3 rectangle of warm yellowed old paper blended with matte aged ABS plastic, softly mottled and lightly fibrous, with an especially calm, clean central field for a bottom dialogue box and NinePatch stretching. Let all edges fade naturally with no hard border; only an extremely weak inner shadow and barely perceptible 1–2% fine grain. Keep generous clean padding on all sides. Restrained muted old-paper warm gray and yellowed cream tones, never saturated. No frame, bevel, screws, badges, icon, symbols, readable text, logo, watermark, objects, cast shadow. Place the complete panel on a perfectly flat solid #ff00ff chroma-key background for background removal. The #ff00ff background must be absolutely uniform with no gradient, texture, reflection, shadow, floor plane, or lighting variation, and #ff00ff must not appear in the panel surface. Composition/framing: centered wide dialogue panel with a calm central stretch zone. Lighting/mood: diffuse, subdued, tactile, believable, slightly worn. Materials/textures: yellowed paper, matte plastic, sparse micrograin. Constraints: no readable marks; no explicit geometric border; no high contrast; no high saturation; suitable for 1024x384 output after crop/resize.
```

### 按钮默认态

- 源文件：`source_generated/button_default_source.png`
- image_gen 默认输出：`C:\Users\32402\.codex\generated_images\019fe523-685e-7341-96b9-09d7a167056c\exec-b12f9f17-9656-4443-ad85-96818cf0dfe2.png`
- 原始尺寸：1774×887 RGB；运行时四态均为 512×128 RGBA。
- 完整提示词：

```text
Use case: stylized-concept. Asset type: game UI raster texture, default button surface for a 2D psychological-horror game set in a believable 1999 local radio newsroom. Create one wide 4:1 quiet button texture, warm yellowed old paper blended with matte aged ABS plastic, low contrast and lightly fibrous, with a calm completely clean center for label text and horizontal/vertical NinePatch stretching. Make the outer edge softly worn and weak, not a hard border; only a tiny inner shadow and 1–2% sparse grain. Leave generous transparent-safe-looking padding inside the button silhouette. Muted old-paper warm gray and yellowed cream, never saturated. No text, no logo, no watermark, no icon, no symbols, no screws, no badges, no metallic rim, no bevel, no cast shadow. Place the complete button on a perfectly flat solid #ff00ff chroma-key background for background removal. The #ff00ff background must be absolutely uniform with no gradient, texture, reflection, shadow, floor plane, or lighting variation, and #ff00ff must not appear in the button surface. Composition/framing: centered wide rounded-rectangle button, enough padding on all sides, clean central stretch region. Lighting/mood: diffuse, subdued, tactile, believable, slightly worn. Constraints: no readable marks; default state should be quiet and low-saturation, suitable for 512x128 output after crop/resize.
```

## 后处理

1. 先将源图复制到本目录，源文件保留原始 RGB 内容。
2. `#ff00ff` 并非完全平坦（生成器在边缘产生了渐变），所以按几何圆角区域生成 alpha，并用绿通道/红蓝偏色检测将色键渐变逐步透明；边缘偏红/偏紫像素拉回旧纸暖灰。
3. 面板软遮罩参数：源图 bbox `(82,118)-(1692,773)`、圆角半径 74、Gaussian feather 22 px；对话框 bbox `(146,90)-(1900,678)`、圆角半径 64、feather 20 px。面板/对话框色键软阈值为绿通道 164～200 的渐变区。
4. 缩放前使用预乘 alpha，再用 Lanczos 缩放到目标尺寸，避免透明边缘在纹理过滤时出现黑色或洋红色 fringe。
5. 按钮从源图 `(45,160)-(1729,728)` 取本体，缩放至 480×96，粘贴在 512×128 画布 `(16,16)`，四态复用同一 alpha 遮罩。默认态保持原色；悬停态亮度约 +3.5%（另加 2/255）；按下态亮度约 −10%；禁用态混合约 55% 灰度并整体压暗约 7%。这些差异保持低饱和，不依赖颜色表达禁用原因。
6. 为确保 NinePatch 的中心不被透明噪点打断，面板 `(96,80)-(416,176)`、对话框 `(160,120)-(864,264)` 的干净中心在最终 PNG 中固定为不透明；边缘软遮罩保持不变。
7. 一次性处理脚本已在导出后移除；上述参数足以复核结果，运行时不依赖 Python 脚本。

## NinePatch 建议

以下是接入起点，不代表 Godot 工程内最终验收参数。中心区应只取干净、低纹理、无边缘磨损的区域；拉伸时不要把颗粒边缘复制到正文附近。

| 资源 | 建议 NinePatch margin | 建议干净中心区 | 安全边距（不放文字/图标） |
| --- | ---: | --- | ---: |
| `panel_backdrop.png` | 左右 96 px、上下 80 px | x=96..416，y=80..176 | 32 px |
| `dialogue_backdrop.png` | 左右 160 px、上下 120 px | x=160..864，y=120..264 | 40 px |
| `button_*.png` | 左右 48 px、上下 32 px | x=64..448，y=32..96 | 16 px（另留文字主题内边距） |

按钮四态必须使用完全相同的切片参数；文字、说话人、正文和禁用原因由 Godot 控件绘制，不写入位图。

### Godot `StyleBoxTexture` 接入起点

以下数值对应 `texture_margin_left/right/top/bottom`（像素），`modulate.a` 是建议起始透明度；最终仍需在实际四视图和正文对比度下调整。

| 资源 | texture_margin（L/R/T/B） | 建议 modulate alpha | 说明 |
| --- | --- | ---: | --- |
| `panel_backdrop.png` | 96 / 96 / 80 / 80 | 0.94 | 普通信息/标题面板，保持融入背景；正文对比度不足时优先提高文字颜色，不先加边框。 |
| `dialogue_backdrop.png` | 160 / 160 / 120 / 120 | 0.96 | 底部对白框需要稳定承载正文，避免透明度过低导致长中文阅读发灰。 |
| `button_default.png` | 64 / 64 / 32 / 32 | 0.96 | 安静默认态。 |
| `button_hover.png` | 64 / 64 / 32 / 32 | 1.00 | 悬停只做局部提亮，勿额外叠加高饱和色。 |
| `button_pressed.png` | 64 / 64 / 32 / 32 | 0.92 | 与按下时的机械位移/压暗配合。 |
| `button_disabled.png` | 64 / 64 / 32 / 32 | 0.68 | 仍保留轮廓；必须同时显示简体中文禁用原因，不能只靠 alpha 传达状态。 |

建议把这些值作为主题资源的初始值，而不是在每个场景节点中重复硬编码；关闭 CRT/噪声后再复核一次文字、热点和按钮轮廓。

## Alpha 与资源检查（2026-08-09）

使用 Pillow 对最终 `runtime/*.png` 实测：

| 文件 | 尺寸 | 模式 | 四角 alpha | 非零 alpha 占比 | 强色键残留（alpha>8 的抽样判据） |
| --- | ---: | --- | --- | ---: | ---: |
| `panel_backdrop.png` | 512×256 | RGBA | 0/0/0/0 | 64.29% | 0.0000% |
| `dialogue_backdrop.png` | 1024×384 | RGBA | 0/0/0/0 | 65.47% | 0.0000% |
| `button_default.png` | 512×128 | RGBA | 0/0/0/0 | 68.97% | 0.0000% |
| `button_hover.png` | 512×128 | RGBA | 0/0/0/0 | 68.97% | 0.0000% |
| `button_pressed.png` | 512×128 | RGBA | 0/0/0/0 | 68.97% | 0.0000% |
| `button_disabled.png` | 512×128 | RGBA | 0/0/0/0 | 68.97% | 0.0000% |

四张按钮的 alpha 非零遮罩 IoU 均为 `1.000000`，画布尺寸一致。尚未在 Godot 4.7.1 场景中验证 NinePatch 拉伸、1920×1080 四视图、放大字体或关闭 CRT；这些属于工程建立后的验收项。
