class_name DirectorContextBuilder
extends RefCounted

## Director 的唯一正式世界上下文装配层。
##
## 它只读取确定性系统公开快照，并把 WorldBook 的导演侧数据与 Actor summaries
## 分层组织。DirectorAgent 不需要、也不应该自行遍历 StoryEngine/PhoneSystem 节点。

const KERNEL_RULES: Dictionary = {
	"game_identity": "Last Shift Radio / 末班电台夜班值守",
	"world_authority": "StoryEngine 与确定性系统拥有世界提交权；模型只能提出 proposal。",
	"time_authority": "GameClock 拥有时间权威；02:00 由 WorldKernel 强制结束。",
	"phone_authority": "PhoneSystem 拥有线路、排队、占线与真正挂断权威。",
	"broadcast_authority": "BroadcastSystem/StoryEngine 决定广播是否真正发送。",
	"information_authority": "Truth、Statement 与 Fact 是不同层；Fact/Statement 只能由确定性系统确认或 reveal。",
	"director_permissions": "Director 只能选择已提供 candidate opportunity id，并只能建议 Actor 的 available_goal_ids。",
	"actor_permissions": "Actor 只能基于自己的局部知识、可披露 claims 与受限 guidance 产生对话/动作 proposal。",
}


func build_context(
	plan_context_id: String,
	worldbook_director_lore: Dictionary,
	story_engine: Object,
	game_clock: Object,
	phone_system: Object,
	actor_summaries: Array[Dictionary],
	candidate_opportunities: Array,
	narrative_constraints: Dictionary = {}
) -> Dictionary:
	if plan_context_id.strip_edges().is_empty():
		return {"ok": false, "error_code": "invalid_plan_context_id", "message": "plan_context_id 不能为空。"}
	var worldbook_lore: Dictionary = _build_worldbook_lore(worldbook_director_lore)
	var runtime_world_summary: Dictionary = _build_runtime_world_summary(story_engine, game_clock, phone_system)
	var normalized_candidates: Array[Dictionary] = []
	for raw_candidate: Variant in candidate_opportunities:
		if raw_candidate is Dictionary:
			normalized_candidates.append((raw_candidate as Dictionary).duplicate(true))
	var constraints: Dictionary = _merge_constraints(worldbook_director_lore, narrative_constraints)
	return {
		"ok": true,
		"context": {
			"plan_context_id": plan_context_id,
			"kernel_rules": KERNEL_RULES.duplicate(true),
			"worldbook_lore": worldbook_lore,
			"runtime_world_summary": runtime_world_summary,
			"actor_summaries": actor_summaries.duplicate(true),
			"candidate_opportunities": normalized_candidates,
			"narrative_constraints": constraints,
		},
	}


func _build_worldbook_lore(worldbook_director_lore: Dictionary) -> Dictionary:
	if worldbook_director_lore.is_empty():
		return {
			"worldbook_id": "",
			"lore": {},
			"hidden_truths": [],
			"relationships": [],
			"goals": [],
		}
	return {
		"worldbook_id": String(worldbook_director_lore.get("worldbook_id", "")),
		"lore": _dictionary_or_empty(worldbook_director_lore.get("lore")),
		"hidden_truths": _array_or_empty(worldbook_director_lore.get("hidden_truths")),
		"relationships": _array_or_empty(worldbook_director_lore.get("relationships")),
		"goals": _array_or_empty(worldbook_director_lore.get("goals")),
	}


func _build_runtime_world_summary(story_engine: Object, game_clock: Object, phone_system: Object) -> Dictionary:
	var current_time: String = "unknown"
	var game_tick: int = -1
	if game_clock != null:
		if game_clock.has_method("get_display_time"):
			current_time = String(game_clock.call("get_display_time"))
		if game_clock.has_method("get_current_game_tick"):
			game_tick = int(game_clock.call("get_current_game_tick"))
	elif story_engine != null and story_engine.has_method("get_current_game_tick"):
		game_tick = int(story_engine.call("get_current_game_tick"))

	var confirmed_facts: Array = []
	var revealed_statements: Array = []
	var broadcast_history: Array = []
	var message_state: Array = []
	var task_state: Array = []
	if story_engine != null:
		confirmed_facts = _call_array(story_engine, "get_confirmed_facts")
		revealed_statements = _call_array(story_engine, "get_revealed_statements")
		broadcast_history = _call_array(story_engine, "get_player_broadcast_records")
		message_state = _call_array(story_engine, "get_unlocked_messages")
		task_state = _call_array(story_engine, "get_broadcast_tasks")

	var call_history: Array = []
	var phone_state: Dictionary = {
		"state": "unavailable",
		"busy": false,
		"active_event_id": "",
	}
	if phone_system != null:
		call_history = _call_array(phone_system, "get_call_records")
		if phone_system.has_method("get_state_name"):
			phone_state["state"] = String(phone_system.call("get_state_name"))
		if phone_system.has_method("is_busy"):
			phone_state["busy"] = bool(phone_system.call("is_busy"))
		if phone_system.has_method("get_active_event_id"):
			phone_state["active_event_id"] = String(phone_system.call("get_active_event_id"))

	var signal_state: Dictionary = {"available": false, "records": []}
	if story_engine != null and story_engine.has_method("get_signal_state"):
		var signal_state_value: Variant = story_engine.call("get_signal_state")
		if signal_state_value is Dictionary:
			signal_state = (signal_state_value as Dictionary).duplicate(true)
	var delivery_state: Dictionary = {"available": false, "requests": []}
	if story_engine != null and story_engine.has_method("get_delivery_state"):
		var delivery_state_value: Variant = story_engine.call("get_delivery_state")
		if delivery_state_value is Dictionary:
			delivery_state = (delivery_state_value as Dictionary).duplicate(true)

	return {
		"current_time": current_time,
		"game_tick": game_tick,
		"confirmed_facts": confirmed_facts,
		"revealed_statements": revealed_statements,
		"call_history": call_history,
		"phone_state": phone_state,
		"broadcast_history": broadcast_history,
		"message_state": message_state,
		"task_state": task_state,
		# Signal / Delivery 都只透传各自正式公开只读状态，不为 prompt 虚构运行时事实。
		"signal_state": signal_state,
		"delivery_state": delivery_state,
	}


func _merge_constraints(worldbook_director_lore: Dictionary, runtime_constraints: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	var author_constraints: Dictionary = _dictionary_or_empty(worldbook_director_lore.get("narrative_constraints"))
	if not author_constraints.is_empty():
		result["worldbook"] = author_constraints
	if not runtime_constraints.is_empty():
		result["runtime"] = runtime_constraints.duplicate(true)
	return result


func _call_array(target: Object, method_name: String) -> Array:
	if target == null or not target.has_method(method_name):
		return []
	var value: Variant = target.call(method_name)
	if value is Array:
		return (value as Array).duplicate(true)
	return []


func _dictionary_or_empty(value: Variant) -> Dictionary:
	if value is Dictionary:
		return (value as Dictionary).duplicate(true)
	return {}


func _array_or_empty(value: Variant) -> Array:
	if value is Array:
		return (value as Array).duplicate(true)
	return []
