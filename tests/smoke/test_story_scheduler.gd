extends SceneTree

const EVENT_SCHEDULER_SCRIPT: GDScript = preload("res://scripts/core/event_scheduler.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _has_failed: bool = false
var _expired_count: int = 0
var _ending_count: int = 0


func _init() -> void:
	_test_mainline_event_queues_while_busy()
	_test_normal_event_expires_exactly_once()
	_test_expired_normal_event_creates_one_phone_record()
	_test_queue_has_stable_priority_order()
	_test_0200_clears_and_locks_scheduler()

	if _has_failed:
		print("[测试][StoryScheduler] 失败。")
		quit(1)
		return
	print("[测试][StoryScheduler] 通过：占线队列、普通过期、稳定排序与 02:00 收束均符合契约。")
	quit(0)


func _test_mainline_event_queues_while_busy() -> void:
	var scheduler: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	_assert_ok(scheduler.schedule_event(_make_event("call_main_busy", "main", 5, 8, "queue")), "主线事件应能注册。")
	var result: Dictionary = scheduler.advance_to_minute(5, true)
	_assert_ok(result, "占线推进应成功。")
	_assert_equal(scheduler.get_event_status("call_main_busy"), "queued", "主线来电占线时必须进入队列。")
	var queued_events: Array[Dictionary] = scheduler.get_queued_events()
	_assert_equal(queued_events.size(), 1, "主线占线时应仅有一条队列事件。")
	_assert_equal(String(queued_events[0]["id"]), "call_main_busy", "队列事件 ID 应保持不变。")
	var dequeued: Dictionary = scheduler.take_next_queued_event()
	_assert_ok(dequeued, "电话空闲时应能取出主线队列。")
	_assert_true(bool(dequeued["has_event"]), "队列应确实提供一条事件。")
	_assert_equal(String((dequeued["event"] as Dictionary)["id"]), "call_main_busy", "取出的事件必须与入队事件一致。")


func _test_normal_event_expires_exactly_once() -> void:
	var scheduler: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	_expired_count = 0
	scheduler.event_expired.connect(_on_event_expired)
	_assert_ok(scheduler.schedule_event(_make_event("call_normal_expire", "normal", 2, 3, "expire")), "普通事件应能注册。")
	_assert_ok(scheduler.advance_to_minute(2, true), "普通来电占线时不应立即失败。")
	_assert_equal(_expired_count, 0, "仍在窗口内的普通来电不能提前漏接。")
	_assert_ok(scheduler.advance_to_minute(4, true), "跨过时间窗应能处理普通来电。")
	_assert_equal(_expired_count, 1, "普通来电过期时必须只生成一次漏接。")
	_assert_equal(scheduler.get_event_status("call_normal_expire"), "expired", "普通来电过期后状态必须是 expired。")
	_assert_ok(scheduler.advance_to_minute(5, true), "过期后的继续推进应成功。")
	_assert_equal(_expired_count, 1, "过期事件不得在后续分钟重复生成漏接。")


func _test_queue_has_stable_priority_order() -> void:
	var scheduler: EventScheduler = EVENT_SCHEDULER_SCRIPT.new()
	var events: Array = [
		_make_event("call_normal_first", "normal", 7, 9, "queue"),
		_make_event("call_main_first", "main", 7, 9, "queue"),
		_make_event("call_main_second", "main", 7, 9, "queue"),
	]
	_assert_ok(scheduler.schedule_events(events), "同一窗口的事件批次应能注册。")
	_assert_ok(scheduler.advance_to_minute(7, true), "占线时应能将同窗事件排队。")
	var queued_events: Array[Dictionary] = scheduler.get_queued_events()
	_assert_equal(queued_events.size(), 3, "三个同窗占线事件均应排队。")
	_assert_equal(String(queued_events[0]["id"]), "call_main_first", "队列必须优先主线事件。")
	_assert_equal(String(queued_events[1]["id"]), "call_main_second", "同优先级事件必须保持原始触发顺序。")
	_assert_equal(String(queued_events[2]["id"]), "call_normal_first", "普通事件应排在主线事件之后。")


func _test_expired_normal_event_creates_one_phone_record() -> void:
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone_system: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.set_phone_system(phone_system), "StoryEngine 应能注入 PhoneSystem。")
	var events: Array = [
		_make_event("call_busy_main", "main", 1, 3, "queue"),
		_make_event("call_busy_normal", "normal", 1, 1, "expire"),
	]
	_assert_ok(engine.schedule_events(events), "真实电话记录测试的事件应能注册。")
	_assert_ok(engine.advance_to_game_tick(60), "第 1 分钟应触发主线响铃并保持线路占线。")
	_assert_true(phone_system.is_busy(), "主线响铃后电话应处于忙状态。")
	_assert_ok(engine.advance_to_game_tick(120), "跨过普通事件窗口时应处理过期记录。")
	var records_after_expire: Array[Dictionary] = phone_system.get_call_records()
	_assert_equal(_count_records(records_after_expire, "call_busy_normal"), 1, "占线过期的普通来电必须产生且只产生一条记录。")
	var normal_record: Dictionary = _find_record(records_after_expire, "call_busy_normal")
	_assert_equal(String(normal_record["outcome"]), "missed", "占线过期的普通来电必须由 PhoneSystem 记录为 missed。")
	_assert_equal(int(normal_record["duration_ticks"]), 0, "从未响铃的过期普通来电通话时长必须为 0。")
	_assert_ok(engine.advance_to_game_tick(180), "过期后继续推进不应失败。")
	_assert_equal(_count_records(phone_system.get_call_records(), "call_busy_normal"), 1, "继续推进不得重复写入普通来电的漏接记录。")


