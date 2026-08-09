## 《末班电台》的最小权威剧情状态。
##
## 本类只协调时钟、事件调度和电话入口；不为未确认的事实图、对话或存档
## 预建占位层。时间始终由 GameClock 提供的整数 tick 派生。
extends RefCounted
class_name StoryEngine

signal event_ready(event: Dictionary)
signal event_queued(event: Dictionary)
signal event_expired(event: Dictionary)
signal ending_forced(end_tick: int)
signal story_time_advanced(previous_tick: int, current_tick: int, current_minute: int)
signal story_error(error_code: String, message: String)

const TICKS_PER_GAME_MINUTE: int = 60
const ENDING_TICK: int = 60 * TICKS_PER_GAME_MINUTE

var _scheduler: EventScheduler = EventScheduler.new()
var _condition_state_by_id: Dictionary = {}
var _game_clock: Node = null
var _phone_system: RefCounted = null
var _current_game_tick: int = 0
var _current_minute: int = 0
var _is_ending_forced: bool = false
var _unauthorized_broadcast_record: Dictionary = {}


func _init() -> void:
	_scheduler.event_ready.connect(_on_scheduler_event_ready)
	_scheduler.event_queued.connect(_on_scheduler_event_queued)
	_scheduler.event_expired.connect(_on_scheduler_event_expired)
	_scheduler.scheduler_error.connect(_on_scheduler_error)


## 注入 GameClock。只依赖稳定信号和 get_current_game_tick()，不硬编码节点路径。
func connect_game_clock(game_clock: Node) -> Dictionary:
	if not is_instance_valid(game_clock):
		return _make_error("invalid_game_clock", "GameClock 实例无效。")
	if not game_clock.has_signal(&"game_time_advanced") or not game_clock.has_signal(&"ending_time_reached"):
		return _make_error("invalid_game_clock_contract", "GameClock 缺少 game_time_advanced 或 ending_time_reached 信号。")
	if not game_clock.has_method(&"get_current_game_tick"):
		return _make_error("invalid_game_clock_contract", "GameClock 缺少 get_current_game_tick() 方法。")

	_disconnect_game_clock()
	_game_clock = game_clock
	var time_callback: Callable = Callable(self, "_on_game_time_advanced")
	var ending_callback: Callable = Callable(self, "_on_ending_time_reached")
	var time_result: Error = _game_clock.connect(&"game_time_advanced", time_callback)
	if time_result != OK:
		_game_clock = null
		return _make_error("game_clock_connect_failed", "无法连接 GameClock 的 game_time_advanced 信号。")
	var ending_result: Error = _game_clock.connect(&"ending_time_reached", ending_callback)
	if ending_result != OK:
		_game_clock.disconnect(&"game_time_advanced", time_callback)
		_game_clock = null
		return _make_error("game_clock_connect_failed", "无法连接 GameClock 的 ending_time_reached 信号。")

	var tick_value: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_value) != TYPE_INT:
		_disconnect_game_clock()
		return _make_error("invalid_game_clock_tick", "GameClock.get_current_game_tick() 必须返回整数 tick。")
	return advance_to_game_tick(int(tick_value))


## 注入电话状态机。要求 PhoneSystem 提供约定的公开方法，避免场景节点耦合。
func set_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("invalid_phone_system", "PhoneSystem 实例不能为空。")
	var required_methods: PackedStringArray = [
		"begin_incoming_call",
		"force_end_at_0200",
		"is_busy",
		"advance_to_tick",
		"record_expired_call",
	]
	for method_name: String in required_methods:
		if not phone_system.has_method(method_name):
			return _make_error("invalid_phone_system_contract", "PhoneSystem 缺少 %s() 方法。" % method_name)
	_disconnect_phone_system()
	_phone_system = phone_system
	if _phone_system.has_signal(&"call_became_idle"):
		var idle_callback: Callable = Callable(self, "_on_phone_became_idle")
		if not _phone_system.is_connected(&"call_became_idle", idle_callback):
			var connect_result: Error = _phone_system.connect(&"call_became_idle", idle_callback)
			if connect_result != OK:
				_phone_system = null
				return _make_error("phone_signal_connect_failed", "无法连接 PhoneSystem 的 call_became_idle 信号。")
	return {"ok": true}


func schedule_event(event_data: Dictionary) -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")
	return _scheduler.schedule_event(event_data)


func schedule_events(event_definitions: Array) -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")
	return _scheduler.schedule_events(event_definitions)


