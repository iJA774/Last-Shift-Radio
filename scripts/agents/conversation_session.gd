class_name ConversationSession
extends RefCounted

## 单次电话交互的确定性会话状态。
##
## 模型上下文不是历史权威；只有这里记录的 PlayerTurn / 已接受 ActorTurn 才属于
## committed transcript。request_serial 每次模型请求递增，任何结束/失效操作也会
## 递增 serial，从而让已经在路上的旧响应天然失效。

const SNAPSHOT_VERSION: int = 1
const STATUS_ACTIVE: String = "active"
const STATUS_ENDED: String = "ended"
const CHANNEL_PHONE: String = "phone"

var session_id: String = ""
var channel: String = ""
var event_id: String = ""
var actor_id: String = ""
var status: String = STATUS_ENDED
var turn_index: int = 0
var request_serial: int = 0
var transcript: Array[Dictionary] = []
var _request_pending: bool = false
var _end_reason: String = ""


func configure(p_session_id: String, p_channel: String, p_event_id: String, p_actor_id: String) -> Dictionary:
	if not session_id.is_empty():
		return _error("conversation_session_already_configured", "ConversationSession 不能重复配置。")
	for field: Dictionary in [
		{"name": "session_id", "value": p_session_id},
		{"name": "channel", "value": p_channel},
		{"name": "event_id", "value": p_event_id},
		{"name": "actor_id", "value": p_actor_id},
	]:
		if String(field["value"]).strip_edges().is_empty():
			return _error("conversation_session_field_invalid", "%s 必须是非空字符串。" % String(field["name"]))
	if p_channel != CHANNEL_PHONE:
		return _error("conversation_channel_unsupported", "当前 ConversationSession 只支持 phone channel。")
	session_id = p_session_id
	channel = p_channel
	event_id = p_event_id
	actor_id = p_actor_id
	status = STATUS_ACTIVE
	turn_index = 0
	request_serial = 0
	transcript.clear()
	_request_pending = false
	_end_reason = ""
	return {"ok": true}


func is_active() -> bool:
	return status == STATUS_ACTIVE


func is_request_pending() -> bool:
	return _request_pending


func get_end_reason() -> String:
	return _end_reason


func append_player_turn(text: String, game_tick: int) -> Dictionary:
	if not is_active():
		return _error("conversation_session_inactive", "会话已结束，不能提交 PlayerTurn。")
	if _request_pending:
		return _error("conversation_request_pending", "上一轮 ActorTurn 尚未完成，不能重复提交 PlayerTurn。")
	var normalized_text: String = text.strip_edges()
	if normalized_text.is_empty():
		return _error("player_turn_empty", "PlayerTurn 文本不能为空。")
	if game_tick < 0:
		return _error("player_turn_tick_invalid", "PlayerTurn game_tick 不能为负数。")
	var entry: Dictionary = {
		"kind": "player",
		"turn_index": turn_index,
		"text": normalized_text,
		"game_tick": game_tick,
	}
	transcript.append(entry)
	return {"ok": true, "entry": entry.duplicate(true)}


func reserve_request() -> Dictionary:
	if not is_active():
		return _error("conversation_session_inactive", "会话已结束，不能发起 ActorTurn 请求。")
	if _request_pending:
		return _error("conversation_request_pending", "当前已经有 ActorTurn 请求在等待响应。")
	if transcript.is_empty():
		return _error("conversation_player_turn_missing", "发起 ActorTurn 请求前必须先提交本轮 PlayerTurn。")
	var last_entry: Dictionary = transcript.back()
	if String(last_entry.get("kind", "")) != "player" or int(last_entry.get("turn_index", -1)) != turn_index:
		return _error("conversation_player_turn_missing", "发起 ActorTurn 请求前必须先提交本轮 PlayerTurn。")
	request_serial += 1
	_request_pending = true
	return {
		"ok": true,
		"session_id": session_id,
		"event_id": event_id,
		"request_serial": request_serial,
		"turn_index": turn_index,
	}


func is_request_current(expected_session_id: String, expected_event_id: String, expected_serial: int) -> bool:
	return is_active() \
		and _request_pending \
		and expected_session_id == session_id \
		and expected_event_id == event_id \
		and expected_serial == request_serial


func append_actor_turn(actor_turn: Dictionary, source: String, game_tick: int, expected_serial: int) -> Dictionary:
	if not is_active():
		return _error("conversation_session_inactive", "会话已结束，不能提交 ActorTurn。")
	if not _request_pending or expected_serial != request_serial:
		return _error("conversation_response_stale", "ActorTurn request_serial 已失效。")
	if source.strip_edges().is_empty():
		return _error("conversation_actor_source_invalid", "ActorTurn source 不能为空。")
	if game_tick < 0:
		return _error("actor_turn_tick_invalid", "ActorTurn game_tick 不能为负数。")
	if not actor_turn.has("utterance") or not actor_turn["utterance"] is String:
		return _error("conversation_actor_turn_invalid", "ActorTurn 缺少 utterance。")
	var entry: Dictionary = {
		"kind": "actor",
		"turn_index": turn_index,
		"actor_id": actor_id,
		"turn": actor_turn.duplicate(true),
		"source": source,
		"game_tick": game_tick,
	}
	transcript.append(entry)
	turn_index += 1
	_request_pending = false
	return {"ok": true, "entry": entry.duplicate(true), "turn_index": turn_index}


func cancel_pending_request(reason: String) -> void:
	if not _request_pending:
		return
	request_serial += 1
	_request_pending = false
	if not reason.strip_edges().is_empty():
		_end_reason = reason.strip_edges()


func end_session(reason: String) -> Dictionary:
	if status == STATUS_ENDED:
		return {"ok": true, "already_ended": true}
	var normalized_reason: String = reason.strip_edges()
	if normalized_reason.is_empty():
		return _error("conversation_end_reason_invalid", "结束 ConversationSession 必须提供原因。")
	request_serial += 1
	_request_pending = false
	status = STATUS_ENDED
	_end_reason = normalized_reason
	return {"ok": true, "already_ended": false}


func create_context_snapshot() -> Dictionary:
	return {
		"session_id": session_id,
		"channel": channel,
		"event_id": event_id,
		"actor_id": actor_id,
		"status": status,
		"turn_index": turn_index,
		"request_serial": request_serial,
		"transcript": transcript.duplicate(true),
	}


func create_archive_record() -> Dictionary:
	var record: Dictionary = create_context_snapshot()
	record["end_reason"] = _end_reason
	return record


func create_snapshot() -> Dictionary:
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": "conversation_session",
		"session_id": session_id,
		"channel": channel,
		"event_id": event_id,
		"actor_id": actor_id,
		"status": status,
		"turn_index": turn_index,
		"request_serial": request_serial,
		"request_pending": _request_pending,
		"end_reason": _end_reason,
		"transcript": transcript.duplicate(true),
	}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
