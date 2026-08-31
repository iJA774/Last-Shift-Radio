class_name TurnSemanticGuard
extends RefCounted

## ActorTurn 的确定性语义边界。
##
## 结构校验由 ActorAgent 负责；本类只检查“台词是否与已声明 claim 的作者语义规则冲突”。
## claim 的 meaning 会发送给模型作为权威含义，但运行时不会用自然语言相似度猜测事实。
## 对关键 claim，作者可显式声明 required_term_groups / forbidden_terms；更复杂的检查由
## world-specific external_validator 提供，且仍然只读、不得提交世界状态。


func validate_claim_catalog(disclosable_claims: Array) -> Dictionary:
	var seen_ids: Dictionary = {}
	for raw_claim: Variant in disclosable_claims:
		if not raw_claim is Dictionary:
			return _error("turn_claim_catalog_invalid", "disclosable_claims 只能包含对象。")
		var claim: Dictionary = raw_claim as Dictionary
		for required_key: String in ["id", "meaning"]:
			if not claim.has(required_key):
				return _error("turn_claim_catalog_invalid", "disclosable_claims 条目缺少字段：%s。" % required_key)
		if not claim["id"] is String or String(claim["id"]).strip_edges().is_empty():
			return _error("turn_claim_catalog_invalid", "claim.id 必须是非空字符串。")
		if not claim["meaning"] is String or String(claim["meaning"]).strip_edges().is_empty():
			return _error("turn_claim_catalog_invalid", "claim %s.meaning 必须是非空字符串。" % String(claim["id"]))
		var claim_id: String = String(claim["id"])
		if seen_ids.has(claim_id):
			return _error("turn_claim_catalog_duplicate", "disclosable_claims 存在重复 claim id：%s。" % claim_id)
		seen_ids[claim_id] = true
		if claim.has("semantic_guard"):
			if not claim["semantic_guard"] is Dictionary:
				return _error("turn_semantic_rule_invalid", "claim %s.semantic_guard 必须是对象。" % claim_id)
			var rule_result: Dictionary = _validate_semantic_rule(claim_id, claim["semantic_guard"] as Dictionary)
			if not bool(rule_result.get("ok", false)):
				return rule_result
	return {"ok": true}


func collect_claim_ids(disclosable_claims: Array) -> Dictionary:
	var validation: Dictionary = validate_claim_catalog(disclosable_claims)
	if not bool(validation.get("ok", false)):
		return validation
	var claim_ids: Array[String] = []
	for raw_claim: Variant in disclosable_claims:
		claim_ids.append(String((raw_claim as Dictionary)["id"]))
	return {"ok": true, "claim_ids": claim_ids}


func validate_turn_semantics(
	turn: Dictionary,
	disclosable_claims: Array,
	external_validator: Callable = Callable()
) -> Dictionary:
	var catalog_result: Dictionary = validate_claim_catalog(disclosable_claims)
	if not bool(catalog_result.get("ok", false)):
		return catalog_result
	if not turn.has("utterance") or not turn["utterance"] is String:
		return _turn_error("turn_semantic_input_invalid", "ActorTurn 缺少字符串 utterance。", turn)
	if not turn.has("asserted_claim_ids") or not turn["asserted_claim_ids"] is Array:
		return _turn_error("turn_semantic_input_invalid", "ActorTurn 缺少 asserted_claim_ids 数组。", turn)

	var claims_by_id: Dictionary = {}
	for raw_claim: Variant in disclosable_claims:
		var claim: Dictionary = raw_claim as Dictionary
		claims_by_id[String(claim["id"])] = claim

	var utterance: String = String(turn["utterance"])
	var matched_claims: Array[Dictionary] = []
	for raw_claim_id: Variant in turn["asserted_claim_ids"] as Array:
		if not raw_claim_id is String:
			return _turn_error("turn_semantic_input_invalid", "ActorTurn asserted_claim_ids 只能包含字符串。", turn)
		var claim_id: String = String(raw_claim_id)
		if not claims_by_id.has(claim_id):
			return _turn_error("turn_semantic_claim_not_available", "ActorTurn 引用了未提供语义定义的 claim：%s。" % claim_id, turn)
		var claim: Dictionary = claims_by_id[claim_id] as Dictionary
		matched_claims.append(claim.duplicate(true))
		var semantic_rule: Dictionary = claim.get("semantic_guard", {}) as Dictionary
		var semantic_result: Dictionary = _validate_claim_utterance(claim_id, utterance, semantic_rule, turn)
		if not bool(semantic_result.get("ok", false)):
			return semantic_result

	if external_validator.is_valid():
		var external_result: Variant = external_validator.call(turn.duplicate(true), matched_claims.duplicate(true))
		if not external_result is Dictionary:
			return _turn_error("turn_semantic_external_validator_invalid", "Turn 语义校验器必须返回 Dictionary。", turn)
		var validation: Dictionary = external_result as Dictionary
		if not bool(validation.get("ok", false)):
			if not validation.has("error_code"):
				validation["error_code"] = "turn_semantic_world_rejected"
			if not validation.has("message"):
				validation["message"] = "世界语义规则拒绝了 ActorTurn。"
			validation["turn"] = turn.duplicate(true)
			return validation
	return {
		"ok": true,
		"turn": turn.duplicate(true),
		"matched_claims": matched_claims,
	}


