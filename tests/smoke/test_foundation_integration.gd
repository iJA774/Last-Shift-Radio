extends SceneTree

## 纯系统端到端验证：实际连接 GameClock、StoryEngine 与 PhoneSystem，
## 不经由任何场景或 UI 伪造电话状态、记录或 02:00 收束。

const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _has_failed: bool = false
var _ending_signal_count: int = 0


func _init() -> void:
	_test_event_answer_hang_up_generates_record()
	_test_mainline_call_queues_and_rings_after_idle()
	_test_0200_forces_ringing_call()
	_test_0200_forces_connected_call()
	_test_0200_forces_dialogue_choice_call()

	if _has_failed:
		print("[测试][FoundationIntegration] 失败。")
		quit(1)
		return
	print("[测试][FoundationIntegration] 通过：电话、调度、时钟与 02:00 收束端到端契约成立。")
	quit(0)


func _test_event_answer_hang_up_generates_record() -> void:
	var sut: Dictionary = _create_systems()
	var clock = sut["clock"]
	var engine = sut["engine"]
	var phone = sut["phone"]

	_assert_ok(
		engine.schedule_event(_make_call_event("call_e2e_hang_up", "normal", 1, 4, "expire")),
		"端到端挂断测试应能注册来电。"
	)
	clock.start_shift()
	_assert_true(clock.advance_ticks_for_verification(60), "时钟应能推进到第一通电话触发 tick。")
	_assert_equal(phone.get_state_name(), "RINGING", "事件触发后电话必须真实进入 Ringing。")
	_assert_equal(phone.get_active_event_id(), "call_e2e_hang_up", "响铃线路必须来自调度事件 ID。")
	_assert_true(phone.answer_call(clock.get_current_game_tick()), "Ringing 状态必须可由玩家意图接听。")
	_assert_true(phone.hang_up(clock.get_current_game_tick() + 9), "Connected 状态必须可由玩家意图主动挂断。")

	var records: Array[Dictionary] = phone.get_call_records()
	_assert_equal(records.size(), 1, "接听后挂断必须只生成一条电话系统记录。")
	_assert_record(records[0], "call_e2e_hang_up", "hung_up", 60, 9, "接听后挂断记录字段不正确。")
	_cleanup_clock(clock)


func _test_mainline_call_queues_and_rings_after_idle() -> void:
	var sut: Dictionary = _create_systems()
	var clock = sut["clock"]
	var engine = sut["engine"]
	var phone = sut["phone"]

	_assert_ok(
		engine.schedule_event(_make_call_event("call_e2e_main_active", "main", 1, 6, "queue")),
		"第一条主线来电应能注册。"
	)
	_assert_ok(
		engine.schedule_event(_make_call_event("call_e2e_main_queued", "main", 1, 6, "queue")),
		"第二条主线来电应能注册。"
	)
	clock.start_shift()
	_assert_true(clock.advance_ticks_for_verification(60), "时钟应能推进到同窗主线来电。")
	_assert_equal(phone.get_active_event_id(), "call_e2e_main_active", "第一条主线来电应先响铃。")
	_assert_equal(engine.get_scheduler().get_queued_events().size(), 1, "占线主线来电必须进入队列。")

	_assert_true(phone.answer_call(clock.get_current_game_tick()), "排队测试的第一通来电应能接听。")
	_assert_true(phone.hang_up(clock.get_current_game_tick() + 1), "排队测试的第一通来电应能主动挂断。")
	_assert_equal(phone.get_state_name(), "RINGING", "线路空闲后 StoryEngine 必须立即派发下一条队列来电。")
	_assert_equal(phone.get_active_event_id(), "call_e2e_main_queued", "队列来电必须在第一条结束后成为活动线路。")
	_assert_equal(engine.get_scheduler().get_queued_events().size(), 0, "派发后的队列不得保留旧事件。")
	_assert_equal(phone.get_call_records().size(), 1, "派发队列不应伪造第二条来电记录。")
	_cleanup_clock(clock)


func _test_0200_forces_ringing_call() -> void:
	_run_0200_fixture("ringing")


func _test_0200_forces_connected_call() -> void:
	_run_0200_fixture("connected")


func _test_0200_forces_dialogue_choice_call() -> void:
	_run_0200_fixture("dialogue_choice")


