extends SceneTree

## 第七阶段底层快照合同验证：本文件只覆盖 GameClock、EventScheduler 与
## PhoneSystem。StoryEngine / SaveManager 的嵌套快照与文件 I/O 由各自测试覆盖。

const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const EVENT_SCHEDULER_SCRIPT: GDScript = preload("res://scripts/core/event_scheduler.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _has_failed: bool = false


func _init() -> void:
	_test_clock_snapshot_round_trip_and_deferred_resume()
	_test_scheduler_snapshot_round_trip_and_atomic_rejection()
	_test_phone_ringing_snapshot_round_trip_and_save_guard()
	if _has_failed:
		push_error("[测试][RuntimeSnapshotsTimePhone] 失败。")
		quit(1)
		return
	print("[测试][RuntimeSnapshotsTimePhone] 通过：时钟分数进度、调度队列与响铃电话快照均可严格往返。")
	quit(0)


func _test_clock_snapshot_round_trip_and_deferred_resume() -> void:
	var source: GameClockService = GAME_CLOCK_SCRIPT.new()
	root.add_child(source)
	source.set_process(false)
	source.start_shift()
	_assert_true(source.advance_real_usec_for_verification(33_333), "时钟必须能制造未满 tick 的保存边界。")
	var snapshot: Dictionary = _json_round_trip(source.create_snapshot())
	_assert_equal(int(snapshot["current_game_tick"]), 0, "分数 tick 保存时完整 tick 仍应为零。")
	_assert_true(int(snapshot["pending_tick_progress_units"]) > 0, "快照必须保留未满 tick 的进度。")

	var restored: GameClockService = GAME_CLOCK_SCRIPT.new()
	root.add_child(restored)
	restored.set_process(false)
	var restored_start_signals: int = 0
	var restored_advance_signals: int = 0
	restored.shift_started.connect(func(_tick: int) -> void: restored_start_signals += 1)
	restored.game_time_advanced.connect(func(_from_tick: int, _to_tick: int) -> void: restored_advance_signals += 1)
	var restore_result: Dictionary = restored.restore_snapshot(snapshot, {"defer_running": true})
	_assert_ok(restore_result, "时钟快照应能使用延后启动恢复。")
	_assert_true(bool(restore_result["resume_required"]), "运行中的保存恢复到 defer_running 时必须要求显式恢复。")
	_assert_true(not restored.is_running(), "延后恢复时钟在运行时全部就绪前不得自行推进。")
	_assert_equal(restored_start_signals, 0, "恢复不得重新发出 shift_started。")
	_assert_equal(restored_advance_signals, 0, "恢复不得伪造时间推进。")
	_assert_ok(restored.resume_restored_clock(), "延后恢复的时钟必须能显式开始。")
	_assert_equal(_json_round_trip(restored.create_snapshot()), snapshot, "显式恢复运行后时钟快照必须完整往返。")
	_assert_equal(restored_start_signals, 0, "恢复运行不是开始新班次，不得发送 shift_started。")
	# Idle 现为 3 秒/游戏分钟，即每 tick 精确需要 50,000 微秒；保存前已累计
	# 33,333 微秒，恢复后补足 16,667 微秒应恰好跨过一个 tick。
	_assert_true(restored.advance_real_usec_for_verification(16_667), "恢复后的时钟必须继续累计分数进度。")
	_assert_equal(restored.get_current_game_tick(), 1, "恢复后补足的真实时间必须精确产生一个 tick。")
	var before_invalid_restore: Dictionary = restored.create_snapshot()
	var invalid_snapshot: Dictionary = snapshot.duplicate(true)
	invalid_snapshot["pending_tick_progress_units"] = -1
	_assert_true(not bool(restored.restore_snapshot(invalid_snapshot).get("ok", false)), "负分数进度必须被严格拒绝。")
	_assert_equal(restored.create_snapshot(), before_invalid_restore, "时钟恢复失败必须保持原状态。")
	var wall_source: GameClockService = GAME_CLOCK_SCRIPT.new()
	root.add_child(wall_source)
	wall_source.set_process(false)
	wall_source.start_shift()
	var wall_snapshot: Dictionary = _json_round_trip(wall_source.create_snapshot())
	var wall_restored: GameClockService = GAME_CLOCK_SCRIPT.new()
	root.add_child(wall_restored)
	wall_restored.set_process(false)
	OS.delay_msec(40)
	_assert_ok(wall_restored.restore_snapshot(wall_snapshot), "时钟必须能恢复零进度边界。")
	wall_restored._process(0.0)
	_assert_equal(wall_restored.get_current_game_tick(), 0, "恢复必须重置 wall-clock 基准，加载耗时不得补算。")
	_cleanup_node(source)
	_cleanup_node(restored)
	_cleanup_node(wall_source)
	_cleanup_node(wall_restored)


func _test_scheduler_snapshot_round_trip_and_atomic_rejection() -> void:
	var definitions: Array = [
		_event("call_triggered", "main", 0, 0, "queue", []),
		_event("call_queued_main", "main", 1, 3, "queue", []),
		_event("call_queued_normal", "normal", 1, 3, "queue", []),
		_event("call_expired", "normal", 1, 1, "expire", []),
		_event("call_suppressed", "normal", 1, 1, "expire", ["condition_never"]),
		_event("call_eligible", "normal", 1, 3, "expire", ["condition_once"]),
	]
	var source: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	_assert_ok(source.schedule_events(definitions), "调度器快照测试必须先完成当前内容事件配置。")
	_assert_ok(source.advance_to_minute(0, false, func(_condition_id: String) -> bool: return false), "首个无条件事件应触发。")
	_assert_ok(
		source.advance_to_minute(1, true, func(condition_id: String) -> bool: return condition_id == "condition_once"),
		"占线分钟应创建队列并记录条件资格。"
	)
	_assert_ok(source.advance_to_minute(2, true, func(_condition_id: String) -> bool: return false), "跨窗应生成 expired 与 suppressed 状态。")
	var snapshot: Dictionary = _json_round_trip(source.create_snapshot())
	_assert_equal(String((snapshot["event_status_by_id"] as Dictionary)["call_triggered"]), "triggered", "触发状态必须进入快照。")
	_assert_equal(String((snapshot["event_status_by_id"] as Dictionary)["call_expired"]), "expired", "过期状态必须进入快照。")
	_assert_equal(String((snapshot["event_status_by_id"] as Dictionary)["call_suppressed"]), "suppressed_condition_unmet", "未获资格条件事件必须安静失效。")
	_assert_equal((snapshot["queued_items"] as Array).size(), 2, "两个占线 queue 事件必须保留在快照中。")
	_assert_equal((snapshot["condition_eligible_event_ids"] as Array), ["call_eligible"], "已获条件资格且未处理的事件必须保留。")

	var restored: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	_assert_ok(restored.schedule_events(definitions), "恢复对象必须按相同内容完成配置。")
	var signal_count: int = 0
	restored.event_ready.connect(func(_event: Dictionary) -> void: signal_count += 1)
	restored.event_queued.connect(func(_event: Dictionary) -> void: signal_count += 1)
	restored.event_expired.connect(func(_event: Dictionary) -> void: signal_count += 1)
	var context: Dictionary = {"event_by_id": restored.get_configured_events_by_id()}
	_assert_ok(restored.restore_snapshot(snapshot, context), "调度器动态队列、状态与序号必须能严格恢复。")
	_assert_equal(signal_count, 0, "调度器恢复不得重新触发、入队或过期事件。")
	_assert_equal(_json_round_trip(restored.create_snapshot()), snapshot, "调度器完整动态状态必须往返一致。")
	var queue_items: Array = restored.create_snapshot()["queued_items"] as Array
	_assert_equal(String((queue_items[0] as Dictionary)["event_id"]), "call_queued_main", "队列恢复必须保留主线优先顺序。")
	_assert_equal(String((queue_items[1] as Dictionary)["event_id"]), "call_queued_normal", "队列恢复必须保留同一队列顺序。")
	var before_invalid_restore: Dictionary = restored.create_snapshot()
	var invalid_snapshot: Dictionary = snapshot.duplicate(true)
	(invalid_snapshot["pending_event_ids"] as Array).append("call_queued_main")
	_assert_true(not bool(restored.restore_snapshot(invalid_snapshot, context).get("ok", false)), "待处理与队列重叠必须被拒绝。")
	_assert_equal(restored.create_snapshot(), before_invalid_restore, "调度器恢复失败必须保持原状态。")
	var unknown_snapshot: Dictionary = snapshot.duplicate(true)
	var unknown_statuses: Dictionary = (unknown_snapshot["event_status_by_id"] as Dictionary).duplicate(true)
	unknown_statuses["call_unknown"] = "triggered"
	unknown_snapshot["event_status_by_id"] = unknown_statuses
	_assert_true(not bool(restored.validate_snapshot(unknown_snapshot, context).get("ok", false)), "调度器快照中的未知事件 ID 必须拒绝。")
	var open_window_scheduler: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	var open_window_definition: Dictionary = _event("call_open_window", "normal", 1, 2, "expire", [])
	_assert_ok(open_window_scheduler.schedule_event(open_window_definition), "无条件 expire 事件必须能注册。")
	_assert_ok(open_window_scheduler.advance_to_minute(1, true), "占线时无条件 expire 事件应保持待处理。")
	var open_window_snapshot: Dictionary = _json_round_trip(open_window_scheduler.create_snapshot())
	_assert_equal(open_window_snapshot["condition_eligible_event_ids"], ["call_open_window"], "当前窗口内无条件 expire 事件也必须保留派发资格。")
	_assert_ok(
		open_window_scheduler.validate_snapshot(open_window_snapshot, {"event_by_id": open_window_scheduler.get_configured_events_by_id()}),
		"无条件 expire 的窗口资格快照必须是合法状态。"
	)


func _test_phone_ringing_snapshot_round_trip_and_save_guard() -> void:
	var event_by_id: Dictionary = {
		"call_recorded": _event("call_recorded", "normal", 0, 1, "expire", []),
		"call_ringing": _event("call_ringing", "main", 1, 2, "queue", []),
	}
	var source: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_true(source.record_expired_call(event_by_id["call_recorded"] as Dictionary, 20), "真实过期记录必须由 PhoneSystem 生成。")
	_assert_true(source.begin_incoming_call(event_by_id["call_ringing"] as Dictionary, 83, 5), "响铃保存边界必须能开始来电。")
	_assert_true(not source.advance_to_tick(85), "剩余三 tick 时不能提前漏接。")
	_assert_true(source.can_save(), "RINGING 必须允许保存。")
	_assert_equal(source.get_save_block_reason(), "", "RINGING 保存不得显示禁止原因。")
	var snapshot: Dictionary = _json_round_trip(source.create_snapshot())
	var active_snapshot: Dictionary = snapshot["active_call"] as Dictionary
	_assert_equal(int(snapshot["snapshot_current_tick"]), 85, "电话快照必须绑定当前游戏 tick。")
	_assert_equal(int(active_snapshot["ringing_ticks_remaining"]), 3, "响铃快照必须保存相对剩余 tick。")

	var restored: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	var state_signal_count: int = 0
	var record_signal_count: int = 0
	restored.state_changed.connect(func(_before: int, _after: int, _event_id: String) -> void: state_signal_count += 1)
	restored.call_record_created.connect(func(_record: Dictionary) -> void: record_signal_count += 1)
	var context: Dictionary = {"current_game_tick": 85, "event_by_id": event_by_id}
	_assert_ok(restored.restore_snapshot(snapshot, context), "响铃、真实记录与已处理 ID 必须能完整恢复。")
	_assert_equal(state_signal_count, 0, "电话恢复不得发送 state_changed。")
	_assert_equal(record_signal_count, 0, "电话恢复不得伪造来电记录。")
	_assert_equal(_json_round_trip(restored.create_snapshot()), snapshot, "RINGING 电话快照必须往返一致。")
	_assert_true(not restored.advance_to_tick(87), "恢复后剩余 N-1 tick 时不得漏接。")
	_assert_equal(restored.get_call_records().size(), 1, "恢复后 N-1 tick 不得重复现有记录。")
	_assert_true(restored.advance_to_tick(88), "恢复后剩余 N tick 时必须精确生成一次漏接。")
	_assert_equal(restored.get_call_records().size(), 2, "响铃超时必须只新增一条真实记录。")
	_assert_true(not restored.advance_to_tick(89), "已经漏接的来电不得重复记录。")
	_assert_equal(restored.get_call_records().size(), 2, "超时后的继续推进不得重复漏接。")

	var before_invalid_restore: Dictionary = restored.create_snapshot()
	var invalid_snapshot: Dictionary = snapshot.duplicate(true)
	var invalid_active: Dictionary = (invalid_snapshot["active_call"] as Dictionary).duplicate(true)
	invalid_active["ringing_ticks_remaining"] = -1
	invalid_snapshot["active_call"] = invalid_active
	_assert_true(not bool(restored.restore_snapshot(invalid_snapshot, context).get("ok", false)), "负响铃剩余 tick 必须拒绝恢复。")
	_assert_equal(restored.create_snapshot(), before_invalid_restore, "电话恢复失败必须保持原状态。")
	var unknown_snapshot: Dictionary = snapshot.duplicate(true)
	var unknown_active: Dictionary = (unknown_snapshot["active_call"] as Dictionary).duplicate(true)
	unknown_active["event_id"] = "call_unknown"
	unknown_snapshot["active_call"] = unknown_active
	_assert_true(not bool(restored.validate_snapshot(unknown_snapshot, context).get("ok", false)), "未知来电 ID 必须拒绝读取。")
	var premature_forced_snapshot: Dictionary = snapshot.duplicate(true)
	premature_forced_snapshot["state"] = "IDLE"
	premature_forced_snapshot["active_call"] = null
	premature_forced_snapshot["forced_end"] = true
	_assert_true(
		not bool(restored.validate_snapshot(premature_forced_snapshot, context).get("ok", false)),
		"02:00 前的 forced_end 电话快照必须被拒绝。"
	)
	var ended_phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_true(ended_phone.force_end_at_0200(3_600), "空闲线路也必须能在精确 02:00 标记强制结束。")
	var ended_snapshot: Dictionary = _json_round_trip(ended_phone.create_snapshot())
	_assert_ok(
		ended_phone.validate_snapshot(ended_snapshot, {"current_game_tick": 3_600, "event_by_id": event_by_id}),
		"精确 02:00 的 forced_end 电话快照必须通过严格校验。"
	)

	var connected: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_true(connected.begin_incoming_call(event_by_id["call_ringing"] as Dictionary, 40, 5), "保存限制测试必须开始来电。")
	_assert_true(connected.answer_call(41), "保存限制测试必须接通电话。")
	_assert_true(not connected.can_save(), "CONNECTED 必须拒绝保存。")
	_assert_true(connected.get_save_block_reason().contains("通话已接通"), "CONNECTED 必须提供中文禁止原因。")
	_assert_true(connected.enter_dialogue_choice(), "保存限制测试必须进入对话选择。")
	_assert_true(not connected.can_save(), "DIALOGUE_CHOICE 必须拒绝保存。")
	_assert_true(connected.get_save_block_reason().contains("对话选择"), "DIALOGUE_CHOICE 必须提供中文禁止原因。")


func _event(event_id: String, priority: String, start_minute: int, end_minute: int, when_busy: String, condition_ids: Array) -> Dictionary:
	return {
		"id": event_id,
		"kind": "incoming_call",
		"priority": priority,
		"window_start_minute": start_minute,
		"window_end_minute": end_minute,
		"when_busy": when_busy,
		"on_expire": "mark_missed",
		"condition_ids": condition_ids,
		"caller_display_name": "来电者 %s" % event_id,
		"caller_number": "555-%04d" % (1000 + start_minute),
	}


func _cleanup_node(node: Node) -> void:
	if is_instance_valid(node) and node.get_parent() != null:
		node.get_parent().remove_child(node)
		node.free()


func _json_round_trip(snapshot: Dictionary) -> Dictionary:
	var encoded: String = JSON.stringify(snapshot)
	var decoded: Variant = JSON.parse_string(encoded)
	if decoded is Dictionary:
		return decoded as Dictionary
	_assert_true(false, "运行时快照必须可 JSON 编码并还原为对象。")
	return {}


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][RuntimeSnapshotsTimePhone] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
