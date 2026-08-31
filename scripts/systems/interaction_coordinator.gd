class_name InteractionCoordinator
extends RefCounted

## 自由 Agent 交互的系统层协调器。
##
## UI 只提交 PlayerTurn；本类负责 ConversationSession、模型请求、stale response guard、
## StoryEngine 正式提交和 PhoneSystem 的结束请求。它不拥有世界事实，也不直接修改
## StoryEngine/PhoneSystem 的私有状态。

signal session_started(snapshot: Dictionary)
signal session_changed(snapshot: Dictionary)
signal session_ended(record: Dictionary)
signal player_turn_committed(entry: Dictionary)
signal actor_turn_request_started(session_id: String, request_serial: int)
signal actor_turn_committed(entry: Dictionary)
signal stale_response_discarded(session_id: String, request_serial: int, reason: String)
signal interaction_error(error_code: String, message: String)

const CONVERSATION_SESSION_SCRIPT: GDScript = preload("res://scripts/agents/conversation_session.gd")
const ENDING_TICK: int = 3600

var _story_engine: RefCounted = null
var _phone_system: RefCounted = null
var _game_clock: Node = null
var _agent_runtime: AgentRuntimeService = null
var _runtime_serial: int = 0
var _session_sequence: int = 0
var _active_session: ConversationSession = null
var _committed_history: Array[Dictionary] = []
var _signals_connected: bool = false


func bind_runtime(
	story_engine: RefCounted,
	phone_system: RefCounted,
	game_clock: Node,
	agent_runtime: AgentRuntimeService,
	runtime_serial: int
) -> Dictionary:
	if _story_engine != null or _phone_system != null or _game_clock != null or _agent_runtime != null:
		return _error("interaction_runtime_already_bound", "InteractionCoordinator 不能重复绑定运行时。")
	if story_engine == null or phone_system == null or not is_instance_valid(game_clock) or agent_runtime == null:
		return _error("interaction_runtime_invalid", "InteractionCoordinator 的运行时依赖不能为空。")
	if runtime_serial <= 0:
		return _error("interaction_runtime_serial_invalid", "InteractionCoordinator runtime_serial 必须大于零。")
	var story_methods: PackedStringArray = [
		"get_active_agent_call_context",
		"begin_agent_interaction",
		"commit_agent_turn",
		"complete_agent_interaction",
		"validate_agent_turn_semantics",
		"is_ending_forced",
		"get_current_game_tick",
	]
	for method_name: String in story_methods:
		if not story_engine.has_method(method_name):
			return _error("interaction_story_contract_invalid", "StoryEngine 缺少 %s()。" % method_name)
	var phone_methods: PackedStringArray = [
		"get_active_event_id",
		"get_state_name",
		"is_forced_ended",
		"exit_dialogue_choice",
		"finish_call",
	]
	for method_name: String in phone_methods:
		if not phone_system.has_method(method_name):
			return _error("interaction_phone_contract_invalid", "PhoneSystem 缺少 %s()。" % method_name)
	if not phone_system.has_signal(&"state_changed"):
		return _error("interaction_phone_contract_invalid", "PhoneSystem 缺少 state_changed 信号。")
	if not story_engine.has_signal(&"ending_forced"):
		return _error("interaction_story_contract_invalid", "StoryEngine 缺少 ending_forced 信号。")
	if not game_clock.has_method(&"get_current_game_tick"):
		return _error("interaction_clock_contract_invalid", "GameClock 缺少 get_current_game_tick()。")
	if not agent_runtime.has_method(&"request_actor_turn") or not agent_runtime.has_method(&"apply_actor_state_patch"):
		return _error("interaction_agent_contract_invalid", "AgentRuntime 缺少 request_actor_turn()/apply_actor_state_patch()。")
	_story_engine = story_engine
	_phone_system = phone_system
	_game_clock = game_clock
	_agent_runtime = agent_runtime
	_runtime_serial = runtime_serial
	var signal_result: Dictionary = _connect_runtime_signals()
	if not bool(signal_result.get("ok", false)):
		release_runtime("bind_failed")
		return signal_result
	return {"ok": true, "runtime_serial": _runtime_serial}


func release_runtime(reason: String = "runtime_released") -> Dictionary:
	if _active_session != null:
		_archive_active_session(reason)
	_disconnect_runtime_signals()
	_story_engine = null
	_phone_system = null
	_game_clock = null
	_agent_runtime = null
	_runtime_serial += 1
	return {"ok": true}


