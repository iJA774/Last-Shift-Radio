extends SceneTree
## 电话与门窗旧游戏内 UI 的独立主题、隐私字段和放大字号回归检查。

const PHONE_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/phone_closeup.tscn")
const DOOR_WINDOW_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/door_window_closeup.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const LEGACY_THEME: Theme = preload("res://resources/legacy_game_ui_theme.tres")
const GLOBAL_STATUS_SAFE_RECT: Rect2 = Rect2(32.0, 30.0, 420.0, 258.0)
const INTERNAL_EVENT_ID: String = "call_internal_layout_probe_do_not_display"

var _failures: int = 0


class DialogueStub extends RefCounted:
	signal dialogue_changed(snapshot: Dictionary)

	var snapshot: Dictionary = {
		"speaker": "来电者",
		"text": "雨声很大。我只能确认桥口停着一辆旧旅行车，其他说法都还没有得到核实。",
		"is_terminal": false,
		"options": [
			{"id": "opt_confirm_time", "text": "请先确认你经过桥口的准确时间，以及当时是否已经开始下雨。"},
			{"id": "opt_confirm_direction", "text": "请回忆那辆旧旅行车当时朝向哪一侧，不确定的部分可以直接说明。"},
			{"id": "opt_reassure", "text": "先慢一点说。我们只登记你亲眼看见的情况，不会把传闻当成事实。"},
			{"id": "opt_repeat", "text": "线路有杂音，请把车辆、路灯和桥口的先后变化再重复一次。"},
		],
	}

	func get_active_dialogue_snapshot() -> Dictionary:
		return snapshot.duplicate(true)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	_test_theme_states()
	await _test_phone_closeup()
	await _test_door_closeup()
	_finish()


func _test_theme_states() -> void:
	_assert_true(LEGACY_THEME.resource_path.ends_with("legacy_game_ui_theme.tres"), "旧游戏 UI 必须使用独立 Theme 资源。")
	for state_name: StringName in [&"normal", &"hover", &"pressed", &"disabled", &"focus"]:
		_assert_true(LEGACY_THEME.has_stylebox(state_name, &"Button"), "独立 Theme 缺少按钮 %s 状态。" % state_name)
	_assert_true(LEGACY_THEME.has_stylebox(&"panel", &"PanelContainer"), "独立 Theme 必须提供低饱和面板样式。")


