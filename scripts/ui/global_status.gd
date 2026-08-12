class_name GlobalStatus
extends Control
## 所有固定视图共用的悬浮状态提示。
##
## 它只读取整数游戏 tick 和 PhoneSystem 的只读状态。来电牌纯粹是提醒，
## 不接收鼠标输入，也不请求导航或修改电话线路状态。工作状态由 GameScreen
## 传入派生快照；本控件保留其严格契约，但不再将它作为可见 HUD 文本。

var _phone_system: RefCounted = null
var _game_clock: Node = null
var _is_phone_connected: bool = false
var _is_ringing: bool = false
var _is_motion_enabled: bool = true
var _is_ringing_bright: bool = true
var _ringing_blink_toggle_count: int = 0
var _ringing_blink_start_count: int = 0
var _last_work_state_snapshot: Dictionary = {}

@onready var _time_title: Label = $Content/TimeTitle
@onready var _clock_digits: Control = $Content/ClockDigits
@onready var _hour_tens: TextureRect = $Content/ClockDigits/HourTens
@onready var _hour_units: TextureRect = $Content/ClockDigits/HourUnits
@onready var _minute_tens: TextureRect = $Content/ClockDigits/MinuteTens
@onready var _minute_units: TextureRect = $Content/ClockDigits/MinuteUnits
@onready var _meridiem: TextureRect = $Content/ClockDigits/Meridiem
@onready var _clock_glyph_library: Control = $Content/ClockGlyphLibrary
@onready var _ringing_indicator: Control = $Content/RingingIndicator
@onready var _ringing_icon: TextureRect = $Content/RingingIndicator/RingingIcon
@onready var _ringing_dim_texture: TextureRect = $Content/RingingIndicator/RingingDimTexture
@onready var _ringing_blink_timer: Timer = $RingingBlinkTimer
@onready var _ringing_bright_texture: Texture2D = _ringing_icon.texture


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ringing_blink_timer.timeout.connect(_on_ringing_blink_timeout)
	_refresh_clock()
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
	if (state_name != "ACTIVE" or not uses_realtime_rate) and (state_name != "IDLE" or uses_realtime_rate):
		return _make_error("工作状态与时间倍率标志不一致：%s。" % state_name)
	_last_work_state_snapshot = {
		"state_name": state_name,
		"reason_ids": (snapshot["reason_ids"] as PackedStringArray).duplicate(),
		"uses_realtime_rate": uses_realtime_rate,
	}
	return {"ok": true}


func get_last_work_state_snapshot() -> Dictionary:
	if _last_work_state_snapshot.is_empty():
		return {}
	return {
		"state_name": String(_last_work_state_snapshot["state_name"]),
		"reason_ids": (_last_work_state_snapshot["reason_ids"] as PackedStringArray).duplicate(),
		"uses_realtime_rate": bool(_last_work_state_snapshot["uses_realtime_rate"]),
	}


func get_display_clock_snapshot() -> Dictionary:
	var display_result: Dictionary = _get_clock_display_result()
	if not bool(display_result.get("ok", false)):
		return display_result
	return {
		"ok": true,
		"date": "1999年12月31日",
		"time_24h": String(display_result["time_24h"]),
		"time_12h": String(display_result["time_12h"]),
		"meridiem": String(display_result["meridiem"]),
	}


## 减少动态时保持亮图，并停止提示切换；来电状态和布局保持不变。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	if not _is_motion_enabled:
		_stop_ringing_blink()
		_set_ringing_icon_bright(true)
		return {"ok": true, "motion_enabled": false}
	if _is_ringing:
		_start_ringing_blink()
	return {"ok": true, "motion_enabled": true}


func is_motion_enabled() -> bool:
	return _is_motion_enabled


func get_ringing_blink_snapshot() -> Dictionary:
	return {
		"is_ringing": _is_ringing,
		"is_bright": _is_ringing_bright,
		"toggle_count": _ringing_blink_toggle_count,
		"start_count": _ringing_blink_start_count,
		"timer_active": not _ringing_blink_timer.is_stopped(),
		"interval_seconds": _ringing_blink_timer.wait_time,
	}


## 专供冒烟测试确定性验证，不影响 PhoneSystem 权威状态或真实计时器配置。
func advance_ringing_blink_for_verification(toggle_count: int = 1) -> Dictionary:
	if toggle_count < 0:
		return _make_error("来电闪烁验证次数不能为负数。")
	if not _is_ringing or not _is_motion_enabled:
		return {"ok": true, "toggle_count": 0, "is_bright": _is_ringing_bright}
	for index: int in toggle_count:
		_toggle_ringing_icon()
	return {"ok": true, "toggle_count": toggle_count, "is_bright": _is_ringing_bright}


func _exit_tree() -> void:
	_stop_ringing_blink()
	_disconnect_phone_system()


func _on_phone_state_changed(_previous_state: int, _current_state: int, _event_id: String) -> void:
	_refresh_phone_indicator()


