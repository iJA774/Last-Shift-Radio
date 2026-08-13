# 观察窗路灯熄灭素材生成记录 v3

- 生成日期：2026-08-08
- 原用途：观察窗近景中“门外路灯熄灭”的逐帧切换背景。
- 运行时状态：**已于 2026-08-13 退役**。该整帧编辑图与亮灯底图存在透视/构图连续性问题，会导致闪烁时画面抽搐；保留本文件仅用于来源与缺陷审计，场景不再引用它。
- 编辑目标：`E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\door_window_closeup_v2.png`
- 使用工具：Codex 内置 `image_gen` 图像编辑工具。
- 模型版本：内置工具未提供可获得的模型版本信息，未臆测或补写版本号。
- 默认生成目录原文件：`C:\Users\32402\.codex\generated_images\019fe183-2bb8-7cf3-aacc-1c85b545bd10\exec-1a6fb967-1a1b-43d8-85d5-7d8644b8ae24.png`
- 项目文件：`E:\GAME\Last Shift Radio\art\concept\style_baseline_v1\door_window_closeup_street_lamp_off_v3.png`
- 输出分辨率：1672×941，与编辑目标一致。
- 输出 SHA-256：`0F11F86247EA81E6C40307388DFB2706473131778006FD04BE2DC29E65CD541D`
- 后期修改：无。项目文件由内置工具的原始 PNG 直接复制，未裁切、调色、重绘或压缩。

## 最终提示词

```text
Use case: lighting-weather
Asset type: Last Shift Radio 观察窗近景的可切换游戏背景，作为现有亮灯版本的紧邻帧。
Input images: Image 1 is the edit target and mandatory compositional reference.
Primary request: Precisely edit Image 1 so that only the single sodium-vapor street lamp visible outside the central wired-glass pane is switched off.
Scene/backdrop: the same rain-dark alley viewed through the same single central wired-glass window, with the same narrow dark door frames on the left and right.
Subject: the existing lamp remains in exactly the same position, silhouette, size, shade shape, perspective, and partial obstruction by the wired glass, but its bulb and shade emit absolutely no light.
Lighting/mood: remove all warm sodium illumination cast by that lamp from the rainy alley, wet ground, rain droplets, moisture on the glass, nearby surfaces, and reflections. Keep the unlit alley dark and cool blue-black only; do not introduce any replacement or second light source.
Materials/textures: preserve the exact wired-glass diamond mesh, raindrops, wet-glass distortion, rain-night background texture, framing, perspective, material appearance, and original image resolution.
Constraints: Change only the lamp's emission and its warm spill/reflection. Maintain extremely high frame-to-frame continuity with Image 1. Keep one single central pane of wired glass and the narrow left/right door frames. No new procedural rain streaks. No people, creatures, text, symbols, geometric overlays, extra windows, extra lamps, or added light sources. No watermark.
```

## 自检结论

生成当时的自检曾认为路灯位置与门窗结构保持一致。2026-08-13 的缺陷复核确认该判断不成立：左右窗边分别存在约 4 px 的反向位移，中央窗口宽度约差 7 px，雨滴、网格和远景也被重新生成，无法作为相邻切换帧。该素材现已被稳定亮灯底图上的局部暗化遮罩替代，处理记录见 `../../runtime/door_window/street_lamp_darkening_mask_processing_record.md`。
