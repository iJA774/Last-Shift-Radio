extends SceneTree

## 应用壳集成验证：Main 只能编排运行时、完整测试剧情数据和 02:00 收束。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(game_clock != null, "测试运行时必须存在 GameClock 自动加载节点。")
	if game_clock == null:
		_finish()
		return
	_assert_true(not bool(game_clock.call(&"is_running")), "损坏数据夹具启动前 GameClock 必须尚未运行。")
	var invalid_app: Control = MAIN_SCENE.instantiate()
	invalid_app.set("content_source_path", "res://tests/fixtures/content/malformed_syntax.json")
	root.add_child(invalid_app)
	await process_frame
	_assert_equal(invalid_app.call(&"get_application_state_name"), "MAIN_MENU", "启动时必须先停在主菜单。")
	invalid_app.call(&"request_start_shift")
	await process_frame
	invalid_app.call(&"confirm_content_notice")
	await process_frame
	_assert_true(not bool(invalid_app.get("_is_shift_started")), "损坏 JSON 必须阻止 Main 启动夜班。")
	_assert_true(not bool(game_clock.call(&"is_running")), "损坏 JSON 后不得启动 GameClock。")
	var invalid_notice: Control = invalid_app.get_node_or_null(NodePath("ScreenHost/ContentNotice")) as Control
	var startup_error_label: Label = null
	if invalid_notice != null:
		startup_error_label = invalid_notice.get_node("Content/NoticePanel/Margin/Layout/ErrorPanel/ErrorLabel") as Label
	_assert_true(
		startup_error_label != null
			and startup_error_label.text.contains("测试剧情数据")
			and startup_error_label.text.contains("JSON 解析失败"),
		"损坏 JSON 必须在 GameScreen 显示可定位的中文错误。"
	)
	root.remove_child(invalid_app)
	invalid_app.queue_free()
	await process_frame

	var app: Control = MAIN_SCENE.instantiate()
	root.add_child(app)
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "有效数据时启动也必须先进入主菜单。")
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"confirm_content_notice")
	await process_frame

	var phone_system: RefCounted = app.get("_phone_system") as RefCounted
	var story_engine: RefCounted = app.get("_story_engine") as RefCounted
	var game_screen: GameScreen = app.get("_game_screen") as GameScreen
	_assert_true(phone_system != null, "Main 必须创建 PhoneSystem。")
	_assert_true(story_engine != null, "Main 必须创建 StoryEngine。")
	_assert_true(game_screen != null, "Main 必须注入预制的 GameScreen。")
	_assert_true(bool(app.get("_is_shift_started")), "有效测试剧情数据通过校验后必须启动夜班。")
	var validation_result: Variant = app.get("_content_validation_result")
	_assert_true(
		validation_result is Dictionary and bool((validation_result as Dictionary).get("ok", false)),
		"Main 必须保留成功的测试剧情数据校验结果。"
	)
	if validation_result is Dictionary:
		var events: Variant = (validation_result as Dictionary).get("events")
		_assert_true(events is Array and (events as Array).size() == 11, "测试剧情的 11 通来电必须完整交给 StoryEngine。")
	_assert_main_has_no_demo_event_builder()
	if phone_system == null or story_engine == null or game_screen == null:
		_finish()
		return

	_assert_equal(String(phone_system.call(&"get_state_name")), "IDLE", "01:00 开场不应提前响铃。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 60)), "时钟必须能推进到 01:01 首通来电。")
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "首条 JSON 剧情事件必须通过 StoryEngine 进入响铃。")
	var phone_closeup: Control = game_screen.get_node("ViewHost/PhoneCloseup") as Control
	_assert_true(phone_closeup != null, "GameScreen 必须持有电话近景场景。")
	if phone_closeup != null:
		phone_closeup.emit_signal(&"answer_requested")
		_assert_equal(String(phone_system.call(&"get_state_name")), "CONNECTED", "电话近景接听意图必须由 GameScreen 转交 PhoneSystem。")
		phone_closeup.emit_signal(&"finish_call_requested")
		_assert_equal(String(phone_system.call(&"get_state_name")), "IDLE", "第一通电话结束后若无同窗事件，线路必须恢复空闲。")

	var records_result: Variant = phone_system.call(&"get_call_records")
	_assert_true(records_result is Array and (records_result as Array).size() == 1, "电话状态机必须只为已结束的第一通电话生成记录。")
	if records_result is Array and not (records_result as Array).is_empty():
		var first_record: Dictionary = (records_result as Array)[0] as Dictionary
		_assert_equal(String(first_record.get("event_id", "")), "call_01_warren", "记录必须来自 JSON 稳定事件 ID。")
		_assert_equal(String(first_record.get("outcome", "")), "answered", "正常结束的记录结果必须为 answered。")

	var remaining_ticks: Variant = game_clock.call(&"get_remaining_game_ticks")
	_assert_true(typeof(remaining_ticks) == TYPE_INT, "GameClock 必须返回整数剩余 tick。")
	_assert_true(
		bool(game_clock.call(&"advance_ticks_for_verification", int(remaining_ticks))),
		"验证接口必须能把运行中的夜班推进到 02:00。"
	)
	await process_frame
	_assert_true(bool(story_engine.call(&"is_ending_forced")), "02:00 必须由 StoryEngine 强制收束。")
	_assert_true(bool(phone_system.call(&"is_forced_ended")), "02:00 必须由 StoryEngine 终止 PhoneSystem。")
	_assert_equal(game_screen.get_current_view_id(), "computer", "收束后 GameScreen 必须切换到电脑未授权播出记录。")
	_assert_true(game_screen.is_ending(), "收束后 GameScreen 必须锁定非电脑视图。")
	_assert_true(not game_screen.is_view_transitioning(), "02:00 收束不得遗留未完成的视图过渡。")
	var broadcast_record: Variant = story_engine.call(&"get_unauthorized_broadcast_record")
	_assert_true(broadcast_record is Dictionary and not (broadcast_record as Dictionary).is_empty(), "收束后必须有权威未授权播出记录。")
	if broadcast_record is Dictionary:
		var record: Dictionary = broadcast_record as Dictionary
		_assert_equal(String(record.get("fact_id", "")), "fact_unauthorized_broadcast", "播出记录必须使用稳定事实 ID。")
		_assert_equal(int(record.get("time_tick", -1)), 3_600, "播出记录必须精确标记 02:00 tick。")
		_assert_equal(String(record.get("source", "")), "Studio A", "播出记录来源必须为 Studio A。")
	var call_log_view: Control = game_screen.get_node("ViewHost/ComputerCloseup/TerminalSurface/CallLogView") as Control
	var displayed_broadcast: Variant = call_log_view.get("_unauthorized_broadcast") if call_log_view != null else null
	_assert_true(
		displayed_broadcast is Dictionary and String((displayed_broadcast as Dictionary).get("fact_id", "")) == "fact_unauthorized_broadcast",
		"电脑页必须展示 StoryEngine 交给 GameScreen 的未授权播出记录。"
	)
	_finish()


func _assert_main_has_no_demo_event_builder() -> void:
	var file: FileAccess = FileAccess.open("res://scripts/app/main.gd", FileAccess.READ)
	_assert_true(file != null, "必须能够读取 Main 源码以检查瘦身边界。")
	if file == null:
		return
	var source: String = file.get_as_text()
	file.close()
	_assert_true(not source.contains("_build_demo_events"), "Main 不得保留硬编码演示事件构造器。")
	_assert_true(not source.contains("call_demo_intro"), "Main 不得保留硬编码演示事件 ID。")


func _finish() -> void:
	if _has_failed:
		print("[测试][MainIntegration] 失败。")
		quit(1)
		return
	print("[测试][MainIntegration] 通过：瘦应用壳、JSON 测试剧情启动、电话意图与 02:00 收束已连通。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][MainIntegration] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
