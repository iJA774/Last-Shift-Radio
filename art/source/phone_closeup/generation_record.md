# `phone_closeup` 运行时资产生成记录

## 1. 基本信息

| 项目 | 内容 |
| --- | --- |
| 用途 | 《末班电台》MVP 电话近景基础图与来电指示灯状态层 |
| 生成工具 | Codex 内置 `image_gen`（默认内置路径） |
| 模型/版本 | 工具返回结果未公开具体后端模型与版本，记录为不可获得 |
| 生成日期 | 2026-08-09 |
| 提示词版本 | `phone_closeup_runtime_v1`、`phone_indicator_on_runtime_v1` |
| 设计基准 | 1920×1080、16:9；下方约 30% 保留对话框安全区 |
| 资产状态 | 运行时副本已输出；Godot 场景中的字体、来显、按钮和状态文字仍由 UI 绘制 |

本次不覆盖 `art/concept/style_baseline_v1/` 下的任何概念图。电话近景参考既有概念图与运行时总览，仅作为风格/连续性输入；生成后按本记录进行尺寸统一和状态拆层。

生成前人工查看了 `art/concept/style_baseline_v1/phone_closeup.png` 与 `art/concept/style_baseline_v1/studio_overview_v2.png`；前者作为电话材质/按钮分组参考，后者用于确认总览中的电话朝向、米黄 ABS 色光和桌面关系。实际 `image_gen` 输入按上表使用电话概念图与运行时 `studio_base.png`，未把概念图覆盖为运行时文件。

## 2. 输入、原始输出和项目副本

| 生成步骤 | 输入角色与路径 | Codex 默认输出 | 项目内副本 |
| --- | --- | --- | --- |
| 基础图初稿 | Image 1：电话近景风格参考 `art/concept/style_baseline_v1/phone_closeup.png`；Image 2：总览连续性参考 `art/runtime/studio_overview/studio_base.png` | `C:\Users\32402\.codex\generated_images\019fe504-0a30-72e3-988e-dccaf8f247f1\exec-31d63ef3-6f4f-4c21-950b-07180d2f9bce.png` | `art/source/phone_closeup/phone_base_source_raw.png` |
| 基础图灯位修订 | 编辑目标：`art/source/phone_closeup/phone_base_source_raw.png`；只改电话右上方单一来电指示灯 | `C:\Users\32402\.codex\generated_images\019fe504-0a30-72e3-988e-dccaf8f247f1\exec-fb2ef61c-e483-40cc-bf49-d0861a986408.png` | `art/source/phone_closeup/phone_base_source_edited.png` |
| 亮灯覆盖层 | 无输入图；仅生成平坦绿色色键上的独立小灯 | `C:\Users\32402\.codex\generated_images\019fe504-0a30-72e3-988e-dccaf8f247f1\exec-27130157-8140-4273-b70c-536fc284c982.png` | `art/source/phone_closeup/phone_state_indicator_on_source_chroma.png` |

基础图内置输出为 1672×941 RGB；亮灯色键源为 1536×1024 RGB。最终运行时 PNG 均按下节步骤生成 1920×1080。

## 3. 完整提示词

### 3.1 基础图初稿（`phone_closeup_runtime_v1`）

