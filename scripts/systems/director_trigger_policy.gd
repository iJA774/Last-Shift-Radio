class_name DirectorTriggerPolicy
extends RefCounted

## 把高频 committed 世界变化压缩成低频 Director planning opportunity。
## 策略只做确定性 dedupe/cooldown；它不判断剧情事实，也不调用模型。

const MIN_PLAN_INTERVAL_TICKS: int = 30
const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "director_trigger_policy"
const SUPPORTED_TRIGGER_KINDS: PackedStringArray = [
	"signal_committed",
	"interaction_completed",
	"statement_revealed",
	"fact_confirmed",
	"delivery_committed",
	"delivery_rejected",
]

var _seen_trigger_keys: Dictionary = {}
var _pending_triggers: Array[Dictionary] = []
var _last_attempt_tick: int = -MIN_PLAN_INTERVAL_TICKS
var _next_context_serial: int = 1


func reset() -> void:
	_seen_trigger_keys.clear()
	_pending_triggers.clear()
	_last_attempt_tick = -MIN_PLAN_INTERVAL_TICKS
	_next_context_serial = 1


func enqueue_trigger(
	kind: String,
	source_id: String,
	current_tick: int,
	actor_id: String = "",
	related_opportunity_id: String = ""
) -> Dictionary:
	if not SUPPORTED_TRIGGER_KINDS.has(kind):
		return _error("director_trigger_kind_invalid", "DirectorTriggerPolicy 不支持 trigger kind：%s。" % kind)
	if source_id.strip_edges().is_empty():
		return _error("director_trigger_source_invalid", "Director trigger source_id 不能为空。")
	if current_tick < 0:
		return _error("director_trigger_tick_invalid", "Director trigger tick 不能为负数。")
	var trigger: Dictionary = {
		"kind": kind,
		"source_id": source_id,
		"created_at_tick": current_tick,
	}
	if not actor_id.is_empty():
		trigger["actor_id"] = actor_id
	if not related_opportunity_id.is_empty():
		trigger["related_opportunity_id"] = related_opportunity_id
	var trigger_key: String = _trigger_key(trigger)
	if _seen_trigger_keys.has(trigger_key):
		return {"ok": true, "duplicate": true, "queued": false}
	_seen_trigger_keys[trigger_key] = true
	_pending_triggers.append(trigger)
	return {"ok": true, "duplicate": false, "queued": true, "pending_count": _pending_triggers.size()}


func take_ready_trigger(current_tick: int) -> Dictionary:
	if current_tick < 0:
		return _error("director_trigger_tick_invalid", "Director trigger tick 不能为负数。")
	if current_tick < _last_attempt_tick:
		return _error("director_trigger_time_reversed", "DirectorTriggerPolicy 的游戏时间不能倒退。")
	if _pending_triggers.is_empty():
		return {"ok": true, "ready": false, "reason": "empty"}
	if current_tick - _last_attempt_tick < MIN_PLAN_INTERVAL_TICKS:
		return {
			"ok": true,
			"ready": false,
			"reason": "cooldown",
			"ready_at_tick": _last_attempt_tick + MIN_PLAN_INTERVAL_TICKS,
		}
	var trigger: Dictionary = _pending_triggers.pop_front() as Dictionary
	var context_id: String = "director_context_%d" % _next_context_serial
	_next_context_serial += 1
	return {
		"ok": true,
		"ready": true,
		"trigger": trigger.duplicate(true),
		"plan_context_id": context_id,
	}


func mark_attempt_completed(current_tick: int) -> Dictionary:
	if current_tick < 0 or current_tick < _last_attempt_tick:
		return _error("director_trigger_tick_invalid", "Director attempt 完成 tick 无效。")
	_last_attempt_tick = current_tick
	return {"ok": true}


func get_pending_count() -> int:
	return _pending_triggers.size()


func create_snapshot() -> Dictionary:
	var seen_keys: Array[String] = []
	for raw_key: Variant in _seen_trigger_keys.keys():
		seen_keys.append(String(raw_key))
	seen_keys.sort()
	var pending: Array[Dictionary] = []
	for trigger: Dictionary in _pending_triggers:
		pending.append(trigger.duplicate(true))
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"seen_trigger_keys": seen_keys,
		"pending_triggers": pending,
		"last_attempt_tick": _last_attempt_tick,
		"next_context_serial": _next_context_serial,
	}


