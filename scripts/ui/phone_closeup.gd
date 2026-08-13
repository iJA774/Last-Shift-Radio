class_name PhoneCloseup
extends Control
## 电话近景是 PhoneSystem 的只读适配器。
## 它只显示公开快照并发出玩家意图，不复制来电、计时或记录状态。

signal return_requested()
signal answer_requested()
signal dialogue_choice_requested()
signal dialogue_option_requested(option_id: String)
signal hang_up_requested()
# 挂断按键在终止台词后提交既有的正常结束意图，保留来电记录 outcome 语义。
signal finish_call_requested()

var _phone_system: RefCounted = null
var _story_engine: RefCounted = null
var _dialogue_snapshot: Dictionary = {}
var _is_phone_connected: bool = false
var _is_story_connected: bool = false
var _are_actions_enabled: bool = true
var _actions_disabled_reason: String = ""
var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true
var _text_speed_multiplier: float = 1.0
var _typewriter_tween: Tween = null
var _typewriter_full_text: String = ""
# 此标志只控制当前权威对白的呈现时机；不保存、不修改剧情或电话状态。
var _are_dialogue_options_revealed: bool = false

const DIALOGUE_CHARACTERS_PER_SECOND: float = 34.0

@onready var _phone_state_label: Label = %PhoneStateLabel
@onready var _caller_label: Label = %CallerLabel
@onready var _dialogue_hint_label: Label = %DialogueHintLabel
@onready var _dialogue_scroll: ScrollContainer = %DialogueScroll
@onready var _dialogue_options: VBoxContainer = %DialogueOptions
@onready var _dialogue_choice_overlay: Control = %DialogueChoiceOverlay
@onready var _answer_button: Button = %AnswerButton
@onready var _dialogue_choice_button: Button = %DialogueChoiceButton
@onready var _hang_up_button: Button = %HangUpButton
@onready var _return_button: Button = %BackButton


func _ready() -> void:
	_connect_phone_system_if_possible()
	_configure_ambient_fx()
	_refresh()


func _exit_tree() -> void:
	_stop_typewriter()
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
		return _make_error("对话内容暂时不可用。")
	if not story_engine.has_method(&"get_active_dialogue_snapshot") or not story_engine.has_signal(&"dialogue_changed"):
		return _make_error("对话内容暂时不可用。")
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
	_actions_disabled_reason = "" if is_enabled else disabled_reason.strip_edges()
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
	return {"ok": true}


## 此倍率只作用于 DialogueHintLabel 的逐字展示；它不推进 StoryEngine、
## GameClock 或 PhoneSystem。设置变更时从完整当前文本安全重启展示。
func set_text_speed_multiplier(multiplier: float) -> Dictionary:
	if is_nan(multiplier) or is_inf(multiplier) or multiplier < 0.25 or multiplier > 4.0:
		return _make_error("逐字文字速度必须在 0.25 到 4.0 之间。")
	_text_speed_multiplier = multiplier
	if not _typewriter_full_text.is_empty():
		_start_typewriter(_typewriter_full_text)
	return {"ok": true, "text_speed": _text_speed_multiplier}


func get_text_speed_multiplier() -> float:
	return _text_speed_multiplier


## 只读展示状态供设置验收使用；不复制任何剧情状态。
func get_text_presentation_snapshot() -> Dictionary:
	return {
		"text_speed": _text_speed_multiplier,
		"is_revealing": _typewriter_tween != null and _typewriter_tween.is_valid() and _typewriter_tween.is_running(),
		"text_length": _typewriter_full_text.length(),
	}


func stop_text_presentation() -> Dictionary:
	_stop_typewriter()
	return {"ok": true}


func _validate_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("线路暂时不可用。")
	var required_methods: PackedStringArray = ["get_state_name", "get_active_call_snapshot"]
	for method_name: String in required_methods:
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
	_are_dialogue_options_revealed = false
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	if _phone_system == null:
		_phone_state_label.text = "线路未接通"
		_caller_label.text = "暂无来电"
		_set_dialogue_hint_text("拿起听筒后，对方的声音会显示在这里。")
		_set_action_availability("", false)
		return

	var state_value: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_value) != TYPE_STRING:
		_phone_state_label.text = "线路中断"
		_caller_label.text = "来电信息暂不可用"
		_set_dialogue_hint_text("线路暂时没有回应。")
		push_error("[电话][invalid_state] PhoneSystem.get_state_name() 必须返回 String。")
		_set_action_availability("", false)
		return

	var state_name: String = state_value
	_phone_state_label.text = _format_state(state_name)
	_refresh_caller_snapshot()
	_refresh_dialogue_hint(state_name)
	_refresh_dialogue_options(state_name)
	_set_action_availability(state_name, _are_actions_enabled)


