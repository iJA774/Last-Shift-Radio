extends SceneTree
## 1920×1080 下的文本布局回归检查。
##
## 该检查使用代表性的长中文内容。它只验证文字控件的
## 可见边界和可滚动承载关系，不修改剧情、电话或广播权威状态。

const PHONE_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/phone_closeup.tscn")
const COMPUTER_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/computer_closeup.tscn")
const DOOR_WINDOW_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/door_window_closeup.tscn")
const STUDIO_OVERVIEW_SCENE: PackedScene = preload("res://scenes/studio/studio_overview.tscn")
const GLOBAL_STATUS_SCENE: PackedScene = preload("res://scenes/ui/global_status.tscn")
const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const LOADING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/loading_screen.tscn")
const ENDING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/ending_screen.tscn")
const SAVE_SLOT_PANEL_SCENE: PackedScene = preload("res://scenes/ui/save_slot_panel.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const BLACK_BANNER_STYLE: StyleBoxFlat = preload("res://resources/black_banner_style.tres")

const LONG_CALLER_TEXT: String = "来显：玛莎·克莱恩正在确认北桥附近的情况，雨声很大，信号反复中断。\n号码：555-0199-EXT-北桥东侧临时公话\n线路编号：call_story_martha_klein_north_bridge_signal_interrupted"
const LONG_DIALOGUE_TEXT: String = "沃伦先是笑了一声，又说雨把酒吧门口的台阶冲得发亮。他想点一首旧歌，顺口提起北桥那边有消防车和拖车，没人说得清是油罐车起火、桥面塌陷，还是两件事同时发生。请把这条来电当作未经证实的听闻。"
const LONG_OPTION_TEXT: String = "先照常答应点歌，并提醒听众北桥附近路况尚未得到官方确认。"
const LONG_ERROR_TEXT: String = "剧情数据校验失败：示例中的长错误说明用于确认页面能在不裁切、不越出安全区的前提下完整显示文件路径、稳定事件 ID、字段名和建议的后续处理方式。请返回主菜单后修复数据，再重新开始值班。"

var _failures: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	await _test_phone_long_text()
	await _test_global_status_long_caller()
	await _test_static_studio_views()
	await _test_application_pages()
	await _test_black_banner_structure()
	await _test_save_slot_panel()
	_finish()


func _test_phone_long_text() -> void:
	var phone: Control = PHONE_CLOSEUP_SCENE.instantiate() as Control
	_assert_true(phone != null, "电话近景必须能实例化。")
	if phone == null:
		return
	root.add_child(phone)
	await _wait_frames(4)
	var caller_label: Label = phone.get_node_or_null(NodePath("CallerLabel")) as Label
	var dialogue_label: Label = phone.get_node_or_null(NodePath("DialogueScroll/DialogueScrollContent/DialogueHintLabel")) as Label
	var dialogue_scroll: ScrollContainer = phone.get_node_or_null(NodePath("DialogueScroll")) as ScrollContainer
	var dialogue_overlay: Control = phone.get_node_or_null(NodePath("DialogueChoiceOverlay")) as Control
	var dialogue_options: VBoxContainer = phone.get_node_or_null(NodePath("DialogueChoiceOverlay/ChoiceScroll/DialogueOptions")) as VBoxContainer
	_assert_true(caller_label != null, "电话页必须提供来电人信息标签。")
	_assert_true(dialogue_label != null and dialogue_scroll != null and dialogue_overlay != null and dialogue_options != null, "电话页长台词必须可滚动，分支选项必须位于独立的屏幕中央纵向选择区。")
	if caller_label != null:
		caller_label.text = "登记名：玛莎·克莱恩    号码：555-0199"
	if dialogue_label != null:
		dialogue_label.text = LONG_DIALOGUE_TEXT
	if dialogue_options != null and dialogue_overlay != null:
		dialogue_overlay.visible = true
		for option_index: int in 2:
			var option: Button = Button.new()
			option.name = "LayoutProbeOption%d" % option_index
			option.custom_minimum_size = Vector2(0.0, 86.0)
			option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			option.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			option.text = "%d. %s" % [option_index + 1, LONG_OPTION_TEXT]
			dialogue_options.add_child(option)
	await _wait_frames(5)
	_assert_scroll_exposes_overflow(dialogue_scroll, "电话长台词")
	_assert_layout(phone, "电话近景（长文本）")
	phone.queue_free()
	await process_frame


func _test_global_status_long_caller() -> void:
	var status: Control = GLOBAL_STATUS_SCENE.instantiate() as Control
	var phone_system: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_true(status != null, "全局状态条必须能实例化。")
	if status == null:
		return
	root.add_child(status)
	await _wait_frames(3)
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(game_clock != null, "文本布局测试需要 GameClock 自动加载节点。")
	if game_clock != null:
		var bind_result: Variant = status.call(&"bind_runtime", phone_system, game_clock)
		_assert_true(bind_result is Dictionary and bool((bind_result as Dictionary).get("ok", false)), "全局状态条必须能绑定只读运行时。")
	var event_data: Dictionary = {
		"id": "layout_probe_call",
		"caller_display_name": "来自北桥东侧临时公话的长名称来电，用于确认状态条在放大字体下不会压出文字框",
		"caller_number": "555-0199-EXT-北桥东侧临时公话",
	}
	_assert_true(bool(phone_system.call(&"begin_incoming_call", event_data, 0, 60)), "文本布局测试必须能创建响铃快照。")
	await _wait_frames(5)
	_assert_layout(status, "全局状态条（长来显）")
	status.queue_free()
	await process_frame


func _test_static_studio_views() -> void:
	for scene: PackedScene in [STUDIO_OVERVIEW_SCENE, COMPUTER_CLOSEUP_SCENE, DOOR_WINDOW_CLOSEUP_SCENE]:
		var view: Control = scene.instantiate() as Control
		_assert_true(view != null, "固定视图必须能实例化。")
		if view == null:
			continue
		root.add_child(view)
		if view.name == &"ComputerCloseup":
			await _wait_frames(4)
			_assert_computer_terminal_structure(view)
			_assert_layout(view, "电脑近景")
		await _wait_frames(4)
		_assert_layout(view, "%s" % view.name)
		view.queue_free()
		await process_frame


func _assert_computer_terminal_structure(computer: Control) -> void:
	var information_view: Control = computer.get_node_or_null(NodePath("TerminalSurface/InformationView")) as Control
	_assert_true(information_view != null, "电脑近景必须保留独立 CRT 信息视图。")
	if information_view == null:
		return
	var terminal_layout: VBoxContainer = information_view.find_child("TerminalLayout", true, false) as VBoxContainer
	var tab_bar: HBoxContainer = information_view.find_child("TabBar", true, false) as HBoxContainer
	var content_scroll: ScrollContainer = information_view.find_child("ContentScroll", true, false) as ScrollContainer
	_assert_true(terminal_layout != null and tab_bar != null and content_scroll != null, "电脑终端必须提供状态、页签与可滚动内容层级。")
	if tab_bar != null:
		_assert_true(tab_bar.get_child_count() == 5, "电脑终端必须恰好显示五个固定页签。")


func _test_application_pages() -> void:
	var main: Control = MAIN_SCENE.instantiate() as Control
	_assert_true(main != null, "应用主场景必须能实例化。")
	if main != null:
		root.add_child(main)
		await _wait_frames(4)
		var shell_error_panel: PanelContainer = main.get_node_or_null(NodePath("ShellErrorPanel")) as PanelContainer
		var shell_error_label: Label = main.get_node_or_null(NodePath("ShellErrorPanel/ErrorLabel")) as Label
		_assert_true(shell_error_panel != null and shell_error_label != null, "主场景必须提供可读的提示区域。")
		if shell_error_panel != null and shell_error_label != null:
			shell_error_label.text = "提示：%s" % LONG_ERROR_TEXT
			shell_error_panel.visible = true
		await _wait_frames(4)
		_assert_layout(main, "主菜单与提示条")
		main.queue_free()
		await process_frame

	var loading: Control = LOADING_SCREEN_SCENE.instantiate() as Control
	_assert_true(loading != null, "加载页面必须能实例化。")
	if loading != null:
		root.add_child(loading)
		await _wait_frames(3)
		await _wait_frames(4)
		_assert_layout(loading, "加载页面")
		loading.queue_free()
		await process_frame

	var ending: Control = ENDING_SCREEN_SCENE.instantiate() as Control
	_assert_true(ending != null, "结束页必须能实例化。")
	if ending != null:
		root.add_child(ending)
		await _wait_frames(4)
		_assert_layout(ending, "结束页")
		ending.queue_free()
		await process_frame


func _test_save_slot_panel() -> void:
	var panel: SaveSlotPanel = SAVE_SLOT_PANEL_SCENE.instantiate() as SaveSlotPanel
	_assert_true(panel != null, "三槽存档界面必须能实例化。")
	if panel == null:
		return
	root.add_child(panel)
	await _wait_frames(3)
	panel.set_mode(SaveSlotPanel.Mode.LOAD)
	panel.set_slot_summaries([
		{"slot_id": "slot_1", "exists": true, "is_valid": true, "saved_at_utc": "2026-08-09T14:37:00Z", "display_time": "01:23", "message": "可读取"},
		{"slot_id": "slot_2", "exists": true, "is_valid": false, "message": "损坏或不兼容：存档 JSON 损坏，已拒绝读取；请返回主菜单后选择其他槽位。"},
		{"slot_id": "slot_3", "exists": false, "is_valid": false, "message": "空槽位"},
	])
	await _wait_frames(4)
	_assert_layout(panel, "三槽存档覆盖层（长错误）")
	panel.queue_free()
	await process_frame


func _test_black_banner_structure() -> void:
	_assert_true(BLACK_BANNER_STYLE.bg_color == Color(0.0, 0.0, 0.0, 1.0), "横幅共用样式必须是完全不透明的纯黑背景。")
	_assert_true(BLACK_BANNER_STYLE is StyleBoxFlat, "横幅共用样式必须是无纹理的 StyleBoxFlat。")
	_assert_true(BLACK_BANNER_STYLE.border_width_left == 0 and BLACK_BANNER_STYLE.corner_radius_top_left == 0, "横幅共用样式不得带描边或圆角装饰。")
	for scene: PackedScene in [MAIN_SCENE, preload("res://scenes/studio/game_screen.tscn") as PackedScene]:
		var view: Control = scene.instantiate() as Control
		_assert_true(view != null, "横幅场景必须可实例化。")
		if view == null:
			continue
		root.add_child(view)
		await _wait_frames(2)
		var banner_path: NodePath = NodePath("ShellErrorPanel") if view.name == &"Main" else NodePath("SystemMessagePanel")
		var banner: PanelContainer = view.get_node_or_null(banner_path) as PanelContainer
		_assert_true(banner != null and banner.get_theme_stylebox(&"panel") == BLACK_BANNER_STYLE, "%s 横幅必须复用纯黑样式资源。" % view.name)
		view.queue_free()
		await process_frame


func _assert_layout(layout_root: Control, context: String) -> void:
	var failures: PackedStringArray = []
	_collect_layout_failures(layout_root, context, failures)
	for failure: String in failures:
		_fail(failure)


func _collect_layout_failures(node: Node, context: String, failures: PackedStringArray) -> void:
	if node is Control:
		var control: Control = node as Control
		if control.is_visible_in_tree() and control.size.x > 0.0 and control.size.y > 0.0:
			if not _is_inside_scroll_container(control):
				var rect: Rect2 = control.get_global_rect()
				var viewport_size: Vector2 = Vector2(root.size)
				# 主菜单选择框按既有新 UI 构图故意压住左侧画面边缘；它不承载文字，
				# 也不属于本轮旧 UI 的安全区回归对象。
				var is_protected_menu_decoration: bool = control.name == &"SelectionFrame" and context.begins_with("主菜单")
				if not is_protected_menu_decoration and (rect.position.x < -1.0 or rect.position.y < -1.0 or rect.end.x > viewport_size.x + 1.0 or rect.end.y > viewport_size.y + 1.0):
					failures.append("%s 中控件越出 1920×1080 安全视口：%s，rect=%s。" % [context, control.get_path(), rect])
			if control is Label or control is Button:
				_assert_text_control_minimum(control, context, failures)
	for child: Node in node.get_children():
		_collect_layout_failures(child, context, failures)


func _assert_text_control_minimum(control: Control, context: String, failures: PackedStringArray) -> void:
	if _is_inside_scroll_container(control):
		return
	var minimum_size: Vector2 = control.get_combined_minimum_size()
	if minimum_size.x > control.size.x + 1.0 or minimum_size.y > control.size.y + 1.0:
		failures.append("%s 中文字控件可能裁切或越框：%s，minimum=%s，size=%s。" % [
			context,
			control.get_path(),
			minimum_size,
			control.size,
		])


func _assert_scroll_exposes_overflow(scroll: ScrollContainer, context: String) -> void:
	if scroll == null:
		_fail("%s 缺少 ScrollContainer。" % context)
		return
	var vertical_bar: VScrollBar = scroll.get_v_scroll_bar()
	_assert_true(vertical_bar != null and vertical_bar.max_value > 0.0, "%s 的超长内容必须可垂直滚动，不能被裁切。" % context)


func _is_inside_scroll_container(control: Control) -> bool:
	var current: Node = control.get_parent()
	while current != null:
		if current is ScrollContainer:
			return true
		current = current.get_parent()
	return false


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _assert_true(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failures += 1
	push_error("[测试][UITextLayout] %s" % message)


func _finish() -> void:
	if _failures > 0:
		push_error("[测试][UITextLayout] 失败：共 %d 项。" % _failures)
		quit(1)
		return
	print("[测试][UITextLayout] 通过：1920×1080 下的长中文文本均未越框，超长电话内容可滚动阅读。")
	quit(0)
