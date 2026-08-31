class_name AgentRuntimeService
extends Node

## Director + Actor 的运行时编排层。
##
## 权限边界：模型只能返回 proposal；StoryEngine/世界系统仍是事实与提交权威。
## 本服务永远不读取 SettingsManager，模型配置只来自独立 Agent JSON 配置文件。

signal runtime_status_changed(status: Dictionary)
signal director_plan_updated(plan_snapshot: Dictionary)
signal actor_registered(actor_id: String)
signal actor_decision_started(actor_id: String)
signal actor_decision_escalated(actor_id: String, level: String, reason: String)
signal actor_action_selected(actor_id: String, proposal: Dictionary, source: String)
signal actor_turn_started(actor_id: String)
signal actor_turn_escalated(actor_id: String, level: String, reason: String)
signal actor_turn_selected(actor_id: String, turn: Dictionary, source: String)
signal actor_perception_updated(actor_id: String, signal_id: String)
signal agent_request_failed(role: String, error_code: String, message: String)

const AGENT_STATE_FORMAT_VERSION: int = 2
const USER_CONFIG_PATH: String = "user://agent_runtime.json"
const LOCAL_CONFIG_PATH: String = "res://config/agent_runtime.local.json"

const AGENT_CONFIG_SCRIPT: GDScript = preload("res://scripts/agents/agent_config.gd")
const LLM_GATEWAY_SCRIPT: GDScript = preload("res://scripts/agents/llm_gateway.gd")
const ACTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/actor_agent.gd")
const DIRECTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/director_agent.gd")
const DIRECTOR_CONTEXT_BUILDER_SCRIPT: GDScript = preload("res://scripts/agents/director_context_builder.gd")
const ACTION_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/agents/agent_action_validator.gd")
const TURN_SEMANTIC_GUARD_SCRIPT: GDScript = preload("res://scripts/agents/turn_semantic_guard.gd")
const OPPORTUNITY_BUILDER_SCRIPT: GDScript = preload("res://scripts/systems/opportunity_builder.gd")
const DIRECTOR_TRIGGER_POLICY_SCRIPT: GDScript = preload("res://scripts/systems/director_trigger_policy.gd")
const ACTOR_SCHEDULER_SCRIPT: GDScript = preload("res://scripts/systems/actor_scheduler.gd")

var _config: Dictionary = {}
var _config_path: String = ""
var _last_config_result: Dictionary = {}
var _gateway: LlmGateway = null
var _director: DirectorAgent = null
var _director_context_builder: DirectorContextBuilder = null
var _action_validator: AgentActionValidator = null
var _turn_semantic_guard: TurnSemanticGuard = null
var _opportunity_builder: OpportunityBuilder = null
var _director_trigger_policy: DirectorTriggerPolicy = null
var _actor_scheduler: ActorScheduler = null
var _actors: Dictionary = {}
var _director_plan_serial: int = 0
var _director_plan_cache: Dictionary = {}
var _story_engine: RefCounted = null
var _phone_system: RefCounted = null
var _game_clock: Node = null
var _worldbook_director_lore: Dictionary = {}
var _autonomous_world_serial: int = 0
var _autonomous_cycle_running: bool = false
var _autonomous_cycle_queued: bool = false


func _ready() -> void:
	_gateway = LLM_GATEWAY_SCRIPT.new() as LlmGateway
	_director = DIRECTOR_AGENT_SCRIPT.new() as DirectorAgent
	_director_context_builder = DIRECTOR_CONTEXT_BUILDER_SCRIPT.new() as DirectorContextBuilder
	_action_validator = ACTION_VALIDATOR_SCRIPT.new() as AgentActionValidator
	_turn_semantic_guard = TURN_SEMANTIC_GUARD_SCRIPT.new() as TurnSemanticGuard
	_opportunity_builder = OPPORTUNITY_BUILDER_SCRIPT.new() as OpportunityBuilder
	_director_trigger_policy = DIRECTOR_TRIGGER_POLICY_SCRIPT.new() as DirectorTriggerPolicy
	_actor_scheduler = ACTOR_SCHEDULER_SCRIPT.new() as ActorScheduler
	add_child(_gateway)
	reload_config()


func reload_config() -> Dictionary:
	var loader: AgentConfig = AGENT_CONFIG_SCRIPT.new() as AgentConfig
	if loader == null:
		_last_config_result = _error("config_loader_missing", "无法创建 AgentConfig。")
		_config.clear()
		_config_path = ""
		runtime_status_changed.emit(get_runtime_status())
		return _last_config_result.duplicate(true)
	var selected_path: String = ""
	for candidate: String in [USER_CONFIG_PATH, LOCAL_CONFIG_PATH]:
		if FileAccess.file_exists(candidate):
			selected_path = candidate
			break
	if selected_path.is_empty():
		_last_config_result = _error(
			"config_missing",
			"未找到 Agent 配置。请创建 %s，或在开发环境创建 %s。" % [USER_CONFIG_PATH, LOCAL_CONFIG_PATH]
		)
		_config.clear()
		_config_path = ""
		runtime_status_changed.emit(get_runtime_status())
		return _last_config_result.duplicate(true)
	var load_result: Dictionary = loader.load_from_path(selected_path)
	_last_config_result = load_result.duplicate(true)
	if not bool(load_result.get("ok", false)):
		_config.clear()
		_config_path = selected_path
		push_error("[AgentRuntime][config_invalid] %s" % String(load_result.get("message", "Agent 配置无效。")))
		runtime_status_changed.emit(get_runtime_status())
		return load_result
	_config = (load_result["config"] as Dictionary).duplicate(true)
	_config_path = selected_path
	print("[AgentRuntime][config_loaded] 已读取独立 Agent 配置：%s，enabled=%s。" % [_config_path, str(bool(_config["enabled"]))])
	runtime_status_changed.emit(get_runtime_status())
	return {"ok": true, "path": _config_path, "enabled": bool(_config["enabled"])}


func get_runtime_status() -> Dictionary:
	return {
		"config_loaded": not _config.is_empty(),
		"config_path": _config_path,
		"enabled": is_enabled(),
		"world_bound": _story_engine != null and _phone_system != null and _game_clock != null,
		"actor_count": _actors.size(),
		"director_plan_serial": _director_plan_serial,
		"has_director_plan": not _director_plan_cache.is_empty(),
		"last_error_code": String(_last_config_result.get("error_code", "")),
		"last_message": String(_last_config_result.get("message", "")),
	}


func is_enabled() -> bool:
	return not _config.is_empty() and bool(_config.get("enabled", false))


## Autonomous Director/Actor 请求在途时不能保存：网络响应本身不可序列化，恢复一个
## 没有对应请求的 pending Actor 会造成永久死锁。已排队但尚未开始的 trigger 可以安全存档。
func can_save() -> bool:
	if _autonomous_cycle_running:
		return false
	if _actor_scheduler != null and _actor_scheduler.has_pending_requests():
		return false
	return true


func get_save_block_reason() -> String:
	if can_save():
		return ""
	return "导演或角色正在处理一次自主决策，请等待本次模型请求完成后再保存。"


