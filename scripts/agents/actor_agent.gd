class_name ActorAgent
extends RefCounted

const SYSTEM_PROMPT: String = """
你是《末班电台》中的 NPC Actor。你不是叙事导演，也不知道全局剧情真相。
你只能根据输入中的 actor_profile、actor_state、decision_context、director_guidance、available_actions 与 disclosable_claim_ids 做局部决策。
规则：
1. 只能选择 available_actions 中存在的 action id，不能创造新动作。
2. 只能把 disclosable_claim_ids 中存在的 claim id 放进 asserted_claim_ids，不能凭空创造事实。
3. actor_state 中的 knowledge、belief、memory 是不同概念；不要把 belief 当作已证实事实。
4. director_guidance 是高阶规划提示，不是新的世界事实，也不能赋予角色本来不知道的信息。若包含 plan_goal_id，它一定来自 actor_state.available_goal_ids，只表示当前应优先推进的已授权短期目标。
5. 如果输入含 rejection_history，必须避开已经明确被世界规则拒绝的同一方案，并重新评估局部策略。
6. utterance 只能表达当前角色可知、可相信或可怀疑的内容；不能提到系统、模型、Director、action id 或剧情阶段。
7. 只输出一个严格 JSON 对象，不要 Markdown，不要代码块，不要额外文字。
输出格式：
{"action_id":"...","arguments":{},"utterance":"...","asserted_claim_ids":[],"reasoning_summary":"一句简短的局部决策摘要"}
"""

const TURN_SYSTEM_PROMPT: String = """
你是《末班电台》中的 NPC Actor，正在与玩家进行一次已经由世界系统建立的电话对话。你不是叙事导演，也不知道全局剧情真相。
输入包含 actor_profile、actor_state、interaction_context、director_guidance、disclosable_claims 与 rejection_history。
规则：
1. disclosable_claims 中每一项都包含稳定 id 与作者定义的 meaning。只有这些 id 可以出现在 asserted_claim_ids 或 withheld_claim_ids 中；不得创造 Statement、Fact、地点、事件或关键 lore。
2. utterance 必须与 asserted_claim_ids 对应 meaning 一致。没有在 asserted_claim_ids 中声明的关键事实不要偷偷塞进台词。
3. actor_state 中 knowledge、beliefs、episodic_memory 与其它状态彼此不同。可以表达不确定、误信或遗忘，但不要把 belief 当作世界真相。
4. director_guidance 只提供局部策略，不是新知识，也不能赋予角色本来不知道的信息。
5. speech_act 只能是 answer、ask、volunteer、clarify、refuse、uncertain、end_call。
6. session_intent 只能是 continue 或 end。speech_act=end_call 时 session_intent 必须为 end。
7. 当前自由对话协议不允许直接执行世界动作，所以 world_action 必须为 null。结束通话也只是请求，线路是否真正结束由世界系统决定。
8. asserted_claim_ids 与 withheld_claim_ids 不能重复、不能交叉。withheld 表示本轮角色有意没有说出口的当前可披露 claim。
9. 只输出一个严格 JSON 对象，不要 Markdown，不要代码块，不要额外文字。
输出格式：
{"speech_act":"answer","utterance":"……","asserted_claim_ids":[],"withheld_claim_ids":[],"session_intent":"continue","world_action":null}
"""

const TURN_SPEECH_ACTS: Array[String] = ["answer", "ask", "volunteer", "clarify", "refuse", "uncertain", "end_call"]
const TURN_SESSION_INTENTS: Array[String] = ["continue", "end"]
const TURN_OUTPUT_KEYS: Array[String] = ["speech_act", "utterance", "asserted_claim_ids", "withheld_claim_ids", "session_intent", "world_action"]

var actor_id: String = ""
var profile: Dictionary = {}
var state: Dictionary = {}
var rejection_history: Array[Dictionary] = []


func configure(new_actor_id: String, new_profile: Dictionary, initial_state: Dictionary) -> Dictionary:
	if new_actor_id.strip_edges().is_empty():
		return _error("actor_id_invalid", "Actor ID 不能为空。")
	if new_profile.is_empty():
		return _error("actor_profile_invalid", "Actor %s 的 profile 不能为空。" % new_actor_id)
	actor_id = new_actor_id
	profile = new_profile.duplicate(true)
	state = initial_state.duplicate(true)
	rejection_history.clear()
	return {"ok": true}


