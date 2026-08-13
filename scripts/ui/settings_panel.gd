class_name SettingsPanel
extends Control
## 设置面板只展示并提交 SettingsManager 的全局设置。
##
## 它不缓存可写设置，也不把选项放进剧情存档；任何控件变更均直接调用
## SettingsManager 的 typed setter，随后从其公开快照回填显示。

signal closed

const SETTING_IDS: PackedStringArray = [
	"master_volume",
	"ambience_volume",
	"ui_phone_volume",
	"window_mode",
	"text_speed",
	"reduce_flashing",
	"crt_enabled",
]
const FADE_SECONDS: float = 0.25

var _settings_manager: Node = null
var _is_refreshing: bool = false
var _is_manager_connected: bool = false
var _fade_tween: Tween = null
var _is_closing: bool = false
var _has_emitted_closed: bool = false

@onready var _master_slider: HSlider = %MasterSlider
@onready var _master_value: Label = %MasterValue
@onready var _ambience_slider: HSlider = %AmbienceSlider
@onready var _ambience_value: Label = %AmbienceValue
@onready var _ui_phone_slider: HSlider = %UiPhoneSlider
@onready var _ui_phone_value: Label = %UiPhoneValue
@onready var _reduce_flashing_button: Button = %ReduceFlashingButton
@onready var _disable_crt_button: Button = %DisableCrtButton
@onready var _message_label: Label = %MessageLabel
@onready var _close_button: Button = %CloseButton
@onready var _recovery_reset_button: Button = %RecoveryResetButton

var _is_reduce_flashing_enabled: bool = false
var _is_crt_enabled: bool = true


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_controls()
	_refresh_from_manager()
	_start_fade_in()


func _exit_tree() -> void:
	_disconnect_manager()
	_cancel_fade()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and not event.is_echo():
		_on_close_pressed()
		get_viewport().set_input_as_handled()


func get_fade_snapshot() -> Dictionary:
	return {"ok": true, "fade_seconds": FADE_SECONDS, "is_closing": _is_closing}


func finish_fade_for_verification() -> Dictionary:
	if not _is_closing:
		return {"ok": true, "already_idle": true}
	_cancel_fade()
	_complete_close()
	return {"ok": true}


func get_visual_snapshot() -> Dictionary:
	return {
		"ok": true,
		"master": _volume_visual_snapshot("Master", _master_slider.value),
		"ambience": _volume_visual_snapshot("Ambience", _ambience_slider.value),
		"ui_phone": _volume_visual_snapshot("UiPhone", _ui_phone_slider.value),
		"disable_crt": not _crt_enabled_value(),
		"reduce_flashing": _reduce_flashing_value(),
	}


func bind_settings_manager(settings_manager: Node) -> Dictionary:
	var validation: Dictionary = _validate_settings_manager(settings_manager)
	if not bool(validation.get("ok", false)):
		return validation
	_disconnect_manager()
	_settings_manager = settings_manager
	_connect_manager()
	_refresh_from_manager()
	return {"ok": true}


func get_settings_manager() -> Node:
	return _settings_manager


func _connect_controls() -> void:
	_master_slider.value_changed.connect(_on_master_volume_changed)
	_ambience_slider.value_changed.connect(_on_ambience_volume_changed)
	_ui_phone_slider.value_changed.connect(_on_ui_phone_volume_changed)
	_reduce_flashing_button.pressed.connect(_on_reduce_flashing_pressed)
	_disable_crt_button.pressed.connect(_on_disable_crt_pressed)
	_close_button.pressed.connect(_on_close_pressed)
	_recovery_reset_button.pressed.connect(_on_recovery_reset_pressed)
	_message_label.visible = false
	_recovery_reset_button.visible = false


func _connect_manager() -> void:
	if _settings_manager == null or not is_instance_valid(_settings_manager) or _is_manager_connected:
		return
	var callback: Callable = Callable(self, "_on_settings_applied")
	if not _settings_manager.is_connected(&"settings_applied", callback):
		var connect_result: Error = _settings_manager.connect(&"settings_applied", callback)
		if connect_result != OK:
			_show_message("无法监听设置变更（错误码=%d）。" % connect_result, true)
			return
	_is_manager_connected = true


func _disconnect_manager() -> void:
	if _settings_manager != null and is_instance_valid(_settings_manager) and _is_manager_connected:
		var callback: Callable = Callable(self, "_on_settings_applied")
		if _settings_manager.is_connected(&"settings_applied", callback):
			_settings_manager.disconnect(&"settings_applied", callback)
	_is_manager_connected = false


