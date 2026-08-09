# 低饱和按钮四态生成记录

## 1. 基本信息

| 项目 | 内容 |
| --- | --- |
| 生成日期 | 2026-08-08 |
| 生成工具 | Codex 内置 `image_gen` |
| 模型/版本 | 内置工具未暴露具体模型与版本，无法可靠记录 |
| 资产用途 | Godot 4.7.1 `TextureButton` / `NinePatchRect` 按钮状态纹理 |
| 风格参考 | `art/concept/style_baseline_v1/studio_overview.png`，仅用于默认态的色彩与材质参考 |
| 参考文档 | `doc/美术风格基调.md` |
| 色键 | `#ff00ff` |
| 原始画布 | 1774 × 887 px，RGBA PNG |
| 运行时画布 | 1774 × 887 px，RGBA PNG |
| 可读文字 | 无；中文标签应由 Godot UI 叠加 |

原始色键图保存在 `source_generated/`；去除色键后的运行时图保存在 `runtime/`。除技能自带去色键脚本外，未执行其他图像编辑。

## 2. 文件映射

| 状态 | 色键原图 | 运行时透明图 |
| --- | --- | --- |
| 默认 | `source_generated/button_default_source.png` | `runtime/button_default.png` |
| 悬停 | `source_generated/button_hover_source.png` | `runtime/button_hover.png` |
| 按下 | `source_generated/button_pressed_source.png` | `runtime/button_pressed.png` |
| 禁用 | `source_generated/button_disabled_source.png` | `runtime/button_disabled.png` |

## 3. 最终提示词

### 3.1 默认态

```text
Use case: stylized-concept
Asset type: production-ready 2D game UI button texture for Godot TextureButton / NinePatchRect, NOT a UI concept, NOT a screen mockup
Input images: Image 1 is color and worn-material reference only; do not copy its scene, objects, composition, or text
Primary request: create exactly one blank default-state wide horizontal rectangular button asset, low-saturation charcoal blue-gray, calm and understated, ready for Chinese text to be overlaid later in Godot
Scene/backdrop: perfectly flat solid #ff00ff chroma-key background for local background removal
Subject: one single centered button occupying most of a wide landscape canvas, straight-on orthographic front view, symmetrical, simple broad rectangle with only subtly softened corners; quiet empty center; no symbols and no text
Style/medium: polished production-ready painted 2D game UI sprite, restrained realistic matte painted-metal / aged laminate surface inspired by the reference image, subtle fine wear only near plausible touch areas and edges
Composition/framing: strict front view with no perspective; generous but even chroma-key padding on all sides; the entire button silhouette fully visible; wide aspect ratio approximately 4:1; preserve a broad visually uniform center suitable for Chinese label text and safe NinePatch stretching
Lighting/mood: very soft low-contrast ambient light; extremely weak top-to-bottom material shading only; no cast shadow, no contact shadow, no glow
Color palette: dominant muted charcoal blue-gray around #273033 and #354044, faint cool reflection around #52666C used sparingly; no saturated accent colors; do not use #ff00ff anywhere in the subject
Materials/textures: matte, low-sheen, very restrained grain and tiny edge wear; almost no outer border; at most a very weak low-contrast inner edge and shallow inner shading
Constraints: exactly one isolated blank button; no text, glyph, icon, logo, watermark, labels, screws, rivets, brass, gold, badges, ornaments, thick frame, bevel, raised plate, dramatic highlights, bright outline, large-area illumination, scanlines, CRT distortion, background scene, floor plane, reflection, shadow, extra objects; button center must remain clean enough for legible Godot UI text; silhouette edges must be crisp and continuous for chroma removal; background must be one perfectly uniform #ff00ff with no gradients, texture, shadows, reflections, lighting variation, or color contamination; production asset only, not concept art and not a mockup
```

### 3.2 悬停态（最终迭代）

```text
Use case: precise-object-edit
Asset type: production-ready hover-state 2D game UI button texture for Godot TextureButton / NinePatchRect
Input images: Image 1 is the exact edit target; treat its button outline, outermost edge pixels, chroma-key background, wear map, and geometry as immutable
Primary request: apply only a very subtle hover color-grade to the INTERIOR pixels of the existing button: lift midtone brightness slightly and shift the same charcoal blue-gray fractionally cooler. Do not redraw, reconstruct, move, expand, contract, sharpen, soften, or reinterpret the button.
Scene/backdrop: preserve every #ff00ff background pixel exactly; no variation
Subject: identical existing single blank button, pixel-aligned to Image 1
Lighting/mood: a gentle uniform material response only, perceptible beside default but still dark, low-saturation, and calm; no new light source
Hard invariants: canvas dimensions and aspect ratio unchanged; exact same button bounds; exact same silhouette; exact same corner radii; exact same outer contour and edge thickness; exact same position and alignment; exact same chroma-key padding; exact same wear, scuff, grain, and weak inner-edge placement; exact same empty center. All pixels at and outside the silhouette boundary must remain unchanged. Change only the interior midtone color/brightness.
Constraints: exactly one isolated blank button; no text, glyph, icon, logo, watermark, saturated accents, bright outline, glow, shadow, reflection, frame, bevel, screws, rivets, brass, badge, ornament, extra objects, or scene; do not use #ff00ff in the button; production asset, not concept art or mockup
```

