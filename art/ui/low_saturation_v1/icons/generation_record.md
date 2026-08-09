# 低饱和 UI 图标生成记录

## 1. 基本信息

| 项目 | 内容 |
| --- | --- |
| 生成日期 | 2026-08-08 |
| 提示词版本 | `low_saturation_icons_prompt_v1` |
| 生成工具 | Codex 内置 `image_gen` |
| 可获得的生成器标记 | 生成文件元数据显示为 `gpt-imagegen 2.0`；内置工具未公开更具体的后端模型名 |
| 色彩/材质参考 | `art/concept/style_baseline_v1/studio_overview.png`，仅用于低饱和冷灰、旧纸暖灰和克制琥珀方向 |
| 生成方式 | 每个图标一次独立 `image_gen` 调用，共 4 次；未生成展示板或 UI 概念图 |
| 原图尺寸 | 4 张均为 1254×1254 px、PNG、纯洋红色键背景 |
| 原图目录 | `source_generated/` |
| 运行时目录 | `runtime/` |

`source_generated/` 保留内置工具生成的原始色键图；`runtime/` 保存使用技能自带脚本去底后的 RGBA PNG。除色键移除外，没有进行裁切、重绘、调色、锐化或其他图像编辑。

## 2. 完整提示词

### `icon_phone_ringing.png`

```text
Use case: stylized-concept
Asset type: production-ready small game UI icon, single independent raster asset
Input images: Image 1 is color and material reference only; do not copy its scene, composition, objects, lighting layout, or borders.
Primary request: create exactly one icon: an old late-1990s desk telephone handset with exactly two short vibration lines, clearly indicating ringing.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal.
Style/medium: restrained simplified painted UI icon, nearly flat, clean single silhouette, small-size friendly; subtle aged-paper and matte painted-metal feel; not a concept sheet and not a UI mockup.
Composition/framing: one centered handset with exactly two vibration lines; balanced generous transparent-safe padding; readable at 32–64 px; no other objects.
Color palette: low-saturation old paper gray #D2C9B2 and cool slate gray #52666C / #777C79, with at most one tiny controlled dark amber #C28A4B accent; subject must contain no magenta.
Materials/textures: very subtle worn analog-office texture only, no noisy micro-detail.
Constraints: exactly one isolated icon; crisp antialiased outer edge; background must be one uniform #ff00ff with no shadows, gradients, texture, reflections, floor plane, or lighting variation; no cast shadow, no contact shadow, no reflection; no square or round badge/backplate, no enclosing frame, no border, no screws, no brass trim, no thick bevel, no text, no digits, no watermark; no neon glow; no modern app icon styling; icon complements Chinese status text and does not need to communicate every nuance alone.
Avoid: icon sheet, presentation board, UI concept art, multiple variants, telephone base, smartphone, bright red/yellow, high saturation, glossy 3D, photorealism, pixel art, horror ornament.
```

### `icon_unread.png`

```text
Use case: stylized-concept
Asset type: production-ready small game UI icon, single independent raster asset
Input images: Image 1 is color and material reference only; do not copy its scene, composition, objects, lighting layout, or borders.
Primary request: create exactly one icon: a simple closed paper envelope with one small diamond-shaped unread marker beside its upper-right edge.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal.
Style/medium: restrained simplified painted UI icon, nearly flat, clean single silhouette, small-size friendly; subtle old-paper feel; not a concept sheet and not a UI mockup.
Composition/framing: one centered closed envelope plus exactly one small diamond unread marker; balanced generous transparent-safe padding; readable at 32–64 px; no other objects.
Color palette: low-saturation old paper gray #D2C9B2 and cool gray #52666C / #777C79, with at most one tiny controlled dark amber #C28A4B accent in the diamond; subject must contain no magenta.
Materials/textures: very subtle paper wear only, no noisy micro-detail.
Constraints: exactly one isolated icon; crisp antialiased outer edge; background must be one uniform #ff00ff with no shadows, gradients, texture, reflections, floor plane, or lighting variation; no cast shadow, no contact shadow, no reflection; no square or round badge/backplate, no enclosing frame, no border, no screws, no brass trim, no thick bevel, no text, no digits, no watermark; no red notification dot, no neon glow; no modern app icon styling; icon complements Chinese status text.
Avoid: icon sheet, presentation board, UI concept art, multiple variants, open letter contents, speech bubble, bright red/yellow, high saturation, glossy 3D, photorealism, pixel art, horror ornament.
```

### `icon_back.png`

```text
Use case: stylized-concept
Asset type: production-ready small game UI icon, single independent raster asset
Input images: Image 1 is color and material reference only; do not copy its scene, composition, objects, lighting layout, or borders.
Primary request: create exactly one icon: a simple return/back arrow, pointing left, with a clear compact silhouette and a modest bent shaft.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal.
Style/medium: restrained simplified painted UI icon, nearly flat, clean single silhouette, small-size friendly; faint matte aged-office finish; not a concept sheet and not a UI mockup.
Composition/framing: one centered left-pointing return arrow; balanced generous transparent-safe padding; readable at 32–64 px; no other objects.
Color palette: low-saturation old paper gray #D2C9B2 and cool gray #52666C / #777C79; subject must contain no magenta; no bright accent needed.
Materials/textures: extremely subtle matte wear only, no noisy micro-detail.
Constraints: exactly one isolated icon; crisp antialiased outer edge; background must be one uniform #ff00ff with no shadows, gradients, texture, reflections, floor plane, or lighting variation; no cast shadow, no contact shadow, no reflection; no square or round badge/backplate, no enclosing frame, no border, no screws, no brass trim, no thick bevel, no text, no digits, no watermark; no neon glow; no modern app icon styling; icon complements Chinese status text.
Avoid: icon sheet, presentation board, UI concept art, multiple variants, circular refresh arrow, chevrons, ornate arrow, bright color, high saturation, glossy 3D, photorealism, pixel art, horror ornament.
```

