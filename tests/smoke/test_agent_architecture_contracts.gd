extends SceneTree

## 不访问网络的 Agent 架构合同测试：配置、Actor claim 边界、动作白名单、
## Director 输出约束与 AgentRuntime 快照都必须保持确定性。

const AGENT_CONFIG_SCRIPT: GDScript = preload("res://scripts/agents/agent_config.gd")
const ACTION_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/agents/agent_action_validator.gd")
const ACTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/actor_agent.gd")
const DIRECTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/director_agent.gd")
const TURN_SEMANTIC_GUARD_SCRIPT: GDScript = preload("res://scripts/agents/turn_semantic_guard.gd")
const AGENT_RUNTIME_SCRIPT: GDScript = preload("res://scripts/systems/agent_runtime.gd")

var _has_failed: bool = false


func _init() -> void:
	_test_config_contract()
	_test_actor_claim_boundary()
	_test_actor_turn_contracts()
	_test_turn_semantic_guard()
	_test_action_validation_and_fallback()
	_test_director_contract()
	_test_runtime_snapshot()
	if _has_failed:
		print("[测试][AgentArchitectureContracts] 失败。")
		quit(1)
		return
	print("[测试][AgentArchitectureContracts] 通过：Director/Actor/动作/快照合同成立。")
	quit(0)


func _test_config_contract() -> void:
	var loader: AgentConfig = AGENT_CONFIG_SCRIPT.new() as AgentConfig
	var valid_config: Dictionary = _valid_config()
	_assert_ok(loader.validate_document(valid_config), "合法 Agent 配置必须通过。")
	var json_number_config: Dictionary = valid_config.duplicate(true)
	json_number_config["schema_version"] = 1.0
	(json_number_config["director"] as Dictionary)["max_tokens"] = 1200.0
	(json_number_config["director"] as Dictionary)["timeout_seconds"] = 45.0
	(json_number_config["actor"] as Dictionary)["max_tokens"] = 600.0
	(json_number_config["actor"] as Dictionary)["timeout_seconds"] = 30.0
	(json_number_config["runtime"] as Dictionary)["actor_retry_limit"] = 2.0
	(json_number_config["runtime"] as Dictionary)["max_rejection_history"] = 6.0
	_assert_ok(loader.validate_document(json_number_config), "Godot JSON 解析得到的精确整数 float 必须通过。")
	var fractional_version: Dictionary = json_number_config.duplicate(true)
	fractional_version["schema_version"] = 1.5
	_assert_error_code(loader.validate_document(fractional_version), "config_field_type_invalid", "非整数 JSON number 必须继续被拒绝。")
	var missing_model: Dictionary = valid_config.duplicate(true)
	(missing_model["actor"] as Dictionary).erase("model")
	_assert_error_code(loader.validate_document(missing_model), "config_field_missing", "缺少 actor.model 必须被拒绝。")


func _test_actor_claim_boundary() -> void:
	var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
	_assert_ok(actor.configure("ronnie", {"display_name": "罗尼"}, {"beliefs": {}, "memory": []}), "Actor 必须可以配置。")
	var valid_output: Dictionary = {
		"action_id": "call_station",
		"arguments": {},
		"utterance": "我想再确认一次调度记录。",
		"asserted_claim_ids": ["claim_dispatch_empty"],
		"reasoning_summary": "向外部来源求证",
	}
	_assert_ok(actor.validate_model_output(valid_output, ["claim_dispatch_empty"]), "Actor 只能陈述授权 claim。")
	var leaked_output: Dictionary = valid_output.duplicate(true)
	leaked_output["asserted_claim_ids"] = ["claim_secret_future"]
	_assert_error_code(
		actor.validate_model_output(leaked_output, ["claim_dispatch_empty"]),
		"actor_claim_not_disclosable",
		"Actor 未授权 claim 必须被拒绝。"
	)


