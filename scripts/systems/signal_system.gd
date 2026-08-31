class_name SignalSystem
extends RefCounted

## 已提交世界事件到 Actor 感知之间的确定性边界。
##
## SignalRecord 只传播稳定 ID 和有限结构数据，不复制可由模型自由解释的正文，也不
## 请求模型决定受众。当前来源包括玩家广播，以及 Actor 自身 Delivery 的 committed/rejected 结果。

signal signal_committed(record: Dictionary)
signal actor_signal_perceived(actor_id: String, signal_id: String)

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "signal_system"
const SIGNAL_TYPE_PLAYER_BROADCAST: String = "player_broadcast"
const SIGNAL_TYPE_DELIVERY_OUTCOME: String = "delivery_outcome"
const SIGNAL_TYPE_PHONE_TERMINAL: String = "phone_terminal"
const SIGNAL_TYPE_MESSAGE_READ: String = "message_read"
const SIGNAL_TYPE_INTERACTION_OUTCOME: String = "interaction_outcome"
const SIGNAL_TYPE_TASK_TRANSITION: String = "task_transition"
const AUDIENCE_ALL_REGISTERED_ACTORS: String = "all_registered_actors"
const AUDIENCE_SOURCE_ACTOR: String = "source_actor"
const AUDIENCE_EXPLICIT_ACTORS: String = "explicit_actor_ids"
const AUDIENCE_NONE: String = "none"
const DELIVERY_STATUSES: PackedStringArray = ["committed", "rejected"]
const DELIVERY_ACTIONS: PackedStringArray = ["call_station", "send_message"]
const PHONE_OUTCOMES: PackedStringArray = ["answered", "missed", "hung_up", "forced_end"]
const INTERACTION_DISPOSITIONS: PackedStringArray = ["completed", "cooperated", "refused", "uncertain", "terminated"]
const TASK_STATUSES: PackedStringArray = ["pending", "active", "completed", "failed"]

var _is_configured: bool = false
var _actor_ids: Array[String] = []
var _information_item_ids_by_task: Dictionary = {}
var _records: Array[Dictionary] = []
var _record_by_id: Dictionary = {}


