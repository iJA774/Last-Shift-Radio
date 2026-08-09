# 工作室总览分层资产生成记录

## 交付范围

- 日期：2026-08-09
- 用途：`Studio A` 1920×1080 固定视图的三层运行时美术资源。
- 运行时文件：
  - `art/runtime/studio_overview/studio_base.png`
  - `art/runtime/studio_overview/studio_light_lamp.png`
  - `art/runtime/studio_overview/studio_state_lamp_off.png`
- 生成工具：Codex 内置 `image_gen`。
- 模型/版本：内置工具未公开后端模型版本，记录为不可获得。
- 来源与许可证：由项目通过 Codex 内置图像生成工具生成；不含第三方图片、字体、标识或可读文字。项目内保留原始生成图、色键中间图和处理后的母版，供审查与追溯。

## 输入与角色

- `E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\studio_overview_v2.png`：基础层的编辑目标，作为既有构图、房间、设备和透视的权威视觉参考。
- `E:\GAME\Last Shift Radio\art\runtime\studio_overview\studio_base.png`：灯光层与熄灯阴影层的对齐参考，不作为编辑目标；只用于说明 1920×1080 的设备位置和台灯落点。

## 生成源文件

| 层 | 内置工具输出（默认目录） | 项目内源副本 |
| --- | --- | --- |
| 基础层 | `C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-b7a90873-1aee-4f12-be2d-25b17c0fd53d.png` | `studio_base_source.png` |
| 台灯暖光（修订版） | `C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-c91e0908-1e54-499a-b5e5-642b5f969e45.png` | `studio_light_lamp_v2_chroma_green.png` |
| 熄灯阴影 | `C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-7c18d604-d276-4e70-8e61-d357d685022a.png` | `studio_state_lamp_off_chroma_green.png` |

内置工具本轮输出尺寸为 `1672×941`。运行时图统一以 Lanczos 非破坏缩放为 `1920×1080`；没有覆盖 `art/concept/style_baseline_v1` 中的任何概念图。

## 基础层 `studio_base`

### 最终提示词

```text
Use case: precise-object-edit
Asset type: 1920x1080 2D fixed-view psychological-horror game background layer
Input images: Image 1 is the existing studio_overview_v2.png, used as the authoritative composition, room geometry, camera, object silhouettes, material and wear reference.
Primary request: Create the project-bound static base layer named studio_base. Preserve the exact Studio A radio-room composition and perspective from Image 1: central rain window, wall clock, desk, analog mixing console, articulated desk lamp in the same left-center position, beige corded telephone at lower-left, hanging microphone, bulky beige CRT monitor, keyboard, papers, chair silhouette, and the right-side metal door with its small wired observation slit. This is the unlit base image underneath state overlays.
Lighting/mood: calm, low-key deep blue-gray interior exposure for a cold rainy 1999 night. Remove all warm desk-lamp illumination and local amber spill. The articulated lamp remains physically present but its bulb and shade interior are dark and non-emissive. Make the CRT monitor screen a dark inactive glass surface with no content, no screen glow, and no reflections that look like text. Turn off every telephone indicator/LED and any tiny device status lamp, while preserving the physical buttons and equipment. Keep the room readable and believable, not blacked out.
Composition/framing: exact wide 16:9 seated fixed viewpoint, stable horizontal lines, no crop, no camera shift. Target output 1920x1080.
Materials/textures: restrained hand-painted realism, low-resolution editorial concept-art texture, worn laminate, aged beige ABS, matte dark metal, damp rain-streaked glass, subtle grain only.
Constraints: all readable labels, signs, clock digits, UI, logos and watermarks must be absent or rendered as non-readable marks; all later labels are Godot UI. Keep every object silhouette and position stable for compositing. This layer must not contain foreground UI or hotspot overlays.
Avoid: global crushed blacks, global color grading, excessive vignette, full-scene darkness, changed furniture, changed equipment, missing lamp, glowing lamp, glowing CRT, CRT content, phone LEDs, text, numbers, logos, branding, people, faces, hands, vehicles, creatures, monster, corpse, blood, gore, jump scare, neon cyberpunk, strong glitch, heavy scanlines, fisheye, dutch angle, extra objects.
```

