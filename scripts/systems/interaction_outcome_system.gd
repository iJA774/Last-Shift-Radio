class_name InteractionOutcomeSystem
extends RefCounted

## 自由交互结束后的确定性 Outcome authority。
##
## 模型台词只能作为已经由 StoryEngine 提交的输入事实；最终 disposition、
## trust/stress/suspicion 与 OutcomeRecord 均由本系统确定并持久化。默认不凭空改变
## 数值；authoritative_effects 只允许世界/作者规则提供有限 delta。

signal interaction_outcome_committed(record: Dictionary)

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "interaction_outcome_system"
const DISPOSITIONS: PackedStringArray = ["completed", "cooperated", "refused", "uncertain", "terminated"]
const TERMINAL_REASONS: PackedStringArray = [
	"interaction_completed",
	"phone_ended",
	"actor_requested_end",
	"ending_forced",
	"phone_event_changed",
	"runtime_released",
	"bind_failed",
	"actor_state_patch_failed",
]
const SPEECH_ACTS: PackedStringArray = ["", "answer", "ask", "volunteer", "clarify", "refuse", "uncertain", "end_call"]
const METRIC_FIELDS: PackedStringArray = ["trust", "stress", "suspicion"]

var _is_configured: bool = false
var _initial_metrics_by_actor: Dictionary = {}
var _metrics_by_actor: Dictionary = {}
var _outcomes: Array[Dictionary] = []
var _outcome_by_event_id: Dictionary = {}


func configure(actor_definitions: Array) -> Dictionary:
	if _is_configured or not _metrics_by_actor.is_empty() or not _outcomes.is_empty():
		return _error("interaction_outcome_already_configured", "InteractionOutcomeSystem 已配置，不能覆盖 Actor authority。")
	var initial: Dictionary = {}
	for raw_actor: Variant in actor_definitions:
		if not raw_actor is Dictionary:
			return _error("interaction_outcome_actor_invalid", "InteractionOutcomeSystem actor definition 必须是对象。")
		var actor: Dictionary = raw_actor as Dictionary
		if not actor.get("id") is String or String(actor["id"]).strip_edges().is_empty() or not actor.get("initial_state") is Dictionary:
			return _error("interaction_outcome_actor_invalid", "InteractionOutcomeSystem actor 缺少 id/initial_state。")
		var actor_id: String = String(actor["id"])
		if initial.has(actor_id):
			return _error("interaction_outcome_actor_duplicate", "InteractionOutcomeSystem Actor ID 重复：%s。" % actor_id)
		var state: Dictionary = actor["initial_state"] as Dictionary
		for field_name: String in ["trust", "stress"]:
			if not _is_unit_number(state.get(field_name)):
				return _error("interaction_outcome_metric_invalid", "Actor %s.%s 必须是 0..1 数值。" % [actor_id, field_name])
		initial[actor_id] = {
			"trust": float(state["trust"]),
			"stress": float(state["stress"]),
			"suspicion": 0.0,
		}
	_initial_metrics_by_actor = initial.duplicate(true)
	_metrics_by_actor = initial.duplicate(true)
	_is_configured = true
	return {"ok": true, "actor_count": _metrics_by_actor.size()}