func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var fields: PackedStringArray = [
		"snapshot_version",
		"system_id",
		"seen_trigger_keys",
		"pending_triggers",
		"last_attempt_tick",
		"next_context_serial",
	]
	if snapshot.size() != fields.size():
		return _error("director_trigger_snapshot_fields_invalid", "DirectorTriggerPolicy 存档字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not snapshot.has(field_name):
			return _error("director_trigger_snapshot_missing_field", "DirectorTriggerPolicy 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("director_trigger_snapshot_version_invalid", "DirectorTriggerPolicy 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("director_trigger_snapshot_system_invalid", "DirectorTriggerPolicy 存档 system_id 不匹配。")
	var current_tick: int = 3600
	if context.has("current_game_tick"):
		var current_tick_result: Dictionary = _read_exact_integer(context["current_game_tick"])
		if not bool(current_tick_result.get("ok", false)) or int(current_tick_result["value"]) < 0:
			return _error("director_trigger_snapshot_context_invalid", "DirectorTriggerPolicy current_game_tick 恢复上下文无效。")
		current_tick = int(current_tick_result["value"])
	var last_tick_result: Dictionary = _read_exact_integer(snapshot["last_attempt_tick"])
	if not bool(last_tick_result.get("ok", false)):
		return _error("director_trigger_snapshot_tick_invalid", "DirectorTriggerPolicy last_attempt_tick 必须是整数。")
	var last_attempt_tick: int = int(last_tick_result["value"])
	if last_attempt_tick < -MIN_PLAN_INTERVAL_TICKS or last_attempt_tick > current_tick:
		return _error("director_trigger_snapshot_tick_invalid", "DirectorTriggerPolicy last_attempt_tick 超出当前世界时间。")
	var serial_result: Dictionary = _read_exact_integer(snapshot["next_context_serial"])
	if not bool(serial_result.get("ok", false)) or int(serial_result["value"]) < 1:
		return _error("director_trigger_snapshot_serial_invalid", "DirectorTriggerPolicy next_context_serial 必须是正整数。")
	if not snapshot["seen_trigger_keys"] is Array or not snapshot["pending_triggers"] is Array:
		return _error("director_trigger_snapshot_collection_invalid", "DirectorTriggerPolicy seen/pending 必须是数组。")
	var seen_lookup: Dictionary = {}
	var seen_keys: Array[String] = []
	for raw_key: Variant in snapshot["seen_trigger_keys"] as Array:
		if not raw_key is String or String(raw_key).strip_edges().is_empty() or seen_lookup.has(String(raw_key)):
			return _error("director_trigger_snapshot_seen_invalid", "DirectorTriggerPolicy seen_trigger_keys 含空、非字符串或重复项。")
		var key: String = String(raw_key)
		seen_lookup[key] = true
		seen_keys.append(key)
	seen_keys.sort()
	var pending: Array[Dictionary] = []
	var pending_keys: Dictionary = {}
	for raw_trigger: Variant in snapshot["pending_triggers"] as Array:
		var trigger_result: Dictionary = _validate_snapshot_trigger(raw_trigger, current_tick)
		if not bool(trigger_result.get("ok", false)):
			return trigger_result
		var trigger: Dictionary = trigger_result["trigger"] as Dictionary
		var trigger_key: String = _trigger_key(trigger)
		if pending_keys.has(trigger_key):
			return _error("director_trigger_snapshot_pending_duplicate", "DirectorTriggerPolicy pending_triggers 含重复 trigger。")
		if not seen_lookup.has(trigger_key):
			return _error("director_trigger_snapshot_seen_mismatch", "每个 pending trigger 都必须已存在于 seen_trigger_keys。")
		pending_keys[trigger_key] = true
		pending.append(trigger)
	return {
		"ok": true,
		"normalized": {
			"seen_trigger_keys": seen_keys,
			"pending_triggers": pending,
			"last_attempt_tick": last_attempt_tick,
			"next_context_serial": int(serial_result["value"]),
		},
	}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	var next_seen: Dictionary = {}
	for key: String in normalized["seen_trigger_keys"] as Array[String]:
		next_seen[key] = true
	_seen_trigger_keys = next_seen
	_pending_triggers = (normalized["pending_triggers"] as Array[Dictionary]).duplicate(true)
	_last_attempt_tick = int(normalized["last_attempt_tick"])
	_next_context_serial = int(normalized["next_context_serial"])
	return {"ok": true}


func _validate_snapshot_trigger(value: Variant, current_tick: int) -> Dictionary:
	if not value is Dictionary:
		return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger 必须是对象。")
	var trigger: Dictionary = value as Dictionary
	for required_key: String in ["kind", "source_id", "created_at_tick"]:
		if not trigger.has(required_key):
			return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger 缺少字段：%s。" % required_key)
	for raw_key: Variant in trigger.keys():
		var key: String = String(raw_key)
		if not ["kind", "source_id", "created_at_tick", "actor_id", "related_opportunity_id"].has(key):
			return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger 含未知字段：%s。" % key)
	if not trigger["kind"] is String or not SUPPORTED_TRIGGER_KINDS.has(String(trigger["kind"])):
		return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger kind 无效。")
	if not trigger["source_id"] is String or String(trigger["source_id"]).strip_edges().is_empty():
		return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger source_id 无效。")
	var tick_result: Dictionary = _read_exact_integer(trigger["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0 or int(tick_result["value"]) > current_tick:
		return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger created_at_tick 超出当前世界时间。")
	var normalized: Dictionary = {
		"kind": String(trigger["kind"]),
		"source_id": String(trigger["source_id"]),
		"created_at_tick": int(tick_result["value"]),
	}
	for optional_key: String in ["actor_id", "related_opportunity_id"]:
		if trigger.has(optional_key):
			if not trigger[optional_key] is String or String(trigger[optional_key]).strip_edges().is_empty():
				return _error("director_trigger_snapshot_trigger_invalid", "DirectorTriggerPolicy pending trigger.%s 无效。" % optional_key)
			normalized[optional_key] = String(trigger[optional_key])
	return {"ok": true, "trigger": normalized}


func _trigger_key(trigger: Dictionary) -> String:
	return "%s|%s|%s|%s" % [
		String(trigger.get("kind", "")),
		String(trigger.get("source_id", "")),
		String(trigger.get("actor_id", "")),
		String(trigger.get("related_opportunity_id", "")),
	]


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