### `icon_warning.png`

```text
Use case: stylized-concept
Asset type: production-ready small game UI icon, single independent raster asset
Input images: Image 1 is color and material reference only; do not copy its scene, composition, objects, lighting layout, or borders.
Primary request: create exactly one icon: a discreet triangular warning symbol containing a simple exclamation mark, quiet and utilitarian rather than alarming.
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal.
Style/medium: restrained simplified painted UI icon, nearly flat, clean single silhouette, small-size friendly; faint matte aged-office finish; not a concept sheet and not a UI mockup.
Composition/framing: one centered low-profile warning triangle and exclamation mark; balanced generous transparent-safe padding; readable at 32–64 px; no other objects.
Color palette: low-saturation cool gray #777C79 / #52666C and old paper gray #D2C9B2, with at most a small controlled dark amber #C28A4B infill; subject must contain no magenta; avoid bright hazard yellow.
Materials/textures: extremely subtle matte wear only, no noisy micro-detail.
Constraints: exactly one isolated icon; crisp antialiased outer edge; background must be one uniform #ff00ff with no shadows, gradients, texture, reflections, floor plane, or lighting variation; no cast shadow, no contact shadow, no reflection; no square or round badge/backplate, no separate enclosing frame beyond the warning triangle itself, no screws, no brass trim, no thick bevel, no text apart from the single exclamation glyph, no digits, no watermark; no neon glow; no modern app icon styling; icon complements Chinese warning text and is not the sole meaning carrier.
Avoid: icon sheet, presentation board, UI concept art, multiple variants, skull, hazard stripes, bright yellow/red, high saturation, glossy 3D, photorealism, pixel art, horror ornament.
```

## 3. 去底处理

四张图分别执行技能自带脚本：

```powershell
python "<CODEX_HOME>\skills\.system\imagegen\scripts\remove_chroma_key.py" `
  --input <source_generated/图标文件名> `
  --out <runtime/图标文件名> `
  --auto-key border `
  --soft-matte `
  --transparent-threshold 12 `
  --opaque-threshold 220 `
  --despill
```

脚本自动采样到的实际边缘键色：

| 图标 | 自动键色 | 全透明像素 | 部分透明像素 |
| --- | --- | ---: | ---: |
| `icon_phone_ringing.png` | `#f904f8` | 1,374,006 / 1,572,516 | 2,889 / 1,572,516 |
| `icon_unread.png` | `#fc04fa` | 1,232,327 / 1,572,516 | 2,712 / 1,572,516 |
| `icon_back.png` | `#fc04fa` | 1,382,233 / 1,572,516 | 2,640 / 1,572,516 |
| `icon_warning.png` | `#fa04f3` | 1,289,706 / 1,572,516 | 2,622 / 1,572,516 |

## 4. 验证结果

对 `runtime/` 中四张图进行了只读像素检查和透明图目视检查：

- 文件均为 1254×1254 px、RGBA PNG。
- 四个角的 alpha 值均为 0。
- alpha 主体包围盒占整张画布面积约 24.1%～30.1%，留白充足且主体没有贴边。
- alpha 大于 12 的可见像素中，符合明显洋红残留判据的像素数均为 0。
- 目视未发现明显洋红边、方形或圆形徽章底板、额外围框、螺丝、黄铜包边、文字、数字或霓虹发光。
- 四个主体轮廓明确；电话图标含两条振动线，未读图标含一个菱形标记，返回图标指向左侧，警告图标为三角形加单个感叹号。

## 5. Godot 用法

- 运行时只引用 `runtime/` 下的 PNG，不引用 `source_generated/` 色键原图。
- 可在 `TextureRect`、`TextureButton` 或自定义 `Control` 中加载；建议保持等比缩放并使用居中模式，不拉伸变形。
- 图标设计目标显示尺寸为 32～64 px，并应和简体中文状态文字共同使用；来电、未读和警告状态不能只靠图标或颜色表达。
- Godot 导入时使用适合 UI 的无损纹理设置；最终过滤方式应在实际 1920×1080 UI 中同时检查 32 px 与 64 px 后确定。
- 不要为这些图标添加高饱和描边、徽章底板或常亮发光；悬停/按下状态宜由 Godot 的轻微明暗或透明度变化实现。

## 6. 已知限制

- 这些文件是 AI 生成的高分辨率栅格源，不是像素对齐的矢量图；32 px 下的局部纸张纹理和电话孔位会被缩小，但主体轮廓仍是主要识别依据。
- 本次只完成独立资产级透明度与目视检查。仓库当前未在本任务中建立或修改 Godot UI，因此尚未完成真实界面中的 32/64 px、放大字体、关闭 CRT、1920×1080 四视图和非 16:9 验收。
- 图标色值受生成器材质绘制影响，不是逐像素严格锁定色板；整体方向保持低饱和旧纸灰、冷灰和少量暗琥珀。