func configure(actor_ids: Array, broadcast_tasks: Array) -> Dictionary:
	if _is_configured or not _records.is_empty():
		return _error("signal_system_already_configured", "SignalSystem 已配置，不能在同一局中覆盖世界定义。")
	var actor_seen: Dictionary = {}
	var normalized_actor_ids: Array[String] = []
	for raw_actor_id: Variant in actor_ids:
		if not raw_actor_id is String or String(raw_actor_id).strip_edges().is_empty():
			return _error("signal_actor_id_invalid", "SignalSystem actor_ids 只能包含非空字符串。")
		var actor_id: String = String(raw_actor_id)
		if actor_seen.has(actor_id):
			return _error("signal_actor_id_duplicate", "SignalSystem actor_ids 含重复 Actor：%s。" % actor_id)
		actor_seen[actor_id] = true
		normalized_actor_ids.append(actor_id)
	normalized_actor_ids.sort()

	var task_items: Dictionary = {}
	for raw_task: Variant in broadcast_tasks:
		if not raw_task is Dictionary:
			return _error("signal_broadcast_task_invalid", "SignalSystem broadcast_tasks 中每项必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		if not task.get("id") is String or String(task["id"]).strip_edges().is_empty():
			return _error("signal_broadcast_task_invalid", "SignalSystem 广播任务缺少有效 id。")
		var task_id: String = String(task["id"])
		if task_items.has(task_id):
			return _error("signal_broadcast_task_duplicate", "SignalSystem 广播任务 ID 重复：%s。" % task_id)
		if not task.get("information_items") is Array:
			return _error("signal_broadcast_task_invalid", "SignalSystem 广播任务缺少 information_items。")
		var item_ids: Dictionary = {}
		for raw_item: Variant in task["information_items"] as Array:
			if not raw_item is Dictionary or not (raw_item as Dictionary).get("id") is String:
				return _error("signal_information_item_invalid", "SignalSystem information item 缺少有效 id。")
			var item_id: String = String((raw_item as Dictionary)["id"])
			if item_id.is_empty() or item_ids.has(item_id):
				return _error("signal_information_item_invalid", "SignalSystem information item ID 为空或重复：%s。" % item_id)
			item_ids[item_id] = true
		task_items[task_id] = item_ids

	_actor_ids = normalized_actor_ids
	_information_item_ids_by_task = task_items
	_is_configured = true
	return {"ok": true, "actor_count": _actor_ids.size(), "broadcast_task_count": _information_item_ids_by_task.size()}


func commit_player_broadcast(broadcast_record: Dictionary) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交世界信号。")
	var validation: Dictionary = _validate_player_broadcast_record(broadcast_record)
	if not bool(validation.get("ok", false)):
		return validation
	var task_id: String = String(validation["task_id"])
	var signal_id: String = "signal_player_broadcast_%s" % task_id
	var recipients: Array[String] = _actor_ids.duplicate()
	var record: Dictionary = {
		"signal_id": signal_id,
		"signal_type": SIGNAL_TYPE_PLAYER_BROADCAST,
		"source_id": task_id,
		"created_at_tick": int(validation["sent_at_tick"]),
		"payload": {
			"information_item_ids": (validation["information_item_ids"] as Array[String]).duplicate(),
		},
		"audience_rule": AUDIENCE_ALL_REGISTERED_ACTORS,
		"committed_recipients": recipients,
	}
	return _commit_record(record, "玩家广播")


## Delivery 已经由 Phone/Computer authority 得出终态后才进入这里。反馈只送给发起该
## 动作的 Actor；模型不能把“请求已提交”提前当成“世界已经接受”。
func commit_delivery_outcome(delivery_record: Dictionary, outcome_tick: int) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交 Delivery feedback。")
	var validation: Dictionary = _validate_delivery_outcome(delivery_record, outcome_tick)
	if not bool(validation.get("ok", false)):
		return validation
	var delivery_id: String = String(validation["delivery_id"])
	var actor_id: String = String(validation["actor_id"])
	var record: Dictionary = {
		"signal_id": "signal_delivery_outcome_%s" % delivery_id,
		"signal_type": SIGNAL_TYPE_DELIVERY_OUTCOME,
		"source_id": delivery_id,
		"created_at_tick": int(validation["outcome_tick"]),
		"payload": {
			"status": String(validation["status"]),
			"action_id": String(validation["action_id"]),
			"source_opportunity_id": String(validation["source_opportunity_id"]),
			"source_director_plan_id": String(validation["source_director_plan_id"]),
		},
		"audience_rule": AUDIENCE_SOURCE_ACTOR,
		"committed_recipients": [actor_id],
	}
	return _commit_record(record, "Delivery feedback")


func commit_phone_terminal(event_id: String, outcome: String, actor_id: String, created_at_tick: int) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交电话终态。")
	if event_id.strip_edges().is_empty() or not PHONE_OUTCOMES.has(outcome) or created_at_tick < 0:
		return _error("signal_phone_terminal_invalid", "phone_terminal 需要有效 event_id/outcome/tick。")
	if actor_id.strip_edges().is_empty() or not _actor_ids.has(actor_id):
		return _error("signal_phone_actor_invalid", "phone_terminal actor_id 不属于当前注册 Actor。")
	var record: Dictionary = {
		"signal_id": "signal_phone_terminal_%s" % event_id,
		"signal_type": SIGNAL_TYPE_PHONE_TERMINAL,
		"source_id": event_id,
		"created_at_tick": created_at_tick,
		"payload": {"outcome": outcome, "actor_id": actor_id},
		"audience_rule": AUDIENCE_SOURCE_ACTOR,
		"committed_recipients": [actor_id],
	}
	return _commit_record(record, "电话终态")


func commit_message_read(source_id: String, created_at_tick: int) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交 message_read。")
	if source_id.strip_edges().is_empty() or created_at_tick < 0:
		return _error("signal_message_read_invalid", "message_read 需要有效 source_id/tick。")
	var record: Dictionary = {
		"signal_id": "signal_message_read_%s" % source_id,
		"signal_type": SIGNAL_TYPE_MESSAGE_READ,
		"source_id": source_id,
		"created_at_tick": created_at_tick,
		"payload": {"category": "messages"},
		"audience_rule": AUDIENCE_NONE,
		"committed_recipients": [],
	}
	return _commit_record(record, "短信已读")


func commit_interaction_outcome(outcome_record: Dictionary) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交 interaction_outcome。")
	for field_name: String in ["outcome_id", "event_id", "actor_id", "disposition", "terminal_reason", "metric_deltas", "created_at_tick"]:
		if not outcome_record.has(field_name):
			return _error("signal_interaction_outcome_invalid", "InteractionOutcome signal 缺少字段：%s。" % field_name)
	if not outcome_record["event_id"] is String or String(outcome_record["event_id"]).strip_edges().is_empty():
		return _error("signal_interaction_outcome_invalid", "InteractionOutcome signal event_id 无效。")
	if not outcome_record["outcome_id"] is String or String(outcome_record["outcome_id"]).strip_edges().is_empty():
		return _error("signal_interaction_outcome_invalid", "InteractionOutcome signal outcome_id 无效。")
	if not outcome_record["actor_id"] is String or not _actor_ids.has(String(outcome_record["actor_id"])):
		return _error("signal_interaction_outcome_actor_invalid", "InteractionOutcome signal actor_id 不属于当前注册 Actor。")
	if not outcome_record["disposition"] is String or not INTERACTION_DISPOSITIONS.has(String(outcome_record["disposition"])):
		return _error("signal_interaction_outcome_disposition_invalid", "InteractionOutcome signal disposition 不受支持。")
	if not outcome_record["terminal_reason"] is String or String(outcome_record["terminal_reason"]).strip_edges().is_empty():
		return _error("signal_interaction_outcome_reason_invalid", "InteractionOutcome signal terminal_reason 无效。")
	if not outcome_record["metric_deltas"] is Dictionary:
		return _error("signal_interaction_outcome_metrics_invalid", "InteractionOutcome signal metric_deltas 必须是对象。")
	var metric_deltas: Dictionary = outcome_record["metric_deltas"] as Dictionary
	for metric: String in ["trust", "stress", "suspicion"]:
		if not metric_deltas.has(metric) or (typeof(metric_deltas[metric]) != TYPE_INT and typeof(metric_deltas[metric]) != TYPE_FLOAT):
			return _error("signal_interaction_outcome_metrics_invalid", "InteractionOutcome signal metric_deltas 必须包含 trust/stress/suspicion 数值。")
	if typeof(outcome_record["created_at_tick"]) != TYPE_INT or int(outcome_record["created_at_tick"]) < 0:
		return _error("signal_interaction_outcome_tick_invalid", "InteractionOutcome signal created_at_tick 无效。")
	var event_id: String = String(outcome_record["event_id"])
	var actor_id: String = String(outcome_record["actor_id"])
	var record: Dictionary = {
		"signal_id": "signal_interaction_outcome_%s" % event_id,
		"signal_type": SIGNAL_TYPE_INTERACTION_OUTCOME,
		"source_id": event_id,
		"created_at_tick": int(outcome_record["created_at_tick"]),
		"payload": {
			"outcome_id": String(outcome_record["outcome_id"]),
			"actor_id": actor_id,
			"disposition": String(outcome_record["disposition"]),
			"terminal_reason": String(outcome_record["terminal_reason"]),
			"metric_deltas": metric_deltas.duplicate(true),
		},
		"audience_rule": AUDIENCE_SOURCE_ACTOR,
		"committed_recipients": [actor_id],
	}
	return _commit_record(record, "交互结果")


func commit_task_transition(transition_record: Dictionary, recipients: Array) -> Dictionary:
	if not _is_configured:
		return _error("signal_system_not_configured", "SignalSystem 尚未配置，不能提交 task_transition。")
	for field_name: String in ["transition_id", "task_id", "from_status", "to_status", "created_at_tick", "reason"]:
		if not transition_record.has(field_name):
			return _error("signal_task_transition_invalid", "Task transition signal 缺少字段：%s。" % field_name)
	if not transition_record["task_id"] is String or String(transition_record["task_id"]).strip_edges().is_empty():
		return _error("signal_task_transition_invalid", "Task transition signal task_id 无效。")
	if not transition_record["transition_id"] is String or String(transition_record["transition_id"]).strip_edges().is_empty():
		return _error("signal_task_transition_invalid", "Task transition signal transition_id 无效。")
	if not transition_record["from_status"] is String or not TASK_STATUSES.has(String(transition_record["from_status"])) or not transition_record["to_status"] is String or not TASK_STATUSES.has(String(transition_record["to_status"])):
		return _error("signal_task_transition_status_invalid", "Task transition signal 状态不受支持。")
	if typeof(transition_record["created_at_tick"]) != TYPE_INT or int(transition_record["created_at_tick"]) < 0:
		return _error("signal_task_transition_tick_invalid", "Task transition signal created_at_tick 无效。")
	if not transition_record["reason"] is String or String(transition_record["reason"]).strip_edges().is_empty():
		return _error("signal_task_transition_reason_invalid", "Task transition signal reason 无效。")
	var recipients_result: Dictionary = _normalize_recipients(recipients)
	if not bool(recipients_result.get("ok", false)):
		return recipients_result
	var normalized_recipients: Array[String] = recipients_result["recipients"] as Array[String]
	var task_id: String = String(transition_record["task_id"])
	var record: Dictionary = {
		"signal_id": "signal_task_transition_%s" % String(transition_record["transition_id"]),
		"signal_type": SIGNAL_TYPE_TASK_TRANSITION,
		"source_id": task_id,
		"created_at_tick": int(transition_record["created_at_tick"]),
		"payload": {
			"transition_id": String(transition_record["transition_id"]),
			"from_status": String(transition_record["from_status"]),
			"to_status": String(transition_record["to_status"]),
			"reason": String(transition_record["reason"]),
		},
		"audience_rule": AUDIENCE_EXPLICIT_ACTORS if not normalized_recipients.is_empty() else AUDIENCE_NONE,
		"committed_recipients": normalized_recipients,
	}
	return _commit_record(record, "Task transition")


func get_signal_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _records:
		result.append(_read_only_record(record))
	return result


func get_actor_perceived_signal_ids(actor_id: String) -> Array[String]:
	if not _actor_ids.has(actor_id):
		return []
	var result: Array[String] = []
	for record: Dictionary in _records:
		if (record["committed_recipients"] as Array).has(actor_id):
			result.append(String(record["signal_id"]))
	return result


func get_state_summary() -> Dictionary:
	return {
		"available": true,
		"records": get_signal_records(),
	}


func create_snapshot() -> Dictionary:
	var records: Array[Dictionary] = []
	for record: Dictionary in _records:
		records.append(record.duplicate(true))
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"records": records,
	}
	snapshot.make_read_only()
	return snapshot


