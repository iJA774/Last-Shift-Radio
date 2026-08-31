class_name PhoneCloseup
extends Control
## 电话近景是 PhoneSystem 与 committed ConversationSession 的只读展示层。
## 它只发出玩家意图；不保存 Actor memory、claim、Fact、Task 或任何世界权威状态。

signal return_requested()
signal answer_requested()
signal player_turn_requested(text: String)
signal hang_up_requested()

var _phone_system: RefCounted = null
var _conversation_snapshot: Dictionary = {}
var _is_phone_connected: bool = false
var _are_actions_enabled: bool = true
var _actions_disabled_reason: String = ""
var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true
var _text_speed_multiplier: float = 1.0
var _typewriter_tween: Tween = null
var _typewriter_full_text: String = ""
var _is_agent_request_pending: bool = false
var _last_interaction_error: String = ""

const DIALOGUE_CHARACTERS_PER_SECOND: float = 34.0

@onready var _phone_state_label: Label = %PhoneStateLabel
@onready var _caller_label: Label = %CallerLabel
@onready var _dialogue_hint_label: Label = %DialogueHintLabel
@onready var _dialogue_scroll: ScrollContainer = %DialogueScroll
@onready var _conversation_overlay: Control = %ConversationOverlay
@onready var _turn_status_label: Label = %TurnStatusLabel
@onready var _player_input: LineEdit = %PlayerInput
@onready var _send_button: Button = %SendButton
@onready var _answer_button: Button = %AnswerButton
@onready var _hang_up_button: Button = %HangUpButton
@onready var _return_button: Button = %BackButton


func _ready() -> void:
	_connect_phone_system_if_possible()
	_configure_ambient_fx()
	_refresh()


func _exit_tree() -> void:
	_stop_typewriter()
	_disconnect_phone_system()


func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	var validation: Dictionary = _validate_phone_system(phone_system)
	if not bool(validation["ok"]):
		return validation
	_disconnect_phone_system()
	_phone_system = phone_system
	_connect_phone_system_if_possible()
	_refresh()
	return {"ok": true}


## GameScreen 只把 InteractionCoordinator 的 committed presentation snapshot 传进来。
## 未被 stale guard 接受的模型响应不会进入这个 snapshot，因此无法成为“幽灵台词”。
func set_conversation_snapshot(snapshot: Dictionary) -> Dictionary:
	if not snapshot.is_empty():
		for field_name: String in ["session_id", "event_id", "actor_id", "status", "turn_index", "request_serial", "transcript"]:
			if not snapshot.has(field_name):
				return _make_error("会话展示快照缺少字段：%s。" % field_name)
		if not snapshot["transcript"] is Array:
			return _make_error("会话展示快照 transcript 必须是数组。")
	_conversation_snapshot = snapshot.duplicate(true)
	_last_interaction_error = ""
	_refresh()
	return {"ok": true}


func clear_conversation_snapshot() -> void:
	_conversation_snapshot.clear()
	_is_agent_request_pending = false
	_last_interaction_error = ""
	if is_node_ready():
		_player_input.clear()
	_refresh()


func set_agent_request_pending(is_pending: bool) -> void:
	_is_agent_request_pending = is_pending
	if is_node_ready():
		_refresh()


func set_interaction_error(message: String) -> void:
	_last_interaction_error = message.strip_edges()
	_is_agent_request_pending = false
	if is_node_ready():
		_refresh()


func set_actions_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用电话操作时必须提供中文原因。")
	_are_actions_enabled = is_enabled
	_actions_disabled_reason = "" if is_enabled else disabled_reason.strip_edges()
	_refresh()
	return {"ok": true}


func set_return_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用返回工作室总览时必须提供中文原因。")
	_is_return_enabled = is_enabled
	_refresh_return_button(disabled_reason)
	return {"ok": true}


func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null or not ambient_fx.has_method(&"set_motion_enabled"):
		return _make_error("环境效果组件缺少 set_motion_enabled() 接口。")
	ambient_fx.call(&"set_motion_enabled", is_enabled)
	return {"ok": true}