## 直接按整数 tick 推进，供 GameClock 信号和 Headless 验证共同使用。
func advance_to_game_tick(current_tick: int) -> Dictionary:
	if current_tick < _current_game_tick:
		return _make_error("time_reversed", "StoryEngine 的游戏时间不能倒退。")
	if current_tick < 0:
		return _make_error("invalid_game_tick", "游戏 tick 不能小于 0。")
	if _is_ending_forced:
		_current_game_tick = current_tick
		_current_minute = current_tick / TICKS_PER_GAME_MINUTE
		return {"ok": true, "ignored_after_ending": true}

	var previous_tick: int = _current_game_tick
	_current_game_tick = current_tick
	_current_minute = current_tick / TICKS_PER_GAME_MINUTE
	if current_tick >= ENDING_TICK:
		force_ending_at_0200(ENDING_TICK)
		return {"ok": true, "forced_ending": true}

	_advance_phone_to_tick(current_tick)
	if not _is_phone_busy():
		_dispatch_next_queued_event()
	var processing_result: Dictionary = _scheduler.advance_to_minute(_current_minute, _is_phone_busy(), _is_condition_met)
	if not bool(processing_result["ok"]):
		return processing_result
	story_time_advanced.emit(previous_tick, _current_game_tick, _current_minute)
	return processing_result


## 由电话状态机空闲信号或集成方显式调用。
func dispatch_next_queued_event_if_idle() -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能派发队列事件。")
	if _is_phone_busy():
		return {"ok": true, "dispatched": false, "reason": "phone_busy"}
	return _dispatch_next_queued_event()


func force_ending_at_0200(end_tick: int = ENDING_TICK) -> Dictionary:
	if _is_ending_forced:
		return {"ok": true, "already_forced": true}
	if end_tick != ENDING_TICK:
		return _make_error("invalid_ending_tick", "ending_forced 必须使用精确的 02:00 tick（3600）。")

	_is_ending_forced = true
	_current_game_tick = max(_current_game_tick, end_tick)
	_current_minute = _current_game_tick / TICKS_PER_GAME_MINUTE
	var scheduler_result: Dictionary = _scheduler.force_ending()
	if not bool(scheduler_result["ok"]):
		return scheduler_result
	_unauthorized_broadcast_record = {
		"fact_id": "fact_unauthorized_broadcast",
		"time_tick": end_tick,
		"source": "Studio A",
		"body": "北桥已经恢复通行。请保持车速，不要停车。",
	}
	_unauthorized_broadcast_record.make_read_only()
	var phone_force_failed: bool = false
	if _phone_system != null:
		var phone_result: Variant = _phone_system.call(&"force_end_at_0200", end_tick)
		if typeof(phone_result) == TYPE_BOOL:
			phone_force_failed = not bool(phone_result)
		elif typeof(phone_result) == TYPE_DICTIONARY:
			phone_force_failed = not bool((phone_result as Dictionary).get("ok", false))
		else:
			phone_force_failed = true
	ending_forced.emit(end_tick)
	print("[剧情][ending_forced] 02:00 强制收束已执行。")
	if phone_force_failed:
		return _make_error("phone_force_end_failed", "PhoneSystem 未能在 02:00 终止当前线路。")
	return {"ok": true, "already_forced": false}


func set_condition_state(condition_id: String, is_met: bool) -> Dictionary:
	if condition_id.is_empty() or condition_id.begins_with("_") or condition_id != condition_id.to_lower() or not condition_id.is_valid_identifier() or not condition_id.is_valid_ascii_identifier():
		return _make_error("invalid_condition_id", "条件 ID 必须是英文 snake_case 标识符。")
	_condition_state_by_id[condition_id] = is_met
	return {"ok": true}


func is_condition_met(condition_id: String) -> bool:
	return _is_condition_met(condition_id)


func is_ending_forced() -> bool:
	return _is_ending_forced


func get_current_game_tick() -> int:
	return _current_game_tick


func get_current_minute() -> int:
	return _current_minute


func get_scheduler() -> EventScheduler:
	return _scheduler


## 结尾电脑页读取的唯一播出记录来源。收束前返回空字典。
func get_unauthorized_broadcast_record() -> Dictionary:
	if _unauthorized_broadcast_record.is_empty():
		return {}
	var record_copy: Dictionary = _unauthorized_broadcast_record.duplicate(true)
	record_copy.make_read_only()
	return record_copy


## 应用壳销毁一局运行时时调用。它只解除跨对象信号和引用，不重置或复活剧情。
## 保持幂等，避免旧 RefCounted 因 GameClock 或 PhoneSystem 的回调继续存活。
func release_runtime() -> Dictionary:
	_disconnect_game_clock()
	_disconnect_phone_system()
	_phone_system = null
	return {"ok": true}


func _on_game_time_advanced(previous_tick: int, current_tick: int) -> void:
	# GameClock 会先发 ending_time_reached；若信号顺序异常，本方法仍自行守住 02:00。
	if previous_tick > current_tick:
		_make_error("time_reversed", "GameClock 发出了倒退的游戏时间信号。")
		return
	advance_to_game_tick(current_tick)


func _on_ending_time_reached(end_tick: int) -> void:
	force_ending_at_0200(end_tick)


