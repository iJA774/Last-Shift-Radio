class_name AudioManagerService
extends Node
## 全局音频总线控制器。它只把 SettingsManager 的已验证完整设置快照应用到 AudioServer，
## 不播放声音、不推进时钟，也不读取或修改剧情和电话状态。

signal bus_volume_applied(bus_name: StringName, linear_volume: float, is_muted: bool)
signal bus_mute_changed(bus_name: StringName, is_muted: bool, is_persistent_setting: bool)

const MASTER_BUS_NAME: StringName = &"Master"
const AMBIENCE_BUS_NAME: StringName = &"Ambience"
const UI_PHONE_BUS_NAME: StringName = &"UIPhone"

const MASTER_VOLUME_SETTING_ID: StringName = &"master_volume"
const AMBIENCE_VOLUME_SETTING_ID: StringName = &"ambience_volume"
const UI_PHONE_VOLUME_SETTING_ID: StringName = &"ui_phone_volume"

var _settings_manager: Node = null
## 仅供专项测试在进入场景树前注入内存设置源，避免测试向真实 Autoload 发射信号。
var _settings_manager_for_verification: Node = null
var _linear_volume_by_bus: Dictionary[StringName, float] = {
	MASTER_BUS_NAME: 1.0,
	AMBIENCE_BUS_NAME: 1.0,
	UI_PHONE_BUS_NAME: 1.0,
}
## 线性音量为零产生的设置静音；随设置文件持久化的只有其来源音量，而不是本字典。
var _settings_mute_by_bus: Dictionary[StringName, bool] = {
	MASTER_BUS_NAME: false,
	AMBIENCE_BUS_NAME: false,
	UI_PHONE_BUS_NAME: false,
}
## 临时静音只用于公开的运行时控制能力，绝不写入 SettingsManager 或剧情存档。
var _temporary_mute_by_bus: Dictionary[StringName, bool] = {
	MASTER_BUS_NAME: false,
	AMBIENCE_BUS_NAME: false,
	UI_PHONE_BUS_NAME: false,
}


func _ready() -> void:
	var bus_result: Dictionary = _validate_required_buses()
	if not bool(bus_result.get("ok", false)):
		return
	var settings_result: Dictionary = _connect_settings_manager()
	if not bool(settings_result.get("ok", false)):
		push_error("[音频][settings_connect_failed] %s" % String(settings_result.get("message", "设置系统连接失败。")))
		return
	var apply_result: Dictionary = _apply_current_settings()
	if not bool(apply_result.get("ok", false)):
		push_error("[音频][settings_apply_failed] %s" % String(apply_result.get("message", "无法应用当前音频设置。")))


func _exit_tree() -> void:
	if _settings_manager == null:
		return
	var applied_callback: Callable = Callable(self, "_on_settings_applied")
	if _settings_manager.is_connected(&"settings_applied", applied_callback):
		_settings_manager.disconnect(&"settings_applied", applied_callback)
	_settings_manager = null


## 只用于自动化专项。必须在节点进入场景树前调用，生产运行始终连接 /root/SettingsManager。
func set_settings_manager_for_verification(settings_manager: Node) -> Dictionary:
	if settings_manager == null:
		return _make_error("missing_verification_settings_manager", "专项设置源不能为空。")
	if is_inside_tree():
		return _make_error("verification_settings_manager_too_late", "专项设置源必须在 AudioManager 进入场景树前设置。")
	_settings_manager_for_verification = settings_manager
	return {"ok": true}


func apply_master_volume(linear_volume: float) -> Dictionary:
	return _apply_linear_volume(MASTER_BUS_NAME, linear_volume)


func apply_ambience_volume(linear_volume: float) -> Dictionary:
	return _apply_linear_volume(AMBIENCE_BUS_NAME, linear_volume)


func apply_ui_phone_volume(linear_volume: float) -> Dictionary:
	return _apply_linear_volume(UI_PHONE_BUS_NAME, linear_volume)


## 临时静音不持久化。设置中的线性音量为 0 才是可跨重启保留的静音来源。
func set_master_muted(is_muted: bool) -> Dictionary:
	return _set_temporary_mute(MASTER_BUS_NAME, is_muted)


func set_ambience_muted(is_muted: bool) -> Dictionary:
	return _set_temporary_mute(AMBIENCE_BUS_NAME, is_muted)


func set_ui_phone_muted(is_muted: bool) -> Dictionary:
	return _set_temporary_mute(UI_PHONE_BUS_NAME, is_muted)