func _validate_settings_manager(settings_manager: Node) -> Dictionary:
	if settings_manager == null or not is_instance_valid(settings_manager):
		return _make_error("SettingsManager 自动加载节点不可用。")
	var required_methods: PackedStringArray = [
		"get_settings_snapshot",
		"is_settings_loaded",
		"get_last_load_result",
		"reset_to_defaults",
		"set_master_volume",
		"set_ambience_volume",
		"set_ui_phone_volume",
		"set_window_mode",
		"set_text_speed",
		"set_reduce_flashing_enabled",
		"set_crt_enabled",
	]
	for method_name: String in required_methods:
		if not settings_manager.has_method(method_name):
			return _make_error("SettingsManager 缺少 %s() 接口。" % method_name)
	if not settings_manager.has_signal(&"settings_applied"):
		return _make_error("SettingsManager 缺少 settings_applied 信号。")
	return {"ok": true}


func _refresh_from_manager() -> void:
	if not is_node_ready():
		return
	if _settings_manager == null or not is_instance_valid(_settings_manager):
		_set_controls_enabled(false)
		_show_message("设置暂时不可用。", true)
		return
	var snapshot_value: Variant = _settings_manager.call(&"get_settings_snapshot")
	if not snapshot_value is Dictionary:
		_set_controls_enabled(false)
		_show_message("设置暂时无法读取。", true)
		return
	var snapshot: Dictionary = snapshot_value as Dictionary
	var validation: Dictionary = _validate_snapshot(snapshot)
	if not bool(validation.get("ok", false)):
		_set_controls_enabled(false)
		_show_message(String(validation.get("message", "设置快照无效。")), true)
		return
	_is_refreshing = true
	_master_slider.value = float(snapshot["master_volume"])
	_ambience_slider.value = float(snapshot["ambience_volume"])
	_ui_phone_slider.value = float(snapshot["ui_phone_volume"])
	_update_toggle_visuals(bool(snapshot["reduce_flashing"]), bool(snapshot["crt_enabled"]))
	_update_value_labels()
	_is_refreshing = false
	if not bool(_settings_manager.call(&"is_settings_loaded")):
		_set_controls_enabled(false)
		var load_result: Variant = _settings_manager.call(&"get_last_load_result")
		var reason: String = String((load_result as Dictionary).get("message", "设置文件损坏或不可读取。")) if load_result is Dictionary else "设置文件损坏或不可读取。"
		_show_message("设置文件读取失败：%s\n请点击右侧“修复设置”恢复默认。" % reason, true)
		_recovery_reset_button.visible = true
		_recovery_reset_button.disabled = false
		return
	_set_controls_enabled(true)
	_message_label.visible = false
	_recovery_reset_button.visible = false


func _validate_snapshot(snapshot: Dictionary) -> Dictionary:
	for setting_id: String in SETTING_IDS:
		if not snapshot.has(setting_id):
			return _make_error("设置快照缺少字段：%s。" % setting_id)
	if typeof(snapshot["master_volume"]) not in [TYPE_FLOAT, TYPE_INT] \
		or typeof(snapshot["ambience_volume"]) not in [TYPE_FLOAT, TYPE_INT] \
		or typeof(snapshot["ui_phone_volume"]) not in [TYPE_FLOAT, TYPE_INT] \
		or typeof(snapshot["text_speed"]) not in [TYPE_FLOAT, TYPE_INT] \
		or typeof(snapshot["window_mode"]) != TYPE_STRING \
		or typeof(snapshot["reduce_flashing"]) != TYPE_BOOL \
		or typeof(snapshot["crt_enabled"]) != TYPE_BOOL:
		return _make_error("设置快照字段类型无效。")
	return {"ok": true}


func _set_controls_enabled(is_enabled: bool) -> void:
	for control: Control in [
		_master_slider,
		_ambience_slider,
		_ui_phone_slider,
		_reduce_flashing_button,
		_disable_crt_button,
	]:
		if control is Range:
			(control as Range).editable = is_enabled
		elif control is BaseButton:
			(control as BaseButton).disabled = not is_enabled
		if not is_enabled:
			control.tooltip_text = "不可用：设置尚未准备完成。"


func _update_value_labels() -> void:
	_master_value.text = _format_percent(_master_slider.value)
	_ambience_value.text = _format_percent(_ambience_slider.value)
	_ui_phone_value.text = _format_percent(_ui_phone_slider.value)
	_update_volume_visual("Master", _master_slider.value)
	_update_volume_visual("Ambience", _ambience_slider.value)
	_update_volume_visual("UiPhone", _ui_phone_slider.value)


