class_name OpportunityBuilder
extends RefCounted

## 从 committed world state 与 WorldBook authored definitions 中构造 Director 候选机会。
## 本类不请求模型、不修改世界，也绝不创建 WorldBook 中不存在的 Opportunity ID。

const SUPPORTED_TRIGGER_KINDS: PackedStringArray = [
	"signal_committed",
	"interaction_completed",
	"statement_revealed",
	"fact_confirmed",
	"delivery_committed",
	"delivery_rejected",
]

var _is_configured: bool = false
var _opportunities: Array[Dictionary] = []
var _event_by_id: Dictionary = {}
var _event_ids_by_statement_id: Dictionary = {}
var _task_by_id: Dictionary = {}
var _fact_by_id: Dictionary = {}


func reset() -> void:
	_is_configured = false
	_opportunities.clear()
	_event_by_id.clear()
	_event_ids_by_statement_id.clear()
	_task_by_id.clear()
	_fact_by_id.clear()


func configure(compiled_world_definition: Dictionary) -> Dictionary:
	reset()
	for field_name: String in ["opportunities", "events", "tasks", "facts"]:
		if not compiled_world_definition.has(field_name) or not compiled_world_definition[field_name] is Array:
			return _error("opportunity_definition_missing", "CompiledWorldDefinition 缺少数组字段：%s。" % field_name)

	var seen_opportunity_ids: Dictionary = {}
	for raw_opportunity: Variant in compiled_world_definition["opportunities"] as Array:
		if not raw_opportunity is Dictionary:
			return _error("opportunity_definition_invalid", "WorldBook opportunity 必须是对象。")
		var opportunity: Dictionary = raw_opportunity as Dictionary
		var shape_result: Dictionary = _validate_opportunity_shape(opportunity)
		if not bool(shape_result.get("ok", false)):
			return shape_result
		var opportunity_id: String = String(opportunity["id"])
		if seen_opportunity_ids.has(opportunity_id):
			return _error("opportunity_id_duplicate", "WorldBook opportunity ID 重复：%s。" % opportunity_id)
		seen_opportunity_ids[opportunity_id] = true
		_opportunities.append(opportunity.duplicate(true))

	for raw_event: Variant in compiled_world_definition["events"] as Array:
		if not raw_event is Dictionary:
			return _error("opportunity_event_invalid", "CompiledWorldDefinition events 中存在非对象条目。")
		var event_data: Dictionary = raw_event as Dictionary
		var event_id: String = String(event_data.get("id", ""))
		if event_id.is_empty() or _event_by_id.has(event_id):
			return _error("opportunity_event_invalid", "OpportunityBuilder 遇到空或重复 event id：%s。" % event_id)
		_event_by_id[event_id] = event_data.duplicate(true)
		var statement_ids_value: Variant = event_data.get("available_statement_ids", [])
		if not statement_ids_value is Array:
			return _error("opportunity_event_invalid", "事件 %s.available_statement_ids 必须是数组。" % event_id)
		for raw_statement_id: Variant in statement_ids_value as Array:
			if not raw_statement_id is String:
				return _error("opportunity_event_invalid", "事件 %s.available_statement_ids 只能包含字符串。" % event_id)
			var statement_id: String = String(raw_statement_id)
			var mapped_event_ids: Array = _event_ids_by_statement_id.get(statement_id, []) as Array
			if not mapped_event_ids.has(event_id):
				mapped_event_ids.append(event_id)
			_event_ids_by_statement_id[statement_id] = mapped_event_ids

	for raw_task: Variant in compiled_world_definition["tasks"] as Array:
		if not raw_task is Dictionary:
			return _error("opportunity_task_invalid", "CompiledWorldDefinition tasks 中存在非对象条目。")
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = String(task.get("id", ""))
		if task_id.is_empty() or _task_by_id.has(task_id):
			return _error("opportunity_task_invalid", "OpportunityBuilder 遇到空或重复 task id：%s。" % task_id)
		_task_by_id[task_id] = task.duplicate(true)

	for raw_fact: Variant in compiled_world_definition["facts"] as Array:
		if not raw_fact is Dictionary:
			return _error("opportunity_fact_invalid", "CompiledWorldDefinition facts 中存在非对象条目。")
		var fact: Dictionary = raw_fact as Dictionary
		var fact_id: String = String(fact.get("id", ""))
		if fact_id.is_empty() or _fact_by_id.has(fact_id):
			return _error("opportunity_fact_invalid", "OpportunityBuilder 遇到空或重复 fact id：%s。" % fact_id)
		_fact_by_id[fact_id] = fact.duplicate(true)

	_is_configured = true
	return {"ok": true, "opportunity_count": _opportunities.size()}


