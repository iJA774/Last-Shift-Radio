class_name ComputerCloseup
extends Control
## 电脑近景只包装信息、来电记录与播出工作台显示组件。
## 来电记录和播出状态的权威来源仍分别是 PhoneSystem 与 StoryEngine。

signal return_requested()
signal broadcast_requested(broadcast_id: String)

var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true
var _cursor_tween: Tween = null
var _glow_tween: Tween = null

@onready var _call_log_view: Control = %CallLogView
@onready var _return_button: Button = %BackButton
@onready var _screen_glow: ColorRect = %ScreenGlow
@onready var _screen_cursor: Label = %ScreenCursor


func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("电话系统实例不能为空。")
	if _call_log_view == null or not _call_log_view.has_method(&"bind_phone_system"):
		return _make_error("电脑来电记录组件缺少 bind_phone_system() 接口。")
	var result: Variant = _call_log_view.call(&"bind_phone_system", phone_system)
	return _validate_component_result(result, "绑定电话系统")


## 电脑只读取 StoryEngine 给出的稿件/记录，并向 GameScreen 上报 broadcast_id 意图。
func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	if _call_log_view == null or not _call_log_view.has_method(&"bind_story_engine"):
		return _make_error("电脑记录组件缺少 bind_story_engine() 接口。")
	var result: Variant = _call_log_view.call(&"bind_story_engine", story_engine)
	return _validate_component_result(result, "绑定剧情引擎")


## GameScreen 转交 StoryEngine 的发送结果；电脑不自行调用发送接口或拼装记录。
func show_broadcast_feedback(result: Dictionary) -> Dictionary:
	if _call_log_view == null or not _call_log_view.has_method(&"show_broadcast_feedback"):
		return _make_error("电脑记录组件缺少 show_broadcast_feedback() 接口。")
	var component_result: Variant = _call_log_view.call(&"show_broadcast_feedback", result)
	return _validate_component_result(component_result, "显示播出反馈")


func show_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	if _call_log_view == null or not _call_log_view.has_method(&"show_unauthorized_broadcast"):
		return _make_error("电脑来电记录组件缺少 show_unauthorized_broadcast() 接口。")
	var result: Variant = _call_log_view.call(&"show_unauthorized_broadcast", record)
	return _validate_component_result(result, "显示未授权播出记录")


## 收束期间由 GameScreen 锁定导航；电脑近景不自行决定收束时间或剧情状态。
func set_return_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用返回工作室总览时必须提供中文原因。")
	_is_return_enabled = is_enabled
	_refresh_return_button(disabled_reason)
	return {"ok": true}


## 减少动态只停止 CRT 光标闪烁与环境效果，不影响记录内容或收束状态。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null or not ambient_fx.has_method(&"set_motion_enabled"):
		return _make_error("环境效果组件缺少 set_motion_enabled() 接口。")
	ambient_fx.call(&"set_motion_enabled", is_enabled)
	_refresh_screen_motion()
	return {"ok": true}


func _ready() -> void:
	_connect_call_log_signals()
	_refresh_return_button()
	_configure_ambient_fx()
	_refresh_screen_motion()


func _refresh_return_button(disabled_reason: String = "") -> void:
	_return_button.disabled = not _is_return_enabled
	if _is_return_enabled:
		_return_button.text = "返回工作室总览"
		_return_button.tooltip_text = "返回工作室总览。"
		return
	# 02:00 收束页必须在不依赖悬停的情况下说明导航已锁定。
	_return_button.text = "返回不可用\n02:00 已锁定"
	_return_button.tooltip_text = "不可用：%s" % disabled_reason


func _on_back_button_pressed() -> void:
	if _is_return_enabled and not _return_button.disabled:
		return_requested.emit()


func _connect_call_log_signals() -> void:
	if _call_log_view == null or not _call_log_view.has_signal(&"broadcast_requested"):
		push_error("[电脑][broadcast_signal_missing] 电脑记录组件缺少 broadcast_requested 信号。")
		return
	var callback: Callable = Callable(self, "_on_call_log_broadcast_requested")
	if _call_log_view.is_connected(&"broadcast_requested", callback):
		return
	var result: Error = _call_log_view.connect(&"broadcast_requested", callback)
	if result != OK:
		push_error("[电脑][broadcast_signal_connect_failed] 无法连接 broadcast_requested，错误码=%d。" % result)


func _on_call_log_broadcast_requested(broadcast_id: String) -> void:
	if broadcast_id.strip_edges().is_empty():
		push_error("[电脑][invalid_broadcast_id] 记录组件发出了空广播 ID。")
		return
	broadcast_requested.emit(broadcast_id)


func _configure_ambient_fx() -> void:
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null:
		push_error("[电脑][ambient_fx_missing] 缺少 AmbientFx 环境效果组件。")
		return
	if not ambient_fx.has_method(&"set_profile") or not ambient_fx.has_method(&"set_random_seed"):
		push_error("[电脑][ambient_fx_contract] AmbientFx 缺少 set_profile() 或 set_random_seed() 接口。")
		return
	ambient_fx.call(&"set_profile", "equipment")
	ambient_fx.call(&"set_random_seed", 199903)
	var result: Dictionary = set_motion_enabled(_is_motion_enabled)
	if not bool(result.get("ok", false)):
		push_error("[电脑][ambient_fx_motion] %s" % String(result.get("message", "环境效果初始化失败。")))


func _refresh_screen_motion() -> void:
	_screen_glow.visible = true
	_screen_glow.modulate = Color(1.0, 1.0, 1.0, 0.72)
	_screen_cursor.visible = true
	_screen_cursor.modulate = Color(1.0, 1.0, 1.0, 0.76)
	_stop_cursor_tween()
	_stop_glow_tween()
	if not _is_motion_enabled:
		return
	# 极低频、低幅度的屏幕呼吸光，仅营造 CRT 通电感，不制造闪烁惊吓。
	_glow_tween = create_tween().set_loops()
	_glow_tween.tween_property(_screen_glow, "modulate", Color(1.0, 1.0, 1.0, 0.46), 1.65)
	_glow_tween.tween_property(_screen_glow, "modulate", Color(1.0, 1.0, 1.0, 0.78), 1.65)
	_cursor_tween = create_tween().set_loops()
	_cursor_tween.tween_property(_screen_cursor, "modulate", Color(1.0, 1.0, 1.0, 0.15), 0.58)
	_cursor_tween.tween_property(_screen_cursor, "modulate", Color(1.0, 1.0, 1.0, 0.82), 0.58)


func _stop_cursor_tween() -> void:
	if _cursor_tween != null and _cursor_tween.is_valid():
		_cursor_tween.kill()
	_cursor_tween = null


func _stop_glow_tween() -> void:
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	_glow_tween = null


func _validate_component_result(result: Variant, action_name: String) -> Dictionary:
	if result is Dictionary and (result as Dictionary).has("ok"):
		return result as Dictionary
	return _make_error("%s失败：来电记录组件未返回带 ok 字段的结果。" % action_name)


func _make_error(message: String) -> Dictionary:
	push_error("[电脑][closeup_error] %s" % message)
	return {"ok": false, "message": message}
