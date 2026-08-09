class_name GlobalStatus
extends PanelContainer
## 所有固定视图共用的状态条。
##
## 它只读取整数游戏 tick 和 PhoneSystem 的只读状态；点击来电提示只请求
## GameScreen 导航，绝不在这里接听或修改线路状态。工作状态由 GameScreen
## 传入派生快照，本控件只显示与实际倍率一致的中文说明。

signal phone_view_requested

var _phone_system: RefCounted = null
var _game_clock: Node = null
var _is_phone_connected: bool = false
var _is_ringing: bool = false
var _is_motion_enabled: bool = true
var _ringing_pulse_tween: Tween = null
var _button_feedback_tween: Tween = null

@onready var _time_label: Label = $Content/TimeLabel
@onready var _work_state_label: Label = $Content/WorkStateLabel
@onready var _ringing_indicator: HBoxContainer = $Content/RingingIndicator
@onready var _ringing_text: Label = $Content/RingingIndicator/RingingText
@onready var _phone_button: Button = $Content/RingingIndicator/PhoneButton


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_phone_button.pressed.connect(_on_phone_button_pressed)
	_phone_button.mouse_entered.connect(_on_phone_button_mouse_entered)
	_phone_button.mouse_exited.connect(_on_phone_button_mouse_exited)
	_phone_button.button_down.connect(_on_phone_button_down)
	_phone_button.button_up.connect(_on_phone_button_up)
	_refresh_clock()
	_show_idle_work_state()
	_refresh_phone_indicator()


func _process(_delta: float) -> void:
	_refresh_clock()


func bind_runtime(phone_system: RefCounted, game_clock: Node) -> Dictionary:
	if phone_system == null:
		return _make_error("电话系统实例不能为空。")
	if not phone_system.has_signal(&"state_changed"):
		return _make_error("电话系统缺少 state_changed 信号。")
	if not phone_system.has_method(&"get_state_name") or not phone_system.has_method(&"get_active_call_snapshot"):
		return _make_error("电话系统缺少全局来电提示所需的只读接口。")
	if not is_instance_valid(game_clock) or not game_clock.has_method(&"get_current_game_tick") or not game_clock.has_method(&"get_display_time"):
		return _make_error("GameClock 缺少 get_current_game_tick() 或 get_display_time() 时钟接口。")

	_disconnect_phone_system()
	_phone_system = phone_system
	_game_clock = game_clock
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	var connect_result: Error = _phone_system.connect(&"state_changed", callback)
	if connect_result != OK:
		_phone_system = null
		_game_clock = null
		return _make_error("无法监听 PhoneSystem.state_changed，错误码=%d。" % connect_result)
	_is_phone_connected = true
	_refresh_clock()
	_refresh_phone_indicator()
	return {"ok": true}


func is_ringing() -> bool:
	return _is_ringing


func show_work_state(snapshot: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = ["state_name", "reason_ids", "uses_realtime_rate"]
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return _make_error("工作状态快照缺少字段：%s。" % field_name)
	if typeof(snapshot["state_name"]) != TYPE_STRING \
		or typeof(snapshot["reason_ids"]) != TYPE_PACKED_STRING_ARRAY \
		or typeof(snapshot["uses_realtime_rate"]) != TYPE_BOOL:
		return _make_error("工作状态快照字段类型无效。")
	var state_name: String = String(snapshot["state_name"])
	var uses_realtime_rate: bool = bool(snapshot["uses_realtime_rate"])
	if state_name == "ACTIVE" and uses_realtime_rate:
		_work_state_label.text = "工作状态：非空闲\n时间流速：现实 1 分钟 = 游戏 1 分钟"
		var reason_ids: PackedStringArray = snapshot["reason_ids"]
		_work_state_label.tooltip_text = _describe_active_reasons(reason_ids)
		return {"ok": true}
	if state_name == "IDLE" and not uses_realtime_rate:
		_show_idle_work_state()
		return {"ok": true}
	return _make_error("工作状态与时间倍率标志不一致：%s。" % state_name)


## 仅控制提示脉冲和按钮微反馈；来电状态、布局与导航意图保持不变。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	if not _is_motion_enabled:
		_stop_ringing_pulse()
		_reset_phone_button_feedback()
		return {"ok": true, "motion_enabled": false}
	if _is_ringing:
		_start_ringing_pulse()
	return {"ok": true, "motion_enabled": true}


func is_motion_enabled() -> bool:
	return _is_motion_enabled


func is_phone_pulse_active() -> bool:
	return _ringing_pulse_tween != null and _ringing_pulse_tween.is_valid() and _ringing_pulse_tween.is_running()


func _exit_tree() -> void:
	_stop_ringing_pulse()
	_reset_phone_button_feedback()
	_disconnect_phone_system()


func _on_phone_state_changed(_previous_state: int, _current_state: int, _event_id: String) -> void:
	_refresh_phone_indicator()


func _on_phone_button_pressed() -> void:
	if _is_ringing:
		phone_view_requested.emit()


func _on_phone_button_mouse_entered() -> void:
	if _is_ringing:
		_animate_phone_button_to(Vector2(1.035, 1.035), 0.10)


func _on_phone_button_mouse_exited() -> void:
	_animate_phone_button_to(Vector2.ONE, 0.10)


func _on_phone_button_down() -> void:
	if _is_ringing:
		_animate_phone_button_to(Vector2(0.965, 0.965), 0.06)


func _on_phone_button_up() -> void:
	if not _is_ringing:
		return
	var target_scale: Vector2 = Vector2(1.035, 1.035) if _phone_button.is_hovered() else Vector2.ONE
	_animate_phone_button_to(target_scale, 0.08)


func _refresh_clock() -> void:
	if _game_clock == null or not is_instance_valid(_game_clock):
		_time_label.text = "时间：--:--"
		return
	var tick_result: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_result) != TYPE_INT:
		_time_label.text = "时间：数据无效"
		push_error("[全局状态][invalid_clock_tick] GameClock.get_current_game_tick() 必须返回整数 tick。")
		return
	if int(tick_result) < 0:
		_time_label.text = "时间：数据无效"
		push_error("[全局状态][invalid_clock_tick] GameClock 返回了负数 tick。")
		return
	var display_result: Variant = _game_clock.call(&"get_display_time")
	if typeof(display_result) != TYPE_STRING or String(display_result).is_empty():
		_time_label.text = "时间：数据无效"
		push_error("[全局状态][invalid_clock_display] GameClock.get_display_time() 必须返回非空字符串。")
		return
	_time_label.text = "1999 年 12 月 31 日 / %s" % String(display_result)