func commit_interaction_outcome(input: Dictionary, authoritative_effects: Dictionary = {}) -> Dictionary:
	if not _is_configured:
		return _error("interaction_outcome_not_configured", "InteractionOutcomeSystem 尚未配置。")
	var validation: Dictionary = _validate_input(input, authoritative_effects)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["input"] as Dictionary
	var event_id: String = String(normalized["event_id"])
	if _outcome_by_event_id.has(event_id):
		var existing: Dictionary = _outcome_by_event_id[event_id] as Dictionary
		for field_name: String in ["session_id", "actor_id", "terminal_reason", "last_speech_act", "created_at_tick"]:
			if existing[field_name] != normalized[field_name]:
				return _error("interaction_outcome_conflict", "同一 event_id 不能提交不同 InteractionOutcome：%s。" % event_id)
		if (existing["asserted_claim_ids"] as Array) != (normalized["asserted_claim_ids"] as Array) \
		or (existing["metric_deltas"] as Dictionary) != (validation["deltas"] as Dictionary):
			return _error("interaction_outcome_conflict", "同一 event_id 不能提交不同 claims 或 authoritative effects：%s。" % event_id)
		return {"ok": true, "duplicate": true, "record": _read_only(existing), "actor_state_patch": _actor_state_patch(String(existing["actor_id"]))}

	var actor_id: String = String(normalized["actor_id"])
	var before: Dictionary = (_metrics_by_actor[actor_id] as Dictionary).duplicate(true)
	var deltas: Dictionary = validation["deltas"] as Dictionary
	var after: Dictionary = {}
	for metric: String in METRIC_FIELDS:
		after[metric] = clampf(float(before[metric]) + float(deltas[metric]), 0.0, 1.0)
	var record: Dictionary = {
		"outcome_id": "interaction_outcome_%s" % event_id,
		"event_id": event_id,
		"session_id": String(normalized["session_id"]),
		"actor_id": actor_id,
		"terminal_reason": String(normalized["terminal_reason"]),
		"last_speech_act": String(normalized["last_speech_act"]),
		"asserted_claim_ids": (normalized["asserted_claim_ids"] as Array[String]).duplicate(),
		"disposition": _derive_disposition(String(normalized["terminal_reason"]), String(normalized["last_speech_act"])),
		"metric_deltas": deltas.duplicate(true),
		"metric_before": before,
		"metric_after": after,
		"created_at_tick": int(normalized["created_at_tick"]),
	}
	_metrics_by_actor[actor_id] = after.duplicate(true)
	_outcomes.append(record)
	_outcome_by_event_id[event_id] = record
	var public_record: Dictionary = _read_only(record)
	interaction_outcome_committed.emit(public_record)
	return {"ok": true, "duplicate": false, "record": public_record, "actor_state_patch": _actor_state_patch(actor_id)}


func get_actor_metrics(actor_id: String) -> Dictionary:
	if not _metrics_by_actor.has(actor_id):
		return {}
	return _read_only(_metrics_by_actor[actor_id] as Dictionary)


func get_outcome_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _outcomes:
		result.append(_read_only(record))
	return result


func get_outcome_event_ids() -> Array[String]:
	var ids: Array[String] = []
	for record: Dictionary in _outcomes:
		ids.append(String(record["event_id"]))
	ids.sort()
	return ids


func get_state_summary() -> Dictionary:
	return {"available": true, "actor_metrics": _metrics_by_actor.duplicate(true), "outcomes": get_outcome_records()}


func create_snapshot() -> Dictionary:
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"actor_metrics": _metrics_by_actor.duplicate(true),
		"outcomes": _outcomes.duplicate(true),
	}
	snapshot.make_read_only()
	return snapshot


