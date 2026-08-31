class_name TestNightStoryV2Validator
extends RefCounted

## Agent Dialogue v2 的完整测试夜班严格校验器。
## v1 incoming_call_events 继续由 ContentValidator 原合同负责；本类只接受
## content_kind=test_night_story 且 content_format_version=2 的单体内容包。

const CONTENT_FORMAT_VERSION: int = 2
const CONTENT_KIND: String = "test_night_story"
const SHIFT_DURATION_MINUTES: int = 60
const REQUIRED_EVENT_COUNT: int = 11
const REQUIRED_ACTOR_COUNT: int = 10
const NORTH_BRIDGE_TOPIC_ID: String = "north_bridge"
const ENDING_ONLY_FACT_IDS: PackedStringArray = ["fact_unauthorized_broadcast", "fact_anomaly_cause_unknown"]
const REQUIRED_FACT_IDS: PackedStringArray = [
	"fact_bridge_accident_before_shift",
	"fact_bridge_closed",
	"fact_accounts_conflict",
	"fact_same_wagon_recurs",
	"fact_wagon_positions_conflict",
	"fact_bridge_traffic_after_closure",
	"fact_unauthorized_broadcast",
	"fact_anomaly_cause_unknown",
]
const SUPPORTED_PRIORITIES: PackedStringArray = ["main", "normal"]
const SUPPORTED_BUSY_POLICIES: PackedStringArray = ["queue", "expire"]
const SUPPORTED_REQUIREMENT_TYPES: PackedStringArray = [
	"statement_revealed",
	"fact_confirmed",
	"condition_true",
	"interaction_answered",
	"interaction_completed",
	"broadcast_sent",
	"message_read",
]
const TOP_LEVEL_FIELDS: PackedStringArray = [
	"content_format_version",
	"content_kind",
	"conditions",
	"events",
	"checklist_entries",
	"news_entries",
	"messages",
	"broadcast_tasks",
	"actors",
	"statements",
	"facts",
]
const ACTOR_STATE_FIELDS: PackedStringArray = [
	"knowledge",
	"beliefs",
	"episodic_memory",
	"current_goal",
	"available_goal_ids",
	"trust",
	"stress",
	"heard_signal_ids",
	"private_information",
	"forbidden_knowledge",
]
const EVENT_AGENT_FIELDS: PackedStringArray = [
	"actor_id",
	"available_statement_ids",
	"line_profile_id",
	"call_reason",
	"opening_intent",
	"fallback_utterance",
]