func _test_phone_closeup() -> void:
	var phone: Control = PHONE_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(phone != null, "电话近景必须可实例化。")
	if phone == null:
		return
	root.add_child(phone)
	await _wait_frames(4)
	_assert_true(phone.theme == LEGACY_THEME, "电话近景必须使用 legacy_game_ui_theme，不得继承主应用 Theme。")
	_assert_avoids_global_status(phone.get_node_or_null(NodePath("CallerLabel")) as Control, "电话来显区域")

	var phone_system: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var event_data: Dictionary = {
		"id": INTERNAL_EVENT_ID,
		"caller_display_name": "北桥公共电话",
		"caller_number": "555-0199",
	}
	_assert_true(bool(phone_system.call(&"begin_incoming_call", event_data, 10, 60)), "测试来电必须能进入响铃。")
	_assert_ok(phone.call(&"bind_phone_system", phone_system), "电话近景必须能绑定测试 PhoneSystem。")
	_assert_true(bool(phone_system.call(&"answer_call", 12)), "测试来电必须能接通。")
	_assert_true(bool(phone_system.call(&"enter_dialogue_choice")), "测试来电必须能进入选择状态。")
	var dialogue_stub: DialogueStub = DialogueStub.new()
	_assert_ok(phone.call(&"bind_story_engine", dialogue_stub), "电话近景必须能绑定预制对话快照。")
	await _wait_frames(5)

	var caller_label: Label = phone.get_node_or_null(NodePath("CallerLabel")) as Label
	_assert_true(caller_label != null and caller_label.text.contains("登记名：北桥公共电话"), "电话来显必须显示登记名。")
	_assert_true(caller_label != null and caller_label.text.contains("号码：555-0199"), "电话来显必须显示号码。")
	_assert_true(caller_label != null and not caller_label.text.contains(INTERNAL_EVENT_ID), "电话来显不得泄露内部 event_id。")
	_assert_true(caller_label != null and not caller_label.text.contains("线路编号"), "电话来显不得用线路编号名义展示稳定 ID。")

	_assert_option_hidden(phone)
	_assert_ok(phone.call(&"reveal_dialogue_options"), "对方发言显示后，电话页必须能按继续对话意图展示回应。")
	await _wait_frames(3)
	_assert_option_layout(phone)
	_assert_ok(phone.call(&"stop_text_presentation"), "视觉检查前必须能完整显示当前对话段落。")
	await _capture_if_requested("phone_dialogue_options_1920x1080.png")
	dialogue_stub.snapshot = {
		"speaker": "来电者",
		"text": "……那就到这里吧。",
		"is_terminal": true,
		"options": [],
	}
	dialogue_stub.dialogue_changed.emit(dialogue_stub.snapshot.duplicate(true))
	await _wait_frames(2)
	var terminal_overlay: Control = phone.get_node_or_null(NodePath("DialogueChoiceOverlay")) as Control
	var terminal_text: Label = phone.get_node_or_null(NodePath("DialogueScroll/DialogueScrollContent/DialogueHintLabel")) as Label
	_assert_true(terminal_overlay != null and not terminal_overlay.visible, "本轮对白结束后不得遗留选择层。")
	_assert_true(terminal_text != null and not terminal_text.text.contains("本轮对话结束"), "本轮对白结束后不得显示开发提示条文案。")

	var lock_reason: String = "02:00 强制收束中，电话操作已经停止。"
	_assert_ok(phone.call(&"set_actions_enabled", false, lock_reason), "电话页必须接受带中文原因的操作锁定。")
	await _wait_frames(3)
	for button_path: NodePath in [
		NodePath("AnswerButton"),
		NodePath("DialogueChoiceButton"),
		NodePath("HangUpButton"),
	]:
		var action_button: Button = phone.get_node_or_null(button_path) as Button
		_assert_true(action_button != null and action_button.disabled, "锁定后电话操作按钮必须进入禁用态：%s。" % button_path)
		_assert_true(action_button != null and action_button.tooltip_text.contains(lock_reason), "禁用电话按钮必须保留具体中文原因：%s。" % button_path)
	phone.queue_free()
	await process_frame


func _assert_option_hidden(phone: Control) -> void:
	var overlay: Control = phone.get_node_or_null(NodePath("DialogueChoiceOverlay")) as Control
	var dialogue_scroll: ScrollContainer = phone.get_node_or_null(NodePath("DialogueScroll")) as ScrollContainer
	_assert_true(overlay != null and not overlay.visible, "对方发言刚出现时不得立刻弹出回应选项。")
	_assert_true(dialogue_scroll != null and dialogue_scroll.visible, "对方发言刚出现时正文必须可读。")


func _assert_option_layout(phone: Control) -> void:
	var overlay: Control = phone.get_node_or_null(NodePath("DialogueChoiceOverlay")) as Control
	var backdrop: ColorRect = phone.get_node_or_null(NodePath("DialogueChoiceOverlay/ChoiceBackdrop")) as ColorRect
	var title: Label = phone.get_node_or_null(NodePath("DialogueChoiceOverlay/ChoiceTitle")) as Label
	var choice_scroll: ScrollContainer = phone.get_node_or_null(NodePath("DialogueChoiceOverlay/ChoiceScroll")) as ScrollContainer
	var options: VBoxContainer = phone.get_node_or_null(NodePath("DialogueChoiceOverlay/ChoiceScroll/DialogueOptions")) as VBoxContainer
	var dialogue_scroll: ScrollContainer = phone.get_node_or_null(NodePath("DialogueScroll")) as ScrollContainer
	_assert_true(overlay != null and overlay.visible, "继续对话后分支选项必须显示在正文下方。")
	_assert_true(backdrop != null and title != null and choice_scroll != null, "选择层必须包含清晰的面板、标题和可滚动选项区。")
	_assert_true(dialogue_scroll != null and dialogue_scroll.visible, "选择出现后对方发言仍必须可读。")
	_assert_non_overlapping_header(phone, "默认字号")
	if backdrop != null and title != null and choice_scroll != null:
		_assert_true(backdrop.get_global_rect().encloses(title.get_global_rect()) and backdrop.get_global_rect().encloses(choice_scroll.get_global_rect()), "选择标题和选项区必须完整置于独立面板内。")
		_assert_true(choice_scroll.get_global_rect().position.y >= dialogue_scroll.get_global_rect().end.y, "选项区不得覆盖对方发言。")
	_assert_true(options != null and options.get_child_count() == 4, "必须完整生成四个预制选项。")
	if options == null:
		return
	for child: Node in options.get_children():
		var button: Button = child as Button
		_assert_true(button != null, "动态选项必须是按钮。")
		if button == null:
			continue
		var minimum_size: Vector2 = button.get_combined_minimum_size()
		_assert_true(button.autowrap_mode != TextServer.AUTOWRAP_OFF, "动态选项必须允许中文换行。")
		_assert_true(button.size.x + 1.0 >= minimum_size.x and button.size.y + 1.0 >= minimum_size.y, "动态选项不得截断：minimum=%s，size=%s。" % [minimum_size, button.size])
		_assert_true(button.get_global_rect().size.x >= 1000.0, "每个选项必须保持横向长条边界，而非散落文字。")