### 后期处理

原始 RGB 图直接复制为 `studio_base_source.png`，再以 `Pillow.Image.Resampling.LANCZOS` 缩放到 `studio_base.png` 的 `1920×1080`。该层保持 RGB、不含透明通道；台灯几何仍在基础层中，但灯泡/灯罩内部无发光，CRT 与电话指示灯关闭。

## 台灯暖光层 `studio_light_lamp`

### 最终修订提示词

```text
Use case: background-extraction
Asset type: 1920x1080 local desk-lamp light overlay for a 2D fixed-view Godot game
Input images: Image 1 is the authoritative studio_base reference. This output is an alpha-ready layer only, never a full room image.
Canvas: fill the entire 16:9 canvas with a perfectly uniform flat chroma-key green #00ff00. No variation, texture, shadow, vignette, floor, or scene outside the light.
Light source and footprint: the only source is the real articulated desk lamp shade in Image 1, whose lower rim is approximately x=475,y=500 on the final 1920x1080 canvas. Paint a very small, low-intensity warm desk-lamp pool directly below that rim. On the final canvas the visible light must stay almost entirely inside x=280..670 and y=505..790, tapering to full green/transparent before those bounds. The pool is a shallow soft trapezoid/ellipse on the nearby desktop, following the desk plane, not a giant circle and not a vertical cone. Do not illuminate the microphone, window, wall, CRT, keyboard, chair back, door, or the far half of the mixing console. A tiny warm edge may touch the nearby telephone/paper at x=280..360,y=680..790.
Color: subdued aged amber and brown-gold, close to #C28A4B, with low apparent opacity and no white center. The center must remain translucent-looking and textured, never solid, neon yellow, lemon, or orange. Soft feathered alpha-style falloff at every edge.
Constraints: only warm light paint exists besides the green key. No lamp, bulb, shade, desk, console, telephone, CRT, object silhouettes, outlines, text, digits, logos, branding or watermark. No black, gray, blue, cyan, magenta, purple or vivid lime in the light.
Avoid: large overlay, full desk wash, light covering the chair or CRT, hard border, lens flare, spotlight beam, giant blob, saturated yellow, white glow, scene reconstruction, people, creatures, monster, blood, gore, glitch, scanlines.
```

### 色键与状态约束

1. 复制 `studio_light_lamp_v2_chroma_green.png` 后使用项目外的技能助手 `C:\Users\32402\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py`：`--auto-key border --soft-matte --transparent-threshold 12 --opaque-threshold 220 --despill --edge-contract 1`，得到 `studio_light_lamp_v2_keyed_1672x941.png`。
2. 用 Pillow 从去色键纹理裁取光场，重排到 1672×941 母版的台灯落点；将色调压到棕黄 `#C28A4B` 附近，最大 alpha 限制为 72，应用 16 px Gaussian 边缘遮罩。遮罩母版范围为 `(230,440)-(580,680)`，对应最终画布约 `x=264..666, y=505..780`。
3. 生成 `studio_light_lamp_v3_processed_1672x941.png` 后先以 premultiplied-alpha 方式缩放（RGB 乘 alpha、Lanczos 缩放 RGB/alpha、再解除 premultiply），得到最终 `1920×1080` RGBA `studio_light_lamp.png`。透明四角保留；最终 alpha 最大值为 72，无全画布不透明背景。

## 熄灯局部阴影层 `studio_state_lamp_off`

### 最终提示词