func _refresh_clock() -> void:
	if _game_clock == null or not is_instance_valid(_game_clock):
		_clock_digits.visible = false
		return
	var tick_result: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_result) != TYPE_INT:
		_clock_digits.visible = false
		push_error("[全局状态][invalid_clock_tick] GameClock.get_current_game_tick() 必须返回整数 tick。")
		return
	if int(tick_result) < 0:
		_clock_digits.visible = false
		push_error("[全局状态][invalid_clock_tick] GameClock 返回了负数 tick。")
		return
	var display_result: Dictionary = _get_clock_display_result()
	if not bool(display_result.get("ok", false)):
		_clock_digits.visible = false
		push_error("[全局状态][invalid_clock_display] %s" % String(display_result.get("message", "GameClock.get_display_time() 返回无效数据。")))
		return
	var time_12h: String = String(display_result["time_12h"])
	_set_digit_texture(_hour_tens, time_12h[0])
	_set_digit_texture(_hour_units, time_12h[1])
	_set_digit_texture(_minute_tens, time_12h[3])
	_set_digit_texture(_minute_units, time_12h[4])
	_meridiem.texture = _get_meridiem_texture(String(display_result["meridiem"]))
	_time_title.text = "1999年12月31日"
	_clock_digits.visible = true


func _get_clock_display_result() -> Dictionary:
	if _game_clock == null or not is_instance_valid(_game_clock):
		return _make_silent_error("GameClock 不可用。")
	var display_value: Variant = _game_clock.call(&"get_display_time")
	if typeof(display_value) != TYPE_STRING:
		return _make_silent_error("GameClock.get_display_time() 必须返回字符串。")
	var time_24h: String = String(display_value)
	if time_24h.length() != 5 or time_24h[2] != ":":
		return _make_silent_error("GameClock.get_display_time() 必须使用 HH:MM 格式。")
	var hour_text: String = time_24h.left(2)
	var minute_text: String = time_24h.right(2)
	if not hour_text.is_valid_int() or not minute_text.is_valid_int():
		return _make_silent_error("GameClock.get_display_time() 的小时或分钟不是整数。")
	var hour_24h: int = int(hour_text)
	var minute: int = int(minute_text)
	if hour_24h < 0 or hour_24h > 23 or minute < 0 or minute > 59:
		return _make_silent_error("GameClock.get_display_time() 超出 24 小时制范围。")
	var meridiem: String = "AM" if hour_24h < 12 else "PM"
	var hour_12h: int = hour_24h % 12
	if hour_12h == 0:
		hour_12h = 12
	return {
		"ok": true,
		"time_24h": time_24h,
		"time_12h": "%02d:%02d" % [hour_12h, minute],
		"meridiem": meridiem,
	}


func _set_digit_texture(target: TextureRect, digit: String) -> void:
	var glyph: TextureRect = _clock_glyph_library.get_node("Digit%s" % digit) as TextureRect
	if glyph == null or glyph.texture == null:
		push_error("[全局状态][missing_clock_glyph] 时间图集缺少数字图块：%s。" % digit)
		_clock_digits.visible = false
		return
	target.texture = glyph.texture


func _get_meridiem_texture(meridiem: String) -> AtlasTexture:
	var glyph_name: String = "Am" if meridiem == "AM" else "Pm"
	var glyph: TextureRect = _clock_glyph_library.get_node(glyph_name) as TextureRect
	if glyph == null or not glyph.texture is AtlasTexture:
		push_error("[全局状态][missing_clock_meridiem] 时间图集缺少 %s 图块。" % meridiem)
		return null
	return glyph.texture as AtlasTexture


func _make_silent_error(message: String) -> Dictionary:
	return {"ok": false, "message": message}


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
		_stop_ringing_blink()
		return
	_set_ringing_icon_bright(true)
	_start_ringing_blink()


func _start_ringing_blink() -> void:
	if not _is_motion_enabled or not _is_ringing or not _ringing_blink_timer.is_stopped():
		return
	_ringing_blink_timer.start()
	_ringing_blink_start_count += 1


func _stop_ringing_blink() -> void:
	if is_instance_valid(_ringing_blink_timer):
		_ringing_blink_timer.stop()


func _on_ringing_blink_timeout() -> void:
	if not _is_ringing or not _is_motion_enabled:
		_stop_ringing_blink()
		_set_ringing_icon_bright(true)
		return
	_toggle_ringing_icon()


func _toggle_ringing_icon() -> void:
	_set_ringing_icon_bright(not _is_ringing_bright)
	_ringing_blink_toggle_count += 1


func _set_ringing_icon_bright(is_bright: bool) -> void:
	_is_ringing_bright = is_bright
	if not is_instance_valid(_ringing_icon):
		return
	_ringing_icon.texture = _ringing_bright_texture if is_bright else _ringing_dim_texture.texture


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