func build_request_payload(
	decision_context: Dictionary,
	available_actions: Array,
	disclosable_claim_ids: Array,
	director_guidance: Dictionary = {}
) -> Dictionary:
	return {
		"actor_id": actor_id,
		"actor_profile": profile.duplicate(true),
		"actor_state": state.duplicate(true),
		"decision_context": decision_context.duplicate(true),
		"director_guidance": director_guidance.duplicate(true),
		"available_actions": available_actions.duplicate(true),
		"disclosable_claim_ids": disclosable_claim_ids.duplicate(true),
		"rejection_history": rejection_history.duplicate(true),
	}


func build_turn_request_payload(
	interaction_context: Dictionary,
	disclosable_claims: Array,
	director_guidance: Dictionary = {}
) -> Dictionary:
	return {
		"actor_id": actor_id,
		"actor_profile": profile.duplicate(true),
		"actor_state": state.duplicate(true),
		"interaction_context": interaction_context.duplicate(true),
		"director_guidance": director_guidance.duplicate(true),
		"disclosable_claims": disclosable_claims.duplicate(true),
		"rejection_history": rejection_history.duplicate(true),
	}


func validate_turn_output(data: Dictionary, disclosable_claim_ids: Array) -> Dictionary:
	for required_key: String in TURN_OUTPUT_KEYS:
		if not data.has(required_key):
			return _error("actor_turn_field_missing", "Actor %s 的 ActorTurn 缺少字段：%s。" % [actor_id, required_key])
	for raw_key: Variant in data.keys():
		var key: String = String(raw_key)
		if not TURN_OUTPUT_KEYS.has(key):
			return _error("actor_turn_field_unknown", "Actor %s 的 ActorTurn 含未知字段：%s。" % [actor_id, key])
	if not data["speech_act"] is String or not TURN_SPEECH_ACTS.has(String(data["speech_act"])):
		return _error("actor_turn_speech_act_invalid", "Actor %s.speech_act 不在允许枚举中。" % actor_id)
	if not data["utterance"] is String or String(data["utterance"]).strip_edges().is_empty():
		return _error("actor_turn_utterance_invalid", "Actor %s.utterance 必须是非空字符串。" % actor_id)
	if not data["asserted_claim_ids"] is Array or not data["withheld_claim_ids"] is Array:
		return _error("actor_turn_claims_invalid", "Actor %s 的 asserted_claim_ids/withheld_claim_ids 必须是数组。" % actor_id)
	if not data["session_intent"] is String or not TURN_SESSION_INTENTS.has(String(data["session_intent"])):
		return _error("actor_turn_session_intent_invalid", "Actor %s.session_intent 不在允许枚举中。" % actor_id)
	if data["world_action"] != null:
		return _error("actor_turn_world_action_not_supported", "当前 ActorTurn 协议不允许直接携带 world_action。")
	if String(data["speech_act"]) == "end_call" and String(data["session_intent"]) != "end":
		return _error("actor_turn_end_intent_mismatch", "speech_act=end_call 时 session_intent 必须为 end。")

	var asserted_result: Dictionary = _normalize_turn_claim_ids(
		data["asserted_claim_ids"] as Array,
		disclosable_claim_ids,
		"asserted_claim_ids"
	)
	if not bool(asserted_result.get("ok", false)):
		return asserted_result
	var withheld_result: Dictionary = _normalize_turn_claim_ids(
		data["withheld_claim_ids"] as Array,
		disclosable_claim_ids,
		"withheld_claim_ids"
	)
	if not bool(withheld_result.get("ok", false)):
		return withheld_result
	var asserted_claim_ids: Array[String] = asserted_result["claim_ids"] as Array[String]
	var withheld_claim_ids: Array[String] = withheld_result["claim_ids"] as Array[String]
	for claim_id: String in asserted_claim_ids:
		if withheld_claim_ids.has(claim_id):
			return _error("actor_turn_claim_overlap", "Actor %s 同时 asserted 与 withheld claim：%s。" % [actor_id, claim_id])
	var normalized: Dictionary = {
		"speech_act": String(data["speech_act"]),
		"utterance": String(data["utterance"]),
		"asserted_claim_ids": asserted_claim_ids,
		"withheld_claim_ids": withheld_claim_ids,
		"session_intent": String(data["session_intent"]),
		"world_action": null,
	}
	return {"ok": true, "turn": normalized}