func set_text_speed_multiplier(multiplier: float) -> Dictionary:
	if is_nan(multiplier) or is_inf(multiplier) or multiplier < 0.25 or multiplier > 4.0:
		return _make_error("逐字文字速度必须在 0.25 到 4.0 之间。")
	_text_speed_multiplier = multiplier
	if not _typewriter_full_text.is_empty():
		_start_typewriter(_typewriter_full_text)
	return {"ok": true, "text_speed": _text_speed_multiplier}


func get_text_speed_multiplier() -> float:
	return _text_speed_multiplier


func get_text_presentation_snapshot() -> Dictionary:
	return {
		"text_speed": _text_speed_multiplier,
		"is_revealing": _typewriter_tween != null and _typewriter_tween.is_valid() and _typewriter_tween.is_running(),
		"text_length": _typewriter_full_text.length(),
	}


func stop_text_presentation() -> Dictionary:
	_stop_typewriter()
	return {"ok": true}


func focus_player_input() -> void:
	if is_node_ready() and not _player_input.editable:
		return
	if is_node_ready():
		_player_input.grab_focus()


func _validate_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("线路暂时不可用。")
	for method_name: String in ["get_state_name", "get_active_call_snapshot"]:
		if not phone_system.has_method(method_name):
			return _make_error("线路暂时不可用。")
	if not phone_system.has_signal(&"state_changed"):
		return _make_error("线路暂时不可用。")
	return {"ok": true}


func _connect_phone_system_if_possible() -> void:
	if _phone_system == null or not is_node_ready() or _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	var result: Error = _phone_system.connect(&"state_changed", callback)
	if result != OK:
		push_error("[电话][state_connect_failed] 无法连接 PhoneSystem.state_changed，错误码=%d。" % result)
		return
	_is_phone_connected = true


func _disconnect_phone_system() -> void:
	if _phone_system == null or not _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	if _phone_system.is_connected(&"state_changed", callback):
		_phone_system.disconnect(&"state_changed", callback)
	_is_phone_connected = false


func _on_phone_state_changed(_previous_state: int, _current_state: int, _event_id: String) -> void:
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	if _phone_system == null:
		_phone_state_label.text = "线路未接通"
		_caller_label.text = "暂无来电"
		_set_dialogue_text("拿起听筒后，对方的声音会显示在这里。")
		_conversation_overlay.visible = false
		_set_action_availability("", false)
		return
	var state_value: Variant = _phone_system.call(&"get_state_name")
	if not state_value is String:
		_phone_state_label.text = "线路中断"
		_caller_label.text = "来电信息暂不可用"
		_set_dialogue_text("线路暂时没有回应。")
		_conversation_overlay.visible = false
		_set_action_availability("", false)
		return
	var state_name: String = String(state_value)
	_phone_state_label.text = _format_state(state_name)
	_refresh_caller_snapshot()
	_refresh_transcript(state_name)
	_refresh_turn_controls(state_name)
	_set_action_availability(state_name, _are_actions_enabled)


func _refresh_caller_snapshot() -> void:
	var snapshot_value: Variant = _phone_system.call(&"get_active_call_snapshot")
	if not snapshot_value is Dictionary:
		_caller_label.text = "来电信息暂不可用"
		return
	var snapshot: Dictionary = snapshot_value as Dictionary
	if snapshot.is_empty():
		_caller_label.text = "暂无来电"
		return
	var caller_name: Variant = snapshot.get("caller_name")
	var caller_number: Variant = snapshot.get("caller_number")
	if not caller_name is String or not caller_number is String:
		_caller_label.text = "来电信息不完整"
		return
	_caller_label.text = "登记名：%s    号码：%s" % [String(caller_name), String(caller_number)]


