extends SceneTree

## 字号设置只能作用于真实文字控件，不能向 TextureRect 或纯布局 Control
## 写入 font_size 覆写；否则会破坏 HUD 图集和固定定位。

const SETTINGS_UI_SCALE_SCRIPT: GDScript = preload("res://scripts/ui/settings_ui_scale.gd")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_control := Control.new()
	var text_label := Label.new()
	text_label.add_theme_font_size_override(&"font_size", 20)
	var action_button := Button.new()
	action_button.add_theme_font_size_override(&"font_size", 18)
	var option_button := OptionButton.new()
	option_button.add_theme_font_size_override(&"font_size", 16)
	var image := TextureRect.new()
	var layout := Control.new()
	root_control.add_child(text_label)
	root_control.add_child(action_button)
	root_control.add_child(option_button)
	root_control.add_child(image)
	root_control.add_child(layout)

	_assert_ok(SETTINGS_UI_SCALE_SCRIPT.apply_font_size(root_control, 125), "必须能应用 125% 字号。")
	_assert_equal(text_label.get_theme_font_size(&"font_size"), 25, "Label 必须按 125% 缩放。")
	_assert_equal(action_button.get_theme_font_size(&"font_size"), 23, "Button 必须按 125% 缩放。")
	_assert_equal(option_button.get_theme_font_size(&"font_size"), 20, "OptionButton 必须按 125% 缩放。")
	_assert_true(not image.has_theme_font_size_override(&"font_size"), "TextureRect 不得获得 font_size 覆写。")
	_assert_true(not layout.has_theme_font_size_override(&"font_size"), "纯布局 Control 不得获得 font_size 覆写。")
	_assert_ok(SETTINGS_UI_SCALE_SCRIPT.apply_font_size(root_control, 100, 125), "必须能恢复 100% 字号。")
	_assert_equal(text_label.get_theme_font_size(&"font_size"), 20, "恢复后 Label 必须回到基准字号。")
	root_control.free()
	_finish()


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][SettingsUiScale] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _finish() -> void:
	if _has_failed:
		print("[测试][SettingsUiScale] 失败。")
		quit(1)
		return
	print("[测试][SettingsUiScale] 通过：字号设置只影响真实文字控件。")
	quit(0)
