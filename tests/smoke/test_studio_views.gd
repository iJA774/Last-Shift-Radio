extends SceneTree
## 固定视图的无窗口冒烟检查。
## 覆盖场景装载、背景、真实设备命中区、环境效果与公开意图接口；
## 不把 UI 当作剧情状态机测试。

const STUDIO_OVERVIEW_SCENE: PackedScene = preload("res://scenes/studio/studio_overview.tscn")
const PHONE_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/phone_closeup.tscn")
const COMPUTER_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/computer_closeup.tscn")
const DOOR_WINDOW_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/door_window_closeup.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _failures: int = 0
var _view_requests: Array[String] = []
var _return_requests: int = 0
var _answer_requests: int = 0
var _choice_requests: int = 0
var _hang_up_requests: int = 0
var _finish_requests: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	await _test_studio_overview()
	await _test_phone_closeup()
	await _test_computer_closeup()
	await _test_door_window_closeup()
	_finish()


func _test_studio_overview() -> void:
	var overview: Control = STUDIO_OVERVIEW_SCENE.instantiate() as Control
	_assert_true(overview != null, "工作室总览场景必须可实例化为 Control。")
	if overview == null:
		return
	root.add_child(overview)
	await process_frame
	await process_frame
	await process_frame
	root.warp_mouse(Vector2(1910.0, 1060.0))
	await process_frame
	await _capture_view_if_requested("studio_overview_1920x1080.png")
	_assert_background_contract(overview, "studio_overview_v2.png", "工作室总览")
	_assert_window_rain_foreground_contract(overview)
	_assert_ambient_contract(overview, NodePath("AmbientFx"), "studio", "工作室总览")
	_assert_true(overview.get_node_or_null(NodePath("DoorWindowMask")) == null, "总览门体不得再使用会产生异色框的运行时遮罩。")
	var overview_atmosphere: Dictionary = overview.call(&"get_atmosphere_snapshot") as Dictionary
	var overview_lamp: Dictionary = overview_atmosphere.get("table_lamp", {}) as Dictionary
	var window_rain: Dictionary = overview_atmosphere.get("window_rain", {}) as Dictionary
	_assert_true(window_rain.size() > 0, "总览氛围快照必须公开独立窗外雨幕状态。")
	_assert_true((window_rain.get("far_rain_marks", []) as Array).size() > 0 and (window_rain.get("near_rain_marks", []) as Array).size() > 0, "窗外雨幕必须同时包含远近两层雨线。")
	_assert_true(float(overview_lamp.get("minimum_wait_seconds", 0.0)) >= 3.0 and float(overview_lamp.get("maximum_wait_seconds", 0.0)) <= 9.0, "台灯异常必须比旧版更频繁。")
	_assert_true(int(overview_lamp.get("minimum_burst_flickers", 0)) >= 3, "台灯异常必须是连续快速闪烁。")
	await _assert_background_material_switch(
		overview,
		NodePath("Background"),
		NodePath("BackgroundLampOff"),
		NodePath("TableLampMaterialSwitch"),
		"studio_overview_v2.png",
		"studio_overview_lamp_off_v3.png",
		"工作室总览"
	)
	_assert_true(overview.has_signal(&"view_requested"), "工作室总览必须公开 view_requested(view_id) 信号。")
	var targets_value: Variant = overview.call(&"get_hotspot_targets")
	_assert_true(targets_value is PackedStringArray, "工作室总览必须返回热点目标列表。")
	if targets_value is PackedStringArray:
		_assert_true(
			(targets_value as PackedStringArray) == PackedStringArray(["phone", "computer", "door"]),
			"总览热点目标必须且只能是 phone、computer、door。"
		)
	var connection: Error = overview.connect(&"view_requested", Callable(self, "_on_view_requested"))
	_assert_true(connection == OK, "工作室总览 view_requested 信号必须可连接。")
	var hotspot_names: PackedStringArray = PackedStringArray(["PhoneHotspot", "ComputerHotspot", "DoorHotspot"])
	var expected_targets: PackedStringArray = PackedStringArray(["phone", "computer", "door"])
	for index: int in hotspot_names.size():
		var hotspot: Button = overview.get_node_or_null(NodePath(hotspot_names[index])) as Button
		_assert_true(hotspot != null, "工作室总览缺少热点 %s。" % hotspot_names[index])
		if hotspot == null:
			continue
		_assert_true(not hotspot.disabled, "默认热点 %s 必须可用。" % hotspot_names[index])
		_assert_true(hotspot.text.is_empty(), "默认热点 %s 不得以大段文字遮挡概念图。" % hotspot_names[index])
		_assert_true(hotspot.tooltip_text.is_empty(), "启用热点 %s 不得显示重复的系统 tooltip。" % hotspot_names[index])
		_assert_true(hotspot.has_theme_stylebox_override(&"normal"), "热点 %s 必须有透明默认样式。" % hotspot_names[index])
		_assert_true(hotspot.has_theme_stylebox_override(&"hover"), "热点 %s 必须有悬停可见样式。" % hotspot_names[index])
		_assert_true(hotspot.has_theme_stylebox_override(&"pressed"), "热点 %s 必须有按下可见样式。" % hotspot_names[index])
		_assert_true(hotspot.has_theme_stylebox_override(&"disabled"), "热点 %s 必须有禁用可见样式。" % hotspot_names[index])
		hotspot.emit_signal(&"mouse_exited")
		hotspot.emit_signal(&"pressed")
		_assert_equal(_view_requests.back(), expected_targets[index], "热点必须只请求预期的近景目标。")
		var hint: PanelContainer = _get_overview_hint(overview, expected_targets[index])
		_assert_true(hint != null and not hint.visible, "默认热点 %s 不应显示行动提示。" % hotspot_names[index])
		hotspot.emit_signal(&"mouse_entered")
		_assert_true(hint != null and hint.visible, "悬停热点 %s 时必须显示短中文行动提示。" % hotspot_names[index])
		hotspot.emit_signal(&"button_down")
		_assert_true(hotspot.scale.x < 1.0, "按下热点 %s 时必须有轻微缩放反馈。" % hotspot_names[index])
		hotspot.emit_signal(&"button_up")
		_assert_true(is_equal_approx(hotspot.scale.x, 1.0), "松开热点 %s 后必须恢复原始缩放。" % hotspot_names[index])
		hotspot.emit_signal(&"mouse_exited")
		_assert_true(hint != null and not hint.visible, "离开热点 %s 后应隐藏行动提示。" % hotspot_names[index])
	var phone_hotspot: Button = overview.get_node_or_null(NodePath("PhoneHotspot")) as Button
	if phone_hotspot != null:
		phone_hotspot.emit_signal(&"mouse_entered")
	await process_frame
	await _capture_view_if_requested("studio_overview_phone_hover_1920x1080.png")
	if phone_hotspot != null:
		phone_hotspot.emit_signal(&"mouse_exited")
	var disable_result: Variant = overview.call(&"set_hotspot_enabled", "phone", false, "正在验证禁用反馈")
	_assert_true(disable_result is Dictionary and bool((disable_result as Dictionary).get("ok", false)), "总览必须接受带中文原因的热点禁用请求。")
	var phone_hint: PanelContainer = overview.get_node_or_null(NodePath("PhoneHint")) as PanelContainer
	var phone_hint_label: Label = overview.get_node_or_null(NodePath("PhoneHint/PhoneHintLabel")) as Label
	_assert_true(phone_hotspot != null and phone_hotspot.disabled, "电话热点禁用后必须停止接收输入。")
	_assert_true(phone_hint != null and phone_hint.visible, "电话热点禁用后必须显示可见文字原因，而非仅改变颜色。")
	_assert_true(phone_hint_label != null and phone_hint_label.text.contains("不可用"), "电话热点禁用后的提示必须包含中文不可用原因。")
	_assert_true(phone_hotspot != null and phone_hotspot.tooltip_text.contains("正在验证禁用反馈"), "禁用热点必须把完整中文原因保留在 tooltip 中。")
	await process_frame
	await _capture_view_if_requested("studio_overview_phone_disabled_1920x1080.png")
	if phone_hotspot != null:
		phone_hotspot.emit_signal(&"pressed")
	_assert_equal(_view_requests.size(), 3, "禁用热点不得继续发送导航请求。")
	overview.queue_free()
	await process_frame


