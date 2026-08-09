## 管理时间窗事件的最小调度器。
##
## 时间单位是相对 01:00 的完整游戏分钟；02:00 由 StoryEngine 单独强制处理，
## 因而永远不会作为普通事件进入本调度器。
extends RefCounted
class_name EventScheduler

signal event_queued(event: Dictionary)
signal event_ready(event: Dictionary)
signal event_expired(event: Dictionary)
signal scheduler_error(event_id: String, error_code: String, message: String)

const ENDING_EVENT_ID: String = "ending_forced"
const SHIFT_DURATION_MINUTES: int = 60

const _SUPPORTED_KINDS: PackedStringArray = ["incoming_call"]
const _SUPPORTED_PRIORITIES: PackedStringArray = ["main", "normal"]
const _SUPPORTED_BUSY_POLICIES: PackedStringArray = ["queue", "expire"]
const _SUPPORTED_EXPIRY_POLICIES: PackedStringArray = ["mark_missed"]
var _events_by_id: Dictionary = {}
var _pending_event_ids: Array[String] = []
var _queued_items: Array[Dictionary] = []
var _event_status_by_id: Dictionary = {}
## 条件来电只有在窗口内至少一次满足所有条件后才成为真实电话。
## 从未取得资格的事件必须安静失效，不能伪造成玩家漏接。
var _condition_eligible_event_ids: Dictionary = {}
var _schedule_sequence: int = 0
var _queue_sequence: int = 0
var _last_processed_minute: int = 0
var _is_ending_forced: bool = false


## 注册单个事件。事件数据错误时不改变既有调度状态。
func schedule_event(event_data: Dictionary) -> Dictionary:
	var validation: Dictionary = validate_event(event_data)
	if not bool(validation["ok"]):
		return validation

	if _is_ending_forced:
		return _make_error(String(event_data["id"]), "ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")

	var event_id: String = String(event_data["id"])
	if _events_by_id.has(event_id):
		return _make_error(event_id, "duplicate_event_id", "事件 ID 已被注册，不能重复调度。")

	var stored_event: Dictionary = event_data.duplicate(true)
	stored_event["_schedule_sequence"] = _schedule_sequence
	_schedule_sequence += 1
	_events_by_id[event_id] = stored_event
	_pending_event_ids.append(event_id)
	_event_status_by_id[event_id] = "scheduled"
	print("[事件][%s] 已注册，窗口 %d-%d 分钟。" % [event_id, int(stored_event["window_start_minute"]), int(stored_event["window_end_minute"])])
	return {"ok": true, "event_id": event_id}


## 原子注册一批事件。任一条无效时整批不写入，避免半损坏的内容状态。
func schedule_events(event_definitions: Array) -> Dictionary:
	if _is_ending_forced:
		return _make_error("", "ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")

	var seen_ids: Dictionary = {}
	for raw_event: Variant in event_definitions:
		if not raw_event is Dictionary:
			return _make_error("", "invalid_event_type", "事件条目必须是 Dictionary。")
		var event_data: Dictionary = raw_event
		var validation: Dictionary = validate_event(event_data)
		if not bool(validation["ok"]):
			return validation
		var event_id: String = String(event_data["id"])
		if seen_ids.has(event_id) or _events_by_id.has(event_id):
			return _make_error(event_id, "duplicate_event_id", "事件 ID 已存在或在当前批次中重复。")
		seen_ids[event_id] = true

	for raw_event: Variant in event_definitions:
		var result: Dictionary = schedule_event(raw_event as Dictionary)
		if not bool(result["ok"]):
			# 此处在前置完整校验后仍失败代表内部契约被破坏，不能伪装为成功。
			return result
	return {"ok": true, "scheduled_count": event_definitions.size()}