func bind_world(
	story_engine: RefCounted,
	phone_system: RefCounted,
	game_clock: Node,
	worldbook_director_lore: Dictionary = {},
	compiled_world_definition: Dictionary = {}
) -> Dictionary:
	if story_engine == null or phone_system == null or game_clock == null:
		return _error("world_bind_invalid", "AgentRuntime 绑定世界时 StoryEngine、PhoneSystem、GameClock 均不能为空。")
	if not story_engine.has_method(&"create_snapshot"):
		return _error("world_contract_invalid", "StoryEngine 缺少 create_snapshot()，拒绝绑定 AgentRuntime。")
	if not phone_system.has_method(&"get_call_records"):
		return _error("world_contract_invalid", "PhoneSystem 缺少 get_call_records()，拒绝绑定 AgentRuntime。")
	if not game_clock.has_method(&"get_current_game_tick"):
		return _error("world_contract_invalid", "GameClock 缺少 get_current_game_tick()，拒绝绑定 AgentRuntime。")
	if _opportunity_builder == null or _director_trigger_policy == null or _actor_scheduler == null:
		return _error("autonomous_runtime_incomplete", "AgentRuntime autonomous 编排组件未初始化完成。")
	_story_engine = story_engine
	_phone_system = phone_system
	_game_clock = game_clock
	_worldbook_director_lore = worldbook_director_lore.duplicate(true)
	_autonomous_world_serial += 1
	_autonomous_cycle_running = false
	_autonomous_cycle_queued = false
	_opportunity_builder.reset()
	_director_trigger_policy.reset()
	_actor_scheduler.reset()
	if not compiled_world_definition.is_empty():
		var opportunity_result: Dictionary = _opportunity_builder.configure(compiled_world_definition)
		if not bool(opportunity_result.get("ok", false)):
			unbind_world()
			return opportunity_result
	if story_engine.has_signal(&"actor_signal_perceived"):
		var perception_callback: Callable = Callable(self, "_on_actor_signal_perceived")
		if not story_engine.is_connected(&"actor_signal_perceived", perception_callback):
			var perception_connect_result: Error = story_engine.connect(&"actor_signal_perceived", perception_callback)
			if perception_connect_result != OK:
				unbind_world()
				return _error("world_signal_connect_failed", "AgentRuntime 无法监听 StoryEngine.actor_signal_perceived。")
	if story_engine.has_method(&"get_actor_definitions"):
		var actor_definitions_value: Variant = story_engine.call(&"get_actor_definitions")
		if not actor_definitions_value is Array:
			unbind_world()
			return _error("world_actor_contract_invalid", "StoryEngine.get_actor_definitions() 必须返回 Array。")
		if not (actor_definitions_value as Array).is_empty():
			var actor_config_result: Dictionary = configure_actor_definitions(actor_definitions_value as Array)
			if not bool(actor_config_result.get("ok", false)):
				unbind_world()
				return actor_config_result
	if _opportunity_builder.is_configured():
		var autonomous_connect_result: Dictionary = _connect_autonomous_world_signals()
		if not bool(autonomous_connect_result.get("ok", false)):
			unbind_world()
			return autonomous_connect_result
	runtime_status_changed.emit(get_runtime_status())
	return {"ok": true, "autonomous_loop_configured": _opportunity_builder.is_configured()}


func unbind_world() -> void:
	_disconnect_autonomous_world_signals()
	if _story_engine != null and _story_engine.has_signal(&"actor_signal_perceived"):
		var perception_callback: Callable = Callable(self, "_on_actor_signal_perceived")
		if _story_engine.is_connected(&"actor_signal_perceived", perception_callback):
			_story_engine.disconnect(&"actor_signal_perceived", perception_callback)
	_story_engine = null
	_phone_system = null
	_game_clock = null
	_worldbook_director_lore.clear()
	_director_plan_serial = 0
	_director_plan_cache.clear()
	_actors.clear()
	_autonomous_world_serial += 1
	_autonomous_cycle_running = false
	_autonomous_cycle_queued = false
	if _opportunity_builder != null:
		_opportunity_builder.reset()
	if _director_trigger_policy != null:
		_director_trigger_policy.reset()
	if _actor_scheduler != null:
		_actor_scheduler.reset()
	runtime_status_changed.emit(get_runtime_status())


func configure_actor_definitions(actor_definitions: Array) -> Dictionary:
	if actor_definitions.is_empty():
		return _error("actor_definitions_empty", "Agent Dialogue v2 至少需要一个 Actor 定义。")
	if not _actors.is_empty():
		return _error("actors_already_configured", "本局 Actor 已配置，不能用另一份内容覆盖。")
	var configured_ids: Array[String] = []
	for raw_actor: Variant in actor_definitions:
		if not raw_actor is Dictionary:
			_actors.clear()
			return _error("actor_definition_invalid", "Actor 定义必须是对象。")
		var definition: Dictionary = raw_actor as Dictionary
		for field_name: String in ["id", "display_name", "voice_profile_id", "profile", "initial_state"]:
			if not definition.has(field_name):
				_actors.clear()
				return _error("actor_definition_invalid", "Actor 定义缺少字段：%s。" % field_name)
		if not definition["id"] is String or String(definition["id"]).strip_edges().is_empty():
			_actors.clear()
			return _error("actor_definition_invalid", "Actor id 必须是非空字符串。")
		if not definition["profile"] is Dictionary or not definition["initial_state"] is Dictionary:
			_actors.clear()
			return _error("actor_definition_invalid", "Actor profile/initial_state 必须是对象。")
		var actor_id: String = String(definition["id"])
		var runtime_profile: Dictionary = (definition["profile"] as Dictionary).duplicate(true)
		runtime_profile["display_name"] = String(definition["display_name"])
		runtime_profile["voice_profile_id"] = String(definition["voice_profile_id"])
		var result: Dictionary = register_actor(actor_id, runtime_profile, definition["initial_state"] as Dictionary)
		if not bool(result.get("ok", false)):
			_actors.clear()
			return result
		configured_ids.append(actor_id)
	return {"ok": true, "actor_ids": configured_ids}


func register_actor(actor_id: String, profile: Dictionary, initial_state: Dictionary) -> Dictionary:
	if _actors.has(actor_id):
		return _error("actor_already_registered", "Actor 已注册：%s。" % actor_id)
	var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
	if actor == null:
		return _error("actor_create_failed", "无法创建 Actor：%s。" % actor_id)
	var configure_result: Dictionary = actor.configure(actor_id, profile, initial_state)
	if not bool(configure_result.get("ok", false)):
		return configure_result
	_actors[actor_id] = actor
	actor_registered.emit(actor_id)
	return {"ok": true}


func unregister_actor(actor_id: String) -> Dictionary:
	if not _actors.has(actor_id):
		return _error("actor_not_registered", "Actor 未注册：%s。" % actor_id)
	_actors.erase(actor_id)
	return {"ok": true}


func replace_actor_state(actor_id: String, new_state: Dictionary) -> Dictionary:
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	(actor_result["actor"] as ActorAgent).replace_state(new_state)
	return {"ok": true}


func apply_actor_state_patch(actor_id: String, patch: Dictionary) -> Dictionary:
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	return (actor_result["actor"] as ActorAgent).apply_state_patch(patch)


func record_actor_signal_perception(actor_id: String, signal_id: String) -> Dictionary:
	if _story_engine == null or not _story_engine.has_method(&"get_actor_perceived_signal_ids"):
		return _error("world_signal_contract_missing", "AgentRuntime 只能从已绑定 StoryEngine 的 committed SignalSystem 接受 Actor 感知。")
	var committed_signal_ids_value: Variant = _story_engine.call(&"get_actor_perceived_signal_ids", actor_id)
	if not committed_signal_ids_value is Array:
		return _error("world_signal_contract_invalid", "StoryEngine.get_actor_perceived_signal_ids() 必须返回 Array。")
	if not (committed_signal_ids_value as Array).has(signal_id):
		return _error("actor_signal_not_committed", "Actor %s 不能感知未由 SignalSystem 提交的 signal：%s。" % [actor_id, signal_id])
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	var perception_result: Dictionary = (actor_result["actor"] as ActorAgent).record_signal_perception(signal_id)
	if not bool(perception_result.get("ok", false)):
		return perception_result
	if not bool(perception_result.get("already_perceived", false)):
		actor_perception_updated.emit(actor_id, signal_id)
	return perception_result


func get_actor_snapshot(actor_id: String) -> Dictionary:
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	return {"ok": true, "snapshot": (actor_result["actor"] as ActorAgent).create_snapshot()}