```text
Use case: background-extraction
Asset type: 1920x1080 local shadow patch layer for a 2D fixed-view Godot game
Input images: Image 1 is the authoritative studio_base reference; align only the same desk-lamp footprint.
Primary request: Create a subtle local shadow-state overlay named studio_state_lamp_off. This is an alpha-ready patch only, not a room redraw.
Canvas: fill the entire 16:9 landscape canvas with perfectly flat uniform chroma-key green #00ff00; no texture or variation outside the patch.
Light source footprint: the articulated desk lamp sits left-center in Image 1. Paint a very restrained cool blue-gray / charcoal shadow patch where the lamp's local warm illumination would have touched the desk and nearby console when switched off. On the final 1920x1080 canvas keep it almost entirely inside x=280..670,y=505..790, following the desk plane as a shallow irregular ellipse/trapezoid. Edges must feather to full green/transparent. It may barely deepen the small phone/paper edge, but must not reach the CRT, keyboard, chair back, window, wall, microphone, or door.
Color and strength: neutral deep blue-gray close to #26343A mixed with a little #1B252A; low opacity, gentle darkening only. Never pure black, no hard vignette, no black hole, and no full-opacity center. The patch should remain a quiet state correction over studio_base.
Constraints: only subdued shadow paint besides the green key. No objects, lamp, bulb, shade, desk, console, telephone, CRT, text, digits, logos, watermark or silhouettes.
Avoid: giant dark blob, global darkening, full desk shadow, black rectangle, hard border, spotlight, colored glow, neon, red, purple, people, faces, hands, vehicles, creatures, monster, corpse, blood, gore, glitch, scanlines.
```

### 色键与状态约束

1. 复制 `studio_state_lamp_off_chroma_green.png`，使用同一色键参数并保留透明母版 `studio_state_lamp_off_keyed_1672x941.png`。
2. Pillow 将纹理排到与暖光层相同的 1672×941 遮罩 `(230,440)-(580,680)`，重映射到深蓝灰 `#26343A`，最大 alpha 限制为 34，并应用同一 16 px Gaussian 边缘遮罩；母版输出为 `studio_state_lamp_off_processed_1672x941.png`。
3. 以 premultiplied-alpha 的 Lanczos 方式缩放到 `1920×1080` RGBA `studio_state_lamp_off.png`，避免透明边缘藏有彩色 ringing。透明四角保留；最终 alpha 最大值为 28，层只用于局部加深，不改变基础层全局曝光。

## 审查、被拒版本与已知限制

- `studio_light_lamp_composite_preview_v3.png` 与 `studio_state_lamp_off_composite_preview.png` 是将各层叠加在 `studio_base.png` 上的审查图，不是运行时依赖。
- 被拒台灯光层 v1：源图 `studio_light_lamp_chroma.png`（默认输出 `C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-bd5a08e8-ac3b-437a-934f-e9bc215c805a.png`）使用洋红色键；去色键后出现接近色键的粉红边缘和过宽光场，不能作为可叠加资产，故仅保留为审查对照。
- 被拒台灯光层 v2：源图 `studio_light_lamp_chroma_green.png`（默认输出 `C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-c9f8f1d5-0abb-44ec-8757-5999ff2e8615.png`）使用绿色键；去色键后的合成预览 `studio_light_lamp_composite_preview_v2.png` 形成大面积高饱和黄色覆盖，延伸到调音台、椅背并且中心接近不透明，违反局部灯光范围，故不进入 runtime。
- 未采用的中间修订源：`C:\Users\32402\.codex\generated_images\019fe4eb-c425-70e2-b88f-120bb68a36e9\exec-bff25421-d38b-46cb-b390-952f6c7fb1ec.png` 虽已改为绿色键和较窄横向光场，但仍需进一步缩小/限色，未写入 runtime；其项目内源副本未替换最终 v3。
- 修订台灯光层 v3：源图 `studio_light_lamp_v2_chroma_green.png`（默认输出 `exec-c91e0908-1e54-499a-b5e5-642b5f969e45.png`）生成小范围低强度纹理，再经坐标遮罩和色调/alpha 限制成为当前 `studio_light_lamp.png`。
- 被拒版本仍保留在 `art/source/studio_overview/`：`studio_light_lamp_chroma.png`、`studio_light_lamp_keyed_1672x941.png`、`studio_light_lamp_composite_preview.png`、`studio_light_lamp_chroma_green.png`、`studio_light_lamp_composite_preview_v2.png`；最终运行时文件已替换为修订版。
- 由于内置 `image_gen` 未提供原生透明输出，透明层采用平坦色键生成后本地去色键；边缘为技能助手的软 matte，并通过裁切、色调压低、alpha 限幅和空间遮罩稳定范围。需要在 Godot 工程实际叠加验证灯光与 CRT/电话状态层的连续性；本轮未声称完成四视图运行时验收。

## 总览雨幕前景遮挡层 `studio_foreground_window`

