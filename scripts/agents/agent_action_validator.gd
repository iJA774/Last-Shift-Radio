class_name AgentActionValidator
extends RefCounted


func validate_proposal(proposal: Dictionary, available_actions: Array, external_validator: Callable = Callable()) -> Dictionary:
	if not proposal.has("action_id") or not proposal["action_id"] is String:
		return _error("action_id_missing", "Actor 输出缺少字符串 action_id。")
	if not proposal.has("arguments") or not proposal["arguments"] is Dictionary:
		return _error("action_arguments_missing", "Actor 输出缺少对象 arguments。")
	if not proposal.has("utterance") or not proposal["utterance"] is String:
		return _error("action_utterance_missing", "Actor 输出缺少字符串 utterance。")
	var action_id: String = String(proposal["action_id"])
	var action_definition: Dictionary = _find_action(action_id, available_actions)
	if action_definition.is_empty():
		return _proposal_error("action_not_available", "Actor 提议了当前不可用动作：%s。" % action_id, proposal)
	var arguments: Dictionary = proposal["arguments"] as Dictionary
	var allowed_argument_keys: Array = action_definition.get("argument_keys", []) as Array
	for raw_key: Variant in arguments.keys():
		var key: String = String(raw_key)
		if not allowed_argument_keys.has(key):
			return _proposal_error("action_argument_not_allowed", "动作 %s 不允许参数：%s。" % [action_id, key], proposal)
	if external_validator.is_valid():
		var external_result: Variant = external_validator.call(proposal.duplicate(true), action_definition.duplicate(true))
		if not external_result is Dictionary:
			return _proposal_error("external_validator_invalid", "世界动作校验器必须返回 Dictionary。", proposal)
		var validation: Dictionary = external_result as Dictionary
		if not bool(validation.get("ok", false)):
			if not validation.has("error_code"):
				validation["error_code"] = "world_action_rejected"
			if not validation.has("message"):
				validation["message"] = "世界规则拒绝了 Actor 动作。"
			validation["proposal"] = proposal.duplicate(true)
			return validation
	return {
		"ok": true,
		"proposal": proposal.duplicate(true),
		"action": action_definition.duplicate(true),
	}


func build_deterministic_fallbacks(available_actions: Array) -> Dictionary:
	if available_actions.is_empty():
		return _error("no_available_actions", "当前没有任何可执行动作，无法进行 deterministic fallback。")
	var candidates: Array[Dictionary] = []
	for raw_action: Variant in available_actions:
		if not raw_action is Dictionary:
			return _error("action_definition_invalid", "available_actions 中存在非对象条目。")
		var action: Dictionary = raw_action as Dictionary
		var validation: Dictionary = validate_action_definition(action)
		if not bool(validation.get("ok", false)):
			return validation
		var candidate: Dictionary = {
			"proposal": {
				"action_id": String(action["id"]),
				"arguments": (action.get("fallback_arguments", {}) as Dictionary).duplicate(true),
				"utterance": "",
				"reasoning_summary": "deterministic_fallback",
			},
			"action": action.duplicate(true),
		}
		var insert_index: int = candidates.size()
		for index: int in range(candidates.size()):
			var existing: Dictionary = candidates[index]
			var existing_action: Dictionary = existing["action"] as Dictionary
			var priority: int = int(action["fallback_priority"])
			var existing_priority: int = int(existing_action["fallback_priority"])
			if priority < existing_priority or (priority == existing_priority and String(action["id"]) < String(existing_action["id"])):
				insert_index = index
				break
		candidates.insert(insert_index, candidate)
	return {"ok": true, "candidates": candidates}


func choose_deterministic_fallback(available_actions: Array) -> Dictionary:
	var candidates_result: Dictionary = build_deterministic_fallbacks(available_actions)
	if not bool(candidates_result.get("ok", false)):
		return candidates_result
	var candidates: Array[Dictionary] = candidates_result["candidates"] as Array[Dictionary]
	if candidates.is_empty():
		return _error("no_available_actions", "当前没有任何 deterministic fallback 候选。")
	var first: Dictionary = candidates[0]
	return {
		"ok": true,
		"proposal": (first["proposal"] as Dictionary).duplicate(true),
		"action": (first["action"] as Dictionary).duplicate(true),
	}