## 低频调用的 Director 全局规划入口。Director 只能选择调用方提供的候选 opportunity，
## 并只能为 Actor 选择其 state.available_goal_ids 中已经声明的 goal id。
## 返回值与缓存都只是 plan proposal；具体事件是否入队仍由调用方的确定性系统提交。
func request_director_plan(
	plan_context_id: String,
	world_summary: Dictionary,
	candidate_opportunities: Array,
	narrative_constraints: Dictionary = {}
) -> Dictionary:
	if not is_enabled():
		return _error("agent_runtime_disabled", "AgentRuntime 未启用或配置未成功加载。")
	if _story_engine == null or _phone_system == null or _game_clock == null:
		return _error("world_not_bound", "AgentRuntime 尚未绑定当前夜班 World Kernel。")
	if _gateway == null or _director == null:
		return _error("agent_runtime_incomplete", "AgentRuntime 的 Director 组件未初始化完成。")
	if plan_context_id.strip_edges().is_empty():
		return _error("director_plan_context_invalid", "Director plan_context_id 不能为空。")
	var summaries_result: Dictionary = _build_director_actor_summaries()
	if not bool(summaries_result.get("ok", false)):
		return summaries_result
	var actor_summaries: Array = summaries_result["actor_summaries"] as Array
	# 先用空选择验证调用方输入合同，避免把重复/无效候选 ID 发送给模型。
	var input_validation: Dictionary = _director.validate_plan(
		{"selected_opportunity_ids": [], "actor_goal_ids": {}, "pacing_note": "input_probe"},
		actor_summaries,
		candidate_opportunities
	)
	if not bool(input_validation.get("ok", false)):
		return input_validation
	var plan_payload: Dictionary = {}
	if not _worldbook_director_lore.is_empty():
		if _director_context_builder == null:
			return _error("director_context_builder_missing", "DirectorContextBuilder 未初始化，无法构造 WorldBook Director 上下文。")
		var context_result: Dictionary = _director_context_builder.build_context(
			plan_context_id,
			_worldbook_director_lore,
			_story_engine,
			_game_clock,
			_phone_system,
			actor_summaries,
			candidate_opportunities,
			narrative_constraints
		)
		if not bool(context_result.get("ok", false)):
			return context_result
		plan_payload = _director.build_plan_payload_from_context(context_result["context"] as Dictionary)
		if plan_payload.is_empty():
			return _error("director_context_payload_invalid", "DirectorContextBuilder 结果无法形成正式 plan payload。")
	else:
		# 兼容旧测试/fixture：未绑定 WorldBook lore 时继续使用调用方传入的 world_summary。
		plan_payload = _director.build_plan_payload(
			plan_context_id,
			world_summary,
			actor_summaries,
			candidate_opportunities,
			narrative_constraints
		)
	var response: Dictionary = await _gateway.request_json(
		_config["director"] as Dictionary,
		DirectorAgent.PLAN_SYSTEM_PROMPT,
		plan_payload
	)
	if not bool(response.get("ok", false)):
		_emit_request_failure("director", response)
		return response
	var plan_result: Dictionary = _director.validate_plan(
		response["data"] as Dictionary,
		actor_summaries,
		candidate_opportunities
	)
	if not bool(plan_result.get("ok", false)):
		return plan_result
	_director_plan_serial += 1
	_director_plan_cache = {
		"serial": _director_plan_serial,
		"context_id": plan_context_id,
		"plan": (plan_result["plan"] as Dictionary).duplicate(true),
	}
	director_plan_updated.emit(_director_plan_cache.duplicate(true))
	runtime_status_changed.emit(get_runtime_status())
	return {"ok": true, "plan_snapshot": _director_plan_cache.duplicate(true)}


func get_director_plan_cache() -> Dictionary:
	return _director_plan_cache.duplicate(true)


func clear_director_plan() -> void:
	_director_plan_cache.clear()
	runtime_status_changed.emit(get_runtime_status())


## 一次完整的 Actor 决策：Actor 自主 -> 受限重试 -> Director guidance -> Director force -> deterministic fallback。
## external_validator 是世界权威提供的只读校验回调；本函数只返回最终 proposal，不提交动作。
func request_actor_action(
	actor_id: String,
	decision_context: Dictionary,
	available_actions: Array,
	disclosable_claim_ids: Array,
	world_constraints: Dictionary = {},
	external_validator: Callable = Callable()
) -> Dictionary:
	var readiness: Dictionary = _validate_decision_readiness(actor_id, available_actions, disclosable_claim_ids)
	if not bool(readiness.get("ok", false)):
		return readiness
	var actor: ActorAgent = readiness["actor"] as ActorAgent
	var runtime_config: Dictionary = _config["runtime"] as Dictionary
	var actor_retry_limit: int = int(runtime_config["actor_retry_limit"])
	var max_history: int = int(runtime_config["max_rejection_history"])
	var baseline_guidance: Dictionary = _get_cached_actor_plan_guidance(actor_id)
	actor_decision_started.emit(actor_id)

	for attempt_index: int in range(actor_retry_limit):
		var actor_attempt: Dictionary = await _request_actor_once(
			actor,
			decision_context,
			available_actions,
			disclosable_claim_ids,
			baseline_guidance,
			external_validator
		)
		if bool(actor_attempt.get("ok", false)):
			actor.record_acceptance()
			var actor_proposal: Dictionary = actor_attempt["proposal"] as Dictionary
			var actor_source: String = "actor" if baseline_guidance.is_empty() else "actor_with_director_plan"
			actor_action_selected.emit(actor_id, actor_proposal.duplicate(true), actor_source)
			return {
				"ok": true,
				"proposal": actor_proposal.duplicate(true),
				"source": actor_source,
				"director_guidance": baseline_guidance.duplicate(true),
				"escalation_level": attempt_index,
			}
		_record_rejection(actor, actor_attempt, max_history)
		actor_decision_escalated.emit(
			actor_id,
			"actor_retry",
			String(actor_attempt.get("message", "Actor 决策无效。"))
		)

	var guidance: Dictionary = baseline_guidance.duplicate(true)
	if bool(runtime_config["director_guidance_enabled"]):
		actor_decision_escalated.emit(actor_id, "director_guidance", "Actor 受限重试耗尽，升级给 Director。")
		var guidance_result: Dictionary = await _request_director_guidance(
			actor,
			decision_context,
			available_actions,
			world_constraints
		)
		if bool(guidance_result.get("ok", false)):
			guidance = _merge_director_guidance(baseline_guidance, guidance_result["guidance"] as Dictionary)
			var guided_actions: Array = _apply_director_action_policy(available_actions, guidance)
			var guided_attempt: Dictionary = await _request_actor_once(
				actor,
				decision_context,
				guided_actions,
				disclosable_claim_ids,
				guidance,
				external_validator
			)
			if bool(guided_attempt.get("ok", false)):
				actor.record_acceptance()
				var guided_proposal: Dictionary = guided_attempt["proposal"] as Dictionary
				actor_action_selected.emit(actor_id, guided_proposal.duplicate(true), "actor_with_director_guidance")
				return {
					"ok": true,
					"proposal": guided_proposal.duplicate(true),
					"source": "actor_with_director_guidance",
					"director_guidance": guidance,
					"escalation_level": actor_retry_limit + 1,
				}
			_record_rejection(actor, guided_attempt, max_history)
		else:
			_emit_request_failure("director", guidance_result)

	if bool(runtime_config["director_force_action_enabled"]):
		actor_decision_escalated.emit(actor_id, "director_force_action", "Director guidance 后仍无合法动作，进入强恢复。")
		var force_result: Dictionary = await _request_director_force_action(
			actor,
			decision_context,
			available_actions,
			world_constraints,
			external_validator
		)
		if bool(force_result.get("ok", false)):
			actor.record_acceptance()
			var forced_proposal: Dictionary = force_result["proposal"] as Dictionary
			actor_action_selected.emit(actor_id, forced_proposal.duplicate(true), "director_force_action")
			return {
				"ok": true,
				"proposal": forced_proposal.duplicate(true),
				"source": "director_force_action",
				"director_guidance": guidance,
				"escalation_level": actor_retry_limit + 2,
			}
		_emit_request_failure("director", force_result)

	actor_decision_escalated.emit(actor_id, "deterministic_fallback", "模型恢复链耗尽，按优先级逐个验证确定性动作。")
	var fallback_validation: Dictionary = _action_validator.choose_valid_deterministic_fallback(
		available_actions,
		external_validator
	)
	if not bool(fallback_validation.get("ok", false)):
		return fallback_validation
	actor.record_acceptance()
	var fallback_proposal: Dictionary = fallback_validation["proposal"] as Dictionary
	actor_action_selected.emit(actor_id, fallback_proposal.duplicate(true), "deterministic_fallback")
	return {
		"ok": true,
		"proposal": fallback_proposal.duplicate(true),
		"source": "deterministic_fallback",
		"director_guidance": guidance,
		"escalation_level": actor_retry_limit + 3,
	}


