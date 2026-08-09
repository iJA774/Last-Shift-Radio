class_name SettingsUiScale
extends RefCounted
## 统一将当前界面的可读字体缩放到设置档位。
##
## 场景中的字号有一部分来自 Theme、一部分来自局部 override，不能只修改
## Theme 而遗漏后者。本工具在第一次处理控件时记录原始 override；随后无论
## 菜单、覆盖层或动态电脑卡片何时重建，都能回到其原始设计字号而不叠乘。

const META_BASE_FONT_SIZE: StringName = &"settings_base_font_size"
const META_HAD_FONT_OVERRIDE: StringName = &"settings_had_font_override"
const META_APPLIED_PERCENT: StringName = &"settings_applied_font_percent"
const FONT_SIZE_THEME_KEY: StringName = &"font_size"


static func apply_font_size(root: Node, font_size_percent: int, inherited_percent: int = 100) -> Dictionary:
	if root == null or not is_instance_valid(root):
		return {"ok": false, "message": "字体设置目标界面不可用。"}
	if font_size_percent != 100 and font_size_percent != 125:
		return {"ok": false, "message": "不支持的字体大小档位：%d。" % font_size_percent}
	if inherited_percent != 100 and inherited_percent != 125:
		return {"ok": false, "message": "字体设置继承档位无效：%d。" % inherited_percent}
	var previous_percent: int = int(root.get_meta(META_APPLIED_PERCENT, inherited_percent))
	if previous_percent != 100 and previous_percent != 125:
		previous_percent = inherited_percent
	var controls: Array[Control] = []
	_collect_controls(root, controls)
	# 先在整个子树采集基准，避免父控件先写入 override 后子控件读取到已缩放字号。
	for control: Control in controls:
		_capture_base_font_size(control, previous_percent)
	for control: Control in controls:
		_apply_control_font_size(control, font_size_percent)
	root.set_meta(META_APPLIED_PERCENT, font_size_percent)
	return {"ok": true, "font_size": font_size_percent, "control_count": controls.size()}


static func _collect_controls(node: Node, output: Array[Control]) -> void:
	if node is Control:
		output.append(node as Control)
	for child: Node in node.get_children():
		_collect_controls(child, output)


static func _capture_base_font_size(control: Control, previous_percent: int) -> void:
	if control.has_meta(META_BASE_FONT_SIZE) and control.has_meta(META_HAD_FONT_OVERRIDE):
		return
	var had_override: bool = control.has_theme_font_size_override(FONT_SIZE_THEME_KEY)
	var current_size: int = control.get_theme_font_size(FONT_SIZE_THEME_KEY)
	var base_size: int = current_size
	if not had_override and previous_percent != 100:
		base_size = maxi(1, roundi(float(current_size) * 100.0 / float(previous_percent)))
	control.set_meta(META_BASE_FONT_SIZE, base_size)
	control.set_meta(META_HAD_FONT_OVERRIDE, had_override)


static func _apply_control_font_size(control: Control, font_size_percent: int) -> void:
	var base_size: int = int(control.get_meta(META_BASE_FONT_SIZE, 16))
	var had_override: bool = bool(control.get_meta(META_HAD_FONT_OVERRIDE, false))
	if font_size_percent == 100:
		if had_override:
			control.add_theme_font_size_override(FONT_SIZE_THEME_KEY, base_size)
		else:
			control.remove_theme_font_size_override(FONT_SIZE_THEME_KEY)
		return
	control.add_theme_font_size_override(
		FONT_SIZE_THEME_KEY,
		maxi(1, roundi(float(base_size) * float(font_size_percent) / 100.0))
	)