func is_configured() -> bool:
	return _is_configured


func build_candidates(trigger: Dictionary, story_engine: Object) -> Dictionary:
	if not _is_configured:
		return _error("opportunity_builder_not_configured", "OpportunityBuilder 尚未配置。")
	if story_engine == null or not story_engine.has_method(&"is_condition_met") or not story_engine.has_method(&"get_delivery_state"):
		return _error("opportunity_world_contract_invalid", "OpportunityBuilder 需要 StoryEngine.is_condition_met()/get_delivery_state()。")
	var trigger_result: Dictionary = _validate_trigger(trigger)
	if not bool(trigger_result.get("ok", false)):
		return trigger_result
	var normalized_trigger: Dictionary = trigger_result["trigger"] as Dictionary
	var consumed_ids: Dictionary = _collect_consumed_opportunity_ids(story_engine)
	var candidates: Array[Dictionary] = []
	for authored_opportunity: Dictionary in _opportunities:
		var opportunity_id: String = String(authored_opportunity["id"])
		if consumed_ids.has(opportunity_id):
			continue
		if not _conditions_met(authored_opportunity, story_engine):
			continue
		if not _matches_trigger(authored_opportunity, normalized_trigger):
			continue
		var candidate: Dictionary = authored_opportunity.duplicate(true)
		candidate["trigger"] = normalized_trigger.duplicate(true)
		candidates.append(candidate)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return String(a["id"]) < String(b["id"]))
	return {"ok": true, "candidates": candidates}


func get_actor_disclosable_claim_ids(actor_id: String, opportunity_id: String) -> Array[String]:
	var opportunity: Dictionary = {}
	for authored_opportunity: Dictionary in _opportunities:
		if String(authored_opportunity["id"]) == opportunity_id:
			opportunity = authored_opportunity
			break
	if opportunity.is_empty() or not (opportunity["actor_ids"] as Array).has(actor_id):
		return []
	var seen: Dictionary = {}
	var claim_ids: Array[String] = []
	for raw_event_id: Variant in opportunity["event_ids"] as Array:
		var event_id: String = String(raw_event_id)
		if not _event_by_id.has(event_id):
			continue
		var event_data: Dictionary = _event_by_id[event_id] as Dictionary
		if String(event_data.get("actor_id", "")) != actor_id:
			continue
		for raw_statement_id: Variant in event_data.get("available_statement_ids", []) as Array:
			var statement_id: String = String(raw_statement_id)
			if not seen.has(statement_id):
				seen[statement_id] = true
				claim_ids.append(statement_id)
	claim_ids.sort()
	return claim_ids


func _conditions_met(opportunity: Dictionary, story_engine: Object) -> bool:
	for raw_condition_id: Variant in opportunity["condition_ids"] as Array:
		var condition_id: String = String(raw_condition_id)
		var state_value: Variant = story_engine.call(&"is_condition_met", condition_id)
		if typeof(state_value) != TYPE_BOOL or not bool(state_value):
			return false
	return true