func _validate_semantic_rule(claim_id: String, rule: Dictionary) -> Dictionary:
	for raw_key: Variant in rule.keys():
		var key: String = String(raw_key)
		if not ["required_term_groups", "forbidden_terms"].has(key):
			return _error("turn_semantic_rule_invalid", "claim %s.semantic_guard 含未知字段：%s。" % [claim_id, key])
	if rule.has("required_term_groups"):
		if not rule["required_term_groups"] is Array:
			return _error("turn_semantic_rule_invalid", "claim %s.required_term_groups 必须是数组。" % claim_id)
		for raw_group: Variant in rule["required_term_groups"] as Array:
			if not raw_group is Array or (raw_group as Array).is_empty():
				return _error("turn_semantic_rule_invalid", "claim %s.required_term_groups 每组都必须是非空字符串数组。" % claim_id)
			for raw_term: Variant in raw_group as Array:
				if not raw_term is String or String(raw_term).strip_edges().is_empty():
					return _error("turn_semantic_rule_invalid", "claim %s.required_term_groups 含无效词项。" % claim_id)
	if rule.has("forbidden_terms"):
		if not rule["forbidden_terms"] is Array:
			return _error("turn_semantic_rule_invalid", "claim %s.forbidden_terms 必须是数组。" % claim_id)
		for raw_term: Variant in rule["forbidden_terms"] as Array:
			if not raw_term is String or String(raw_term).strip_edges().is_empty():
				return _error("turn_semantic_rule_invalid", "claim %s.forbidden_terms 含无效词项。" % claim_id)
	return {"ok": true}


func _validate_claim_utterance(
	claim_id: String,
	utterance: String,
	rule: Dictionary,
	turn: Dictionary
) -> Dictionary:
	if rule.is_empty():
		return {"ok": true}
	var normalized_utterance: String = utterance.to_lower()
	for raw_forbidden: Variant in rule.get("forbidden_terms", []) as Array:
		var forbidden: String = String(raw_forbidden)
		if normalized_utterance.contains(forbidden.to_lower()):
			return _turn_error(
				"turn_semantic_conflict",
				"ActorTurn 台词与 claim %s 的权威语义冲突：出现禁止词项“%s”。" % [claim_id, forbidden],
				turn
			)
	for raw_group: Variant in rule.get("required_term_groups", []) as Array:
		var group: Array = raw_group as Array
		var matched: bool = false
		for raw_term: Variant in group:
			if normalized_utterance.contains(String(raw_term).to_lower()):
				matched = true
				break
		if not matched:
			return _turn_error(
				"turn_semantic_required_concept_missing",
				"ActorTurn 声称 claim %s，但台词没有表达作者要求的关键概念组：%s。" % [claim_id, str(group)],
				turn
			)
	return {"ok": true}


func _turn_error(error_code: String, message: String, turn: Dictionary) -> Dictionary:
	return {
		"ok": false,
		"error_code": error_code,
		"message": message,
		"turn": turn.duplicate(true),
	}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