func _assert_non_overlapping_header(phone: Control, scale_label: String) -> void:
	var caller: Control = phone.get_node_or_null(NodePath("CallerLabel")) as Control
	var state: Control = phone.get_node_or_null(NodePath("PhoneStateLabel")) as Control
	var back: Control = phone.get_node_or_null(NodePath("BackButton")) as Control
	_assert_true(caller != null and state != null and back != null, "%s下电话页必须保留来显、线路状态和返回入口。" % scale_label)
	if caller == null or state == null or back == null:
		return
	_assert_true(not caller.get_global_rect().intersects(state.get_global_rect()), "%s下来显与线路状态不得重叠。" % scale_label)
	_assert_true(not caller.get_global_rect().intersects(back.get_global_rect()), "%s下来显与返回入口不得重叠。" % scale_label)
	_assert_true(not state.get_global_rect().intersects(back.get_global_rect()), "%s下线路状态与返回入口不得重叠。" % scale_label)


func _test_door_closeup() -> void:
	var door: Control = DOOR_WINDOW_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(door != null, "门窗近景必须可实例化。")
	if door == null:
		return
	root.add_child(door)
	await _wait_frames(4)
	_assert_true(door.theme == LEGACY_THEME, "门窗近景必须与电话页使用同一独立 Theme。")
	var observation_panel: Control = door.get_node_or_null(NodePath("ObservationPanel")) as Control
	_assert_avoids_global_status(observation_panel, "门窗观察记录")
	var description: Label = door.get_node_or_null(NodePath("ObservationPanel/Content/DescriptionLabel")) as Label
	_assert_true(description != null and description.text.contains("没有可确认的变化"), "门窗观察记录必须保持克制，不引入可确认实体或玩法。")
	await _capture_if_requested("door_observation_1920x1080.png")
	door.queue_free()
	await process_frame


func _assert_avoids_global_status(control: Control, context: String) -> void:
	_assert_true(control != null, "%s必须存在。" % context)
	if control == null:
		return
	_assert_true(not control.get_global_rect().intersects(GLOBAL_STATUS_SAFE_RECT), "%s不得与全局时间牌及来电牌安全区重叠：rect=%s。" % [context, control.get_global_rect()])


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), message)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _capture_if_requested(file_name: String) -> void:
	if not OS.get_cmdline_user_args().has("--capture-legacy-closeups"):
		return
	await RenderingServer.frame_post_draw
	var output_directory: String = ProjectSettings.globalize_path("user://legacy_closeup_visual_qa")
	var directory_result: Error = DirAccess.make_dir_recursive_absolute(output_directory)
	_assert_true(directory_result == OK, "无法创建旧游戏 UI 截图目录，错误码=%d。" % directory_result)
	if directory_result != OK:
		return
	var image: Image = root.get_texture().get_image()
	var output_path: String = "%s/%s" % [output_directory, file_name]
	var save_result: Error = image.save_png(output_path)
	_assert_true(save_result == OK, "无法保存旧游戏 UI 截图：%s。" % output_path)
	if save_result == OK:
		print("[测试][LegacyCloseupUI] 已保存视觉检查截图：%s" % output_path)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[测试][LegacyCloseupUI] %s" % message)


func _finish() -> void:
	if _failures > 0:
		push_error("[测试][LegacyCloseupUI] 失败：共 %d 项。" % _failures)
		quit(1)
		return
	print("[测试][LegacyCloseupUI] 通过：独立低饱和主题、来显隐私、全局状态安全区和通话选项布局有效。")
	quit(0)