func _matches_trigger(opportunity: Dictionary, trigger: Dictionary) -> bool:
	var kind: String = String(trigger["kind"])
	var source_id: String = String(trigger["source_id"])
	var opportunity_event_ids: Array = opportunity["event_ids"] as Array
	match kind:
		"signal_committed":
			if not _task_by_id.has(source_id):
				return false
			var task: Dictionary = _task_by_id[source_id] as Dictionary
			var sets_condition_id: String = String(task.get("sets_condition_id", ""))
			if not sets_condition_id.is_empty() and (opportunity["condition_ids"] as Array).has(sets_condition_id):
				return true
			return _arrays_intersect(opportunity_event_ids, task.get("related_event_ids", []) as Array)
		"interaction_completed":
			return opportunity_event_ids.has(source_id)
		"statement_revealed":
			var event_ids: Array = _event_ids_by_statement_id.get(source_id, []) as Array
			return _arrays_intersect(opportunity_event_ids, event_ids)
		"fact_confirmed":
			if not _fact_by_id.has(source_id):
				return false
			var fact: Dictionary = _fact_by_id[source_id] as Dictionary
			for raw_statement_id: Variant in fact.get("required_statement_ids", []) as Array:
				var fact_event_ids: Array = _event_ids_by_statement_id.get(String(raw_statement_id), []) as Array
				if _arrays_intersect(opportunity_event_ids, fact_event_ids):
					return true
			return false
		"delivery_committed", "delivery_rejected":
			var related_opportunity_id: String = String(trigger.get("related_opportunity_id", ""))
			if related_opportunity_id == String(opportunity["id"]):
				return false
			var actor_id: String = String(trigger.get("actor_id", ""))
			return not actor_id.is_empty() and (opportunity["actor_ids"] as Array).has(actor_id)
	return false


func _collect_consumed_opportunity_ids(story_engine: Object) -> Dictionary:
	var consumed: Dictionary = {}
	var delivery_value: Variant = story_engine.call(&"get_delivery_state")
	if not delivery_value is Dictionary:
		return consumed
	for raw_request: Variant in (delivery_value as Dictionary).get("requests", []) as Array:
		if not raw_request is Dictionary:
			continue
		var opportunity_id: String = String((raw_request as Dictionary).get("source_opportunity_id", ""))
		if not opportunity_id.is_empty():
			consumed[opportunity_id] = true
	return consumed


func _validate_trigger(trigger: Dictionary) -> Dictionary:
	if not trigger.get("kind") is String or not SUPPORTED_TRIGGER_KINDS.has(String(trigger["kind"])):
		return _error("opportunity_trigger_kind_invalid", "OpportunityBuilder 收到不支持的 trigger kind。")
	if not trigger.get("source_id") is String or String(trigger["source_id"]).strip_edges().is_empty():
		return _error("opportunity_trigger_source_invalid", "OpportunityBuilder trigger.source_id 必须是非空字符串。")
	var normalized: Dictionary = {
		"kind": String(trigger["kind"]),
		"source_id": String(trigger["source_id"]),
	}
	for optional_key: String in ["actor_id", "related_opportunity_id"]:
		if trigger.has(optional_key):
			if not trigger[optional_key] is String:
				return _error("opportunity_trigger_field_invalid", "OpportunityBuilder trigger.%s 必须是字符串。" % optional_key)
			normalized[optional_key] = String(trigger[optional_key])
	return {"ok": true, "trigger": normalized}


func _validate_opportunity_shape(opportunity: Dictionary) -> Dictionary:
	for field_name: String in ["id", "summary", "actor_ids", "event_ids", "condition_ids", "goal_ids"]:
		if not opportunity.has(field_name):
			return _error("opportunity_definition_invalid", "WorldBook opportunity 缺少字段：%s。" % field_name)
	if not opportunity["id"] is String or String(opportunity["id"]).strip_edges().is_empty():
		return _error("opportunity_definition_invalid", "WorldBook opportunity.id 必须是非空字符串。")
	if not opportunity["summary"] is String:
		return _error("opportunity_definition_invalid", "WorldBook opportunity.summary 必须是字符串。")
	for array_field: String in ["actor_ids", "event_ids", "condition_ids", "goal_ids"]:
		if not opportunity[array_field] is Array:
			return _error("opportunity_definition_invalid", "WorldBook opportunity.%s 必须是数组。" % array_field)
		for raw_id: Variant in opportunity[array_field] as Array:
			if not raw_id is String or String(raw_id).strip_edges().is_empty():
				return _error("opportunity_definition_invalid", "WorldBook opportunity.%s 只能包含非空字符串。" % array_field)
	return {"ok": true}


func _arrays_intersect(left: Array, right: Array) -> bool:
	for value: Variant in left:
		if right.has(value):
			return true
	return false


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