func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _is_configured:
		return _error("interaction_outcome_snapshot_not_configured", "InteractionOutcomeSystem 尚未配置，不能校验存档。")
	var fields: PackedStringArray = ["snapshot_version", "system_id", "actor_metrics", "outcomes"]
	if snapshot.size() != fields.size():
		return _error("interaction_outcome_snapshot_fields_invalid", "InteractionOutcomeSystem 存档字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not snapshot.has(field_name):
			return _error("interaction_outcome_snapshot_missing_field", "InteractionOutcomeSystem 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("interaction_outcome_snapshot_version_unsupported", "InteractionOutcomeSystem 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("interaction_outcome_snapshot_system_mismatch", "InteractionOutcomeSystem 存档 system_id 不匹配。")
	if not snapshot["actor_metrics"] is Dictionary or not snapshot["outcomes"] is Array:
		return _error("interaction_outcome_snapshot_shape_invalid", "InteractionOutcomeSystem actor_metrics/outcomes 类型无效。")
	var replay_metrics: Dictionary = _initial_metrics_by_actor.duplicate(true)
	var normalized_outcomes: Array[Dictionary] = []
	var seen_events: Dictionary = {}
	var max_tick: int = -1
	if context.has("current_game_tick"):
		var context_tick_result: Dictionary = _read_exact_integer(context["current_game_tick"])
		if not bool(context_tick_result.get("ok", false)) or int(context_tick_result["value"]) < 0:
			return _error("interaction_outcome_snapshot_context_invalid", "InteractionOutcomeSystem context.current_game_tick 必须是非负整数。")
		max_tick = int(context_tick_result["value"])
	for raw_record: Variant in snapshot["outcomes"] as Array:
		var record_result: Dictionary = _validate_record(raw_record, replay_metrics)
		if not bool(record_result.get("ok", false)):
			return record_result
		var record: Dictionary = record_result["record"] as Dictionary
		var event_id: String = String(record["event_id"])
		if seen_events.has(event_id):
			return _error("interaction_outcome_snapshot_duplicate", "InteractionOutcomeSystem 存档含重复 event outcome：%s。" % event_id)
		seen_events[event_id] = true
		if max_tick >= 0 and int(record["created_at_tick"]) > max_tick:
			return _error("interaction_outcome_snapshot_future", "InteractionOutcome 不能晚于剧情存档时间。")
		replay_metrics[String(record["actor_id"])] = (record["metric_after"] as Dictionary).duplicate(true)
		normalized_outcomes.append(record)
	var raw_metrics: Dictionary = snapshot["actor_metrics"] as Dictionary
	if raw_metrics.size() != replay_metrics.size():
		return _error("interaction_outcome_snapshot_metric_set_mismatch", "InteractionOutcomeSystem actor_metrics 集合与当前 Actor 不一致。")
	for actor_id: String in _sorted_keys(replay_metrics):
		if not raw_metrics.has(actor_id) or not raw_metrics[actor_id] is Dictionary:
			return _error("interaction_outcome_snapshot_metric_missing", "InteractionOutcomeSystem 缺少 Actor metrics：%s。" % actor_id)
		var metrics_result: Dictionary = _validate_metrics(raw_metrics[actor_id], "actor_metrics.%s" % actor_id)
		if not bool(metrics_result.get("ok", false)):
			return metrics_result
		if not _metrics_equal(metrics_result["metrics"] as Dictionary, replay_metrics[actor_id] as Dictionary):
			return _error("interaction_outcome_snapshot_metric_history_mismatch", "Actor metrics 与 Outcome 历史不一致：%s。" % actor_id)
	return {"ok": true, "normalized": {"actor_metrics": replay_metrics, "outcomes": normalized_outcomes}}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	_metrics_by_actor = (normalized["actor_metrics"] as Dictionary).duplicate(true)
	_outcomes.clear()
	_outcome_by_event_id.clear()
	for raw_record: Variant in normalized["outcomes"] as Array:
		var record: Dictionary = (raw_record as Dictionary).duplicate(true)
		_outcomes.append(record)
		_outcome_by_event_id[String(record["event_id"])] = record
	return {"ok": true}


func _validate_input(input: Dictionary, authoritative_effects: Dictionary) -> Dictionary:
	var fields: PackedStringArray = ["event_id", "session_id", "actor_id", "terminal_reason", "last_speech_act", "asserted_claim_ids", "created_at_tick"]
	if input.size() != fields.size():
		return _error("interaction_outcome_input_fields_invalid", "InteractionOutcome input 字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not input.has(field_name):
			return _error("interaction_outcome_input_missing", "InteractionOutcome input 缺少字段：%s。" % field_name)
	for id_field: String in ["event_id", "session_id", "actor_id"]:
		if not input[id_field] is String or String(input[id_field]).strip_edges().is_empty():
			return _error("interaction_outcome_input_invalid", "InteractionOutcome %s 必须是非空字符串。" % id_field)
	var actor_id: String = String(input["actor_id"])
	if not _metrics_by_actor.has(actor_id):
		return _error("interaction_outcome_actor_unknown", "InteractionOutcome 引用了未知 Actor：%s。" % actor_id)
	if not input["terminal_reason"] is String or not TERMINAL_REASONS.has(String(input["terminal_reason"])):
		return _error("interaction_outcome_reason_invalid", "InteractionOutcome terminal_reason 不受支持。")
	if not input["last_speech_act"] is String or not SPEECH_ACTS.has(String(input["last_speech_act"])):
		return _error("interaction_outcome_speech_act_invalid", "InteractionOutcome last_speech_act 不受支持。")
	if not input["asserted_claim_ids"] is Array:
		return _error("interaction_outcome_claims_invalid", "InteractionOutcome asserted_claim_ids 必须是数组。")
	var claim_ids: Array[String] = []
	for raw_id: Variant in input["asserted_claim_ids"] as Array:
		if not raw_id is String or String(raw_id).strip_edges().is_empty() or claim_ids.has(String(raw_id)):
			return _error("interaction_outcome_claims_invalid", "InteractionOutcome asserted_claim_ids 必须是唯一非空字符串。")
		claim_ids.append(String(raw_id))
	if typeof(input["created_at_tick"]) != TYPE_INT or int(input["created_at_tick"]) < 0:
		return _error("interaction_outcome_tick_invalid", "InteractionOutcome created_at_tick 必须是非负整数。")
	var deltas_result: Dictionary = _normalize_deltas(authoritative_effects)
	if not bool(deltas_result.get("ok", false)):
		return deltas_result
	return {
		"ok": true,
		"input": {
			"event_id": String(input["event_id"]),
			"session_id": String(input["session_id"]),
			"actor_id": actor_id,
			"terminal_reason": String(input["terminal_reason"]),
			"last_speech_act": String(input["last_speech_act"]),
			"asserted_claim_ids": claim_ids,
			"created_at_tick": int(input["created_at_tick"]),
		},
		"deltas": deltas_result["deltas"],
	}


func _normalize_deltas(effects: Dictionary) -> Dictionary:
	for raw_key: Variant in effects.keys():
		if not METRIC_FIELDS.has(String(raw_key)):
			return _error("interaction_outcome_effect_field_invalid", "InteractionOutcome authoritative_effects 含未知 metric：%s。" % String(raw_key))
	var deltas: Dictionary = {"trust": 0.0, "stress": 0.0, "suspicion": 0.0}
	for metric: String in METRIC_FIELDS:
		if not effects.has(metric):
			continue
		if typeof(effects[metric]) != TYPE_INT and typeof(effects[metric]) != TYPE_FLOAT:
			return _error("interaction_outcome_effect_invalid", "InteractionOutcome %s delta 必须是 -1..1 数值。" % metric)
		var delta: float = float(effects[metric])
		if is_nan(delta) or is_inf(delta) or delta < -1.0 or delta > 1.0:
			return _error("interaction_outcome_effect_invalid", "InteractionOutcome %s delta 必须是 -1..1 数值。" % metric)
		deltas[metric] = delta
	return {"ok": true, "deltas": deltas}


func _validate_record(value: Variant, replay_metrics: Dictionary) -> Dictionary:
	if not value is Dictionary:
		return _error("interaction_outcome_snapshot_record_invalid", "InteractionOutcomeRecord 必须是对象。")
	var record: Dictionary = value as Dictionary
	var fields: PackedStringArray = [
		"outcome_id", "event_id", "session_id", "actor_id", "terminal_reason", "last_speech_act",
		"asserted_claim_ids", "disposition", "metric_deltas", "metric_before", "metric_after", "created_at_tick",
	]
	if record.size() != fields.size():
		return _error("interaction_outcome_snapshot_record_fields_invalid", "InteractionOutcomeRecord 字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not record.has(field_name):
			return _error("interaction_outcome_snapshot_record_missing", "InteractionOutcomeRecord 缺少字段：%s。" % field_name)
	if not record["event_id"] is String or String(record["event_id"]).strip_edges().is_empty():
		return _error("interaction_outcome_snapshot_event_invalid", "InteractionOutcomeRecord event_id 无效。")
	var event_id: String = String(record["event_id"])
	if not record["outcome_id"] is String or String(record["outcome_id"]) != "interaction_outcome_%s" % event_id:
		return _error("interaction_outcome_snapshot_id_invalid", "InteractionOutcomeRecord outcome_id 与 event_id 不一致。")
	if not record["actor_id"] is String or not replay_metrics.has(String(record["actor_id"])):
		return _error("interaction_outcome_snapshot_actor_invalid", "InteractionOutcomeRecord 引用了未知 Actor。")
	if not record["session_id"] is String or String(record["session_id"]).strip_edges().is_empty():
		return _error("interaction_outcome_snapshot_session_invalid", "InteractionOutcomeRecord session_id 无效。")
	if not record["terminal_reason"] is String or not TERMINAL_REASONS.has(String(record["terminal_reason"])):
		return _error("interaction_outcome_snapshot_reason_invalid", "InteractionOutcomeRecord terminal_reason 无效。")
	if not record["last_speech_act"] is String or not SPEECH_ACTS.has(String(record["last_speech_act"])):
		return _error("interaction_outcome_snapshot_speech_act_invalid", "InteractionOutcomeRecord last_speech_act 无效。")
	if not record["disposition"] is String or not DISPOSITIONS.has(String(record["disposition"])) or String(record["disposition"]) != _derive_disposition(String(record["terminal_reason"]), String(record["last_speech_act"])):
		return _error("interaction_outcome_snapshot_disposition_invalid", "InteractionOutcomeRecord disposition 与提交语义不一致。")
	if not record["asserted_claim_ids"] is Array:
		return _error("interaction_outcome_snapshot_claims_invalid", "InteractionOutcomeRecord asserted_claim_ids 必须是数组。")
	var claims_seen: Dictionary = {}
	for raw_id: Variant in record["asserted_claim_ids"] as Array:
		if not raw_id is String or String(raw_id).strip_edges().is_empty() or claims_seen.has(String(raw_id)):
			return _error("interaction_outcome_snapshot_claims_invalid", "InteractionOutcomeRecord asserted_claim_ids 无效或重复。")
		claims_seen[String(raw_id)] = true
	var tick_result: Dictionary = _read_exact_integer(record["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return _error("interaction_outcome_snapshot_tick_invalid", "InteractionOutcomeRecord created_at_tick 无效。")
	for metric_dict_field: String in ["metric_before", "metric_after"]:
		var metric_result: Dictionary = _validate_metrics(record[metric_dict_field], metric_dict_field)
		if not bool(metric_result.get("ok", false)):
			return metric_result
	if not record["metric_deltas"] is Dictionary:
		return _error("interaction_outcome_snapshot_delta_invalid", "InteractionOutcomeRecord metric_deltas 必须是对象。")
	var delta_result: Dictionary = _normalize_deltas(record["metric_deltas"] as Dictionary)
	if not bool(delta_result.get("ok", false)):
		return delta_result
	var actor_id: String = String(record["actor_id"])
	var expected_before: Dictionary = replay_metrics[actor_id] as Dictionary
	if not _metrics_equal(record["metric_before"] as Dictionary, expected_before):
		return _error("interaction_outcome_snapshot_before_mismatch", "InteractionOutcomeRecord metric_before 与前序权威状态不一致。")
	var expected_after: Dictionary = {}
	for metric: String in METRIC_FIELDS:
		expected_after[metric] = clampf(float(expected_before[metric]) + float((delta_result["deltas"] as Dictionary)[metric]), 0.0, 1.0)
	if not _metrics_equal(record["metric_after"] as Dictionary, expected_after):
		return _error("interaction_outcome_snapshot_after_mismatch", "InteractionOutcomeRecord metric_after 与 delta 不一致。")
	var normalized_record: Dictionary = record.duplicate(true)
	normalized_record["created_at_tick"] = int(tick_result["value"])
	return {"ok": true, "record": normalized_record}


func _validate_metrics(value: Variant, path: String) -> Dictionary:
	if not value is Dictionary:
		return _error("interaction_outcome_metric_invalid", "%s 必须是 metrics 对象。" % path)
	var metrics: Dictionary = value as Dictionary
	if metrics.size() != METRIC_FIELDS.size():
		return _error("interaction_outcome_metric_fields_invalid", "%s 必须且只能包含 trust/stress/suspicion。" % path)
	var normalized: Dictionary = {}
	for metric: String in METRIC_FIELDS:
		if not metrics.has(metric) or not _is_unit_number(metrics[metric]):
			return _error("interaction_outcome_metric_invalid", "%s.%s 必须是 0..1 数值。" % [path, metric])
		normalized[metric] = float(metrics[metric])
	return {"ok": true, "metrics": normalized}


func _derive_disposition(terminal_reason: String, speech_act: String) -> String:
	if terminal_reason == "ending_forced" or terminal_reason == "phone_event_changed":
		return "terminated"
	match speech_act:
		"refuse":
			return "refused"
		"uncertain":
			return "uncertain"
		"answer":
			return "cooperated"
		"volunteer":
			return "cooperated"
		"clarify":
			return "cooperated"
	return "completed"


func _actor_state_patch(actor_id: String) -> Dictionary:
	var metrics: Dictionary = _metrics_by_actor[actor_id] as Dictionary
	return {"trust": float(metrics["trust"]), "stress": float(metrics["stress"])}


func _is_unit_number(value: Variant) -> bool:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return false
	var number: float = float(value)
	return not is_nan(number) and not is_inf(number) and number >= 0.0 and number <= 1.0


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number) or number < float(-9223372036854775807) or number > float(9223372036854775807):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _metrics_equal(left: Dictionary, right: Dictionary) -> bool:
	for metric: String in METRIC_FIELDS:
		if not left.has(metric) or not right.has(metric) or not is_equal_approx(float(left[metric]), float(right[metric])):
			return false
	return true


func _sorted_keys(dictionary: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for raw_key: Variant in dictionary.keys():
		keys.append(String(raw_key))
	keys.sort()
	return keys


func _read_only(record: Dictionary) -> Dictionary:
	var copy: Dictionary = record.duplicate(true)
	copy.make_read_only()
	return copy


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
