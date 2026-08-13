# 门外路灯局部暗化遮罩处理记录

- 处理日期：2026-08-13
- 用途：门与观察窗近景的低频路灯熄灭效果；仅遮暗路灯、近处光晕和湿地反射，不能替换整张背景。
- 输入底图：`art/concept/style_baseline_v1/door_window_closeup_v2.png`
- 输出：`art/runtime/door_window/street_lamp_darkening_mask.png`
- 输出画布：1672×941 RGBA PNG；alpha 外像素为完全透明。
- 工具：本地 Python 3（Pillow）。
- 作者：Codex（按缺陷修复任务生成）。

## 确定性处理参数

遮罩由四个以路灯光源与反射为中心的椭圆二次衰减区组成，按每像素最大 alpha 合并：

| 中心 `(x, y)` | 半径 `(rx, ry)` | 最大 alpha |
| --- | --- | --- |
| `(704, 316)` | `(52, 62)` | `0.985` |
| `(675, 370)` | `(105, 125)` | `0.780` |
| `(640, 490)` | `(140, 185)` | `0.660` |
| `(605, 735)` | `(175, 160)` | `0.540` |

对每个椭圆，`d = ((x-cx)/rx)^2 + ((y-cy)/ry)^2`；仅 `d < 1` 时写入
`alpha = peak * (1-d)^2`。有 alpha 的像素写为冷黑 `RGBA(2, 12, 20, alpha)`，其余像素维持
`RGBA(0, 0, 0, 0)`。最终 alpha 像素边界固定为 `(436, 249, 342, 642)`。

## 验证契约

- 运行时仅显示 `door_window_closeup_v2.png` 这张稳定底图；路灯熄灭时叠加本遮罩，绝不切换 AI 生成的整帧熄灯图。
- `tests/smoke/test_door_lamp_flicker_alignment.gd` 在 1920×1080 下断言两层节点 rect 一致、遮罩 alpha 锚点不变、亮/灭差分只在遮罩映射区域内，并写入实机亮帧、灭帧与差分图。
- `door_window_closeup_street_lamp_off_v3.png` 作为导致抽搐的原始审计对象保留在概念素材目录，运行时场景不再引用它。