func _test_actor_turn_contracts() -> void:
	var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
	_assert_ok(actor.configure("ronnie", {"display_name": "罗尼"}, {"knowledge": {}, "beliefs": {}, "episodic_memory": []}), "ActorTurn 测试 Actor 必须可以配置。")
	var valid_turn: Dictionary = {
		"speech_act": "answer",
		"utterance": "我记得车斗里有碎玻璃，但调度单上没有这趟活。",
		"asserted_claim_ids": ["statement_ronnie_dispatch_mismatch"],
		"withheld_claim_ids": [],
		"session_intent": "continue",
		"world_action": null,
	}
	_assert_ok(actor.validate_turn_output(valid_turn, ["statement_ronnie_dispatch_mismatch"]), "合法 ActorTurn 必须通过严格结构校验。")
	var bad_speech_act: Dictionary = valid_turn.duplicate(true)
	bad_speech_act["speech_act"] = "solve_mystery"
	_assert_error_code(actor.validate_turn_output(bad_speech_act, ["statement_ronnie_dispatch_mismatch"]), "actor_turn_speech_act_invalid", "ActorTurn 不得创造 speech_act。")
	var leaked_turn: Dictionary = valid_turn.duplicate(true)
	leaked_turn["asserted_claim_ids"] = ["statement_future_secret"]
	_assert_error_code(actor.validate_turn_output(leaked_turn, ["statement_ronnie_dispatch_mismatch"]), "actor_turn_claim_not_disclosable", "ActorTurn asserted claim 必须受白名单约束。")
	var overlap_turn: Dictionary = valid_turn.duplicate(true)
	overlap_turn["withheld_claim_ids"] = ["statement_ronnie_dispatch_mismatch"]
	_assert_error_code(actor.validate_turn_output(overlap_turn, ["statement_ronnie_dispatch_mismatch"]), "actor_turn_claim_overlap", "同一 claim 不能同时 asserted 与 withheld。")
	var world_action_turn: Dictionary = valid_turn.duplicate(true)
	world_action_turn["world_action"] = {"action_id": "hangup"}
	_assert_error_code(actor.validate_turn_output(world_action_turn, ["statement_ronnie_dispatch_mismatch"]), "actor_turn_world_action_not_supported", "ActorTurn 不能绕过确定性世界提交 world_action。")
	var bad_end_turn: Dictionary = valid_turn.duplicate(true)
	bad_end_turn["speech_act"] = "end_call"
	bad_end_turn["session_intent"] = "continue"
	_assert_error_code(actor.validate_turn_output(bad_end_turn, ["statement_ronnie_dispatch_mismatch"]), "actor_turn_end_intent_mismatch", "Actor 请求结束通话必须使用 end intent。")


func _test_turn_semantic_guard() -> void:
	var guard: TurnSemanticGuard = TURN_SEMANTIC_GUARD_SCRIPT.new() as TurnSemanticGuard
	var claims: Array = [
		{
			"id": "statement_dog_walker_wagon_color",
			"meaning": "遛狗者看到一辆深色旧旅行车，右后灯忽明忽暗。",
			"semantic_guard": {
				"required_term_groups": [["深色", "暗色", "暗绿"], ["旅行车"], ["右后灯", "尾灯"]],
				"forbidden_terms": ["鲜红", "红色旅行车"],
			},
		},
	]
	_assert_ok(guard.validate_claim_catalog(claims), "合法 claim semantic catalog 必须通过。")
	var valid_turn: Dictionary = {
		"speech_act": "answer",
		"utterance": "我看见的是辆深色旧旅行车，右后灯一亮一灭。",
		"asserted_claim_ids": ["statement_dog_walker_wagon_color"],
		"withheld_claim_ids": [],
		"session_intent": "continue",
		"world_action": null,
	}
	_assert_ok(guard.validate_turn_semantics(valid_turn, claims), "ActorTurn 台词与 claim 作者语义一致时必须通过。")
	var conflicting_turn: Dictionary = valid_turn.duplicate(true)
	conflicting_turn["utterance"] = "我看见的是一辆鲜红色的旅行车，右后灯一亮一灭。"
	_assert_error_code(guard.validate_turn_semantics(conflicting_turn, claims), "turn_semantic_conflict", "结构合法但与 claim 含义冲突的台词必须被拒绝。")
	var missing_concept_turn: Dictionary = valid_turn.duplicate(true)
	missing_concept_turn["utterance"] = "我只看到一辆深色旧旅行车。"
	_assert_error_code(guard.validate_turn_semantics(missing_concept_turn, claims), "turn_semantic_required_concept_missing", "声明关键 claim 时缺少作者要求的概念必须被拒绝。")