func _refresh_transcript(state_name: String) -> void:
	if not _conversation_snapshot.is_empty():
		var transcript: Array = _conversation_snapshot.get("transcript", []) as Array
		if not transcript.is_empty():
			var lines: PackedStringArray = []
			for raw_entry: Variant in transcript:
				if not raw_entry is Dictionary:
					continue
				var entry: Dictionary = raw_entry as Dictionary
				match String(entry.get("kind", "")):
					"player":
						lines.append("你：%s" % String(entry.get("text", "")))
					"actor":
						var actor_turn: Dictionary = entry.get("turn", {}) as Dictionary
						lines.append("来电者：%s" % String(actor_turn.get("utterance", "")))
			var transcript_text: String = "\n\n".join(lines)
			_set_dialogue_text(transcript_text, true)
			call_deferred("_scroll_transcript_to_bottom")
			return
	match state_name:
		"RINGING":
			_set_dialogue_text("铃声响起。你可以接听，或等它停下。")
		"CONNECTED":
			_set_dialogue_text("线路已接通。正在建立对话会话……")
		"DIALOGUE_CHOICE":
			_set_dialogue_text("线路里传来呼吸与底噪。你可以直接开口询问。")
		_:
			_set_dialogue_text("当前没有可操作的接通线路。")


func _refresh_turn_controls(state_name: String) -> void:
	var has_session: bool = not _conversation_snapshot.is_empty() and String(_conversation_snapshot.get("status", "")) == "active"
	_conversation_overlay.visible = state_name == "DIALOGUE_CHOICE" and has_session
	if not _conversation_overlay.visible:
		_turn_status_label.text = ""
		return
	if not _last_interaction_error.is_empty():
		_turn_status_label.text = "线路反馈：%s" % _last_interaction_error
	elif _is_agent_request_pending:
		_turn_status_label.text = "对方正在回应……"
	else:
		_turn_status_label.text = "输入你想说的话。对方可能拒绝、追问或主动结束通话。"


func _set_dialogue_text(text_value: String, use_typewriter: bool = false) -> void:
	if _dialogue_hint_label == null:
		return
	if text_value == _typewriter_full_text and _dialogue_hint_label.text == text_value:
		return
	_stop_typewriter()
	_typewriter_full_text = text_value
	_dialogue_hint_label.text = text_value
	_dialogue_hint_label.visible_ratio = 1.0
	if use_typewriter and not text_value.is_empty():
		_start_typewriter(text_value)


func _start_typewriter(text_value: String) -> void:
	if _dialogue_hint_label == null:
		return
	_stop_typewriter()
	_typewriter_full_text = text_value
	_dialogue_hint_label.text = text_value
	_dialogue_hint_label.visible_ratio = 0.0
	var duration: float = maxf(0.05, float(text_value.length()) / (DIALOGUE_CHARACTERS_PER_SECOND * _text_speed_multiplier))
	_typewriter_tween = create_tween()
	_typewriter_tween.tween_property(_dialogue_hint_label, "visible_ratio", 1.0, duration)


func _stop_typewriter() -> void:
	if _typewriter_tween != null and _typewriter_tween.is_valid():
		_typewriter_tween.kill()
	_typewriter_tween = null
	if _dialogue_hint_label != null:
		_dialogue_hint_label.visible_ratio = 1.0


func _scroll_transcript_to_bottom() -> void:
	if not is_node_ready():
		return
	var scroll_bar: VScrollBar = _dialogue_scroll.get_v_scroll_bar()
	if scroll_bar != null:
		scroll_bar.value = scroll_bar.max_value


