extends SceneTree

## 验证 autonomous call_station 的 Delivery 不只会让电话响铃，还能进入正式
## StoryEngine Agent context 与 InteractionCoordinator ConversationSession。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const COORDINATOR_SCRIPT: GDScript = preload("res://scripts/systems/interaction_coordinator.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


class FakeClock extends Node:
	var current_tick: int = 0

	func get_current_game_tick() -> int:
		return current_tick


class FakeAgentRuntime extends AgentRuntimeService:
	func apply_actor_state_patch(_actor_id: String, _patch: Dictionary) -> Dictionary:
		return {"ok": true}

	func request_actor_turn(
		_actor_id: String,
		_interaction_context: Dictionary,
		_disclosable_claims: Array,
		_world_constraints: Dictionary = {},
		_deterministic_fallback_turn: Dictionary = {},
		_external_semantic_validator: Callable = Callable()
	) -> Dictionary:
		return {
			"ok": true,
			"turn": {
				"speech_act": "answer",
				"utterance": "我只是想再确认一下。",
				"asserted_claim_ids": [],
				"withheld_claim_ids": [],
				"session_intent": "continue",
				"world_action": null,
			},
			"source": "fake_dynamic_call_actor",
		}


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var validated_story: Dictionary = _load_validated_story()
	if validated_story.is_empty():
		_finish()
		return
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new() as PhoneSystem
	var story: StoryEngine = STORY_ENGINE_SCRIPT.new() as StoryEngine
	var clock: FakeClock = FakeClock.new()
	var agent: FakeAgentRuntime = FakeAgentRuntime.new()
	var coordinator: InteractionCoordinator = COORDINATOR_SCRIPT.new() as InteractionCoordinator
	root.add_child(clock)

	_assert_ok(story.set_phone_system(phone), "StoryEngine 必须先绑定 PhoneSystem authority。")
	_assert_ok(story.configure_test_night_story(validated_story), "动态来电测试必须配置正式 Agent Dialogue v2 内容。")
	var submit_result: Dictionary = story.submit_delivery_request(
		"martha",
		"call_station",
		{"topic": "follow_up_missing_driver"},
		"opportunity_dynamic_martha_follow_up",
		"director_plan_dynamic_test"
	)
	_assert_ok(submit_result, "call_station DeliveryRequest 必须真正进入 PhoneSystem。")
	var delivery_id: String = ""
	if bool(submit_result.get("ok", false)):
		var delivery_record: Dictionary = submit_result.get("record", {}) as Dictionary
		delivery_id = String(delivery_record.get("delivery_id", ""))
		_assert_equal(String(delivery_record.get("status", "")), "committed", "空闲线路上的动态 call_station 必须 committed。")
		_assert_equal(delivery_id, "delivery_call_martha_1", "动态电话 ID 必须来自 DeliverySystem 稳定 serial。")
	_assert_equal(phone.get_state_name(), "RINGING", "Delivery committed 后 PhoneSystem 必须真实进入 RINGING。")
	_assert_equal(phone.get_active_event_id(), delivery_id, "PhoneSystem 活动 event 必须是该 Delivery ID。")
	var signal_state: Dictionary = story.get_signal_state()
	var signal_records: Array = signal_state.get("records", []) as Array
	_assert_equal(signal_records.size(), 1, "committed Delivery 必须先形成一条正式 feedback Signal。")
	if signal_records.size() == 1:
		var feedback: Dictionary = signal_records[0] as Dictionary
		_assert_equal(String(feedback.get("signal_type", "")), "delivery_outcome", "StoryEngine 必须把 Delivery 终态反馈接入 SignalSystem。")
		_assert_equal(feedback.get("committed_recipients", []), ["martha"], "Delivery feedback 只能让 source Actor 感知。")
		_assert_equal(story.get_actor_perceived_signal_ids("martha"), [String(feedback.get("signal_id", ""))], "StoryEngine Actor perception 查询必须包含 Delivery feedback。")

	_assert_true(phone.answer_call(clock.current_tick), "玩家必须能接听动态 Delivery 来电。")
	_assert_true(phone.enter_dialogue_choice(), "接听后必须能进入 Agent Dialogue 等待状态。")
	var call_context: Dictionary = story.get_active_agent_call_context()
	_assert_ok(call_context, "StoryEngine 必须把 committed delivery_call_* 解析成 Agent call context。")
	if bool(call_context.get("ok", false)):
		_assert_equal(String(call_context.get("event_id", "")), delivery_id, "动态 Agent context 必须保持真实 Delivery source ID。")
		_assert_equal(String(call_context.get("actor_id", "")), "martha", "动态 Agent context Actor 必须来自 Delivery authored identity。")
		_assert_equal(String(call_context.get("call_reason", "")), "follow_up_missing_driver", "动态电话 topic 只能作为本次 call reason，而不是世界事实。")
		_assert_equal((call_context.get("disclosable_claims", []) as Array).size(), 0, "动态电话不得继承原 authored call 的 Statement 白名单。")

	_assert_ok(coordinator.bind_runtime(story, phone, clock, agent, 1), "InteractionCoordinator 必须接受动态电话的正式运行时。")
	var session_result: Dictionary = coordinator.begin_active_phone_session()
	_assert_ok(session_result, "delivery_call_* 必须真正建立 ConversationSession，而不只是响铃。")
	if bool(session_result.get("ok", false)):
		var session: Dictionary = session_result.get("session", {}) as Dictionary
		_assert_equal(String(session.get("event_id", "")), delivery_id, "ConversationSession 必须绑定动态 Delivery event ID。")
		_assert_equal(String(session.get("actor_id", "")), "martha", "ConversationSession 必须绑定真实 Actor。")
		_assert_equal((session.get("transcript", []) as Array).size(), 0, "新动态会话不得伪造历史 transcript。")

	var player_turn_result: Dictionary = await coordinator.submit_player_turn("你刚才为什么又打来？")
	_assert_ok(player_turn_result, "动态 ConversationSession 必须接受自由文本 PlayerTurn 与空 claim ActorTurn。")
	var committed_session: Dictionary = coordinator.get_active_session_snapshot()
	var transcript: Array = committed_session.get("transcript", []) as Array
	_assert_equal(transcript.size(), 2, "动态电话一轮自由对话必须形成一个 PlayerTurn 和一个 ActorTurn。")
	_assert_equal((story.get_revealed_statements() as Array).size(), 0, "动态电话空 claim ActorTurn 不得伪造或复用 authored Statement。")
	_assert_true(phone.exit_dialogue_choice(), "动态电话完成一轮 Agent 对话后必须能退出等待状态。")
	_assert_true(phone.finish_call(clock.current_tick), "动态电话必须通过 PhoneSystem 正常结束并生成真实 call record。")
	_assert_equal(phone.get_state_name(), "IDLE", "动态电话正常结束后线路必须回到 IDLE。")
	_assert_true(coordinator.get_active_session_snapshot().is_empty(), "Phone 终态必须让 InteractionCoordinator 归档活动 ConversationSession。")
	var interaction_state: Dictionary = story.get_interaction_state(delivery_id)
	_assert_true(bool(interaction_state.get("answered", false)), "动态 interaction 必须记录已提交 ActorTurn。")
	_assert_true(bool(interaction_state.get("completed", false)), "Phone 终态必须提交动态 interaction completed 状态。")

	var call_records: Array = phone.get_call_records()
	_assert_equal(call_records.size(), 1, "动态电话结束后 PhoneSystem 必须且只能生成一条真实来电记录。")
	if call_records.size() == 1:
		_assert_equal(String((call_records[0] as Dictionary).get("event_id", "")), delivery_id, "动态电话记录必须保留 committed Delivery ID。")
	var scheduler: RefCounted = story.get_scheduler()
	var event_by_id_value: Variant = scheduler.call(&"get_configured_events_by_id") if scheduler != null else null
	_assert_true(event_by_id_value is Dictionary, "动态电话快照校验必须取得当前 authored event 映射。")
	var phone_snapshot: Dictionary = phone.create_snapshot().duplicate(true)
	if event_by_id_value is Dictionary:
		_assert_ok(phone.validate_snapshot(phone_snapshot, {
			"current_game_tick": clock.current_tick,
			"event_by_id": event_by_id_value as Dictionary,
		}), "动态 Delivery call 结束后的 Phone snapshot 必须通过严格校验。")

	var story_snapshot: Dictionary = story.create_snapshot().duplicate(true)
	var story_context: Dictionary = {
		"phone_system": phone,
		"call_record_event_ids": [delivery_id],
		"current_game_tick": clock.current_tick,
	}
	_assert_ok(story.validate_snapshot(story_snapshot, story_context), "Story snapshot 必须验证动态 interaction、committed Delivery、feedback Signal 与 Phone call record 的完整关系。")
	_assert_true((story_snapshot.get("answered_interaction_event_ids", []) as Array).has(delivery_id), "Story snapshot 必须保存动态 interaction answered ID。")
	_assert_true((story_snapshot.get("completed_interaction_event_ids", []) as Array).has(delivery_id), "Story snapshot 必须保存动态 interaction completed ID。")

	coordinator.release_runtime("test_complete")
	story.release_runtime()
	if clock.get_parent() == root:
		root.remove_child(clock)
	clock.free()
	_finish()


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_value: Variant = loader.call(&"load_json", STORY_PATH)
	_assert_true(load_value is Dictionary, "内容读取器必须返回 Dictionary。")
	if not load_value is Dictionary:
		return {}
	var load_result: Dictionary = load_value as Dictionary
	_assert_ok(load_result, "正式 v2 测试剧情必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_value: Variant = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH)
	_assert_true(validation_value is Dictionary, "内容校验器必须返回 Dictionary。")
	if not validation_value is Dictionary:
		return {}
	var validation: Dictionary = validation_value as Dictionary
	_assert_ok(validation, "正式 v2 测试剧情必须通过严格校验。")
	return validation if bool(validation.get("ok", false)) else {}


func _finish() -> void:
	if _has_failed:
		print("[测试][DynamicDeliveryAgentCall] 失败。")
		quit(1)
		return
	print("[测试][DynamicDeliveryAgentCall] 通过：Delivery call_station 可建立受限动态 ConversationSession。")
	quit(0)


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][DynamicDeliveryAgentCall] %s" % message)