func _run_0200_fixture(target_state: String) -> void:
	var sut: Dictionary = _create_systems()
	var clock = sut["clock"]
	var engine = sut["engine"]
	var phone = sut["phone"]
	var active_event_id: String = "call_e2e_end_%s" % target_state
	var queued_event_id: String = "call_e2e_end_queued_%s" % target_state
	var pending_event_id: String = "call_e2e_end_pending_%s" % target_state

	_ending_signal_count = 0
	engine.ending_forced.connect(_on_ending_forced)
	_assert_ok(
		engine.schedule_event(_make_call_event(active_event_id, "main", 1, 8, "queue")),
		"02:00 fixture 应能注册活动来电。"
	)
	_assert_ok(
		engine.schedule_event(_make_call_event(queued_event_id, "main", 1, 8, "queue")),
		"02:00 fixture 应能注册排队主线来电。"
	)
	_assert_ok(
		engine.schedule_event(_make_call_event(pending_event_id, "main", 50, 55, "queue")),
		"02:00 fixture 应能注册尚未触发的主线来电。"
	)

	clock.start_shift()
	_assert_true(clock.advance_ticks_for_verification(60), "02:00 fixture 应能触发活动来电。")
	_assert_equal(phone.get_active_event_id(), active_event_id, "02:00 前必须存在目标活动线路。")
	_assert_equal(engine.get_scheduler().get_queued_events().size(), 1, "02:00 前第二条主线必须已经排队。")
	if target_state == "connected" or target_state == "dialogue_choice":
		_assert_true(phone.answer_call(clock.get_current_game_tick()), "02:00 前应能接听目标来电。")
	if target_state == "dialogue_choice":
		_assert_true(phone.enter_dialogue_choice(), "02:00 前应能进入对话选择。")
	var expected_state_name: String = target_state.to_upper()
	if target_state == "dialogue_choice":
		expected_state_name = "DIALOGUE_CHOICE"
	_assert_equal(phone.get_state_name(), expected_state_name, "02:00 前电话状态与 fixture 不一致。")

	var remaining_ticks: int = GameClockService.SHIFT_DURATION_TICKS - clock.get_current_game_tick()
	_assert_true(clock.advance_ticks_for_verification(remaining_ticks), "测试时钟应能精确推进到 02:00。")
	_assert_true(clock.is_shift_ended(), "02:00 后时钟必须停止。")
	_assert_true(engine.is_ending_forced(), "02:00 后 StoryEngine 必须锁定收束状态。")
	_assert_true(phone.is_forced_ended(), "02:00 后 PhoneSystem 必须锁定强制收束状态。")
	_assert_equal(phone.get_state_name(), "IDLE", "02:00 强制中断后电话必须回到 Idle。")
	_assert_equal(_ending_signal_count, 1, "每个 02:00 fixture 只能发出一次 ending_forced。")
	var phone_records: Array[Dictionary] = phone.get_call_records()
	_assert_equal(phone_records.size(), 1, "02:00 不得为排队或未触发事件伪造电话记录。")
	_assert_equal(_count_records(phone_records, active_event_id), 1, "活动来电只能生成一条 forced_end 记录。")
	var forced_record: Dictionary = _find_record(phone_records, active_event_id)
	_assert_record(forced_record, active_event_id, "forced_end", 60, forced_record.get("duration_ticks"), "强制中断记录字段不正确。")
	_assert_equal(engine.get_scheduler().get_queued_events().size(), 0, "02:00 必须清空电话待触发队列。")
	_assert_equal(engine.get_scheduler().get_pending_event_ids().size(), 0, "02:00 必须清空尚未触发事件。")

	var broadcast_record: Dictionary = engine.get_unauthorized_broadcast_record()
	_assert_equal(String(broadcast_record.get("fact_id")), "fact_unauthorized_broadcast", "02:00 必须创建未授权播出记录。")
	_assert_equal(int(broadcast_record.get("time_tick")), GameClockService.SHIFT_DURATION_TICKS, "未授权播出记录必须使用 02:00 tick。")
	_assert_equal(String(broadcast_record.get("source")), "Studio A", "未授权播出记录必须标记 Studio A 来源。")
	_assert_equal(String(broadcast_record.get("body")), "北桥已经恢复通行。请保持车速，不要停车。", "未授权播出记录正文不正确。")
	_assert_true(broadcast_record.is_read_only(), "未授权播出记录必须是 UI 只读副本。")
	var repeated_force: Dictionary = engine.force_ending_at_0200()
	_assert_true(bool(repeated_force.get("already_forced", false)), "重复执行 02:00 收束必须是幂等操作。")
	_assert_equal(_ending_signal_count, 1, "重复执行 02:00 收束不得重复发出 ending_forced。")
	_assert_equal(phone.get_call_records().size(), 1, "重复执行 02:00 收束不得重复生成 forced_end 记录。")

	_assert_true(not clock.is_running(), "02:00 后时钟不得继续推进。")
	_assert_true(not phone.is_busy(), "02:00 后不得保留可操作的活动线路。")
	_assert_true(not phone.answer_call(GameClockService.SHIFT_DURATION_TICKS), "02:00 后不得再接听。")
	_assert_true(
		not phone.begin_incoming_call(_make_call_event("call_e2e_after_end_%s" % target_state, "normal", 56, 58, "expire"), GameClockService.SHIFT_DURATION_TICKS, 60),
		"02:00 后 PhoneSystem 不得开始新来电。"
	)
	_assert_true(
		not phone.record_expired_call(_make_call_event("call_e2e_expired_after_end_%s" % target_state, "normal", 56, 58, "expire"), GameClockService.SHIFT_DURATION_TICKS),
		"02:00 后 PhoneSystem 不得补写过期来电记录。"
	)
	_assert_equal(engine.get_scheduler().get_pending_event_ids().size(), 0, "02:00 后不得恢复任何待处理事件。")
	_assert_equal(engine.get_scheduler().get_queued_events().size(), 0, "02:00 后不得恢复任何电话队列事件。")
	_assert_equal(_ending_signal_count, 1, "02:00 后的拒绝操作不得重复发出 ending_forced。")
	_cleanup_clock(clock)