func get_master_volume() -> float:
	return float(_linear_volume_by_bus[MASTER_BUS_NAME])


func get_ambience_volume() -> float:
	return float(_linear_volume_by_bus[AMBIENCE_BUS_NAME])


func get_ui_phone_volume() -> float:
	return float(_linear_volume_by_bus[UI_PHONE_BUS_NAME])


func is_master_muted() -> bool:
	return _is_bus_muted(MASTER_BUS_NAME)


func is_ambience_muted() -> bool:
	return _is_bus_muted(AMBIENCE_BUS_NAME)


func is_ui_phone_muted() -> bool:
	return _is_bus_muted(UI_PHONE_BUS_NAME)


## 仅返回只读观测数据，便于专项验证；调用方不能据此保存或重建剧情状态。
func get_bus_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	for bus_name: StringName in _get_required_bus_names():
		var bus_index: int = AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			snapshot[String(bus_name)] = {"exists": false}
			continue
		snapshot[String(bus_name)] = {
			"exists": true,
			"linear_volume": float(_linear_volume_by_bus[bus_name]),
			"volume_db": AudioServer.get_bus_volume_db(bus_index),
			"is_muted": AudioServer.is_bus_mute(bus_index),
			"settings_muted": bool(_settings_mute_by_bus[bus_name]),
			"temporary_muted": bool(_temporary_mute_by_bus[bus_name]),
		}
	snapshot.make_read_only()
	return snapshot


func _apply_linear_volume(bus_name: StringName, linear_volume: float) -> Dictionary:
	var validation: Dictionary = _validate_linear_volume(linear_volume)
	if not bool(validation.get("ok", false)):
		return validation
	var bus_index: int = _get_bus_index(bus_name)
	if bus_index < 0:
		return _make_error("missing_bus", "Audio Bus 不存在：%s。" % String(bus_name))

	# 0 使用 bus mute 实现真正静音，并保留上一次非零 dB 以便恢复；非零值才写入
	# 精确 dB。SettingsManager 仍保存原始线性值，AudioManager 不写任何设置文件。
	if linear_volume > 0.0:
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(linear_volume))
	_linear_volume_by_bus[bus_name] = linear_volume
	_settings_mute_by_bus[bus_name] = linear_volume == 0.0
	var was_muted: bool = AudioServer.is_bus_mute(bus_index)
	var is_muted: bool = _apply_resolved_mute(bus_name, bus_index)
	print("[音频][volume_applied] bus=%s linear=%.4f muted=%s。" % [String(bus_name), linear_volume, is_muted])
	bus_volume_applied.emit(bus_name, linear_volume, is_muted)
	if was_muted != is_muted:
		bus_mute_changed.emit(bus_name, is_muted, true)
	return {
		"ok": true,
		"bus_name": String(bus_name),
		"linear_volume": linear_volume,
		"is_muted": is_muted,
	}


func _set_temporary_mute(bus_name: StringName, is_muted: bool) -> Dictionary:
	var bus_index: int = _get_bus_index(bus_name)
	if bus_index < 0:
		return _make_error("missing_bus", "Audio Bus 不存在：%s。" % String(bus_name))
	_temporary_mute_by_bus[bus_name] = is_muted
	var resolved_mute: bool = _apply_resolved_mute(bus_name, bus_index)
	print("[音频][temporary_mute] bus=%s muted=%s。" % [String(bus_name), resolved_mute])
	bus_mute_changed.emit(bus_name, resolved_mute, false)
	return {"ok": true, "bus_name": String(bus_name), "is_muted": resolved_mute, "is_persistent_setting": false}


func _apply_resolved_mute(bus_name: StringName, bus_index: int) -> bool:
	var is_muted: bool = bool(_settings_mute_by_bus[bus_name]) or bool(_temporary_mute_by_bus[bus_name])
	AudioServer.set_bus_mute(bus_index, is_muted)
	return is_muted


func _is_bus_muted(bus_name: StringName) -> bool:
	var bus_index: int = AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return true
	return AudioServer.is_bus_mute(bus_index)


