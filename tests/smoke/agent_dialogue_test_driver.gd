extends RefCounted

## 正式 Agent Dialogue v2 smoke 的确定性夹具驱动器。
##
## 它不模拟 LLM，也不直接写 StoryEngine 字典；只把“已经通过 Actor/semantic 校验的
## committed ActorTurn”提交给公开 StoryEngine API，并始终让 PhoneSystem 拥有线路结束权。

var _session_serial: int = 0


func commit_active_call(
	story: StoryEngine,
	event_id: String,
	actor_id: String,
	asserted_statement_ids: Array,
	utterance: String,
	session_intent: String = "continue"
) -> Dictionary:
	if story == null:
		return _error("test_story_missing", "Agent Dialogue 测试驱动器缺少 StoryEngine。")
	_session_serial += 1
	var session_id: String = "smoke_%s_%d" % [event_id, _session_serial]
	var begin_result: Dictionary = story.begin_agent_interaction(session_id, event_id, actor_id)
	if not bool(begin_result.get("ok", false)):
		return begin_result
	var actor_turn: Dictionary = {
		"speech_act": "end_call" if session_intent == "end" else "answer",
		"utterance": utterance,
		"asserted_claim_ids": asserted_statement_ids.duplicate(),
		"withheld_claim_ids": [],
		"session_intent": session_intent,
		"world_action": null,
	}
	var commit_result: Dictionary = story.commit_agent_turn({
		"session_id": session_id,
		"event_id": event_id,
		"actor_id": actor_id,
		"request_serial": 1,
		"turn_index": 1,
		"actor_turn": actor_turn,
	})
	if not bool(commit_result.get("ok", false)):
		# 测试夹具失败也要释放 StoryEngine 的 active interaction，避免污染后续断言。
		story.complete_agent_interaction(session_id, event_id, "interaction_completed")
		return commit_result
	var complete_result: Dictionary = story.complete_agent_interaction(session_id, event_id, "interaction_completed")
	if not bool(complete_result.get("ok", false)):
		return complete_result
	return {
		"ok": true,
		"session_id": session_id,
		"commit": commit_result,
		"complete": complete_result,
	}


func complete_scheduled_call(
	story: StoryEngine,
	phone: PhoneSystem,
	tick: int,
	event_id: String,
	actor_id: String,
	asserted_statement_ids: Array,
	utterance: String
) -> Dictionary:
	if story == null or phone == null:
		return _error("test_runtime_missing", "Agent Dialogue 测试驱动器缺少 StoryEngine 或 PhoneSystem。")
	var advance_result: Dictionary = story.advance_to_game_tick(tick)
	if not bool(advance_result.get("ok", false)):
		return advance_result
	if phone.get_active_event_id() != event_id:
		return _error(
			"test_event_mismatch",
			"期望活动来电 %s，实际为 %s。" % [event_id, phone.get_active_event_id()]
		)
	if not phone.answer_call(tick):
		return _error("test_answer_failed", "无法接听测试来电：%s。" % event_id)
	if not phone.enter_dialogue_choice():
		return _error("test_dialogue_state_failed", "测试来电无法进入 DIALOGUE_CHOICE：%s。" % event_id)
	var commit_result: Dictionary = commit_active_call(story, event_id, actor_id, asserted_statement_ids, utterance)
	if not bool(commit_result.get("ok", false)):
		return commit_result
	if not phone.exit_dialogue_choice():
		return _error("test_dialogue_exit_failed", "测试来电无法退出 DIALOGUE_CHOICE：%s。" % event_id)
	if not phone.finish_call(tick):
		return _error("test_finish_call_failed", "PhoneSystem 无法正式结束测试来电：%s。" % event_id)
	return {"ok": true, "commit": commit_result}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
