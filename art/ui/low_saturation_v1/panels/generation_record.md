# 低饱和 UI 底板生成记录

## 基本信息

| 项目 | 内容 |
| --- | --- |
| 资产批次 | `low_saturation_v1/panels` |
| 生成日期 | 2026-08-08 |
| 生成工具 | Codex 内置 `image_gen` |
| 模型/版本 | 内置工具未暴露具体模型名或版本，无法记录 |
| 色彩/材质参考 | `art/concept/style_baseline_v1/studio_overview.png`，仅用于低饱和蓝灰色与克制旧设备材质参考 |
| 透明处理 | 技能自带 `remove_chroma_key.py`，从纯色 `#ff00ff` 色键背景生成 alpha |
| 原始图目录 | `source_generated/` |
| 运行时图目录 | `runtime/` |

## `panel_backdrop.png`

- 用途：通用信息面板或弹层底板，适合 Godot `NinePatchRect`。
- 原始色键图：`source_generated/panel_backdrop_chroma.png`
- 原图尺寸：1536 × 1024 px。
- 运行时透明图：`runtime/panel_backdrop.png`
- 运行时尺寸：1536 × 1024 px，RGBA。

### 完整提示词

```text
Use case: stylized-concept
Asset type: production-ready 2D game UI panel texture for Godot NinePatchRect, a single isolated asset, not a UI screen and not concept art
Input images: Image 1 is color and restrained worn-material reference only; do not copy its room composition, objects, lighting scene, or readable details
Primary request: create one plain universal information-panel / modal backdrop: a solid low-saturation deep blue-gray rectangular slab with an almost invisible perimeter, only a very weak inner edge and extremely subtle old-paper / frosted-equipment matte texture
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal; one uniform color only, no gradients, shadows, texture, reflections, floor plane, or lighting variation in the background
Subject: one clean front-facing rectangular panel, opaque, centered, axis-aligned, fully visible; calm uninterrupted interior intended to hold Chinese text and controls; no internal dividers, no header strip, no ornaments
Style/medium: restrained hand-authored 2D game UI raster texture, practical production asset, low contrast, understated late-1990s local radio newsroom atmosphere
Composition/framing: landscape 3:2; panel fills about 88% of canvas with even chroma-key padding on all sides; perfectly straight-on orthographic view; straight parallel edges; subtly softened corners no more than a tiny radius; keep the central 80% nearly flat and uniform so it can stretch cleanly
Color palette: panel base around #20292d to #273033, muted blue-gray with a trace of charcoal; no saturated accents; do not use #ff00ff anywhere in the subject
Materials/textures: very fine diffuse matte grain and faint uneven age, near-imperceptible; no scratches crossing the center; no stains or focal marks; edge treatment limited to one low-contrast inner darkening line and a slight inner shade, under 3% visual contrast
Lighting/mood: flat diffuse material presentation; quiet, cool, administrative, readable; no cast light or dramatic shading
Constraints: output exactly one independent panel asset; no text, glyphs, icons, buttons, screws, rivets, brass, thick bevels, metal frame, bright outline, glow, drop shadow, cast shadow, contact shadow, reflection, watermark, logo, scene elements, or mockup; crisp silhouette and clean antialiased edges; no magenta halos or fringing
Avoid: full UI screenshot, interface layout, device bezel, steampunk, ornate horror, cyberpunk, neon, glossy glass, high contrast, rounded modern card, heavy grunge
```

## `dialogue_backdrop.png`

- 用途：画面下方的宽横向对话底板。
- 原始色键图：`source_generated/dialogue_backdrop_chroma.png`
- 原图尺寸：1983 × 793 px。
- 运行时透明图：`runtime/dialogue_backdrop.png`
- 运行时尺寸：1983 × 793 px，RGBA。

### 完整提示词