func _connect_settings_manager() -> Dictionary:
	var settings_node: Node = _settings_manager_for_verification
	if settings_node == null:
		settings_node = get_node_or_null(NodePath("/root/SettingsManager")) as Node
	if settings_node == null:
		return _make_error("missing_settings_manager", "未找到 SettingsManager Autoload，无法应用音频设置。")
	if not settings_node.has_signal(&"settings_applied"):
		return _make_error("invalid_settings_contract", "SettingsManager 缺少信号 settings_applied。")
	for method_name: StringName in [&"is_settings_loaded", &"get_master_volume", &"get_ambience_volume", &"get_ui_phone_volume"]:
		if not settings_node.has_method(method_name):
			return _make_error("invalid_settings_contract", "SettingsManager 缺少方法 %s()。" % String(method_name))
	_settings_manager = settings_node
	var applied_callback: Callable = Callable(self, "_on_settings_applied")
	if not _settings_manager.is_connected(&"settings_applied", applied_callback):
		_settings_manager.connect(&"settings_applied", applied_callback)
	return {"ok": true}


func _apply_current_settings() -> Dictionary:
	if _settings_manager == null:
		return _make_error("missing_settings_manager", "SettingsManager 尚未连接，不能读取当前音频设置。")
	var is_loaded_value: Variant = _settings_manager.call(&"is_settings_loaded")
	if typeof(is_loaded_value) != TYPE_BOOL:
		return _make_error("invalid_settings_contract", "SettingsManager.is_settings_loaded() 必须返回布尔值。")
	if not bool(is_loaded_value):
		return _make_error("settings_not_loaded", "设置尚未成功加载，拒绝把内存默认值当作音频设置应用。")
	var settings: Dictionary = {
		String(MASTER_VOLUME_SETTING_ID): _settings_manager.call(&"get_master_volume"),
		String(AMBIENCE_VOLUME_SETTING_ID): _settings_manager.call(&"get_ambience_volume"),
		String(UI_PHONE_VOLUME_SETTING_ID): _settings_manager.call(&"get_ui_phone_volume"),
	}
	return _apply_settings_values(settings)


func _on_settings_applied(settings: Dictionary) -> void:
	var result: Dictionary = _apply_settings_values(settings)
	if not bool(result.get("ok", false)):
		push_error("[音频][settings_applied_invalid] %s" % String(result.get("message", "音频设置无效。")))


func _apply_settings_values(settings: Dictionary) -> Dictionary:
	var bus_by_setting: Dictionary[StringName, StringName] = {
		MASTER_VOLUME_SETTING_ID: MASTER_BUS_NAME,
		AMBIENCE_VOLUME_SETTING_ID: AMBIENCE_BUS_NAME,
		UI_PHONE_VOLUME_SETTING_ID: UI_PHONE_BUS_NAME,
	}
	var validated_values: Dictionary[StringName, float] = {}
	for setting_id: StringName in bus_by_setting:
		var string_setting_id: String = String(setting_id)
		if not settings.has(string_setting_id):
			return _make_error("missing_audio_setting", "SettingsManager 缺少音频设置 %s。" % string_setting_id)
		var validation: Dictionary = _validate_setting_value(string_setting_id, settings[string_setting_id])
		if not bool(validation.get("ok", false)):
			return validation
		validated_values[setting_id] = float(validation["value"])
	for setting_id: StringName in bus_by_setting:
		var result: Dictionary = _apply_linear_volume(bus_by_setting[setting_id], validated_values[setting_id])
		if not bool(result.get("ok", false)):
			return result
	return {"ok": true}


func _validate_setting_value(setting_id: String, value: Variant) -> Dictionary:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return _make_error("invalid_audio_setting_type", "音频设置 %s 必须是 0.0 到 1.0 的数字。" % setting_id)
	return _validate_linear_volume(float(value))


func _validate_linear_volume(linear_volume: float) -> Dictionary:
	if not is_finite(linear_volume) or linear_volume < 0.0 or linear_volume > 1.0:
		return _make_error("invalid_linear_volume", "音量必须是 0.0 到 1.0 之间的有限数值。")
	return {"ok": true, "value": linear_volume}


func _validate_required_buses() -> Dictionary:
	for bus_name: StringName in _get_required_bus_names():
		if AudioServer.get_bus_index(bus_name) < 0:
			return _make_error("missing_bus", "default_bus_layout.tres 缺少必需总线 %s。" % String(bus_name))
	return {"ok": true}


func _get_required_bus_names() -> Array[StringName]:
	return [MASTER_BUS_NAME, AMBIENCE_BUS_NAME, UI_PHONE_BUS_NAME]


func _get_bus_index(bus_name: StringName) -> int:
	return AudioServer.get_bus_index(bus_name)


func _make_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
