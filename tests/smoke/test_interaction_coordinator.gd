extends SceneTree

## Agent Dialogue v2 电话协调器的非网络合同测试。
##
## 重点验证 committed transcript 顺序、单请求约束、StoryEngine 提交边界，以及
## hangup / 02:00 / runtime serial 变化后的 stale response 永远不能进入世界或 transcript。

const COORDINATOR_SCRIPT: GDScript = preload("res://scripts/systems/interaction_coordinator.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _has_failed: bool = false
var _runtime_serial_seed: int = 100
var _stale_response_count: int = 0


class FakeClock extends Node:
	var current_tick: int = 120

	func get_current_game_tick() -> int:
		return current_tick


class FakeStoryEngine extends RefCounted:
	signal ending_forced(game_tick: int)

	var event_id: String = "call_test"
	var actor_id: String = "actor_test"
	var reject_commit: bool = false
	var ending_is_forced: bool = false
	var commit_count: int = 0
	var complete_count: int = 0
	var committed_requests: Array[Dictionary] = []
	var active_session_id: String = ""

	func get_active_agent_call_context() -> Dictionary:
		return {
			"ok": true,
			"event_id": event_id,
			"actor_id": actor_id,
			"caller_display_name": "测试来电者",
			"call_reason": "验证自由电话协调器",
			"opening_intent": "回答玩家问题",
			"disclosable_claims": [],
			"world_constraints": {"channel": "phone", "event_id": event_id},
			"deterministic_fallback_turn": _actor_turn("fallback", "end"),
		}

	func begin_agent_interaction(session_id: String, requested_event_id: String, requested_actor_id: String) -> Dictionary:
		if requested_event_id != event_id or requested_actor_id != actor_id:
			return _error("agent_interaction_mismatch", "测试 interaction 身份不匹配。")
		if not active_session_id.is_empty():
			return _error("agent_interaction_already_active", "测试 interaction 已存在。")
		active_session_id = session_id
		return {"ok": true, "state_patch": {}}

	func validate_agent_turn_semantics(_actor_turn_value: Dictionary, _matched_claims: Array) -> Dictionary:
		return {"ok": true}

	func commit_agent_turn(request: Dictionary) -> Dictionary:
		commit_count += 1
		if reject_commit:
			return _error("test_story_commit_rejected", "测试要求 StoryEngine 拒绝 ActorTurn。")
		committed_requests.append(request.duplicate(true))
		return {"ok": true, "record": {"event_id": event_id}, "newly_revealed_statement_ids": []}

	func complete_agent_interaction(session_id: String, requested_event_id: String, _reason: String) -> Dictionary:
		if session_id != active_session_id or requested_event_id != event_id:
			return _error("agent_interaction_session_mismatch", "测试 interaction 结束身份不匹配。")
		complete_count += 1
		active_session_id = ""
		return {"ok": true, "event_id": event_id}

	func is_ending_forced() -> bool:
		return ending_is_forced

	func get_current_game_tick() -> int:
		return 0

	func force_ending(game_tick: int = 3600) -> void:
		ending_is_forced = true
		ending_forced.emit(game_tick)

	func _error(error_code: String, message: String) -> Dictionary:
		return {"ok": false, "error_code": error_code, "message": message}

	static func _actor_turn(text: String, intent: String = "continue") -> Dictionary:
		return {
			"speech_act": "end_call" if intent == "end" else "answer",
			"utterance": text,
			"asserted_claim_ids": [],
			"withheld_claim_ids": [],
			"session_intent": intent,
			"world_action": null,
		}


class FakeAgentRuntime extends AgentRuntimeService:
	signal response_released

	var defer_response: bool = false
	var response_turn: Dictionary = {
		"speech_act": "answer",
		"utterance": "这是合法的测试回复。",
		"asserted_claim_ids": [],
		"withheld_claim_ids": [],
		"session_intent": "continue",
		"world_action": null,
	}
	var request_count: int = 0
	var state_patch_count: int = 0
	var observed_player_before_request: bool = false

	func request_actor_turn(
		_actor_id: String,
		interaction_context: Dictionary,
		_disclosable_claims: Array,
		_world_constraints: Dictionary = {},
		_deterministic_fallback_turn: Dictionary = {},
		_external_semantic_validator: Callable = Callable()
	) -> Dictionary:
		request_count += 1
		var transcript: Array = interaction_context.get("transcript", []) as Array
		observed_player_before_request = false
		if not transcript.is_empty() and transcript.back() is Dictionary:
			observed_player_before_request = String((transcript.back() as Dictionary).get("kind", "")) == "player"
		if defer_response:
			await response_released
		return {
			"ok": true,
			"turn": response_turn.duplicate(true),
			"source": "fake_actor_turn",
		}

	func apply_actor_state_patch(_actor_id: String, _patch: Dictionary) -> Dictionary:
		state_patch_count += 1
		return {"ok": true}

	func release_response() -> void:
		response_released.emit()


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_session_requires_dialogue_choice()
	await _test_player_commit_pending_and_single_actor_commit()
	await _test_story_reject_keeps_actor_out_of_transcript()
	await _test_hangup_discards_late_actor_turn()
	await _test_ending_discards_late_actor_turn()
	await _test_runtime_serial_stale_clears_pending()
	await _test_actor_end_request_uses_phone_system()
	if _has_failed:
		print("[测试][InteractionCoordinator] 失败。")
		quit(1)
		return
	print("[测试][InteractionCoordinator] 通过：会话提交顺序、stale guard 与电话结束权限边界成立。")
	quit(0)


func _test_session_requires_dialogue_choice() -> void:
	var runtime: Dictionary = _make_bound_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	_assert_true(_begin_test_call(phone, false), "测试来电必须能停在 CONNECTED。")
	_assert_error_code(
		coordinator.begin_active_phone_session(),
		"interaction_phone_state_invalid",
		"只有 DIALOGUE_CHOICE 才能建立 ConversationSession。"
	)
	_assert_true(phone.enter_dialogue_choice(), "测试线路必须能进入 DIALOGUE_CHOICE。")
	_assert_ok(coordinator.begin_active_phone_session(), "进入 DIALOGUE_CHOICE 后必须能建立 ConversationSession。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)
	await process_frame


func _test_player_commit_pending_and_single_actor_commit() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	var agent: FakeAgentRuntime = runtime["agent"] as FakeAgentRuntime
	agent.defer_response = true
	var holder: Dictionary = {}
	_submit_async(coordinator, "第一句玩家文本", holder)
	await process_frame
	var pending_snapshot: Dictionary = coordinator.get_active_session_snapshot()
	var pending_transcript: Array = pending_snapshot.get("transcript", []) as Array
	_assert_equal(pending_transcript.size(), 1, "模型返回前 committed transcript 必须先只有 PlayerTurn。")
	if not pending_transcript.is_empty():
		_assert_equal(String((pending_transcript[0] as Dictionary).get("kind", "")), "player", "首个 committed entry 必须是 PlayerTurn。")
	_assert_true(agent.observed_player_before_request, "AgentRuntime 请求上下文必须已经包含 committed PlayerTurn。")
	_assert_equal(story.commit_count, 0, "模型尚未返回时不得提前调用 StoryEngine.commit_agent_turn。")
	var duplicate_result: Dictionary = await coordinator.submit_player_turn("pending 时的第二句")
	_assert_error_code(duplicate_result, "conversation_request_pending", "pending ActorTurn 时必须拒绝第二个 PlayerTurn。")
	_assert_equal(agent.request_count, 1, "pending 重复提交不得启动第二个 Actor 请求。")
	agent.release_response()
	await process_frame
	_assert_true(bool(holder.get("done", false)), "释放 fake response 后首轮提交必须完成。")
	_assert_ok(holder.get("result", {}), "正常 ActorTurn 必须提交成功。")
	var committed_snapshot: Dictionary = coordinator.get_active_session_snapshot()
	var committed_transcript: Array = committed_snapshot.get("transcript", []) as Array
	_assert_equal(committed_transcript.size(), 2, "正常一轮只能形成一个 PlayerTurn 和一个 ActorTurn。")
	_assert_equal(story.commit_count, 1, "正常 ActorTurn 必须且只能提交 StoryEngine 一次。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _test_story_reject_keeps_actor_out_of_transcript() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	story.reject_commit = true
	var result: Dictionary = await coordinator.submit_player_turn("请给出测试回复。")
	_assert_error_code(result, "test_story_commit_rejected", "StoryEngine 拒绝时协调器必须返回原始提交错误。")
	var snapshot: Dictionary = coordinator.get_active_session_snapshot()
	var transcript: Array = snapshot.get("transcript", []) as Array
	_assert_equal(transcript.size(), 1, "StoryEngine 接受之前 ActorTurn 绝不能进入 committed transcript。")
	if not transcript.is_empty():
		_assert_equal(String((transcript[0] as Dictionary).get("kind", "")), "player", "StoryEngine reject 后只能保留已提交 PlayerTurn。")
	_assert_equal(story.commit_count, 1, "被拒绝的 ActorTurn 只允许尝试一次 StoryEngine commit。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _test_hangup_discards_late_actor_turn() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	var clock: FakeClock = runtime["clock"] as FakeClock
	var agent: FakeAgentRuntime = runtime["agent"] as FakeAgentRuntime
	agent.defer_response = true
	var holder: Dictionary = {}
	var stale_before: int = _stale_response_count
	_submit_async(coordinator, "我先问一句再挂断。", holder)
	await process_frame
	_assert_true(phone.hang_up(clock.current_tick), "玩家挂断必须由 PhoneSystem 正式提交。")
	_assert_true(coordinator.get_active_session_snapshot().is_empty(), "挂断后活动 ConversationSession 必须立即归档。")
	agent.release_response()
	await process_frame
	_assert_true(bool(holder.get("done", false)), "迟到响应释放后 submit coroutine 必须结束。")
	_assert_true(not bool((holder.get("result", {}) as Dictionary).get("ok", true)), "挂断后的模型结果必须判定 stale。")
	_assert_equal(story.commit_count, 0, "挂断后的 stale ActorTurn 不得调用 StoryEngine.commit_agent_turn。")
	_assert_equal(_stale_response_count, stale_before + 1, "挂断后的迟到响应必须发出一次 stale_response_discarded。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _test_ending_discards_late_actor_turn() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	var clock: FakeClock = runtime["clock"] as FakeClock
	var agent: FakeAgentRuntime = runtime["agent"] as FakeAgentRuntime
	agent.defer_response = true
	var holder: Dictionary = {}
	_submit_async(coordinator, "02:00 前发出的最后一句。", holder)
	await process_frame
	clock.current_tick = 3600
	story.force_ending(3600)
	agent.release_response()
	await process_frame
	_assert_true(bool(holder.get("done", false)), "02:00 后迟到响应必须结束 coroutine。")
	_assert_true(not bool((holder.get("result", {}) as Dictionary).get("ok", true)), "02:00 后模型结果必须判定 stale。")
	_assert_equal(story.commit_count, 0, "02:00 后 stale ActorTurn 不得提交 StoryEngine。")
	_assert_true(coordinator.get_active_session_snapshot().is_empty(), "02:00 强制收束必须先归档活动 session。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _test_runtime_serial_stale_clears_pending() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	var agent: FakeAgentRuntime = runtime["agent"] as FakeAgentRuntime
	agent.defer_response = true
	var holder: Dictionary = {}
	_submit_async(coordinator, "旧 runtime serial 的问题。", holder)
	await process_frame
	coordinator.set("_runtime_serial", coordinator.get_runtime_serial() + 1)
	agent.release_response()
	await process_frame
	_assert_true(bool(holder.get("done", false)), "runtime serial 变化后的旧请求必须结束。")
	_assert_true(not bool((holder.get("result", {}) as Dictionary).get("ok", true)), "旧 runtime serial 响应必须判定 stale。")
	_assert_equal(story.commit_count, 0, "旧 runtime serial 响应不得提交 StoryEngine。")
	# stale 分支必须释放仍属于旧请求的 pending 标记，否则下一句会永久被锁死。
	agent.defer_response = false
	var recovery_result: Dictionary = await coordinator.submit_player_turn("新 serial 下继续提问。")
	_assert_ok(recovery_result, "runtime serial stale 后必须能继续提交新的 PlayerTurn。")
	_assert_equal(story.commit_count, 1, "恢复后的新请求只能提交一次 ActorTurn。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _test_actor_end_request_uses_phone_system() -> void:
	var runtime: Dictionary = _make_active_runtime()
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	var story: FakeStoryEngine = runtime["story"] as FakeStoryEngine
	var agent: FakeAgentRuntime = runtime["agent"] as FakeAgentRuntime
	agent.response_turn = FakeStoryEngine._actor_turn("我这边先挂了。", "end")
	var result: Dictionary = await coordinator.submit_player_turn("好的，你可以结束通话。")
	_assert_ok(result, "合法 session_intent=end ActorTurn 必须先完成正常提交。")
	_assert_equal(phone.get_state_name(), "IDLE", "Actor 请求结束后最终线路状态必须由 PhoneSystem 回到 IDLE。")
	var records: Array[Dictionary] = phone.get_call_records()
	_assert_equal(records.size(), 1, "Actor 请求结束只能生成一条 PhoneSystem 通话记录。")
	if not records.is_empty():
		_assert_equal(String(records[0].get("outcome", "")), PhoneSystem.OUTCOME_ANSWERED, "Actor 请求结束应走 PhoneSystem 正常 answered 终止。")
	_assert_equal(story.commit_count, 1, "Actor end turn 必须先被 StoryEngine commit 一次。")
	_assert_equal(story.complete_count, 1, "线路正式结束后 StoryEngine interaction 必须只归档一次。")
	_assert_true(coordinator.get_active_session_snapshot().is_empty(), "Actor 请求结束后不得保留活动 session。")
	coordinator.release_runtime("test_complete")
	_free_runtime(runtime)


func _make_bound_runtime() -> Dictionary:
	_runtime_serial_seed += 1
	var coordinator: InteractionCoordinator = COORDINATOR_SCRIPT.new() as InteractionCoordinator
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new() as PhoneSystem
	var story: FakeStoryEngine = FakeStoryEngine.new()
	var clock: FakeClock = FakeClock.new()
	var agent: FakeAgentRuntime = FakeAgentRuntime.new()
	_assert_ok(
		coordinator.bind_runtime(story, phone, clock, agent, _runtime_serial_seed),
		"InteractionCoordinator 测试运行时必须绑定成功。"
	)
	coordinator.stale_response_discarded.connect(_on_stale_response_discarded)
	return {
		"coordinator": coordinator,
		"phone": phone,
		"story": story,
		"clock": clock,
		"agent": agent,
	}


func _make_active_runtime() -> Dictionary:
	var runtime: Dictionary = _make_bound_runtime()
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	var coordinator: InteractionCoordinator = runtime["coordinator"] as InteractionCoordinator
	_assert_true(_begin_test_call(phone, true), "测试来电必须能进入 DIALOGUE_CHOICE。")
	_assert_ok(coordinator.begin_active_phone_session(), "测试 ConversationSession 必须能建立。")
	return runtime


func _begin_test_call(phone: PhoneSystem, enter_dialogue: bool) -> bool:
	var call_data: Dictionary = {
		"id": "call_test",
		"caller_display_name": "测试来电者",
		"caller_number": "555-0000",
	}
	if not phone.begin_incoming_call(call_data, 120, 120):
		return false
	if not phone.answer_call(120):
		return false
	if enter_dialogue and not phone.enter_dialogue_choice():
		return false
	return true


func _submit_async(coordinator: InteractionCoordinator, text: String, holder: Dictionary) -> void:
	holder["result"] = await coordinator.submit_player_turn(text)
	holder["done"] = true


func _free_runtime(runtime: Dictionary) -> void:
	var agent: FakeAgentRuntime = runtime.get("agent") as FakeAgentRuntime
	var clock: FakeClock = runtime.get("clock") as FakeClock
	if agent != null:
		agent.free()
	if clock != null:
		clock.free()


func _on_stale_response_discarded(_session_id: String, _request_serial: int, _reason: String) -> void:
	_stale_response_count += 1


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_error_code(result: Variant, expected_error_code: String, message: String) -> void:
	_assert_true(result is Dictionary, "%s 结果类型无效：%s。" % [message, type_string(typeof(result))])
	if not result is Dictionary:
		return
	var payload: Dictionary = result as Dictionary
	_assert_true(not bool(payload.get("ok", false)), message)
	_assert_equal(String(payload.get("error_code", "")), expected_error_code, "%s error_code 不正确。" % message)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][InteractionCoordinator] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