func begin_active_phone_session() -> Dictionary:
	if not _is_runtime_bound():
		return _error("interaction_runtime_unbound", "InteractionCoordinator 尚未绑定本局运行时。")
	if _active_session != null and _active_session.is_active():
		return _error("conversation_session_already_active", "当前已经存在活动 ConversationSession。")
	var line_guard: Dictionary = _validate_phone_conversation_state(true)
	if not bool(line_guard.get("ok", false)):
		return line_guard
	var context_value: Variant = _story_engine.call(&"get_active_agent_call_context")
	if not context_value is Dictionary:
		return _error("agent_call_context_invalid", "StoryEngine.get_active_agent_call_context() 必须返回 Dictionary。")
	var context: Dictionary = context_value as Dictionary
	if not bool(context.get("ok", false)):
		return context
	for required_key: String in ["event_id", "actor_id", "disclosable_claims"]:
		if not context.has(required_key):
			return _error("agent_call_context_invalid", "Agent call context 缺少字段：%s。" % required_key)
	if not context["event_id"] is String or not context["actor_id"] is String or not context["disclosable_claims"] is Array:
		return _error("agent_call_context_invalid", "Agent call context 字段类型无效。")
	var active_event_id: String = String(_phone_system.call(&"get_active_event_id"))
	if String(context["event_id"]) != active_event_id:
		return _error("agent_call_context_event_mismatch", "StoryEngine 的 Agent call context 与当前线路事件不一致。")
	_session_sequence += 1
	var session: ConversationSession = CONVERSATION_SESSION_SCRIPT.new() as ConversationSession
	var session_id: String = "session_%04d_%s_%s" % [_session_sequence, active_event_id, String(context["actor_id"])]
	var configure_result: Dictionary = session.configure(
		session_id,
		ConversationSession.CHANNEL_PHONE,
		active_event_id,
		String(context["actor_id"])
	)
	if not bool(configure_result.get("ok", false)):
		return configure_result
	var begin_value: Variant = _story_engine.call(&"begin_agent_interaction", session_id, active_event_id, String(context["actor_id"]))
	if not begin_value is Dictionary:
		return _error("story_begin_interaction_contract_invalid", "StoryEngine.begin_agent_interaction() 必须返回 Dictionary。")
	var begin_result: Dictionary = begin_value as Dictionary
	if not bool(begin_result.get("ok", false)):
		return begin_result
	var state_patch: Dictionary = begin_result.get("state_patch", {}) as Dictionary
	if not state_patch.is_empty():
		var patch_result: Dictionary = _agent_runtime.apply_actor_state_patch(String(context["actor_id"]), state_patch)
		if not bool(patch_result.get("ok", false)):
			_story_engine.call(&"complete_agent_interaction", session_id, active_event_id, "actor_state_patch_failed")
			return patch_result
	_active_session = session
	var snapshot: Dictionary = _active_session.create_context_snapshot()
	session_started.emit(snapshot.duplicate(true))
	session_changed.emit(snapshot.duplicate(true))
	return {"ok": true, "session": snapshot}


