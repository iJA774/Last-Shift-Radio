class_name WorldBookValidator
extends RefCounted

## WorldBook v1 的严格数据边界。
##
## WorldKernel（02:00、系统权限、基础玩法等）不属于此 schema；未知字段直接拒绝。
## 作者自然语言只作为数据校验，不在这里解释或执行任何指令。

const FORMAT_VERSION: int = 1
const MANIFEST_FORMAT_VERSION: int = 1
const MAX_WORLD_BOOK_BYTES: int = 1024 * 1024
const MAX_ID_LENGTH: int = 128
const MAX_STRING_LENGTH: int = 4096
const MAX_ARRAY_LENGTH: int = 512
const MAX_NESTING_DEPTH: int = 16
const MAX_ACTORS: int = 64
const MAX_EVENTS: int = 256
const MAX_STATEMENTS: int = 512
const MAX_FACTS: int = 256
const MAX_OPPORTUNITIES: int = 256
const MAX_GOALS: int = 512
const MAX_RELATIONSHIPS: int = 512
const MAX_TASKS: int = 128

const MANIFEST_FIELDS: PackedStringArray = [
	"manifest_format_version",
	"worldbook_id",
	"display_name",
	"worldbook_version",
	"worldbook_file",
]
const WORLD_BOOK_FIELDS: PackedStringArray = [
	"worldbook_format_version",
	"worldbook_id",
	"lore",
	"hidden_truths",
	"relationships",
	"goals",
	"conditions",
	"events",
	"checklist_entries",
	"news_entries",
	"messages",
	"broadcast_tasks",
	"actors",
	"statements",
	"facts",
	"opportunities",
	"narrative_constraints",
]
const WORLD_KERNEL_FORBIDDEN_FIELDS: PackedStringArray = [
	"world_kernel",
	"kernel_rules",
	"game_start",
	"game_end",
	"ending_tick",
	"shift_duration_minutes",
	"story_engine_authority",
	"phone_system_authority",
	"game_clock_authority",
	"model_permissions",
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
const SUPPORTED_REQUIREMENT_TYPES: PackedStringArray = [
	"statement_revealed",
	"fact_confirmed",
	"condition_true",
	"interaction_answered",
	"interaction_completed",
	"broadcast_sent",
	"message_read",
]
const GLOBAL_ID_COLLECTION_FIELDS: PackedStringArray = [
	"actors",
	"goals",
	"conditions",
	"events",
	"checklist_entries",
	"news_entries",
	"messages",
	"broadcast_tasks",
	"statements",
	"facts",
	"relationships",
	"hidden_truths",
	"opportunities",
]


func load_and_validate(manifest_path: String) -> Dictionary:
	if manifest_path.strip_edges().is_empty():
		return _error(manifest_path, "", "", "$", "invalid_manifest_path", "WorldBook manifest 路径不能为空。")
	if not manifest_path.begins_with("res://worldbooks/") and not manifest_path.begins_with("user://worldbooks/"):
		return _error(manifest_path, "", "", "$", "invalid_manifest_path", "WorldBook v1 只允许从 res://worldbooks/ 或 user://worldbooks/ 加载。")
	if manifest_path.contains("..") or manifest_path.contains("\\") or not manifest_path.ends_with("/manifest.json"):
		return _error(manifest_path, "", "", "$", "invalid_manifest_path", "WorldBook manifest 必须位于独立 worldbooks 子目录并命名为 manifest.json。")
	var manifest_load: Dictionary = _load_json_with_limit(manifest_path, 64 * 1024, "manifest")
	if not bool(manifest_load.get("ok", false)):
		return manifest_load
	var manifest_value: Variant = manifest_load.get("data")
	if not manifest_value is Dictionary:
		return _error(manifest_path, "", "", "$", "invalid_manifest_type", "WorldBook manifest 顶层必须是 JSON 对象。")
	var manifest_result: Dictionary = _validate_manifest(manifest_value as Dictionary, manifest_path)
	if not bool(manifest_result.get("ok", false)):
		return manifest_result
	var manifest: Dictionary = manifest_result["manifest"] as Dictionary
	var worldbook_file: String = String(manifest["worldbook_file"])
	# v1 不允许 manifest 通过路径跳转读取其它资源。社区包必须是自包含 JSON 目录。
	if worldbook_file != "worldbook.json":
		return _error(manifest_path, String(manifest["worldbook_id"]), "", "worldbook_file", "invalid_worldbook_file", "WorldBook v1 的 worldbook_file 必须精确为 worldbook.json。")
	var base_dir: String = manifest_path.get_base_dir()
	var worldbook_path: String = base_dir.path_join(worldbook_file)
	var worldbook_load: Dictionary = _load_json_with_limit(worldbook_path, MAX_WORLD_BOOK_BYTES, "worldbook")
	if not bool(worldbook_load.get("ok", false)):
		worldbook_load["worldbook_id"] = String(manifest["worldbook_id"])
		return worldbook_load
	return validate(
		manifest,
		worldbook_load.get("data"),
		manifest_path,
		worldbook_path,
		int(worldbook_load.get("byte_size", 0))
	)


func validate(
	manifest_value: Variant,
	worldbook_value: Variant,
	manifest_path: String = "memory://manifest.json",
	worldbook_path: String = "memory://worldbook.json",
	worldbook_byte_size: int = -1
) -> Dictionary:
	if not manifest_value is Dictionary:
		return _error(manifest_path, "", "", "$", "invalid_manifest_type", "WorldBook manifest 顶层必须是 JSON 对象。")
	var manifest_result: Dictionary = _validate_manifest(manifest_value as Dictionary, manifest_path)
	if not bool(manifest_result.get("ok", false)):
		return manifest_result
	var manifest: Dictionary = manifest_result["manifest"] as Dictionary
	var worldbook_id: String = String(manifest["worldbook_id"])
	if worldbook_byte_size > MAX_WORLD_BOOK_BYTES:
		return _error(worldbook_path, worldbook_id, "", "$", "worldbook_too_large", "WorldBook 超过 %d 字节硬上限。" % MAX_WORLD_BOOK_BYTES)
	if not worldbook_value is Dictionary:
		return _error(worldbook_path, worldbook_id, "", "$", "invalid_worldbook_type", "WorldBook 顶层必须是 JSON 对象。")
	var root: Dictionary = worldbook_value as Dictionary
	var limit_result: Dictionary = _validate_value_limits(root, worldbook_path, worldbook_id, "$", 0)
	if not bool(limit_result.get("ok", false)):
		return limit_result
	for forbidden_field: String in WORLD_KERNEL_FORBIDDEN_FIELDS:
		if root.has(forbidden_field):
			return _error(worldbook_path, worldbook_id, "", forbidden_field, "world_kernel_field_forbidden", "WorldKernel 字段不得进入玩家 WorldBook：%s。" % forbidden_field)
	var fields_result: Dictionary = _require_exact_fields(root, WORLD_BOOK_FIELDS, worldbook_path, worldbook_id, "", "$", "WorldBook")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	var version_result: Dictionary = _read_exact_integer(root["worldbook_format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != FORMAT_VERSION:
		return _error(worldbook_path, worldbook_id, "", "worldbook_format_version", "invalid_worldbook_format_version", "worldbook_format_version 必须精确为整数 1。")
	if not root["worldbook_id"] is String or String(root["worldbook_id"]) != worldbook_id:
		return _error(worldbook_path, worldbook_id, "", "worldbook_id", "worldbook_id_mismatch", "manifest 与 worldbook 的 worldbook_id 必须一致。")
	for array_field: String in ["hidden_truths", "relationships", "goals", "conditions", "events", "checklist_entries", "news_entries", "messages", "broadcast_tasks", "actors", "statements", "facts", "opportunities"]:
		if not root[array_field] is Array:
			return _error(worldbook_path, worldbook_id, "", array_field, "invalid_array_field", "%s 必须是数组。" % array_field)
	var global_id_result: Dictionary = _validate_global_id_uniqueness(root, worldbook_path, worldbook_id)
	if not bool(global_id_result.get("ok", false)):
		return global_id_result

	var lore_result: Dictionary = _validate_lore(root["lore"], worldbook_path, worldbook_id)
	if not bool(lore_result.get("ok", false)):
		return lore_result
	var constraints_result: Dictionary = _validate_narrative_constraints(root["narrative_constraints"], worldbook_path, worldbook_id)
	if not bool(constraints_result.get("ok", false)):
		return constraints_result
	var conditions_result: Dictionary = _validate_id_collection(root["conditions"] as Array, "conditions", MAX_ARRAY_LENGTH, worldbook_path, worldbook_id, PackedStringArray(["id"]))
	if not bool(conditions_result.get("ok", false)):
		return conditions_result
	var actors_result: Dictionary = _validate_actors(root["actors"] as Array, worldbook_path, worldbook_id)
	if not bool(actors_result.get("ok", false)):
		return actors_result
	var goals_result: Dictionary = _validate_goals(root["goals"] as Array, actors_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(goals_result.get("ok", false)):
		return goals_result
	var actor_goal_result: Dictionary = _validate_actor_goal_references(actors_result["actors"] as Array[Dictionary], goals_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(actor_goal_result.get("ok", false)):
		return actor_goal_result
	var events_result: Dictionary = _validate_events(root["events"] as Array, actors_result["by_id"] as Dictionary, conditions_result["by_id"] as Dictionary, goals_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(events_result.get("ok", false)):
		return events_result
	var checklist_result: Dictionary = _validate_information_entries(root["checklist_entries"] as Array, "checklist_entries", false, worldbook_path, worldbook_id)
	if not bool(checklist_result.get("ok", false)):
		return checklist_result
	var news_result: Dictionary = _validate_information_entries(root["news_entries"] as Array, "news_entries", true, worldbook_path, worldbook_id)
	if not bool(news_result.get("ok", false)):
		return news_result
	var messages_result: Dictionary = _validate_messages(root["messages"] as Array, worldbook_path, worldbook_id)
	if not bool(messages_result.get("ok", false)):
		return messages_result
	var source_result: Dictionary = _combine_source_ids([events_result["by_id"], checklist_result["by_id"], news_result["by_id"], messages_result["by_id"]], worldbook_path, worldbook_id)
	if not bool(source_result.get("ok", false)):
		return source_result
	var statements_result: Dictionary = _validate_statements(root["statements"] as Array, source_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(statements_result.get("ok", false)):
		return statements_result
	var event_statement_result: Dictionary = _validate_event_statement_references(events_result["events"] as Array[Dictionary], statements_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(event_statement_result.get("ok", false)):
		return event_statement_result
	var facts_result: Dictionary = _validate_facts(root["facts"] as Array, statements_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(facts_result.get("ok", false)):
		return facts_result
	var info_refs_result: Dictionary = _validate_information_references([checklist_result["items"], news_result["items"], messages_result["items"]], statements_result["by_id"] as Dictionary, facts_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(info_refs_result.get("ok", false)):
		return info_refs_result
	var tasks_result: Dictionary = _validate_tasks(root["broadcast_tasks"] as Array, events_result["by_id"] as Dictionary, statements_result["by_id"] as Dictionary, facts_result["by_id"] as Dictionary, conditions_result["by_id"] as Dictionary, messages_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(tasks_result.get("ok", false)):
		return tasks_result
	var relationships_result: Dictionary = _validate_relationships(root["relationships"] as Array, actors_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(relationships_result.get("ok", false)):
		return relationships_result
	var truths_result: Dictionary = _validate_hidden_truths(root["hidden_truths"] as Array, worldbook_path, worldbook_id)
	if not bool(truths_result.get("ok", false)):
		return truths_result
	var opportunities_result: Dictionary = _validate_opportunities(root["opportunities"] as Array, actors_result["by_id"] as Dictionary, events_result["by_id"] as Dictionary, conditions_result["by_id"] as Dictionary, goals_result["by_id"] as Dictionary, worldbook_path, worldbook_id)
	if not bool(opportunities_result.get("ok", false)):
		return opportunities_result

	return {
		"ok": true,
		"manifest_path": manifest_path,
		"source_path": worldbook_path,
		"worldbook_id": worldbook_id,
		"manifest": manifest.duplicate(true),
		"worldbook": root.duplicate(true),
		"byte_size": worldbook_byte_size,
	}


func _validate_manifest(manifest: Dictionary, source_path: String) -> Dictionary:
	var worldbook_id: String = String(manifest.get("worldbook_id", ""))
	var limit_result: Dictionary = _validate_value_limits(manifest, source_path, worldbook_id, "$", 0)
	if not bool(limit_result.get("ok", false)):
		return limit_result
	var fields_result: Dictionary = _require_exact_fields(manifest, MANIFEST_FIELDS, source_path, worldbook_id, "", "$", "WorldBook manifest")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	var version_result: Dictionary = _read_exact_integer(manifest["manifest_format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != MANIFEST_FORMAT_VERSION:
		return _error(source_path, worldbook_id, "", "manifest_format_version", "invalid_manifest_format_version", "manifest_format_version 必须精确为整数 1。")
	if not manifest["worldbook_id"] is String or not _is_stable_id(String(manifest["worldbook_id"])):
		return _error(source_path, worldbook_id, "", "worldbook_id", "invalid_worldbook_id", "worldbook_id 必须是英文 snake_case 稳定 ID。")
	worldbook_id = String(manifest["worldbook_id"])
	if not manifest["display_name"] is String or String(manifest["display_name"]).strip_edges().is_empty():
		return _error(source_path, worldbook_id, "", "display_name", "invalid_display_name", "manifest.display_name 必须是非空字符串。")
	var worldbook_version_result: Dictionary = _read_exact_integer(manifest["worldbook_version"])
	if not bool(worldbook_version_result.get("ok", false)) or int(worldbook_version_result["value"]) <= 0:
		return _error(source_path, worldbook_id, "", "worldbook_version", "invalid_worldbook_version", "worldbook_version 必须是正整数。")
	if not manifest["worldbook_file"] is String or String(manifest["worldbook_file"]) != "worldbook.json":
		return _error(source_path, worldbook_id, "", "worldbook_file", "invalid_worldbook_file", "WorldBook v1 的 worldbook_file 必须精确为 worldbook.json。")
	# JSON Parser 会把数字读取为 float；Validator 成功结果必须把已经证明为精确整数的
	# 身份字段规范化为 int，避免 Compiler、存档与 Main 再次解释原始 JSON 类型。
	var normalized_manifest: Dictionary = manifest.duplicate(true)
	normalized_manifest["manifest_format_version"] = int(version_result["value"])
	normalized_manifest["worldbook_version"] = int(worldbook_version_result["value"])
	return {"ok": true, "manifest": normalized_manifest}


func _validate_lore(value: Variant, source_path: String, worldbook_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, worldbook_id, "", "lore", "invalid_lore", "lore 必须是对象。")
	var lore: Dictionary = value as Dictionary
	var fields: PackedStringArray = ["premise", "themes", "atmosphere", "director_notes"]
	var fields_result: Dictionary = _require_exact_fields(lore, fields, source_path, worldbook_id, "", "lore", "lore")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	for text_field: String in ["premise", "atmosphere"]:
		if not lore[text_field] is String or String(lore[text_field]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, "", "lore.%s" % text_field, "invalid_lore_text", "lore.%s 必须是非空字符串。" % text_field)
	for array_field: String in ["themes", "director_notes"]:
		var text_result: Dictionary = _validate_text_array(lore[array_field], source_path, worldbook_id, "", "lore.%s" % array_field, true)
		if not bool(text_result.get("ok", false)):
			return text_result
	return {"ok": true}


func _validate_narrative_constraints(value: Variant, source_path: String, worldbook_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, worldbook_id, "", "narrative_constraints", "invalid_narrative_constraints", "narrative_constraints 必须是对象。")
	var constraints: Dictionary = value as Dictionary
	var fields_result: Dictionary = _require_exact_fields(constraints, PackedStringArray(["notes"]), source_path, worldbook_id, "", "narrative_constraints", "narrative_constraints")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	return _validate_text_array(constraints["notes"], source_path, worldbook_id, "", "narrative_constraints.notes", true)


func _validate_actors(raw_actors: Array, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_actors.is_empty() or raw_actors.size() > MAX_ACTORS:
		return _error(source_path, worldbook_id, "", "actors", "invalid_actor_count", "actors 数量必须在 1..%d。" % MAX_ACTORS)
	var by_id: Dictionary = {}
	var actors: Array[Dictionary] = []
	for raw_actor: Variant in raw_actors:
		if not raw_actor is Dictionary:
			return _error(source_path, worldbook_id, "", "actors", "invalid_actor_type", "actors 中每项必须是对象。")
		var actor: Dictionary = raw_actor as Dictionary
		var actor_id: String = _id_or_empty(actor)
		var fields: PackedStringArray = ["id", "display_name", "voice_profile_id", "profile", "initial_state"]
		var fields_result: Dictionary = _require_exact_fields(actor, fields, source_path, worldbook_id, actor_id, "actors", "Actor")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not actor["id"] is String or not _is_stable_id(String(actor["id"])):
			return _error(source_path, worldbook_id, actor_id, "actors.id", "invalid_actor_id", "Actor ID 必须是英文 snake_case。")
		actor_id = String(actor["id"])
		if by_id.has(actor_id):
			return _error(source_path, worldbook_id, actor_id, "actors.id", "duplicate_actor_id", "Actor ID 重复。")
		for text_field: String in ["display_name", "voice_profile_id"]:
			if not actor[text_field] is String or String(actor[text_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, actor_id, "actors.%s" % text_field, "invalid_actor_text", "Actor %s 必须是非空字符串。" % text_field)
		if not actor["profile"] is Dictionary:
			return _error(source_path, worldbook_id, actor_id, "actors.profile", "invalid_actor_profile", "Actor profile 必须是对象。")
		var profile: Dictionary = actor["profile"] as Dictionary
		var profile_fields: PackedStringArray = ["role", "personality", "speech_style"]
		var profile_result: Dictionary = _require_exact_fields(profile, profile_fields, source_path, worldbook_id, actor_id, "actors.profile", "Actor profile")
		if not bool(profile_result.get("ok", false)):
			return profile_result
		for profile_field: String in profile_fields:
			if not profile[profile_field] is String or String(profile[profile_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, actor_id, "actors.profile.%s" % profile_field, "invalid_actor_profile", "Actor profile.%s 必须是非空字符串。" % profile_field)
		if not actor["initial_state"] is Dictionary:
			return _error(source_path, worldbook_id, actor_id, "actors.initial_state", "invalid_actor_state", "Actor initial_state 必须是对象。")
		var state_result: Dictionary = _validate_actor_state(actor_id, actor["initial_state"] as Dictionary, source_path, worldbook_id)
		if not bool(state_result.get("ok", false)):
			return state_result
		by_id[actor_id] = actor.duplicate(true)
		actors.append(actor.duplicate(true))
	return {"ok": true, "by_id": by_id, "actors": actors}


func _validate_actor_state(actor_id: String, state: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	var fields_result: Dictionary = _require_exact_fields(state, ACTOR_STATE_FIELDS, source_path, worldbook_id, actor_id, "actors.initial_state", "Actor initial_state")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	for text_array_field: String in ["knowledge", "beliefs", "episodic_memory", "private_information", "forbidden_knowledge"]:
		var text_result: Dictionary = _validate_text_array(state[text_array_field], source_path, worldbook_id, actor_id, "actors.initial_state.%s" % text_array_field, true)
		if not bool(text_result.get("ok", false)):
			return text_result
	for ids_field: String in ["available_goal_ids", "heard_signal_ids"]:
		var ids_result: Dictionary = _validate_stable_id_array(state[ids_field], source_path, worldbook_id, actor_id, "actors.initial_state.%s" % ids_field)
		if not bool(ids_result.get("ok", false)):
			return ids_result
	if not state["current_goal"] is String:
		return _error(source_path, worldbook_id, actor_id, "actors.initial_state.current_goal", "invalid_current_goal", "current_goal 必须是字符串。")
	for scalar_field: String in ["trust", "stress"]:
		if typeof(state[scalar_field]) != TYPE_INT and typeof(state[scalar_field]) != TYPE_FLOAT:
			return _error(source_path, worldbook_id, actor_id, "actors.initial_state.%s" % scalar_field, "invalid_actor_scalar", "%s 必须是 0..1 数值。" % scalar_field)
		var scalar: float = float(state[scalar_field])
		if is_nan(scalar) or is_inf(scalar) or scalar < 0.0 or scalar > 1.0:
			return _error(source_path, worldbook_id, actor_id, "actors.initial_state.%s" % scalar_field, "invalid_actor_scalar", "%s 必须是 0..1 数值。" % scalar_field)
	return {"ok": true}


func _validate_goals(raw_goals: Array, actor_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_goals.size() > MAX_GOALS:
		return _error(source_path, worldbook_id, "", "goals", "too_many_goals", "goals 超过 %d 条硬上限。" % MAX_GOALS)
	var by_id: Dictionary = {}
	for raw_goal: Variant in raw_goals:
		if not raw_goal is Dictionary:
			return _error(source_path, worldbook_id, "", "goals", "invalid_goal_type", "goals 中每项必须是对象。")
		var goal: Dictionary = raw_goal as Dictionary
		var goal_id: String = _id_or_empty(goal)
		var fields_result: Dictionary = _require_exact_fields(goal, PackedStringArray(["id", "actor_id", "description"]), source_path, worldbook_id, goal_id, "goals", "Goal")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not goal["id"] is String or not _is_stable_id(String(goal["id"])):
			return _error(source_path, worldbook_id, goal_id, "goals.id", "invalid_goal_id", "Goal ID 必须是英文 snake_case。")
		goal_id = String(goal["id"])
		if by_id.has(goal_id):
			return _error(source_path, worldbook_id, goal_id, "goals.id", "duplicate_goal_id", "Goal ID 重复。")
		if not goal["actor_id"] is String or not actor_by_id.has(String(goal["actor_id"])):
			return _error(source_path, worldbook_id, goal_id, "goals.actor_id", "unknown_actor_id", "Goal 必须引用已声明 Actor。")
		if not goal["description"] is String or String(goal["description"]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, goal_id, "goals.description", "invalid_goal_description", "Goal description 必须是非空字符串。")
		by_id[goal_id] = goal.duplicate(true)
	return {"ok": true, "by_id": by_id}


func _validate_actor_goal_references(actors: Array[Dictionary], goal_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	for actor: Dictionary in actors:
		var actor_id: String = String(actor["id"])
		var state: Dictionary = actor["initial_state"] as Dictionary
		for raw_goal_id: Variant in state["available_goal_ids"] as Array:
			var goal_id: String = String(raw_goal_id)
			if not goal_by_id.has(goal_id):
				return _error(source_path, worldbook_id, actor_id, "actors.initial_state.available_goal_ids", "unknown_goal_id", "Actor 引用了未声明 Goal：%s。" % goal_id)
			if String((goal_by_id[goal_id] as Dictionary)["actor_id"]) != actor_id:
				return _error(source_path, worldbook_id, actor_id, "actors.initial_state.available_goal_ids", "goal_actor_mismatch", "Actor 不能引用属于其他 Actor 的 Goal：%s。" % goal_id)
		var current_goal: String = String(state["current_goal"])
		if not current_goal.is_empty() and not (state["available_goal_ids"] as Array).has(current_goal):
			return _error(source_path, worldbook_id, actor_id, "actors.initial_state.current_goal", "current_goal_not_available", "current_goal 必须为空或来自 available_goal_ids。")
	return {"ok": true}


func _validate_events(raw_events: Array, actor_by_id: Dictionary, condition_by_id: Dictionary, goal_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_events.is_empty() or raw_events.size() > MAX_EVENTS:
		return _error(source_path, worldbook_id, "", "events", "invalid_event_count", "events 数量必须在 1..%d。" % MAX_EVENTS)
	var by_id: Dictionary = {}
	var events: Array[Dictionary] = []
	for raw_event: Variant in raw_events:
		if not raw_event is Dictionary:
			return _error(source_path, worldbook_id, "", "events", "invalid_event_type", "events 中每项必须是对象。")
		var event: Dictionary = raw_event as Dictionary
		var event_id: String = _id_or_empty(event)
		var required_fields: PackedStringArray = ["id", "kind", "priority", "window_start_minute", "window_end_minute", "when_busy", "on_expire", "condition_ids", "caller_display_name", "caller_number", "actor_id", "available_statement_ids", "line_profile_id", "call_reason", "opening_intent", "fallback_utterance"]
		var allowed_fields: PackedStringArray = required_fields.duplicate()
		allowed_fields.append("session_state_patch")
		var fields_result: Dictionary = _require_fields_and_allow_only(event, required_fields, allowed_fields, source_path, worldbook_id, event_id, "events", "Event")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if event.has("dialogue_start_id"):
			return _error(source_path, worldbook_id, event_id, "events.dialogue_start_id", "legacy_dialogue_start_forbidden", "WorldBook v1 Agent Dialogue 事件不得使用 dialogue_start_id。")
		if not event["id"] is String or not _is_stable_id(String(event["id"])):
			return _error(source_path, worldbook_id, event_id, "events.id", "invalid_event_id", "Event ID 必须是英文 snake_case。")
		event_id = String(event["id"])
		if by_id.has(event_id):
			return _error(source_path, worldbook_id, event_id, "events.id", "duplicate_event_id", "Event ID 重复。")
		if not event["kind"] is String or String(event["kind"]) != "incoming_call":
			return _error(source_path, worldbook_id, event_id, "events.kind", "unsupported_event_kind", "WorldBook v1 暂只支持 incoming_call 事件。")
		if not event["priority"] is String or not ["main", "normal"].has(String(event["priority"])):
			return _error(source_path, worldbook_id, event_id, "events.priority", "invalid_priority", "priority 必须为 main 或 normal。")
		if not event["when_busy"] is String or not ["queue", "expire"].has(String(event["when_busy"])):
			return _error(source_path, worldbook_id, event_id, "events.when_busy", "invalid_when_busy", "when_busy 必须为 queue 或 expire。")
		if not event["on_expire"] is String or String(event["on_expire"]) != "mark_missed":
			return _error(source_path, worldbook_id, event_id, "events.on_expire", "invalid_on_expire", "on_expire 必须为 mark_missed。")
		var start_result: Dictionary = _read_exact_integer(event["window_start_minute"])
		var end_result: Dictionary = _read_exact_integer(event["window_end_minute"])
		if not bool(start_result.get("ok", false)) or not bool(end_result.get("ok", false)):
			return _error(source_path, worldbook_id, event_id, "events.window_start_minute/window_end_minute", "invalid_time_window", "事件时间窗必须使用整数分钟。")
		var start_minute: int = int(start_result["value"])
		var end_minute: int = int(end_result["value"])
		# 0..59 来自不可变 WorldKernel；WorldBook 只能在该窗口内部放置事件。
		if start_minute < 0 or end_minute < start_minute or end_minute >= 60:
			return _error(source_path, worldbook_id, event_id, "events.window_start_minute/window_end_minute", "invalid_time_window", "事件时间窗必须满足 0 <= start <= end < 60。")
		if not event["actor_id"] is String or not actor_by_id.has(String(event["actor_id"])):
			return _error(source_path, worldbook_id, event_id, "events.actor_id", "unknown_actor_id", "来电引用了未声明 Actor。")
		var condition_result: Dictionary = _validate_stable_id_array(event["condition_ids"], source_path, worldbook_id, event_id, "events.condition_ids")
		if not bool(condition_result.get("ok", false)):
			return condition_result
		for raw_condition_id: Variant in event["condition_ids"] as Array:
			if not condition_by_id.has(String(raw_condition_id)):
				return _error(source_path, worldbook_id, event_id, "events.condition_ids", "unknown_condition_id", "事件引用了未声明 Condition：%s。" % String(raw_condition_id))
		var statements_result: Dictionary = _validate_stable_id_array(event["available_statement_ids"], source_path, worldbook_id, event_id, "events.available_statement_ids")
		if not bool(statements_result.get("ok", false)):
			return statements_result
		for text_field: String in ["caller_display_name", "caller_number", "line_profile_id", "call_reason", "opening_intent", "fallback_utterance"]:
			if not event[text_field] is String or String(event[text_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, event_id, "events.%s" % text_field, "invalid_event_text", "%s 必须是非空字符串。" % text_field)
		if event.has("session_state_patch"):
			var patch_result: Dictionary = _validate_session_state_patch(event["session_state_patch"], String(event["actor_id"]), goal_by_id, source_path, worldbook_id, event_id)
			if not bool(patch_result.get("ok", false)):
				return patch_result
		by_id[event_id] = event.duplicate(true)
		events.append(event.duplicate(true))
	return {"ok": true, "by_id": by_id, "events": events}


func _validate_session_state_patch(value: Variant, actor_id: String, goal_by_id: Dictionary, source_path: String, worldbook_id: String, event_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, worldbook_id, event_id, "events.session_state_patch", "invalid_session_state_patch", "session_state_patch 必须是对象。")
	var patch: Dictionary = value as Dictionary
	var allowed_fields: PackedStringArray = ["knowledge", "beliefs", "episodic_memory", "current_goal", "trust", "stress"]
	for raw_key: Variant in patch.keys():
		if not allowed_fields.has(String(raw_key)):
			return _error(source_path, worldbook_id, event_id, "events.session_state_patch", "unknown_session_state_patch_field", "session_state_patch 含未知字段：%s。" % String(raw_key))
	for array_field: String in ["knowledge", "beliefs", "episodic_memory"]:
		if patch.has(array_field):
			var text_result: Dictionary = _validate_text_array(patch[array_field], source_path, worldbook_id, event_id, "events.session_state_patch.%s" % array_field, true)
			if not bool(text_result.get("ok", false)):
				return text_result
	if patch.has("current_goal"):
		if not patch["current_goal"] is String:
			return _error(source_path, worldbook_id, event_id, "events.session_state_patch.current_goal", "invalid_session_state_patch_goal", "session_state_patch.current_goal 必须是字符串。")
		var goal_id: String = String(patch["current_goal"])
		if not goal_id.is_empty() and (not goal_by_id.has(goal_id) or String((goal_by_id[goal_id] as Dictionary)["actor_id"]) != actor_id):
			return _error(source_path, worldbook_id, event_id, "events.session_state_patch.current_goal", "unknown_goal_id", "session_state_patch.current_goal 必须引用当前 Actor 已声明 Goal。")
	for scalar_field: String in ["trust", "stress"]:
		if patch.has(scalar_field):
			if typeof(patch[scalar_field]) != TYPE_INT and typeof(patch[scalar_field]) != TYPE_FLOAT:
				return _error(source_path, worldbook_id, event_id, "events.session_state_patch.%s" % scalar_field, "invalid_session_state_patch_scalar", "%s patch 必须是 0..1 数值。" % scalar_field)
			var scalar: float = float(patch[scalar_field])
			if is_nan(scalar) or is_inf(scalar) or scalar < 0.0 or scalar > 1.0:
				return _error(source_path, worldbook_id, event_id, "events.session_state_patch.%s" % scalar_field, "invalid_session_state_patch_scalar", "%s patch 必须是 0..1 数值。" % scalar_field)
	return {"ok": true}


func _validate_information_entries(raw_items: Array, collection_name: String, requires_source: bool, source_path: String, worldbook_id: String) -> Dictionary:
	var by_id: Dictionary = {}
	var items: Array[Dictionary] = []
	for raw_item: Variant in raw_items:
		if not raw_item is Dictionary:
			return _error(source_path, worldbook_id, "", collection_name, "invalid_information_entry_type", "%s 中每项必须是对象。" % collection_name)
		var item: Dictionary = raw_item as Dictionary
		var item_id: String = _id_or_empty(item)
		var required_fields: PackedStringArray = ["id", "title", "body", "unlock_minute", "statement_ids", "fact_ids"]
		var allowed_fields: PackedStringArray = required_fields.duplicate()
		if requires_source:
			required_fields.append("source")
			allowed_fields.append("source")
		if collection_name == "news_entries":
			required_fields.append("topic_ids")
			allowed_fields.append("topic_ids")
		var fields_result: Dictionary = _require_fields_and_allow_only(item, required_fields, allowed_fields, source_path, worldbook_id, item_id, collection_name, "Information entry")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not item["id"] is String or not _is_stable_id(String(item["id"])):
			return _error(source_path, worldbook_id, item_id, "%s.id" % collection_name, "invalid_information_id", "信息来源 ID 必须是英文 snake_case。")
		item_id = String(item["id"])
		if by_id.has(item_id):
			return _error(source_path, worldbook_id, item_id, "%s.id" % collection_name, "duplicate_information_id", "信息来源 ID 重复。")
		for text_field: String in ["title", "body"]:
			if not item[text_field] is String or String(item[text_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, item_id, "%s.%s" % [collection_name, text_field], "invalid_information_text", "%s 必须是非空字符串。" % text_field)
		if requires_source and (not item["source"] is String or String(item["source"]).strip_edges().is_empty()):
			return _error(source_path, worldbook_id, item_id, "%s.source" % collection_name, "invalid_information_source", "source 必须是非空字符串。")
		var minute_result: Dictionary = _read_exact_integer(item["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= 60:
			return _error(source_path, worldbook_id, item_id, "%s.unlock_minute" % collection_name, "invalid_unlock_minute", "unlock_minute 必须在 0..59。")
		for ids_field: String in ["statement_ids", "fact_ids"]:
			var ids_result: Dictionary = _validate_stable_id_array(item[ids_field], source_path, worldbook_id, item_id, "%s.%s" % [collection_name, ids_field])
			if not bool(ids_result.get("ok", false)):
				return ids_result
		if collection_name == "news_entries":
			var topic_result: Dictionary = _validate_stable_id_array(item["topic_ids"], source_path, worldbook_id, item_id, "news_entries.topic_ids")
			if not bool(topic_result.get("ok", false)):
				return topic_result
		by_id[item_id] = item.duplicate(true)
		items.append(item.duplicate(true))
	return {"ok": true, "by_id": by_id, "items": items}


func _validate_messages(raw_items: Array, source_path: String, worldbook_id: String) -> Dictionary:
	var by_id: Dictionary = {}
	var items: Array[Dictionary] = []
	for raw_item: Variant in raw_items:
		if not raw_item is Dictionary:
			return _error(source_path, worldbook_id, "", "messages", "invalid_message_type", "messages 中每项必须是对象。")
		var item: Dictionary = raw_item as Dictionary
		var item_id: String = _id_or_empty(item)
		var fields: PackedStringArray = ["id", "sender", "body", "unlock_minute", "statement_ids", "fact_ids"]
		var fields_result: Dictionary = _require_exact_fields(item, fields, source_path, worldbook_id, item_id, "messages", "Message")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not item["id"] is String or not _is_stable_id(String(item["id"])):
			return _error(source_path, worldbook_id, item_id, "messages.id", "invalid_message_id", "Message ID 必须是英文 snake_case。")
		item_id = String(item["id"])
		if by_id.has(item_id):
			return _error(source_path, worldbook_id, item_id, "messages.id", "duplicate_message_id", "Message ID 重复。")
		for text_field: String in ["sender", "body"]:
			if not item[text_field] is String or String(item[text_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, item_id, "messages.%s" % text_field, "invalid_message_text", "%s 必须是非空字符串。" % text_field)
		var minute_result: Dictionary = _read_exact_integer(item["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= 60:
			return _error(source_path, worldbook_id, item_id, "messages.unlock_minute", "invalid_unlock_minute", "Message unlock_minute 必须在 0..59。")
		for ids_field: String in ["statement_ids", "fact_ids"]:
			var ids_result: Dictionary = _validate_stable_id_array(item[ids_field], source_path, worldbook_id, item_id, "messages.%s" % ids_field)
			if not bool(ids_result.get("ok", false)):
				return ids_result
		by_id[item_id] = item.duplicate(true)
		items.append(item.duplicate(true))
	return {"ok": true, "by_id": by_id, "items": items}


func _combine_source_ids(collections: Array, source_path: String, worldbook_id: String) -> Dictionary:
	var by_id: Dictionary = {}
	for raw_collection: Variant in collections:
		var collection: Dictionary = raw_collection as Dictionary
		for raw_id: Variant in collection.keys():
			var source_id: String = String(raw_id)
			if by_id.has(source_id):
				return _error(source_path, worldbook_id, source_id, "id", "duplicate_source_id", "电话、电脑来源与消息不能复用稳定 ID。")
			by_id[source_id] = true
	return {"ok": true, "by_id": by_id}


func _validate_statements(raw_statements: Array, source_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_statements.size() > MAX_STATEMENTS:
		return _error(source_path, worldbook_id, "", "statements", "too_many_statements", "statements 超过 %d 条硬上限。" % MAX_STATEMENTS)
	var by_id: Dictionary = {}
	for raw_statement: Variant in raw_statements:
		if not raw_statement is Dictionary:
			return _error(source_path, worldbook_id, "", "statements", "invalid_statement_type", "statements 中每项必须是对象。")
		var statement: Dictionary = raw_statement as Dictionary
		var statement_id: String = _id_or_empty(statement)
		var required_fields: PackedStringArray = ["id", "source_id", "body"]
		var allowed_fields: PackedStringArray = ["id", "source_id", "body", "semantic_guard"]
		var fields_result: Dictionary = _require_fields_and_allow_only(statement, required_fields, allowed_fields, source_path, worldbook_id, statement_id, "statements", "Statement")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not statement["id"] is String or not _is_stable_id(String(statement["id"])):
			return _error(source_path, worldbook_id, statement_id, "statements.id", "invalid_statement_id", "Statement ID 必须是英文 snake_case。")
		statement_id = String(statement["id"])
		if by_id.has(statement_id):
			return _error(source_path, worldbook_id, statement_id, "statements.id", "duplicate_statement_id", "Statement ID 重复。")
		if not statement["source_id"] is String or not source_by_id.has(String(statement["source_id"])):
			return _error(source_path, worldbook_id, statement_id, "statements.source_id", "unknown_statement_source_id", "Statement source_id 必须引用现有来源。")
		if not statement["body"] is String or String(statement["body"]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, statement_id, "statements.body", "invalid_statement_body", "Statement body 必须是非空字符串。")
		if statement.has("semantic_guard"):
			var guard_result: Dictionary = _validate_semantic_guard(statement["semantic_guard"], source_path, worldbook_id, statement_id)
			if not bool(guard_result.get("ok", false)):
				return guard_result
		by_id[statement_id] = statement.duplicate(true)
	return {"ok": true, "by_id": by_id}


func _validate_semantic_guard(value: Variant, source_path: String, worldbook_id: String, statement_id: String) -> Dictionary:
	if not value is Dictionary:
		return _error(source_path, worldbook_id, statement_id, "statements.semantic_guard", "invalid_semantic_guard", "semantic_guard 必须是对象。")
	var guard: Dictionary = value as Dictionary
	for raw_key: Variant in guard.keys():
		if not ["required_term_groups", "forbidden_terms"].has(String(raw_key)):
			return _error(source_path, worldbook_id, statement_id, "statements.semantic_guard", "unknown_semantic_guard_field", "semantic_guard 含未知字段。")
	if guard.has("required_term_groups"):
		if not guard["required_term_groups"] is Array:
			return _error(source_path, worldbook_id, statement_id, "statements.semantic_guard.required_term_groups", "invalid_semantic_guard", "required_term_groups 必须是数组。")
		for raw_group: Variant in guard["required_term_groups"] as Array:
			var group_result: Dictionary = _validate_text_array(raw_group, source_path, worldbook_id, statement_id, "statements.semantic_guard.required_term_groups", false)
			if not bool(group_result.get("ok", false)):
				return group_result
	if guard.has("forbidden_terms"):
		var forbidden_result: Dictionary = _validate_text_array(guard["forbidden_terms"], source_path, worldbook_id, statement_id, "statements.semantic_guard.forbidden_terms", true)
		if not bool(forbidden_result.get("ok", false)):
			return forbidden_result
	return {"ok": true}


func _validate_event_statement_references(events: Array[Dictionary], statement_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	for event: Dictionary in events:
		var event_id: String = String(event["id"])
		for raw_statement_id: Variant in event["available_statement_ids"] as Array:
			var statement_id: String = String(raw_statement_id)
			if not statement_by_id.has(statement_id):
				return _error(source_path, worldbook_id, event_id, "events.available_statement_ids", "unknown_statement_id", "来电引用不存在的 Statement：%s。" % statement_id)
			if String((statement_by_id[statement_id] as Dictionary)["source_id"]) != event_id:
				return _error(source_path, worldbook_id, event_id, "events.available_statement_ids", "statement_source_mismatch", "来电只能披露 source_id 等于自身 event id 的 Statement。")
	return {"ok": true}


func _validate_facts(raw_facts: Array, statement_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_facts.size() > MAX_FACTS:
		return _error(source_path, worldbook_id, "", "facts", "too_many_facts", "facts 超过 %d 条硬上限。" % MAX_FACTS)
	var by_id: Dictionary = {}
	for raw_fact: Variant in raw_facts:
		if not raw_fact is Dictionary:
			return _error(source_path, worldbook_id, "", "facts", "invalid_fact_type", "facts 中每项必须是对象。")
		var fact: Dictionary = raw_fact as Dictionary
		var fact_id: String = _id_or_empty(fact)
		var fields_result: Dictionary = _require_exact_fields(fact, PackedStringArray(["id", "initially_confirmed", "required_statement_ids"]), source_path, worldbook_id, fact_id, "facts", "Fact")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not fact["id"] is String or not _is_stable_id(String(fact["id"])):
			return _error(source_path, worldbook_id, fact_id, "facts.id", "invalid_fact_id", "Fact ID 必须是英文 snake_case。")
		fact_id = String(fact["id"])
		if by_id.has(fact_id):
			return _error(source_path, worldbook_id, fact_id, "facts.id", "duplicate_fact_id", "Fact ID 重复。")
		if typeof(fact["initially_confirmed"]) != TYPE_BOOL:
			return _error(source_path, worldbook_id, fact_id, "facts.initially_confirmed", "invalid_initially_confirmed", "initially_confirmed 必须是 bool。")
		var statements_result: Dictionary = _validate_stable_id_array(fact["required_statement_ids"], source_path, worldbook_id, fact_id, "facts.required_statement_ids")
		if not bool(statements_result.get("ok", false)):
			return statements_result
		for raw_statement_id: Variant in fact["required_statement_ids"] as Array:
			if not statement_by_id.has(String(raw_statement_id)):
				return _error(source_path, worldbook_id, fact_id, "facts.required_statement_ids", "unknown_statement_id", "Fact 引用了不存在的 Statement：%s。" % String(raw_statement_id))
		by_id[fact_id] = fact.duplicate(true)
	return {"ok": true, "by_id": by_id}


func _validate_information_references(collections: Array, statement_by_id: Dictionary, fact_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	for raw_collection: Variant in collections:
		for raw_item: Variant in raw_collection as Array:
			var item: Dictionary = raw_item as Dictionary
			var item_id: String = String(item["id"])
			for raw_statement_id: Variant in item["statement_ids"] as Array:
				var statement_id: String = String(raw_statement_id)
				if not statement_by_id.has(statement_id):
					return _error(source_path, worldbook_id, item_id, "statement_ids", "unknown_statement_id", "信息来源引用不存在的 Statement：%s。" % statement_id)
				if String((statement_by_id[statement_id] as Dictionary)["source_id"]) != item_id:
					return _error(source_path, worldbook_id, item_id, "statement_ids", "statement_source_mismatch", "信息来源只能引用 source_id 等于自身 id 的 Statement。")
			for raw_fact_id: Variant in item["fact_ids"] as Array:
				if not fact_by_id.has(String(raw_fact_id)):
					return _error(source_path, worldbook_id, item_id, "fact_ids", "unknown_fact_id", "信息来源引用不存在的 Fact：%s。" % String(raw_fact_id))
	return {"ok": true}


func _validate_tasks(raw_tasks: Array, event_by_id: Dictionary, statement_by_id: Dictionary, fact_by_id: Dictionary, condition_by_id: Dictionary, message_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_tasks.size() > MAX_TASKS:
		return _error(source_path, worldbook_id, "", "broadcast_tasks", "too_many_tasks", "broadcast_tasks 超过 %d 条硬上限。" % MAX_TASKS)
	var task_by_id: Dictionary = {}
	for raw_task: Variant in raw_tasks:
		if raw_task is Dictionary and raw_task.has("id") and raw_task["id"] is String:
			var task_id: String = String(raw_task["id"])
			if not _is_stable_id(task_id):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.id", "invalid_task_id", "Task ID 必须是英文 snake_case。")
			if task_by_id.has(task_id):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.id", "duplicate_task_id", "Task ID 重复。")
			task_by_id[task_id] = raw_task
	for raw_task: Variant in raw_tasks:
		if not raw_task is Dictionary:
			return _error(source_path, worldbook_id, "", "broadcast_tasks", "invalid_task_type", "broadcast_tasks 中每项必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = _id_or_empty(task)
		var fields: PackedStringArray = ["id", "name", "selection_mode", "channel", "source", "related_event_ids", "requirements", "sets_condition_id", "information_items"]
		var fields_result: Dictionary = _require_exact_fields(task, fields, source_path, worldbook_id, task_id, "broadcast_tasks", "Broadcast task")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		for legacy_field: String in ["related_dialogue_event_ids", "required_dialogue_event_ids"]:
			if task.has(legacy_field):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.%s" % legacy_field, "legacy_dialogue_requirement_forbidden", "WorldBook v1 Task 不得依赖预制 dialogue event 语义。")
		for text_field: String in ["name", "source"]:
			if not task[text_field] is String or String(task[text_field]).strip_edges().is_empty():
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.%s" % text_field, "invalid_task_text", "%s 必须是非空字符串。" % text_field)
		if not task["channel"] is String or String(task["channel"]) != "microphone":
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.channel", "invalid_task_channel", "WorldBook v1 广播 channel 必须为 microphone。")
		if not task["selection_mode"] is String or not ["single", "multiple"].has(String(task["selection_mode"])):
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.selection_mode", "invalid_selection_mode", "selection_mode 必须为 single 或 multiple。")
		var related_result: Dictionary = _validate_stable_id_array(task["related_event_ids"], source_path, worldbook_id, task_id, "broadcast_tasks.related_event_ids")
		if not bool(related_result.get("ok", false)):
			return related_result
		for raw_event_id: Variant in task["related_event_ids"] as Array:
			if not event_by_id.has(String(raw_event_id)):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.related_event_ids", "unknown_event_id", "Task 引用了不存在的 Event：%s。" % String(raw_event_id))
		if not task["requirements"] is Array:
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "invalid_requirements", "Task requirements 必须是数组。")
		var requirement_seen: Dictionary = {}
		for raw_requirement: Variant in task["requirements"] as Array:
			if not raw_requirement is Dictionary:
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "invalid_requirement", "requirement 必须是对象。")
			var requirement: Dictionary = raw_requirement as Dictionary
			if requirement.size() != 2 or not requirement.has("type") or not requirement.has("id") or not requirement["type"] is String or not requirement["id"] is String:
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "invalid_requirement_shape", "requirement 必须且只能包含字符串 type/id。")
			var requirement_type: String = String(requirement["type"])
			var requirement_id: String = String(requirement["id"])
			if not SUPPORTED_REQUIREMENT_TYPES.has(requirement_type) or not _is_stable_id(requirement_id):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "invalid_requirement", "requirement type/id 无效。")
			var requirement_key: String = "%s:%s" % [requirement_type, requirement_id]
			if requirement_seen.has(requirement_key):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "duplicate_requirement", "Task requirements 含重复引用：%s。" % requirement_key)
			requirement_seen[requirement_key] = true
			var target_map: Dictionary = {}
			match requirement_type:
				"statement_revealed": target_map = statement_by_id
				"fact_confirmed": target_map = fact_by_id
				"condition_true": target_map = condition_by_id
				"interaction_answered", "interaction_completed": target_map = event_by_id
				"broadcast_sent": target_map = task_by_id
				"message_read": target_map = message_by_id
			if not target_map.has(requirement_id) or (requirement_type == "broadcast_sent" and requirement_id == task_id):
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.requirements", "unknown_requirement_id", "Task requirement 引用了不存在或不允许的 ID：%s。" % requirement_id)
		if not task["sets_condition_id"] is String:
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.sets_condition_id", "invalid_sets_condition_id", "sets_condition_id 必须是字符串。")
		var sets_condition_id: String = String(task["sets_condition_id"])
		if not sets_condition_id.is_empty() and not condition_by_id.has(sets_condition_id):
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.sets_condition_id", "unknown_condition_id", "Task sets_condition_id 引用了不存在的 Condition。")
		if not task["information_items"] is Array:
			return _error(source_path, worldbook_id, task_id, "broadcast_tasks.information_items", "invalid_information_items", "information_items 必须是数组。")
		var info_seen: Dictionary = {}
		for raw_info: Variant in task["information_items"] as Array:
			if not raw_info is Dictionary:
				return _error(source_path, worldbook_id, task_id, "broadcast_tasks.information_items", "invalid_information_item", "information item 必须是对象。")
			var info: Dictionary = raw_info as Dictionary
			var info_id: String = _id_or_empty(info)
			var info_fields: PackedStringArray = ["id", "source_label", "body", "statement_ids", "fact_ids"]
			var info_fields_result: Dictionary = _require_exact_fields(info, info_fields, source_path, worldbook_id, info_id, "broadcast_tasks.information_items", "Information item")
			if not bool(info_fields_result.get("ok", false)):
				return info_fields_result
			if not info["id"] is String or not _is_stable_id(String(info["id"])):
				return _error(source_path, worldbook_id, info_id, "broadcast_tasks.information_items.id", "invalid_information_item_id", "Information item ID 无效。")
			info_id = String(info["id"])
			if info_seen.has(info_id):
				return _error(source_path, worldbook_id, info_id, "broadcast_tasks.information_items.id", "duplicate_information_item_id", "同一 Task 内 information item ID 重复。")
			info_seen[info_id] = true
			for text_field: String in ["source_label", "body"]:
				if not info[text_field] is String or String(info[text_field]).strip_edges().is_empty():
					return _error(source_path, worldbook_id, info_id, "broadcast_tasks.information_items.%s" % text_field, "invalid_information_item_text", "%s 必须是非空字符串。" % text_field)
			for ids_field: String in ["statement_ids", "fact_ids"]:
				var ids_result: Dictionary = _validate_stable_id_array(info[ids_field], source_path, worldbook_id, info_id, "broadcast_tasks.information_items.%s" % ids_field)
				if not bool(ids_result.get("ok", false)):
					return ids_result
			for raw_statement_id: Variant in info["statement_ids"] as Array:
				if not statement_by_id.has(String(raw_statement_id)):
					return _error(source_path, worldbook_id, info_id, "broadcast_tasks.information_items.statement_ids", "unknown_statement_id", "Information item 引用了不存在的 Statement。")
			for raw_fact_id: Variant in info["fact_ids"] as Array:
				if not fact_by_id.has(String(raw_fact_id)):
					return _error(source_path, worldbook_id, info_id, "broadcast_tasks.information_items.fact_ids", "unknown_fact_id", "Information item 引用了不存在的 Fact。")
	return {"ok": true, "by_id": task_by_id}


func _validate_relationships(raw_relationships: Array, actor_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_relationships.size() > MAX_RELATIONSHIPS:
		return _error(source_path, worldbook_id, "", "relationships", "too_many_relationships", "relationships 超过 %d 条硬上限。" % MAX_RELATIONSHIPS)
	var seen: Dictionary = {}
	for raw_relationship: Variant in raw_relationships:
		if not raw_relationship is Dictionary:
			return _error(source_path, worldbook_id, "", "relationships", "invalid_relationship_type", "relationships 中每项必须是对象。")
		var relationship: Dictionary = raw_relationship as Dictionary
		var relationship_id: String = _id_or_empty(relationship)
		var fields_result: Dictionary = _require_exact_fields(relationship, PackedStringArray(["id", "actor_id", "target_actor_id", "description"]), source_path, worldbook_id, relationship_id, "relationships", "Relationship")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not relationship["id"] is String or not _is_stable_id(String(relationship["id"])):
			return _error(source_path, worldbook_id, relationship_id, "relationships.id", "invalid_relationship_id", "Relationship ID 无效。")
		relationship_id = String(relationship["id"])
		if seen.has(relationship_id):
			return _error(source_path, worldbook_id, relationship_id, "relationships.id", "duplicate_relationship_id", "Relationship ID 重复。")
		seen[relationship_id] = true
		for actor_field: String in ["actor_id", "target_actor_id"]:
			if not relationship[actor_field] is String or not actor_by_id.has(String(relationship[actor_field])):
				return _error(source_path, worldbook_id, relationship_id, "relationships.%s" % actor_field, "unknown_actor_id", "Relationship 引用了不存在的 Actor。")
		if not relationship["description"] is String or String(relationship["description"]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, relationship_id, "relationships.description", "invalid_relationship_description", "Relationship description 必须是非空字符串。")
	return {"ok": true}


func _validate_hidden_truths(raw_truths: Array, source_path: String, worldbook_id: String) -> Dictionary:
	var seen: Dictionary = {}
	for raw_truth: Variant in raw_truths:
		if not raw_truth is Dictionary:
			return _error(source_path, worldbook_id, "", "hidden_truths", "invalid_hidden_truth_type", "hidden_truths 中每项必须是对象。")
		var truth: Dictionary = raw_truth as Dictionary
		var truth_id: String = _id_or_empty(truth)
		var fields_result: Dictionary = _require_exact_fields(truth, PackedStringArray(["id", "body"]), source_path, worldbook_id, truth_id, "hidden_truths", "Hidden truth")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not truth["id"] is String or not _is_stable_id(String(truth["id"])):
			return _error(source_path, worldbook_id, truth_id, "hidden_truths.id", "invalid_hidden_truth_id", "Hidden truth ID 无效。")
		truth_id = String(truth["id"])
		if seen.has(truth_id):
			return _error(source_path, worldbook_id, truth_id, "hidden_truths.id", "duplicate_hidden_truth_id", "Hidden truth ID 重复。")
		seen[truth_id] = true
		if not truth["body"] is String or String(truth["body"]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, truth_id, "hidden_truths.body", "invalid_hidden_truth_body", "Hidden truth body 必须是非空字符串。")
	return {"ok": true}


func _validate_opportunities(raw_opportunities: Array, actor_by_id: Dictionary, event_by_id: Dictionary, condition_by_id: Dictionary, goal_by_id: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	if raw_opportunities.size() > MAX_OPPORTUNITIES:
		return _error(source_path, worldbook_id, "", "opportunities", "too_many_opportunities", "opportunities 超过 %d 条硬上限。" % MAX_OPPORTUNITIES)
	var seen: Dictionary = {}
	for raw_opportunity: Variant in raw_opportunities:
		if not raw_opportunity is Dictionary:
			return _error(source_path, worldbook_id, "", "opportunities", "invalid_opportunity_type", "opportunities 中每项必须是对象。")
		var opportunity: Dictionary = raw_opportunity as Dictionary
		var opportunity_id: String = _id_or_empty(opportunity)
		var fields: PackedStringArray = ["id", "summary", "actor_ids", "event_ids", "condition_ids", "goal_ids"]
		var fields_result: Dictionary = _require_exact_fields(opportunity, fields, source_path, worldbook_id, opportunity_id, "opportunities", "Opportunity")
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not opportunity["id"] is String or not _is_stable_id(String(opportunity["id"])):
			return _error(source_path, worldbook_id, opportunity_id, "opportunities.id", "invalid_opportunity_id", "Opportunity ID 无效。")
		opportunity_id = String(opportunity["id"])
		if seen.has(opportunity_id):
			return _error(source_path, worldbook_id, opportunity_id, "opportunities.id", "duplicate_opportunity_id", "Opportunity ID 重复。")
		seen[opportunity_id] = true
		if not opportunity["summary"] is String or String(opportunity["summary"]).strip_edges().is_empty():
			return _error(source_path, worldbook_id, opportunity_id, "opportunities.summary", "invalid_opportunity_summary", "Opportunity summary 必须是非空字符串。")
		for ref_spec: Dictionary in [
			{"field": "actor_ids", "map": actor_by_id},
			{"field": "event_ids", "map": event_by_id},
			{"field": "condition_ids", "map": condition_by_id},
			{"field": "goal_ids", "map": goal_by_id},
		]:
			var field_name: String = String(ref_spec["field"])
			var ids_result: Dictionary = _validate_stable_id_array(opportunity[field_name], source_path, worldbook_id, opportunity_id, "opportunities.%s" % field_name)
			if not bool(ids_result.get("ok", false)):
				return ids_result
			var target_map: Dictionary = ref_spec["map"] as Dictionary
			for raw_id: Variant in opportunity[field_name] as Array:
				if not target_map.has(String(raw_id)):
					return _error(source_path, worldbook_id, opportunity_id, "opportunities.%s" % field_name, "unknown_opportunity_reference", "Opportunity 引用了不存在的 ID：%s。" % String(raw_id))
	return {"ok": true}


func _validate_global_id_uniqueness(root: Dictionary, source_path: String, worldbook_id: String) -> Dictionary:
	var registry: Dictionary = {}
	for collection_name: String in GLOBAL_ID_COLLECTION_FIELDS:
		for raw_item: Variant in root[collection_name] as Array:
			if not raw_item is Dictionary:
				continue
			var item: Dictionary = raw_item as Dictionary
			if not item.get("id") is String:
				continue
			var stable_id: String = String(item["id"])
			if not _is_stable_id(stable_id):
				continue
			var collection_register_result: Dictionary = _register_global_id(registry, stable_id, collection_name, "", "%s.id" % collection_name, source_path, worldbook_id)
			if not bool(collection_register_result.get("ok", false)):
				return collection_register_result

	for task_index: int in range((root["broadcast_tasks"] as Array).size()):
		var raw_task: Variant = (root["broadcast_tasks"] as Array)[task_index]
		if not raw_task is Dictionary:
			continue
		var task: Dictionary = raw_task as Dictionary
		if not task.get("information_items") is Array:
			continue
		var task_scope: String = _id_or_empty(task)
		if task_scope.is_empty():
			task_scope = "#%d" % task_index
		for raw_info: Variant in task["information_items"] as Array:
			if not raw_info is Dictionary:
				continue
			var info: Dictionary = raw_info as Dictionary
			if not info.get("id") is String:
				continue
			var info_id: String = String(info["id"])
			if not _is_stable_id(info_id):
				continue
			var information_register_result: Dictionary = _register_global_id(
				registry,
				info_id,
				"broadcast_tasks.information_items",
				task_scope,
				"broadcast_tasks.information_items.id",
				source_path,
				worldbook_id
			)
			if not bool(information_register_result.get("ok", false)):
				return information_register_result
	return {"ok": true}


func _register_global_id(registry: Dictionary, stable_id: String, domain: String, scope: String, field_name: String, source_path: String, worldbook_id: String) -> Dictionary:
	if not registry.has(stable_id):
		registry[stable_id] = {"domain": domain, "scope": scope, "field": field_name}
		return {"ok": true}
	var previous: Dictionary = registry[stable_id] as Dictionary
	var previous_domain: String = String(previous["domain"])
	var previous_scope: String = String(previous["scope"])
	# 同一普通 collection 内的重复继续交给原有、更具体的 duplicate_* 错误；
	# information item 则只有跨 Task 复用才属于全局引用空间冲突。
	if previous_domain == domain and (domain != "broadcast_tasks.information_items" or previous_scope == scope):
		return {"ok": true}
	return _error(
		source_path,
		worldbook_id,
		stable_id,
		field_name,
		"duplicate_global_id",
		"稳定 ID 在全局运行时引用域中冲突：%s 已用于 %s，不能再次用于 %s。" % [stable_id, previous_domain, domain]
	)


func _validate_id_collection(raw_items: Array, collection_name: String, max_count: int, source_path: String, worldbook_id: String, exact_fields: PackedStringArray) -> Dictionary:
	if raw_items.size() > max_count:
		return _error(source_path, worldbook_id, "", collection_name, "collection_too_large", "%s 超过 %d 条硬上限。" % [collection_name, max_count])
	var by_id: Dictionary = {}
	for raw_item: Variant in raw_items:
		if not raw_item is Dictionary:
			return _error(source_path, worldbook_id, "", collection_name, "invalid_collection_item", "%s 中每项必须是对象。" % collection_name)
		var item: Dictionary = raw_item as Dictionary
		var item_id: String = _id_or_empty(item)
		var fields_result: Dictionary = _require_exact_fields(item, exact_fields, source_path, worldbook_id, item_id, collection_name, collection_name)
		if not bool(fields_result.get("ok", false)):
			return fields_result
		if not item["id"] is String or not _is_stable_id(String(item["id"])):
			return _error(source_path, worldbook_id, item_id, "%s.id" % collection_name, "invalid_id", "%s ID 必须是英文 snake_case。" % collection_name)
		item_id = String(item["id"])
		if by_id.has(item_id):
			return _error(source_path, worldbook_id, item_id, "%s.id" % collection_name, "duplicate_id", "%s ID 重复。" % collection_name)
		by_id[item_id] = item.duplicate(true)
	return {"ok": true, "by_id": by_id}


func _validate_value_limits(value: Variant, source_path: String, worldbook_id: String, field_path: String, depth: int) -> Dictionary:
	if depth > MAX_NESTING_DEPTH:
		return _error(source_path, worldbook_id, "", field_path, "nesting_too_deep", "WorldBook 嵌套深度超过 %d。" % MAX_NESTING_DEPTH)
	match typeof(value):
		TYPE_STRING:
			if (value as String).length() > MAX_STRING_LENGTH:
				return _error(source_path, worldbook_id, "", field_path, "string_too_long", "字符串超过 %d 字符硬上限。" % MAX_STRING_LENGTH)
		TYPE_ARRAY:
			var array_value: Array = value as Array
			if array_value.size() > MAX_ARRAY_LENGTH:
				return _error(source_path, worldbook_id, "", field_path, "array_too_large", "数组超过 %d 项硬上限。" % MAX_ARRAY_LENGTH)
			for index: int in range(array_value.size()):
				var child_result: Dictionary = _validate_value_limits(array_value[index], source_path, worldbook_id, "%s[%d]" % [field_path, index], depth + 1)
				if not bool(child_result.get("ok", false)):
					return child_result
		TYPE_DICTIONARY:
			var dictionary_value: Dictionary = value as Dictionary
			if dictionary_value.size() > MAX_ARRAY_LENGTH:
				return _error(source_path, worldbook_id, "", field_path, "object_too_large", "对象字段数超过 %d 项硬上限。" % MAX_ARRAY_LENGTH)
			for raw_key: Variant in dictionary_value.keys():
				if not raw_key is String:
					return _error(source_path, worldbook_id, "", field_path, "invalid_object_key", "JSON 对象键必须是字符串。")
				var child_result: Dictionary = _validate_value_limits(dictionary_value[raw_key], source_path, worldbook_id, "%s.%s" % [field_path, String(raw_key)], depth + 1)
				if not bool(child_result.get("ok", false)):
					return child_result
	return {"ok": true}


func _validate_stable_id_array(value: Variant, source_path: String, worldbook_id: String, object_id: String, field_name: String) -> Dictionary:
	if not value is Array:
		return _error(source_path, worldbook_id, object_id, field_name, "invalid_id_array", "%s 必须是数组。" % field_name)
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not _is_stable_id(String(raw_id)):
			return _error(source_path, worldbook_id, object_id, field_name, "invalid_stable_id", "%s 中每项必须是英文 snake_case ID。" % field_name)
		var stable_id: String = String(raw_id)
		if seen.has(stable_id):
			return _error(source_path, worldbook_id, object_id, field_name, "duplicate_reference", "%s 含重复 ID：%s。" % [field_name, stable_id])
		seen[stable_id] = true
	return {"ok": true}


func _validate_text_array(value: Variant, source_path: String, worldbook_id: String, object_id: String, field_name: String, allow_empty: bool) -> Dictionary:
	if not value is Array:
		return _error(source_path, worldbook_id, object_id, field_name, "invalid_text_array", "%s 必须是数组。" % field_name)
	if not allow_empty and (value as Array).is_empty():
		return _error(source_path, worldbook_id, object_id, field_name, "empty_text_array", "%s 不能为空。" % field_name)
	for raw_text: Variant in value as Array:
		if not raw_text is String or String(raw_text).strip_edges().is_empty():
			return _error(source_path, worldbook_id, object_id, field_name, "invalid_text_array", "%s 只能包含非空字符串。" % field_name)
	return {"ok": true}


func _require_exact_fields(value: Dictionary, fields: PackedStringArray, source_path: String, worldbook_id: String, object_id: String, field_path: String, label: String) -> Dictionary:
	return _require_fields_and_allow_only(value, fields, fields, source_path, worldbook_id, object_id, field_path, label)


func _require_fields_and_allow_only(value: Dictionary, required_fields: PackedStringArray, allowed_fields: PackedStringArray, source_path: String, worldbook_id: String, object_id: String, field_path: String, label: String) -> Dictionary:
	for field_name: String in required_fields:
		if not value.has(field_name):
			return _error(source_path, worldbook_id, object_id, "%s.%s" % [field_path, field_name], "missing_field", "%s 缺少字段：%s。" % [label, field_name])
	for raw_key: Variant in value.keys():
		var key: String = String(raw_key)
		if not allowed_fields.has(key):
			return _error(source_path, worldbook_id, object_id, "%s.%s" % [field_path, key], "unknown_field", "%s 含未知字段：%s。" % [label, key])
	return {"ok": true}


func _load_json_with_limit(source_path: String, max_bytes: int, label: String) -> Dictionary:
	if not FileAccess.file_exists(source_path):
		return _error(source_path, "", "", "$", "file_not_found", "找不到 %s JSON 文件。" % label)
	var file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		return _error(source_path, "", "", "$", "file_open_failed", "无法打开 %s JSON 文件，错误码=%d。" % [label, int(FileAccess.get_open_error())])
	var byte_size: int = file.get_length()
	if byte_size > max_bytes:
		file.close()
		return _error(source_path, "", "", "$", "%s_too_large" % label, "%s 文件超过 %d 字节硬上限。" % [label, max_bytes])
	var source_text: String = file.get_as_text()
	file.close()
	var parser: JSON = JSON.new()
	var parse_error: Error = parser.parse(source_text)
	if parse_error != OK:
		return _error(source_path, "", "", "$", "json_syntax_error", "%s JSON 解析失败（第 %d 行）：%s。" % [label, parser.get_error_line(), parser.get_error_message()])
	return {"ok": true, "data": parser.data, "byte_size": byte_size}


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
	if candidate.is_empty() or candidate.length() > MAX_ID_LENGTH:
		return false
	var first_code: int = candidate.unicode_at(0)
	if first_code < 97 or first_code > 122:
		return false
	for index: int in range(candidate.length()):
		var code: int = candidate.unicode_at(index)
		var is_lower_ascii: bool = code >= 97 and code <= 122
		var is_digit: bool = code >= 48 and code <= 57
		if not is_lower_ascii and not is_digit and code != 95:
			return false
	return true


func _id_or_empty(value: Dictionary) -> String:
	if value.has("id") and value["id"] is String:
		return String(value["id"])
	return ""


func _error(source_path: String, worldbook_id: String, object_id: String, field_name: String, error_code: String, message: String) -> Dictionary:
	return {
		"ok": false,
		"source_path": source_path,
		"worldbook_id": worldbook_id,
		"object_id": object_id,
		"field": field_name,
		"error_code": error_code,
		"message": message,
	}