```text
Use case: stylized-concept
Asset type: final 1920x1080 Godot 2D fixed-view telephone closeup background for a restrained psychological-horror game.
Input images: Image 1 is a telephone closeup style reference; Image 2 is the runtime studio overview continuity reference. Derive the same late-1990s beige telephone family, desk material, restrained blue-green shadows and nicotine-amber edge light; do not copy any readable AI text.
Primary request: create one coherent 16:9 close fixed view of the same beige late-1990s push-button corded desk telephone on the worn radio-studio desk. The handset sits in its cradle, with a visible coiled cord, tactile grouped keypad, two small function-button groups, and one single caller-indicator lamp/window on the upper-right face of the phone. That only lamp must be visibly OFF: a small deep amber / dark red lens with no glow and no highlight that could be mistaken for illumination. Do not show any other indicator lights, screens, or glowing buttons.
Scene/backdrop: same scratched dark laminate desk and subtle radio-room edge context; telephone dominates upper-middle/left-middle of frame. Keep the lower 30 percent of the 1920x1080 canvas as a calm, uncluttered desk-colored negative space for a Godot dialogue box; no handset or cord crossing the lower safe zone except a very small edge of cord if unavoidable.
Style/medium: low-resolution hand-painted realism, restrained editorial concept art, simplified production-ready shapes, not pixel art, not photorealistic.
Composition/framing: straight practical desk-level perspective, readable silhouette, generous side padding, no fisheye. Phone body approximately centered slightly left; indicator lamp location stable and easy to mask later.
Lighting/mood: weak nicotine-yellow desk lamp with cold blue-green rainy ambient fill; ordinary work object made faintly uneasy, all device lights off.
Color palette/materials: aged beige ABS plastic, dark brown rubber, oxidized teal-blue shadows, scratched laminate, muted amber/dark-red OFF indicator.
Constraints: 1920x1080 landscape; no readable words, no readable numerals, no logos, no branding, no watermark, no UI text, no paper writing; no extra phone; only one indicator lamp and it is off; preserve clear lower dialogue safe zone; no generated interface content.
Avoid: active glowing lamp, multiple LEDs, glowing buttons, caller ID text, readable keypad numbers, modern smartphone or office phone, rotary phone, futuristic screen, people, hands, faces, monster, corpse, blood, gore, jump-scare composition, neon cyberpunk, glossy modern equipment, heavy CRT effects, obvious pixel grid, strong chromatic aberration.
```

### 3.2 基础图灯位修订（`phone_closeup_runtime_v1` 编辑提示词）

```text
Use case: precise-object-edit.
Asset type: same final telephone closeup background.
Input image: the provided image is the edit target. Preserve every pixel-like design decision, camera framing, desk, handset, keypad, cord, shadows, right-edge console, palette, and empty lower dialogue safe zone as faithfully as possible.
Primary request: change only the single caller-indicator lamp on the upper-right face of the phone. Redraw it as a small narrow dark amber / dark red lens, approximately 35–55 px wide relative to this 1672 px source, inset cleanly into the same phone panel. It must read unmistakably OFF: matte deep amber-red surface, no specular highlight, no bloom, no halo, no emitted light, no glowing pixels. Keep it clearly distinct from the black buttons but much darker than the beige body.
Constraints: no other indicator lights, no glowing buttons, no screen, no readable text or numerals, no labels, no logos, no watermark; change only the lamp; keep the lower 30 percent of the frame calm and empty for a Godot dialogue box.
Avoid: bright orange square button, lit red LED, neon, extra lamps, call display, modern phone, people, hands, faces, monster, blood, gore, dramatic effects.
```

### 3.3 亮灯覆盖层（`phone_indicator_on_runtime_v1`）

```text
Use case: background-extraction.
Asset type: isolated runtime state overlay for a 2D Godot telephone closeup.
Primary request: draw only one tiny caller-indicator lamp, centered on a perfectly flat solid #00ff00 chroma-key background for later removal. The lamp is a narrow rounded rectangle / small pill, matching a late-1990s beige corded phone's upper-right indicator: restrained warm red-orange center with a darker red edge and at most a very weak, tight halo extending no more than 12–20 pixels at final display size. It is ON but not neon; no large bloom.
Scene/backdrop: absolutely uniform chroma green #00ff00 from edge to edge, no gradient, no texture, no shadows, no floor plane, no vignette.
Subject: only the small lamp lens and its subtle local glow; no phone body, no bezel, no buttons, no desk, no cord.
Style/medium: low-resolution hand-painted realism matching the Last Shift Radio telephone palette; compact, clean, production-ready state sprite.
Composition/framing: place the lamp dead center with generous green padding on all sides; keep it horizontally narrow and approximately 2:1 width-to-height; do not add a separate dark housing.
Constraints: use exactly #00ff00 for every background pixel; no text, numbers, logos, watermark, extra lights, reflections or decorative marks; keep all colored pixels confined to the one small lamp.
Avoid: full telephone, object silhouette, multiple LEDs, large red patch, neon cyberpunk, starburst, lens flare, smoke, particles, gradients in the background.
```