func _refresh_caller_snapshot() -> void:
	var snapshot_value: Variant = _phone_system.call(&"get_active_call_snapshot")
	if not snapshot_value is Dictionary:
		_caller_label.text = "来电信息暂不可用"
		push_error("[电话][invalid_snapshot] PhoneSystem.get_active_call_snapshot() 必须返回 Dictionary。")
		return
	var snapshot: Dictionary = snapshot_value as Dictionary
	if snapshot.is_empty():
		_caller_label.text = "暂无来电"
		return
	var caller_name: Variant = snapshot.get("caller_name")
	var caller_number: Variant = snapshot.get("caller_number")
	if not caller_name is String or not caller_number is String:
		_caller_label.text = "来电信息不完整"
		push_error("[电话][invalid_snapshot_fields] 活动线路快照缺少字符串来显字段。")
		return
	_caller_label.text = "登记名：%s    号码：%s" % [String(caller_name), String(caller_number)]


func _refresh_dialogue_hint(state_name: String) -> void:
	if not _dialogue_snapshot.is_empty():
		var speaker: String = String(_dialogue_snapshot.get("speaker", "来电者"))
		var text: String = String(_dialogue_snapshot.get("text", ""))
		if not text.strip_edges().is_empty():
			var display_text: String = "%s：\n%s" % [speaker, text]
			# 仅终止节点是 StoryEngine 的“本轮对话完成”权威语义。全量设置文本而
			# 非 append，既避免重复标记，也不会把中途挂断或 02:00 打断伪装成完成。
			if bool(_dialogue_snapshot.get("is_terminal", false)):
				display_text += "\n[ 对话结束 ]"
			_set_dialogue_hint_text(display_text, true)
			return
	match state_name:
		"RINGING":
			_set_dialogue_hint_text("铃声响起。你可以接听，或等它停下。")
		"CONNECTED":
			_set_dialogue_hint_text("线路已接通。点击面板上的“继续对话”。")
		"DIALOGUE_CHOICE":
			_set_dialogue_hint_text("对方正在等待你的回应。")
		_:
			_set_dialogue_hint_text("当前没有可操作的接通线路。")


func _set_dialogue_hint_text(text_value: String, use_typewriter: bool = false) -> void:
	if _dialogue_hint_label == null:
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