func _update_volume_visual(prefix: String, normalized_value: float) -> void:
	var clip: Control = get_node("VolumeVisuals/%sClip" % prefix) as Control
	var available_width: float = 737.0
	clip.size.x = available_width * clampf(normalized_value, 0.0, 1.0)


func _update_toggle_visuals(reduce_flashing: bool, crt_enabled: bool) -> void:
	_is_reduce_flashing_enabled = reduce_flashing
	_is_crt_enabled = crt_enabled
	var disable_crt: bool = not _is_crt_enabled
	%DisableCrtStateBar.modulate.a = 1.0 if disable_crt else 0.22
	%ReduceFlashingStateBar.modulate.a = 1.0 if reduce_flashing else 0.22
	%DisableCrtOffOverlay.visible = not disable_crt
	%ReduceFlashingOffOverlay.visible = not reduce_flashing


func _volume_visual_snapshot(prefix: String, normalized_value: float) -> Dictionary:
	var clip: Control = get_node("VolumeVisuals/%sClip" % prefix) as Control
	return {"normalized_value": normalized_value, "visible_width": clip.size.x}


func _reduce_flashing_value() -> bool:
	return _is_reduce_flashing_enabled


func _crt_enabled_value() -> bool:
	return _is_crt_enabled


func _format_percent(value: float) -> String:
	return "%d%%" % roundi(clampf(value, 0.0, 1.0) * 100.0)


func _submit_setter(method_name: StringName, arguments: Array) -> void:
	if _is_refreshing:
		return
	if _settings_manager == null or not is_instance_valid(_settings_manager):
		_show_message("设置暂时不可用，无法保存变更。", true)
		return
	var result: Variant = _settings_manager.callv(method_name, arguments)
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		var reason: String = String((result as Dictionary).get("message", "SettingsManager 未返回成功结果。")) if result is Dictionary else "SettingsManager 未返回 Dictionary 结果。"
		_show_message("应用设置失败：%s" % reason, true)
		_refresh_from_manager()
		return
	_refresh_from_manager()


func _show_message(message: String, is_error: bool) -> void:
	if not is_node_ready():
		return
	_message_label.text = message
	_message_label.modulate = Color(1.0, 0.72, 0.68, 1.0) if is_error else Color(0.70, 0.93, 0.82, 1.0)
	_message_label.visible = not message.strip_edges().is_empty()


func _on_settings_applied(_snapshot: Dictionary) -> void:
	_refresh_from_manager()


func _on_master_volume_changed(value: float) -> void:
	_update_value_labels()
	_submit_setter(&"set_master_volume", [value])


func _on_ambience_volume_changed(value: float) -> void:
	_update_value_labels()
	_submit_setter(&"set_ambience_volume", [value])


func _on_ui_phone_volume_changed(value: float) -> void:
	_update_value_labels()
	_submit_setter(&"set_ui_phone_volume", [value])


func _on_reduce_flashing_pressed() -> void:
	_submit_setter(&"set_reduce_flashing_enabled", [not _reduce_flashing_value()])


func _on_disable_crt_pressed() -> void:
	# 素材文案是“关闭 CRT 效果”；开表示 SettingsManager.crt_enabled=false。
	_submit_setter(&"set_crt_enabled", [not _crt_enabled_value()])


func _on_recovery_reset_pressed() -> void:
	_submit_setter(&"reset_to_defaults", [])


func _on_close_pressed() -> void:
	if _is_closing or _has_emitted_closed:
		return
	_play_button_click()
	_is_closing = true
	_cancel_fade()
	_fade_tween = create_tween()
	_fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(self, "modulate:a", 0.0, FADE_SECONDS)
	_fade_tween.tween_callback(_complete_close)


func _start_fade_in() -> void:
	modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(self, "modulate:a", 1.0, FADE_SECONDS)


func _cancel_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _complete_close() -> void:
	if _has_emitted_closed:
		return
	_has_emitted_closed = true
	_is_closing = false
	closed.emit()


## 鼠标返回与 Esc 共用本方法；关闭状态先行拦截，避免同一输入在渐出期间重复发声。
func _play_button_click() -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	if player == null or not player.has_method(&"play_button_click"):
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，设置返回点击音未播放。")
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] 设置返回点击音播放失败：%s" % str(result))


func _make_error(message: String) -> Dictionary:
	push_error("[设置界面][settings_panel_error] %s" % message)
	return {"ok": false, "message": message}