```text
Use case: stylized-concept
Asset type: production-ready 2D game dialogue-box backdrop texture for Godot, a single isolated asset, not a UI screen and not concept art
Input images: Image 1 is color and restrained worn-material reference only; do not copy its room composition, objects, equipment, lighting scene, or readable details
Primary request: create one wide horizontal dialogue backdrop for the bottom of a 2D psychological-horror game view: a low-saturation charcoal blue-gray opaque panel, visually quiet and flat across the text area, with an almost imperceptible edge
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal; one uniform color only, no gradients, shadows, texture, reflections, floor plane, or lighting variation in the background
Subject: one clean front-facing wide rectangular dialogue panel, centered, axis-aligned, fully visible; uninterrupted interior for several lines of Chinese dialogue; no portrait area, no speaker tab, no choice buttons, no internal divisions, no decorations
Style/medium: restrained hand-authored 2D game UI raster texture, practical production asset, low contrast, understated late-1990s local radio newsroom atmosphere
Composition/framing: very wide 5:2 horizontal panel; panel fills about 90% of canvas width and 72% of canvas height with even chroma-key padding; perfectly straight-on orthographic view; straight parallel edges; nearly square corners with only minute softening; keep central 85% exceptionally flat and uniform for readable text and clean stretching
Color palette: charcoal blue-gray around #1d2529 to #273033, slightly darker than a generic information panel; no saturated accents; do not use #ff00ff anywhere in the subject
Materials/textures: extremely subtle fine matte equipment grain, nearly invisible at normal UI scale; faint localized age only near perimeter; center must remain calm with no scratches, stains, mottling, or focal marks; edge treatment limited to one very low-contrast inner line and minimal inner shading under 2% visual contrast
Lighting/mood: flat diffuse material presentation; restrained, cool, intimate, readable, quietly uneasy; no directional or dramatic light
Constraints: output exactly one independent dialogue backdrop asset; no text, glyphs, name labels, icons, buttons, portraits, screws, rivets, brass, thick bevels, metal frame, bright outline, glow, drop shadow, cast shadow, contact shadow, reflection, watermark, logo, scene elements, or mockup; crisp silhouette and clean antialiased edges; no magenta halos or fringing
Avoid: full UI screenshot, interface layout, visual novel mockup, speech bubble, modern rounded card, device bezel, steampunk, ornate horror, cyberpunk, neon, glossy glass, high contrast, heavy grunge
```

## 去底参数

两张图均使用以下参数，未追加边缘收缩或羽化：

```text
--auto-key border
--soft-matte
--transparent-threshold 12
--opaque-threshold 220
--despill
```

脚本自动采样到的背景键色：

| 原始图 | 自动键色 |
| --- | --- |
| `panel_backdrop_chroma.png` | `#fc07ee` |
| `dialogue_backdrop_chroma.png` | `#f90bf3` |

## 验证结果

| 运行时资产 | Alpha 格式 | 四角 Alpha | 非全透明主体覆盖 | 非透明强洋红像素 |
| --- | --- | --- | --- | --- |
| `panel_backdrop.png` | 32-bit RGBA | `0, 0, 0, 0` | 78.74% | 0 |
| `dialogue_backdrop.png` | 32-bit RGBA | `0, 0, 0, 0` | 77.50% | 0 |

目视检查未发现明显洋红边、文字、图标、螺丝、黄铜、厚倒角、发光或场景残留。底板中央保持为低对比、可承载文字的安静区域。

## Godot 使用建议

- 使用 `runtime/` 下的 PNG，不要直接引用 `source_generated/` 中的色键原图。
- `panel_backdrop.png` 建议作为 `NinePatchRect` 纹理，初始 Patch Margin 可从四边 96 px 开始，再按实际控件尺寸微调。
- `dialogue_backdrop.png` 可直接作为宽横向 `NinePatchRect`；初始 Patch Margin 可从四边 112 px 开始，中央区域用于 Godot 排版的对白文字。
- 纹理导入建议关闭重复纹理造成的边缘采样；缩放过滤应结合最终字号与目标分辨率实际检查。
- 可读文字、说话人、选项和状态全部由 Godot UI 绘制，不要写入位图。

## 已知限制

- 两张图由生成模型绘制，中央细微磨砂纹理不是数学意义上的无缝纹理；NinePatch 拉伸比例过大时应检查是否出现纹理变形。
- 透明画布保留了生成时的安全留白；布局时需把留白计入控件视觉边界。
- Patch Margin 是基于当前纹理边缘宽度给出的起始值，尚未在实际 Godot 界面中验证。
- 本批次没有创建 Godot 工程、场景或 `.tres`；1920 × 1080、默认/放大字体及四视图中的最终可读性仍需工程建立后验证。
