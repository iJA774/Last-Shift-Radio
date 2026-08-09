class_name PhoneCloseup
extends Control
## 电话近景是 PhoneSystem 的只读适配器。
## 它只显示公开快照并发出玩家意图，不复制来电、计时或记录状态。

signal return_requested()
signal answer_requested()
signal dialogue_choice_requested()
signal dialogue_option_requested(option_id: String)
signal hang_up_requested()
signal finish_call_requested()

var _phone_system: RefCounted = null
var _story_engine: RefCounted = null
var _dialogue_snapshot: Dictionary = {}
var _is_phone_connected: bool = false
var _is_story_connected: bool = false
var _are_actions_enabled: bool = true
var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true
var _indicator_timer: Timer = null
var _is_indicator_lit: bool = false

@onready var _phone_state_label: Label = %PhoneStateLabel
@onready var _caller_label: Label = %CallerLabel
@onready var _dialogue_hint_label: Label = %DialogueHintLabel
@onready var _dialogue_options: HFlowContainer = %DialogueOptions
@onready var _answer_button: Button = %AnswerButton
@onready var _dialogue_choice_button: Button = %DialogueChoiceButton
@onready var _hang_up_button: Button = %HangUpButton
@onready var _finish_button: Button = %FinishButton
@onready var _return_button: Button = %BackButton
@onready var _phone_indicator_light: TextureRect = $PhoneIndicatorLight


func _ready() -> void:
	_indicator_timer = Timer.new()
	_indicator_timer.one_shot = true
	_indicator_timer.process_callback = Timer.TIMER_PROCESS_IDLE
	_indicator_timer.timeout.connect(_on_indicator_timer_timeout)
	add_child(_indicator_timer)
	_connect_phone_system_if_possible()
	_configure_ambient_fx()
	_refresh()


func _exit_tree() -> void:
	_disconnect_phone_system()
	_disconnect_story_engine()


## 绑定前检查公共只读契约，失败时保留旧的有效绑定。
func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	var validation: Dictionary = _validate_phone_system(phone_system)
	if not bool(validation["ok"]):
		return validation
	_disconnect_phone_system()
	_phone_system = phone_system
	_connect_phone_system_if_possible()
	_refresh()
	return {"ok": true}


## 电话近景只读取当前预制对话快照；选项仍通过 GameScreen 交给 StoryEngine。
func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	if not story_engine.has_method(&"get_active_dialogue_snapshot") or not story_engine.has_signal(&"dialogue_changed"):
		return _make_error("StoryEngine 缺少预制对话展示所需接口。")
	_disconnect_story_engine()
	_story_engine = story_engine
	_connect_story_engine_if_possible()
	_refresh_dialogue_snapshot()
	_refresh()
	return {"ok": true}


## 收束页或系统错误状态可统一禁用意图入口；这不改变 PhoneSystem。
func set_actions_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用电话操作时必须提供中文原因。")
	_are_actions_enabled = is_enabled
	_refresh()
	return {"ok": true}


## 导航锁定属于上层界面状态；电话近景不据此改写任何 PhoneSystem 状态。
func set_return_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用返回工作室总览时必须提供中文原因。")
	_is_return_enabled = is_enabled
	_refresh_return_button(disabled_reason)
	return {"ok": true}


## 减少动态只静止环境层和设备指示灯，不接触电话状态机或来电记录。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null or not ambient_fx.has_method(&"set_motion_enabled"):
		return _make_error("环境效果组件缺少 set_motion_enabled() 接口。")
	ambient_fx.call(&"set_motion_enabled", is_enabled)
	_refresh_phone_indicator()
	return {"ok": true}


func _validate_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("电话系统实例不能为空。")
	var required_methods: PackedStringArray = ["get_state_name", "get_active_call_snapshot"]
	for method_name: String in required_methods:
		if not phone_system.has_method(method_name):
			return _make_error("电话系统缺少 %s() 公开接口。" % method_name)
	if not phone_system.has_signal(&"state_changed"):
		return _make_error("电话系统缺少 state_changed 信号。")
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