### 3.3 按下态

```text
Use case: precise-object-edit
Asset type: production-ready pressed-state 2D game UI button texture for Godot TextureButton / NinePatchRect, NOT a UI concept or mockup
Input images: Image 1 is the exact edit target and geometry anchor
Primary request: change only the button material shading from default state to a restrained pressed state, suggesting a very shallow mechanical inward depression using subtle inner darkening near the top and sides plus a faint compressed-light response near the lower interior; no geometric movement and no saturated color
Scene/backdrop: keep the perfectly flat solid #ff00ff chroma-key background exactly unchanged
Subject: the same single blank wide horizontal button, same position, same pixel footprint, same silhouette, same corner radii, same straight-on view, same empty center
Lighting/mood: low contrast, quiet, shallow inset response only; no cast shadow, contact shadow, glow, new outline, dramatic highlight, or deep bevel
Color palette: preserve muted charcoal blue-gray and low saturation; no accent color and do not use #ff00ff anywhere in the button
Constraints: change only subtle internal pressed-state light and shade; preserve canvas size and aspect ratio, button bounds, alignment, silhouette, corner shape, edge thickness, surface grain, every wear mark and scuff placement, center cleanliness, chroma-key padding, background color, and all other content exactly; no apparent translation or resizing; exactly one isolated blank button; no text, glyphs, icons, logo, watermark, screws, rivets, brass, gold, badge, ornament, thick frame, raised plate, bright outline, large-area glow, floor, reflection, shadow, or extra object; keep edges crisp and continuous; production asset only, not concept art
```

### 3.4 禁用态

```text
Use case: precise-object-edit
Asset type: production-ready disabled-state 2D game UI button texture for Godot TextureButton / NinePatchRect, NOT a UI concept or mockup
Input images: Image 1 is the exact edit target and geometry anchor
Primary request: change only the button's tonal response from default to a disabled state by lowering contrast moderately, slightly desaturating the already muted charcoal blue-gray, and softening surface highlights while keeping the button clearly visible
Scene/backdrop: keep the perfectly flat solid #ff00ff chroma-key background exactly unchanged
Subject: the same single blank wide horizontal button, same position, same pixel footprint, same silhouette, same corner radii, same straight-on view, same empty center
Lighting/mood: flat restrained disabled response; remain readable and present, not transparent-looking and not lost in darkness; no glow, shadow, new outline, or dramatic highlight
Color palette: muted charcoal gray-blue shifting gently toward neutral gray; never pure black, never high saturation; do not use #ff00ff anywhere in the button
Constraints: change only overall contrast, saturation, and highlight softness for disabled state; preserve canvas size and aspect ratio, button bounds, alignment, silhouette, corner shape, edge thickness, weak inner edge, surface grain, every wear mark and scuff placement, center cleanliness, chroma-key padding, background color, and all other content exactly; exactly one isolated blank button; no text, glyphs, icons, logo, watermark, screws, rivets, brass, gold, badge, ornament, thick frame, bevel, raised plate, bright outline, illumination, floor, reflection, shadow, or extra object; keep edges crisp and continuous; production asset only, not concept art
```

## 4. 被替换的悬停态迭代

首次悬停态生成的 Alpha 遮罩相对默认态出现约 2～3 px 的位置漂移，遮罩 IoU 为 0.992390，因此未作为最终资产保留。为收紧轮廓连续性，使用 3.2 节的单变量提示词重新生成。首次提示词如下：

