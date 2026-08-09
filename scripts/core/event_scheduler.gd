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
const SNAPSHOT_VERSION: int = 1
const SNAPSHOT_SYSTEM_ID: String = "event_scheduler"

const _SNAPSHOT_EVENT_STATUSES: PackedStringArray = [
	"scheduled",
	"triggered",
	"queued",
	"expired",
	"suppressed_condition_unmet",
	"cleared_for_ending",
]

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


## 供存档编排层构造 PhoneSystem 恢复上下文。事件定义本身不写入调度器快照。
func get_configured_events_by_id() -> Dictionary:
	var public_events: Dictionary = {}
	for event_id_variant: Variant in _events_by_id:
		var event_id: String = String(event_id_variant)
		public_events[event_id] = _public_event_copy(_events_by_id[event_id] as Dictionary)
	return public_events


## 返回仅包含 JSON 标准类型的调度器运行时快照。事件定义由当前内容包负责。
func create_snapshot() -> Dictionary:
	var queued_items: Array[Dictionary] = []
	for queue_item: Dictionary in _queued_items:
		var event_data: Dictionary = queue_item["event"] as Dictionary
		queued_items.append({
			"event_id": String(event_data["id"]),
			"queue_sequence": int(queue_item["queue_sequence"]),
		})
	var eligible_ids: Array[String] = []
	for event_id_variant: Variant in _condition_eligible_event_ids:
		eligible_ids.append(String(event_id_variant))
	eligible_ids.sort()
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SNAPSHOT_SYSTEM_ID,
		"event_status_by_id": _event_status_by_id.duplicate(true),
		"pending_event_ids": _pending_event_ids.duplicate(),
		"queued_items": queued_items,
		"condition_eligible_event_ids": eligible_ids,
		"schedule_sequence": _schedule_sequence,
		"queue_sequence": _queue_sequence,
		"last_processed_minute": _last_processed_minute,
		"ending_forced": _is_ending_forced,
	}