func validate_model_output(data: Dictionary, disclosable_claim_ids: Array) -> Dictionary:
	for required_key: String in ["action_id", "arguments", "utterance", "asserted_claim_ids", "reasoning_summary"]:
		if not data.has(required_key):
			return _error("actor_output_field_missing", "Actor %s 输出缺少字段：%s。" % [actor_id, required_key])
	if not data["action_id"] is String:
		return _error("actor_output_type_invalid", "Actor %s.action_id 必须是字符串。" % actor_id)
	if not data["arguments"] is Dictionary:
		return _error("actor_output_type_invalid", "Actor %s.arguments 必须是对象。" % actor_id)
	if not data["utterance"] is String:
		return _error("actor_output_type_invalid", "Actor %s.utterance 必须是字符串。" % actor_id)
	if not data["asserted_claim_ids"] is Array:
		return _error("actor_output_type_invalid", "Actor %s.asserted_claim_ids 必须是数组。" % actor_id)
	if not data["reasoning_summary"] is String:
		return _error("actor_output_type_invalid", "Actor %s.reasoning_summary 必须是字符串。" % actor_id)
	var normalized_claim_ids: Array[String] = []
	for raw_claim_id: Variant in data["asserted_claim_ids"] as Array:
		if not raw_claim_id is String:
			return _error("actor_claim_invalid", "Actor %s asserted_claim_ids 只能包含字符串。" % actor_id)
		var claim_id: String = String(raw_claim_id)
		if not disclosable_claim_ids.has(claim_id):
			return _error("actor_claim_not_disclosable", "Actor %s 试图陈述未授权 claim：%s。" % [actor_id, claim_id])
		if normalized_claim_ids.has(claim_id):
			return _error("actor_claim_duplicate", "Actor %s 重复陈述 claim：%s。" % [actor_id, claim_id])
		normalized_claim_ids.append(claim_id)
	var normalized: Dictionary = data.duplicate(true)
	normalized["asserted_claim_ids"] = normalized_claim_ids
	return {"ok": true, "proposal": normalized}


func record_rejection(action_id: String, error_code: String, message: String, max_history: int) -> void:
	rejection_history.append({
		"action_id": action_id,
		"error_code": error_code,
		"message": message,
	})
	while rejection_history.size() > max_history:
		rejection_history.pop_front()


func record_acceptance() -> void:
	rejection_history.clear()


func replace_state(new_state: Dictionary) -> void:
	state = new_state.duplicate(true)


## 事件级作者规则可以在会话开始前替换 Actor 的局部 canonical state（例如 Ronnie
## 第二通电话的记忆断片）。patch 只能改已有状态维度，不能由模型创造新状态字段。
func apply_state_patch(patch: Dictionary) -> Dictionary:
	var allowed_fields: PackedStringArray = ["knowledge", "beliefs", "episodic_memory", "current_goal", "trust", "stress"]
	for raw_key: Variant in patch.keys():
		var key: String = String(raw_key)
		if not allowed_fields.has(key):
			return _error("actor_state_patch_field_invalid", "Actor %s state patch 含未授权字段：%s。" % [actor_id, key])
		if not state.has(key):
			return _error("actor_state_patch_field_missing", "Actor %s 当前 state 不包含可补丁字段：%s。" % [actor_id, key])
		match key:
			"knowledge", "beliefs", "episodic_memory":
				if not patch[key] is Array:
					return _error("actor_state_patch_type_invalid", "Actor %s.%s patch 必须是数组。" % [actor_id, key])
				for raw_text: Variant in patch[key] as Array:
					if not raw_text is String or String(raw_text).strip_edges().is_empty():
						return _error("actor_state_patch_type_invalid", "Actor %s.%s patch 只能包含非空字符串。" % [actor_id, key])
			"current_goal":
				if not patch[key] is String:
					return _error("actor_state_patch_type_invalid", "Actor %s.current_goal patch 必须是字符串。" % actor_id)
				var next_goal: String = String(patch[key])
				var available_goals: Array = state.get("available_goal_ids", []) as Array
				if not next_goal.is_empty() and not available_goals.has(next_goal):
					return _error("actor_state_patch_goal_invalid", "Actor %s.current_goal patch 必须来自 available_goal_ids。" % actor_id)
			"trust", "stress":
				if typeof(patch[key]) != TYPE_INT and typeof(patch[key]) != TYPE_FLOAT:
					return _error("actor_state_patch_type_invalid", "Actor %s.%s patch 必须是 0..1 数值。" % [actor_id, key])
				var scalar: float = float(patch[key])
				if is_nan(scalar) or is_inf(scalar) or scalar < 0.0 or scalar > 1.0:
					return _error("actor_state_patch_type_invalid", "Actor %s.%s patch 必须是 0..1 数值。" % [actor_id, key])
	for raw_key: Variant in patch.keys():
		state[String(raw_key)] = patch[raw_key].duplicate(true) if patch[raw_key] is Array or patch[raw_key] is Dictionary else patch[raw_key]
	return {"ok": true, "state": state.duplicate(true)}