func submit_player_turn(text: String) -> Dictionary:
	if _active_session == null or not _active_session.is_active():
		return _error("conversation_session_missing", "当前没有活动电话会话。")
	var line_guard: Dictionary = _validate_phone_conversation_state(true)
	if not bool(line_guard.get("ok", false)):
		return line_guard
	var current_tick_result: Dictionary = _read_current_game_tick()
	if not bool(current_tick_result.get("ok", false)):
		return current_tick_result
	var player_result: Dictionary = _active_session.append_player_turn(text, int(current_tick_result["tick"]))
	if not bool(player_result.get("ok", false)):
		return player_result
	player_turn_committed.emit((player_result["entry"] as Dictionary).duplicate(true))
	session_changed.emit(_active_session.create_context_snapshot())

	var request_result: Dictionary = _active_session.reserve_request()
	if not bool(request_result.get("ok", false)):
		return request_result
	var captured_session_id: String = String(request_result["session_id"])
	var captured_event_id: String = String(request_result["event_id"])
	var captured_request_serial: int = int(request_result["request_serial"])
	var captured_runtime_serial: int = _runtime_serial
	actor_turn_request_started.emit(captured_session_id, captured_request_serial)

	var context_value: Variant = _story_engine.call(&"get_active_agent_call_context")
	if not context_value is Dictionary:
		_active_session.cancel_pending_request("agent_call_context_invalid")
		return _error("agent_call_context_invalid", "StoryEngine.get_active_agent_call_context() 必须返回 Dictionary。")
	var call_context: Dictionary = context_value as Dictionary
	if not bool(call_context.get("ok", false)):
		_active_session.cancel_pending_request("agent_call_context_rejected")
		return call_context
	var context_guard: Dictionary = _validate_request_context(call_context, captured_event_id, _active_session.actor_id)
	if not bool(context_guard.get("ok", false)):
		_active_session.cancel_pending_request("agent_call_context_changed")
		return context_guard
	var interaction_context: Dictionary = _active_session.create_context_snapshot()
	interaction_context["current_player_turn"] = (player_result["entry"] as Dictionary).duplicate(true)
	interaction_context["request_serial"] = captured_request_serial

	var agent_result: Dictionary = await _agent_runtime.request_actor_turn(
		_active_session.actor_id,
		interaction_context,
		call_context["disclosable_claims"] as Array,
		call_context.get("world_constraints", {}) as Dictionary,
		call_context.get("deterministic_fallback_turn", {}) as Dictionary,
		Callable(_story_engine, "validate_agent_turn_semantics")
	)
	var stale_guard: Dictionary = validate_response_guard(
		captured_session_id,
		captured_event_id,
		captured_request_serial,
		captured_runtime_serial
	)
	if not bool(stale_guard.get("ok", false)):
		# hangup/ending 通常已经通过同步信号归档 session；但 runtime serial 或其它
		# guard 变化也可能在 session 仍 active 时使响应过期。此时只取消仍属于该请求的
		# pending 标记，绝不提交、展示或尝试复用 stale ActorTurn。
		if _active_session != null and _active_session.is_request_current(
			captured_session_id,
			captured_event_id,
			captured_request_serial
		):
			_active_session.cancel_pending_request("stale_response_discarded")
			session_changed.emit(_active_session.create_context_snapshot())
		stale_response_discarded.emit(
			captured_session_id,
			captured_request_serial,
			String(stale_guard.get("message", "ActorTurn 响应已失效。"))
		)
		return stale_guard
	if not bool(agent_result.get("ok", false)):
		_active_session.cancel_pending_request("actor_turn_request_failed")
		return agent_result
	if not agent_result.has("turn") or not agent_result["turn"] is Dictionary:
		_active_session.cancel_pending_request("actor_turn_result_invalid")
		return _error("actor_turn_result_invalid", "AgentRuntime 成功结果缺少 ActorTurn。")
	var actor_turn: Dictionary = agent_result["turn"] as Dictionary
	var source: String = String(agent_result.get("source", "actor_turn"))
	var commit_request: Dictionary = {
		"session_id": captured_session_id,
		"event_id": captured_event_id,
		"actor_id": _active_session.actor_id,
		"request_serial": captured_request_serial,
		"turn_index": _active_session.turn_index,
		"actor_turn": actor_turn.duplicate(true),
	}
	var commit_value: Variant = _story_engine.call(&"commit_agent_turn", commit_request)
	if not commit_value is Dictionary:
		_active_session.cancel_pending_request("story_commit_contract_invalid")
		return _error("story_commit_contract_invalid", "StoryEngine.commit_agent_turn() 必须返回 Dictionary。")
	var commit_result: Dictionary = commit_value as Dictionary
	if not bool(commit_result.get("ok", false)):
		_active_session.cancel_pending_request("story_commit_rejected")
		return commit_result
	var append_result: Dictionary = _active_session.append_actor_turn(
		actor_turn,
		source,
		int(current_tick_result["tick"]),
		captured_request_serial
	)
	if not bool(append_result.get("ok", false)):
		# stale guard 与 StoryEngine commit 到 append 之间没有 await；到这里失败表示内部
		# 合同错误，必须显式暴露，不能尝试重新生成或重复提交模型结果。
		return _error("conversation_commit_invariant_broken", "StoryEngine 已接受 ActorTurn，但 ConversationSession 无法记录同一已提交回合。")
	var committed_entry: Dictionary = append_result["entry"] as Dictionary
	actor_turn_committed.emit(committed_entry.duplicate(true))
	session_changed.emit(_active_session.create_context_snapshot())
	if String(actor_turn.get("session_intent", "continue")) == "end":
		var finish_result: Dictionary = _finish_actor_requested_call()
		if not bool(finish_result.get("ok", false)):
			return finish_result
	return {
		"ok": true,
		"player_entry": (player_result["entry"] as Dictionary).duplicate(true),
		"actor_entry": committed_entry.duplicate(true),
		"source": source,
		"story_commit": commit_result.duplicate(true),
	}