func _show_idle_work_state() -> void:
	_work_state_label.text = "工作状态：空闲\n时间流速：现实 2 秒 = 游戏 1 分钟"
	_work_state_label.tooltip_text = "当前没有来电、待播稿件，也未打开电脑。"


func _describe_active_reasons(reason_ids: PackedStringArray) -> String:
	var labels: PackedStringArray = PackedStringArray()
	for reason_id: String in reason_ids:
		match reason_id:
			"phone_ringing":
				labels.append("有电话正在响铃")
			"phone_connected":
				labels.append("电话已接通")
			"dialogue_choice":
				labels.append("正在进行电话对话")
			"broadcast_pending":
				labels.append("存在需要处理的待播稿件")
			"computer_open":
				labels.append("正在查看电脑")
			"settings_open":
				labels.append("设置面板已打开（故事时间继续推进）")
			_:
				labels.append("未知原因：%s" % reason_id)
	return "非空闲原因：%s。" % "、".join(labels)


func _refresh_phone_indicator() -> void:
	_is_ringing = false
	if _phone_system == null:
		_ringing_indicator.visible = false
		return
	var state_result: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_result) != TYPE_STRING:
		_ringing_indicator.visible = false
		push_error("[全局状态][invalid_phone_state] PhoneSystem.get_state_name() 必须返回字符串。")
		return
	_is_ringing = String(state_result) == "RINGING"
	_ringing_indicator.visible = _is_ringing
	if not _is_ringing:
		_stop_ringing_pulse()
		return

	var caller_text: String = "未知来电"
	var snapshot_result: Variant = _phone_system.call(&"get_active_call_snapshot")
	if snapshot_result is Dictionary:
		var snapshot: Dictionary = snapshot_result as Dictionary
		var caller_name: String = String(snapshot.get("caller_name", "")).strip_edges()
		var caller_number: String = String(snapshot.get("caller_number", "")).strip_edges()
		if not caller_name.is_empty() and not caller_number.is_empty():
			caller_text = "%s / %s" % [caller_name, caller_number]
		elif not caller_name.is_empty():
			caller_text = caller_name
	_ringing_text.text = "电话正在响铃\n%s" % caller_text
	_phone_button.tooltip_text = "打开电话近景；不会自动接听。"
	_start_ringing_pulse()


func _start_ringing_pulse() -> void:
	if not _is_motion_enabled or not _is_ringing:
		return
	if _ringing_pulse_tween != null and _ringing_pulse_tween.is_valid() and _ringing_pulse_tween.is_running():
		return
	_stop_ringing_pulse()
	_ringing_indicator.pivot_offset = _ringing_indicator.size * 0.5
	_ringing_indicator.scale = Vector2.ONE
	_ringing_indicator.self_modulate = Color.WHITE
	_ringing_pulse_tween = create_tween().set_loops()
	_ringing_pulse_tween.tween_property(_ringing_indicator, "scale", Vector2(1.025, 1.025), 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ringing_pulse_tween.parallel().tween_property(_ringing_indicator, "self_modulate", Color(1.0, 1.0, 1.0, 0.88), 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ringing_pulse_tween.tween_property(_ringing_indicator, "scale", Vector2.ONE, 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_ringing_pulse_tween.parallel().tween_property(_ringing_indicator, "self_modulate", Color.WHITE, 0.62).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_ringing_pulse() -> void:
	if _ringing_pulse_tween != null and _ringing_pulse_tween.is_valid():
		_ringing_pulse_tween.kill()
	_ringing_pulse_tween = null
	if is_instance_valid(_ringing_indicator):
		_ringing_indicator.scale = Vector2.ONE
		_ringing_indicator.self_modulate = Color.WHITE


func _animate_phone_button_to(target_scale: Vector2, duration: float) -> void:
	if not _is_motion_enabled:
		_phone_button.scale = Vector2.ONE
		return
	if _button_feedback_tween != null and _button_feedback_tween.is_valid():
		_button_feedback_tween.kill()
	_phone_button.pivot_offset = _phone_button.size * 0.5
	_button_feedback_tween = create_tween()
	_button_feedback_tween.tween_property(_phone_button, "scale", target_scale, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _reset_phone_button_feedback() -> void:
	if _button_feedback_tween != null and _button_feedback_tween.is_valid():
		_button_feedback_tween.kill()
	_button_feedback_tween = null
	if is_instance_valid(_phone_button):
		_phone_button.scale = Vector2.ONE


func _disconnect_phone_system() -> void:
	if _phone_system == null or not _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	if _phone_system.is_connected(&"state_changed", callback):
		_phone_system.disconnect(&"state_changed", callback)
	_is_phone_connected = false


func _make_error(message: String) -> Dictionary:
	push_error("[全局状态][global_status_error] %s" % message)
	return {"ok": false, "message": message}