```text
Use case: precise-object-edit
Asset type: production-ready hover-state 2D game UI button texture for Godot TextureButton / NinePatchRect, NOT a UI concept or mockup
Input images: Image 1 is the exact edit target and geometry anchor
Primary request: change only the button surface response from default state to a restrained hover state by raising overall brightness very slightly and adding an extremely subtle cool-to-neutral color shift; the result must remain low-saturation and calm
Scene/backdrop: keep the perfectly flat solid #ff00ff chroma-key background exactly unchanged
Subject: the same single blank wide horizontal button, same position, same pixel footprint, same silhouette, same corner radii, same straight-on view, same empty center
Lighting/mood: only a slight diffuse lift in local material brightness, enough to be perceptible beside the default state but never luminous; no new directional light, glow, shadow, outline, or highlight
Color palette: preserve muted charcoal blue-gray; introduce no saturated color and do not use #ff00ff anywhere in the button
Constraints: change only the subtle hover brightness / temperature; preserve canvas size and aspect ratio, button bounds, alignment, shape, edge thickness, weak inner edge, surface grain, every wear mark and scuff placement, center cleanliness, chroma-key padding, background color, and all other content exactly; exactly one isolated blank button; no text, glyphs, icons, logo, watermark, screws, rivets, brass, gold, badge, ornament, thick frame, bevel, raised plate, bright outline, large-area glow, floor, reflection, shadow, or extra object; keep edges crisp and continuous; production asset only, not concept art
```

## 5. 去色键参数

四个最终运行时资产均使用技能自带脚本：

```powershell
python "<CODEX_HOME>\skills\.system\imagegen\scripts\remove_chroma_key.py" `
  --input <source_generated/*.png> `
  --out <runtime/*.png> `
  --auto-key border `
  --soft-matte `
  --transparent-threshold 12 `
  --opaque-threshold 220 `
  --despill
```

悬停态重做后，覆盖已有运行时文件时额外使用 `--force`；其余参数不变。未使用边缘收缩或羽化参数。

脚本实际采样的色键：

| 状态 | 自动采样色键 |
| --- | --- |
| 默认 | `#fb06fa` |
| 悬停（最终） | `#f407e8` |
| 按下 | `#f90bf9` |
| 禁用 | `#fa0bf8` |

## 6. 验证结果

对运行时 PNG 做了透明通道、透明角、洋红残边和 Alpha 轮廓连续性检查。

| 文件 | 尺寸 | 四角最大 Alpha | 可见洋红疑似像素 | Alpha ≥ 128 边界 | 相对默认态遮罩 IoU |
| --- | --- | ---: | ---: | --- | ---: |
| `button_default.png` | 1774 × 887 | 0 | 0 | `(55,205)–(1718,685)` | 1.000000 |
| `button_hover.png` | 1774 × 887 | 0 | 0 | `(52,205)–(1719,685)` | 0.997647 |
| `button_pressed.png` | 1774 × 887 | 0 | 0 | `(54,205)–(1719,685)` | 0.999965 |
| `button_disabled.png` | 1774 × 887 | 0 | 0 | `(54,205)–(1719,685)` | 0.999956 |

视觉检查确认：四态均为同一宽横向按钮；默认态安静、悬停态轻微提亮并偏冷、按下态通过浅内凹明暗表达、禁用态降低对比但仍清楚可见；没有文字、螺丝、黄铜、厚倒角、高亮徽章或大面积发光。

## 7. Godot 用法

- `TextureButton`：分别把 `runtime/button_default.png`、`button_hover.png`、`button_pressed.png`、`button_disabled.png` 指定给 Normal、Hover、Pressed、Disabled 状态纹理。
- `NinePatchRect`：四态应使用相同的 patch margin；建议先以约 80 px 左右、220 px 上下作为切片试验起点，再在实际字号和控件尺寸下目测微调。不要把边缘磨损区放入可拉伸中心。
- 中文标签由单独的 `Label` 或按钮文字层绘制，保持居中，并在默认与放大字体两档下检查。
- 运行时图保留透明安全区，四态画布完全一致；切换状态时不要改变控件尺寸。
- Godot 工程尚未建立，因此本次没有创建 `.tres`，也没有进行 1920 × 1080、放大字体或四视图内的实际运行验证。

## 8. 已知限制

- 内置生成工具无法保证逐像素不重绘；最终悬停态的 Alpha ≥ 128 边界相对默认态仍有最多 3 px 差异，但视觉轮廓连续，遮罩 IoU 为 0.997647。按下与禁用态差异小于 0.01%。
- 画布包含较大的透明安全区。直接按整张纹理布局时应保持四态一致；若项目后续希望缩小导入体积或紧贴可见边界，应在已确认的 UI 线框尺寸下统一裁切四张图，不能分别自动裁切。
- NinePatch margin 尚未在 Godot 4.7.1 中实测；上面的建议值只是接入起点，不是验收通过值。
- 未生成焦点态；键盘焦点框应由 Godot Theme 单独绘制，避免与鼠标悬停态混用。