func _test_phone_closeup() -> void:
	var closeup: Control = PHONE_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(closeup != null, "电话近景场景必须可实例化为 Control。")
	if closeup == null:
		return
	root.add_child(closeup)
	await process_frame
	await process_frame
	await process_frame
	await _capture_view_if_requested("phone_closeup_1920x1080.png")
	_assert_background_contract(closeup, "通话UI.png", "电话近景", TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	_assert_ambient_contract(closeup, NodePath("AmbientFx"), "equipment", "电话近景")
	_assert_true(closeup.has_method(&"set_motion_enabled"), "电话近景必须公开 set_motion_enabled()。")
	_assert_true(closeup.has_signal(&"return_requested"), "电话近景必须公开 return_requested()。")
	_assert_true(closeup.has_signal(&"answer_requested"), "电话近景必须公开 answer_requested()。")
	_assert_true(closeup.has_signal(&"dialogue_choice_requested"), "电话近景必须公开 dialogue_choice_requested()。")
	_assert_true(closeup.has_signal(&"hang_up_requested"), "电话近景必须公开 hang_up_requested()。")
	_connect_signal(closeup, &"return_requested", "_on_return_requested", "电话近景返回")
	_connect_signal(closeup, &"answer_requested", "_on_answer_requested", "电话近景接听意图")
	_connect_signal(closeup, &"dialogue_choice_requested", "_on_choice_requested", "电话近景选择意图")
	_connect_signal(closeup, &"hang_up_requested", "_on_hang_up_requested", "电话近景挂断意图")
	var phone_system: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var bind_result: Variant = closeup.call(&"bind_phone_system", phone_system)
	_assert_true(bind_result is Dictionary and bool((bind_result as Dictionary).get("ok", false)), "电话近景必须能绑定 PhoneSystem 只读接口。")
	var event_data: Dictionary = {
		"id": "call_view_smoke",
		"caller_display_name": "视图测试来电",
		"caller_number": "555-0199",
	}
	_assert_true(bool(phone_system.call(&"begin_incoming_call", event_data, 10, 60)), "电话视图测试必须能触发响铃。")
	await process_frame
	var caller_label: Label = closeup.get_node_or_null(NodePath("CallerLabel")) as Label
	_assert_true(caller_label != null and caller_label.get_theme_color(&"font_color") == Color(0.22, 0.105, 0.035, 1), "来电人信息必须使用通话美术可读的暖棕色。")
	await _capture_view_if_requested("phone_closeup_ringing_1920x1080.png")
	var answer_button: Button = closeup.get_node_or_null(NodePath("AnswerButton")) as Button
	_assert_true(answer_button != null and not answer_button.disabled, "响铃时电话近景必须启用接听意图。")
	if answer_button != null:
		answer_button.emit_signal(&"pressed")
	_assert_equal(_answer_requests, 1, "电话页接听按钮只能发意图，不自行修改 PhoneSystem。")
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "电话页发出接听意图后不得自行推进电话状态。")
	_assert_true(bool(phone_system.call(&"answer_call", 12)), "测试控制器必须能将电话推进为已接通。")
	await process_frame
	var choice_button: Button = closeup.get_node_or_null(NodePath("DialogueChoiceButton")) as Button
	var hang_up_button: Button = closeup.get_node_or_null(NodePath("HangUpButton")) as Button
	_assert_true(choice_button != null and not choice_button.disabled, "接通后必须能请求进入对话选择。")
	_assert_true(hang_up_button != null and not hang_up_button.disabled, "接通后必须能请求主动挂断。")
	_assert_true(closeup.get_node_or_null(NodePath("FinishButton")) == null, "通话美术只保留接通、继续对话与挂断三个电话操作按钮。")
	if choice_button != null:
		choice_button.emit_signal(&"pressed")
	if hang_up_button != null:
		hang_up_button.emit_signal(&"pressed")
	_assert_equal(_choice_requests, 1, "电话近景选择按钮必须发意图。")
	_assert_equal(_hang_up_requests, 1, "电话近景挂断按钮必须发意图。")
	var back_button: Button = closeup.get_node_or_null(NodePath("BackButton")) as Button
	_assert_true(back_button != null, "电话近景必须有明确返回按钮。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 1, "电话近景只应通过返回按钮请求总览。")
	var lock_result: Variant = closeup.call(&"set_return_enabled", false, "02:00 强制收束中，已锁定在电脑播出记录。")
	_assert_true(lock_result is Dictionary and bool((lock_result as Dictionary).get("ok", false)), "电话近景必须接受带中文原因的返回禁用请求。")
	_assert_true(back_button != null and back_button.disabled, "电话近景返回禁用后必须停止接收输入。")
	_assert_true(back_button != null and back_button.text.contains("不可用"), "电话近景返回禁用后必须显示中文原因，而非仅改变颜色。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 1, "禁用后的电话返回按钮不得继续发送返回请求。")
	closeup.queue_free()
	await process_frame


func _test_computer_closeup() -> void:
	var closeup: Control = COMPUTER_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(closeup != null, "电脑近景场景必须可实例化为 Control。")
	if closeup == null:
		return
	root.add_child(closeup)
	await process_frame
	await process_frame
	await process_frame
	await _capture_view_if_requested("computer_closeup_1920x1080.png")
	_assert_background_contract(closeup, "computer_closeup.png", "电脑近景")
	_assert_ambient_contract(closeup, NodePath("AmbientFx"), "equipment", "电脑近景")
	_assert_true(closeup.has_method(&"set_motion_enabled"), "电脑近景必须公开 set_motion_enabled()。")
	_assert_true(closeup.has_signal(&"return_requested"), "电脑近景必须公开 return_requested()。")
	_assert_true(closeup.has_method(&"bind_phone_system"), "电脑近景必须公开 bind_phone_system()。")
	_assert_true(closeup.has_method(&"show_unauthorized_broadcast"), "电脑近景必须公开 show_unauthorized_broadcast()。")
	var information_view: Control = closeup.get_node_or_null(NodePath("TerminalSurface/InformationView")) as Control
	_assert_true(information_view != null, "电脑近景必须包装独立的信息终端组件。")
	var screen_glow: ColorRect = closeup.get_node_or_null(NodePath("ScreenGlow")) as ColorRect
	var screen_cursor: Label = closeup.get_node_or_null(NodePath("ScreenCursor")) as Label
	_assert_true(screen_glow != null and screen_glow.visible, "电脑近景必须有 CRT 屏幕光感层。")
	_assert_true(screen_cursor != null and screen_cursor.visible, "电脑近景必须有可控的 CRT 光标。")
	var glow_tween: Tween = closeup.get("_glow_tween") as Tween
	_assert_true(glow_tween != null and glow_tween.is_valid(), "启用动态时 CRT 光感必须有低频呼吸 Tween。")
	var still_result: Variant = closeup.call(&"set_motion_enabled", false)
	_assert_true(still_result is Dictionary and bool((still_result as Dictionary).get("ok", false)), "电脑近景必须能停止 CRT 光感微动。")
	_assert_true(closeup.get("_glow_tween") == null, "减少动态后 CRT 光感 Tween 必须被终止。")
	_assert_true(screen_glow != null and is_equal_approx(screen_glow.modulate.a, 0.72), "减少动态后 CRT 光感必须停在低亮度静态状态。")
	var motion_result: Variant = closeup.call(&"set_motion_enabled", true)
	_assert_true(motion_result is Dictionary and bool((motion_result as Dictionary).get("ok", false)), "电脑近景必须能恢复 CRT 光感微动。")
	var phone_system: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var bind_result: Variant = closeup.call(&"bind_phone_system", phone_system)
	_assert_true(bind_result is Dictionary and bool((bind_result as Dictionary).get("ok", false)), "电脑近景必须将 PhoneSystem 绑定交给来电记录组件。")
	var broadcast_result: Variant = closeup.call(&"show_unauthorized_broadcast", {
		"broadcast_id": "broadcast_unauthorized_north_bridge_open",
		"fact_id": "fact_unauthorized_broadcast",
		"sent_at_tick": 3600,
		"time_tick": 3600,
		"source": "Studio A",
		"body": "北桥已经恢复通行。请保持车速，不要停车。",
		"is_unauthorized": true,
	})
	_assert_true(broadcast_result is Dictionary and bool((broadcast_result as Dictionary).get("ok", false)), "电脑近景必须显示 StoryEngine 提供的未授权播出记录。")
	_connect_signal(closeup, &"return_requested", "_on_return_requested", "电脑近景返回")
	var back_button: Button = closeup.get_node_or_null(NodePath("BackButton")) as Button
	_assert_true(back_button != null, "电脑近景必须有明确返回按钮。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 2, "电脑近景只能请求返回总览。")
	var lock_result: Variant = closeup.call(&"set_return_enabled", false, "02:00 强制收束中，已锁定在电脑播出记录。")
	_assert_true(lock_result is Dictionary and bool((lock_result as Dictionary).get("ok", false)), "电脑近景必须接受带中文原因的返回禁用请求。")
	_assert_true(back_button != null and back_button.disabled, "电脑近景返回禁用后必须停止接收输入。")
	_assert_true(back_button != null and back_button.text.contains("不可用"), "电脑近景返回禁用后必须显示中文原因，而非仅改变颜色。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 2, "禁用后的电脑返回按钮不得继续发送返回请求。")
	await process_frame
	await _capture_view_if_requested("computer_closeup_return_locked_1920x1080.png")
	closeup.queue_free()
	await process_frame


func _test_door_window_closeup() -> void:
	var closeup: Control = DOOR_WINDOW_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(closeup != null, "门窗近景场景必须可实例化为 Control。")
	if closeup == null:
		return
	root.add_child(closeup)
	await process_frame
	await process_frame
	await process_frame
	await _capture_view_if_requested("door_window_closeup_1920x1080.png")
	_assert_background_contract(closeup, "door_window_closeup_v2.png", "门窗近景")
	_assert_no_dynamic_rain_nodes(closeup, "门窗近景", false)
	var background_zoom: Control = closeup.get_node_or_null(NodePath("BackgroundZoom")) as Control
	_assert_true(background_zoom != null and background_zoom.clip_contents, "门窗近景必须放大观察窗并只在边缘保留门框。")
	var door_atmosphere: Dictionary = closeup.call(&"get_atmosphere_snapshot") as Dictionary
	var street_lamp: Dictionary = door_atmosphere.get("street_lamp", {}) as Dictionary
	_assert_true(not door_atmosphere.has("rain"), "门窗近景氛围快照不得保留雨层状态。")
	_assert_true(float(street_lamp.get("minimum_wait_seconds", 0.0)) >= 3.0 and float(street_lamp.get("maximum_wait_seconds", 0.0)) <= 12.0, "门外路灯异常必须比旧版更频繁。")
	_assert_true(int(street_lamp.get("minimum_burst_flickers", 0)) >= 3, "门外路灯异常必须是连续快速闪烁。")
	await _assert_background_material_switch(
		closeup,
		NodePath("BackgroundZoom/Background"),
		NodePath("BackgroundZoom/StreetLampDarkeningMask"),
		NodePath("StreetLampMaterialSwitch"),
		"door_window_closeup_v2.png",
		"street_lamp_darkening_mask.png",
		"门窗近景",
		true
	)
	_assert_true(closeup.has_method(&"set_motion_enabled"), "门窗近景必须公开 set_motion_enabled()。")
	_assert_true(closeup.has_signal(&"return_requested"), "门窗近景必须公开 return_requested()。")
	_assert_true(get_signal_list_size(closeup) == 1, "门窗近景不应暴露剧情实体或其他交互信号。")
	_connect_signal(closeup, &"return_requested", "_on_return_requested", "门窗近景返回")
	var back_button: Button = closeup.get_node_or_null(NodePath("BackButton")) as Button
	_assert_true(back_button != null, "门窗近景必须有明确返回按钮。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 3, "门窗近景只能请求返回总览。")
	var lock_result: Variant = closeup.call(&"set_return_enabled", false, "02:00 强制收束中，已锁定在电脑播出记录。")
	_assert_true(lock_result is Dictionary and bool((lock_result as Dictionary).get("ok", false)), "门窗近景必须接受带中文原因的返回禁用请求。")
	_assert_true(back_button != null and back_button.disabled, "门窗近景返回禁用后必须停止接收输入。")
	_assert_true(back_button != null and back_button.text.contains("不可用"), "门窗近景返回禁用后必须显示中文原因，而非仅改变颜色。")
	if back_button != null:
		back_button.emit_signal(&"pressed")
	_assert_equal(_return_requests, 3, "禁用后的门窗返回按钮不得继续发送返回请求。")
	closeup.queue_free()
	await process_frame


func _assert_background_contract(view: Control, texture_file_name: String, view_name: String, expected_stretch_mode: TextureRect.StretchMode = TextureRect.STRETCH_KEEP_ASPECT_COVERED) -> void:
	var background: TextureRect = view.get_node_or_null(NodePath("Background")) as TextureRect
	if background == null:
		background = view.get_node_or_null(NodePath("BackgroundZoom/Background")) as TextureRect
	_assert_true(background != null, "%s必须包含 TextureRect 背景。" % view_name)
	if background == null:
		return
	_assert_true(background.texture != null, "%s背景必须有已加载的概念图片资源。" % view_name)
	if background.texture != null:
		_assert_true(background.texture.resource_path.ends_with(texture_file_name), "%s背景必须引用对应概念图 %s。" % [view_name, texture_file_name])
	_assert_true(background.expand_mode == TextureRect.EXPAND_IGNORE_SIZE, "%s背景必须忽略原始纹理尺寸。" % view_name)
	_assert_true(background.stretch_mode == expected_stretch_mode, "%s背景必须使用约定的保持比例模式。" % view_name)


func _assert_window_rain_foreground_contract(overview: Control) -> void:
	var rain_clip: Control = overview.get_node_or_null(NodePath("WindowRainClip")) as Control
	var rain_fx: Control = overview.get_node_or_null(NodePath("WindowRainClip/WindowRainFx")) as Control
	var foreground: TextureRect = overview.get_node_or_null(NodePath("WindowInteriorForeground")) as TextureRect
	_assert_true(rain_clip != null and rain_clip.clip_contents and rain_fx != null, "窗外雨幕必须裁切在总览雨窗内部。")
	_assert_true(
		foreground != null and foreground.texture != null and foreground.texture.resource_path.ends_with("studio_foreground_window.png"),
		"总览必须在雨层之上使用室内窗框前景，遮挡台灯、麦克风与窗框区域的雨线。"
	)
	if foreground != null:
		_assert_true(foreground.expand_mode == TextureRect.EXPAND_IGNORE_SIZE, "室内窗框前景必须忽略原始纹理尺寸。")
		_assert_true(foreground.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED, "室内窗框前景必须保持画幅比例。")


func _assert_ambient_contract(view: Control, ambient_path: NodePath, profile_id: String, view_name: String) -> void:
	var ambient_fx: Control = view.get_node_or_null(ambient_path) as Control
	_assert_true(ambient_fx != null, "%s必须包含 AmbientFx 环境效果组件。" % view_name)
	if ambient_fx == null:
		return
	_assert_true(ambient_fx.mouse_filter == Control.MOUSE_FILTER_IGNORE, "%s环境效果不得接收鼠标输入。" % view_name)
	_assert_true(ambient_fx.has_method(&"get_profile"), "%s环境效果必须公开 get_profile()。" % view_name)
	_assert_true(String(ambient_fx.call(&"get_profile")) == profile_id, "%s环境效果 profile 必须为 %s。" % [view_name, profile_id])
	var disable_result: Variant = view.call(&"set_motion_enabled", false)
	_assert_true(disable_result is Dictionary and bool((disable_result as Dictionary).get("ok", false)), "%s必须能关闭动态效果。" % view_name)
	var disabled_snapshot: Variant = ambient_fx.call(&"get_effect_snapshot")
	_assert_true(
		disabled_snapshot is Dictionary and not bool((disabled_snapshot as Dictionary).get("motion_enabled", true)),
		"%s关闭动态后 AmbientFx 必须停止动态绘制。" % view_name
	)
	var enable_result: Variant = view.call(&"set_motion_enabled", true)
	_assert_true(enable_result is Dictionary and bool((enable_result as Dictionary).get("ok", false)), "%s必须能恢复动态效果。" % view_name)


func _assert_no_dynamic_rain_nodes(view: Control, view_name: String, keeps_indoor_ambient: bool) -> void:
	_assert_true(view.get_node_or_null(NodePath("StormWindowClip")) == null, "%s不得保留 StormWindowClip 程序化雨层。" % view_name)
	_assert_true(view.get_node_or_null(NodePath("RainWindowClip")) == null, "%s不得保留 RainWindowClip 程序化雨层。" % view_name)
	_assert_true(view.get_node_or_null(NodePath("StormWindowClip/AmbientFx")) == null, "%s不得在总览窗外保留 AmbientFx 动态雨节点。" % view_name)
	_assert_true(view.get_node_or_null(NodePath("RainWindowClip/AmbientFx")) == null, "%s不得在观察窗保留 AmbientFx 动态雨节点。" % view_name)
	if not keeps_indoor_ambient:
		_assert_true(view.get_node_or_null(NodePath("AmbientFx")) == null, "%s不得保留任何 AmbientFx 动态雨节点。" % view_name)


func _assert_background_material_switch(
	view: Control,
	light_background_path: NodePath,
	off_background_path: NodePath,
	switch_path: NodePath,
	light_texture_name: String,
	off_texture_name: String,
	view_name: String,
	keeps_light_background_visible: bool = false
) -> void:
	var light_background: TextureRect = view.get_node_or_null(light_background_path) as TextureRect
	var off_background: TextureRect = view.get_node_or_null(off_background_path) as TextureRect
	var material_switch: Control = view.get_node_or_null(switch_path) as Control
	_assert_true(light_background != null and off_background != null, "%s必须预留亮灯与灭灯 TextureRect。" % view_name)
	_assert_true(material_switch != null, "%s必须包含低频背景素材切换组件。" % view_name)
	if light_background == null or off_background == null or material_switch == null:
		return
	_assert_true(light_background.texture != null and light_background.texture.resource_path.ends_with(light_texture_name), "%s亮灯背景必须引用 %s。" % [view_name, light_texture_name])
	_assert_true(off_background.texture != null and off_background.texture.resource_path.ends_with(off_texture_name), "%s灭灯背景必须引用 %s。" % [view_name, off_texture_name])
	_assert_true(not (material_switch is ColorRect), "%s不得再用 ColorRect 局部光晕实现闪烁。" % view_name)
	_assert_true(material_switch.material == null, "%s背景亮灭组件不得绑定局部光晕 Shader。" % view_name)
	_assert_true(material_switch.has_method(&"trigger_flicker_for_verification"), "%s素材切换组件必须提供确定性验收接口。" % view_name)
	var initial: Dictionary = material_switch.call(&"get_effect_snapshot") as Dictionary
	_assert_true(bool(initial.get("is_configured", false)), "%s素材切换组件必须已绑定亮灭 TextureRect。" % view_name)
	_assert_true(bool(initial.get("is_lit", false)), "%s默认必须显示亮灯背景。" % view_name)
	_assert_true(light_background.visible and not off_background.visible, "%s默认不得显示熄灯层。" % view_name)
	_assert_true(light_background.get_global_rect() == off_background.get_global_rect(), "%s亮灯底图与熄灯层必须使用完全相同的 1920×1080 几何区域。" % view_name)
	_assert_true(float(initial.get("minimum_wait_seconds", 0.0)) >= 3.0, "%s自动异常间隔不得低于 3 秒。" % view_name)
	_assert_true(int(initial.get("minimum_burst_flickers", 0)) >= 3, "%s灯光异常必须包含连续快速连闪。" % view_name)
	_assert_true(not initial.has("tween_is_running") and not initial.has("current_alpha"), "%s不得保留透明度 Tween 或光晕透明度状态。" % view_name)
	var trigger_result: Variant = material_switch.call(&"trigger_flicker_for_verification")
	_assert_true(trigger_result is Dictionary and bool((trigger_result as Dictionary).get("ok", false)), "%s必须能确定性切换到熄灯状态。" % view_name)
	await process_frame
	var during: Dictionary = material_switch.call(&"get_effect_snapshot") as Dictionary
	_assert_true(not bool(during.get("is_lit", true)), "%s触发后必须处于灭灯状态。" % view_name)
	if keeps_light_background_visible:
		_assert_true(light_background.visible and off_background.visible, "%s熄灯时必须保留稳定底图，仅叠加局部暗化层。" % view_name)
	else:
		_assert_true(not light_background.visible and off_background.visible, "%s触发后必须直接显示灭灯背景素材。" % view_name)
	var disable_result: Variant = view.call(&"set_motion_enabled", false)
	_assert_true(disable_result is Dictionary and bool((disable_result as Dictionary).get("ok", false)), "%s必须能关闭背景素材切换动态。" % view_name)
	var disabled: Dictionary = material_switch.call(&"get_effect_snapshot") as Dictionary
	_assert_true(not bool(disabled.get("schedule_timer_is_running", true)) and not bool(disabled.get("off_timer_is_running", true)), "%s减少动态后不得保留亮灭 Timer。" % view_name)
	_assert_true(bool(disabled.get("is_lit", false)) and light_background.visible and not off_background.visible, "%s减少动态后必须稳定回亮灯状态。" % view_name)
	var enable_result: Variant = view.call(&"set_motion_enabled", true)
	_assert_true(enable_result is Dictionary and bool((enable_result as Dictionary).get("ok", false)), "%s必须能恢复背景素材切换动态。" % view_name)


func _get_overview_hint(overview: Control, view_id: String) -> PanelContainer:
	match view_id:
		"phone":
			return overview.get_node_or_null(NodePath("PhoneHint")) as PanelContainer
		"computer":
			return overview.get_node_or_null(NodePath("ComputerHint")) as PanelContainer
		"door":
			return overview.get_node_or_null(NodePath("DoorHint")) as PanelContainer
	return null


func _capture_view_if_requested(file_name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-studio-views"):
		return
	await RenderingServer.frame_post_draw
	var output_directory: String = ProjectSettings.globalize_path("user://studio_views_visual_qa")
	var directory_result: Error = DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_result != OK:
		_assert_true(false, "无法创建视图截图目录，错误码=%d。" % directory_result)
		return
	var viewport_texture: ViewportTexture = root.get_texture()
	if viewport_texture == null:
		_assert_true(false, "当前渲染驱动不支持取得视图截图纹理。")
		return
	var image: Image = viewport_texture.get_image()
	if image == null:
		_assert_true(false, "当前渲染驱动未返回可保存的视图截图。")
		return
	var output_path: String = "%s/%s" % [output_directory, file_name]
	var save_result: Error = image.save_png(output_path)
	_assert_true(save_result == OK, "无法保存 1920×1080 视图截图：%s。" % output_path)
	if save_result == OK:
		print("[测试][StudioViews] 已保存 UI 视觉检查截图：%s" % output_path)


func get_signal_list_size(node: Object) -> int:
	var custom_signal_count: int = 0
	for raw_signal: Dictionary in node.get_signal_list():
		var signal_name: String = String(raw_signal.get("name", ""))
		if signal_name == "return_requested":
			custom_signal_count += 1
	return custom_signal_count


func _connect_signal(node: Object, signal_name: StringName, method_name: StringName, label: String) -> void:
	var result: Error = node.connect(signal_name, Callable(self, method_name))
	_assert_true(result == OK, "%s信号必须可连接。" % label)


func _on_view_requested(view_id: String) -> void:
	_view_requests.append(view_id)


func _on_return_requested() -> void:
	_return_requests += 1


func _on_answer_requested() -> void:
	_answer_requests += 1


func _on_choice_requested() -> void:
	_choice_requests += 1


func _on_hang_up_requested() -> void:
	_hang_up_requests += 1


func _on_finish_requested() -> void:
	_finish_requests += 1


func _finish() -> void:
	if _failures == 0:
		print("[测试][StudioViews] 通过：四个固定视图、概念背景、导航信号和电话/电脑公开接口有效。")
		quit(0)
		return
	push_error("[测试][StudioViews] 失败数量=%d。" % _failures)
	quit(1)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[测试][StudioViews] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