func _connect_story_engine_if_possible() -> void:
	if _story_engine == null or not is_node_ready() or _is_story_connected:
		return
	var callback: Callable = Callable(self, "_on_dialogue_changed")
	var result: Error = _story_engine.connect(&"dialogue_changed", callback)
	if result != OK:
		push_error("[电话][dialogue_connect_failed] 无法连接 StoryEngine.dialogue_changed，错误码=%d。" % result)
		return
	_is_story_connected = true


func _disconnect_story_engine() -> void:
	if _story_engine == null or not _is_story_connected:
		return
	var callback: Callable = Callable(self, "_on_dialogue_changed")
	if _story_engine.is_connected(&"dialogue_changed", callback):
		_story_engine.disconnect(&"dialogue_changed", callback)
	_is_story_connected = false


func _on_phone_state_changed(_previous_state: int, _current_state: int, _event_id: String) -> void:
	_refresh()


func _on_dialogue_changed(snapshot: Dictionary) -> void:
	_dialogue_snapshot = snapshot.duplicate(true)
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	if _phone_system == null:
		_phone_state_label.text = "电话状态：系统未连接"
		_caller_label.text = "来显：等待电话系统提供活动线路。"
		_dialogue_hint_label.text = "对话：当前不能提交电话操作。"
		_set_action_availability("", false)
		_refresh_phone_indicator()
		return

	var state_value: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_value) != TYPE_STRING:
		_phone_state_label.text = "电话状态：数据无效"
		_caller_label.text = "来显：电话系统未返回有效状态。"
		_dialogue_hint_label.text = "对话：状态数据无效，已禁用操作。"
		push_error("[电话][invalid_state] PhoneSystem.get_state_name() 必须返回 String。")
		_set_action_availability("", false)
		_refresh_phone_indicator()
		return

	var state_name: String = state_value
	_phone_state_label.text = "电话状态：%s" % _format_state(state_name)
	_refresh_caller_snapshot()
	_refresh_dialogue_hint(state_name)
	_refresh_dialogue_options(state_name)
	_set_action_availability(state_name, _are_actions_enabled)
	_refresh_phone_indicator()


func _refresh_caller_snapshot() -> void:
	var snapshot_value: Variant = _phone_system.call(&"get_active_call_snapshot")
	if not snapshot_value is Dictionary:
		_caller_label.text = "来显：电话系统未返回有效快照。"
		push_error("[电话][invalid_snapshot] PhoneSystem.get_active_call_snapshot() 必须返回 Dictionary。")
		return
	var snapshot: Dictionary = snapshot_value as Dictionary
	if snapshot.is_empty():
		_caller_label.text = "来显：当前没有活动线路。"
		return
	var caller_name: Variant = snapshot.get("caller_name")
	var caller_number: Variant = snapshot.get("caller_number")
	var event_id: Variant = snapshot.get("event_id")
	if not caller_name is String or not caller_number is String or not event_id is String:
		_caller_label.text = "来显：活动线路数据不完整。"
		push_error("[电话][invalid_snapshot_fields] 活动线路快照缺少字符串来显字段。")
		return
	_caller_label.text = "来显：%s\n号码：%s\n线路编号：%s" % [
		String(caller_name), String(caller_number), String(event_id),
	]


func _refresh_dialogue_hint(state_name: String) -> void:
	if not _dialogue_snapshot.is_empty():
		var speaker: String = String(_dialogue_snapshot.get("speaker", "来电者"))
		var text: String = String(_dialogue_snapshot.get("text", ""))
		if not text.strip_edges().is_empty():
			var suffix: String = "\n\n请选择回应。"
			if bool(_dialogue_snapshot.get("is_terminal", false)):
				suffix = "\n\n本轮对话结束，可结束通话。"
			_dialogue_hint_label.text = "%s：\n%s%s" % [speaker, text, suffix]
			return
	match state_name:
		"RINGING":
			_dialogue_hint_label.text = "线路正在响铃。接听或等待系统处理；不能主动外拨。"
		"CONNECTED":
			_dialogue_hint_label.text = "线路已接通。可以请求进入一轮预制选择、主动挂断或结束通话。"
		"DIALOGUE_CHOICE":
			_dialogue_hint_label.text = "正在等待本轮选择。时钟继续流动，02:00 可由系统中断。"
		_:
			_dialogue_hint_label.text = "当前没有可操作的接通线路。"