## 4. 后期处理与状态拆层

1. 将编辑后的基础图从 `art/source/phone_closeup/phone_base_source_edited.png` 用 Pillow Lanczos 缩放到 `1920×1080`，转换并保存为 RGB：`art/source/phone_closeup/phone_base_1920x1080_rgb.png`，再复制到运行时 `art/runtime/phone_closeup/phone_base.png`。
2. 对色键源运行内置技能助手（不是项目自写的替代实现）：

   ```powershell
   python C:\Users\32402\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py `
     --input art/source/phone_closeup/phone_state_indicator_on_source_chroma.png `
     --out art/source/phone_closeup/phone_state_indicator_on_keyed.png `
     --auto-key border --soft-matte --transparent-threshold 12 `
     --opaque-threshold 220 --despill
   ```

   生成器实际背景存在轻微压缩色差，助手自动取色为 `#08f90e`；第一次结果报告透明 1,562,958/1,572,864 像素、半透明 3,554 像素。另试过 `--edge-contract 1`，但保留不作为最终文件。
3. 使用 Pillow 做必要的绿色溢色处理：在缩放前后将透明像素 RGB 置黑；对 `G >= 0.99R` 且 `G >= 1.20B` 的色键残留像素置为完全透明；其余像素将 G 通道限制到不高于 R，保留暖红/橙色灯体。这样去除了合成预览中的黄绿色色键边缘。
4. 从助手输出的非透明边界裁出灯体与微弱辉光，缩放到 `64×37`；将其放在 1920×1080 画布的 `(1066,150)`，对应基础图熄灭灯位中心约 `(1098,168)`。生成全画布 RGBA 状态层 `art/runtime/phone_closeup/phone_state_indicator_on.png`，并保留 `art/source/phone_closeup/phone_state_indicator_on_sprite_64x37.png` 与 `phone_state_indicator_on_processed_1920x1080.png` 供追溯。
5. 将基础图与状态层合成，生成 `art/source/phone_closeup/phone_base_with_indicator_preview.png`；预览只用于验收，不作为运行时基础图。

## 5. 尺寸、通道与合成检查（2026-08-09）

| 文件 | 尺寸 | 通道 | 检查结果 |
| --- | --- | --- | --- |
| `art/runtime/phone_closeup/phone_base.png` | 1920×1080 | RGB | 通过；无 alpha，电话主体上方，底部约 30% 保持桌面安全区 |
| `art/runtime/phone_closeup/phone_state_indicator_on.png` | 1920×1080 | RGBA | 通过；alpha 边界 `(1066,150)-(1130,187)`，四角 alpha 均为 0 |
| `art/source/phone_closeup/phone_base_with_indicator_preview.png` | 1920×1080 | RGB | 通过；亮灯覆盖在同一灯位，无电话本体/文字被状态层带入 |

最终状态层统计：非透明像素 1,555（其中完全不透明 1,066、部分透明 489）；不透明核心边界约 `(1071,155)-(1124,181)`，外围辉光约 5～6 px，低于 12～20 px 上限；最终非透明像素中无绿色主导像素（`G > R` 为 0）。

肉眼检查通过：基础图唯一来电灯为深红/琥珀熄灭状态；亮灯层为克制的暖红/橙色小灯，未加入屏幕内容、可读文字、人物、手、血腥、怪物或水印；电话下方保留对话框安全区。尚未在 Godot 工程中验证四视图、放大字体、CRT 开关、非 16:9 留边与实际帧率，待工程集成后按项目验收门槛复核。

## 6. 许可与来源说明

- 画面由 Codex 内置 `image_gen` 生成；模型具体版本由工具隐藏，已在本记录中标明不可获得。
- 参考输入均为本项目已有概念/运行时资产；没有联网下载、第三方图片、商标、字体或可读 AI 文字被引入。
- 后期仅做尺寸统一、色键去除、去溢色、裁切、缩放和合成预览；未使用外部素材。
- 按项目规则保留原始生成副本、编辑副本、色键源、去色键结果和默认输出路径，便于后续审计与重生成。