## 可单独合同测试的 stale response guard。模型结果只有全部权威条件仍成立时才有提交资格。
func validate_response_guard(
	expected_session_id: String,
	expected_event_id: String,
	expected_request_serial: int,
	expected_runtime_serial: int
) -> Dictionary:
	if not _is_runtime_bound():
		return _stale("stale_runtime_unbound", "模型响应返回时本局运行时已经释放。")
	if expected_runtime_serial != _runtime_serial:
		return _stale("stale_runtime_serial", "模型响应属于已经被替换的旧夜班运行时。")
	if _active_session == null:
		return _stale("stale_session_missing", "模型响应返回时原 ConversationSession 已不存在。")
	if not _active_session.is_request_current(expected_session_id, expected_event_id, expected_request_serial):
		return _stale("stale_request_serial", "模型响应的 session_id 或 request_serial 已失效。")
	var active_event_value: Variant = _phone_system.call(&"get_active_event_id")
	if not active_event_value is String or String(active_event_value) != expected_event_id:
		return _stale("stale_phone_event", "模型响应返回时活动电话已经不是原事件。")
	var phone_state_value: Variant = _phone_system.call(&"get_state_name")
	if not phone_state_value is String or String(phone_state_value) != "DIALOGUE_CHOICE":
		return _stale("stale_phone_state", "模型响应返回时电话已不处于当前会话等待状态。")
	if bool(_phone_system.call(&"is_forced_ended")):
		return _stale("stale_phone_forced_end", "02:00 已强制终止电话线路。")
	if bool(_story_engine.call(&"is_ending_forced")):
		return _stale("stale_story_ending", "02:00 已强制结束剧情。")
	var tick_result: Dictionary = _read_current_game_tick()
	if not bool(tick_result.get("ok", false)):
		return _stale("stale_clock_invalid", String(tick_result.get("message", "无法确认当前游戏时间。")))
	if int(tick_result["tick"]) >= ENDING_TICK:
		return _stale("stale_ending_tick", "模型响应到达时已经达到 02:00。")
	return {"ok": true}


func get_active_session_snapshot() -> Dictionary:
	if _active_session == null:
		return {}
	return _active_session.create_context_snapshot()


func get_committed_history() -> Array[Dictionary]:
	return _committed_history.duplicate(true)


func has_active_session() -> bool:
	return _active_session != null and _active_session.is_active()


func _finish_actor_requested_call() -> Dictionary:
	if _active_session == null:
		return _error("conversation_session_missing", "Actor 请求结束时已没有活动 ConversationSession。")
	var current_tick_result: Dictionary = _read_current_game_tick()
	if not bool(current_tick_result.get("ok", false)):
		return current_tick_result
	var exit_value: Variant = _phone_system.call(&"exit_dialogue_choice")
	if typeof(exit_value) != TYPE_BOOL or not bool(exit_value):
		return _error("phone_conversation_exit_failed", "Actor 请求结束通话时 PhoneSystem 未能退出等待状态。")
	var finish_value: Variant = _phone_system.call(&"finish_call", int(current_tick_result["tick"]))
	if typeof(finish_value) != TYPE_BOOL or not bool(finish_value):
		return _error("phone_finish_call_failed", "Actor 请求结束通话时 PhoneSystem 未能完成线路。")
	# PhoneSystem 的同步 state_changed/call_became_idle 会正常归档 session；这里仅补
	# 防御性检查，避免未来信号契约变化留下活动会话。
	if _active_session != null:
		_archive_active_session("actor_requested_end")
	return {"ok": true}


func _validate_request_context(context: Dictionary, expected_event_id: String, expected_actor_id: String) -> Dictionary:
	if not context.has("event_id") or not context.has("actor_id") or not context.has("disclosable_claims"):
		return _error("agent_call_context_invalid", "Agent call context 缺少 event_id/actor_id/disclosable_claims。")
	if String(context["event_id"]) != expected_event_id or String(context["actor_id"]) != expected_actor_id:
		return _error("agent_call_context_changed", "PlayerTurn 提交后 Agent call context 已发生变化。")
	if not context["disclosable_claims"] is Array:
		return _error("agent_call_context_invalid", "Agent call context.disclosable_claims 必须是数组。")
	if context.has("world_constraints") and not context["world_constraints"] is Dictionary:
		return _error("agent_call_context_invalid", "Agent call context.world_constraints 必须是对象。")
	if context.has("deterministic_fallback_turn") and not context["deterministic_fallback_turn"] is Dictionary:
		return _error("agent_call_context_invalid", "Agent call context.deterministic_fallback_turn 必须是对象。")
	return {"ok": true}