func validate_snapshot(snapshot: Dictionary, _context: Dictionary = {}) -> Dictionary:
	if not _is_configured:
		return _error("signal_snapshot_content_not_configured", "SignalSystem 尚未配置，不能校验存档。")
	var required_fields: PackedStringArray = ["snapshot_version", "system_id", "records"]
	if snapshot.size() != required_fields.size():
		return _error("signal_snapshot_fields_invalid", "SignalSystem 存档字段缺失或包含未知字段。")
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return _error("signal_snapshot_missing_field", "SignalSystem 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("signal_snapshot_version_unsupported", "SignalSystem 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("signal_snapshot_system_id_mismatch", "SignalSystem 存档所属系统不匹配。")
	if not snapshot["records"] is Array:
		return _error("signal_snapshot_records_invalid", "SignalSystem 存档 records 必须是数组。")
	var normalized_records: Array[Dictionary] = []
	var seen_signal_ids: Dictionary = {}
	for raw_record: Variant in snapshot["records"] as Array:
		var record_result: Dictionary = _validate_snapshot_record(raw_record)
		if not bool(record_result.get("ok", false)):
			return record_result
		var normalized: Dictionary = record_result["record"] as Dictionary
		var signal_id: String = String(normalized["signal_id"])
		if seen_signal_ids.has(signal_id):
			return _error("signal_snapshot_duplicate_id", "SignalSystem 存档含重复 signal_id：%s。" % signal_id)
		seen_signal_ids[signal_id] = true
		normalized_records.append(normalized)
	return {"ok": true, "normalized": {"records": normalized_records}}


## restore 不发 signal_committed / actor_signal_perceived；历史感知由 AgentRuntime 自身快照恢复。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var next_records: Array[Dictionary] = []
	var next_by_id: Dictionary = {}
	for normalized: Dictionary in (validation["normalized"] as Dictionary)["records"] as Array[Dictionary]:
		var record: Dictionary = normalized.duplicate(true)
		next_records.append(record)
		next_by_id[String(record["signal_id"])] = record
	_records = next_records
	_record_by_id = next_by_id
	return {"ok": true}


func _commit_record(record: Dictionary, source_label: String) -> Dictionary:
	var signal_id: String = String(record["signal_id"])
	if _record_by_id.has(signal_id):
		var existing: Dictionary = _record_by_id[signal_id] as Dictionary
		if existing != record:
			return _error("signal_id_conflict", "同一 signal_id 不能映射到不同 committed SignalRecord：%s。" % signal_id)
		return {"ok": true, "duplicate": true, "record": _read_only_record(existing)}
	_records.append(record)
	_record_by_id[signal_id] = record
	var public_record: Dictionary = _read_only_record(record)
	signal_committed.emit(public_record)
	for actor_id: String in record["committed_recipients"] as Array[String]:
		actor_signal_perceived.emit(actor_id, signal_id)
	print("[SignalSystem][%s] 已提交%s信号，recipients=%d。" % [signal_id, source_label, (record["committed_recipients"] as Array).size()])
	return {"ok": true, "duplicate": false, "record": public_record}


func _validate_player_broadcast_record(record: Dictionary) -> Dictionary:
	if not record.get("task_id") is String or String(record["task_id"]).strip_edges().is_empty():
		return _error("signal_broadcast_record_invalid", "已提交玩家广播缺少有效 task_id。")
	var task_id: String = String(record["task_id"])
	if not _information_item_ids_by_task.has(task_id):
		return _error("signal_broadcast_task_unknown", "已提交玩家广播引用未知 task_id：%s。" % task_id)
	if not record.get("information_item_ids") is Array:
		return _error("signal_broadcast_record_invalid", "已提交玩家广播 information_item_ids 必须是数组。")
	var normalized_ids: Array[String] = []
	var seen: Dictionary = {}
	var allowed_items: Dictionary = _information_item_ids_by_task[task_id] as Dictionary
	for raw_id: Variant in record["information_item_ids"] as Array:
		if not raw_id is String:
			return _error("signal_information_item_invalid", "玩家广播 signal 只能引用字符串 information item ID。")
		var item_id: String = String(raw_id)
		if not allowed_items.has(item_id) or seen.has(item_id):
			return _error("signal_information_item_invalid", "玩家广播 signal 引用了未知或重复 information item：%s。" % item_id)
		seen[item_id] = true
		normalized_ids.append(item_id)
	if normalized_ids.is_empty():
		return _error("signal_information_item_invalid", "玩家广播 signal 至少需要一个 information item。")
	var tick_result: Dictionary = _read_exact_integer(record.get("sent_at_tick"))
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return _error("signal_broadcast_tick_invalid", "玩家广播 signal 的 sent_at_tick 必须是非负整数。")
	return {
		"ok": true,
		"task_id": task_id,
		"information_item_ids": normalized_ids,
		"sent_at_tick": int(tick_result["value"]),
	}


func _validate_delivery_outcome(record: Dictionary, outcome_tick: int) -> Dictionary:
	for required_key: String in [
		"delivery_id", "actor_id", "action_id", "created_at_tick", "status",
		"source_opportunity_id", "source_director_plan_id",
	]:
		if not record.has(required_key):
			return _error("signal_delivery_record_invalid", "Delivery feedback 缺少字段：%s。" % required_key)
	if not record["delivery_id"] is String or String(record["delivery_id"]).strip_edges().is_empty():
		return _error("signal_delivery_record_invalid", "Delivery feedback delivery_id 无效。")
	if not record["actor_id"] is String or not _actor_ids.has(String(record["actor_id"])):
		return _error("signal_delivery_actor_invalid", "Delivery feedback actor_id 不属于当前注册 Actor。")
	if not record["action_id"] is String or not DELIVERY_ACTIONS.has(String(record["action_id"])):
		return _error("signal_delivery_action_invalid", "Delivery feedback action_id 不受支持。")
	if not record["status"] is String or not DELIVERY_STATUSES.has(String(record["status"])):
		return _error("signal_delivery_status_invalid", "Delivery feedback 只接受 committed/rejected 终态。")
	for source_key: String in ["source_opportunity_id", "source_director_plan_id"]:
		if not record[source_key] is String:
			return _error("signal_delivery_source_invalid", "Delivery feedback %s 必须是字符串。" % source_key)
	var created_result: Dictionary = _read_exact_integer(record["created_at_tick"])
	if not bool(created_result.get("ok", false)) or int(created_result["value"]) < 0:
		return _error("signal_delivery_tick_invalid", "Delivery feedback created_at_tick 无效。")
	if outcome_tick < int(created_result["value"]):
		return _error("signal_delivery_tick_invalid", "Delivery outcome 不能早于 DeliveryRequest 创建时间。")
	return {
		"ok": true,
		"delivery_id": String(record["delivery_id"]),
		"actor_id": String(record["actor_id"]),
		"action_id": String(record["action_id"]),
		"status": String(record["status"]),
		"source_opportunity_id": String(record["source_opportunity_id"]),
		"source_director_plan_id": String(record["source_director_plan_id"]),
		"outcome_tick": outcome_tick,
	}


func _validate_snapshot_record(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("signal_snapshot_record_invalid", "SignalRecord 必须是对象。")
	var record: Dictionary = value as Dictionary
	var fields: PackedStringArray = ["signal_id", "signal_type", "source_id", "created_at_tick", "payload", "audience_rule", "committed_recipients"]
	if record.size() != fields.size():
		return _error("signal_snapshot_record_fields_invalid", "SignalRecord 字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not record.has(field_name):
			return _error("signal_snapshot_record_missing_field", "SignalRecord 缺少字段：%s。" % field_name)
	if not record["signal_type"] is String:
		return _error("signal_snapshot_type_invalid", "SignalRecord signal_type 必须是字符串。")
	match String(record["signal_type"]):
		SIGNAL_TYPE_PLAYER_BROADCAST:
			return _validate_player_broadcast_snapshot_record(record)
		SIGNAL_TYPE_DELIVERY_OUTCOME:
			return _validate_delivery_outcome_snapshot_record(record)
		SIGNAL_TYPE_PHONE_TERMINAL, SIGNAL_TYPE_MESSAGE_READ, SIGNAL_TYPE_INTERACTION_OUTCOME, SIGNAL_TYPE_TASK_TRANSITION:
			return _validate_observation_snapshot_record(record)
	return _error("signal_snapshot_type_invalid", "SignalRecord signal_type 不受支持。")


func _validate_player_broadcast_snapshot_record(record: Dictionary) -> Dictionary:
	if not record["source_id"] is String:
		return _error("signal_snapshot_source_invalid", "玩家广播 SignalRecord source_id 必须是字符串。")
	var task_id: String = String(record["source_id"])
	var expected_signal_id: String = "signal_player_broadcast_%s" % task_id
	if not record["signal_id"] is String or String(record["signal_id"]) != expected_signal_id:
		return _error("signal_snapshot_id_invalid", "玩家广播 SignalRecord signal_id 与 source_id 不一致。")
	if not record["payload"] is Dictionary:
		return _error("signal_snapshot_payload_invalid", "玩家广播 SignalRecord payload 必须是对象。")
	var payload: Dictionary = record["payload"] as Dictionary
	if payload.size() != 1 or not payload.has("information_item_ids"):
		return _error("signal_snapshot_payload_invalid", "玩家广播 SignalRecord payload 只能包含 information_item_ids。")
	var source_validation: Dictionary = _validate_player_broadcast_record({
		"task_id": task_id,
		"information_item_ids": payload["information_item_ids"],
		"sent_at_tick": record["created_at_tick"],
	})
	if not bool(source_validation.get("ok", false)):
		return source_validation
	if not record["audience_rule"] is String or String(record["audience_rule"]) != AUDIENCE_ALL_REGISTERED_ACTORS:
		return _error("signal_snapshot_audience_invalid", "玩家广播 SignalRecord audience_rule 不受支持。")
	var recipients_result: Dictionary = _normalize_recipients(record["committed_recipients"])
	if not bool(recipients_result.get("ok", false)):
		return _error("signal_snapshot_recipients_mismatch", "玩家广播 SignalRecord recipients 必须与当前全部注册 Actor 一致。")
	var recipients: Array[String] = recipients_result["recipients"] as Array[String]
	if recipients != _actor_ids:
		return _error("signal_snapshot_recipients_mismatch", "玩家广播 SignalRecord recipients 必须与当前全部注册 Actor 一致。")
	return {
		"ok": true,
		"record": {
			"signal_id": expected_signal_id,
			"signal_type": SIGNAL_TYPE_PLAYER_BROADCAST,
			"source_id": task_id,
			"created_at_tick": int(source_validation["sent_at_tick"]),
			"payload": {"information_item_ids": (source_validation["information_item_ids"] as Array[String]).duplicate()},
			"audience_rule": AUDIENCE_ALL_REGISTERED_ACTORS,
			"committed_recipients": recipients.duplicate(),
		},
	}


func _validate_delivery_outcome_snapshot_record(record: Dictionary) -> Dictionary:
	if not record["source_id"] is String or String(record["source_id"]).strip_edges().is_empty():
		return _error("signal_snapshot_source_invalid", "Delivery SignalRecord source_id 必须是非空 delivery_id。")
	var delivery_id: String = String(record["source_id"])
	var expected_signal_id: String = "signal_delivery_outcome_%s" % delivery_id
	if not record["signal_id"] is String or String(record["signal_id"]) != expected_signal_id:
		return _error("signal_snapshot_id_invalid", "Delivery SignalRecord signal_id 与 delivery_id 不一致。")
	var tick_result: Dictionary = _read_exact_integer(record["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return _error("signal_snapshot_tick_invalid", "Delivery SignalRecord created_at_tick 无效。")
	if not record["payload"] is Dictionary:
		return _error("signal_snapshot_payload_invalid", "Delivery SignalRecord payload 必须是对象。")
	var payload: Dictionary = record["payload"] as Dictionary
	var payload_fields: PackedStringArray = ["status", "action_id", "source_opportunity_id", "source_director_plan_id"]
	if payload.size() != payload_fields.size():
		return _error("signal_snapshot_payload_invalid", "Delivery SignalRecord payload 字段不完整或含未知字段。")
	for field_name: String in payload_fields:
		if not payload.has(field_name) or not payload[field_name] is String:
			return _error("signal_snapshot_payload_invalid", "Delivery SignalRecord payload.%s 必须是字符串。" % field_name)
	if not DELIVERY_STATUSES.has(String(payload["status"])) or not DELIVERY_ACTIONS.has(String(payload["action_id"])):
		return _error("signal_snapshot_payload_invalid", "Delivery SignalRecord status/action_id 不受支持。")
	if not record["audience_rule"] is String or String(record["audience_rule"]) != AUDIENCE_SOURCE_ACTOR:
		return _error("signal_snapshot_audience_invalid", "Delivery SignalRecord audience_rule 必须是 source_actor。")
	var recipients_result: Dictionary = _normalize_recipients(record["committed_recipients"])
	if not bool(recipients_result.get("ok", false)):
		return recipients_result
	var recipients: Array[String] = recipients_result["recipients"] as Array[String]
	if recipients.size() != 1:
		return _error("signal_snapshot_recipients_mismatch", "Delivery SignalRecord 必须且只能反馈给一个 source Actor。")
	return {
		"ok": true,
		"record": {
			"signal_id": expected_signal_id,
			"signal_type": SIGNAL_TYPE_DELIVERY_OUTCOME,
			"source_id": delivery_id,
			"created_at_tick": int(tick_result["value"]),
			"payload": payload.duplicate(true),
			"audience_rule": AUDIENCE_SOURCE_ACTOR,
			"committed_recipients": recipients.duplicate(),
		},
	}


func _validate_observation_snapshot_record(record: Dictionary) -> Dictionary:
	if not record["source_id"] is String or String(record["source_id"]).strip_edges().is_empty():
		return _error("signal_snapshot_source_invalid", "Observation SignalRecord source_id 必须是非空字符串。")
	var tick_result: Dictionary = _read_exact_integer(record["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return _error("signal_snapshot_tick_invalid", "Observation SignalRecord created_at_tick 无效。")
	if not record["payload"] is Dictionary or not record["audience_rule"] is String:
		return _error("signal_snapshot_payload_invalid", "Observation SignalRecord payload/audience_rule 类型无效。")
	var signal_type: String = String(record["signal_type"])
	var source_id: String = String(record["source_id"])
	var payload: Dictionary = record["payload"] as Dictionary
	var recipients_result: Dictionary = _normalize_recipients(record["committed_recipients"])
	if not bool(recipients_result.get("ok", false)):
		return recipients_result
	var recipients: Array[String] = recipients_result["recipients"] as Array[String]
	var expected_signal_id: String = ""
	var expected_audience: String = ""
	match signal_type:
		SIGNAL_TYPE_PHONE_TERMINAL:
			expected_signal_id = "signal_phone_terminal_%s" % source_id
			if payload.size() != 2 or not payload.has("outcome") or not payload.has("actor_id"):
				return _error("signal_snapshot_payload_invalid", "phone_terminal payload 必须且只能包含 outcome/actor_id。")
			if not payload["outcome"] is String or not PHONE_OUTCOMES.has(String(payload["outcome"])):
				return _error("signal_snapshot_payload_invalid", "phone_terminal outcome 无效。")
			if not payload["actor_id"] is String or not _actor_ids.has(String(payload["actor_id"])):
				return _error("signal_snapshot_payload_invalid", "phone_terminal actor_id 无效。")
			expected_audience = AUDIENCE_SOURCE_ACTOR
			if recipients != [String(payload["actor_id"])]:
				return _error("signal_snapshot_recipients_mismatch", "phone_terminal 必须只反馈给 source Actor。")
		SIGNAL_TYPE_MESSAGE_READ:
			expected_signal_id = "signal_message_read_%s" % source_id
			if payload.size() != 1 or String(payload.get("category", "")) != "messages":
				return _error("signal_snapshot_payload_invalid", "message_read payload 必须且只能声明 category=messages。")
			expected_audience = AUDIENCE_NONE
			if not recipients.is_empty():
				return _error("signal_snapshot_recipients_mismatch", "message_read 当前不应直接泄露给任何 Actor。")
		SIGNAL_TYPE_INTERACTION_OUTCOME:
			expected_signal_id = "signal_interaction_outcome_%s" % source_id
			var outcome_fields: PackedStringArray = ["outcome_id", "actor_id", "disposition", "terminal_reason", "metric_deltas"]
			if payload.size() != outcome_fields.size():
				return _error("signal_snapshot_payload_invalid", "interaction_outcome payload 字段不完整或含未知字段。")
			for field_name: String in outcome_fields:
				if not payload.has(field_name):
					return _error("signal_snapshot_payload_invalid", "interaction_outcome payload 缺少字段：%s。" % field_name)
			if not payload["outcome_id"] is String or String(payload["outcome_id"]) != "interaction_outcome_%s" % source_id:
				return _error("signal_snapshot_payload_invalid", "interaction_outcome outcome_id 与 source_id 不一致。")
			if not payload["actor_id"] is String or not _actor_ids.has(String(payload["actor_id"])):
				return _error("signal_snapshot_payload_invalid", "interaction_outcome actor_id 无效。")
			if not payload["disposition"] is String or not INTERACTION_DISPOSITIONS.has(String(payload["disposition"])):
				return _error("signal_snapshot_payload_invalid", "interaction_outcome disposition 无效。")
			if not payload["terminal_reason"] is String or String(payload["terminal_reason"]).strip_edges().is_empty() or not payload["metric_deltas"] is Dictionary:
				return _error("signal_snapshot_payload_invalid", "interaction_outcome terminal_reason/metric_deltas 无效。")
			var metric_deltas: Dictionary = payload["metric_deltas"] as Dictionary
			if metric_deltas.size() != 3:
				return _error("signal_snapshot_payload_invalid", "interaction_outcome metric_deltas 必须且只能包含三个 authority metric。")
			for metric: String in ["trust", "stress", "suspicion"]:
				if not metric_deltas.has(metric) or (typeof(metric_deltas[metric]) != TYPE_INT and typeof(metric_deltas[metric]) != TYPE_FLOAT):
					return _error("signal_snapshot_payload_invalid", "interaction_outcome metric_deltas.%s 必须是数值。" % metric)
			expected_audience = AUDIENCE_SOURCE_ACTOR
			if recipients != [String(payload["actor_id"])]:
				return _error("signal_snapshot_recipients_mismatch", "interaction_outcome 必须只反馈给 source Actor。")
		SIGNAL_TYPE_TASK_TRANSITION:
			var transition_fields: PackedStringArray = ["transition_id", "from_status", "to_status", "reason"]
			if payload.size() != transition_fields.size():
				return _error("signal_snapshot_payload_invalid", "task_transition payload 字段不完整或含未知字段。")
			for field_name: String in transition_fields:
				if not payload.has(field_name) or not payload[field_name] is String:
					return _error("signal_snapshot_payload_invalid", "task_transition payload.%s 必须是字符串。" % field_name)
			expected_signal_id = "signal_task_transition_%s" % String(payload["transition_id"])
			if not TASK_STATUSES.has(String(payload["from_status"])) or not TASK_STATUSES.has(String(payload["to_status"])) or String(payload["reason"]).strip_edges().is_empty():
				return _error("signal_snapshot_payload_invalid", "task_transition status/reason 无效。")
			expected_audience = AUDIENCE_EXPLICIT_ACTORS if not recipients.is_empty() else AUDIENCE_NONE
	if not record["signal_id"] is String or String(record["signal_id"]) != expected_signal_id:
		return _error("signal_snapshot_id_invalid", "Observation SignalRecord signal_id 与 source/payload 不一致。")
	if String(record["audience_rule"]) != expected_audience:
		return _error("signal_snapshot_audience_invalid", "Observation SignalRecord audience_rule 与 recipients 不一致。")
	return {
		"ok": true,
		"record": {
			"signal_id": expected_signal_id,
			"signal_type": signal_type,
			"source_id": source_id,
			"created_at_tick": int(tick_result["value"]),
			"payload": payload.duplicate(true),
			"audience_rule": expected_audience,
			"committed_recipients": recipients.duplicate(),
		},
	}


func _normalize_recipients(value: Variant) -> Dictionary:
	if not value is Array:
		return _error("signal_snapshot_recipients_invalid", "SignalRecord committed_recipients 必须是数组。")
	var recipients: Array[String] = []
	var seen: Dictionary = {}
	for raw_actor_id: Variant in value as Array:
		if not raw_actor_id is String:
			return _error("signal_snapshot_recipients_invalid", "SignalRecord recipients 只能包含 Actor ID 字符串。")
		var actor_id: String = String(raw_actor_id)
		if not _actor_ids.has(actor_id) or seen.has(actor_id):
			return _error("signal_snapshot_recipients_invalid", "SignalRecord recipients 含未知或重复 Actor：%s。" % actor_id)
		seen[actor_id] = true
		recipients.append(actor_id)
	return {"ok": true, "recipients": recipients}


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _read_only_record(record: Dictionary) -> Dictionary:
	var copy: Dictionary = record.duplicate(true)
	copy.make_read_only()
	return copy


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