## 按 fallback_priority 顺序逐个经过与模型 proposal 完全相同的世界校验。
## 只有所有作者声明的 deterministic fallback 都被拒绝时，才允许报告活性耗尽。
func choose_valid_deterministic_fallback(
	available_actions: Array,
	external_validator: Callable = Callable()
) -> Dictionary:
	var candidates_result: Dictionary = build_deterministic_fallbacks(available_actions)
	if not bool(candidates_result.get("ok", false)):
		return candidates_result
	var candidates: Array[Dictionary] = candidates_result["candidates"] as Array[Dictionary]
	var rejected_candidates: Array[Dictionary] = []
	for candidate: Dictionary in candidates:
		var proposal: Dictionary = candidate["proposal"] as Dictionary
		var validation: Dictionary = validate_proposal(proposal, available_actions, external_validator)
		if bool(validation.get("ok", false)):
			return {
				"ok": true,
				"proposal": (validation["proposal"] as Dictionary).duplicate(true),
				"action": (validation["action"] as Dictionary).duplicate(true),
				"attempted_candidate_count": rejected_candidates.size() + 1,
				"rejected_candidates": rejected_candidates.duplicate(true),
			}
		rejected_candidates.append({
			"action_id": String(proposal.get("action_id", "")),
			"error_code": String(validation.get("error_code", "world_action_rejected")),
			"message": String(validation.get("message", "世界规则拒绝了 deterministic fallback。")),
		})
	return {
		"ok": false,
		"error_code": "agent_liveness_exhausted",
		"message": "全部 deterministic fallback 均被世界规则拒绝。",
		"attempted_candidate_count": candidates.size(),
		"rejected_candidates": rejected_candidates,
	}


func validate_available_actions(available_actions: Array) -> Dictionary:
	if available_actions.is_empty():
		return _error("no_available_actions", "Actor 决策至少需要一个 available_action。")
	var seen_ids: Dictionary = {}
	for raw_action: Variant in available_actions:
		if not raw_action is Dictionary:
			return _error("action_definition_invalid", "available_actions 中存在非对象条目。")
		var action: Dictionary = raw_action as Dictionary
		var validation: Dictionary = validate_action_definition(action)
		if not bool(validation.get("ok", false)):
			return validation
		var action_id: String = String(action["id"])
		if seen_ids.has(action_id):
			return _error("action_id_duplicate", "available_actions 存在重复动作 ID：%s。" % action_id)
		seen_ids[action_id] = true
	return {"ok": true}


func validate_action_definition(action: Dictionary) -> Dictionary:
	for required_key: String in ["id", "description", "argument_keys", "fallback_priority"]:
		if not action.has(required_key):
			return _error("action_definition_invalid", "动作定义缺少字段：%s。" % required_key)
	if not action["id"] is String or String(action["id"]).strip_edges().is_empty():
		return _error("action_definition_invalid", "动作 id 必须是非空字符串。")
	if not action["description"] is String:
		return _error("action_definition_invalid", "动作 %s.description 必须是字符串。" % String(action["id"]))
	if not action["argument_keys"] is Array:
		return _error("action_definition_invalid", "动作 %s.argument_keys 必须是数组。" % String(action["id"]))
	for raw_key: Variant in action["argument_keys"] as Array:
		if not raw_key is String:
			return _error("action_definition_invalid", "动作 %s.argument_keys 只能包含字符串。" % String(action["id"]))
	if action.has("fallback_arguments"):
		if not action["fallback_arguments"] is Dictionary:
			return _error("action_definition_invalid", "动作 %s.fallback_arguments 必须是对象。" % String(action["id"]))
		for raw_key: Variant in (action["fallback_arguments"] as Dictionary).keys():
			if not (action["argument_keys"] as Array).has(String(raw_key)):
				return _error("action_definition_invalid", "动作 %s.fallback_arguments 包含未声明参数：%s。" % [String(action["id"]), String(raw_key)])
	if not action["fallback_priority"] is int:
		return _error("action_definition_invalid", "动作 %s.fallback_priority 必须是整数。" % String(action["id"]))
	return {"ok": true}


func _find_action(action_id: String, available_actions: Array) -> Dictionary:
	for raw_action: Variant in available_actions:
		if raw_action is Dictionary and String((raw_action as Dictionary).get("id", "")) == action_id:
			return (raw_action as Dictionary).duplicate(true)
	return {}


func _proposal_error(error_code: String, message: String, proposal: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"error_code": error_code,
		"message": message,
		"proposal": proposal.duplicate(true),
	}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