func _test_action_validation_and_fallback() -> void:
	var validator: AgentActionValidator = ACTION_VALIDATOR_SCRIPT.new() as AgentActionValidator
	var actions: Array = [
		{
			"id": "drive_bridge",
			"description": "前往北桥",
			"argument_keys": [],
			"fallback_priority": 20,
		},
		{
			"id": "call_station",
			"description": "给电台打电话",
			"argument_keys": ["topic"],
			"fallback_priority": 5,
			"fallback_arguments": {"topic": "verify_discrepancy"},
		},
	]
	_assert_ok(validator.validate_available_actions(actions), "动作定义必须通过校验。")
	var invalid_proposal: Dictionary = {
		"action_id": "teleport",
		"arguments": {},
		"utterance": "",
	}
	var invalid_result: Dictionary = validator.validate_proposal(invalid_proposal, actions)
	_assert_error_code(invalid_result, "action_not_available", "Actor 不能创造动作。")
	_assert_equal(String((invalid_result.get("proposal", {}) as Dictionary).get("action_id", "")), "teleport", "被拒绝 proposal 必须保留 action_id 供 Director 识别循环。")
	var fallback: Dictionary = validator.choose_deterministic_fallback(actions)
	_assert_ok(fallback, "必须能选择 deterministic fallback。")
	var proposal: Dictionary = fallback.get("proposal", {}) as Dictionary
	_assert_equal(String(proposal.get("action_id", "")), "call_station", "fallback 必须按最低 fallback_priority 选择。")
	_assert_equal((proposal.get("arguments", {}) as Dictionary).get("topic", ""), "verify_discrepancy", "fallback 必须携带作者显式参数。")
	var world_checked: Dictionary = validator.choose_valid_deterministic_fallback(actions, Callable(self, "_reject_first_fallback"))
	_assert_ok(world_checked, "首个 fallback 被世界拒绝后必须继续尝试后续候选。")
	_assert_equal(String((world_checked.get("proposal", {}) as Dictionary).get("action_id", "")), "drive_bridge", "第二个合法 fallback 必须被选中。")
	_assert_equal(int(world_checked.get("attempted_candidate_count", 0)), 2, "fallback 必须记录已尝试两个候选。")
	var all_rejected: Dictionary = validator.choose_valid_deterministic_fallback(actions, Callable(self, "_reject_all_fallbacks"))
	_assert_error_code(all_rejected, "agent_liveness_exhausted", "只有全部 deterministic fallback 被拒绝才允许活性耗尽。")
	_assert_equal(int(all_rejected.get("attempted_candidate_count", 0)), 2, "活性耗尽前必须尝试全部 fallback 候选。")


func _test_director_contract() -> void:
	var director: DirectorAgent = DIRECTOR_AGENT_SCRIPT.new() as DirectorAgent
	var actions: Array = [
		{"id": "call_station", "description": "给电台打电话", "argument_keys": [], "fallback_priority": 1},
		{"id": "wait", "description": "等待", "argument_keys": [], "fallback_priority": 2},
	]
	var guidance: Dictionary = {
		"immediate_goal": "向外部来源求证",
		"salient_conflicts": ["记忆与调度记录冲突"],
		"prefer_action_ids": ["call_station"],
		"avoid_action_ids": [],
		"strategy_hint": "不要继续依赖同一条记忆。",
	}
	_assert_ok(director.validate_guidance(guidance, actions), "Director guidance 必须受动作集合约束。")
	var bad_guidance: Dictionary = guidance.duplicate(true)
	bad_guidance["prefer_action_ids"] = ["invent_plot_event"]
	_assert_error_code(director.validate_guidance(bad_guidance, actions), "director_action_not_available", "Director 不能创造动作。")
	var actor_summaries: Array = [
		{"actor_id": "ronnie", "available_goal_ids": ["verify_memory", "seek_external_confirmation"]},
	]
	var opportunities: Array = [
		{"id": "opportunity_ronnie_call", "description": "允许罗尼的求证电话进入表现层"},
		{"id": "opportunity_silence", "description": "继续保持短暂沉默"},
	]
	var plan: Dictionary = {
		"selected_opportunity_ids": ["opportunity_ronnie_call"],
		"actor_goal_ids": {"ronnie": "seek_external_confirmation"},
		"pacing_note": "让记忆冲突进入玩家视野。",
	}
	_assert_ok(director.validate_plan(plan, actor_summaries, opportunities), "Director 全局 plan 必须只能选择已声明 opportunity 与 goal。")
	var invented_plan: Dictionary = plan.duplicate(true)
	invented_plan["selected_opportunity_ids"] = ["invented_scene"]
	_assert_error_code(director.validate_plan(invented_plan, actor_summaries, opportunities), "director_opportunity_not_available", "Director 不能创造叙事机会。")
	var invented_goal_plan: Dictionary = plan.duplicate(true)
	invented_goal_plan["actor_goal_ids"] = {"ronnie": "solve_mystery_now"}
	_assert_error_code(director.validate_plan(invented_goal_plan, actor_summaries, opportunities), "director_goal_not_available", "Director 不能给 Actor 创造未授权 goal。")


