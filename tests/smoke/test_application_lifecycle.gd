extends SceneTree

## 第四阶段应用生命周期验证。
## 覆盖页面状态、延迟收束、重新开始的对象隔离以及回主菜单后的清理。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")

var _has_failed: bool = false
var _app: Control = null
var _shift_started_count: int = 0
var _main_menu_exit_intent_count: int = 0
var _observe_primary_shift_started: bool = true


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(game_clock != null, "测试运行时必须存在 GameClock 自动加载节点。")
	if game_clock == null:
		_finish()
		return
	var app: Control = MAIN_SCENE.instantiate() as Control
	_app = app
	# 需要比一帧的内容/设置重排开销更长，才能稳定验证 02:00 的电脑余韵。
	app.set("ending_transition_delay_seconds", 0.50)
	game_clock.connect(&"shift_started", Callable(self, "_on_shift_started"))
	root.add_child(app)
	await process_frame

	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "启动后必须进入主菜单。")
	_assert_true(not bool(game_clock.call(&"is_running")), "主菜单期间 GameClock 不得运行。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "主菜单不得创建本局 StoryEngine、PhoneSystem 或 GameScreen。")
	var main_menu: Control = app.get_node_or_null(NodePath("ScreenHost/MainMenu")) as Control
	_assert_true(main_menu != null and main_menu.visible, "主菜单必须可见。")
	if main_menu != null:
		var load_button: Button = main_menu.get_node_or_null(NodePath("Content/MenuPanel/Margin/Layout/LoadGameButton")) as Button
		var settings_button: Button = main_menu.get_node_or_null(NodePath("Content/MenuPanel/Margin/Layout/SettingsButton")) as Button
		var load_reason: Label = main_menu.get_node_or_null(NodePath("Content/MenuPanel/Margin/Layout/LoadDisabledReason")) as Label
		var settings_reason: Label = main_menu.get_node_or_null(NodePath("Content/MenuPanel/Margin/Layout/SettingsDisabledReason")) as Label
		_assert_true(load_button != null and not load_button.disabled, "第七阶段后主菜单读取存档必须可用。")
		_assert_true(settings_button != null and not settings_button.disabled, "第八阶段后主菜单设置必须可用。")
		_assert_true(load_reason != null and load_reason.visible and load_reason.text.contains("本地三槽"), "主菜单必须直接说明本地三槽读取入口。")
		_assert_true(settings_reason != null and not settings_reason.visible, "设置已建立后不得遗留过时的禁用原因。")

	app.call(&"request_start_shift")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "LOADING", "开始值班后必须先进入加载页面。")
	_assert_true(not bool(game_clock.call(&"is_running")), "加载页面期间 GameClock 不得运行。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "加载页面期间不得创建本局运行时。")
	var loading: Control = app.get_node_or_null(NodePath("ScreenHost/LoadingScreen")) as Control
	_assert_true(loading != null and loading.visible, "加载页面必须可见。")
	if loading != null:
		var timing: Dictionary = loading.call(&"get_timing_snapshot") as Dictionary
		_assert_equal(float(timing.get("fade_in_seconds", 0.0)), 0.5, "加载页面必须使用 0.5 秒渐入。")
		_assert_equal(float(timing.get("hold_seconds", 0.0)), 2.0, "加载页面必须完整显示 2 秒。")
		_assert_equal(float(timing.get("fade_out_seconds", 0.0)), 0.5, "加载页面必须使用 0.5 秒渐出。")
		var loading_art: TextureRect = loading.get_node_or_null(NodePath("LoadingArt")) as TextureRect
		_assert_true(loading_art != null and loading_art.texture != null and loading_art.texture.resource_path == "res://UI美术/加载页面.png", "加载页面必须使用指定美术资源。")

	app.call(&"finish_loading_for_verification")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "SHIFT", "加载页渐出完成后必须进入 SHIFT。")
	_assert_true(bool(game_clock.call(&"is_running")), "加载页渐出完成后 GameClock 必须开始运行。")
	_assert_equal(String(game_clock.call(&"get_display_time")), "01:00", "每局夜班必须从 01:00 开始。")
	var first_engine: RefCounted = app.get("_story_engine") as RefCounted
	var first_phone: RefCounted = app.get("_phone_system") as RefCounted
	var first_screen: GameScreen = app.call(&"get_current_game_screen") as GameScreen
	_assert_true(first_engine != null and first_phone != null and first_screen != null, "确认后必须创建并注入新的本局运行时。")
	_assert_equal(_shift_started_count, 1, "第一局完整绑定后必须只发送一次 shift_started。")
	if first_engine == null or first_phone == null or first_screen == null:
		_finish()
		return
	_assert_equal(first_screen.get_current_view_id(), "studio", "新局 GameScreen 必须可操作并从工作室总览开始。")
	_assert_equal(String(first_phone.call(&"get_state_name")), "IDLE", "01:00 开场前一分钟不应提前触发来电。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 60)), "第一局必须能推进到 01:01 的首通来电窗口。")
	_assert_equal(String(first_phone.call(&"get_state_name")), "RINGING", "已校验的沃伦来电必须由 StoryEngine 真实触发。")
	first_screen.call(&"_on_answer_requested")
	await process_frame
	_assert_equal(String(first_phone.call(&"get_state_name")), "DIALOGUE_CHOICE", "接通成功后必须立即进入首段权威对白。")
	var phone_view: Control = first_screen.get_node_or_null(NodePath("ViewHost/PhoneCloseup")) as Control
	var dialogue_overlay: Control = phone_view.get_node_or_null(NodePath("DialogueChoiceOverlay")) as Control if phone_view != null else null
	var dialogue_scroll: ScrollContainer = phone_view.get_node_or_null(NodePath("DialogueScroll")) as ScrollContainer if phone_view != null else null
	_assert_true(dialogue_overlay != null and not dialogue_overlay.visible, "接通后必须先展示发言，不能立刻显示回应选项。")
	_assert_true(dialogue_scroll != null and dialogue_scroll.visible, "接通后的首段发言必须可见。")
	first_screen.call(&"_on_dialogue_choice_requested")
	await process_frame
	_assert_true(dialogue_overlay != null and dialogue_overlay.visible, "第一次继续对话就应显示回应选项。")
	_assert_true(dialogue_scroll != null and dialogue_scroll.visible, "回应选项出现后对方发言仍必须可读。")
	first_screen.show_system_error("StoryEngine、PhoneSystem、Dictionary 与 option_id 都不应显示给玩家。")
	var system_message: Label = first_screen.get_node_or_null(NodePath("SystemMessagePanel/SystemMessage")) as Label
	_assert_player_text_is_natural(system_message, "运行时提示必须过滤开发术语。")
	first_screen.call(&"_on_hang_up_requested")
	await process_frame
	_assert_equal(String(first_phone.call(&"get_state_name")), "IDLE", "正常挂断必须保持可操作。")
	var first_records: Variant = first_phone.call(&"get_call_records")
	_assert_true(first_records is Array and (first_records as Array).size() == 1, "第一局必须由 PhoneSystem 产生真实电话记录。")

	var remaining_ticks: int = int(game_clock.call(&"get_remaining_game_ticks"))
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", remaining_ticks)), "第一局必须可推进到 02:00。")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "SHIFT", "收束余韵期间应用仍应保持 SHIFT。")
	_assert_equal(first_screen.get_current_view_id(), "computer", "02:00 后必须先切到 GameScreen 电脑页。")
	var broadcast_record: Variant = first_engine.call(&"get_unauthorized_broadcast_record")
	_assert_true(broadcast_record is Dictionary and not (broadcast_record as Dictionary).is_empty(), "02:00 后 StoryEngine 必须拥有权威未授权播出记录。")
	var information_view: Control = first_screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup/TerminalSurface/InformationView")) as Control
	var displayed_broadcast: Variant = information_view.get("_ending_record") if information_view != null else null
	_assert_true(
		displayed_broadcast is Dictionary and String((displayed_broadcast as Dictionary).get("fact_id", "")) == "fact_unauthorized_broadcast",
		"延时进入结束页前，电脑必须显示权威未授权播出记录。"
	)
	_assert_player_text_is_natural(system_message, "02:00 收束提示不得暴露内部实现。")
	await create_timer(0.56).timeout
	assert_application_ending(app)

	var ending: Control = app.get_node_or_null(NodePath("ScreenHost/EndingScreen")) as Control
	if ending != null:
		var ending_hotspot: Button = ending.get_node_or_null(NodePath("ReturnToMenuHotspot")) as Button
		_assert_true(ending_hotspot != null, "结束页必须保留素材内返回主界面热点。")
		_assert_true(ending.get_node_or_null(NodePath("ActionsPanel")) == null, "结束页不得保留额外操作面板。")
		var success_art: Dictionary = ending.call(&"get_ending_art_snapshot") as Dictionary
		_assert_equal(String(success_art.get("outcome", "")), "success", "02:00 固定收束必须明确映射值夜成功素材。")
		_assert_equal(String(success_art.get("resource_path", "")), "res://UI美术/值夜成功.png", "02:00 结束页必须使用值夜成功.png。")
		var failure_result: Dictionary = ending.call(&"set_result", EndingScreen.EndResult.FAILURE) as Dictionary
		_assert_true(bool(failure_result.get("ok", false)), "结束页必须支持已声明的 failure 结果素材呈现。")
		var failure_art: Dictionary = ending.call(&"get_ending_art_snapshot") as Dictionary
		_assert_equal(String(failure_art.get("resource_path", "")), "res://UI美术/值夜失败.png", "failure 结果必须选择值夜失败.png。")
		var unknown_result: Dictionary = ending.call(&"set_result", 99) as Dictionary
		_assert_true(not bool(unknown_result.get("ok", true)) and String(unknown_result.get("error_code", "")) == "unknown_end_result", "结束页必须拒绝未知结果值。")
		ending.call(&"set_result", EndingScreen.EndResult.SUCCESS)

	app.call(&"return_to_main_menu")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "ENDING 必须可返回主菜单。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "返回主菜单必须清理本局运行时。")
	_assert_true(not bool(game_clock.call(&"is_running")), "返回主菜单后 GameClock 必须保持不运行。")
	_observe_primary_shift_started = false
	await _test_shift_return_to_main_menu(game_clock)

	_finish()


func _test_shift_return_to_main_menu(game_clock: Node) -> void:
	var return_app: Control = MAIN_SCENE.instantiate() as Control
	_assert_true(return_app != null, "夜班返回验证必须能实例化独立 Main。")
	if return_app == null:
		return
	root.add_child(return_app)
	await process_frame
	return_app.call(&"request_start_shift")
	await process_frame
	return_app.call(&"finish_loading_for_verification")
	await process_frame
	var return_screen: GameScreen = return_app.call(&"get_current_game_screen") as GameScreen
	_assert_true(return_screen != null and String(return_app.call(&"get_application_state_name")) == "SHIFT", "返回验证必须先进入正常夜班。")
	if return_screen == null:
		return_app.queue_free()
		return
	return_screen.toggle_control_bar()
	var control_bar: Control = return_screen.get_node_or_null(NodePath("ShiftControlBar")) as Control
	var exit_button: Button = control_bar.get_node_or_null(NodePath("Backdrop/MenuArt/ActionHotspots/ExitButton")) as Button if control_bar != null else null
	_assert_true(exit_button != null, "夜班 ESC 菜单必须保留返回主界面热点。")
	if exit_button != null:
		exit_button.emit_signal(&"pressed")
	await process_frame
	_assert_equal(return_app.call(&"get_application_state_name"), "LOADING", "夜班退出必须先进入 LOADING，而非直接退出程序。")
	_assert_true(not bool(return_app.call(&"has_active_runtime")), "夜班返回加载期间必须销毁本局运行时。")
	_assert_true(not bool(game_clock.call(&"is_running")), "夜班返回加载期间 GameClock 必须停止。")
	return_app.call(&"finish_loading_for_verification")
	await process_frame
	_assert_equal(return_app.call(&"get_application_state_name"), "MAIN_MENU", "夜班返回加载完成后必须到达 MAIN_MENU。")
	_assert_true(not bool(return_app.call(&"has_active_runtime")) and not bool(game_clock.call(&"is_running")), "夜班返回主菜单后不得遗留运行时或时钟。")
	var main_menu: Control = return_app.get_node_or_null(NodePath("ScreenHost/MainMenu")) as Control
	var main_exit: Button = main_menu.get_node_or_null(NodePath("Content/MenuPanel/Margin/Layout/ExitButton")) as Button if main_menu != null else null
	var quit_callback: Callable = Callable(return_app, "_on_exit_requested")
	if main_menu != null and main_menu.is_connected(&"exit_requested", quit_callback):
		main_menu.disconnect(&"exit_requested", quit_callback)
		main_menu.connect(&"exit_requested", Callable(self, "_on_main_menu_exit_intent"))
	_assert_true(main_exit != null, "主菜单必须保留真正退出程序的独立按钮。")
	if main_exit != null:
		main_exit.emit_signal(&"pressed")
		# bong_001.wav 约 0.132 秒，主菜单退出会保留听觉反馈后再提交退出意图。
		await create_timer(0.16).timeout
	_assert_equal(_main_menu_exit_intent_count, 1, "替换测试接收者后，主菜单退出按钮必须仍发出退出意图。")
	root.remove_child(return_app)
	return_app.queue_free()


func _on_main_menu_exit_intent() -> void:
	_main_menu_exit_intent_count += 1


func assert_application_ending(app: Control) -> void:
	_assert_equal(app.call(&"get_application_state_name"), "ENDING", "短暂应用级延时后必须进入 ENDING。")
	var ending: Control = app.get_node_or_null(NodePath("ScreenHost/EndingScreen")) as Control
	_assert_true(ending != null and ending.visible, "ENDING 状态必须显示独立结束页。")


func _on_shift_started(start_tick: int) -> void:
	if not _observe_primary_shift_started:
		return
	_shift_started_count += 1
	_assert_equal(start_tick, 0, "shift_started 必须从 01:00 的 tick 0 发出。")
	if _app == null:
		_assert_true(false, "shift_started 发出时应用实例必须已存在。")
		return
	var engine: RefCounted = _app.get("_story_engine") as RefCounted
	var phone: RefCounted = _app.get("_phone_system") as RefCounted
	var screen: GameScreen = _app.call(&"get_current_game_screen") as GameScreen
	var is_bound: bool = screen != null and screen.get("_story_engine") == engine and screen.get("_phone_system") == phone
	_assert_true(
		_app.call(&"get_application_state_name") == "SHIFT"
			and bool(_app.get("_is_shift_started"))
			and engine != null
			and phone != null
			and screen != null
			and is_bound,
		"shift_started 发出时 Main、StoryEngine、PhoneSystem 与已绑定 GameScreen 必须完整可用。"
	)


func _finish() -> void:
	if _has_failed:
		print("[测试][ApplicationLifecycle] 失败。")
		quit(1)
		return
	print("[测试][ApplicationLifecycle] 通过：页面状态、延迟收束、重开隔离和运行时清理均符合契约。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][ApplicationLifecycle] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_player_text_is_natural(label: Label, context: String) -> void:
	_assert_true(label != null, "%s 缺少提示文本。" % context)
	if label == null:
		return
	var forbidden_terms: PackedStringArray = ["预制对话", "StoryEngine", "PhoneSystem", "System", "Dictionary", "option_id", "稳定 ID", "电话状态", "工作状态", "本轮对话结束"]
	for term: String in forbidden_terms:
		_assert_true(not label.text.contains(term), "%s 检测到禁词：%s。" % [context, term])