func _refresh_dialogue_options(state_name: String) -> void:
	for child: Node in _dialogue_options.get_children():
		child.queue_free()
	if state_name != "DIALOGUE_CHOICE" or _dialogue_snapshot.is_empty() or bool(_dialogue_snapshot.get("is_terminal", false)):
		return
	var raw_options: Variant = _dialogue_snapshot.get("options", [])
	if not raw_options is Array:
		push_error("[电话][invalid_dialogue_options] StoryEngine 对话快照 options 必须是 Array。")
		return
	for raw_option: Variant in raw_options as Array:
		if not raw_option is Dictionary:
			push_error("[电话][invalid_dialogue_option] StoryEngine 对话快照包含非对象选项。")
			continue
		var option: Dictionary = raw_option as Dictionary
		if typeof(option.get("id")) != TYPE_STRING or typeof(option.get("text")) != TYPE_STRING:
			push_error("[电话][invalid_dialogue_option] StoryEngine 对话选项缺少字符串 id 或 text。")
			continue
		var option_id: String = String(option["id"])
		var option_text: String = String(option["text"])
		if option_id.is_empty() or option_text.strip_edges().is_empty():
			push_error("[电话][invalid_dialogue_option] StoryEngine 对话选项不能为空。")
			continue
		var button: Button = Button.new()
		button.text = option_text
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.custom_minimum_size = Vector2(260.0, 70.0)
		button.disabled = not _are_actions_enabled
		button.tooltip_text = "不可用：当前界面已由系统锁定。" if button.disabled else "选择此回应。"
		button.pressed.connect(_on_dialogue_option_button_pressed.bind(option_id))
		_dialogue_options.add_child(button)


func _set_action_availability(state_name: String, allow_actions: bool) -> void:
	_answer_button.disabled = not allow_actions or state_name != "RINGING"
	_answer_button.tooltip_text = _action_tooltip(_answer_button.disabled, "仅在电话响铃时可以接听。")
	var has_completed_dialogue: bool = not _dialogue_snapshot.is_empty() and bool(_dialogue_snapshot.get("is_terminal", false))
	_dialogue_choice_button.disabled = not allow_actions or state_name != "CONNECTED" or has_completed_dialogue
	if has_completed_dialogue:
		_dialogue_choice_button.text = "对话已结束\n请结束通话"
		_dialogue_choice_button.tooltip_text = "不可用：本通电话的预制对话已经结束，请结束通话或主动挂断。"
	else:
		_dialogue_choice_button.text = "开始预制对话" if state_name == "CONNECTED" else "对话选项见上方"
		_dialogue_choice_button.tooltip_text = _action_tooltip(_dialogue_choice_button.disabled, "仅在已接通时可以开始预制对话。")
	_hang_up_button.disabled = not allow_actions or (state_name != "CONNECTED" and state_name != "DIALOGUE_CHOICE")
	_hang_up_button.tooltip_text = _action_tooltip(_hang_up_button.disabled, "仅在已接通或对话选择时可主动挂断。")
	_finish_button.disabled = not allow_actions or state_name != "CONNECTED"
	_finish_button.tooltip_text = _action_tooltip(_finish_button.disabled, "仅在已接通时可以正常结束通话。")