## 严格校验调度器动态状态。context.event_by_id 可显式传入 StoryEngine 已验证的
## 内容映射；省略时使用本 Scheduler 已配置的事件。无论哪一种，恢复对象本身
## 都必须已经按照当前内容完成 schedule_events，避免存档重写剧情定义。
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _has_exact_snapshot_fields(
		snapshot,
		PackedStringArray([
			"snapshot_version",
			"system_id",
			"event_status_by_id",
			"pending_event_ids",
			"queued_items",
			"condition_eligible_event_ids",
			"schedule_sequence",
			"queue_sequence",
			"last_processed_minute",
			"ending_forced",
		])
	):
		return _make_snapshot_validation_error("invalid_fields", "事件调度器快照字段缺失或包含未知字段。")
	var version_result: Dictionary = _read_snapshot_integer(snapshot, "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result["ok"]):
		return version_result
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SNAPSHOT_SYSTEM_ID:
		return _make_snapshot_validation_error("invalid_system_id", "事件调度器快照 system_id 必须为 event_scheduler。")
	if not snapshot["event_status_by_id"] is Dictionary:
		return _make_snapshot_validation_error("invalid_event_status_by_id", "event_status_by_id 必须是对象。")
	if not snapshot["pending_event_ids"] is Array:
		return _make_snapshot_validation_error("invalid_pending_event_ids", "pending_event_ids 必须是数组。")
	if not snapshot["queued_items"] is Array:
		return _make_snapshot_validation_error("invalid_queued_items", "queued_items 必须是数组。")
	if not snapshot["condition_eligible_event_ids"] is Array:
		return _make_snapshot_validation_error("invalid_condition_eligible_event_ids", "condition_eligible_event_ids 必须是数组。")
	if typeof(snapshot["ending_forced"]) != TYPE_BOOL:
		return _make_snapshot_validation_error("invalid_ending_forced", "ending_forced 必须是布尔值。")
	var schedule_sequence_result: Dictionary = _read_snapshot_integer(snapshot, "schedule_sequence", 0)
	if not bool(schedule_sequence_result["ok"]):
		return schedule_sequence_result
	var queue_sequence_result: Dictionary = _read_snapshot_integer(snapshot, "queue_sequence", 0)
	if not bool(queue_sequence_result["ok"]):
		return queue_sequence_result
	var last_minute_result: Dictionary = _read_snapshot_integer(snapshot, "last_processed_minute", 0, SHIFT_DURATION_MINUTES - 1)
	if not bool(last_minute_result["ok"]):
		return last_minute_result

	var configured_result: Dictionary = _resolve_configured_events(context)
	if not bool(configured_result["ok"]):
		return configured_result
	var configured_events: Dictionary = configured_result["event_by_id"] as Dictionary
	if int(schedule_sequence_result["value"]) != _schedule_sequence:
		return _make_snapshot_validation_error("schedule_sequence_mismatch", "schedule_sequence 与当前内容调度顺序不一致。")

	var status_by_id: Dictionary = snapshot["event_status_by_id"] as Dictionary
	if status_by_id.size() != configured_events.size():
		return _make_snapshot_validation_error("event_status_id_set_mismatch", "事件状态集合必须与当前内容事件 ID 完全一致。")
	for event_id_variant: Variant in configured_events:
		var event_id: String = String(event_id_variant)
		if not status_by_id.has(event_id) or typeof(status_by_id[event_id]) != TYPE_STRING:
			return _make_snapshot_validation_error("missing_or_invalid_event_status", "事件 %s 缺少有效状态。" % event_id)
		if not _SNAPSHOT_EVENT_STATUSES.has(String(status_by_id[event_id])):
			return _make_snapshot_validation_error("unsupported_event_status", "事件 %s 使用了不支持的状态。" % event_id)
	for status_id_variant: Variant in status_by_id:
		if typeof(status_id_variant) != TYPE_STRING or not configured_events.has(String(status_id_variant)):
			return _make_snapshot_validation_error("unknown_event_id", "事件状态包含当前内容不存在的 ID。")

	var pending_result: Dictionary = _validate_snapshot_id_array(
		snapshot["pending_event_ids"] as Array,
		configured_events,
		"pending_event_ids"
	)
	if not bool(pending_result["ok"]):
		return pending_result
	var pending_ids: Array[String] = pending_result["ids"] as Array[String]
	var pending_lookup: Dictionary = _id_lookup(pending_ids)

	var queue_result: Dictionary = _validate_snapshot_queue(
		snapshot["queued_items"] as Array,
		configured_events,
		int(queue_sequence_result["value"])
	)
	if not bool(queue_result["ok"]):
		return queue_result
	var normalized_queue: Array[Dictionary] = queue_result["queued_items"] as Array[Dictionary]
	var queued_lookup: Dictionary = queue_result["queued_lookup"] as Dictionary

	var eligible_result: Dictionary = _validate_snapshot_id_array(
		snapshot["condition_eligible_event_ids"] as Array,
		configured_events,
		"condition_eligible_event_ids"
	)
	if not bool(eligible_result["ok"]):
		return eligible_result
	var eligible_ids: Array[String] = eligible_result["ids"] as Array[String]

	for event_id_variant: Variant in configured_events:
		var state_event_id: String = String(event_id_variant)
		var event_status: String = String(status_by_id[state_event_id])
		if (event_status == "scheduled") != pending_lookup.has(state_event_id):
			return _make_snapshot_validation_error("pending_status_conflict", "事件 %s 的 scheduled 状态与待处理集合不一致。" % state_event_id)
		if (event_status == "queued") != queued_lookup.has(state_event_id):
			return _make_snapshot_validation_error("queue_status_conflict", "事件 %s 的 queued 状态与队列不一致。" % state_event_id)
		if pending_lookup.has(state_event_id) and queued_lookup.has(state_event_id):
			return _make_snapshot_validation_error("pending_queue_overlap", "事件 %s 不能同时待处理和排队。" % state_event_id)
	for eligible_event_id: String in eligible_ids:
		if not pending_lookup.has(eligible_event_id):
			return _make_snapshot_validation_error("eligible_not_pending", "条件资格事件 %s 必须仍在待处理集合中。" % eligible_event_id)
		var eligible_definition: Dictionary = configured_events[eligible_event_id] as Dictionary
		if int(last_minute_result["value"]) < int(eligible_definition["window_start_minute"]) or int(last_minute_result["value"]) > int(eligible_definition["window_end_minute"]):
			return _make_snapshot_validation_error("eligible_window_conflict", "资格事件 %s 不在其有效时间窗内。" % eligible_event_id)
	for pending_event_id: String in pending_ids:
		var pending_definition: Dictionary = configured_events[pending_event_id] as Dictionary
		if int(last_minute_result["value"]) > int(pending_definition["window_end_minute"]):
			return _make_snapshot_validation_error("pending_window_expired", "待处理事件 %s 已超过其时间窗。" % pending_event_id)

	var ending_forced: bool = bool(snapshot["ending_forced"])
	if ending_forced and (not pending_ids.is_empty() or not normalized_queue.is_empty() or not eligible_ids.is_empty()):
		return _make_snapshot_validation_error("ending_active_event_state", "02:00 后调度器不得保留待处理、队列或条件资格事件。")
	if ending_forced:
		for ending_event_id_variant: Variant in configured_events:
			var ending_event_id: String = String(ending_event_id_variant)
			var ending_status: String = String(status_by_id[ending_event_id])
			if ending_status == "scheduled" or ending_status == "queued":
				return _make_snapshot_validation_error("ending_nonterminal_status", "02:00 后事件 %s 不能保持待处理或排队状态。" % ending_event_id)

	return {
		"ok": true,
		"normalized_snapshot": {
			"snapshot_version": SNAPSHOT_VERSION,
			"system_id": SNAPSHOT_SYSTEM_ID,
			"event_status_by_id": status_by_id.duplicate(true),
			"pending_event_ids": pending_ids,
			"queued_items": normalized_queue,
			"condition_eligible_event_ids": eligible_ids,
			"schedule_sequence": int(schedule_sequence_result["value"]),
			"queue_sequence": int(queue_sequence_result["value"]),
			"last_processed_minute": int(last_minute_result["value"]),
			"ending_forced": ending_forced,
		},
	}


## 恢复时只提交动态状态，绝不重新触发、入队或过期事件，也不发送调度信号。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation["ok"]):
		return validation
	var normalized: Dictionary = validation["normalized_snapshot"] as Dictionary
	var restored_queue: Array[Dictionary] = []
	for queue_entry: Dictionary in normalized["queued_items"] as Array[Dictionary]:
		var event_id: String = String(queue_entry["event_id"])
		restored_queue.append({
			"event": (_events_by_id[event_id] as Dictionary).duplicate(true),
			"queue_sequence": int(queue_entry["queue_sequence"]),
		})
	var restored_pending: Array[String] = []
	for event_id_variant: Variant in normalized["pending_event_ids"] as Array:
		restored_pending.append(String(event_id_variant))
	var restored_eligible: Dictionary = {}
	for event_id_variant: Variant in normalized["condition_eligible_event_ids"] as Array:
		restored_eligible[String(event_id_variant)] = true
	_event_status_by_id = (normalized["event_status_by_id"] as Dictionary).duplicate(true)
	_pending_event_ids = restored_pending
	_queued_items = restored_queue
	_condition_eligible_event_ids = restored_eligible
	_schedule_sequence = int(normalized["schedule_sequence"])
	_queue_sequence = int(normalized["queue_sequence"])
	_last_processed_minute = int(normalized["last_processed_minute"])
	_is_ending_forced = bool(normalized["ending_forced"])
	return {"ok": true}


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


func _resolve_configured_events(context: Dictionary) -> Dictionary:
	var configured_events: Dictionary = _events_by_id
	if context.has("event_by_id"):
		if not context["event_by_id"] is Dictionary:
			return _make_snapshot_validation_error("invalid_context_event_by_id", "恢复上下文 event_by_id 必须是对象。")
		configured_events = context["event_by_id"] as Dictionary
	if configured_events.size() != _events_by_id.size():
		return _make_snapshot_validation_error("configured_event_set_mismatch", "当前 Scheduler 尚未按同一内容包完成事件配置。")
	for event_id_variant: Variant in configured_events:
		if typeof(event_id_variant) != TYPE_STRING:
			return _make_snapshot_validation_error("invalid_context_event_id", "恢复上下文 event_by_id 的 ID 必须是字符串。")
		var event_id: String = String(event_id_variant)
		if not _events_by_id.has(event_id) or not configured_events[event_id] is Dictionary:
			return _make_snapshot_validation_error("configured_event_set_mismatch", "恢复上下文包含当前 Scheduler 不存在的事件 %s。" % event_id)
		var validation: Dictionary = validate_event(configured_events[event_id] as Dictionary)
		if not bool(validation["ok"]):
			return _make_snapshot_validation_error("invalid_context_event", "恢复上下文事件 %s 不符合当前事件内容契约。" % event_id)
		var context_event: Dictionary = configured_events[event_id] as Dictionary
		if String(context_event["id"]) != event_id:
			return _make_snapshot_validation_error("context_event_id_mismatch", "恢复上下文事件键与事件 id 不一致：%s。" % event_id)
		var internal_event: Dictionary = _events_by_id[event_id] as Dictionary
		if String(internal_event["id"]) != event_id:
			return _make_snapshot_validation_error("invalid_configured_event", "Scheduler 内部事件定义已损坏：%s。" % event_id)
		if _public_event_copy(internal_event) != _public_event_copy(context_event):
			return _make_snapshot_validation_error("configured_event_definition_mismatch", "恢复上下文事件 %s 与当前内容定义不一致。" % event_id)
	# 后续队列优先级与时间窗一律取实际已配置的定义，避免外部 context 影响恢复行为。
	return {"ok": true, "event_by_id": _events_by_id}


func _validate_snapshot_id_array(raw_ids: Array, configured_events: Dictionary, field_name: String) -> Dictionary:
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in raw_ids:
		if typeof(raw_id) != TYPE_STRING:
			return _make_snapshot_validation_error("invalid_%s" % field_name, "%s 中的事件 ID 必须是字符串。" % field_name)
		var event_id: String = String(raw_id)
		if not configured_events.has(event_id):
			return _make_snapshot_validation_error("unknown_event_id", "%s 包含当前内容不存在的事件 %s。" % [field_name, event_id])
		if seen.has(event_id):
			return _make_snapshot_validation_error("duplicate_event_id", "%s 不能包含重复事件 %s。" % [field_name, event_id])
		seen[event_id] = true
		ids.append(event_id)
	return {"ok": true, "ids": ids}


func _validate_snapshot_queue(raw_queue: Array, configured_events: Dictionary, queue_sequence: int) -> Dictionary:
	var normalized_queue: Array[Dictionary] = []
	var queued_lookup: Dictionary = {}
	var previous_entry: Dictionary = {}
	var maximum_sequence: int = -1
	for raw_entry: Variant in raw_queue:
		if not raw_entry is Dictionary:
			return _make_snapshot_validation_error("invalid_queue_entry", "queued_items 中的每一项必须是对象。")
		var entry: Dictionary = raw_entry as Dictionary
		if not _has_exact_snapshot_fields(entry, PackedStringArray(["event_id", "queue_sequence"])):
			return _make_snapshot_validation_error("invalid_queue_entry_fields", "队列条目字段缺失或包含未知字段。")
		if typeof(entry["event_id"]) != TYPE_STRING:
			return _make_snapshot_validation_error("invalid_queue_event_id", "队列事件 ID 必须是字符串。")
		var event_id: String = String(entry["event_id"])
		if not configured_events.has(event_id):
			return _make_snapshot_validation_error("unknown_event_id", "队列包含当前内容不存在的事件 %s。" % event_id)
		if queued_lookup.has(event_id):
			return _make_snapshot_validation_error("duplicate_queue_event", "队列不能包含重复事件 %s。" % event_id)
		var sequence_result: Dictionary = _read_snapshot_integer(entry, "queue_sequence", 0)
		if not bool(sequence_result["ok"]):
			return sequence_result
		var entry_sequence: int = int(sequence_result["value"])
		if entry_sequence >= queue_sequence:
			return _make_snapshot_validation_error("invalid_queue_sequence", "队列事件 %s 的 sequence 必须小于 queue_sequence。" % event_id)
		var normalized_entry: Dictionary = {"event_id": event_id, "queue_sequence": entry_sequence}
		if not previous_entry.is_empty() and not _is_valid_snapshot_queue_order(previous_entry, normalized_entry, configured_events):
			return _make_snapshot_validation_error("invalid_queue_order", "队列顺序必须按主线优先级和入队顺序稳定排列。")
		previous_entry = normalized_entry
		maximum_sequence = maxi(maximum_sequence, entry_sequence)
		queued_lookup[event_id] = true
		normalized_queue.append(normalized_entry)
	if not normalized_queue.is_empty() and queue_sequence <= maximum_sequence:
		return _make_snapshot_validation_error("invalid_queue_sequence", "queue_sequence 必须大于所有在队列中的 sequence。")
	return {"ok": true, "queued_items": normalized_queue, "queued_lookup": queued_lookup}


func _is_valid_snapshot_queue_order(previous_entry: Dictionary, current_entry: Dictionary, configured_events: Dictionary) -> bool:
	var previous_event: Dictionary = configured_events[String(previous_entry["event_id"])] as Dictionary
	var current_event: Dictionary = configured_events[String(current_entry["event_id"])] as Dictionary
	var previous_rank: int = _priority_rank(String(previous_event["priority"]))
	var current_rank: int = _priority_rank(String(current_event["priority"]))
	if previous_rank != current_rank:
		return previous_rank < current_rank
	return int(previous_entry["queue_sequence"]) < int(current_entry["queue_sequence"])


func _id_lookup(ids: Array[String]) -> Dictionary:
	var lookup: Dictionary = {}
	for event_id: String in ids:
		lookup[event_id] = true
	return lookup


func _has_exact_snapshot_fields(snapshot: Dictionary, required_fields: PackedStringArray) -> bool:
	if snapshot.size() != required_fields.size():
		return false
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return false
	return true


func _read_snapshot_integer(snapshot: Dictionary, field_name: String, minimum: int, maximum: int = -1) -> Dictionary:
	if not snapshot.has(field_name):
		return _make_snapshot_validation_error("missing_%s" % field_name, "调度器快照缺少字段 %s。" % field_name)
	var raw_value: Variant = snapshot[field_name]
	if typeof(raw_value) != TYPE_INT and typeof(raw_value) != TYPE_FLOAT:
		return _make_snapshot_validation_error("invalid_%s" % field_name, "调度器快照字段 %s 必须是整数。" % field_name)
	var numeric_value: float = float(raw_value)
	if not is_finite(numeric_value) or floor(numeric_value) != numeric_value:
		return _make_snapshot_validation_error("invalid_%s" % field_name, "调度器快照字段 %s 必须是有限整数。" % field_name)
	var integer_value: int = int(numeric_value)
	if integer_value < minimum or (maximum >= 0 and integer_value > maximum):
		return _make_snapshot_validation_error("out_of_range_%s" % field_name, "调度器快照字段 %s 超出允许范围。" % field_name)
	return {"ok": true, "value": integer_value}


func _make_snapshot_validation_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