func _validate_phone_conversation_state(require_dialogue_choice: bool) -> Dictionary:
	if bool(_story_engine.call(&"is_ending_forced")) or bool(_phone_system.call(&"is_forced_ended")):
		return _error("interaction_ending_forced", "02:00 强制收束已执行，不能继续电话会话。")
	var active_event_value: Variant = _phone_system.call(&"get_active_event_id")
	var state_value: Variant = _phone_system.call(&"get_state_name")
	if not active_event_value is String or String(active_event_value).is_empty() or not state_value is String:
		return _error("interaction_phone_state_invalid", "当前电话线路没有有效活动事件。")
	var state_name: String = String(state_value)
	if require_dialogue_choice and state_name != "DIALOGUE_CHOICE":
		return _error("interaction_phone_state_invalid", "自由对话只在电话等待玩家输入时可继续。")
	if _active_session != null and _active_session.event_id != String(active_event_value):
		return _error("interaction_session_event_mismatch", "ConversationSession 与当前 PhoneSystem 事件不一致。")
	return {"ok": true, "event_id": String(active_event_value), "state_name": state_name}


func _connect_runtime_signals() -> Dictionary:
	if _signals_connected:
		return {"ok": true}
	var phone_callback: Callable = Callable(self, "_on_phone_state_changed")
	var phone_connect: Error = _phone_system.connect(&"state_changed", phone_callback)
	if phone_connect != OK:
		return _error("interaction_phone_signal_failed", "无法连接 PhoneSystem.state_changed，错误码=%d。" % phone_connect)
	var ending_callback: Callable = Callable(self, "_on_ending_forced")
	var ending_connect: Error = _story_engine.connect(&"ending_forced", ending_callback)
	if ending_connect != OK:
		_phone_system.disconnect(&"state_changed", phone_callback)
		return _error("interaction_story_signal_failed", "无法连接 StoryEngine.ending_forced，错误码=%d。" % ending_connect)
	_signals_connected = true
	return {"ok": true}


func _disconnect_runtime_signals() -> void:
	if not _signals_connected:
		return
	if _phone_system != null:
		var phone_callback: Callable = Callable(self, "_on_phone_state_changed")
		if _phone_system.is_connected(&"state_changed", phone_callback):
			_phone_system.disconnect(&"state_changed", phone_callback)
	if _story_engine != null:
		var ending_callback: Callable = Callable(self, "_on_ending_forced")
		if _story_engine.is_connected(&"ending_forced", ending_callback):
			_story_engine.disconnect(&"ending_forced", ending_callback)
	_signals_connected = false


func _on_phone_state_changed(_previous_state: int, current_state: int, event_id: String) -> void:
	if _active_session == null:
		return
	if event_id != _active_session.event_id:
		_archive_active_session("phone_event_changed")
		return
	if current_state == PhoneSystem.State.ENDED or current_state == PhoneSystem.State.MISSED or current_state == PhoneSystem.State.IDLE:
		_archive_active_session("phone_ended")


func _on_ending_forced(_end_tick: int) -> void:
	if _active_session != null:
		_archive_active_session("ending_forced")


func _archive_active_session(reason: String) -> void:
	if _active_session == null:
		return
	var session_id: String = _active_session.session_id
	var event_id: String = _active_session.event_id
	var complete_value: Variant = _story_engine.call(&"complete_agent_interaction", session_id, event_id, reason) if _story_engine != null else null
	if complete_value is Dictionary and not bool((complete_value as Dictionary).get("ok", false)):
		interaction_error.emit(String((complete_value as Dictionary).get("error_code", "interaction_complete_failed")), String((complete_value as Dictionary).get("message", "StoryEngine 未能完成 Agent interaction。")))
	_active_session.end_session(reason)
	var record: Dictionary = _active_session.create_archive_record()
	_committed_history.append(record.duplicate(true))
	_active_session = null
	session_ended.emit(record.duplicate(true))
	session_changed.emit({})


func _read_current_game_tick() -> Dictionary:
	if _game_clock == null or not is_instance_valid(_game_clock):
		return _error("interaction_clock_invalid", "GameClock 不可用。")
	var tick_value: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_value) != TYPE_INT:
		return _error("interaction_clock_invalid", "GameClock.get_current_game_tick() 必须返回整数。")
	var tick: int = int(tick_value)
	if tick < 0:
		return _error("interaction_clock_invalid", "GameClock 返回了负数 tick。")
	return {"ok": true, "tick": tick}


func _is_runtime_bound() -> bool:
	return _story_engine != null and _phone_system != null and _game_clock != null and _agent_runtime != null


func _stale(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "stale": true, "error_code": error_code, "message": message}


func _error(error_code: String, message: String) -> Dictionary:
	interaction_error.emit(error_code, message)
	return {"ok": false, "error_code": error_code, "message": message}