func _refresh_dialogue_options(state_name: String) -> void:
	for child: Node in _dialogue_options.get_children():
		child.queue_free()
	_dialogue_choice_overlay.visible = false
	_dialogue_scroll.visible = true
	if state_name != "DIALOGUE_CHOICE" or not _are_dialogue_options_revealed or _dialogue_snapshot.is_empty() or bool(_dialogue_snapshot.get("is_terminal", false)):
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
		# 分支仍由稳定 option_id 提交；选择区独立于通话面板，使用屏幕中央纵向长条。
		button.custom_minimum_size = Vector2(0.0, 48.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.add_theme_color_override(&"font_color", Color(0.46, 0.96, 0.60, 1.0))
		button.add_theme_color_override(&"font_hover_color", Color(0.72, 1.0, 0.76, 1.0))
		button.add_theme_color_override(&"font_pressed_color", Color(0.25, 0.76, 0.40, 1.0))
		button.add_theme_color_override(&"font_disabled_color", Color(0.30, 0.47, 0.34, 1.0))
		button.add_theme_color_override(&"font_outline_color", Color(0.02, 0.12, 0.05, 1.0))
		button.add_theme_constant_override(&"outline_size", 2)
		_style_dialogue_choice_button(button)
		button.disabled = not _are_actions_enabled
		button.tooltip_text = _disabled_tooltip(_actions_disabled_reason) if button.disabled else "选择此回应。"
		button.pressed.connect(_on_dialogue_option_button_pressed.bind(option_id))
		_dialogue_options.add_child(button)
	var has_options: bool = _dialogue_options.get_child_count() > 0
	# 选择区固定在正文下方，既不遮挡说话内容，也不改变权威对话状态。
	_dialogue_choice_overlay.visible = has_options
	_dialogue_scroll.visible = true


## 分支选择使用明确的横向长条而非只靠绿色文字；各状态仍保留可见反馈。
func _style_dialogue_choice_button(button: Button) -> void:
	button.add_theme_stylebox_override(&"normal", _make_choice_style(Color(0.018, 0.10, 0.045, 0.94), Color(0.18, 0.72, 0.36, 0.82)))
	button.add_theme_stylebox_override(&"hover", _make_choice_style(Color(0.035, 0.20, 0.085, 0.98), Color(0.43, 1.0, 0.60, 1.0)))
	button.add_theme_stylebox_override(&"pressed", _make_choice_style(Color(0.012, 0.055, 0.025, 1.0), Color(0.22, 0.84, 0.42, 1.0)))
	button.add_theme_stylebox_override(&"disabled", _make_choice_style(Color(0.018, 0.045, 0.027, 0.72), Color(0.18, 0.32, 0.22, 0.82)))


func _make_choice_style(background_color: Color, border_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background_color
	style.border_color = border_color
	style.set_border_width_all(2)
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_left = 5
	style.corner_radius_bottom_right = 5
	style.content_margin_left = 24.0
	style.content_margin_right = 24.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 5.0
	return style


func _set_action_availability(state_name: String, allow_actions: bool) -> void:
	_answer_button.disabled = not allow_actions or state_name != "RINGING"
	_answer_button.tooltip_text = _action_tooltip(_answer_button.disabled, "仅在电话响铃时可以接听。")
	var has_completed_dialogue: bool = not _dialogue_snapshot.is_empty() and bool(_dialogue_snapshot.get("is_terminal", false))
	var can_reveal_options: bool = state_name == "DIALOGUE_CHOICE" and not _are_dialogue_options_revealed and not _dialogue_snapshot.is_empty() and not has_completed_dialogue
	_dialogue_choice_button.disabled = not allow_actions or (state_name != "CONNECTED" and not can_reveal_options) or has_completed_dialogue
	if not allow_actions:
		_dialogue_choice_button.tooltip_text = _disabled_tooltip(_actions_disabled_reason)
	elif has_completed_dialogue:
		_dialogue_choice_button.tooltip_text = "不可用：请挂断电话。"
	else:
		_dialogue_choice_button.tooltip_text = _action_tooltip(_dialogue_choice_button.disabled, "继续听对方说话，或作出回应。")
	_hang_up_button.disabled = not allow_actions or (state_name != "CONNECTED" and state_name != "DIALOGUE_CHOICE")
	var hang_up_hint: String = "结束本次通话。" if has_completed_dialogue else "仅在已接通或对话选择时可主动挂断。"
	_hang_up_button.tooltip_text = _action_tooltip(_hang_up_button.disabled, hang_up_hint)


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
		"IDLE":
			return "线路待机"
		"RINGING":
			return "正在响铃"
		"CONNECTED":
			return "已接通"
		"DIALOGUE_CHOICE":
			return "正在通话"
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


## 仅由 GameScreen 在已确认的 DIALOGUE_CHOICE 状态下调用；这不是剧情状态。
func reveal_dialogue_options() -> Dictionary:
	if _phone_system == null or _dialogue_snapshot.is_empty() or bool(_dialogue_snapshot.get("is_terminal", false)):
		return {"ok": false, "message": "当前没有可回应的内容。"}
	var state_value: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_value) != TYPE_STRING or String(state_value) != "DIALOGUE_CHOICE":
		return {"ok": false, "message": "当前不能回应。"}
	if _are_dialogue_options_revealed:
		return {"ok": false, "message": "回应已经显示。"}
	_are_dialogue_options_revealed = true
	_refresh_dialogue_options(String(state_value))
	_set_action_availability(String(state_value), _are_actions_enabled)
	return {"ok": true}


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
		if _is_active_dialogue_terminal():
			finish_call_requested.emit()
			return
		hang_up_requested.emit()


func _is_active_dialogue_terminal() -> bool:
	return not _dialogue_snapshot.is_empty() and bool(_dialogue_snapshot.get("is_terminal", false))


func _make_error(message: String) -> Dictionary:
	push_error("[电话][closeup_error] %s" % message)
	return {"ok": false, "message": message}