func _test_runtime_snapshot() -> void:
	var runtime: AgentRuntimeService = AGENT_RUNTIME_SCRIPT.new() as AgentRuntimeService
	_assert_ok(runtime.register_actor("ronnie", {"display_name": "罗尼"}, {"goal": "verify_memory", "available_goal_ids": ["verify_memory", "seek_external_confirmation"]}), "AgentRuntime 必须可以注册 Actor。")
	var snapshot: Dictionary = runtime.create_snapshot()
	_assert_equal(int(snapshot.get("agent_state_format_version", 0)), 2, "AgentRuntime v2 快照必须显式携带 autonomous orchestration state。")
	_assert_true(snapshot.get("autonomous_state") is Dictionary, "AgentRuntime 快照必须包含 autonomous_state。")
	_assert_ok(runtime.validate_snapshot(snapshot), "AgentRuntime 自身快照必须通过验证。")
	var tampered: Dictionary = snapshot.duplicate(true)
	(((tampered["autonomous_state"] as Dictionary)["director_trigger_policy"] as Dictionary)["pending_triggers"] as Array).append({
		"kind": "fact_confirmed",
		"source_id": "fact_future",
		"created_at_tick": 9999,
	})
	_assert_error_code(runtime.validate_snapshot(tampered), "director_trigger_snapshot_trigger_invalid", "AgentRuntime 必须拒绝来自未来的 autonomous pending trigger。")
	var restored: AgentRuntimeService = AGENT_RUNTIME_SCRIPT.new() as AgentRuntimeService
	_assert_ok(restored.restore_snapshot(snapshot), "AgentRuntime 快照必须可恢复而不重新调用模型。")
	var actor_snapshot: Dictionary = restored.get_actor_snapshot("ronnie")
	_assert_ok(actor_snapshot, "恢复后 Actor 必须仍存在。")
	_assert_equal(
		String((((actor_snapshot["snapshot"] as Dictionary)["state"] as Dictionary).get("goal", ""))),
		"verify_memory",
		"恢复后 Actor state 必须保持提交历史。"
	)


func _valid_config() -> Dictionary:
	return {
		"schema_version": 1,
		"enabled": false,
		"director": _endpoint("director-model", 0.2, 1200, 45),
		"actor": _endpoint("actor-model", 0.7, 600, 30),
		"runtime": {
			"actor_retry_limit": 2,
			"director_guidance_enabled": true,
			"director_force_action_enabled": true,
			"deterministic_fallback_policy": "lowest_fallback_priority",
			"max_rejection_history": 6,
		},
	}


func _endpoint(model: String, temperature: float, max_tokens: int, timeout_seconds: int) -> Dictionary:
	return {
		"protocol": "openai_chat_completions",
		"url": "https://example.invalid/v1/chat/completions",
		"model": model,
		"api_key": "",
		"temperature": temperature,
		"max_tokens": max_tokens,
		"timeout_seconds": timeout_seconds,
		"extra_headers": {},
		"extra_body": {},
	}


func _reject_first_fallback(candidate: Dictionary, _definition: Dictionary) -> Dictionary:
	if String(candidate.get("action_id", "")) == "call_station":
		return {"ok": false, "error_code": "line_busy", "message": "线路暂时不可用。"}
	return {"ok": true}


func _reject_all_fallbacks(_candidate: Dictionary, _definition: Dictionary) -> Dictionary:
	return {"ok": false, "error_code": "world_reject", "message": "测试拒绝。"}


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_error_code(result: Dictionary, expected_code: String, message: String) -> void:
	_assert_true(not bool(result.get("ok", true)), "%s 不应成功。" % message)
	_assert_equal(String(result.get("error_code", "")), expected_code, message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][AgentArchitectureContracts] %s" % message)
