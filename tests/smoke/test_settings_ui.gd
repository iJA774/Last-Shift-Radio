extends SceneTree

## 第八阶段设置 UI / 生命周期集成验证。
## 覆盖损坏设置恢复、已有 125% 设置的启动页、夜班覆盖层不暂停、电话仍响、
## CRT/减少闪烁分离、逐字速度、动态电脑控件字号、读档重应用与 02:00 抢占。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const SETTINGS_PATH: String = "user://phase8_settings_ui.json"
const SAVE_DIRECTORY: String = "user://phase8_settings_slots"
const FORBIDDEN_SAVE_SETTING_KEYS: PackedStringArray = [
	"settings",
	"settings_state",
	"master_volume",
	"ambience_volume",
	"ui_phone_volume",
	"window_mode",
	"text_speed",
	"font_size",
	"reduce_flashing",
	"crt_enabled",
]

var _has_failed: bool = false
var _original_settings_path: String = ""


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings_manager: Node = root.get_node_or_null(NodePath("SettingsManager")) as Node
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(settings_manager != null and game_clock != null, "设置 UI 验证需要 SettingsManager 和 GameClock 自动加载。")
	if settings_manager == null or game_clock == null:
		_finish()
		return
	_original_settings_path = String(settings_manager.call(&"get_settings_path"))
	_cleanup_test_files()
	_assert_ok(settings_manager.call(&"set_settings_path_for_verification", SETTINGS_PATH), "必须能切换到隔离设置文件。")

	# 损坏文件不能被 Main 当作正常默认加载；设置页必须保留“恢复默认”修复路径。
	var damaged_file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	_assert_true(damaged_file != null, "必须能写入隔离损坏设置夹具。")
	if damaged_file != null:
		damaged_file.store_string("{invalid settings")
		damaged_file.close()
	var damaged_load: Dictionary = settings_manager.call(&"load_settings") as Dictionary
	_assert_true(not bool(damaged_load.get("ok", false)), "损坏设置文件必须被严格拒绝。")
	var recovery_app: Control = await _create_app()
	var shell_error: PanelContainer = recovery_app.get_node_or_null(NodePath("ShellErrorPanel")) as PanelContainer
	var settings_button: Button = recovery_app.get_node_or_null(NodePath("ScreenHost/MainMenu/Content/MenuPanel/Margin/Layout/SettingsButton")) as Button
	_assert_true(shell_error != null and shell_error.visible, "设置加载失败必须在应用壳显示中文错误。")
	_assert_true(settings_button != null and not settings_button.disabled, "设置文件损坏时仍必须能打开设置页修复。")
	recovery_app.call(&"request_start_shift")
	await process_frame
	recovery_app.call(&"confirm_content_notice")
	await process_frame
	_assert_equal(String(recovery_app.call(&"get_application_state_name")), "CONTENT_NOTICE", "损坏设置时不得创建并提交 GameScreen。")
	_assert_true(not bool(recovery_app.call(&"has_active_runtime")), "损坏设置时 GameScreen 绑定失败后必须清理本局运行时。")
	recovery_app.call(&"return_to_main_menu")
	await process_frame
	settings_button = recovery_app.get_node_or_null(NodePath("ScreenHost/MainMenu/Content/MenuPanel/Margin/Layout/SettingsButton")) as Button
	if settings_button != null:
		settings_button.emit_signal(&"pressed")
	await process_frame
	var recovery_panel: SettingsPanel = recovery_app.get_node_or_null(NodePath("OverlayHost/SettingsPanel")) as SettingsPanel
	_assert_true(recovery_panel != null, "损坏设置时必须仍显示设置覆盖层。")
	if recovery_panel != null:
		var master_slider: HSlider = recovery_panel.get_node_or_null(NodePath("Center/Panel/Margin/Layout/ContentScroll/SettingsRows/MasterRow/ControlRow/MasterSlider")) as HSlider
		var reset_button: Button = recovery_panel.get_node_or_null(NodePath("Center/Panel/Margin/Layout/Actions/ResetButton")) as Button
		_assert_true(master_slider != null and not master_slider.editable, "损坏设置时普通控件必须禁用。")
		_assert_true(reset_button != null and not reset_button.disabled, "损坏设置时“恢复默认设置”必须保留可用。")
		if reset_button != null:
			reset_button.emit_signal(&"pressed")
	await process_frame
	_assert_true(bool(settings_manager.call(&"is_settings_loaded")), "恢复默认设置后必须重新得到已加载的设置文件。")
	if recovery_panel != null:
		var recovered_slider: HSlider = recovery_panel.get_node_or_null(NodePath("Center/Panel/Margin/Layout/ContentScroll/SettingsRows/MasterRow/ControlRow/MasterSlider")) as HSlider
		_assert_true(recovered_slider != null and recovered_slider.editable, "恢复默认后普通设置控件必须重新启用。")
	root.remove_child(recovery_app)
	recovery_app.queue_free()
	await process_frame

	_assert_ok(settings_manager.call(&"set_font_size", 125), "必须能设置 125% 字体。")
	_assert_ok(settings_manager.call(&"set_text_speed", 4.0), "必须能设置 4 倍逐字速度。")
	_assert_ok(settings_manager.call(&"set_reduce_flashing_enabled", true), "必须能开启减少闪烁。")
	_assert_ok(settings_manager.call(&"set_crt_enabled", false), "必须能关闭 CRT。")

	# 已持久 125% 设置后，新进程/新 Main 的主菜单必须立即重排。
	var app: Control = await _create_app()
	var menu_title: Label = app.get_node_or_null(NodePath("ScreenHost/MainMenu/Content/MenuPanel/Margin/Layout/Title")) as Label
	_assert_true(menu_title != null and menu_title.get_theme_font_size(&"font_size") == 53, "已有 125% 设置启动时主菜单标题必须立即变为 53px。")
	_assert_equal(String(app.call(&"get_window_mode_observation")), "headless", "Headless 下窗口设置必须以可观测跳过状态执行。")

	app.call(&"request_start_shift")
	await process_frame
	app.call(&"confirm_content_notice")
	await process_frame
	var screen: GameScreen = app.get("_game_screen") as GameScreen
	var phone: RefCounted = app.get("_phone_system") as RefCounted
	var story: RefCounted = app.get("_story_engine") as RefCounted
	var save_manager: SaveManager = app.get("_save_manager") as SaveManager
	_assert_true(screen != null and phone != null and story != null and save_manager != null, "夜班必须创建完整运行时。")
	if screen == null or phone == null or story == null or save_manager == null:
		_cleanup_and_finish(settings_manager)
		return
	_assert_ok(save_manager.set_save_directory(SAVE_DIRECTORY), "设置验收必须使用隔离存档目录。")
	var global_settings_before_read: Dictionary = settings_manager.call(&"get_settings_snapshot") as Dictionary
	var save_result: Dictionary = save_manager.save_slot("slot_1", app.get("_content_validation_result") as Dictionary, game_clock, story, phone, screen)
	_assert_true(bool(save_result.get("ok", false)), "空闲状态必须能写入读取设置验收槽位。")
	var saved_document: Dictionary = save_result.get("document", {}) as Dictionary
	_assert_true(not _contains_forbidden_setting_key(saved_document), "剧情存档的顶层或嵌套状态不得包含 settings/settings_state 或八个设置字段。")

	# 读档在提交 staging 前遇到不可应用的全局设置，不能转换为 SHIFT 或让
	# GameClock 保留 deferred-running 标记。读取槽位页及旧页面必须完整保留。
	var invalid_settings_file: FileAccess = FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	_assert_true(invalid_settings_file != null, "必须能写入读档原子性损坏设置夹具。")
	if invalid_settings_file != null:
		invalid_settings_file.store_string("{invalid while loading")
		invalid_settings_file.close()
	var invalid_settings_load: Dictionary = settings_manager.call(&"load_settings") as Dictionary
	_assert_true(not bool(invalid_settings_load.get("ok", false)), "读档前损坏的全局设置必须拒绝加载。")
	app.call(&"_show_main_menu")
	await process_frame
	app.call(&"request_load_game")
	await process_frame
	app.call(&"_on_load_slot_requested", "slot_1")
	await process_frame
	_assert_equal(String(app.call(&"get_application_state_name")), "LOAD_SLOTS", "设置应用失败时必须仍停留在读取槽位页。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "设置应用失败时不得遗留已恢复的 SHIFT 运行时。")
	_assert_true(not bool(game_clock.call(&"is_running")), "设置应用失败回滚后 GameClock 必须停止，不能保留 deferred restore。")
	_assert_ok(settings_manager.call(&"reset_to_defaults"), "读档失败后必须能通过恢复默认设置修复。")
	_assert_ok(settings_manager.call(&"set_font_size", 125), "修复后必须能恢复 125% 全局字体。")
	_assert_ok(settings_manager.call(&"set_text_speed", 4.0), "修复后必须能恢复全局逐字速度。")
	_assert_ok(settings_manager.call(&"set_reduce_flashing_enabled", true), "修复后必须能恢复减少闪烁。")
	_assert_ok(settings_manager.call(&"set_crt_enabled", false), "修复后必须能恢复 CRT 关闭。")
	global_settings_before_read = settings_manager.call(&"get_settings_snapshot") as Dictionary
	app.call(&"_on_load_slot_requested", "slot_1")
	await process_frame
	screen = app.get("_game_screen") as GameScreen
	phone = app.get("_phone_system") as RefCounted
	story = app.get("_story_engine") as RefCounted
	_assert_equal(String(app.call(&"get_application_state_name")), "SHIFT", "修复设置后必须能从原槽位完成读取。")
	_assert_true(screen != null and phone != null and story != null, "修复后的读取必须重新建立完整夜班运行时。")
	if screen == null or phone == null or story == null:
		_cleanup_and_finish(settings_manager)
		return

	# 动态电脑页签内容在 125% 下新建时也必须继承字号。
	_assert_ok(screen.show_view(GameScreen.VIEW_COMPUTER), "必须能进入电脑视图。")
	var computer: Control = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup")) as Control
	_assert_true(computer != null and not bool(computer.get("_is_crt_enabled")), "CRT off 必须独立隐藏电脑 CRT 层。")
	if computer != null:
		_assert_true(not (computer.get_node(NodePath("ScreenGlow")) as ColorRect).visible, "关闭 CRT 后必须隐藏 CRT 光感层。")
		_assert_true(not (computer.get_node(NodePath("ScreenCursor")) as Label).visible, "关闭 CRT 后必须隐藏 CRT 光标。")
		_assert_ok(computer.call(&"select_category", "news"), "必须能切换电脑新闻页。")
		await process_frame
		var information_view: Control = computer.get_node_or_null(NodePath("TerminalSurface/InformationView")) as Control
		var dynamic_label: Label = _find_label_with_text(information_view, "来源：")
		_assert_true(dynamic_label != null and dynamic_label.get_theme_font_size(&"font_size") == 23, "125% 下运行时创建的电脑信息卡文本必须为 23px。")

	# 读档不得恢复或覆盖设置槽内容，必须再次以当前全局快照应用视觉/文字参数。
	app.call(&"_show_main_menu")
	await process_frame
	app.call(&"request_load_game")
	await process_frame
	app.call(&"_on_load_slot_requested", "slot_1")
	await process_frame
	screen = app.get("_game_screen") as GameScreen
	phone = app.get("_phone_system") as RefCounted
	story = app.get("_story_engine") as RefCounted
	_assert_equal(String(app.call(&"get_application_state_name")), "SHIFT", "读取隔离槽位后必须恢复夜班。")
	_assert_true(screen != null and is_equal_approx(screen.get_text_speed_multiplier(), 4.0), "读取剧情槽后必须重新应用当前全局文字速度。")
	_assert_true(
		(settings_manager.call(&"get_settings_snapshot") as Dictionary) == global_settings_before_read,
		"读取剧情槽前后 SettingsManager 全局快照必须保持不变。"
	)
	if screen == null or phone == null or story == null:
		_cleanup_and_finish(settings_manager)
		return
	var restored_computer: Control = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup")) as Control
	_assert_true(restored_computer != null and not (restored_computer.get_node(NodePath("ScreenCursor")) as Label).visible, "读取后必须保持全局 CRT off。")
	_assert_true(not screen.is_motion_enabled(), "读取后必须保持全局减少闪烁。")

	# 夜班内设置覆盖层是 ACTIVE/慢速而非暂停；电话仍可在其上方真实响铃。
	(screen.get_node(NodePath("SettingsButton")) as Button).emit_signal(&"pressed")
	await process_frame
	_assert_true(screen.is_settings_panel_open(), "夜班内必须能打开设置覆盖层。")
	var work_snapshot: Dictionary = screen.get_work_state_snapshot()
	_assert_true((work_snapshot["reason_ids"] as PackedStringArray).has(GameScreen.WORK_REASON_SETTINGS_OPEN), "设置覆盖层必须作为 ACTIVE 的明确原因。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 60)), "设置覆盖层打开时故事时间必须继续推进。")
	_assert_equal(String(phone.call(&"get_state_name")), "RINGING", "设置覆盖层打开时第一通电话仍必须真实响铃。")
	var phone_closeup: Control = screen.get_node_or_null(NodePath("ViewHost/PhoneCloseup")) as Control
	_assert_true(phone_closeup != null and (phone_closeup.get("_indicator_timer") as Timer).is_stopped(), "减少闪烁必须停止电话指示灯闪烁计时器。")

	# 关闭覆盖层后电话对白以真实 StoryEngine 快照逐字展示；调速不改变线路状态。
	var shift_panel: SettingsPanel = screen.get_node_or_null(NodePath("SettingsPanel")) as SettingsPanel
	if shift_panel != null:
		shift_panel.emit_signal(&"closed")
	await process_frame
	_assert_ok(screen.show_view(GameScreen.VIEW_PHONE), "电话响铃时必须能进入电话近景。")
	_assert_true(bool(phone.call(&"answer_call", int(game_clock.call(&"get_current_game_tick")))), "必须通过 PhoneSystem 接听真实来电。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "必须进入真实对话选择状态。")
	_assert_ok(story.call(&"begin_active_call_dialogue"), "必须由 StoryEngine 提供真实对话快照。")
	await process_frame
	var text_snapshot: Dictionary = phone_closeup.call(&"get_text_presentation_snapshot") as Dictionary
	_assert_true(is_equal_approx(float(text_snapshot.get("text_speed", 0.0)), 4.0) and bool(text_snapshot.get("is_revealing", false)), "电话对白必须使用当前 4 倍逐字速度实际展示。")
	_assert_ok(settings_manager.call(&"set_text_speed", 0.25), "必须能在对话显示中即时调整逐字速度。")
	await process_frame
	_assert_equal(String(phone.call(&"get_state_name")), "DIALOGUE_CHOICE", "调整逐字速度不得改变 PhoneSystem 状态。")
	_assert_true(is_equal_approx(screen.get_text_speed_multiplier(), 0.25), "调整后 GameScreen 必须使用新的逐字速度。")

	# 02:00 必须抢占设置页、停止逐字展示并执行固定收束。
	(screen.get_node(NodePath("SettingsButton")) as Button).emit_signal(&"pressed")
	await process_frame
	_assert_true(screen.is_settings_panel_open(), "收束前必须可再次打开夜班设置覆盖层。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", int(game_clock.call(&"get_remaining_game_ticks")))), "设置覆盖层期间必须可推进到 02:00。")
	await process_frame
	_assert_true(not screen.is_settings_panel_open(), "02:00 必须立即关闭夜班设置覆盖层。")
	_assert_true(screen.is_ending() and bool(story.call(&"is_ending_forced")), "02:00 必须抢占设置并进入强制收束。")
	text_snapshot = phone_closeup.call(&"get_text_presentation_snapshot") as Dictionary
	_assert_true(not bool(text_snapshot.get("is_revealing", true)), "02:00 必须终止逐字展示 Tween。")

	root.remove_child(app)
	app.queue_free()
	await process_frame
	_cleanup_and_finish(settings_manager)


func _create_app() -> Control:
	var app: Control = MAIN_SCENE.instantiate() as Control
	root.add_child(app)
	await process_frame
	return app


func _find_label_with_text(node: Node, prefix: String) -> Label:
	if node is Label and String((node as Label).text).begins_with(prefix):
		return node as Label
	for child: Node in node.get_children():
		var found: Label = _find_label_with_text(child, prefix)
		if found != null:
			return found
	return null


func _contains_forbidden_setting_key(value: Variant) -> bool:
	if value is Dictionary:
		for raw_key: Variant in (value as Dictionary).keys():
			if typeof(raw_key) == TYPE_STRING and FORBIDDEN_SAVE_SETTING_KEYS.has(String(raw_key)):
				return true
			if _contains_forbidden_setting_key((value as Dictionary)[raw_key]):
				return true
		return false
	if value is Array:
		for item: Variant in value as Array:
			if _contains_forbidden_setting_key(item):
				return true
	return false


func _cleanup_and_finish(settings_manager: Node) -> void:
	if not _original_settings_path.is_empty():
		settings_manager.call(&"set_settings_path_for_verification", _original_settings_path)
		settings_manager.call(&"load_settings")
	_cleanup_test_files()
	_finish()


func _cleanup_test_files() -> void:
	for path: String in [SETTINGS_PATH, "%s.tmp" % SETTINGS_PATH, "%s.bak" % SETTINGS_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	for suffix: String in ["slot_1.json", "slot_1.tmp", "slot_1.bak", "slot_2.json", "slot_3.json"]:
		var slot_path: String = "%s/%s" % [SAVE_DIRECTORY, suffix]
		if FileAccess.file_exists(slot_path):
			DirAccess.remove_absolute(slot_path)


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][SettingsUI] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _finish() -> void:
	if _has_failed:
		print("[测试][SettingsUI] 失败。")
		quit(1)
		return
	print("[测试][SettingsUI] 通过：设置恢复、即时应用、夜班覆盖层、逐字显示、读档与 02:00 抢占均符合契约。")
	quit(0)
