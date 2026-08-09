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

var _state: State = State.IDLE
var _active_call: PhoneCall = null
var _call_records: Array[Dictionary] = []
var _handled_event_ids: Dictionary = {}
var _has_forced_ended: bool = false
var _last_error: String = ""


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
