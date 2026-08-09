# 低饱和 UI 美术资源包 `low_saturation_v1`

## 定位

本目录保存可独立接入 Godot 的 UI 栅格资源，不是整张 UI 概念图。资源遵循《美术风格基调》中“默认无厚重外框、低饱和、弱边界、由 Godot 绘制文字”的规则。

`runtime/` 中的文件已经从纯色键控源图转换为带透明通道的 PNG，可供项目引用；`source_generated/` 只用于保留生成溯源，不应被运行时加载。

## 运行时资源清单

| 类别 | 文件 | 尺寸 | 建议用途 |
| --- | --- | --- | --- |
| 面板 | [panel_backdrop.png](panels/runtime/panel_backdrop.png) | 1536×1024 | 通用信息面板、设置或存档弹层的 `NinePatchRect` |
| 面板 | [dialogue_backdrop.png](panels/runtime/dialogue_backdrop.png) | 1983×793 | 电话对白区、选择区的 `NinePatchRect` |
| 按钮 | [button_default.png](buttons/runtime/button_default.png) | 1774×887 | `TextureButton` Normal |
| 按钮 | [button_hover.png](buttons/runtime/button_hover.png) | 1774×887 | `TextureButton` Hover |
| 按钮 | [button_pressed.png](buttons/runtime/button_pressed.png) | 1774×887 | `TextureButton` Pressed |
| 按钮 | [button_disabled.png](buttons/runtime/button_disabled.png) | 1774×887 | `TextureButton` Disabled，仍需中文禁用原因 |
| 图标 | [icon_phone_ringing.png](icons/runtime/icon_phone_ringing.png) | 1254×1254 | 来电状态，配合“正在响铃”等文字 |
| 图标 | [icon_unread.png](icons/runtime/icon_unread.png) | 1254×1254 | 未读状态，配合“未读”或数量 |
| 图标 | [icon_back.png](icons/runtime/icon_back.png) | 1254×1254 | 返回总览或返回上一级 |
| 图标 | [icon_warning.png](icons/runtime/icon_warning.png) | 1254×1254 | 错误、警告或禁用原因标题 |

## Godot 接入起点

- 只引用各分类的 `runtime/` PNG，不引用 `source_generated/`。
- `panel_backdrop.png` 的 NinePatch Margin 可先从四边 96 px 试起。
- `dialogue_backdrop.png` 的 NinePatch Margin 可先从四边 112 px 试起。
- 四张按钮使用相同切片参数；可先试左右约 80 px、上下约 220 px，避免把边缘磨损放进拉伸中心。
- 按钮文字、说话人、正文、数量和禁用原因由独立 Godot `Label`/主题绘制，不写入位图。
- 图标保持等比缩放，设计目标显示尺寸为 32～64 px，并与简体中文状态文字同时出现。
- 未生成键盘焦点位图；若后续支持键盘焦点，应由 Godot Theme 绘制克制且清晰的焦点框。

上述切片与显示尺寸是接入起点，不是已通过的工程参数。

## 已完成的资产级验证

- 10 张运行时 PNG 均为 RGBA。
- 10 张图的四角 Alpha 均为 0。
- 对运行时图按 2 px 步长抽样，未发现可见的强洋红色键残留。
- 按钮四态画布尺寸一致；相对默认态的 Alpha 遮罩 IoU：Hover `0.997647`、Pressed `0.999965`、Disabled `0.999956`。
- 逐张目视确认：没有完整 UI 截图、内嵌文字、厚重金属框、螺丝徽章或霓虹发光；图标没有外围徽章底板。

## 尚未验证

- 当前仓库仍没有 `project.godot`，因此未创建 `.tres`、Theme 或测试场景。
- 尚未在 Godot 4.7.1 中验证 NinePatch 拉伸、纹理导入过滤、32/64 px 图标清晰度、默认/放大字体、1920×1080 四视图和非 16:9 安全区。
- 资源保留较大透明安全区；若 UI 线框确定后需要裁切，必须对按钮四态使用完全相同的裁切矩形，不能分别自动裁切。
- AI 绘制的中央磨砂纹理不是数学意义上的无缝纹理，过度拉伸时需要目视检查。

## 生成记录

- [面板生成记录](panels/generation_record.md)
- [按钮生成记录](buttons/generation_record.md)
- [图标生成记录](icons/generation_record.md)

记录包含内置 `image_gen` 的完整提示词、色键源图、去底参数、生成日期、尺寸、验证结果和已知限制。