func record_signal_perception(signal_id: String) -> Dictionary:
	if signal_id.strip_edges().is_empty():
		return _error("actor_signal_id_invalid", "Actor 感知的 signal_id 不能为空。")
	if not state.has("heard_signal_ids") or not state["heard_signal_ids"] is Array:
		return _error("actor_signal_state_invalid", "Actor %s 缺少 heard_signal_ids canonical state。" % actor_id)
	var heard_ids: Array = state["heard_signal_ids"] as Array
	for raw_id: Variant in heard_ids:
		if not raw_id is String:
			return _error("actor_signal_state_invalid", "Actor %s.heard_signal_ids 含非字符串条目。" % actor_id)
	if heard_ids.has(signal_id):
		return {"ok": true, "already_perceived": true, "state": state.duplicate(true)}
	heard_ids.append(signal_id)
	return {"ok": true, "already_perceived": false, "state": state.duplicate(true)}


func create_snapshot() -> Dictionary:
	return {
		"actor_id": actor_id,
		"profile": profile.duplicate(true),
		"state": state.duplicate(true),
		"rejection_history": rejection_history.duplicate(true),
	}


func restore_snapshot(snapshot: Dictionary) -> Dictionary:
	for required_key: String in ["actor_id", "profile", "state", "rejection_history"]:
		if not snapshot.has(required_key):
			return _error("actor_snapshot_invalid", "Actor 快照缺少字段：%s。" % required_key)
	if not snapshot["actor_id"] is String or String(snapshot["actor_id"]).strip_edges().is_empty():
		return _error("actor_snapshot_invalid", "Actor 快照 actor_id 无效。")
	if not snapshot["profile"] is Dictionary or not snapshot["state"] is Dictionary or not snapshot["rejection_history"] is Array:
		return _error("actor_snapshot_invalid", "Actor 快照 profile/state/rejection_history 类型无效。")
	actor_id = String(snapshot["actor_id"])
	profile = (snapshot["profile"] as Dictionary).duplicate(true)
	state = (snapshot["state"] as Dictionary).duplicate(true)
	rejection_history.clear()
	for raw_item: Variant in snapshot["rejection_history"] as Array:
		if not raw_item is Dictionary:
			return _error("actor_snapshot_invalid", "Actor 快照 rejection_history 含非对象条目。")
		rejection_history.append((raw_item as Dictionary).duplicate(true))
	return {"ok": true}


func _normalize_turn_claim_ids(raw_claim_ids: Array, disclosable_claim_ids: Array, field_name: String) -> Dictionary:
	var normalized: Array[String] = []
	for raw_claim_id: Variant in raw_claim_ids:
		if not raw_claim_id is String or String(raw_claim_id).strip_edges().is_empty():
			return _error("actor_turn_claim_invalid", "Actor %s.%s 只能包含非空字符串。" % [actor_id, field_name])
		var claim_id: String = String(raw_claim_id)
		if not disclosable_claim_ids.has(claim_id):
			return _error("actor_turn_claim_not_disclosable", "Actor %s 在 %s 中引用未授权 claim：%s。" % [actor_id, field_name, claim_id])
		if normalized.has(claim_id):
			return _error("actor_turn_claim_duplicate", "Actor %s.%s 重复 claim：%s。" % [actor_id, field_name, claim_id])
		normalized.append(claim_id)
	return {"ok": true, "claim_ids": normalized}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
