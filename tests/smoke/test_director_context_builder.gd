extends SceneTree

const WORLD_BOOK_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/worldbook_validator.gd")
const WORLD_BOOK_COMPILER_SCRIPT: GDScript = preload("res://scripts/core/worldbook_compiler.gd")
const DIRECTOR_CONTEXT_BUILDER_SCRIPT: GDScript = preload("res://scripts/agents/director_context_builder.gd")
const DIRECTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/director_agent.gd")
const ACTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/actor_agent.gd")
const DEFAULT_MANIFEST_PATH: String = "res://worldbooks/default/manifest.json"

var _has_failed: bool = false


class FakeStoryEngine:
	extends RefCounted

	func get_confirmed_facts() -> Array:
		return [{"id": "fact_bridge_closed", "confirmed": true}]

	func get_revealed_statements() -> Array:
		return [{"id": "statement_miller_bridge_closure", "revealed": true}]

	func get_player_broadcast_records() -> Array:
		return [{"task_id": "task_broadcast_bridge_closure", "sent": true}]

	func get_unlocked_messages() -> Array:
		return [{"id": "message_01_miller", "read": true}]

	func get_broadcast_tasks() -> Array:
		return [{"id": "task_broadcast_bridge_closure", "status": "available"}]

	func get_signal_state() -> Dictionary:
		return {
			"available": true,
			"records": [{
				"signal_id": "signal_player_broadcast_task_broadcast_bridge_closure",
				"signal_type": "player_broadcast",
				"source_id": "task_broadcast_bridge_closure",
				"created_at_tick": 70,
				"payload": {"information_item_ids": ["info_bridge_official_closure"]},
				"audience_rule": "all_registered_actors",
				"committed_recipients": ["ronnie"],
			}],
		}


class FakeClock:
	extends RefCounted

	func get_display_time() -> String:
		return "01:17"

	func get_current_game_tick() -> int:
		return 77


class FakePhoneSystem:
	extends RefCounted

	func get_call_records() -> Array:
		return [{"event_id": "call_03_martha", "state": "completed"}]

	func get_state_name() -> String:
		return "IDLE"

	func is_busy() -> bool:
		return false

	func get_active_event_id() -> String:
		return ""


func _init() -> void:
	var validator: WorldBookValidator = WORLD_BOOK_VALIDATOR_SCRIPT.new() as WorldBookValidator
	var validation: Dictionary = validator.load_and_validate(DEFAULT_MANIFEST_PATH)
	_assert_ok(validation, "default WorldBook 必须可用于 DirectorContext 测试。")
	if not bool(validation.get("ok", false)):
		_finish()
		return
	var compiler: WorldBookCompiler = WORLD_BOOK_COMPILER_SCRIPT.new() as WorldBookCompiler
	var compile_result: Dictionary = compiler.compile(validation)
	_assert_ok(compile_result, "default WorldBook 必须能编译 Director lore。")
	if not bool(compile_result.get("ok", false)):
		_finish()
		return
	var compiled: Dictionary = compile_result["compiled"] as Dictionary
	var actor_summaries: Array[Dictionary] = _build_actor_summaries(compiled["actors"] as Array)
	var builder: DirectorContextBuilder = DIRECTOR_CONTEXT_BUILDER_SCRIPT.new() as DirectorContextBuilder
	var build_result: Dictionary = builder.build_context(
		"after_martha_call",
		compiled["director_lore"] as Dictionary,
		FakeStoryEngine.new(),
		FakeClock.new(),
		FakePhoneSystem.new(),
		actor_summaries,
		compiled["opportunities"] as Array,
		{"trigger": "important_interaction_completed"}
	)
	_assert_ok(build_result, "DirectorContextBuilder 必须生成六层正式上下文。")
	if bool(build_result.get("ok", false)):
		_test_six_layers(build_result["context"] as Dictionary)
		_test_director_payload(build_result["context"] as Dictionary)
		_test_actor_does_not_receive_director_lore(compiled)
	_finish()