func _test_0200_clears_and_locks_scheduler() -> void:
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var test_clock: GameClockService = GAME_CLOCK_SCRIPT.new()
	var phone_system: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	root.add_child(test_clock)
	_ending_count = 0
	engine.ending_forced.connect(_on_ending_forced)
	_assert_ok(engine.set_phone_system(phone_system), "02:00 测试应能注入 PhoneSystem。")
	_assert_ok(engine.connect_game_clock(test_clock), "StoryEngine 应能连接 GameClock 稳定信号。")
	_assert_ok(engine.schedule_event(_make_event("call_active_at_end", "main", 1, 3, "queue")), "收束时的活动来电应能注册。")
	_assert_ok(engine.schedule_event(_make_event("call_pending_before_end", "main", 50, 55, "queue")), "02:00 前的待处理主线应能注册。")
	test_clock.start_shift()
	_assert_true(test_clock.advance_ticks_for_verification(60), "测试时钟应能先触发一条活动来电。")
	_assert_true(phone_system.is_busy(), "02:00 前的活动来电应真实占用电话线路。")
	_assert_true(test_clock.advance_ticks_for_verification(GameClockService.SHIFT_DURATION_TICKS - 60), "测试时钟应能精确到达 02:00。")
	_assert_true(engine.is_ending_forced(), "02:00 时 StoryEngine 必须进入强制收束状态。")
	_assert_true(phone_system.is_forced_ended(), "02:00 时 StoryEngine 必须强制结束 PhoneSystem。")
	var forced_call: Dictionary = _find_record(phone_system.get_call_records(), "call_active_at_end")
	_assert_equal(String(forced_call["outcome"]), "forced_end", "02:00 必须把活动来电记录为 forced_end。")
	_assert_equal(_ending_count, 1, "强制收束信号必须只发一次。")
	_assert_equal(engine.get_scheduler().get_pending_event_ids().size(), 0, "02:00 必须清空尚未触发事件。")
	var broadcast_record: Dictionary = engine.get_unauthorized_broadcast_record()
	_assert_equal(String(broadcast_record["fact_id"]), "fact_unauthorized_broadcast", "结尾必须由 StoryEngine 创建未授权播出事实。")
	_assert_equal(int(broadcast_record["time_tick"]), GameClockService.SHIFT_DURATION_TICKS, "未授权播出记录必须使用 02:00 tick。")
	_assert_true(broadcast_record.is_read_only(), "UI 读取的未授权播出记录必须是只读副本。")
	var rejected_schedule: Dictionary = engine.schedule_event(_make_event("call_after_end", "main", 56, 58, "queue"))
	_assert_true(not bool(rejected_schedule["ok"]), "02:00 后必须拒绝新的事件调度。")
	_assert_equal(String(rejected_schedule["error_code"]), "ending_forced", "02:00 后拒绝调度应返回 ending_forced。")
	var rejected_dispatch: Dictionary = engine.dispatch_next_queued_event_if_idle()
	_assert_true(not bool(rejected_dispatch["ok"]), "02:00 后必须拒绝派发队列事件。")
	test_clock.queue_free()


func _make_event(event_id: String, priority: String, start_minute: int, end_minute: int, when_busy: String) -> Dictionary:
	return {
		"id": event_id,
		"kind": "incoming_call",
		"priority": priority,
		"window_start_minute": start_minute,
		"window_end_minute": end_minute,
		"when_busy": when_busy,
		"on_expire": "mark_missed",
		"condition_ids": [],
		"caller_display_name": "测试来电者",
		"caller_number": "555-0100",
	}


func _count_records(records: Array[Dictionary], event_id: String) -> int:
	var count: int = 0
	for record: Dictionary in records:
		if String(record["event_id"]) == event_id:
			count += 1
	return count


func _find_record(records: Array[Dictionary], event_id: String) -> Dictionary:
	for record: Dictionary in records:
		if String(record["event_id"]) == event_id:
			return record
	push_error("[测试][StoryScheduler] 未找到来电记录 %s。" % event_id)
	return {}


func _on_event_expired(_event: Dictionary) -> void:
	_expired_count += 1


func _on_ending_forced(_end_tick: int) -> void:
	_ending_count += 1


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][StoryScheduler] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
