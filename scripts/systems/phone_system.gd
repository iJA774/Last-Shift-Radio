class_name PhoneSystem
extends RefCounted

## 电话状态机只维护线路状态和由状态转移产生的记录。
## 剧情时钟、事件队列和对话内容仍由 StoryEngine 持有。

signal state_changed(previous_state: int, current_state: int, event_id: String)
signal call_record_created(record: Dictionary)
signal call_became_idle(event_id: String)
signal phone_error(event_id: String, message: String)

enum State {
	IDLE,
	RINGING,
	CONNECTED,
	DIALOGUE_CHOICE,
	ENDED,
	MISSED,
}

const OUTCOME_ANSWERED: String = "answered"
const OUTCOME_MISSED: String = "missed"
const OUTCOME_HUNG_UP: String = "hung_up"
const OUTCOME_FORCED_END: String = "forced_end"

const INVALID_TICK: int = -1
const SNAPSHOT_VERSION: int = 1
const SNAPSHOT_SYSTEM_ID: String = "phone_system"
const MAX_GAME_TICK: int = 3_600

const _SNAPSHOT_STATES: PackedStringArray = ["IDLE", "RINGING", "CONNECTED", "DIALOGUE_CHOICE"]
const _SNAPSHOT_OUTCOMES: PackedStringArray = [
	OUTCOME_ANSWERED,
	OUTCOME_MISSED,
	OUTCOME_HUNG_UP,
	OUTCOME_FORCED_END,
]

var _state: State = State.IDLE
var _active_call: PhoneCall = null
var _call_records: Array[Dictionary] = []
var _handled_event_ids: Dictionary = {}
var _has_forced_ended: bool = false
var _last_error: String = ""
## PhoneSystem 不拥有时钟；由每个带 current_tick 的公开操作更新此镜像，供
## create_snapshot() 将响铃剩余时间与同一游戏 tick 绑定。
var _last_known_game_tick: int = 0


class PhoneCall extends RefCounted:
	var event_id: String
	var caller_name: String
	var caller_number: String
	var ringing_started_tick: int
	var ringing_deadline_tick: int
	var connected_started_tick: int = INVALID_TICK

	func _init(
		p_event_id: String,
		p_caller_name: String,
		p_caller_number: String,
		p_ringing_started_tick: int,
		p_ringing_deadline_tick: int
	) -> void:
		event_id = p_event_id
		caller_name = p_caller_name
		caller_number = p_caller_number
		ringing_started_tick = p_ringing_started_tick
		ringing_deadline_tick = p_ringing_deadline_tick


func get_state() -> State:
	return _state


func get_state_name() -> String:
	return State.keys()[_state]


func is_busy() -> bool:
	return _state == State.RINGING or _state == State.CONNECTED or _state == State.DIALOGUE_CHOICE


func is_forced_ended() -> bool:
	return _has_forced_ended


func get_active_event_id() -> String:
	if _active_call == null:
		return ""
	return _active_call.event_id


## 供 UI 只读展示来显与响铃倒计时。返回新字典，调用方不能修改权威线路状态。
func get_active_call_snapshot() -> Dictionary:
	if _active_call == null:
		return {}
	return {
		"event_id": _active_call.event_id,
		"caller_name": _active_call.caller_name,
		"caller_number": _active_call.caller_number,
		"ringing_started_tick": _active_call.ringing_started_tick,
		"ringing_deadline_tick": _active_call.ringing_deadline_tick,
		"connected_started_tick": _active_call.connected_started_tick,
	}


func get_last_error() -> String:
	return _last_error


func get_call_records() -> Array[Dictionary]:
	return _call_records.duplicate(true)


## 线路空闲或响铃时允许写档；已经接通或等待对话选择时必须由玩家先完成当前操作。
func can_save() -> bool:
	return _state == State.IDLE or _state == State.RINGING


func get_save_block_reason() -> String:
	match _state:
		State.CONNECTED:
			return "通话已接通，不能保存；请先结束通话。"
		State.DIALOGUE_CHOICE:
			return "正在等待对话选择，不能保存；请先作出选择。"
		State.IDLE, State.RINGING:
			return ""
	return "当前电话状态不能保存。"


