extends SceneTree

## 第四阶段应用生命周期验证。
## 覆盖页面状态、延迟收束、重新开始的对象隔离以及回主菜单后的清理。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")

var _has_failed: bool = false
var _app: Control = null
var _shift_started_count: int = 0


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
	_assert_equal(app.call(&"get_application_state_name"), "CONTENT_NOTICE", "开始值班后必须先进入内容提示。")
	_assert_true(not bool(game_clock.call(&"is_running")), "内容提示期间 GameClock 不得运行。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "内容提示期间不得创建本局运行时。")
	var notice: Control = app.get_node_or_null(NodePath("ScreenHost/ContentNotice")) as Control
	_assert_true(notice != null and notice.visible, "内容提示页必须可见。")
	if notice != null:
		var notice_text: Label = notice.get_node_or_null(NodePath("Content/NoticePanel/Margin/Layout/NoticeText")) as Label
		_assert_true(notice_text != null, "内容提示必须显示文本。")
		if notice_text != null:
			_assert_true(notice_text.text.contains("心理恐怖"), "内容提示必须正向说明心理恐怖。")
			_assert_true(notice_text.text.contains("交通事故"), "内容提示必须正向说明交通事故暗示。")
			_assert_true(notice_text.text.contains("失踪") or notice_text.text.contains("死亡"), "内容提示必须说明失踪或死亡暗示。")
			_assert_true(notice_text.text.contains("突发声音") or notice_text.text.contains("视觉刺激"), "内容提示必须说明轻度突发声音或视觉刺激。")
			_assert_true(not notice_text.text.contains("北桥") and not notice_text.text.contains("旅行车") and not notice_text.text.contains("播出"), "内容提示不得泄露地点、车辆或结尾细节。")

	app.call(&"confirm_content_notice")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "SHIFT", "确认内容提示后必须进入 SHIFT。")
	_assert_true(bool(game_clock.call(&"is_running")), "确认后 GameClock 必须开始运行。")
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
	_assert_true(bool(first_phone.call(&"answer_call", int(game_clock.call(&"get_current_game_tick")))), "第一局必须能真实接听来电。")
	_assert_true(bool(first_phone.call(&"finish_call", int(game_clock.call(&"get_current_game_tick")))), "第一局必须能真实结束来电。")
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
	var displayed_broadcast: Variant = information_view.get("_unauthorized_broadcast") if information_view != null else null
	_assert_true(
		displayed_broadcast is Dictionary and String((displayed_broadcast as Dictionary).get("fact_id", "")) == "fact_unauthorized_broadcast",
		"延时进入结束页前，电脑必须显示权威未授权播出记录。"
	)
	await create_timer(0.56).timeout
	assert_application_ending(app)

	var ending: Control = app.get_node_or_null(NodePath("ScreenHost/EndingScreen")) as Control
	if ending != null:
		var ending_load: Button = ending.get_node_or_null(NodePath("Content/EndingPanel/Margin/Layout/LoadGameButton")) as Button
		var ending_reason: Label = ending.get_node_or_null(NodePath("Content/EndingPanel/Margin/Layout/LoadDisabledReason")) as Label
		_assert_true(ending_load != null and ending_load.disabled, "结束页读取存档必须禁用。")
		_assert_true(ending_reason != null and ending_reason.visible and ending_reason.text.contains("存档系统尚未建立"), "结束页必须直接显示存档禁用原因。")

	app.call(&"restart_shift")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "SHIFT", "重新开始必须直接创建新一局 SHIFT。")
	_assert_equal(String(game_clock.call(&"get_display_time")), "01:00", "重新开始后第二局必须回到 01:00。")
	var second_engine: RefCounted = app.get("_story_engine") as RefCounted
	var second_phone: RefCounted = app.get("_phone_system") as RefCounted
	var second_screen: GameScreen = app.call(&"get_current_game_screen") as GameScreen
	_assert_true(second_engine != first_engine and second_phone != first_phone and second_screen != first_screen, "重新开始必须使用全新的 StoryEngine、PhoneSystem 和 GameScreen。")
	_assert_equal(_shift_started_count, 2, "重新开始后第二局必须只额外发送一次 shift_started。")
	var old_time_callback: Callable = Callable(first_engine, "_on_game_time_advanced")
	var old_ending_callback: Callable = Callable(first_engine, "_on_ending_time_reached")
	var old_phone_idle_callback: Callable = Callable(first_engine, "_on_phone_became_idle")
	_assert_true(not game_clock.is_connected(&"game_time_advanced", old_time_callback), "重开后旧 StoryEngine 不得继续监听 GameClock.game_time_advanced。")
	_assert_true(not game_clock.is_connected(&"ending_time_reached", old_ending_callback), "重开后旧 StoryEngine 不得继续监听 GameClock.ending_time_reached。")
	_assert_true(not first_phone.is_connected(&"call_became_idle", old_phone_idle_callback), "重开后旧 PhoneSystem 不得继续监听旧 StoryEngine 的空闲回调。")
	var first_scheduler: RefCounted = first_engine.call(&"get_scheduler") as RefCounted
	var second_scheduler: RefCounted = second_engine.call(&"get_scheduler") as RefCounted
	_assert_true(second_scheduler != first_scheduler, "重新开始必须使用全新的 EventScheduler。")
	_assert_true((second_phone.call(&"get_call_records") as Array).is_empty(), "第二局电话记录必须为空。")
	_assert_true(not bool(second_scheduler.call(&"is_ending_forced")), "第二局调度器不得遗留强制收束状态。")
	_assert_true(not bool(second_phone.call(&"is_forced_ended")), "第二局 PhoneSystem 不得遗留强制收束状态。")
	_assert_true(not bool(second_engine.call(&"is_ending_forced")), "第二局 StoryEngine 不得遗留结尾状态。")
	_assert_true((second_engine.call(&"get_unauthorized_broadcast_record") as Dictionary).is_empty(), "第二局不得遗留未授权播出记录。")

	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", int(game_clock.call(&"get_remaining_game_ticks")))), "第二局必须可推进到结束页。")
	await create_timer(0.56).timeout
	_assert_equal(app.call(&"get_application_state_name"), "ENDING", "第二局收束后必须进入 ENDING。")
	app.call(&"return_to_main_menu")
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "ENDING 必须可返回主菜单。")
	_assert_true(not bool(app.call(&"has_active_runtime")), "返回主菜单必须清理本局运行时。")
	_assert_true(not bool(game_clock.call(&"is_running")), "返回主菜单后 GameClock 必须保持不运行。")

	_finish()


func assert_application_ending(app: Control) -> void:
	_assert_equal(app.call(&"get_application_state_name"), "ENDING", "短暂应用级延时后必须进入 ENDING。")
	var ending: Control = app.get_node_or_null(NodePath("ScreenHost/EndingScreen")) as Control
	_assert_true(ending != null and ending.visible, "ENDING 状态必须显示独立结束页。")


func _on_shift_started(start_tick: int) -> void:
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