func _on_phone_became_idle(_event_id: String) -> void:
	# 02:00 强制结束活动线路也会发出空闲信号；此时绝不能再尝试派发队列。
	if _is_ending_forced:
		return
	dispatch_next_queued_event_if_idle()


func _dispatch_next_queued_event() -> Dictionary:
	var queue_result: Dictionary = _scheduler.take_next_queued_event()
	if not bool(queue_result["ok"]):
		return queue_result
	if not bool(queue_result["has_event"]):
		return {"ok": true, "dispatched": false}
	var event_data: Dictionary = queue_result["event"]
	# take_next_queued_event() 发出 event_ready；统一由 _on_scheduler_event_ready
	# 调用 PhoneSystem，避免同一来电被开始两次。
	return {"ok": true, "dispatched": true, "event": event_data}


func _on_scheduler_event_ready(event_data: Dictionary) -> void:
	if _is_ending_forced:
		return
	if not _begin_phone_call(event_data):
		_make_error("phone_begin_call_failed", "PhoneSystem 未能开始来电 %s。" % String(event_data["id"]))
		return
	event_ready.emit(event_data)


func _on_scheduler_event_queued(event_data: Dictionary) -> void:
	event_queued.emit(event_data)


func _on_scheduler_event_expired(event_data: Dictionary) -> void:
	if _phone_system != null:
		var record_result: Variant = _phone_system.call(&"record_expired_call", event_data, _current_game_tick)
		var record_succeeded: bool = false
		if typeof(record_result) == TYPE_BOOL:
			record_succeeded = bool(record_result)
		elif typeof(record_result) == TYPE_DICTIONARY:
			record_succeeded = bool((record_result as Dictionary).get("ok", false))
		if not record_succeeded:
			_make_error("phone_expired_record_failed", "PhoneSystem 未能为过期来电 %s 生成漏接记录。" % String(event_data["id"]))
			return
	event_expired.emit(event_data)


func _on_scheduler_error(_event_id: String, error_code: String, message: String) -> void:
	story_error.emit(error_code, message)


func _begin_phone_call(event_data: Dictionary) -> bool:
	if _phone_system == null:
		# 测试和纯调度阶段允许没有电话系统；事件仍由 StoryEngine 作为权威状态公开。
		return true
	var begin_result: Variant = _phone_system.call(&"begin_incoming_call", event_data, _current_game_tick, TICKS_PER_GAME_MINUTE)
	if typeof(begin_result) == TYPE_BOOL:
		return bool(begin_result)
	if typeof(begin_result) == TYPE_DICTIONARY:
		return bool((begin_result as Dictionary).get("ok", false))
	_make_error("invalid_phone_result", "PhoneSystem.begin_incoming_call() 必须返回 bool 或带 ok 的 Dictionary。")
	return false


func _is_phone_busy() -> bool:
	if _phone_system == null:
		return false
	var busy_result: Variant = _phone_system.call(&"is_busy")
	if typeof(busy_result) != TYPE_BOOL:
		_make_error("invalid_phone_busy_result", "PhoneSystem.is_busy() 必须返回 bool。")
		return true
	return bool(busy_result)


func _advance_phone_to_tick(current_tick: int) -> void:
	if _phone_system == null:
		return
	var advance_result: Variant = _phone_system.call(&"advance_to_tick", current_tick)
	if typeof(advance_result) != TYPE_BOOL:
		_make_error("invalid_phone_advance_result", "PhoneSystem.advance_to_tick() 必须返回 bool。")


func _is_condition_met(condition_id: String) -> bool:
	return bool(_condition_state_by_id.get(condition_id, false))


func _disconnect_game_clock() -> void:
	if _game_clock == null or not is_instance_valid(_game_clock):
		_game_clock = null
		return
	var time_callback: Callable = Callable(self, "_on_game_time_advanced")
	var ending_callback: Callable = Callable(self, "_on_ending_time_reached")
	if _game_clock.is_connected(&"game_time_advanced", time_callback):
		_game_clock.disconnect(&"game_time_advanced", time_callback)
	if _game_clock.is_connected(&"ending_time_reached", ending_callback):
		_game_clock.disconnect(&"ending_time_reached", ending_callback)
	_game_clock = null


func _disconnect_phone_system() -> void:
	if _phone_system == null:
		return
	var idle_callback: Callable = Callable(self, "_on_phone_became_idle")
	if _phone_system.has_signal(&"call_became_idle") and _phone_system.is_connected(&"call_became_idle", idle_callback):
		_phone_system.disconnect(&"call_became_idle", idle_callback)


func _make_error(error_code: String, message: String) -> Dictionary:
	story_error.emit(error_code, message)
	push_error("[剧情][%s] %s" % [error_code, message])
	return {"ok": false, "error_code": error_code, "message": message}