func _test_six_layers(context: Dictionary) -> void:
	for key: String in ["kernel_rules", "worldbook_lore", "runtime_world_summary", "actor_summaries", "candidate_opportunities", "narrative_constraints"]:
		_assert_true(context.has(key), "DirectorContext 必须包含层：%s。" % key)
	var worldbook_lore: Dictionary = context["worldbook_lore"] as Dictionary
	_assert_true(not (worldbook_lore["hidden_truths"] as Array).is_empty(), "Director 必须获得 hidden Truth。")
	var runtime_summary: Dictionary = context["runtime_world_summary"] as Dictionary
	_assert_equal(String(runtime_summary["current_time"]), "01:17", "Runtime summary 必须来自 GameClock。")
	_assert_equal(int(runtime_summary["game_tick"]), 77, "Runtime summary 必须携带真实 game tick。")
	_assert_equal((runtime_summary["confirmed_facts"] as Array).size(), 1, "Director 必须获得确定性 confirmed facts。")
	_assert_equal((runtime_summary["revealed_statements"] as Array).size(), 1, "Director 必须获得确定性 revealed statements。")
	_assert_equal((runtime_summary["call_history"] as Array).size(), 1, "Director 必须获得电话历史。")
	_assert_true(bool((runtime_summary["signal_state"] as Dictionary)["available"]), "SignalSystem 落地后 DirectorContext 必须读取真实 available 状态。")
	_assert_equal(((runtime_summary["signal_state"] as Dictionary)["records"] as Array).size(), 1, "DirectorContext 必须获得已提交 SignalRecord。")
	_assert_true(not bool((runtime_summary["delivery_state"] as Dictionary)["available"]), "DeliverySystem 未落地时必须明确 unavailable。")
	_assert_equal((context["actor_summaries"] as Array).size(), 10, "Director 必须获得 10 个编译后 Actor summaries。")
	_assert_true(not (context["candidate_opportunities"] as Array).is_empty(), "Director 必须只从已编译 candidate opportunities 中选择。")


func _test_director_payload(context: Dictionary) -> void:
	var director: DirectorAgent = DIRECTOR_AGENT_SCRIPT.new() as DirectorAgent
	var payload: Dictionary = director.build_plan_payload_from_context(context)
	_assert_true(not payload.is_empty(), "DirectorAgent 必须接受 DirectorContextBuilder 的正式 payload。")
	_assert_true(payload.has("kernel_rules") and payload.has("worldbook_lore") and payload.has("runtime_world_summary"), "正式 Director payload 必须保留 Kernel/Lore/Runtime 分层。")
	_assert_true(not payload.has("world_summary"), "正式 WorldBook Director payload 不应再依赖调用方手工 world_summary。")
	var prompt: String = DirectorAgent.PLAN_SYSTEM_PROMPT
	_assert_true(prompt.contains("worldbook_lore") and prompt.contains("kernel_rules"), "Director system prompt 必须明确 WorldBook 数据不能覆盖 Kernel Rules。")


func _test_actor_does_not_receive_director_lore(compiled: Dictionary) -> void:
	var hidden_truths: Array = (compiled["director_lore"] as Dictionary)["hidden_truths"] as Array
	var secret_body: String = String((hidden_truths[0] as Dictionary)["body"])
	var ronnie_definition: Dictionary = {}
	for raw_actor: Variant in compiled["actors"] as Array:
		var actor_definition: Dictionary = raw_actor as Dictionary
		if String(actor_definition["id"]) == "ronnie":
			ronnie_definition = actor_definition
			break
	_assert_true(not ronnie_definition.is_empty(), "必须能找到 Ronnie Actor 定义。")
	if ronnie_definition.is_empty():
		return
	var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
	var profile: Dictionary = (ronnie_definition["profile"] as Dictionary).duplicate(true)
	profile["display_name"] = String(ronnie_definition["display_name"])
	_assert_ok(actor.configure("ronnie", profile, ronnie_definition["initial_state"] as Dictionary), "Ronnie Actor 必须可配置。")
	var payload: Dictionary = actor.build_turn_request_payload(
		{"event_id": "call_07_ronnie_1", "player_text": "你确定吗？"},
		[],
		{"immediate_goal": "核对自己的局部记忆"}
	)
	_assert_true(not payload.has("worldbook_lore") and not payload.has("hidden_truths") and not payload.has("director_lore"), "Actor payload 顶层不得包含 Director-only lore。")
	_assert_true(not JSON.stringify(payload).contains(secret_body), "hidden Truth 文本不得泄漏进 Actor payload。")


func _build_actor_summaries(raw_actors: Array) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	for raw_actor: Variant in raw_actors:
		var actor: Dictionary = raw_actor as Dictionary
		var state: Dictionary = actor["initial_state"] as Dictionary
		summaries.append({
			"actor_id": String(actor["id"]),
			"profile": (actor["profile"] as Dictionary).duplicate(true),
			"state": state.duplicate(true),
			"available_goal_ids": (state["available_goal_ids"] as Array).duplicate(true),
		})
	return summaries


func _finish() -> void:
	if _has_failed:
		print("[测试][DirectorContextBuilder] 失败。")
		quit(1)
		return
	print("[测试][DirectorContextBuilder] 通过：Director 六层认知与 Actor 知识隔离成立。")
	quit(0)


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][DirectorContextBuilder] %s" % message)