func _create_systems() -> Dictionary:
	var clock = GAME_CLOCK_SCRIPT.new()
	root.add_child(clock)
	var engine = STORY_ENGINE_SCRIPT.new()
	var phone = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.set_phone_system(phone), "StoryEngine 必须接受 PhoneSystem 契约。")
	_assert_ok(engine.connect_game_clock(clock), "StoryEngine 必须接受 GameClock 契约。")
	return {"clock": clock, "engine": engine, "phone": phone}


func _cleanup_clock(clock: Node) -> void:
	if is_instance_valid(clock) and clock.get_parent() != null:
		clock.get_parent().remove_child(clock)
		clock.free()


func _make_call_event(event_id: String, priority: String, start_minute: int, end_minute: int, when_busy: String) -> Dictionary:
	return {
		"id": event_id,
		"kind": "incoming_call",
		"priority": priority,
		"window_start_minute": start_minute,
		"window_end_minute": end_minute,
		"when_busy": when_busy,
		"on_expire": "mark_missed",
		"condition_ids": [],
		"caller_display_name": "端到端测试来电者",
		"caller_number": "555-0188",
	}


func _count_records(records: Array[Dictionary], event_id: String) -> int:
	var count: int = 0
	for record: Dictionary in records:
		if String(record.get("event_id")) == event_id:
			count += 1
	return count


func _find_record(records: Array[Dictionary], event_id: String) -> Dictionary:
	for record: Dictionary in records:
		if String(record.get("event_id")) == event_id:
			return record
	_assert_true(false, "未找到电话记录 %s。" % event_id)
	return {}


func _assert_record(record: Dictionary, event_id: String, outcome: String, time: int, duration_ticks: Variant, message: String) -> void:
	_assert_equal(String(record.get("event_id")), event_id, "%s event_id 错误。" % message)
	_assert_equal(String(record.get("caller_name")), "端到端测试来电者", "%s caller_name 错误。" % message)
	_assert_equal(String(record.get("caller_number")), "555-0188", "%s caller_number 错误。" % message)
	_assert_equal(String(record.get("outcome")), outcome, "%s outcome 错误。" % message)
	_assert_equal(int(record.get("time")), time, "%s time 错误。" % message)
	_assert_equal(int(record.get("duration_ticks")), int(duration_ticks), "%s duration_ticks 错误。" % message)


func _on_ending_forced(_end_tick: int) -> void:
	_ending_signal_count += 1


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][FoundationIntegration] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