## 校验外部内容事件的完整结构与受支持策略。
func validate_event(event_data: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = [
		"id",
		"kind",
		"priority",
		"window_start_minute",
		"window_end_minute",
		"when_busy",
		"on_expire",
		"condition_ids",
	]
	for field_name: String in required_fields:
		if not event_data.has(field_name):
			return _make_error("", "missing_field", "事件缺少必填字段：%s。" % field_name, field_name)

	var event_id: String = ""
	if typeof(event_data["id"]) == TYPE_STRING:
		event_id = String(event_data["id"])
	if event_id.is_empty() or event_id.begins_with("_") or event_id != event_id.to_lower() or not event_id.is_valid_identifier() or not event_id.is_valid_ascii_identifier():
		return _make_error(event_id, "invalid_event_id", "事件 ID 必须是英文 snake_case 标识符。", "id")
	if event_id == ENDING_EVENT_ID:
		return _make_error(event_id, "reserved_event_id", "ending_forced 只能由 02:00 强制收束生成，不能作为普通事件。", "id")

	if typeof(event_data["kind"]) != TYPE_STRING or not _SUPPORTED_KINDS.has(String(event_data["kind"])):
		return _make_error(event_id, "invalid_kind", "kind 必须是受支持的事件类型：incoming_call。", "kind")
	if typeof(event_data["priority"]) != TYPE_STRING or not _SUPPORTED_PRIORITIES.has(String(event_data["priority"])):
		return _make_error(event_id, "invalid_priority", "priority 必须是 main 或 normal。", "priority")
	if typeof(event_data["when_busy"]) != TYPE_STRING or not _SUPPORTED_BUSY_POLICIES.has(String(event_data["when_busy"])):
		return _make_error(event_id, "invalid_when_busy", "when_busy 必须是 queue 或 expire。", "when_busy")
	if typeof(event_data["on_expire"]) != TYPE_STRING or not _SUPPORTED_EXPIRY_POLICIES.has(String(event_data["on_expire"])):
		return _make_error(event_id, "invalid_on_expire", "on_expire 必须是 mark_missed。", "on_expire")
	if String(event_data["priority"]) == "main" and String(event_data["when_busy"]) != "queue":
		return _make_error(event_id, "main_event_must_queue", "主线事件占线时必须使用 queue 策略。", "when_busy")

	if typeof(event_data["window_start_minute"]) != TYPE_INT:
		return _make_error(event_id, "invalid_window_start", "window_start_minute 必须是整数分钟。", "window_start_minute")
	if typeof(event_data["window_end_minute"]) != TYPE_INT:
		return _make_error(event_id, "invalid_window_end", "window_end_minute 必须是整数分钟。", "window_end_minute")
	var window_start: int = int(event_data["window_start_minute"])
	var window_end: int = int(event_data["window_end_minute"])
	if window_start < 0 or window_end < window_start or window_end >= SHIFT_DURATION_MINUTES:
		return _make_error(event_id, "invalid_time_window", "事件时间窗必须满足 0 <= 开始 <= 结束 < 60。", "window_start_minute/window_end_minute")

	if not event_data["condition_ids"] is Array:
		return _make_error(event_id, "invalid_condition_ids", "condition_ids 必须是数组。", "condition_ids")
	for condition_id_variant: Variant in event_data["condition_ids"]:
		if typeof(condition_id_variant) != TYPE_STRING:
			return _make_error(event_id, "invalid_condition_id", "condition_ids 中的每一项必须是字符串。", "condition_ids")
		var condition_id: String = String(condition_id_variant)
		if condition_id.is_empty() or condition_id.begins_with("_") or condition_id != condition_id.to_lower() or not condition_id.is_valid_identifier() or not condition_id.is_valid_ascii_identifier():
			return _make_error(event_id, "invalid_condition_id", "condition_ids 必须使用英文 snake_case 标识符。", "condition_ids")

	return {"ok": true}


## 推进到指定游戏内分钟，并返回本次可立即派发的事件（至多一条）。
##
## 条件检查器接收 condition_id 并返回 bool。条件来电必须在窗口内至少一次
## 取得资格；从未满足条件而越窗的条目不是电话事件，不生成漏接记录。
func advance_to_minute(current_minute: int, is_busy: bool, condition_checker: Callable = Callable()) -> Dictionary:
	if _is_ending_forced:
		return _make_error("", "ending_forced", "02:00 强制收束已发生，不再推进普通事件。")
	if current_minute < _last_processed_minute:
		return _make_error("", "time_reversed", "事件调度时间不能倒退。")
	if current_minute < 0:
		return _make_error("", "invalid_current_minute", "当前游戏分钟不能小于 0。")
	if current_minute >= SHIFT_DURATION_MINUTES:
		return _make_error("", "ending_time_reached", "已到 02:00；必须由 StoryEngine 执行 ending_forced，而非继续调度普通事件。")

	_last_processed_minute = current_minute
	# 先在当前窗口内写入资格，再处理超窗；避免“从未解锁”走入 mark_missed。
	for event_id: String in _pending_event_ids:
		var eligibility_event: Dictionary = _events_by_id[event_id]
		if current_minute < int(eligibility_event["window_start_minute"]) or current_minute > int(eligibility_event["window_end_minute"]):
			continue
		if (eligibility_event["condition_ids"] as Array).is_empty() or _conditions_are_met(eligibility_event, condition_checker):
			_condition_eligible_event_ids[event_id] = true

	var expired_events: Array[Dictionary] = []
	for event_id: String in _pending_event_ids.duplicate():
		var event_data: Dictionary = _events_by_id[event_id]
		if current_minute > int(event_data["window_end_minute"]):
			if not (event_data["condition_ids"] as Array).is_empty() and not _condition_eligible_event_ids.has(event_id):
				_suppress_unqualified_conditional_event(event_id)
				continue
			expired_events.append(_expire_event(event_id, event_data))

	var due_events: Array[Dictionary] = []
	for event_id: String in _pending_event_ids:
		var event_data: Dictionary = _events_by_id[event_id]
		if current_minute < int(event_data["window_start_minute"]):
			continue
		if not _condition_eligible_event_ids.has(event_id):
			continue
		due_events.append(event_data)
	due_events.sort_custom(_sort_by_priority_then_schedule)

	var ready_events: Array[Dictionary] = []
	var effectively_busy: bool = is_busy
	for event_data: Dictionary in due_events:
		var event_id: String = String(event_data["id"])
		if not _pending_event_ids.has(event_id):
			continue
		if not effectively_busy:
			_pending_event_ids.erase(event_id)
			_condition_eligible_event_ids.erase(event_id)
			_event_status_by_id[event_id] = "triggered"
			var ready_event: Dictionary = _public_event_copy(event_data)
			ready_events.append(ready_event)
			event_ready.emit(ready_event)
			print("[事件][%s] 已触发，电话当前空闲，进入响铃状态。" % event_id)
			effectively_busy = true
		elif String(event_data["when_busy"]) == "queue":
			_enqueue_event(event_id, event_data)

	return {"ok": true, "ready_events": ready_events, "expired_events": expired_events}


## 仅在电话返回空闲时取出一个待触发主线/队列事件。
func take_next_queued_event() -> Dictionary:
	if _is_ending_forced:
		return _make_error("", "ending_forced", "02:00 强制收束已发生，队列已清空。")
	if _queued_items.is_empty():
		return {"ok": true, "has_event": false}

	var queue_item: Dictionary = _queued_items.pop_front()
	var event_data: Dictionary = queue_item["event"]
	var event_id: String = String(event_data["id"])
	_event_status_by_id[event_id] = "triggered"
	var ready_event: Dictionary = _public_event_copy(event_data)
	event_ready.emit(ready_event)
	print("[事件][%s] 从待触发队列取出，进入响铃状态。" % event_id)
	return {"ok": true, "has_event": true, "event": ready_event}


## 02:00 调用此方法。它只清除未触发/排队事件，不把它们伪造成漏接。
func force_ending() -> Dictionary:
	if _is_ending_forced:
		return {"ok": true, "already_forced": true, "cleared_pending_count": 0, "cleared_queue_count": 0}
	var cleared_pending_count: int = _pending_event_ids.size()
	var cleared_queue_count: int = _queued_items.size()
	for event_id: String in _pending_event_ids:
		_event_status_by_id[event_id] = "cleared_for_ending"
	for queue_item: Dictionary in _queued_items:
		var event_data: Dictionary = queue_item["event"]
		_event_status_by_id[String(event_data["id"])] = "cleared_for_ending"
	_pending_event_ids.clear()
	_condition_eligible_event_ids.clear()
	_queued_items.clear()
	_is_ending_forced = true
	print("[事件][ending_forced] 02:00 强制收束，已清空待处理 %d 项、队列 %d 项。" % [cleared_pending_count, cleared_queue_count])
	return {"ok": true, "already_forced": false, "cleared_pending_count": cleared_pending_count, "cleared_queue_count": cleared_queue_count}


func is_ending_forced() -> bool:
	return _is_ending_forced


func get_event_status(event_id: String) -> String:
	if not _event_status_by_id.has(event_id):
		return "unknown"
	return String(_event_status_by_id[event_id])


func get_queued_events() -> Array[Dictionary]:
	var queued_events: Array[Dictionary] = []
	for queue_item: Dictionary in _queued_items:
		queued_events.append(_public_event_copy(queue_item["event"] as Dictionary))
	return queued_events


func get_pending_event_ids() -> Array[String]:
	return _pending_event_ids.duplicate()


func _conditions_are_met(event_data: Dictionary, condition_checker: Callable) -> bool:
	for condition_id_variant: Variant in event_data["condition_ids"]:
		var condition_id: String = String(condition_id_variant)
		if not condition_checker.is_valid():
			print("[事件][%s] 条件 %s 未提供检查器，当前不触发。" % [String(event_data["id"]), condition_id])
			return false
		var condition_result: Variant = condition_checker.call(condition_id)
		if typeof(condition_result) != TYPE_BOOL:
			var message: String = "条件检查器必须返回 bool，当前返回 %s。" % type_string(typeof(condition_result))
			scheduler_error.emit(String(event_data["id"]), "invalid_condition_result", message)
			push_error("[事件][%s] %s" % [String(event_data["id"]), message])
			return false
		if not bool(condition_result):
			print("[事件][%s] 条件 %s 未满足，本分钟不触发。" % [String(event_data["id"]), condition_id])
			return false
	return true


func _enqueue_event(event_id: String, event_data: Dictionary) -> void:
	_pending_event_ids.erase(event_id)
	_condition_eligible_event_ids.erase(event_id)
	_event_status_by_id[event_id] = "queued"
	var queue_item: Dictionary = {
		"event": event_data.duplicate(true),
		"queue_sequence": _queue_sequence,
	}
	_queue_sequence += 1
	var insert_index: int = _queued_items.size()
	for index: int in range(_queued_items.size()):
		if _sort_queue_items(queue_item, _queued_items[index]):
			insert_index = index
			break
	_queued_items.insert(insert_index, queue_item)
	var queued_event: Dictionary = _public_event_copy(event_data)
	event_queued.emit(queued_event)
	print("[事件][%s] 电话占线，已进入待触发队列。" % event_id)


func _expire_event(event_id: String, event_data: Dictionary) -> Dictionary:
	_pending_event_ids.erase(event_id)
	_condition_eligible_event_ids.erase(event_id)
	_event_status_by_id[event_id] = "expired"
	var expired_event: Dictionary = _public_event_copy(event_data)
	event_expired.emit(expired_event)
	print("[事件][%s] 时间窗已过期，执行 mark_missed。" % event_id)
	return expired_event


func _suppress_unqualified_conditional_event(event_id: String) -> void:
	_pending_event_ids.erase(event_id)
	_condition_eligible_event_ids.erase(event_id)
	_event_status_by_id[event_id] = "suppressed_condition_unmet"
	print("[事件][%s] 条件在窗口内从未满足，事件安静失效，不生成漏接记录。" % event_id)


func _sort_by_priority_then_schedule(first: Dictionary, second: Dictionary) -> bool:
	var first_priority: int = _priority_rank(String(first["priority"]))
	var second_priority: int = _priority_rank(String(second["priority"]))
	if first_priority != second_priority:
		return first_priority < second_priority
	return int(first["_schedule_sequence"]) < int(second["_schedule_sequence"])


func _sort_queue_items(first: Dictionary, second: Dictionary) -> bool:
	var first_event: Dictionary = first["event"]
	var second_event: Dictionary = second["event"]
	var first_priority: int = _priority_rank(String(first_event["priority"]))
	var second_priority: int = _priority_rank(String(second_event["priority"]))
	if first_priority != second_priority:
		return first_priority < second_priority
	return int(first["queue_sequence"]) < int(second["queue_sequence"])


func _priority_rank(priority: String) -> int:
	if priority == "main":
		return 0
	return 1


func _public_event_copy(event_data: Dictionary) -> Dictionary:
	var event_copy: Dictionary = event_data.duplicate(true)
	event_copy.erase("_schedule_sequence")
	return event_copy


func _make_error(event_id: String, error_code: String, message: String, field_name: String = "") -> Dictionary:
	var suffix: String = ""
	if not field_name.is_empty():
		suffix = " 字段：%s。" % field_name
	var full_message: String = "%s%s" % [message, suffix]
	scheduler_error.emit(event_id, error_code, full_message)
	push_error("[事件][%s][%s] %s" % [event_id, error_code, full_message])
	return {"ok": false, "event_id": event_id, "error_code": error_code, "message": full_message}