func _refresh_return_button(disabled_reason: String = "") -> void:
	if not is_node_ready():
		return
	_return_button.disabled = not _is_return_enabled
	if _is_return_enabled:
		_return_button.text = "返回工作室总览"
		_return_button.tooltip_text = "返回工作室总览。"
		return
	# 按钮空间固定，完整原因只放在 tooltip；可见短文案仍明确说明已锁定。
	_return_button.text = "返回不可用\n当前界面已锁定"
	_return_button.tooltip_text = "不可用：%s" % disabled_reason


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


func _refresh_phone_indicator() -> void:
	if _phone_indicator_light == null:
		push_error("[电话][indicator_missing] 缺少电话线路指示灯贴图层。")
		return
	var is_ringing: bool = false
	if _phone_system != null:
		var state_value: Variant = _phone_system.call(&"get_state_name")
		is_ringing = typeof(state_value) == TYPE_STRING and String(state_value) == "RINGING"
	if not is_ringing:
		_stop_indicator_blink()
		_set_indicator_lit(false)
		return
	if not _is_motion_enabled:
		_stop_indicator_blink()
		_set_indicator_lit(true)
		return
	if _indicator_timer == null or not _indicator_timer.is_stopped():
		return
	_set_indicator_lit(true)
	_indicator_timer.wait_time = 0.34
	_indicator_timer.start()


func _on_indicator_timer_timeout() -> void:
	if _phone_system == null or not _is_motion_enabled:
		return
	var state_value: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_value) != TYPE_STRING or String(state_value) != "RINGING":
		_set_indicator_lit(false)
		return
	_set_indicator_lit(not _is_indicator_lit)
	if _indicator_timer == null:
		return
	_indicator_timer.wait_time = 0.16 if not _is_indicator_lit else 0.34
	_indicator_timer.start()


func _stop_indicator_blink() -> void:
	if _indicator_timer != null:
		_indicator_timer.stop()


func _set_indicator_lit(is_lit: bool) -> void:
	_is_indicator_lit = is_lit
	if _phone_indicator_light != null:
		_phone_indicator_light.visible = is_lit


func _action_tooltip(is_disabled: bool, enabled_text: String) -> String:
	if is_disabled:
		if not _are_actions_enabled:
			return "不可用：当前界面已由系统锁定。"
		return "不可用：%s" % enabled_text
	return enabled_text


func _format_state(state_name: String) -> String:
	match state_name:
		"IDLE":
			return "空闲"
		"RINGING":
			return "正在响铃"
		"CONNECTED":
			return "已接通"
		"DIALOGUE_CHOICE":
			return "等待选择"
		"ENDED":
			return "通话结束"
		"MISSED":
			return "漏接"
	return "未知（%s）" % state_name


func _on_back_button_pressed() -> void:
	if _is_return_enabled and not _return_button.disabled:
		return_requested.emit()


func _on_answer_button_pressed() -> void:
	if not _answer_button.disabled:
		answer_requested.emit()


func _on_dialogue_choice_button_pressed() -> void:
	if not _dialogue_choice_button.disabled:
		dialogue_choice_requested.emit()


func _on_dialogue_option_button_pressed(option_id: String) -> void:
	if _are_actions_enabled and not option_id.strip_edges().is_empty():
		dialogue_option_requested.emit(option_id)


func _refresh_dialogue_snapshot() -> void:
	if _story_engine == null:
		_dialogue_snapshot = {}
		return
	var result: Variant = _story_engine.call(&"get_active_dialogue_snapshot")
	if result is Dictionary:
		_dialogue_snapshot = (result as Dictionary).duplicate(true)
		return
	_dialogue_snapshot = {}
	push_error("[电话][invalid_dialogue_snapshot] StoryEngine.get_active_dialogue_snapshot() 必须返回 Dictionary。")


func _on_hang_up_button_pressed() -> void:
	if not _hang_up_button.disabled:
		hang_up_requested.emit()


func _on_finish_button_pressed() -> void:
	if not _finish_button.disabled:
		finish_call_requested.emit()


func _make_error(message: String) -> Dictionary:
	push_error("[电话][closeup_error] %s" % message)
	return {"ok": false, "message": message}