## 自由对话专用入口。ActorTurn 与 ActorAction 保持独立，不允许通过 world_action 绕过确定性系统。
## 模型回复会先经过严格结构校验，再经过 TurnSemanticGuard；全部模型恢复失败后只使用作者可控、
## 不携带 claim 的 deterministic dialogue fallback，避免 API 故障把通话永久卡死。
func request_actor_turn(
	actor_id: String,
	interaction_context: Dictionary,
	disclosable_claims: Array,
	world_constraints: Dictionary = {},
	deterministic_fallback_turn: Dictionary = {},
	external_semantic_validator: Callable = Callable()
) -> Dictionary:
	var readiness: Dictionary = _validate_turn_readiness(actor_id, disclosable_claims)
	if not bool(readiness.get("ok", false)):
		return readiness
	var actor: ActorAgent = readiness["actor"] as ActorAgent
	var disclosable_claim_ids: Array[String] = readiness["claim_ids"] as Array[String]
	var runtime_config: Dictionary = _config["runtime"] as Dictionary
	var actor_retry_limit: int = int(runtime_config["actor_retry_limit"])
	var max_history: int = int(runtime_config["max_rejection_history"])
	var baseline_guidance: Dictionary = _get_cached_actor_plan_guidance(actor_id)
	actor_turn_started.emit(actor_id)

	for attempt_index: int in range(actor_retry_limit):
		var actor_attempt: Dictionary = await _request_actor_turn_once(
			actor,
			interaction_context,
			disclosable_claims,
			disclosable_claim_ids,
			baseline_guidance,
			external_semantic_validator
		)
		if bool(actor_attempt.get("ok", false)):
			actor.record_acceptance()
			var actor_turn: Dictionary = actor_attempt["turn"] as Dictionary
			var actor_source: String = "actor_turn" if baseline_guidance.is_empty() else "actor_turn_with_director_plan"
			actor_turn_selected.emit(actor_id, actor_turn.duplicate(true), actor_source)
			return {
				"ok": true,
				"turn": actor_turn.duplicate(true),
				"source": actor_source,
				"director_guidance": baseline_guidance.duplicate(true),
				"escalation_level": attempt_index,
			}
		_record_turn_rejection(actor, actor_attempt, max_history)
		actor_turn_escalated.emit(
			actor_id,
			"actor_turn_retry",
			String(actor_attempt.get("message", "ActorTurn 无效。"))
		)

	var guidance: Dictionary = baseline_guidance.duplicate(true)
	if bool(runtime_config["director_guidance_enabled"]):
		actor_turn_escalated.emit(actor_id, "director_turn_guidance", "ActorTurn 受限重试耗尽，升级给 Director 做局部语义纠偏。")
		var guidance_result: Dictionary = await _request_director_turn_guidance(
			actor,
			interaction_context,
			disclosable_claims,
			disclosable_claim_ids,
			world_constraints
		)
		if bool(guidance_result.get("ok", false)):
			guidance = _merge_director_guidance(baseline_guidance, guidance_result["guidance"] as Dictionary)
			var guided_attempt: Dictionary = await _request_actor_turn_once(
				actor,
				interaction_context,
				disclosable_claims,
				disclosable_claim_ids,
				guidance,
				external_semantic_validator
			)
			if bool(guided_attempt.get("ok", false)):
				actor.record_acceptance()
				var guided_turn: Dictionary = guided_attempt["turn"] as Dictionary
				actor_turn_selected.emit(actor_id, guided_turn.duplicate(true), "actor_turn_with_director_guidance")
				return {
					"ok": true,
					"turn": guided_turn.duplicate(true),
					"source": "actor_turn_with_director_guidance",
					"director_guidance": guidance.duplicate(true),
					"escalation_level": actor_retry_limit + 1,
				}
			_record_turn_rejection(actor, guided_attempt, max_history)
		else:
			_emit_request_failure("director", guidance_result)

	actor_turn_escalated.emit(actor_id, "deterministic_dialogue_fallback", "模型对话恢复链耗尽，使用作者可控且不伪造 claim 的确定性台词。")
	var fallback_turn: Dictionary = deterministic_fallback_turn.duplicate(true)
	if fallback_turn.is_empty():
		fallback_turn = _build_default_dialogue_fallback_turn()
	var fallback_shape: Dictionary = actor.validate_turn_output(fallback_turn, disclosable_claim_ids)
	if not bool(fallback_shape.get("ok", false)):
		return _error(
			"deterministic_dialogue_fallback_invalid",
			"作者定义的 deterministic dialogue fallback 无效：%s" % String(fallback_shape.get("message", "未知原因。"))
		)
	var fallback_semantics: Dictionary = _turn_semantic_guard.validate_turn_semantics(
		fallback_shape["turn"] as Dictionary,
		disclosable_claims,
		external_semantic_validator
	)
	if not bool(fallback_semantics.get("ok", false)):
		return {
			"ok": false,
			"error_code": "agent_dialogue_liveness_exhausted",
			"message": "Actor、Director guidance 与 deterministic dialogue fallback 均无法产生合法 ActorTurn：%s" % String(fallback_semantics.get("message", "未知原因。")),
		}
	actor.record_acceptance()
	var accepted_fallback: Dictionary = fallback_semantics["turn"] as Dictionary
	actor_turn_selected.emit(actor_id, accepted_fallback.duplicate(true), "deterministic_dialogue_fallback")
	return {
		"ok": true,
		"turn": accepted_fallback.duplicate(true),
		"source": "deterministic_dialogue_fallback",
		"director_guidance": guidance.duplicate(true),
		"escalation_level": actor_retry_limit + 2,
	}


func create_snapshot() -> Dictionary:
	_ensure_autonomous_components()
	var actor_snapshots: Dictionary = {}
	var actor_ids: Array = _actors.keys()
	actor_ids.sort()
	for raw_actor_id: Variant in actor_ids:
		var actor_id: String = String(raw_actor_id)
		actor_snapshots[actor_id] = (_actors[actor_id] as ActorAgent).create_snapshot()
	return {
		"agent_state_format_version": AGENT_STATE_FORMAT_VERSION,
		"director_plan_serial": _director_plan_serial,
		"director_plan_cache": _director_plan_cache.duplicate(true),
		"actors": actor_snapshots,
		"autonomous_state": {
			"director_trigger_policy": _director_trigger_policy.create_snapshot(),
			"actor_scheduler": _actor_scheduler.create_snapshot(),
		},
	}