## 返回仅包含 JSON 标准类型的电话运行时快照。响铃使用相对
## snapshot_current_tick 的 remaining tick，恢复时不会把加载耗时折算进去。
func create_snapshot() -> Dictionary:
	var active_call_snapshot: Variant = null
	if _active_call != null:
		active_call_snapshot = {
			"event_id": _active_call.event_id,
			"caller_name": _active_call.caller_name,
			"caller_number": _active_call.caller_number,
			"ringing_started_tick": _active_call.ringing_started_tick,
			"connected_started_tick": _active_call.connected_started_tick,
			"ringing_ticks_remaining": maxi(_active_call.ringing_deadline_tick - _last_known_game_tick, 0),
		}
	var handled_ids: Array[String] = []
	for event_id_variant: Variant in _handled_event_ids:
		handled_ids.append(String(event_id_variant))
	handled_ids.sort()
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SNAPSHOT_SYSTEM_ID,
		"state": get_state_name(),
		"handled_event_ids": handled_ids,
		"call_records": _call_records.duplicate(true),
		"forced_end": _has_forced_ended,
		"snapshot_current_tick": _last_known_game_tick,
		"active_call": active_call_snapshot,
	}


## 严格校验电话快照。需要 context.current_game_tick 与 context.event_by_id：前者
## 绑定全局时钟，后者用于确认电话记录/来显确实来自当前内容包，而非存档伪造。
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _has_exact_snapshot_fields(
		snapshot,
		PackedStringArray([
			"snapshot_version",
			"system_id",
			"state",
			"handled_event_ids",
			"call_records",
			"forced_end",
			"snapshot_current_tick",
			"active_call",
		])
	):
		return _make_snapshot_error("invalid_fields", "电话快照字段缺失或包含未知字段。")
	var version_result: Dictionary = _read_snapshot_integer(snapshot, "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result["ok"]):
		return version_result
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SNAPSHOT_SYSTEM_ID:
		return _make_snapshot_error("invalid_system_id", "电话快照 system_id 必须为 phone_system。")
	if typeof(snapshot["state"]) != TYPE_STRING or not _SNAPSHOT_STATES.has(String(snapshot["state"])):
		return _make_snapshot_error("invalid_state", "电话快照 state 必须是可持久化的线路状态。")
	if not snapshot["handled_event_ids"] is Array:
		return _make_snapshot_error("invalid_handled_event_ids", "handled_event_ids 必须是数组。")
	if not snapshot["call_records"] is Array:
		return _make_snapshot_error("invalid_call_records", "call_records 必须是数组。")
	if typeof(snapshot["forced_end"]) != TYPE_BOOL:
		return _make_snapshot_error("invalid_forced_end", "forced_end 必须是布尔值。")
	var snapshot_tick_result: Dictionary = _read_snapshot_integer(snapshot, "snapshot_current_tick", 0, MAX_GAME_TICK)
	if not bool(snapshot_tick_result["ok"]):
		return snapshot_tick_result
	var context_result: Dictionary = _validate_snapshot_context(context, int(snapshot_tick_result["value"]))
	if not bool(context_result["ok"]):
		return context_result
	var event_by_id: Dictionary = context_result["event_by_id"] as Dictionary
	var snapshot_tick: int = int(snapshot_tick_result["value"])
	var handled_result: Dictionary = _validate_event_id_array(snapshot["handled_event_ids"] as Array, event_by_id, "handled_event_ids")
	if not bool(handled_result["ok"]):
		return handled_result
	var handled_ids: Array[String] = handled_result["ids"] as Array[String]
	var records_result: Dictionary = _validate_call_records(snapshot["call_records"] as Array, event_by_id, snapshot_tick)
	if not bool(records_result["ok"]):
		return records_result
	var records: Array[Dictionary] = records_result["records"] as Array[Dictionary]
	var record_lookup: Dictionary = records_result["record_lookup"] as Dictionary
	if handled_ids.size() != records.size():
		return _make_snapshot_error("handled_record_count_mismatch", "已处理来电集合必须与真实来电记录一一对应。")
	for handled_event_id: String in handled_ids:
		if not record_lookup.has(handled_event_id):
			return _make_snapshot_error("handled_record_mismatch", "已处理来电 %s 缺少真实记录。" % handled_event_id)

	var state_name: String = String(snapshot["state"])
	var forced_end: bool = bool(snapshot["forced_end"])
	if snapshot_tick < MAX_GAME_TICK and forced_end:
		return _make_snapshot_error("forced_end_before_ending", "02:00 前的电话快照不得设置 forced_end。")
	var active_result: Dictionary = _validate_active_call(
		snapshot["active_call"],
		state_name,
		event_by_id,
		handled_result["lookup"] as Dictionary,
		snapshot_tick
	)
	if not bool(active_result["ok"]):
		return active_result
	var normalized_active: Variant = active_result["active_call"]
	if forced_end and (state_name != "IDLE" or normalized_active != null):
		return _make_snapshot_error("forced_end_active_line", "02:00 强制结束后电话必须为空闲且没有活动线路。")
	for record: Dictionary in records:
		if String(record["outcome"]) == OUTCOME_FORCED_END and not forced_end:
			return _make_snapshot_error("forced_end_record_without_flag", "forced_end 记录必须同时设置 forced_end 状态。")

	return {
		"ok": true,
		"normalized_snapshot": {
			"snapshot_version": SNAPSHOT_VERSION,
			"system_id": SNAPSHOT_SYSTEM_ID,
			"state": state_name,
			"handled_event_ids": handled_ids,
			"call_records": records,
			"forced_end": forced_end,
			"snapshot_current_tick": snapshot_tick,
			"active_call": normalized_active,
		},
	}


## 校验完成前不触碰线路状态；提交恢复时不发送状态变更、记录创建或空闲信号。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation["ok"]):
		return validation
	var normalized: Dictionary = validation["normalized_snapshot"] as Dictionary
	var restored_active_call: PhoneCall = null
	if normalized["active_call"] != null:
		var active_data: Dictionary = normalized["active_call"] as Dictionary
		var restored_deadline: int = int(normalized["snapshot_current_tick"]) + int(active_data["ringing_ticks_remaining"])
		restored_active_call = PhoneCall.new(
			String(active_data["event_id"]),
			String(active_data["caller_name"]),
			String(active_data["caller_number"]),
			int(active_data["ringing_started_tick"]),
			restored_deadline
		)
		restored_active_call.connected_started_tick = int(active_data["connected_started_tick"])
	var restored_handled: Dictionary = {}
	for event_id_variant: Variant in normalized["handled_event_ids"] as Array:
		restored_handled[String(event_id_variant)] = true
	_state = _state_from_snapshot_name(String(normalized["state"]))
	_active_call = restored_active_call
	_call_records = (normalized["call_records"] as Array).duplicate(true)
	_handled_event_ids = restored_handled
	_has_forced_ended = bool(normalized["forced_end"])
	_last_known_game_tick = int(normalized["snapshot_current_tick"])
	return {"ok": true}


## 在边界处校验外部 JSON 事件。调用成功后，任意 Dictionary 不会进入状态机内部。
func begin_incoming_call(call_data: Dictionary, current_tick: int, ring_timeout_ticks: int) -> bool:
	if _has_forced_ended:
		return _fail("<none>", "02:00 收束已执行，不能开始新的来电。")
	if _state != State.IDLE or _active_call != null:
		return _fail(get_active_event_id(), "电话当前不是空闲状态，不能同时接入第二条线路。")
	if current_tick < 0:
		return _fail("<none>", "游戏时间 tick 不能为负数。")
	if ring_timeout_ticks <= 0:
		return _fail("<none>", "响铃超时 tick 必须大于零。")
	_set_last_known_game_tick(current_tick)

	var validated_call: PhoneCall = _validate_and_create_call(call_data, current_tick, ring_timeout_ticks)
	if validated_call == null:
		return false
	if _handled_event_ids.has(validated_call.event_id):
		return _fail(validated_call.event_id, "该来电事件已经结束并生成记录，拒绝重复触发。")

	_active_call = validated_call
	_transition_to(State.RINGING, "事件触发，进入响铃状态。")
	return true


func answer_call(current_tick: int) -> bool:
	if not _require_active_state([State.RINGING], "接听"):
		return false
	if current_tick < _active_call.ringing_started_tick:
		return _fail(_active_call.event_id, "接听时间早于响铃开始时间。")
	_set_last_known_game_tick(current_tick)
	_active_call.connected_started_tick = current_tick
	_transition_to(State.CONNECTED, "玩家接听。")
	return true


func enter_dialogue_choice() -> bool:
	if not _require_active_state([State.CONNECTED], "进入对话选择"):
		return false
	_transition_to(State.DIALOGUE_CHOICE, "对话等待玩家选择。")
	return true


func exit_dialogue_choice() -> bool:
	if not _require_active_state([State.DIALOGUE_CHOICE], "退出对话选择"):
		return false
	_transition_to(State.CONNECTED, "对话选择已提交，恢复通话。")
	return true


## 预制短分支正常结束。已接来电的正常终止结果固定为 answered。
func finish_call(current_tick: int) -> bool:
	if not _require_active_state([State.CONNECTED], "正常结束通话"):
		return false
	return _end_active_call(State.ENDED, OUTCOME_ANSWERED, current_tick, "通话正常结束。")


## 玩家可在接通或选择期间主动挂断；响铃未接属于 missed，不被伪记为 hung_up。
func hang_up(current_tick: int) -> bool:
	if not _require_active_state([State.CONNECTED, State.DIALOGUE_CHOICE], "主动挂断"):
		return false
	return _end_active_call(State.ENDED, OUTCOME_HUNG_UP, current_tick, "玩家主动挂断。")


## 由整数游戏 tick 推进响铃超时。连接和选择不会因为文本阅读自动终止。
func advance_to_tick(current_tick: int) -> bool:
	if current_tick < 0:
		return _fail(get_active_event_id(), "游戏时间 tick 不能为负数。")
	_set_last_known_game_tick(current_tick)
	if _has_forced_ended or _state != State.RINGING or _active_call == null:
		return false
	if current_tick < _active_call.ringing_deadline_tick:
		return false
	return _end_active_call(State.MISSED, OUTCOME_MISSED, current_tick, "响铃超时，记为漏接。")


## 仅供 EventScheduler 在 normal/expire/mark_missed 策略下调用。
## 这通电话从未占用线路，所以不能改变另一条活动线路的全局状态；但记录仍由
## PhoneSystem 在严格校验后生成，且同一 event_id 永远只能写入一次。
func record_expired_call(call_data: Dictionary, current_tick: int) -> bool:
	if _has_forced_ended:
		return _fail("<none>", "02:00 收束已执行，不能为过期事件生成漏接记录。")
	if current_tick < 0:
		return _fail("<none>", "过期来电的游戏时间 tick 不能为负数。")
	_set_last_known_game_tick(current_tick)

	var expired_call: PhoneCall = _validate_and_create_call(call_data, current_tick, 1)
	if expired_call == null:
		return false
	if _handled_event_ids.has(expired_call.event_id):
		return _fail(expired_call.event_id, "该过期来电事件已经生成记录，拒绝重复写入。")
	if _active_call != null and _active_call.event_id == expired_call.event_id:
		return _fail(expired_call.event_id, "活动线路与过期事件 ID 相同，拒绝生成冲突记录。")

	_log(expired_call.event_id, "MISSED", "普通来电在占线期间超过时间窗，生成漏接记录且不影响当前线路。")
	_append_record(expired_call, OUTCOME_MISSED, current_tick, "MISSED")
	return true


## 02:00 的调用可重复执行；首次调用会覆盖任意活动电话，之后不再生成重复记录。
func force_end_at_0200(current_tick: int) -> bool:
	if current_tick < 0:
		return _fail(get_active_event_id(), "02:00 强制收束的游戏时间 tick 不能为负数。")
	_set_last_known_game_tick(current_tick)
	if _has_forced_ended:
		return true
	if _active_call != null and current_tick < _active_call.ringing_started_tick:
		return _fail(_active_call.event_id, "02:00 强制收束时间早于当前来电的响铃开始时间。")

	_has_forced_ended = true
	if _active_call == null:
		_log("<none>", "IDLE", "02:00 强制收束已执行，当前没有活动线路。")
		return true

	return _end_active_call(State.ENDED, OUTCOME_FORCED_END, current_tick, "02:00 强制收束中断当前线路。")


func _validate_and_create_call(call_data: Dictionary, current_tick: int, ring_timeout_ticks: int) -> PhoneCall:
	if not call_data.has("id"):
		_fail("<unknown>", "电话事件校验失败：缺少必填字段 id。")
		return null
	var raw_event_id: Variant = call_data["id"]
	if not raw_event_id is String:
		_fail("<unknown>", "电话事件校验失败：字段 id 必须是字符串。")
		return null
	var event_id: String = raw_event_id
	if event_id.is_empty() or not event_id.is_valid_identifier() or event_id != event_id.to_lower():
		_fail(event_id, "电话事件校验失败：字段 id 必须是非空英文 snake_case 稳定 ID。")
		return null

	var caller_name: String = _read_required_nonempty_string(call_data, "caller_display_name", event_id)
	if caller_name.is_empty():
		return null
	var caller_number: String = _read_required_nonempty_string(call_data, "caller_number", event_id)
	if caller_number.is_empty():
		return null

	return PhoneCall.new(
		event_id,
		caller_name,
		caller_number,
		current_tick,
		current_tick + ring_timeout_ticks
	)


func _read_required_nonempty_string(call_data: Dictionary, field_name: String, event_id: String) -> String:
	if not call_data.has(field_name):
		_fail(event_id, "电话事件校验失败：缺少必填字段 %s。" % field_name)
		return ""
	var value: Variant = call_data[field_name]
	if not value is String:
		_fail(event_id, "电话事件校验失败：字段 %s 必须是字符串。" % field_name)
		return ""
	var text: String = value
	if text.strip_edges().is_empty():
		_fail(event_id, "电话事件校验失败：字段 %s 不能是空白文本。" % field_name)
		return ""
	return text


func _require_active_state(allowed_states: Array[State], action_name: String) -> bool:
	if _active_call == null:
		return _fail("<none>", "%s失败：当前没有活动线路，状态=%s。" % [action_name, get_state_name()])
	if not allowed_states.has(_state):
		return _fail(
			_active_call.event_id,
			"%s失败：状态=%s 不允许此操作。" % [action_name, get_state_name()]
		)
	return true


func _end_active_call(terminal_state: State, outcome: String, current_tick: int, reason: String) -> bool:
	if _active_call == null:
		return _fail("<none>", "结束线路失败：当前没有活动线路。")
	if current_tick < _active_call.ringing_started_tick:
		return _fail(_active_call.event_id, "结束时间早于响铃开始时间。")
	_set_last_known_game_tick(current_tick)

	var ending_call: PhoneCall = _active_call
	_transition_to(terminal_state, reason)
	_append_record(ending_call, outcome, current_tick)
	_active_call = null
	_transition_to(State.IDLE, "终态记录已生成，线路恢复空闲。", ending_call.event_id)
	call_became_idle.emit(ending_call.event_id)
	return true


func _append_record(ending_call: PhoneCall, outcome: String, current_tick: int, record_state_name: String = "") -> void:
	if _handled_event_ids.has(ending_call.event_id):
		_fail(ending_call.event_id, "内部错误：同一来电事件尝试生成第二条记录。")
		return

	var duration_start_tick: int = ending_call.ringing_started_tick
	if ending_call.connected_started_tick != INVALID_TICK:
		duration_start_tick = ending_call.connected_started_tick
	var record: Dictionary = {
		"event_id": ending_call.event_id,
		"time": ending_call.ringing_started_tick,
		"caller_name": ending_call.caller_name,
		"caller_number": ending_call.caller_number,
		"outcome": outcome,
		"duration_ticks": current_tick - duration_start_tick,
	}
	_handled_event_ids[ending_call.event_id] = true
	_call_records.append(record)
	var log_state_name: String = record_state_name
	if log_state_name.is_empty():
		log_state_name = get_state_name()
	_log(ending_call.event_id, log_state_name, "来电记录已生成，outcome=%s。" % outcome)
	call_record_created.emit(record.duplicate(true))


func _transition_to(next_state: State, reason: String, event_id_override: String = "") -> void:
	var previous_state: State = _state
	if not _is_legal_transition(previous_state, next_state):
		_fail(get_active_event_id(), "内部错误：非法状态转移 %s -> %s。" % [State.keys()[previous_state], State.keys()[next_state]])
		return
	_state = next_state
	var transition_event_id: String = event_id_override
	if transition_event_id.is_empty():
		transition_event_id = get_active_event_id()
	_log(transition_event_id, State.keys()[next_state], "%s %s -> %s。" % [reason, State.keys()[previous_state], State.keys()[next_state]])
	state_changed.emit(previous_state, next_state, transition_event_id)


func _is_legal_transition(previous_state: State, next_state: State) -> bool:
	match previous_state:
		State.IDLE:
			return next_state == State.RINGING
		State.RINGING:
			return next_state == State.CONNECTED or next_state == State.MISSED or next_state == State.ENDED
		State.CONNECTED:
			return next_state == State.DIALOGUE_CHOICE or next_state == State.ENDED
		State.DIALOGUE_CHOICE:
			return next_state == State.CONNECTED or next_state == State.ENDED
		State.ENDED, State.MISSED:
			return next_state == State.IDLE
	return false


func _fail(event_id: String, message: String) -> bool:
	_last_error = message
	var state_name: String = get_state_name()
	printerr("[电话][%s][%s] %s" % [event_id, state_name, message])
	phone_error.emit(event_id, message)
	return false


func _log(event_id: String, state_name: String, message: String) -> void:
	print("[电话][%s][%s] %s" % [event_id, state_name, message])


func _validate_snapshot_context(context: Dictionary, expected_tick: int) -> Dictionary:
	if not context.has("current_game_tick"):
		return _make_snapshot_error("missing_context_current_game_tick", "电话恢复上下文缺少 current_game_tick。")
	var tick_context: Dictionary = {"current_game_tick": context["current_game_tick"]}
	var context_tick_result: Dictionary = _read_snapshot_integer(tick_context, "current_game_tick", 0, MAX_GAME_TICK)
	if not bool(context_tick_result["ok"]):
		return _make_snapshot_error("invalid_context_current_game_tick", "电话恢复上下文 current_game_tick 必须是有效游戏 tick。")
	if int(context_tick_result["value"]) != expected_tick:
		return _make_snapshot_error("context_tick_mismatch", "电话快照 tick 必须与 GameClock 当前 tick 完全一致。")
	if not context.has("event_by_id") or not context["event_by_id"] is Dictionary:
		return _make_snapshot_error("missing_context_event_by_id", "电话恢复上下文必须提供当前内容的 event_by_id。")
	var event_by_id: Dictionary = context["event_by_id"] as Dictionary
	for event_id_variant: Variant in event_by_id:
		if typeof(event_id_variant) != TYPE_STRING or not event_by_id[event_id_variant] is Dictionary:
			return _make_snapshot_error("invalid_context_event_by_id", "event_by_id 必须使用字符串 ID 映射事件对象。")
		var event_id: String = String(event_id_variant)
		var call_validation: Dictionary = _validate_context_event_metadata(event_id, event_by_id[event_id] as Dictionary)
		if not bool(call_validation["ok"]):
			return call_validation
	return {"ok": true, "event_by_id": event_by_id}


func _validate_context_event_metadata(event_id: String, event_data: Dictionary) -> Dictionary:
	if not event_data.has("id") or typeof(event_data["id"]) != TYPE_STRING or String(event_data["id"]) != event_id:
		return _make_snapshot_error("invalid_context_event", "恢复上下文事件 %s 的 id 不匹配。" % event_id)
	if not event_data.has("caller_display_name") or typeof(event_data["caller_display_name"]) != TYPE_STRING:
		return _make_snapshot_error("invalid_context_caller_name", "恢复上下文事件 %s 缺少 caller_display_name。" % event_id)
	if not event_data.has("caller_number") or typeof(event_data["caller_number"]) != TYPE_STRING:
		return _make_snapshot_error("invalid_context_caller_number", "恢复上下文事件 %s 缺少 caller_number。" % event_id)
	if String(event_data["caller_display_name"]).strip_edges().is_empty() or String(event_data["caller_number"]).strip_edges().is_empty():
		return _make_snapshot_error("empty_context_caller_metadata", "恢复上下文事件 %s 的来显信息不能为空。" % event_id)
	return {"ok": true}


func _validate_event_id_array(raw_ids: Array, event_by_id: Dictionary, field_name: String) -> Dictionary:
	var ids: Array[String] = []
	var lookup: Dictionary = {}
	for raw_event_id: Variant in raw_ids:
		if typeof(raw_event_id) != TYPE_STRING:
			return _make_snapshot_error("invalid_%s" % field_name, "%s 中的事件 ID 必须是字符串。" % field_name)
		var event_id: String = String(raw_event_id)
		if not event_by_id.has(event_id) and not _is_delivery_call_id(event_id):
			return _make_snapshot_error("unknown_event_id", "%s 包含既非 authored event 也非 Delivery call 的事件 %s。" % [field_name, event_id])
		if lookup.has(event_id):
			return _make_snapshot_error("duplicate_event_id", "%s 不能包含重复事件 %s。" % [field_name, event_id])
		lookup[event_id] = true
		ids.append(event_id)
	return {"ok": true, "ids": ids, "lookup": lookup}


func _validate_call_records(raw_records: Array, event_by_id: Dictionary, snapshot_tick: int) -> Dictionary:
	var normalized_records: Array[Dictionary] = []
	var record_lookup: Dictionary = {}
	for raw_record: Variant in raw_records:
		if not raw_record is Dictionary:
			return _make_snapshot_error("invalid_call_record", "call_records 中的每一项必须是对象。")
		var record: Dictionary = raw_record as Dictionary
		if not _has_exact_snapshot_fields(
			record,
			PackedStringArray(["event_id", "time", "caller_name", "caller_number", "outcome", "duration_ticks"])
		):
			return _make_snapshot_error("invalid_call_record_fields", "来电记录字段缺失或包含未知字段。")
		if typeof(record["event_id"]) != TYPE_STRING:
			return _make_snapshot_error("invalid_record_event_id", "来电记录 event_id 必须是字符串。")
		var event_id: String = String(record["event_id"])
		if not event_by_id.has(event_id) and not _is_delivery_call_id(event_id):
			return _make_snapshot_error("unknown_record_event_id", "来电记录引用了既非 authored event 也非 Delivery call 的事件 %s。" % event_id)
		if record_lookup.has(event_id):
			return _make_snapshot_error("duplicate_record_event_id", "同一事件 %s 不能拥有两条来电记录。" % event_id)
		if typeof(record["caller_name"]) != TYPE_STRING or String(record["caller_name"]).strip_edges().is_empty():
			return _make_snapshot_error("invalid_record_caller_name", "来电记录 caller_name 必须是非空字符串。")
		if typeof(record["caller_number"]) != TYPE_STRING or String(record["caller_number"]).strip_edges().is_empty():
			return _make_snapshot_error("invalid_record_caller_number", "来电记录 caller_number 必须是非空字符串。")
		if typeof(record["outcome"]) != TYPE_STRING or not _SNAPSHOT_OUTCOMES.has(String(record["outcome"])):
			return _make_snapshot_error("invalid_record_outcome", "来电记录 outcome 不受支持。")
		var time_result: Dictionary = _read_snapshot_integer(record, "time", 0, snapshot_tick)
		if not bool(time_result["ok"]):
			return time_result
		var duration_result: Dictionary = _read_snapshot_integer(record, "duration_ticks", 0, snapshot_tick - int(time_result["value"]))
		if not bool(duration_result["ok"]):
			return duration_result
		if event_by_id.has(event_id):
			var expected_event: Dictionary = event_by_id[event_id] as Dictionary
			if String(record["caller_name"]) != String(expected_event["caller_display_name"]) or String(record["caller_number"]) != String(expected_event["caller_number"]):
				return _make_snapshot_error("record_caller_metadata_mismatch", "来电记录 %s 的来显与当前内容不一致。" % event_id)
		var normalized_record: Dictionary = {
			"event_id": event_id,
			"time": int(time_result["value"]),
			"caller_name": String(record["caller_name"]),
			"caller_number": String(record["caller_number"]),
			"outcome": String(record["outcome"]),
			"duration_ticks": int(duration_result["value"]),
		}
		record_lookup[event_id] = true
		normalized_records.append(normalized_record)
	return {"ok": true, "records": normalized_records, "record_lookup": record_lookup}


func _validate_active_call(
	raw_active_call: Variant,
	state_name: String,
	event_by_id: Dictionary,
	handled_lookup: Dictionary,
	snapshot_tick: int
) -> Dictionary:
	if state_name == "IDLE":
		if raw_active_call != null:
			return _make_snapshot_error("idle_active_call_conflict", "空闲电话快照不得携带活动线路。")
		return {"ok": true, "active_call": null}
	if not raw_active_call is Dictionary:
		return _make_snapshot_error("missing_active_call", "活动电话状态必须携带 active_call 对象。")
	var active_call: Dictionary = raw_active_call as Dictionary
	if not _has_exact_snapshot_fields(
		active_call,
		PackedStringArray([
			"event_id",
			"caller_name",
			"caller_number",
			"ringing_started_tick",
			"connected_started_tick",
			"ringing_ticks_remaining",
		])
	):
		return _make_snapshot_error("invalid_active_call_fields", "active_call 字段缺失或包含未知字段。")
	if typeof(active_call["event_id"]) != TYPE_STRING:
		return _make_snapshot_error("invalid_active_event_id", "活动线路 event_id 必须是字符串。")
	var event_id: String = String(active_call["event_id"])
	if not event_by_id.has(event_id) and not _is_delivery_call_id(event_id):
		return _make_snapshot_error("unknown_active_event_id", "活动线路引用了既非 authored event 也非 Delivery call 的事件 %s。" % event_id)
	if handled_lookup.has(event_id):
		return _make_snapshot_error("active_handled_conflict", "活动线路 %s 不能同时标记为已处理。" % event_id)
	if typeof(active_call["caller_name"]) != TYPE_STRING or typeof(active_call["caller_number"]) != TYPE_STRING:
		return _make_snapshot_error("invalid_active_caller_metadata", "活动线路来显必须是字符串。")
	if event_by_id.has(event_id):
		var expected_event: Dictionary = event_by_id[event_id] as Dictionary
		if String(active_call["caller_name"]) != String(expected_event["caller_display_name"]) or String(active_call["caller_number"]) != String(expected_event["caller_number"]):
			return _make_snapshot_error("active_caller_metadata_mismatch", "活动线路 %s 的来显与当前内容不一致。" % event_id)
	var ringing_start_result: Dictionary = _read_snapshot_integer(active_call, "ringing_started_tick", 0, snapshot_tick)
	if not bool(ringing_start_result["ok"]):
		return ringing_start_result
	var connected_start_result: Dictionary = _read_snapshot_integer(active_call, "connected_started_tick", INVALID_TICK, snapshot_tick)
	if not bool(connected_start_result["ok"]):
		return connected_start_result
	var remaining_result: Dictionary = _read_snapshot_integer(active_call, "ringing_ticks_remaining", 0, MAX_GAME_TICK - snapshot_tick)
	if not bool(remaining_result["ok"]):
		return remaining_result
	var ringing_start: int = int(ringing_start_result["value"])
	var connected_start: int = int(connected_start_result["value"])
	var remaining_ticks: int = int(remaining_result["value"])
	if state_name == "RINGING":
		if connected_start != INVALID_TICK or remaining_ticks <= 0:
			return _make_snapshot_error("invalid_ringing_state", "RINGING 快照必须未接通且保留大于零的响铃 tick。")
	else:
		if connected_start < ringing_start:
			return _make_snapshot_error("invalid_connected_state", "已接通线路的 connected_started_tick 不能早于响铃开始。")
	return {
		"ok": true,
		"active_call": {
			"event_id": event_id,
			"caller_name": String(active_call["caller_name"]),
			"caller_number": String(active_call["caller_number"]),
			"ringing_started_tick": ringing_start,
			"connected_started_tick": connected_start,
			"ringing_ticks_remaining": remaining_ticks,
		},
	}


func _state_from_snapshot_name(state_name: String) -> State:
	match state_name:
		"IDLE":
			return State.IDLE
		"RINGING":
			return State.RINGING
		"CONNECTED":
			return State.CONNECTED
		"DIALOGUE_CHOICE":
			return State.DIALOGUE_CHOICE
	# validate_snapshot 已筛掉未知值；此处保留明确回退仅防止内部契约被绕开。
	return State.IDLE


func _set_last_known_game_tick(current_tick: int) -> void:
	_last_known_game_tick = current_tick


## PhoneSystem 只做动态 Delivery ID 的结构放行；它不知道这条 Delivery 是否真实存在。
## StoryEngine 在恢复剧情 snapshot 时会把所有 delivery_call_* 与 DeliverySystem committed state 交叉校验。
func _is_delivery_call_id(event_id: String) -> bool:
	return event_id.begins_with("delivery_call_") and event_id.is_valid_identifier() and event_id == event_id.to_lower()


func _has_exact_snapshot_fields(snapshot: Dictionary, required_fields: PackedStringArray) -> bool:
	if snapshot.size() != required_fields.size():
		return false
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return false
	return true


func _read_snapshot_integer(snapshot: Dictionary, field_name: String, minimum: int, maximum: int) -> Dictionary:
	if not snapshot.has(field_name):
		return _make_snapshot_error("missing_%s" % field_name, "电话快照缺少字段 %s。" % field_name)
	var raw_value: Variant = snapshot[field_name]
	if typeof(raw_value) != TYPE_INT and typeof(raw_value) != TYPE_FLOAT:
		return _make_snapshot_error("invalid_%s" % field_name, "电话快照字段 %s 必须是整数。" % field_name)
	var numeric_value: float = float(raw_value)
	if not is_finite(numeric_value) or floor(numeric_value) != numeric_value:
		return _make_snapshot_error("invalid_%s" % field_name, "电话快照字段 %s 必须是有限整数。" % field_name)
	var integer_value: int = int(numeric_value)
	if integer_value < minimum or integer_value > maximum:
		return _make_snapshot_error("out_of_range_%s" % field_name, "电话快照字段 %s 超出允许范围。" % field_name)
	return {"ok": true, "value": integer_value}


func _make_snapshot_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