func _set_action_availability(state_name: String, allow_actions: bool) -> void:
	_answer_button.disabled = not allow_actions or state_name != "RINGING"
	_answer_button.tooltip_text = _action_tooltip(_answer_button.disabled, "仅在电话响铃时可以接听。")
	var has_session: bool = not _conversation_snapshot.is_empty() and String(_conversation_snapshot.get("status", "")) == "active"
	var can_send: bool = allow_actions and state_name == "DIALOGUE_CHOICE" and has_session and not _is_agent_request_pending
	_send_button.disabled = not can_send
	_player_input.editable = can_send
	if not allow_actions:
		_send_button.tooltip_text = _disabled_tooltip(_actions_disabled_reason)
	elif _is_agent_request_pending:
		_send_button.tooltip_text = "不可用：正在等待对方回应。"
	else:
		_send_button.tooltip_text = _action_tooltip(_send_button.disabled, "发送这一轮 PlayerTurn。")
	_hang_up_button.disabled = not allow_actions or (state_name != "CONNECTED" and state_name != "DIALOGUE_CHOICE")
	_hang_up_button.tooltip_text = _action_tooltip(_hang_up_button.disabled, "结束本次通话。")
	_refresh_return_button()


func _refresh_return_button(disabled_reason: String = "") -> void:
	if not is_node_ready():
		return
	_return_button.disabled = not _is_return_enabled
	if _is_return_enabled:
		_return_button.text = "返回工作室总览"
		_return_button.tooltip_text = "返回工作室总览。"
		return
	_return_button.text = "返回不可用\n当前界面已锁定"
	var reason: String = disabled_reason.strip_edges()
	if reason.is_empty():
		reason = _actions_disabled_reason if not _actions_disabled_reason.is_empty() else "当前界面已锁定。"
	_return_button.tooltip_text = "不可用：%s" % reason


func _configure_ambient_fx() -> void:
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null:
		push_error("[电话][ambient_fx_missing] 缺少 AmbientFx 环境效果组件。")
		return
	if not ambient_fx.has_method(&"set_profile") or not ambient_fx.has_method(&"set_random_seed"):
		push_error("[电话][ambient_fx_contract] AmbientFx 缺少 set_profile() 或 set_random_seed() 接口。")
		return
	ambient_fx.call(&"set_profile", "equipment")
	ambient_fx.call(&"set_random_seed", 199902)
	var result: Dictionary = set_motion_enabled(_is_motion_enabled)
	if not bool(result.get("ok", false)):
		push_error("[电话][ambient_fx_motion] %s" % String(result.get("message", "环境效果初始化失败。")))


func _action_tooltip(is_disabled: bool, enabled_text: String) -> String:
	if is_disabled:
		if not _are_actions_enabled:
			return _disabled_tooltip(_actions_disabled_reason)
		return "不可用：%s" % enabled_text
	return enabled_text


func _disabled_tooltip(reason: String) -> String:
	var normalized_reason: String = reason.strip_edges()
	if normalized_reason.is_empty():
		normalized_reason = "当前无法操作。"
	return "不可用：%s" % normalized_reason


func _format_state(state_name: String) -> String:
	match state_name:
		"IDLE": return "线路待机"
		"RINGING": return "正在响铃"
		"CONNECTED": return "已接通"
		"DIALOGUE_CHOICE": return "正在通话"
		"ENDED": return "通话结束"
		"MISSED": return "漏接"
	return "未知（%s）" % state_name


func _on_back_button_pressed() -> void:
	if _is_return_enabled and not _return_button.disabled:
		return_requested.emit()


func _on_answer_button_pressed() -> void:
	if not _answer_button.disabled:
		answer_requested.emit()


func _on_send_button_pressed() -> void:
	_submit_player_input()


func _on_player_input_text_submitted(_text: String) -> void:
	_submit_player_input()


func _submit_player_input() -> void:
	if _send_button.disabled or not _player_input.editable:
		return
	var text: String = _player_input.text.strip_edges()
	if text.is_empty():
		_turn_status_label.text = "请输入内容后再发送。"
		return
	_player_input.clear()
	player_turn_requested.emit(text)


func _on_hang_up_button_pressed() -> void:
	if not _hang_up_button.disabled:
		hang_up_requested.emit()


func _make_error(message: String) -> Dictionary:
	push_error("[电话][closeup_error] %s" % message)
	return {"ok": false, "message": message}