func validate_snapshot(snapshot: Dictionary, _context: Dictionary = {}) -> Dictionary:
	_ensure_autonomous_components()
	if snapshot.size() != 5:
		return _error("agent_snapshot_invalid", "AgentRuntime 快照字段缺失或包含未知字段。")
	for required_key: String in ["agent_state_format_version", "director_plan_serial", "director_plan_cache", "actors", "autonomous_state"]:
		if not snapshot.has(required_key):
			return _error("agent_snapshot_invalid", "AgentRuntime 快照缺少字段：%s。" % required_key)
	var version_result: Dictionary = _read_exact_snapshot_integer(snapshot["agent_state_format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != AGENT_STATE_FORMAT_VERSION:
		return _error("agent_snapshot_version_invalid", "AgentRuntime 快照版本无效。")
	var serial_result: Dictionary = _read_exact_snapshot_integer(snapshot["director_plan_serial"])
	if not bool(serial_result.get("ok", false)) or int(serial_result["value"]) < 0:
		return _error("agent_snapshot_invalid", "AgentRuntime 快照 director_plan_serial 必须是非负整数。")
	if not snapshot["director_plan_cache"] is Dictionary:
		return _error("agent_snapshot_invalid", "AgentRuntime 快照 director_plan_cache 必须是对象。")
	var plan_cache_result: Dictionary = _validate_director_plan_cache_snapshot(snapshot["director_plan_cache"] as Dictionary, int(serial_result["value"]))
	if not bool(plan_cache_result.get("ok", false)):
		return plan_cache_result
	if not snapshot["actors"] is Dictionary:
		return _error("agent_snapshot_invalid", "AgentRuntime 快照 actors 必须是对象。")
	var actor_snapshots: Dictionary = snapshot["actors"] as Dictionary
	if not _actors.is_empty():
		var expected_actor_ids: Array = _actors.keys()
		var snapshot_actor_ids: Array = actor_snapshots.keys()
		expected_actor_ids.sort()
		snapshot_actor_ids.sort()
		if expected_actor_ids != snapshot_actor_ids:
			return _error("agent_snapshot_actor_set_mismatch", "AgentRuntime 存档的 Actor 集合与当前内容不一致。")
	var normalized_actor_ids: Array[String] = []
	for raw_actor_id: Variant in actor_snapshots.keys():
		if not raw_actor_id is String or not actor_snapshots[raw_actor_id] is Dictionary:
			return _error("agent_snapshot_invalid", "AgentRuntime 快照含无效 Actor 条目。")
		var actor_id: String = String(raw_actor_id)
		normalized_actor_ids.append(actor_id)
		var probe: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
		var actor_result: Dictionary = probe.restore_snapshot(actor_snapshots[raw_actor_id] as Dictionary)
		if not bool(actor_result.get("ok", false)):
			return actor_result
		if probe.actor_id != actor_id:
			return _error("agent_snapshot_actor_mismatch", "AgentRuntime 快照键与 actor_id 不一致：%s。" % actor_id)
		if _story_engine != null and _story_engine.has_method(&"get_actor_perceived_signal_ids"):
			var expected_signal_value: Variant = _story_engine.call(&"get_actor_perceived_signal_ids", actor_id)
			if not expected_signal_value is Array:
				return _error("agent_snapshot_signal_contract_invalid", "StoryEngine.get_actor_perceived_signal_ids() 必须返回 Array。")
			var expected_signal_ids: Array = (expected_signal_value as Array).duplicate()
			var actual_signal_value: Variant = probe.state.get("heard_signal_ids", [])
			if not actual_signal_value is Array:
				return _error("agent_snapshot_signal_state_invalid", "Actor 快照 heard_signal_ids 必须是数组。")
			var actual_signal_ids: Array = (actual_signal_value as Array).duplicate()
			expected_signal_ids.sort()
			actual_signal_ids.sort()
			if expected_signal_ids != actual_signal_ids:
				return _error("agent_snapshot_signal_mismatch", "Actor %s 的 heard_signal_ids 与已恢复 SignalSystem recipients 不一致。" % actor_id)
	normalized_actor_ids.sort()
	if not snapshot["autonomous_state"] is Dictionary:
		return _error("agent_snapshot_autonomous_invalid", "AgentRuntime autonomous_state 必须是对象。")
	var autonomous_state: Dictionary = snapshot["autonomous_state"] as Dictionary
	if autonomous_state.size() != 2 or not autonomous_state.get("director_trigger_policy") is Dictionary or not autonomous_state.get("actor_scheduler") is Dictionary:
		return _error("agent_snapshot_autonomous_invalid", "AgentRuntime autonomous_state 必须只包含 DirectorTriggerPolicy 与 ActorScheduler 快照。")
	var current_tick: int = _current_world_tick()
	if current_tick < 0:
		current_tick = 3600
	var trigger_validation: Dictionary = _director_trigger_policy.validate_snapshot(
		autonomous_state["director_trigger_policy"] as Dictionary,
		{"current_game_tick": current_tick}
	)
	if not bool(trigger_validation.get("ok", false)):
		return trigger_validation
	var scheduler_validation: Dictionary = _actor_scheduler.validate_snapshot(
		autonomous_state["actor_scheduler"] as Dictionary,
		{"current_game_tick": current_tick, "actor_ids": normalized_actor_ids}
	)
	if not bool(scheduler_validation.get("ok", false)):
		return scheduler_validation
	return {"ok": true}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var restored: Dictionary = {}
	for raw_actor_id: Variant in (snapshot["actors"] as Dictionary).keys():
		var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
		var restore_result: Dictionary = actor.restore_snapshot((snapshot["actors"] as Dictionary)[raw_actor_id] as Dictionary)
		if not bool(restore_result.get("ok", false)):
			return restore_result
		restored[String(raw_actor_id)] = actor
	var current_tick: int = _current_world_tick()
	if current_tick < 0:
		current_tick = 3600
	var actor_ids: Array = restored.keys()
	actor_ids.sort()
	var autonomous_state: Dictionary = snapshot["autonomous_state"] as Dictionary
	var trigger_restore: Dictionary = _director_trigger_policy.restore_snapshot(
		autonomous_state["director_trigger_policy"] as Dictionary,
		{"current_game_tick": current_tick}
	)
	if not bool(trigger_restore.get("ok", false)):
		return trigger_restore
	var scheduler_restore: Dictionary = _actor_scheduler.restore_snapshot(
		autonomous_state["actor_scheduler"] as Dictionary,
		{"current_game_tick": current_tick, "actor_ids": actor_ids}
	)
	if not bool(scheduler_restore.get("ok", false)):
		return scheduler_restore
	_actors = restored
	_director_plan_serial = int(_read_exact_snapshot_integer(snapshot["director_plan_serial"])["value"])
	_director_plan_cache = (snapshot["director_plan_cache"] as Dictionary).duplicate(true)
	return {"ok": true}


func _ensure_autonomous_components() -> void:
	if _opportunity_builder == null:
		_opportunity_builder = OPPORTUNITY_BUILDER_SCRIPT.new() as OpportunityBuilder
	if _director_trigger_policy == null:
		_director_trigger_policy = DIRECTOR_TRIGGER_POLICY_SCRIPT.new() as DirectorTriggerPolicy
	if _actor_scheduler == null:
		_actor_scheduler = ACTOR_SCHEDULER_SCRIPT.new() as ActorScheduler


func _request_actor_once(
	actor: ActorAgent,
	decision_context: Dictionary,
	available_actions: Array,
	disclosable_claim_ids: Array,
	director_guidance: Dictionary,
	external_validator: Callable
) -> Dictionary:
	var response: Dictionary = await _gateway.request_json(
		_config["actor"] as Dictionary,
		ActorAgent.SYSTEM_PROMPT,
		actor.build_request_payload(decision_context, available_actions, disclosable_claim_ids, director_guidance)
	)
	if not bool(response.get("ok", false)):
		_emit_request_failure("actor", response)
		return response
	var output_result: Dictionary = actor.validate_model_output(response["data"] as Dictionary, disclosable_claim_ids)
	if not bool(output_result.get("ok", false)):
		return output_result
	return _action_validator.validate_proposal(
		output_result["proposal"] as Dictionary,
		available_actions,
		external_validator
	)


func _request_actor_turn_once(
	actor: ActorAgent,
	interaction_context: Dictionary,
	disclosable_claims: Array,
	disclosable_claim_ids: Array,
	director_guidance: Dictionary,
	external_semantic_validator: Callable
) -> Dictionary:
	var response: Dictionary = await _gateway.request_json(
		_config["actor"] as Dictionary,
		ActorAgent.TURN_SYSTEM_PROMPT,
		actor.build_turn_request_payload(interaction_context, disclosable_claims, director_guidance)
	)
	if not bool(response.get("ok", false)):
		_emit_request_failure("actor", response)
		return response
	var output_result: Dictionary = actor.validate_turn_output(response["data"] as Dictionary, disclosable_claim_ids)
	if not bool(output_result.get("ok", false)):
		return output_result
	return _turn_semantic_guard.validate_turn_semantics(
		output_result["turn"] as Dictionary,
		disclosable_claims,
		external_semantic_validator
	)


func _request_director_guidance(
	actor: ActorAgent,
	decision_context: Dictionary,
	available_actions: Array,
	world_constraints: Dictionary
) -> Dictionary:
	var actor_snapshot: Dictionary = actor.create_snapshot()
	var response: Dictionary = await _gateway.request_json(
		_config["director"] as Dictionary,
		DirectorAgent.GUIDANCE_SYSTEM_PROMPT,
		_director.build_guidance_payload(
			actor_snapshot,
			decision_context,
			available_actions,
			actor.rejection_history,
			world_constraints
		)
	)
	if not bool(response.get("ok", false)):
		return response
	return _director.validate_guidance(response["data"] as Dictionary, available_actions)


func _request_director_turn_guidance(
	actor: ActorAgent,
	interaction_context: Dictionary,
	disclosable_claims: Array,
	disclosable_claim_ids: Array,
	world_constraints: Dictionary
) -> Dictionary:
	var response: Dictionary = await _gateway.request_json(
		_config["director"] as Dictionary,
		DirectorAgent.TURN_GUIDANCE_SYSTEM_PROMPT,
		_director.build_turn_guidance_payload(
			actor.create_snapshot(),
			interaction_context,
			disclosable_claims,
			actor.rejection_history,
			world_constraints
		)
	)
	if not bool(response.get("ok", false)):
		return response
	return _director.validate_turn_guidance(response["data"] as Dictionary, disclosable_claim_ids)


func _request_director_force_action(
	actor: ActorAgent,
	decision_context: Dictionary,
	available_actions: Array,
	world_constraints: Dictionary,
	external_validator: Callable
) -> Dictionary:
	var response: Dictionary = await _gateway.request_json(
		_config["director"] as Dictionary,
		DirectorAgent.FORCE_SYSTEM_PROMPT,
		_director.build_force_payload(
			actor.create_snapshot(),
			decision_context,
			available_actions,
			actor.rejection_history,
			world_constraints
		)
	)
	if not bool(response.get("ok", false)):
		return response
	var force_shape: Dictionary = _director.validate_force_output(response["data"] as Dictionary)
	if not bool(force_shape.get("ok", false)):
		return force_shape
	return _action_validator.validate_proposal(
		force_shape["proposal"] as Dictionary,
		available_actions,
		external_validator
	)


func _validate_director_plan_cache_snapshot(plan_cache: Dictionary, expected_serial: int) -> Dictionary:
	if plan_cache.is_empty():
		return {"ok": true}
	for required_key: String in ["serial", "context_id", "plan"]:
		if not plan_cache.has(required_key):
			return _error("agent_snapshot_invalid", "Director plan cache 缺少字段：%s。" % required_key)
	var serial_result: Dictionary = _read_exact_snapshot_integer(plan_cache["serial"])
	if not bool(serial_result.get("ok", false)) or int(serial_result["value"]) <= 0 or int(serial_result["value"]) != expected_serial:
		return _error("agent_snapshot_invalid", "Director plan cache.serial 必须等于 director_plan_serial 且大于 0。")
	if not plan_cache["context_id"] is String or String(plan_cache["context_id"]).strip_edges().is_empty():
		return _error("agent_snapshot_invalid", "Director plan cache.context_id 必须是非空字符串。")
	if not plan_cache["plan"] is Dictionary:
		return _error("agent_snapshot_invalid", "Director plan cache.plan 必须是对象。")
	var plan: Dictionary = plan_cache["plan"] as Dictionary
	for required_key: String in ["selected_opportunity_ids", "actor_goal_ids", "pacing_note"]:
		if not plan.has(required_key):
			return _error("agent_snapshot_invalid", "Director plan 快照缺少字段：%s。" % required_key)
	if not plan["selected_opportunity_ids"] is Array or not plan["actor_goal_ids"] is Dictionary or not plan["pacing_note"] is String:
		return _error("agent_snapshot_invalid", "Director plan 快照字段类型无效。")
	var seen_opportunities: Dictionary = {}
	for raw_opportunity_id: Variant in plan["selected_opportunity_ids"] as Array:
		if not raw_opportunity_id is String or String(raw_opportunity_id).strip_edges().is_empty():
			return _error("agent_snapshot_invalid", "Director plan 快照含无效 opportunity id。")
		var opportunity_id: String = String(raw_opportunity_id)
		if seen_opportunities.has(opportunity_id):
			return _error("agent_snapshot_invalid", "Director plan 快照含重复 opportunity id：%s。" % opportunity_id)
		seen_opportunities[opportunity_id] = true
	for raw_actor_id: Variant in (plan["actor_goal_ids"] as Dictionary).keys():
		if not raw_actor_id is String or String(raw_actor_id).strip_edges().is_empty():
			return _error("agent_snapshot_invalid", "Director plan 快照含无效 actor id。")
		var raw_goal_id: Variant = (plan["actor_goal_ids"] as Dictionary)[raw_actor_id]
		if not raw_goal_id is String or String(raw_goal_id).strip_edges().is_empty():
			return _error("agent_snapshot_invalid", "Director plan 快照含无效 goal id。")
	return {"ok": true}


func _build_director_actor_summaries() -> Dictionary:
	var actor_ids: Array = _actors.keys()
	actor_ids.sort()
	var actor_summaries: Array = []
	for raw_actor_id: Variant in actor_ids:
		var actor_id: String = String(raw_actor_id)
		var actor: ActorAgent = _actors[actor_id] as ActorAgent
		if actor == null:
			return _error("actor_runtime_corrupt", "Actor 注册表损坏：%s。" % actor_id)
		var snapshot: Dictionary = actor.create_snapshot()
		var actor_state: Dictionary = snapshot["state"] as Dictionary
		var raw_goal_ids: Variant = actor_state.get("available_goal_ids", [])
		if not raw_goal_ids is Array:
			return _error("actor_goal_catalog_invalid", "Actor %s 的 state.available_goal_ids 必须是数组。" % actor_id)
		actor_summaries.append({
			"actor_id": actor_id,
			"profile": (snapshot["profile"] as Dictionary).duplicate(true),
			"state": actor_state.duplicate(true),
			"available_goal_ids": (raw_goal_ids as Array).duplicate(true),
		})
	return {"ok": true, "actor_summaries": actor_summaries}


func _get_cached_actor_plan_guidance(actor_id: String) -> Dictionary:
	if _director_plan_cache.is_empty():
		return {}
	var plan: Variant = _director_plan_cache.get("plan", {})
	if not plan is Dictionary:
		return {}
	var actor_goal_ids: Variant = (plan as Dictionary).get("actor_goal_ids", {})
	if not actor_goal_ids is Dictionary or not (actor_goal_ids as Dictionary).has(actor_id):
		return {}
	if not _actors.has(actor_id) or not _actors[actor_id] is ActorAgent:
		return {}
	var goal_id: String = String((actor_goal_ids as Dictionary)[actor_id])
	var current_actor: ActorAgent = _actors[actor_id] as ActorAgent
	var available_goal_ids: Variant = current_actor.state.get("available_goal_ids", [])
	if not available_goal_ids is Array or not (available_goal_ids as Array).has(goal_id):
		# Actor 状态已变化时，旧 plan 不能继续把已失效 goal 注入新的局部决策。
		return {}
	return {
		"plan_serial": _director_plan_serial,
		"plan_context_id": String(_director_plan_cache.get("context_id", "")),
		"plan_goal_id": goal_id,
	}


func _merge_director_guidance(base_guidance: Dictionary, recovery_guidance: Dictionary) -> Dictionary:
	var merged: Dictionary = base_guidance.duplicate(true)
	for raw_key: Variant in recovery_guidance.keys():
		merged[raw_key] = recovery_guidance[raw_key]
	return merged


func _apply_director_action_policy(available_actions: Array, guidance: Dictionary) -> Array:
	var avoid_action_ids: Array = guidance.get("avoid_action_ids", []) as Array
	if avoid_action_ids.is_empty():
		return available_actions.duplicate(true)
	var filtered: Array = []
	for raw_action: Variant in available_actions:
		if not raw_action is Dictionary:
			continue
		var action: Dictionary = raw_action as Dictionary
		if avoid_action_ids.has(String(action.get("id", ""))):
			continue
		filtered.append(action.duplicate(true))
	# Director 的 policy 不能把 Actor 动作空间裁成空集；否则保留原动作集合并继续进入后续恢复链。
	if filtered.is_empty():
		return available_actions.duplicate(true)
	return filtered


func _validate_decision_readiness(actor_id: String, available_actions: Array, disclosable_claim_ids: Array) -> Dictionary:
	if not is_enabled():
		return _error("agent_runtime_disabled", "AgentRuntime 未启用或配置未成功加载。")
	if _story_engine == null or _phone_system == null or _game_clock == null:
		return _error("world_not_bound", "AgentRuntime 尚未绑定当前夜班 World Kernel。")
	if _gateway == null or _director == null or _action_validator == null:
		return _error("agent_runtime_incomplete", "AgentRuntime 内部组件未初始化完成。")
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	var actions_result: Dictionary = _action_validator.validate_available_actions(available_actions)
	if not bool(actions_result.get("ok", false)):
		return actions_result
	var seen_claims: Dictionary = {}
	for raw_claim_id: Variant in disclosable_claim_ids:
		if not raw_claim_id is String or String(raw_claim_id).strip_edges().is_empty():
			return _error("disclosable_claim_invalid", "disclosable_claim_ids 只能包含非空字符串。")
		var claim_id: String = String(raw_claim_id)
		if seen_claims.has(claim_id):
			return _error("disclosable_claim_duplicate", "disclosable_claim_ids 存在重复 ID：%s。" % claim_id)
		seen_claims[claim_id] = true
	return {"ok": true, "actor": actor_result["actor"]}


func _validate_turn_readiness(actor_id: String, disclosable_claims: Array) -> Dictionary:
	if not is_enabled():
		return _error("agent_runtime_disabled", "AgentRuntime 未启用或配置未成功加载。")
	if _story_engine == null or _phone_system == null or _game_clock == null:
		return _error("world_not_bound", "AgentRuntime 尚未绑定当前夜班 World Kernel。")
	if _gateway == null or _director == null or _turn_semantic_guard == null:
		return _error("agent_runtime_incomplete", "AgentRuntime 的 ActorTurn 组件未初始化完成。")
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		return actor_result
	var claim_ids_result: Dictionary = _turn_semantic_guard.collect_claim_ids(disclosable_claims)
	if not bool(claim_ids_result.get("ok", false)):
		return claim_ids_result
	return {
		"ok": true,
		"actor": actor_result["actor"],
		"claim_ids": claim_ids_result["claim_ids"],
	}


func _connect_autonomous_world_signals() -> Dictionary:
	if _story_engine == null:
		return _error("world_not_bound", "Autonomous loop 需要已绑定 StoryEngine。")
	var signal_bindings: Array = [
		["world_signal_committed", "_on_autonomous_world_signal_committed"],
		["interaction_state_changed", "_on_autonomous_interaction_state_changed"],
		["statement_revealed", "_on_autonomous_statement_revealed"],
		["fact_confirmed", "_on_autonomous_fact_confirmed"],
		["story_time_advanced", "_on_autonomous_story_time_advanced"],
	]
	for binding: Array in signal_bindings:
		var signal_name: StringName = StringName(String(binding[0]))
		var callback: Callable = Callable(self, String(binding[1]))
		if not _story_engine.has_signal(signal_name):
			return _error("autonomous_world_signal_missing", "StoryEngine 缺少 autonomous loop 所需信号：%s。" % String(signal_name))
		if not _story_engine.is_connected(signal_name, callback):
			var connect_result: Error = _story_engine.connect(signal_name, callback)
			if connect_result != OK:
				return _error("autonomous_world_signal_connect_failed", "无法连接 StoryEngine.%s。" % String(signal_name))
	if _phone_system != null and _phone_system.has_signal(&"call_became_idle"):
		var phone_callback: Callable = Callable(self, "_on_autonomous_phone_became_idle")
		if not _phone_system.is_connected(&"call_became_idle", phone_callback):
			var phone_connect_result: Error = _phone_system.connect(&"call_became_idle", phone_callback)
			if phone_connect_result != OK:
				return _error("autonomous_phone_signal_connect_failed", "无法连接 PhoneSystem.call_became_idle。")
	return {"ok": true}


func _disconnect_autonomous_world_signals() -> void:
	if _story_engine != null:
		var signal_bindings: Array = [
			["world_signal_committed", "_on_autonomous_world_signal_committed"],
			["interaction_state_changed", "_on_autonomous_interaction_state_changed"],
			["statement_revealed", "_on_autonomous_statement_revealed"],
			["fact_confirmed", "_on_autonomous_fact_confirmed"],
			["story_time_advanced", "_on_autonomous_story_time_advanced"],
		]
		for binding: Array in signal_bindings:
			var signal_name: StringName = StringName(String(binding[0]))
			var callback: Callable = Callable(self, String(binding[1]))
			if _story_engine.has_signal(signal_name) and _story_engine.is_connected(signal_name, callback):
				_story_engine.disconnect(signal_name, callback)
	if _phone_system != null and _phone_system.has_signal(&"call_became_idle"):
		var phone_callback: Callable = Callable(self, "_on_autonomous_phone_became_idle")
		if _phone_system.is_connected(&"call_became_idle", phone_callback):
			_phone_system.disconnect(&"call_became_idle", phone_callback)


func _on_autonomous_world_signal_committed(record: Dictionary) -> void:
	var signal_type: String = String(record.get("signal_type", ""))
	match signal_type:
		"player_broadcast":
			_enqueue_autonomous_trigger("signal_committed", String(record.get("source_id", "")))
		"delivery_outcome":
			var payload: Dictionary = record.get("payload", {}) as Dictionary
			var status: String = String(payload.get("status", ""))
			if status != "committed" and status != "rejected":
				return
			var recipients: Array = record.get("committed_recipients", []) as Array
			if recipients.size() != 1 or not recipients[0] is String:
				return
			_enqueue_autonomous_trigger(
				"delivery_%s" % status,
				String(record.get("source_id", "")),
				String(recipients[0]),
				String(payload.get("source_opportunity_id", ""))
			)


func _on_autonomous_interaction_state_changed(event_id: String) -> void:
	if _story_engine == null or not _story_engine.has_method(&"get_interaction_state"):
		return
	var state_value: Variant = _story_engine.call(&"get_interaction_state", event_id)
	if state_value is Dictionary and bool((state_value as Dictionary).get("completed", false)):
		_enqueue_autonomous_trigger("interaction_completed", event_id)


func _on_autonomous_statement_revealed(statement: Dictionary) -> void:
	_enqueue_autonomous_trigger("statement_revealed", String(statement.get("id", "")))


func _on_autonomous_fact_confirmed(fact: Dictionary) -> void:
	_enqueue_autonomous_trigger("fact_confirmed", String(fact.get("id", "")))


func _on_autonomous_story_time_advanced(_previous_tick: int, _current_tick: int, _current_minute: int) -> void:
	if _director_trigger_policy != null and _director_trigger_policy.get_pending_count() > 0:
		_queue_autonomous_processing()


func _on_autonomous_phone_became_idle(_event_id: String) -> void:
	if _director_trigger_policy != null and _director_trigger_policy.get_pending_count() > 0:
		_queue_autonomous_processing()


func _enqueue_autonomous_trigger(
	kind: String,
	source_id: String,
	actor_id: String = "",
	related_opportunity_id: String = ""
) -> void:
	if source_id.strip_edges().is_empty() or _director_trigger_policy == null or _opportunity_builder == null or not _opportunity_builder.is_configured():
		return
	var current_tick: int = _current_world_tick()
	if current_tick < 0 or current_tick >= 3600:
		return
	var result: Dictionary = _director_trigger_policy.enqueue_trigger(
		kind,
		source_id,
		current_tick,
		actor_id,
		related_opportunity_id
	)
	if not bool(result.get("ok", false)):
		_emit_autonomous_error(result)
		return
	if not bool(result.get("duplicate", false)):
		_queue_autonomous_processing()


func _queue_autonomous_processing() -> void:
	if _autonomous_cycle_queued or _autonomous_cycle_running or not is_enabled():
		return
	if _story_engine == null or _phone_system == null or _game_clock == null:
		return
	if _opportunity_builder == null or not _opportunity_builder.is_configured():
		return
	_autonomous_cycle_queued = true
	call_deferred("_process_autonomous_triggers")


func _process_autonomous_triggers() -> void:
	_autonomous_cycle_queued = false
	if _autonomous_cycle_running or not is_enabled():
		return
	if _story_engine == null or _phone_system == null or _game_clock == null:
		return
	if _director_trigger_policy == null or _opportunity_builder == null or _actor_scheduler == null:
		return
	var forced_value: Variant = _phone_system.call(&"is_forced_ended") if _phone_system.has_method(&"is_forced_ended") else false
	if typeof(forced_value) == TYPE_BOOL and bool(forced_value):
		return
	var busy_value: Variant = _phone_system.call(&"is_busy") if _phone_system.has_method(&"is_busy") else false
	if typeof(busy_value) == TYPE_BOOL and bool(busy_value):
		return
	var current_tick: int = _current_world_tick()
	if current_tick < 0 or current_tick >= 3600:
		return
	var ready_result: Dictionary = _director_trigger_policy.take_ready_trigger(current_tick)
	if not bool(ready_result.get("ok", false)):
		_emit_autonomous_error(ready_result)
		return
	if not bool(ready_result.get("ready", false)):
		return
	var trigger: Dictionary = ready_result["trigger"] as Dictionary
	var candidate_result: Dictionary = _opportunity_builder.build_candidates(trigger, _story_engine)
	if not bool(candidate_result.get("ok", false)):
		_emit_autonomous_error(candidate_result)
		_queue_autonomous_processing()
		return
	var candidates: Array = candidate_result["candidates"] as Array
	if candidates.is_empty():
		if _director_trigger_policy.get_pending_count() > 0:
			_queue_autonomous_processing()
		return

	_autonomous_cycle_running = true
	var world_serial: int = _autonomous_world_serial
	var plan_result: Dictionary = await request_director_plan(
		String(ready_result["plan_context_id"]),
		{},
		candidates,
		{"trigger": trigger.duplicate(true)}
	)
	if world_serial != _autonomous_world_serial or _story_engine == null:
		_autonomous_cycle_running = false
		return
	current_tick = _current_world_tick()
	if current_tick >= 0:
		var mark_result: Dictionary = _director_trigger_policy.mark_attempt_completed(current_tick)
		if not bool(mark_result.get("ok", false)):
			_emit_autonomous_error(mark_result)
	if bool(plan_result.get("ok", false)):
		var actor_snapshots: Dictionary = {}
		for raw_actor_id: Variant in _actors.keys():
			var actor_id: String = String(raw_actor_id)
			actor_snapshots[actor_id] = (_actors[actor_id] as ActorAgent).create_snapshot()
		var delivery_state_value: Variant = _story_engine.call(&"get_delivery_state") if _story_engine.has_method(&"get_delivery_state") else {}
		var delivery_state: Dictionary = delivery_state_value as Dictionary if delivery_state_value is Dictionary else {}
		var schedule_result: Dictionary = _actor_scheduler.build_decisions(
			plan_result["plan_snapshot"] as Dictionary,
			candidates,
			actor_snapshots,
			maxi(current_tick, 0),
			delivery_state
		)
		if not bool(schedule_result.get("ok", false)):
			_emit_autonomous_error(schedule_result)
		else:
			for raw_decision: Variant in schedule_result["decisions"] as Array:
				if raw_decision is Dictionary:
					await _execute_autonomous_actor_decision(raw_decision as Dictionary, world_serial)
					if world_serial != _autonomous_world_serial:
						break
	_autonomous_cycle_running = false
	if _director_trigger_policy.get_pending_count() > 0:
		_queue_autonomous_processing()


func _execute_autonomous_actor_decision(decision: Dictionary, world_serial: int) -> void:
	if world_serial != _autonomous_world_serial or _story_engine == null:
		return
	var actor_id: String = String(decision.get("actor_id", ""))
	var opportunity_id: String = String(decision.get("opportunity_id", ""))
	var goal_id: String = String(decision.get("goal_id", ""))
	var director_plan_id: String = String(decision.get("director_plan_id", ""))
	var actor_result: Dictionary = _get_actor(actor_id)
	if not bool(actor_result.get("ok", false)):
		_emit_autonomous_error(actor_result)
		return
	var pending_result: Dictionary = _actor_scheduler.mark_pending(actor_id)
	if not bool(pending_result.get("ok", false)):
		return
	var actor: ActorAgent = actor_result["actor"] as ActorAgent
	var goal_patch_result: Dictionary = actor.apply_state_patch({"current_goal": goal_id})
	if not bool(goal_patch_result.get("ok", false)):
		_actor_scheduler.clear_pending(actor_id)
		_emit_autonomous_error(goal_patch_result)
		return
	runtime_status_changed.emit(get_runtime_status())

	var opportunity: Dictionary = decision.get("opportunity", {}) as Dictionary
	var decision_context: Dictionary = {
		"decision_id": String(decision.get("decision_id", "")),
		"source_opportunity_id": opportunity_id,
		"opportunity_summary": String(opportunity.get("summary", "")),
		"goal_id": goal_id,
		"trigger": (opportunity.get("trigger", {}) as Dictionary).duplicate(true),
		"current_game_tick": _current_world_tick(),
	}
	var available_actions: Array = _build_autonomous_available_actions()
	var disclosable_claim_ids: Array = _opportunity_builder.get_actor_disclosable_claim_ids(actor_id, opportunity_id)
	var world_constraints: Dictionary = {
		"source_opportunity_id": opportunity_id,
		"source_director_plan_id": director_plan_id,
		"ending_tick": 3600,
		"delivery_actions": ["call_station", "send_message"],
	}
	var validator: Callable = Callable(self, "_validate_autonomous_action").bind(actor_id, opportunity_id, director_plan_id)
	var action_result: Dictionary = await request_actor_action(
		actor_id,
		decision_context,
		available_actions,
		disclosable_claim_ids,
		world_constraints,
		validator
	)
	if world_serial != _autonomous_world_serial or _story_engine == null:
		_actor_scheduler.clear_pending(actor_id)
		return
	var current_tick: int = maxi(_current_world_tick(), 0)
	if not bool(action_result.get("ok", false)):
		_actor_scheduler.mark_completed(actor_id, current_tick)
		_emit_autonomous_error(action_result)
		return
	var proposal: Dictionary = action_result["proposal"] as Dictionary
	var action_id: String = String(proposal.get("action_id", ""))
	if action_id == "wait":
		_actor_scheduler.mark_completed(actor_id, current_tick)
		return
	var submit_value: Variant = _story_engine.call(
		&"submit_delivery_request",
		actor_id,
		action_id,
		(proposal.get("arguments", {}) as Dictionary).duplicate(true),
		opportunity_id,
		director_plan_id
	)
	_actor_scheduler.mark_completed(actor_id, current_tick)
	if not submit_value is Dictionary or not bool((submit_value as Dictionary).get("ok", false)):
		var submit_error: Dictionary = submit_value as Dictionary if submit_value is Dictionary else _error("delivery_submit_contract_invalid", "StoryEngine.submit_delivery_request() 必须返回 Dictionary。")
		_emit_autonomous_error(submit_error)


func _build_autonomous_available_actions() -> Array:
	return [
		{
			"id": "call_station",
			"description": "在当前目标需要与 WMLH 直接沟通时，向电台发起一通受 PhoneSystem 管理的电话。",
			"argument_keys": ["topic"],
			"fallback_priority": 10,
			"fallback_arguments": {},
		},
		{
			"id": "send_message",
			"description": "向 WMLH 电脑终端发送一条来自当前 Actor 的短消息。",
			"argument_keys": ["body"],
			"fallback_priority": 20,
		},
		{
			"id": "wait",
			"description": "当前不产生世界动作，保持目标并等待新的 committed information。",
			"argument_keys": [],
			"fallback_priority": 100,
			"fallback_arguments": {},
		},
	]


func _validate_autonomous_action(
	proposal: Dictionary,
	_action_definition: Dictionary,
	actor_id: String,
	opportunity_id: String,
	director_plan_id: String
) -> Dictionary:
	var action_id: String = String(proposal.get("action_id", ""))
	var arguments: Dictionary = proposal.get("arguments", {}) as Dictionary
	if action_id == "wait":
		if not arguments.is_empty():
			return _error("wait_arguments_invalid", "wait 动作不接受参数。")
		return {"ok": true}
	if action_id != "call_station" and action_id != "send_message":
		return _error("autonomous_action_unsupported", "Autonomous loop 只支持 call_station/send_message/wait。")
	if _story_engine == null or not _story_engine.has_method(&"validate_delivery_request"):
		return _error("delivery_validator_unavailable", "StoryEngine 缺少 validate_delivery_request() 世界校验入口。")
	var validation_value: Variant = _story_engine.call(
		&"validate_delivery_request",
		actor_id,
		action_id,
		arguments.duplicate(true),
		opportunity_id,
		director_plan_id
	)
	if not validation_value is Dictionary:
		return _error("delivery_validator_contract_invalid", "StoryEngine.validate_delivery_request() 必须返回 Dictionary。")
	return validation_value as Dictionary


func _current_world_tick() -> int:
	if _story_engine != null and _story_engine.has_method(&"get_current_game_tick"):
		var story_tick_value: Variant = _story_engine.call(&"get_current_game_tick")
		if typeof(story_tick_value) == TYPE_INT:
			return int(story_tick_value)
	if _game_clock != null and _game_clock.has_method(&"get_current_game_tick"):
		var clock_tick_value: Variant = _game_clock.call(&"get_current_game_tick")
		if typeof(clock_tick_value) == TYPE_INT:
			return int(clock_tick_value)
	return -1


func _emit_autonomous_error(result: Dictionary) -> void:
	var error_code: String = String(result.get("error_code", "autonomous_loop_failed"))
	var message: String = String(result.get("message", "Autonomous Actor Loop 处理失败。"))
	agent_request_failed.emit("autonomous", error_code, message)
	push_error("[AgentRuntime][autonomous][%s] %s" % [error_code, message])


func _on_actor_signal_perceived(actor_id: String, signal_id: String) -> void:
	var result: Dictionary = record_actor_signal_perception(actor_id, signal_id)
	if not bool(result.get("ok", false)):
		var error_code: String = String(result.get("error_code", "actor_signal_perception_failed"))
		var message: String = String(result.get("message", "Actor signal perception 提交失败。"))
		agent_request_failed.emit("actor_perception", error_code, message)
		push_error("[AgentRuntime][%s] %s" % [error_code, message])


func _get_actor(actor_id: String) -> Dictionary:
	if actor_id.strip_edges().is_empty():
		return _error("actor_id_invalid", "Actor ID 不能为空。")
	if not _actors.has(actor_id):
		return _error("actor_not_registered", "Actor 未注册：%s。" % actor_id)
	var actor: Variant = _actors[actor_id]
	if not actor is ActorAgent:
		return _error("actor_runtime_corrupt", "Actor 注册表损坏：%s。" % actor_id)
	return {"ok": true, "actor": actor as ActorAgent}


func _record_rejection(actor: ActorAgent, result: Dictionary, max_history: int) -> void:
	var proposal: Dictionary = result.get("proposal", {}) as Dictionary
	actor.record_rejection(
		String(proposal.get("action_id", "")),
		String(result.get("error_code", "actor_attempt_failed")),
		String(result.get("message", "Actor 决策失败。")),
		max_history
	)


func _record_turn_rejection(actor: ActorAgent, result: Dictionary, max_history: int) -> void:
	actor.record_rejection(
		"dialogue_turn",
		String(result.get("error_code", "actor_turn_failed")),
		String(result.get("message", "ActorTurn 失败。")),
		max_history
	)


func _build_default_dialogue_fallback_turn() -> Dictionary:
	return {
		"speech_act": "end_call",
		"utterance": "线路里只剩下一阵杂音，对方很快挂断了。",
		"asserted_claim_ids": [],
		"withheld_claim_ids": [],
		"session_intent": "end",
		"world_action": null,
	}


func _emit_request_failure(role: String, result: Dictionary) -> void:
	var error_code: String = String(result.get("error_code", "model_request_failed"))
	var message: String = String(result.get("message", "模型请求失败。"))
	agent_request_failed.emit(role, error_code, message)
	push_error("[AgentRuntime][%s][%s] %s" % [role, error_code, message])


func _read_exact_snapshot_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) == TYPE_FLOAT:
		var numeric_value: float = float(value)
		if not is_nan(numeric_value) and not is_inf(numeric_value) and numeric_value == floor(numeric_value):
			return {"ok": true, "value": int(numeric_value)}
	return {"ok": false}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