func validate(document: Variant, source_path: String) -> Dictionary:
	if not document is Dictionary:
		return _error(source_path, "", "$", "invalid_top_level_type", "测试剧情顶层必须是 JSON 对象。")
	var root: Dictionary = document as Dictionary
	for field_name: String in TOP_LEVEL_FIELDS:
		if not root.has(field_name):
			return _error(source_path, "", field_name, "missing_field", "Agent Dialogue v2 测试剧情缺少顶层字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(root["content_format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != CONTENT_FORMAT_VERSION:
		return _error(source_path, "", "content_format_version", "invalid_content_format_version", "Agent Dialogue 测试剧情 content_format_version 必须精确为整数 2。")
	if not root["content_kind"] is String or String(root["content_kind"]) != CONTENT_KIND:
		return _error(source_path, "", "content_kind", "invalid_content_kind", "content_kind 必须精确为 test_night_story。")
	for array_field: String in ["conditions", "events", "checklist_entries", "news_entries", "messages", "broadcast_tasks", "actors", "statements", "facts"]:
		if not root[array_field] is Array:
			return _error(source_path, "", array_field, "invalid_array_field", "%s 必须是数组。" % array_field)
	if root.has("dialogue_nodes"):
		return _error(source_path, "", "dialogue_nodes", "legacy_dialogue_nodes_forbidden", "Agent Dialogue v2 不允许保留正式 gameplay 的 dialogue_nodes。")

	var conditions_result: Dictionary = _validate_conditions(root["conditions"] as Array, source_path)
	if not bool(conditions_result.get("ok", false)):
		return conditions_result
	var actors_result: Dictionary = _validate_actors(root["actors"] as Array, source_path)
	if not bool(actors_result.get("ok", false)):
		return actors_result
	var events_result: Dictionary = _validate_events(
		root["events"] as Array,
		conditions_result["ids"] as Dictionary,
		actors_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(events_result.get("ok", false)):
		return events_result
	var checklist_result: Dictionary = _validate_information_entries(root["checklist_entries"] as Array, "checklist_entries", false, source_path)
	if not bool(checklist_result.get("ok", false)):
		return checklist_result
	var news_result: Dictionary = _validate_information_entries(root["news_entries"] as Array, "news_entries", true, source_path)
	if not bool(news_result.get("ok", false)):
		return news_result
	var messages_result: Dictionary = _validate_messages(root["messages"] as Array, source_path)
	if not bool(messages_result.get("ok", false)):
		return messages_result
	var source_ids_result: Dictionary = _combine_source_ids(
		events_result["by_id"] as Dictionary,
		checklist_result["by_id"] as Dictionary,
		news_result["by_id"] as Dictionary,
		messages_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(source_ids_result.get("ok", false)):
		return source_ids_result
	var statements_result: Dictionary = _validate_statements(root["statements"] as Array, source_ids_result["ids"] as Dictionary, source_path)
	if not bool(statements_result.get("ok", false)):
		return statements_result
	var event_claim_result: Dictionary = _validate_event_statement_references(
		events_result["events"] as Array[Dictionary],
		statements_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(event_claim_result.get("ok", false)):
		return event_claim_result
	var facts_result: Dictionary = _validate_facts(root["facts"] as Array, statements_result["by_id"] as Dictionary, source_path)
	if not bool(facts_result.get("ok", false)):
		return facts_result
	var info_ref_result: Dictionary = _validate_information_references(
		[checklist_result["entries"], news_result["entries"], messages_result["messages"]],
		statements_result["by_id"] as Dictionary,
		facts_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(info_ref_result.get("ok", false)):
		return info_ref_result
	var task_result: Dictionary = _validate_broadcast_tasks(
		root["broadcast_tasks"] as Array,
		events_result["by_id"] as Dictionary,
		statements_result["by_id"] as Dictionary,
		conditions_result["ids"] as Dictionary,
		facts_result["by_id"] as Dictionary,
		messages_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(task_result.get("ok", false)):
		return task_result
	var coverage_result: Dictionary = _validate_statement_coverage(
		[checklist_result["entries"], news_result["entries"], messages_result["messages"]],
		events_result["events"] as Array[Dictionary],
		statements_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(coverage_result.get("ok", false)):
		return coverage_result

	return {
		"ok": true,
		"source_path": source_path,
		"content_format_version": CONTENT_FORMAT_VERSION,
		"content_kind": CONTENT_KIND,
		"conditions": (conditions_result["conditions"] as Array[Dictionary]).duplicate(true),
		"events": (events_result["events"] as Array[Dictionary]).duplicate(true),
		"checklist_entries": (checklist_result["entries"] as Array[Dictionary]).duplicate(true),
		"news_entries": (news_result["entries"] as Array[Dictionary]).duplicate(true),
		"messages": (messages_result["messages"] as Array[Dictionary]).duplicate(true),
		"broadcast_tasks": (task_result["tasks"] as Array[Dictionary]).duplicate(true),
		"actors": (actors_result["actors"] as Array[Dictionary]).duplicate(true),
		"statements": (statements_result["statements"] as Array[Dictionary]).duplicate(true),
		"facts": (facts_result["facts"] as Array[Dictionary]).duplicate(true),
	}


func _validate_conditions(raw_conditions: Array, source_path: String) -> Dictionary:
	if raw_conditions.is_empty():
		return _error(source_path, "", "conditions", "empty_conditions", "测试剧情必须声明条件 ID。")
	var ids: Dictionary = {}
	var conditions: Array[Dictionary] = []
	for raw_condition: Variant in raw_conditions:
		if not raw_condition is Dictionary:
			return _error(source_path, "", "conditions", "invalid_condition_type", "conditions 中每项必须是对象。")
		var condition: Dictionary = raw_condition as Dictionary
		if not condition.has("id") or not condition["id"] is String or not _is_stable_id(String(condition["id"])):
			return _error(source_path, "", "conditions.id", "invalid_condition_id", "条件 ID 必须是英文 snake_case。")
		var condition_id: String = String(condition["id"])
		if ids.has(condition_id):
			return _error(source_path, condition_id, "conditions.id", "duplicate_condition_id", "条件 ID 重复。")
		ids[condition_id] = true
		conditions.append(condition.duplicate(true))
	return {"ok": true, "ids": ids, "conditions": conditions}


func _validate_actors(raw_actors: Array, source_path: String) -> Dictionary:
	if raw_actors.size() != REQUIRED_ACTOR_COUNT:
		return _error(source_path, "", "actors", "invalid_actor_count", "测试剧情必须精确声明 10 个 caller Actor。")
	var by_id: Dictionary = {}
	var actors: Array[Dictionary] = []
	for raw_actor: Variant in raw_actors:
		if not raw_actor is Dictionary:
			return _error(source_path, "", "actors", "invalid_actor_type", "actors 中每项必须是对象。")
		var actor: Dictionary = raw_actor as Dictionary
		for field_name: String in ["id", "display_name", "voice_profile_id", "profile", "initial_state"]:
			if not actor.has(field_name):
				return _error(source_path, "", "actors.%s" % field_name, "missing_field", "Actor 缺少字段：%s。" % field_name)
		if not actor["id"] is String or not _is_stable_id(String(actor["id"])):
			return _error(source_path, "", "actors.id", "invalid_actor_id", "Actor ID 必须是英文 snake_case。")
		var actor_id: String = String(actor["id"])
		if by_id.has(actor_id):
			return _error(source_path, actor_id, "actors.id", "duplicate_actor_id", "Actor ID 重复。")
		for text_field: String in ["display_name", "voice_profile_id"]:
			if not actor[text_field] is String or String(actor[text_field]).strip_edges().is_empty():
				return _error(source_path, actor_id, "actors.%s" % text_field, "invalid_actor_text", "Actor %s 必须是非空字符串。" % text_field)
		if not actor["profile"] is Dictionary or (actor["profile"] as Dictionary).is_empty():
			return _error(source_path, actor_id, "actors.profile", "invalid_actor_profile", "Actor profile 必须是非空对象。")
		var profile: Dictionary = actor["profile"] as Dictionary
		for profile_field: String in ["role", "personality", "speech_style"]:
			if not profile.has(profile_field) or not profile[profile_field] is String or String(profile[profile_field]).strip_edges().is_empty():
				return _error(source_path, actor_id, "actors.profile.%s" % profile_field, "invalid_actor_profile", "Actor profile.%s 必须是非空字符串。" % profile_field)
		if not actor["initial_state"] is Dictionary:
			return _error(source_path, actor_id, "actors.initial_state", "invalid_actor_state", "Actor initial_state 必须是对象。")
		var state_result: Dictionary = _validate_actor_state(actor_id, actor["initial_state"] as Dictionary, source_path)
		if not bool(state_result.get("ok", false)):
			return state_result
		var normalized: Dictionary = actor.duplicate(true)
		normalized["initial_state"] = state_result["state"]
		by_id[actor_id] = normalized
		actors.append(normalized)
	return {"ok": true, "by_id": by_id, "actors": actors}


func _validate_actor_state(actor_id: String, state: Dictionary, source_path: String) -> Dictionary:
	for field_name: String in ACTOR_STATE_FIELDS:
		if not state.has(field_name):
			return _error(source_path, actor_id, "actors.initial_state.%s" % field_name, "missing_actor_state_field", "Actor initial_state 缺少字段：%s。" % field_name)
	for text_array_field: String in ["knowledge", "beliefs", "episodic_memory", "private_information", "forbidden_knowledge"]:
		var text_array_result: Dictionary = _validate_text_array(state[text_array_field], source_path, actor_id, "actors.initial_state.%s" % text_array_field)
		if not bool(text_array_result.get("ok", false)):
			return text_array_result
	var goals_result: Dictionary = _validate_stable_id_array(state["available_goal_ids"], source_path, actor_id, "actors.initial_state.available_goal_ids")
	if not bool(goals_result.get("ok", false)):
		return goals_result
	var signal_result: Dictionary = _validate_stable_id_array(state["heard_signal_ids"], source_path, actor_id, "actors.initial_state.heard_signal_ids")
	if not bool(signal_result.get("ok", false)):
		return signal_result
	if not state["current_goal"] is String:
		return _error(source_path, actor_id, "actors.initial_state.current_goal", "invalid_actor_goal", "Actor current_goal 必须是字符串。")
	var current_goal: String = String(state["current_goal"])
	if not current_goal.is_empty() and (not _is_stable_id(current_goal) or not (state["available_goal_ids"] as Array).has(current_goal)):
		return _error(source_path, actor_id, "actors.initial_state.current_goal", "invalid_actor_goal", "Actor current_goal 必须为空或来自 available_goal_ids。")
	for scalar_field: String in ["trust", "stress"]:
		if typeof(state[scalar_field]) != TYPE_INT and typeof(state[scalar_field]) != TYPE_FLOAT:
			return _error(source_path, actor_id, "actors.initial_state.%s" % scalar_field, "invalid_actor_scalar", "Actor %s 必须是 0..1 数值。" % scalar_field)
		var scalar: float = float(state[scalar_field])
		if is_nan(scalar) or is_inf(scalar) or scalar < 0.0 or scalar > 1.0:
			return _error(source_path, actor_id, "actors.initial_state.%s" % scalar_field, "invalid_actor_scalar", "Actor %s 必须是 0..1 数值。" % scalar_field)
	return {"ok": true, "state": state.duplicate(true)}


func _validate_events(raw_events: Array, condition_ids: Dictionary, actor_by_id: Dictionary, source_path: String) -> Dictionary:
	if raw_events.size() != REQUIRED_EVENT_COUNT:
		return _error(source_path, "", "events", "invalid_event_count", "测试剧情必须精确包含 11 通来电事件。")
	var by_id: Dictionary = {}
	var actor_usage: Dictionary = {}
	var events: Array[Dictionary] = []
	for raw_event: Variant in raw_events:
		if not raw_event is Dictionary:
			return _error(source_path, "", "events", "invalid_event_type", "events 中每项必须是对象。")
		var event: Dictionary = raw_event as Dictionary
		var required_fields: PackedStringArray = [
			"id", "kind", "priority", "window_start_minute", "window_end_minute", "when_busy", "on_expire",
			"condition_ids", "caller_display_name", "caller_number",
		]
		for extra_field: String in EVENT_AGENT_FIELDS:
			required_fields.append(extra_field)
		for field_name: String in required_fields:
			if not event.has(field_name):
				return _error(source_path, _id_or_empty(event), field_name, "missing_field", "来电事件缺少字段：%s。" % field_name)
		if event.has("dialogue_start_id"):
			return _error(source_path, _id_or_empty(event), "dialogue_start_id", "legacy_dialogue_start_forbidden", "Agent Dialogue v2 来电不得保留 dialogue_start_id。")
		if not event["id"] is String or not _is_stable_id(String(event["id"])):
			return _error(source_path, _id_or_empty(event), "id", "invalid_event_id", "事件 ID 必须是英文 snake_case。")
		var event_id: String = String(event["id"])
		if by_id.has(event_id):
			return _error(source_path, event_id, "id", "duplicate_event_id", "事件 ID 重复。")
		if not event["kind"] is String or String(event["kind"]) != "incoming_call":
			return _error(source_path, event_id, "kind", "invalid_kind", "测试剧情事件 kind 必须为 incoming_call。")
		if not event["priority"] is String or not SUPPORTED_PRIORITIES.has(String(event["priority"])):
			return _error(source_path, event_id, "priority", "invalid_priority", "priority 必须为 main 或 normal。")
		if not event["when_busy"] is String or not SUPPORTED_BUSY_POLICIES.has(String(event["when_busy"])):
			return _error(source_path, event_id, "when_busy", "invalid_when_busy", "when_busy 必须为 queue 或 expire。")
		if not event["on_expire"] is String or String(event["on_expire"]) != "mark_missed":
			return _error(source_path, event_id, "on_expire", "invalid_on_expire", "on_expire 必须为 mark_missed。")
		if String(event["priority"]) == "main" and String(event["when_busy"]) != "queue":
			return _error(source_path, event_id, "when_busy", "main_event_must_queue", "主线事件占线时必须 queue。")
		var start_result: Dictionary = _read_exact_integer(event["window_start_minute"])
		var end_result: Dictionary = _read_exact_integer(event["window_end_minute"])
		if not bool(start_result.get("ok", false)) or not bool(end_result.get("ok", false)):
			return _error(source_path, event_id, "window_start_minute/window_end_minute", "invalid_time_window", "来电时间窗必须是整数分钟。")
		var start_minute: int = int(start_result["value"])
		var end_minute: int = int(end_result["value"])
		if start_minute < 0 or end_minute < start_minute or end_minute >= SHIFT_DURATION_MINUTES:
			return _error(source_path, event_id, "window_start_minute/window_end_minute", "invalid_time_window", "来电时间窗必须满足 0 <= start <= end < 60。")
		var conditions_shape: Dictionary = _validate_stable_id_array(event["condition_ids"], source_path, event_id, "condition_ids")
		if not bool(conditions_shape.get("ok", false)):
			return conditions_shape
		for raw_condition_id: Variant in event["condition_ids"] as Array:
			if not condition_ids.has(String(raw_condition_id)):
				return _error(source_path, event_id, "condition_ids", "unknown_condition_id", "事件引用了未声明条件：%s。" % String(raw_condition_id))
		for text_field: String in ["caller_display_name", "caller_number", "line_profile_id", "call_reason", "opening_intent", "fallback_utterance"]:
			if not event[text_field] is String or String(event[text_field]).strip_edges().is_empty():
				return _error(source_path, event_id, text_field, "invalid_event_text", "%s 必须是非空字符串。" % text_field)
		if not event["actor_id"] is String or not actor_by_id.has(String(event["actor_id"])):
			return _error(source_path, event_id, "actor_id", "unknown_actor_id", "来电必须引用已声明 Actor。")
		var actor_id: String = String(event["actor_id"])
		actor_usage[actor_id] = int(actor_usage.get(actor_id, 0)) + 1
		var statement_ids_shape: Dictionary = _validate_stable_id_array(event["available_statement_ids"], source_path, event_id, "available_statement_ids")
		if not bool(statement_ids_shape.get("ok", false)):
			return statement_ids_shape
		if event.has("session_state_patch"):
			var patch_result: Dictionary = _validate_session_state_patch(event["session_state_patch"], source_path, event_id)
			if not bool(patch_result.get("ok", false)):
				return patch_result
		var normalized: Dictionary = event.duplicate(true)
		normalized["window_start_minute"] = start_minute
		normalized["window_end_minute"] = end_minute
		by_id[event_id] = normalized
		events.append(normalized)
	if actor_usage.size() != REQUIRED_ACTOR_COUNT:
		return _error(source_path, "", "events.actor_id", "actor_usage_mismatch", "11 通来电必须覆盖全部 10 个 caller Actor。")
	if int(actor_usage.get("ronnie", 0)) != 2:
		return _error(source_path, "ronnie", "events.actor_id", "ronnie_actor_usage_invalid", "Ronnie 两通电话必须共用唯一 actor_id=ronnie。")
	for actor_id_variant: Variant in actor_usage.keys():
		var actor_id: String = String(actor_id_variant)
		if actor_id != "ronnie" and int(actor_usage[actor_id]) != 1:
			return _error(source_path, actor_id, "events.actor_id", "actor_usage_invalid", "除 Ronnie 外每个 caller Actor 必须恰好绑定一通现有电话。")
	return {"ok": true, "by_id": by_id, "events": events}


func _validate_session_state_patch(value: Variant, source_path: String, event_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, event_id, "session_state_patch", "invalid_session_state_patch", "session_state_patch 必须是对象。")
	var patch: Dictionary = value as Dictionary
	var allowed_fields: PackedStringArray = ["knowledge", "beliefs", "episodic_memory", "current_goal", "trust", "stress"]
	for raw_key: Variant in patch.keys():
		if not allowed_fields.has(String(raw_key)):
			return _error(source_path, event_id, "session_state_patch", "unknown_session_state_patch_field", "session_state_patch 含未知字段：%s。" % String(raw_key))
	for text_array_field: String in ["knowledge", "beliefs", "episodic_memory"]:
		if patch.has(text_array_field):
			var array_result: Dictionary = _validate_text_array(patch[text_array_field], source_path, event_id, "session_state_patch.%s" % text_array_field)
			if not bool(array_result.get("ok", false)):
				return array_result
	if patch.has("current_goal") and (not patch["current_goal"] is String or (not String(patch["current_goal"]).is_empty() and not _is_stable_id(String(patch["current_goal"])))):
		return _error(source_path, event_id, "session_state_patch.current_goal", "invalid_session_state_patch_goal", "session_state_patch.current_goal 必须为空或稳定 ID。")
	for scalar_field: String in ["trust", "stress"]:
		if patch.has(scalar_field):
			if typeof(patch[scalar_field]) != TYPE_INT and typeof(patch[scalar_field]) != TYPE_FLOAT:
				return _error(source_path, event_id, "session_state_patch.%s" % scalar_field, "invalid_session_state_patch_scalar", "session_state_patch 数值必须在 0..1。")
			var scalar: float = float(patch[scalar_field])
			if is_nan(scalar) or is_inf(scalar) or scalar < 0.0 or scalar > 1.0:
				return _error(source_path, event_id, "session_state_patch.%s" % scalar_field, "invalid_session_state_patch_scalar", "session_state_patch 数值必须在 0..1。")
	return {"ok": true}


func _validate_information_entries(raw_entries: Array, collection_name: String, requires_source: bool, source_path: String) -> Dictionary:
	if collection_name == "checklist_entries" and raw_entries.is_empty():
		return _error(source_path, "", collection_name, "empty_checklist_entries", "测试剧情必须提供值班清单。")
	if collection_name == "news_entries" and raw_entries.size() < 5:
		return _error(source_path, "", collection_name, "insufficient_news_entries", "测试剧情至少需要 5 条地方新闻。")
	var by_id: Dictionary = {}
	var entries: Array[Dictionary] = []
	var non_bridge_news_count: int = 0
	for raw_entry: Variant in raw_entries:
		if not raw_entry is Dictionary:
			return _error(source_path, "", collection_name, "invalid_information_entry_type", "%s 中每项必须是对象。" % collection_name)
		var entry: Dictionary = raw_entry as Dictionary
		var entry_id: String = _id_or_empty(entry)
		for field_name: String in ["id", "title", "body", "unlock_minute", "statement_ids", "fact_ids"]:
			if not entry.has(field_name):
				return _error(source_path, entry_id, "%s.%s" % [collection_name, field_name], "missing_field", "信息条目缺少字段：%s。" % field_name)
		if requires_source and not entry.has("source"):
			return _error(source_path, entry_id, "%s.source" % collection_name, "missing_field", "地方新闻缺少 source。")
		if collection_name == "news_entries" and not entry.has("topic_ids"):
			return _error(source_path, entry_id, "news_entries.topic_ids", "missing_field", "地方新闻缺少 topic_ids。")
		if not entry["id"] is String or not _is_stable_id(String(entry["id"])):
			return _error(source_path, entry_id, "%s.id" % collection_name, "invalid_information_entry_id", "信息条目 ID 无效。")
		entry_id = String(entry["id"])
		if by_id.has(entry_id):
			return _error(source_path, entry_id, "%s.id" % collection_name, "duplicate_information_entry_id", "信息条目 ID 重复。")
		for text_field: String in ["title", "body"]:
			if not entry[text_field] is String or String(entry[text_field]).strip_edges().is_empty():
				return _error(source_path, entry_id, "%s.%s" % [collection_name, text_field], "invalid_information_entry_text", "%s 必须是非空字符串。" % text_field)
		if requires_source and (not entry["source"] is String or String(entry["source"]).strip_edges().is_empty()):
			return _error(source_path, entry_id, "%s.source" % collection_name, "invalid_information_entry_source", "新闻 source 必须是非空字符串。")
		var minute_result: Dictionary = _read_exact_integer(entry["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= SHIFT_DURATION_MINUTES:
			return _error(source_path, entry_id, "%s.unlock_minute" % collection_name, "invalid_unlock_minute", "电脑条目 unlock_minute 必须在 0..59。")
		for ids_field: String in ["statement_ids", "fact_ids"]:
			var ids_result: Dictionary = _validate_stable_id_array(entry[ids_field], source_path, entry_id, "%s.%s" % [collection_name, ids_field])
			if not bool(ids_result.get("ok", false)):
				return ids_result
		if collection_name == "news_entries":
			var topic_result: Dictionary = _validate_stable_id_array(entry["topic_ids"], source_path, entry_id, "news_entries.topic_ids")
			if not bool(topic_result.get("ok", false)):
				return topic_result
			if (entry["topic_ids"] as Array).is_empty():
				return _error(source_path, entry_id, "news_entries.topic_ids", "empty_news_topics", "地方新闻至少需要一个 topic_id。")
			if not (entry["topic_ids"] as Array).has(NORTH_BRIDGE_TOPIC_ID):
				non_bridge_news_count += 1
		var normalized: Dictionary = entry.duplicate(true)
		normalized["unlock_minute"] = int(minute_result["value"])
		by_id[entry_id] = normalized
		entries.append(normalized)
	if collection_name == "news_entries" and non_bridge_news_count < 2:
		return _error(source_path, "", "news_entries.topic_ids", "insufficient_non_bridge_news", "测试剧情至少需要 2 条非 north_bridge 新闻。")
	return {"ok": true, "by_id": by_id, "entries": entries}


func _validate_messages(raw_messages: Array, source_path: String) -> Dictionary:
	if raw_messages.is_empty():
		return _error(source_path, "", "messages", "empty_messages", "测试剧情必须提供短信内容。")
	var by_id: Dictionary = {}
	var messages: Array[Dictionary] = []
	for raw_message: Variant in raw_messages:
		if not raw_message is Dictionary:
			return _error(source_path, "", "messages", "invalid_message_type", "messages 中每项必须是对象。")
		var message: Dictionary = raw_message as Dictionary
		var message_id: String = _id_or_empty(message)
		for field_name: String in ["id", "sender", "body", "unlock_minute", "statement_ids", "fact_ids"]:
			if not message.has(field_name):
				return _error(source_path, message_id, field_name, "missing_field", "短信缺少字段：%s。" % field_name)
		if not message["id"] is String or not _is_stable_id(String(message["id"])):
			return _error(source_path, message_id, "id", "invalid_message_id", "短信 ID 无效。")
		message_id = String(message["id"])
		if by_id.has(message_id):
			return _error(source_path, message_id, "id", "duplicate_message_id", "短信 ID 重复。")
		for text_field: String in ["sender", "body"]:
			if not message[text_field] is String or String(message[text_field]).strip_edges().is_empty():
				return _error(source_path, message_id, text_field, "invalid_message_text", "短信 %s 必须是非空字符串。" % text_field)
		var minute_result: Dictionary = _read_exact_integer(message["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= SHIFT_DURATION_MINUTES:
			return _error(source_path, message_id, "unlock_minute", "invalid_unlock_minute", "短信 unlock_minute 必须在 0..59。")
		for ids_field: String in ["statement_ids", "fact_ids"]:
			var ids_result: Dictionary = _validate_stable_id_array(message[ids_field], source_path, message_id, ids_field)
			if not bool(ids_result.get("ok", false)):
				return ids_result
		var normalized: Dictionary = message.duplicate(true)
		normalized["unlock_minute"] = int(minute_result["value"])
		by_id[message_id] = normalized
		messages.append(normalized)
	return {"ok": true, "by_id": by_id, "messages": messages}


func _combine_source_ids(event_by_id: Dictionary, checklist_by_id: Dictionary, news_by_id: Dictionary, message_by_id: Dictionary, source_path: String) -> Dictionary:
	var ids: Dictionary = {}
	for collection: Dictionary in [event_by_id, checklist_by_id, news_by_id, message_by_id]:
		for raw_id: Variant in collection.keys():
			var source_id: String = String(raw_id)
			if ids.has(source_id):
				return _error(source_path, source_id, "id", "duplicate_source_id", "电话、电脑来源与短信不能复用稳定 ID。")
			ids[source_id] = true
	return {"ok": true, "ids": ids}


func _validate_statements(raw_statements: Array, source_ids: Dictionary, source_path: String) -> Dictionary:
	if raw_statements.is_empty():
		return _error(source_path, "", "statements", "empty_statements", "测试剧情必须声明 Statement。")
	var by_id: Dictionary = {}
	var statements: Array[Dictionary] = []
	for raw_statement: Variant in raw_statements:
		if not raw_statement is Dictionary:
			return _error(source_path, "", "statements", "invalid_statement_type", "statements 中每项必须是对象。")
		var statement: Dictionary = raw_statement as Dictionary
		var statement_id: String = _id_or_empty(statement)
		for field_name: String in ["id", "source_id", "body"]:
			if not statement.has(field_name):
				return _error(source_path, statement_id, "statements.%s" % field_name, "missing_field", "Statement 缺少字段：%s。" % field_name)
		if not statement["id"] is String or not _is_stable_id(String(statement["id"])):
			return _error(source_path, statement_id, "statements.id", "invalid_statement_id", "Statement ID 无效。")
		statement_id = String(statement["id"])
		if by_id.has(statement_id):
			return _error(source_path, statement_id, "statements.id", "duplicate_statement_id", "Statement ID 重复。")
		if not statement["source_id"] is String or not source_ids.has(String(statement["source_id"])):
			return _error(source_path, statement_id, "statements.source_id", "unknown_statement_source_id", "Statement 必须引用现有来源。")
		if not statement["body"] is String or String(statement["body"]).strip_edges().is_empty():
			return _error(source_path, statement_id, "statements.body", "invalid_statement_body", "Statement body 必须非空。")
		if statement.has("semantic_guard"):
			var guard_result: Dictionary = _validate_semantic_guard(statement["semantic_guard"], source_path, statement_id)
			if not bool(guard_result.get("ok", false)):
				return guard_result
		var normalized: Dictionary = statement.duplicate(true)
		by_id[statement_id] = normalized
		statements.append(normalized)
	return {"ok": true, "by_id": by_id, "statements": statements}


func _validate_semantic_guard(value: Variant, source_path: String, statement_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, statement_id, "statements.semantic_guard", "invalid_semantic_guard", "semantic_guard 必须是对象。")
	var guard: Dictionary = value as Dictionary
	for raw_key: Variant in guard.keys():
		if not ["required_term_groups", "forbidden_terms"].has(String(raw_key)):
			return _error(source_path, statement_id, "statements.semantic_guard", "unknown_semantic_guard_field", "semantic_guard 含未知字段。")
	if guard.has("required_term_groups"):
		if not guard["required_term_groups"] is Array:
			return _error(source_path, statement_id, "statements.semantic_guard.required_term_groups", "invalid_semantic_guard", "required_term_groups 必须是数组。")
		for raw_group: Variant in guard["required_term_groups"] as Array:
			if not raw_group is Array or (raw_group as Array).is_empty():
				return _error(source_path, statement_id, "statements.semantic_guard.required_term_groups", "invalid_semantic_guard", "required_term_groups 每组必须是非空数组。")
			for raw_term: Variant in raw_group as Array:
				if not raw_term is String or String(raw_term).strip_edges().is_empty():
					return _error(source_path, statement_id, "statements.semantic_guard.required_term_groups", "invalid_semantic_guard", "required term 必须是非空字符串。")
	if guard.has("forbidden_terms"):
		var forbidden_result: Dictionary = _validate_text_array(guard["forbidden_terms"], source_path, statement_id, "statements.semantic_guard.forbidden_terms")
		if not bool(forbidden_result.get("ok", false)):
			return forbidden_result
	return {"ok": true}


func _validate_event_statement_references(events: Array[Dictionary], statement_by_id: Dictionary, source_path: String) -> Dictionary:
	for event: Dictionary in events:
		var event_id: String = String(event["id"])
		for raw_statement_id: Variant in event["available_statement_ids"] as Array:
			var statement_id: String = String(raw_statement_id)
			if not statement_by_id.has(statement_id):
				return _error(source_path, event_id, "available_statement_ids", "unknown_statement_id", "来电引用不存在的可披露 Statement：%s。" % statement_id)
			if String((statement_by_id[statement_id] as Dictionary)["source_id"]) != event_id:
				return _error(source_path, event_id, "available_statement_ids", "statement_source_mismatch", "来电只能披露 source_id 等于自身 event_id 的 Statement。")
	return {"ok": true}


func _validate_facts(raw_facts: Array, statement_by_id: Dictionary, source_path: String) -> Dictionary:
	if raw_facts.is_empty():
		return _error(source_path, "", "facts", "empty_facts", "测试剧情必须声明 Fact。")
	var by_id: Dictionary = {}
	var facts: Array[Dictionary] = []
	for raw_fact: Variant in raw_facts:
		if not raw_fact is Dictionary:
			return _error(source_path, "", "facts", "invalid_fact_type", "facts 中每项必须是对象。")
		var fact: Dictionary = raw_fact as Dictionary
		var fact_id: String = _id_or_empty(fact)
		for field_name: String in ["id", "initially_confirmed", "required_statement_ids"]:
			if not fact.has(field_name):
				return _error(source_path, fact_id, "facts.%s" % field_name, "missing_field", "Fact 缺少字段：%s。" % field_name)
		if not fact["id"] is String or not _is_stable_id(String(fact["id"])):
			return _error(source_path, fact_id, "facts.id", "invalid_fact_id", "Fact ID 无效。")
		fact_id = String(fact["id"])
		if by_id.has(fact_id):
			return _error(source_path, fact_id, "facts.id", "duplicate_fact_id", "Fact ID 重复。")
		if typeof(fact["initially_confirmed"]) != TYPE_BOOL:
			return _error(source_path, fact_id, "facts.initially_confirmed", "invalid_initially_confirmed", "initially_confirmed 必须是 bool。")
		var ids_result: Dictionary = _validate_stable_id_array(fact["required_statement_ids"], source_path, fact_id, "facts.required_statement_ids")
		if not bool(ids_result.get("ok", false)):
			return ids_result
		for raw_statement_id: Variant in fact["required_statement_ids"] as Array:
			if not statement_by_id.has(String(raw_statement_id)):
				return _error(source_path, fact_id, "facts.required_statement_ids", "unknown_required_statement_id", "Fact 引用不存在的必要 Statement。")
		if not bool(fact["initially_confirmed"]) and (fact["required_statement_ids"] as Array).is_empty() and not ENDING_ONLY_FACT_IDS.has(fact_id):
			return _error(source_path, fact_id, "facts.required_statement_ids", "missing_fact_evidence", "未初始确认的 Fact 至少需要一个 Statement。")
		var normalized: Dictionary = fact.duplicate(true)
		by_id[fact_id] = normalized
		facts.append(normalized)
	for required_id: String in REQUIRED_FACT_IDS:
		if not by_id.has(required_id):
			return _error(source_path, required_id, "facts.id", "missing_required_fact_id", "测试剧情缺少既定 Fact：%s。" % required_id)
	for raw_fact_id: Variant in by_id.keys():
		if not REQUIRED_FACT_IDS.has(String(raw_fact_id)):
			return _error(source_path, String(raw_fact_id), "facts.id", "unknown_test_fact_id", "测试剧情不能声明既定集合外的 Fact。")
	return {"ok": true, "by_id": by_id, "facts": facts}


func _validate_information_references(collections: Array, statement_by_id: Dictionary, fact_by_id: Dictionary, source_path: String) -> Dictionary:
	for raw_collection: Variant in collections:
		if not raw_collection is Array:
			return _error(source_path, "", "information_entries", "invalid_information_collection", "内部信息来源集合必须是数组。")
		for raw_entry: Variant in raw_collection as Array:
			if not raw_entry is Dictionary:
				return _error(source_path, "", "information_entries", "invalid_information_entry", "内部信息来源必须是对象。")
			var entry: Dictionary = raw_entry as Dictionary
			var entry_id: String = String(entry["id"])
			for raw_statement_id: Variant in entry["statement_ids"] as Array:
				var statement_id: String = String(raw_statement_id)
				if not statement_by_id.has(statement_id):
					return _error(source_path, entry_id, "statement_ids", "unknown_statement_id", "电脑来源引用不存在的 Statement。")
				if String((statement_by_id[statement_id] as Dictionary)["source_id"]) != entry_id:
					return _error(source_path, entry_id, "statement_ids", "statement_source_mismatch", "电脑来源只能引用自身 source_id 的 Statement。")
			for raw_fact_id: Variant in entry["fact_ids"] as Array:
				if not fact_by_id.has(String(raw_fact_id)):
					return _error(source_path, entry_id, "fact_ids", "unknown_fact_id", "电脑来源引用不存在的 Fact。")
	return {"ok": true}


func _validate_broadcast_tasks(
	raw_tasks: Array,
	event_by_id: Dictionary,
	statement_by_id: Dictionary,
	condition_ids: Dictionary,
	fact_by_id: Dictionary,
	message_by_id: Dictionary,
	source_path: String
) -> Dictionary:
	if raw_tasks.is_empty():
		return _error(source_path, "", "broadcast_tasks", "empty_broadcast_tasks", "测试剧情至少需要一个发布任务。")
	var task_ids: Dictionary = {}
	var information_ids: Dictionary = {}
	var tasks: Array[Dictionary] = []
	for raw_task: Variant in raw_tasks:
		if not raw_task is Dictionary:
			return _error(source_path, "", "broadcast_tasks", "invalid_broadcast_task_type", "broadcast_tasks 中每项必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = _id_or_empty(task)
		for field_name: String in ["id", "name", "selection_mode", "channel", "source", "related_event_ids", "requirements", "sets_condition_id", "information_items"]:
			if not task.has(field_name):
				return _error(source_path, task_id, field_name, "missing_field", "发布任务缺少字段：%s。" % field_name)
		for legacy_field: String in ["related_dialogue_event_ids", "required_dialogue_event_ids"]:
			if task.has(legacy_field):
				return _error(source_path, task_id, legacy_field, "legacy_dialogue_requirement_forbidden", "Agent Dialogue v2 任务不得依赖预制 dialogue event 完成状态。")
		if not task["id"] is String or not _is_stable_id(String(task["id"])):
			return _error(source_path, task_id, "id", "invalid_broadcast_task_id", "发布任务 ID 无效。")
		task_id = String(task["id"])
		if task_ids.has(task_id):
			return _error(source_path, task_id, "id", "duplicate_broadcast_task_id", "发布任务 ID 重复。")
		task_ids[task_id] = true
		for text_field: String in ["name", "source"]:
			if not task[text_field] is String or String(task[text_field]).strip_edges().is_empty():
				return _error(source_path, task_id, text_field, "invalid_broadcast_task_text", "发布任务 %s 必须非空。" % text_field)
		if not task["channel"] is String or String(task["channel"]) != "microphone":
			return _error(source_path, task_id, "channel", "invalid_broadcast_task_channel", "发布任务 channel 必须为 microphone。")
		if not task["selection_mode"] is String or not ["single", "multiple"].has(String(task["selection_mode"])):
			return _error(source_path, task_id, "selection_mode", "invalid_broadcast_task_selection_mode", "selection_mode 必须为 single 或 multiple。")
		var related_result: Dictionary = _validate_stable_id_array(task["related_event_ids"], source_path, task_id, "related_event_ids")
		if not bool(related_result.get("ok", false)):
			return related_result
		if (task["related_event_ids"] as Array).is_empty():
			return _error(source_path, task_id, "related_event_ids", "empty_related_event_ids", "发布任务至少需要一个相关事件。")
		for raw_event_id: Variant in task["related_event_ids"] as Array:
			if not event_by_id.has(String(raw_event_id)):
				return _error(source_path, task_id, "related_event_ids", "unknown_event_id", "发布任务引用不存在的相关事件：%s。" % String(raw_event_id))
		var requirements_result: Dictionary = _validate_requirements(task["requirements"], task_id, event_by_id, statement_by_id, condition_ids, fact_by_id, message_by_id, task_ids, source_path)
		if not bool(requirements_result.get("ok", false)):
			return requirements_result
		if not task["sets_condition_id"] is String:
			return _error(source_path, task_id, "sets_condition_id", "invalid_sets_condition_id", "sets_condition_id 必须是字符串。")
		var condition_id: String = String(task["sets_condition_id"])
		if not condition_id.is_empty() and (not _is_stable_id(condition_id) or not condition_ids.has(condition_id)):
			return _error(source_path, task_id, "sets_condition_id", "unknown_condition_id", "发布任务引用未声明条件。")
		if not task["information_items"] is Array or (task["information_items"] as Array).is_empty():
			return _error(source_path, task_id, "information_items", "empty_information_items", "发布任务至少需要一个信息项。")
		for raw_item: Variant in task["information_items"] as Array:
			if not raw_item is Dictionary:
				return _error(source_path, task_id, "information_items", "invalid_information_item_type", "信息项必须是对象。")
			var item: Dictionary = raw_item as Dictionary
			for field_name: String in ["id", "source_label", "body", "statement_ids", "fact_ids"]:
				if not item.has(field_name):
					return _error(source_path, task_id, "information_items.%s" % field_name, "missing_field", "信息项缺少字段：%s。" % field_name)
			if not item["id"] is String or not _is_stable_id(String(item["id"])):
				return _error(source_path, task_id, "information_items.id", "invalid_information_item_id", "信息项 ID 无效。")
			var item_id: String = String(item["id"])
			if information_ids.has(item_id):
				return _error(source_path, item_id, "information_items.id", "duplicate_information_item_id", "信息项 ID 必须全局唯一。")
			information_ids[item_id] = true
			for text_field: String in ["source_label", "body"]:
				if not item[text_field] is String or String(item[text_field]).strip_edges().is_empty():
					return _error(source_path, item_id, text_field, "invalid_information_item_text", "信息项 %s 必须非空。" % text_field)
			var statement_result: Dictionary = _validate_stable_id_array(item["statement_ids"], source_path, item_id, "statement_ids")
			if not bool(statement_result.get("ok", false)):
				return statement_result
			if (item["statement_ids"] as Array).is_empty():
				return _error(source_path, item_id, "statement_ids", "empty_information_statements", "每个信息项至少需要一个 Statement。")
			for raw_statement_id: Variant in item["statement_ids"] as Array:
				if not statement_by_id.has(String(raw_statement_id)):
					return _error(source_path, item_id, "statement_ids", "unknown_statement_id", "信息项引用不存在的 Statement。")
			var fact_result: Dictionary = _validate_stable_id_array(item["fact_ids"], source_path, item_id, "fact_ids")
			if not bool(fact_result.get("ok", false)):
				return fact_result
			for raw_fact_id: Variant in item["fact_ids"] as Array:
				if not fact_by_id.has(String(raw_fact_id)):
					return _error(source_path, item_id, "fact_ids", "unknown_fact_id", "信息项引用不存在的 Fact。")
		tasks.append(task.duplicate(true))
	return {"ok": true, "tasks": tasks}


func _validate_requirements(
	value: Variant,
	task_id: String,
	event_by_id: Dictionary,
	statement_by_id: Dictionary,
	condition_ids: Dictionary,
	fact_by_id: Dictionary,
	message_by_id: Dictionary,
	known_task_ids: Dictionary,
	source_path: String
) -> Dictionary:
	if not value is Array or (value as Array).is_empty():
		return _error(source_path, task_id, "requirements", "empty_requirements", "发布任务 requirements 必须是非空数组。")
	var seen: Dictionary = {}
	for raw_requirement: Variant in value as Array:
		if not raw_requirement is Dictionary:
			return _error(source_path, task_id, "requirements", "invalid_requirement_type", "requirement 必须是对象。")
		var requirement: Dictionary = raw_requirement as Dictionary
		if requirement.size() != 2 or not requirement.has("type") or not requirement.has("id"):
			return _error(source_path, task_id, "requirements", "invalid_requirement_shape", "requirement 必须且只能包含 type/id。")
		if not requirement["type"] is String or not SUPPORTED_REQUIREMENT_TYPES.has(String(requirement["type"])):
			return _error(source_path, task_id, "requirements.type", "unsupported_requirement_type", "不支持的 requirement type。")
		if not requirement["id"] is String or not _is_stable_id(String(requirement["id"])):
			return _error(source_path, task_id, "requirements.id", "invalid_requirement_id", "requirement.id 必须是稳定 ID。")
		var requirement_type: String = String(requirement["type"])
		var requirement_id: String = String(requirement["id"])
		var key: String = "%s:%s" % [requirement_type, requirement_id]
		if seen.has(key):
			return _error(source_path, task_id, "requirements", "duplicate_requirement", "发布任务不能重复同一 requirement。")
		seen[key] = true
		match requirement_type:
			"statement_revealed":
				if not statement_by_id.has(requirement_id):
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "statement_revealed 引用不存在的 Statement。")
			"fact_confirmed":
				if not fact_by_id.has(requirement_id):
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "fact_confirmed 引用不存在的 Fact。")
			"condition_true":
				if not condition_ids.has(requirement_id):
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "condition_true 引用不存在的条件。")
			"interaction_answered", "interaction_completed":
				if not event_by_id.has(requirement_id):
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "interaction requirement 引用不存在的来电。")
			"broadcast_sent":
				# 当前任务只能依赖在其之前已经声明的任务，避免循环。
				if not known_task_ids.has(requirement_id) or requirement_id == task_id:
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "broadcast_sent 必须引用此前已声明且不同于自身的任务。")
			"message_read":
				if not message_by_id.has(requirement_id):
					return _error(source_path, task_id, "requirements", "unknown_requirement_id", "message_read 引用不存在的短信。")
	return {"ok": true}


func _validate_statement_coverage(collections: Array, events: Array[Dictionary], statement_by_id: Dictionary, source_path: String) -> Dictionary:
	var reachable: Dictionary = {}
	for raw_collection: Variant in collections:
		for raw_entry: Variant in raw_collection as Array:
			var entry: Dictionary = raw_entry as Dictionary
			for raw_statement_id: Variant in entry["statement_ids"] as Array:
				reachable[String(raw_statement_id)] = true
	for event: Dictionary in events:
		for raw_statement_id: Variant in event["available_statement_ids"] as Array:
			reachable[String(raw_statement_id)] = true
	for raw_statement_id: Variant in statement_by_id.keys():
		var statement_id: String = String(raw_statement_id)
		if not reachable.has(statement_id):
			return _error(source_path, statement_id, "statements.id", "unrevealed_statement", "Statement 没有可达的电脑/短信来源，也未授权给任何 Actor 来电。")
	return {"ok": true}


func _validate_stable_id_array(value: Variant, source_path: String, entry_id: String, field_name: String) -> Dictionary:
	if not value is Array:
		return _error(source_path, entry_id, field_name, "invalid_stable_id_array", "%s 必须是数组。" % field_name)
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not _is_stable_id(String(raw_id)):
			return _error(source_path, entry_id, field_name, "invalid_stable_id", "%s 中每项必须是英文 snake_case ID。" % field_name)
		var stable_id: String = String(raw_id)
		if seen.has(stable_id):
			return _error(source_path, entry_id, field_name, "duplicate_stable_id", "%s 不能包含重复 ID。" % field_name)
		seen[stable_id] = true
	return {"ok": true}


func _validate_text_array(value: Variant, source_path: String, entry_id: String, field_name: String) -> Dictionary:
	if not value is Array:
		return _error(source_path, entry_id, field_name, "invalid_text_array", "%s 必须是数组。" % field_name)
	for raw_text: Variant in value as Array:
		if not raw_text is String or String(raw_text).strip_edges().is_empty():
			return _error(source_path, entry_id, field_name, "invalid_text_array", "%s 只能包含非空字符串。" % field_name)
	return {"ok": true}


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _is_stable_id(candidate: String) -> bool:
	return not candidate.is_empty() \
		and not candidate.begins_with("_") \
		and candidate == candidate.to_lower() \
		and candidate.is_valid_identifier() \
		and candidate.is_valid_ascii_identifier()


func _id_or_empty(value: Dictionary) -> String:
	if value.has("id") and value["id"] is String:
		return String(value["id"])
	return ""


func _error(source_path: String, entry_id: String, field_name: String, error_code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"source_path": source_path,
		"event_id": entry_id,
		"field": field_name,
		"error_code": error_code,
		"message": message,
	}
