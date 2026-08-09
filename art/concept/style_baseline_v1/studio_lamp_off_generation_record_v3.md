# 工作室总览台灯熄灭素材生成记录 v3

- 日期：2026-08-08
- 用途：`studio_overview_v2.png` 的工作室总览台灯熄灭切换素材。
- 输入编辑目标：`E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\studio_overview_v2.png`
- 内置工具：`image_gen`（内置图像编辑）。
- 模型版本：内置工具未公开模型版本，无法获得。
- 默认生成目录原文件：`C:\Users\32402\.codex\generated_images\019fe1e4-c6f0-7e72-bb4d-1b694cc06ff9\exec-018f0e0b-4f0c-4ee1-bea8-b8795b06541c.png`
- 项目文件：`E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\studio_overview_lamp_off_v3.png`
- 后期修改：无；项目文件是默认生成目录原文件的直接复制。
- 尺寸校验：输入与项目文件均为 `1672×941`。

## 最终提示词

```text
Use case: precise-object-edit
Asset type: 2D fixed-view psychological horror game lighting-toggle asset
Primary request: Edit Image 1 only. Turn OFF the existing articulated desk lamp at the left-center of the desk, whose lampshade is centered around x=390, y=450 in this 1672×941 image. The lamp must remain present in exactly the same position, shape, silhouette, arm joints, shade, perspective, and material; only its bulb and shade interior lose their warm glow.
Input images: Image 1: edit target.
Scene/backdrop: Preserve this exact existing 1999 radio studio overview, including its composition, camera, central rainy window, door, small observation window, control desk, equipment, telephone, hanging microphone, CRT monitor, chair, papers, and every background object.
Lighting/mood: Make a tightly local lighting edit only: remove the warm yellow light emitted directly from this left desk lamp and its nearby warm spill on immediately adjacent desk surfaces and nearby left console/phone/papers. Do NOT darken, brighten, recolor, rebuild, or otherwise alter the global scene illumination. Do NOT change the brightness, color, glow, or content of the CRT monitor, red indicator lights, central rainy night window, door, observation window, or any non-lamp area outside this lamp's direct warm light pool. All cold blue rain-night lighting and all other source intensities must remain visually identical to Image 1.
Style/medium: Preserve the exact original dark cinematic realistic concept-art style, texture, grain, camera viewpoint, framing, perspective, material detail, and 1672×941 pixel dimensions.
Constraints: Change only the desk lamp's ON/OFF state and the direct warm local lighting that it physically casts. Keep every object and silhouette unchanged. The result must cut seamlessly against Image 1 as a frame-by-frame lamp toggle with maximal pixel-level continuity outside the lamp and its immediately lit desk area.
Avoid: no global exposure change, no global darkening, no global color grading, no missing lamp or altered lamp, no changed CRT brightness, no changed red LEDs, no changed rainy window, no new rain streaks, no people, no creatures, no monsters, no text, no logos, no watermarks, no new geometry, no frames, no crop, no shift, no restyling, no object additions or removals.
```

## 视觉自检

- 左侧桌面台灯的灯罩内部与灯泡均无可见发光。
- 原先由该台灯造成的桌面、电话与调音台暖黄局部照明已移除。
- CRT 屏幕辉光、红色设备指示灯、门、小观察窗与中央窗外固有雨夜背景均保留。
- 未发现新增雨线、人物、怪物、文字或几何框；构图与视角保持一致，适合与亮灯图进行高连续性的逐帧切换。
