extends SceneTree

## 统一工作状态与动态时间倍率的 UI 路由验证。
##
## GameScreen 不保存电话或剧情真相；它只将电话、待播广播与当前固定视图
## 合并为 IDLE / ACTIVE 派生状态，并调用 GameClock 的公开倍率接口。

const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var clock = GAME_CLOCK_SCRIPT.new()
	var phone = PHONE_SYSTEM_SCRIPT.new()
	var story_engine = STORY_ENGINE_SCRIPT.new()
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	var story_content: Dictionary = _load_story_content()
	_assert_true(not story_content.is_empty(), "必须能读取测试剧情内容。")
	_assert_ok(story_engine.configure_test_night_story(story_content), "必须能配置待播广播状态所需剧情。")
	_assert_ok(story_engine.set_phone_system(phone), "StoryEngine 必须能绑定测试电话状态机。")
	root.add_child(clock)
	root.add_child(screen)
	await process_frame

	var bind_result: Dictionary = screen.bind_runtime(story_engine, phone, clock)
	_assert_true(bool(bind_result.get("ok", false)), "GameScreen 必须能绑定统一工作状态所需运行时。")
	_assert_work_state(screen, GameScreen.WorkState.IDLE, "工作室总览且没有任务时必须处于 IDLE。")
	_assert_rate(clock, GameClockService.TimeRate.FAST, "工作室总览且电话空闲时必须使用 FAST 倍率。")
	_assert_status_work_state_contract(screen, "IDLE", false, "IDLE 快照必须继续传给 HUD，即使 HUD 不再显示工作状态文字。")

	_assert_ok(screen.show_view(GameScreen.VIEW_COMPUTER), "必须能切换到电脑近景。")
	_assert_work_state(screen, GameScreen.WorkState.ACTIVE, "查看电脑必须进入 ACTIVE。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "电脑近景必须使用 SLOW 倍率。")
	_assert_status_work_state_contract(screen, "ACTIVE", true, "ACTIVE 快照必须继续传给 HUD，以维持 show_work_state 合同。")
	_assert_ok(screen.show_view(GameScreen.VIEW_STUDIO), "必须能从电脑返回工作室总览。")
	_assert_work_state(screen, GameScreen.WorkState.IDLE, "离开电脑且无任务后必须恢复 IDLE。")
	_assert_rate(clock, GameClockService.TimeRate.FAST, "离开电脑且电话空闲后必须恢复 FAST 倍率。")

	_assert_true(phone.begin_incoming_call(_make_call_data("call_time_rate_ringing"), 0, 60), "测试来电必须进入响铃。")
	_assert_equal(phone.get_state_name(), "RINGING", "测试来电必须处于 Ringing。")
	_assert_work_state(screen, GameScreen.WorkState.ACTIVE, "电话开始响铃即属于非空闲状态。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "响铃期间必须与现实 1:1 推进。")

	_assert_true(phone.answer_call(0), "测试来电必须可接听。")
	_assert_equal(phone.get_state_name(), "CONNECTED", "接听后必须处于 Connected。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "已接通电话必须使用 SLOW 倍率。")
	_assert_true(phone.enter_dialogue_choice(), "已接通电话必须能进入对话选择。")
	_assert_equal(phone.get_state_name(), "DIALOGUE_CHOICE", "进入选择后必须处于 DialogueChoice。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "对话选择期间必须保持 SLOW 倍率。")
	_assert_true(phone.exit_dialogue_choice(), "对话选择必须能恢复通话。")
	_assert_true(phone.finish_call(0), "测试通话必须能正常结束。")
	_assert_equal(phone.get_state_name(), "IDLE", "通话结束后电话必须回到 Idle。")
	_assert_work_state(screen, GameScreen.WorkState.IDLE, "通话结束且没有其他任务时必须恢复 IDLE。")
	_assert_rate(clock, GameClockService.TimeRate.FAST, "电话回到 Idle 且不看电脑后必须恢复 FAST 倍率。")

	_assert_true(phone.begin_incoming_call(_make_call_data("call_time_rate_computer"), 0, 60), "第二通测试来电必须进入响铃。")
	_assert_ok(screen.show_view(GameScreen.VIEW_COMPUTER), "响铃时必须仍可切换到电脑近景。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "电脑近景与响铃同时成立时，电脑条件必须使时钟变慢。")
	_assert_ok(screen.show_view(GameScreen.VIEW_STUDIO), "必须能离开响铃期间的电脑近景。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "离开电脑后，单独响铃仍属于 ACTIVE 并保持现实 1:1。")
	_assert_true(phone.answer_call(0), "第二通测试来电必须可接听。")
	_assert_true(phone.finish_call(0), "第二通测试来电必须可结束。")

	_assert_ok(story_engine.advance_to_game_tick(12 * GameClockService.GAME_TICKS_PER_MINUTE), "必须能推进到米勒短信解锁时刻。")
	_drain_story_calls(phone)
	_assert_equal(phone.get_state_name(), "IDLE", "清理同窗测试来电后电话必须空闲。")
	_assert_work_state(screen, GameScreen.WorkState.ACTIVE, "存在可发送广播稿时，即使电话空闲也必须保持 ACTIVE。")
	_assert_rate(clock, GameClockService.TimeRate.SLOW, "待播广播未处理时必须与现实 1:1 推进。")
	var active_snapshot: Dictionary = screen.get_work_state_snapshot()
	_assert_true(
		(active_snapshot["reason_ids"] as PackedStringArray).has(GameScreen.WORK_REASON_BROADCAST_PENDING),
		"ACTIVE 快照必须公开稳定的 broadcast_pending 原因。"
	)
	_assert_ok(
		story_engine.send_player_broadcast("broadcast_bridge_structural_closure"),
		"发送唯一可用的结构封桥稿后必须清除待播状态。"
	)
	_assert_work_state(screen, GameScreen.WorkState.IDLE, "待播稿件处理完且未看电脑时必须恢复 IDLE。")
	_assert_rate(clock, GameClockService.TimeRate.FAST, "所有非空闲原因清除后必须恢复快速倍率。")

	screen.release_runtime()
	root.remove_child(screen)
	screen.queue_free()
	root.remove_child(clock)
	clock.free()
	await process_frame
	_finish()


func _make_call_data(event_id: String) -> Dictionary:
	return {
		"id": event_id,
		"caller_display_name": "时间倍率测试来电者",
		"caller_number": "555-0198",
	}


func _load_story_content() -> Dictionary:
	var file: FileAccess = FileAccess.open("res://data/story/test_night_story.json", FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return {}
	return parsed as Dictionary


func _drain_story_calls(phone: RefCounted) -> void:
	for _attempt: int in range(8):
		var state_name: String = String(phone.call(&"get_state_name"))
		if state_name == "IDLE":
			return
		if state_name != "RINGING":
			_assert_true(false, "清理剧情来电时遇到意外电话状态：%s。" % state_name)
			return
		_assert_true(bool(phone.call(&"answer_call", 12 * GameClockService.GAME_TICKS_PER_MINUTE)), "同窗剧情来电必须可接听。")
		_assert_true(bool(phone.call(&"finish_call", 12 * GameClockService.GAME_TICKS_PER_MINUTE)), "同窗剧情来电必须可结束。")
	_assert_true(false, "同窗剧情来电超过安全清理上限。")


func _assert_rate(clock: Node, expected_rate: GameClockService.TimeRate, message: String) -> void:
	_assert_equal(clock.get_time_rate_mode(), expected_rate, message)


func _assert_work_state(screen: GameScreen, expected_state: GameScreen.WorkState, message: String) -> void:
	_assert_equal(screen.get_work_state(), expected_state, message)


func _assert_status_work_state_contract(screen: GameScreen, expected_state_name: String, expected_uses_realtime_rate: bool, message: String) -> void:
	var global_status: GlobalStatus = screen.get_node("GlobalStatus") as GlobalStatus
	_assert_true(global_status != null, "%s（缺少 GlobalStatus）。" % message)
	if global_status == null:
		return
	var snapshot: Dictionary = global_status.get_last_work_state_snapshot()
	_assert_equal(snapshot.get("state_name"), expected_state_name, "%s state_name 不匹配。" % message)
	_assert_equal(snapshot.get("uses_realtime_rate"), expected_uses_realtime_rate, "%s uses_realtime_rate 不匹配。" % message)


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _finish() -> void:
	if _has_failed:
		print("[测试][TimeRateRouting] 失败。")
		quit(1)
		return
	print("[测试][TimeRateRouting] 通过：统一工作状态、现实 1:1 倍率与 HUD 内部快照合同保持同步。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][TimeRateRouting] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