### 交付与输入角色

- 日期：2026-08-09。
- 用途：放在 `WindowRainFx` 程序化雨线之上的 1920×1080 RGBA 前景层；只遮挡中央雨窗的室内窗框内边、下窗台、台灯关节臂/灯罩和悬挂麦克风。
- 输入图 1（权威构图参考）：`E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\studio_overview_v2.png`，用于机位、窗框、台灯和麦克风连续性。
- 输入图 2（对齐/材质参考）：`E:\GAME\Last Shift Radio\art\runtime\studio_overview\studio_base.png`，用于已经缩放到 1920×1080 的精确像素位置和室内材质；不改变该基础层。
- 原始生成源：`C:\Users\32402\.codex\generated_images\019fe523-122f-76f0-98b0-c0ce87b01552\exec-941eaf54-3224-44bc-8639-d328a357278e.png`；项目内副本为 `studio_foreground_window_chroma_source.png`。
- 内置工具未公开后端模型版本，记录为“不可获得”；生成工具为 Codex 内置 `image_gen`。未使用第三方图片、字体、标识或可读文字。

### 实际生成提示词（完整）

```text
Generate a chroma-key source image for the requested Studio A foreground occlusion layer. Flat #00ff00 background only, with exact aligned dark window inner frame and lower sill, articulated desk-lamp arm/shade/bulb crossing the left half of the window, and hanging broadcast microphone crossing the lower center of the window, matching the referenced composition. No window glass, rain, wall, desk, CRT, phone, console, door, text, UI, scenery, people, or any other object. Keep all empty areas pure green.
```

### 色键、对齐和后期

1. 内置生成源采用平坦 `#00ff00` 色键；使用 `C:\Users\32402\.codex\skills\.system\imagegen\scripts\remove_chroma_key.py`，参数为 `--auto-key border --soft-matte --transparent-threshold 12 --opaque-threshold 220 --despill --edge-contract 1`。助手本次检测到的边框色为 `#09ec12`，生成 `studio_foreground_window_keyed_1672x941.png`。
2. 由于生成源的通用窗框位置不能满足旧总览的像素级机位，最终遮挡层以 `studio_base.png` 为材质来源，按旧总览和 `WindowRainClip`（`x=406..1190,y=203..650`）做可追溯 4× 手工矢量对齐：窗框内外环和下窗台使用原图像素，台灯臂/灯罩/灯泡与麦克风仅保留其在雨窗前的轮廓；玻璃外景、雨、墙、桌面、电话、CRT、调音台、门、文字和 UI 均未写入透明区域。
3. 台灯与麦克风轮廓使用深色中性色相对蓝色玻璃的置信遮罩（`B-R`）抑制窗外纹理，并以 premultiplied-alpha Lanczos 缩放保存 `studio_foreground_window_processed_1672x941.png`；最终 1920×1080 RGBA 运行为 `art/runtime/studio_overview/studio_foreground_window.png`，母版为 `studio_foreground_window_processed_1920x1080.png`。
4. 透明四角 alpha 均为 `0`；最终 alpha 非零包围盒为 `(390,185)`～`(1177,660)`（含边界），非零像素 `65,436`，其中部分透明像素 `19,116`，最大 alpha `255`。所有保存图均为 `1920×1080`（运行时）或 `1672×941`（源母版）并带 RGBA 通道。

### 雨幕合成审查

- `studio_base_rain_foreground_preview.png` 是 `studio_base.png` + 49 条固定随机种子 `199904` 的简单雨线 + 前景层的审查预览，不是运行时依赖。
- 人工放大检查确认雨线位于前景层下方，未覆盖窗框、台灯关节臂/灯罩或悬挂麦克风（包括灯臂与麦克风之间的短连接件）；四角保持透明。
- 已知限制：当前 `WindowRainClip` 的下边缘靠近调音台顶缘、右边缘略越过窗框；为遵守“前景只含窗框/台灯/麦克风”的约束，最终 alpha 有意排除调音台、CRT 和右侧设备，故简单雨线预览在这些 clip 越界处仍可能落到原基础层的设备/墙面。Godot 集成时仍需按真实运行画面收紧雨窗裁切边界，不把未授权设备作为前景层补入。
