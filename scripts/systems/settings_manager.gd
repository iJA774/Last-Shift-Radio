class_name SettingsManagerService
extends Node
## 全局用户设置的唯一持久化边界。
##
## 本模块只负责独立的 user://settings.json。它不读取 StoryEngine、GameClock
## 或 SaveManager，也绝不把设置快照写入三个剧情槽。其他系统通过信号取得已
## 校验的设置并立即应用，而不是各自保留一份可持久化的设置副本。

signal setting_changed(setting_id: String, value: Variant)
signal settings_applied(settings: Dictionary)

const FORMAT_VERSION: int = 1
const DEFAULT_SETTINGS_PATH: String = "user://settings.json"

const SETTING_MASTER_VOLUME: String = "master_volume"
const SETTING_AMBIENCE_VOLUME: String = "ambience_volume"
const SETTING_UI_PHONE_VOLUME: String = "ui_phone_volume"
const SETTING_WINDOW_MODE: String = "window_mode"
const SETTING_TEXT_SPEED: String = "text_speed"
const SETTING_FONT_SIZE: String = "font_size"
const SETTING_REDUCE_FLASHING: String = "reduce_flashing"
const SETTING_CRT_ENABLED: String = "crt_enabled"

const WINDOW_MODE_WINDOWED: String = "windowed"
const WINDOW_MODE_FULLSCREEN: String = "fullscreen"

const MIN_VOLUME: float = 0.0
const MAX_VOLUME: float = 1.0
const MIN_TEXT_SPEED: float = 0.25
const MAX_TEXT_SPEED: float = 4.0
const FONT_SIZE_DEFAULT: int = 100
const FONT_SIZE_LARGE: int = 125

const REQUIRED_TOP_LEVEL_FIELDS: Array[String] = [
	"format_version",
	"settings",
]

const REQUIRED_SETTING_FIELDS: Array[String] = [
	SETTING_MASTER_VOLUME,
	SETTING_AMBIENCE_VOLUME,
	SETTING_UI_PHONE_VOLUME,
	SETTING_WINDOW_MODE,
	SETTING_TEXT_SPEED,
	SETTING_FONT_SIZE,
	SETTING_REDUCE_FLASHING,
	SETTING_CRT_ENABLED,
]

const DEFAULT_SETTINGS: Dictionary = {
	SETTING_MASTER_VOLUME: 1.0,
	SETTING_AMBIENCE_VOLUME: 1.0,
	SETTING_UI_PHONE_VOLUME: 1.0,
	SETTING_WINDOW_MODE: WINDOW_MODE_WINDOWED,
	SETTING_TEXT_SPEED: 1.0,
	SETTING_FONT_SIZE: FONT_SIZE_DEFAULT,
	SETTING_REDUCE_FLASHING: false,
	SETTING_CRT_ENABLED: true,
}

var _settings_path: String = DEFAULT_SETTINGS_PATH
var _settings: Dictionary = DEFAULT_SETTINGS.duplicate(true)
var _is_loaded: bool = false
var _last_load_result: Dictionary = {
	"ok": false,
	"error_code": "not_loaded",
	"message": "设置尚未加载。",
}
var _replace_failure_for_verification: bool = false


func _ready() -> void:
	var verification_path_result: Dictionary = _apply_verification_path_from_command_line()
	if not bool(verification_path_result.get("ok", false)):
		push_error(
			"[设置][verification_path_invalid] error_code=%s message=%s。"
			% [String(verification_path_result.get("error_code", "unknown")), String(verification_path_result.get("message", "验证路径无效。"))]
		)
		return
	var load_result: Dictionary = load_settings()
	if not bool(load_result.get("ok", false)):
		push_error(
			"[设置][load_failed] path=%s error_code=%s message=%s。"
			% [_settings_path, String(load_result.get("error_code", "unknown")), String(load_result.get("message", "设置加载失败。"))]
		)


## 已存在文件只有完整校验通过后才替换内存设置。首次运行没有文件时，默认设置
## 会先写入并读回校验；写入失败同样返回失败，绝不把未落盘的默认值当作成功。
func load_settings() -> Dictionary:
	if not FileAccess.file_exists(_settings_path):
		var backup_path: String = _get_backup_path()
		if FileAccess.file_exists(backup_path):
			var recovery_result: Dictionary = _recover_backup_on_startup(backup_path)
			_last_load_result = recovery_result.duplicate(true)
			if not bool(recovery_result.get("ok", false)):
				_is_loaded = false
			return recovery_result
		var defaults: Dictionary = DEFAULT_SETTINGS.duplicate(true)
		var create_result: Dictionary = _write_settings_document(defaults)
		if not bool(create_result.get("ok", false)):
			_is_loaded = false
			_last_load_result = create_result.duplicate(true)
			return create_result
		_settings = defaults
		_is_loaded = true
		_last_load_result = {
			"ok": true,
			"created_defaults": true,
			"path": _settings_path,
		}
		_emit_settings_applied([])
		print("[设置][defaults_created] path=%s format_version=%d。" % [_settings_path, FORMAT_VERSION])
		return _last_load_result.duplicate(true)

	var read_result: Dictionary = _read_document(_settings_path)
	if not bool(read_result.get("ok", false)):
		_is_loaded = false
		_last_load_result = read_result.duplicate(true)
		return read_result
	var validation_result: Dictionary = validate_document(read_result["document"] as Dictionary)
	if not bool(validation_result.get("ok", false)):
		_is_loaded = false
		_last_load_result = _with_path(validation_result, _settings_path)
		return _last_load_result.duplicate(true)

	_settings = (validation_result["settings"] as Dictionary).duplicate(true)
	_is_loaded = true
	_last_load_result = {
		"ok": true,
		"created_defaults": false,
		"path": _settings_path,
	}
	_emit_settings_applied([])
	print("[设置][load_ok] path=%s format_version=%d。" % [_settings_path, FORMAT_VERSION])
	return _last_load_result.duplicate(true)


## 写入过程曾将旧文件移到 .bak、但新文件尚未来得及替换时，重启必须把 .bak
## 视为唯一可信候选。损坏备份绝不能触发默认设置写入，否则会抹掉可诊断证据。
func _recover_backup_on_startup(backup_path: String) -> Dictionary:
	var read_result: Dictionary = _read_document(backup_path)
	if not bool(read_result.get("ok", false)):
		return _make_backup_recovery_error(
			"backup_invalid",
			backup_path,
			"发现未完成替换留下的备份，但无法读取；已拒绝创建默认设置。",
			String(read_result.get("error_code", "file_open_failed"))
		)
	var validation_result: Dictionary = validate_document(read_result["document"] as Dictionary)
	if not bool(validation_result.get("ok", false)):
		return _make_backup_recovery_error(
			"backup_invalid",
			backup_path,
			"发现未完成替换留下的备份，但格式无效；已拒绝创建默认设置。",
			String(validation_result.get("error_code", "invalid_document"))
		)
	var restore_result: Error = DirAccess.rename_absolute(backup_path, _settings_path)
	if restore_result != OK:
		return _make_backup_recovery_error(
			"backup_restore_failed",
			backup_path,
			"发现有效设置备份，但无法恢复为 settings.json；原备份已保留。",
			str(restore_result)
		)
	_settings = (validation_result["settings"] as Dictionary).duplicate(true)
	_is_loaded = true
	_last_load_result = {
		"ok": true,
		"recovered_backup": true,
		"path": _settings_path,
		"backup_path": backup_path,
	}
	_emit_settings_applied([])
	print("[设置][backup_recovered] path=%s backup_path=%s。" % [_settings_path, backup_path])
	return _last_load_result.duplicate(true)


## 显式重新保存当前已经校验的完整设置。没有成功加载过设置时拒绝保存，防止
## 损坏文件在后台被默认值悄悄覆盖。
func save_settings() -> Dictionary:
	if not _is_loaded:
		return _make_error("settings_not_loaded", "设置未成功加载，拒绝覆盖设置文件。")
	var validation_result: Dictionary = _validate_settings(_settings)
	if not bool(validation_result.get("ok", false)):
		return validation_result
	var write_result: Dictionary = _write_settings_document(validation_result["settings"] as Dictionary)
	if not bool(write_result.get("ok", false)):
		return write_result
	print("[设置][save_ok] path=%s format_version=%d。" % [_settings_path, FORMAT_VERSION])
	return {
		"ok": true,
		"path": _settings_path,
		"settings": get_settings_snapshot(),
	}


## 这是有意的恢复操作：即使已有文件损坏，也可以用确认默认值替换它。
func reset_to_defaults() -> Dictionary:
	return _commit_candidate(DEFAULT_SETTINGS.duplicate(true), REQUIRED_SETTING_FIELDS.duplicate())


## 仅供设置文件写入、重新加载与验证使用；剧情存档不得调用或嵌入此快照。
func get_settings_snapshot() -> Dictionary:
	return _settings.duplicate(true)


func is_settings_loaded() -> bool:
	return _is_loaded


func get_last_load_result() -> Dictionary:
	return _last_load_result.duplicate(true)


func get_settings_path() -> String:
	return _settings_path


func get_master_volume() -> float:
	return float(_settings[SETTING_MASTER_VOLUME])


func set_master_volume(value: float) -> Dictionary:
	return _set_single_value(SETTING_MASTER_VOLUME, value)


func get_ambience_volume() -> float:
	return float(_settings[SETTING_AMBIENCE_VOLUME])


func set_ambience_volume(value: float) -> Dictionary:
	return _set_single_value(SETTING_AMBIENCE_VOLUME, value)


func get_ui_phone_volume() -> float:
	return float(_settings[SETTING_UI_PHONE_VOLUME])


func set_ui_phone_volume(value: float) -> Dictionary:
	return _set_single_value(SETTING_UI_PHONE_VOLUME, value)


func get_window_mode() -> String:
	return String(_settings[SETTING_WINDOW_MODE])


func is_fullscreen() -> bool:
	return get_window_mode() == WINDOW_MODE_FULLSCREEN


func set_window_mode(value: String) -> Dictionary:
	return _set_single_value(SETTING_WINDOW_MODE, value)


func set_fullscreen(is_enabled: bool) -> Dictionary:
	return set_window_mode(WINDOW_MODE_FULLSCREEN if is_enabled else WINDOW_MODE_WINDOWED)


## 数值是显示速度倍率；1.0 为默认速度，较大值表示较快。
func get_text_speed() -> float:
	return float(_settings[SETTING_TEXT_SPEED])


func set_text_speed(value: float) -> Dictionary:
	return _set_single_value(SETTING_TEXT_SPEED, value)


## 当前 MVP 只支持 100% 与 125% 两档，避免无验证的任意比例破坏布局。
func get_font_size() -> int:
	return int(_settings[SETTING_FONT_SIZE])


func set_font_size(value: int) -> Dictionary:
	return _set_single_value(SETTING_FONT_SIZE, value)


func is_reduce_flashing_enabled() -> bool:
	return bool(_settings[SETTING_REDUCE_FLASHING])


func set_reduce_flashing_enabled(is_enabled: bool) -> Dictionary:
	return _set_single_value(SETTING_REDUCE_FLASHING, is_enabled)


func is_crt_enabled() -> bool:
	return bool(_settings[SETTING_CRT_ENABLED])


func set_crt_enabled(is_enabled: bool) -> Dictionary:
	return _set_single_value(SETTING_CRT_ENABLED, is_enabled)


## 严格校验外部 JSON 文档；成功时返回规范化后的 settings 深拷贝，不修改当前状态。
func validate_document(document: Dictionary) -> Dictionary:
	if document.is_empty():
		return _make_error("empty_document", "设置文件顶层对象不能为空。")
	var top_level_result: Dictionary = _validate_exact_fields(document, REQUIRED_TOP_LEVEL_FIELDS, "顶层")
	if not bool(top_level_result.get("ok", false)):
		return top_level_result
	var version_result: Dictionary = _read_exact_integer(document["format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result.get("value", -1)) != FORMAT_VERSION:
		return _make_error("unsupported_format_version", "设置格式版本不受支持，拒绝读取。")
	if not document["settings"] is Dictionary:
		return _make_error("invalid_settings_type", "设置字段 settings 必须是对象。")
	return _validate_settings(document["settings"] as Dictionary)


## 测试只能指定 user:// 下的隔离路径；玩家流程不应调用此接口。
func set_settings_path_for_verification(settings_path: String) -> Dictionary:
	if not _is_safe_user_file_path(settings_path):
		return _make_error("invalid_settings_path", "测试设置路径必须位于 user:// 内、以 .json 结尾且不包含父级路径。")
	_settings_path = settings_path
	_settings = DEFAULT_SETTINGS.duplicate(true)
	_is_loaded = false
	_last_load_result = {
		"ok": false,
		"error_code": "not_loaded",
		"message": "测试设置路径已变更，尚未加载。",
	}
	return {"ok": true, "path": _settings_path}


## 仅供 Headless 验证替换失败时旧文件与进程内设置都不被破坏。
func set_replace_failure_for_verification(is_enabled: bool) -> void:
	_replace_failure_for_verification = is_enabled


func _set_single_value(setting_id: String, value: Variant) -> Dictionary:
	if not _is_loaded:
		return _make_error("settings_not_loaded", "设置未成功加载，不能修改。")
	if not REQUIRED_SETTING_FIELDS.has(setting_id):
		return _make_error("unknown_setting_id", "未知设置项：%s。" % setting_id)
	var candidate: Dictionary = _settings.duplicate(true)
	candidate[setting_id] = value
	return _commit_candidate(candidate, [setting_id])


func _commit_candidate(candidate: Dictionary, changed_setting_ids: Array[String]) -> Dictionary:
	var validation_result: Dictionary = _validate_settings(candidate)
	if not bool(validation_result.get("ok", false)):
		return validation_result
	var normalized: Dictionary = validation_result["settings"] as Dictionary
	var changed_ids: Array[String] = []
	for setting_id: String in changed_setting_ids:
		if not _settings.has(setting_id) or _settings[setting_id] != normalized[setting_id]:
			changed_ids.append(setting_id)
	var write_result: Dictionary = _write_settings_document(normalized)
	if not bool(write_result.get("ok", false)):
		return write_result
	_settings = normalized.duplicate(true)
	_is_loaded = true
	_last_load_result = {
		"ok": true,
		"created_defaults": false,
		"path": _settings_path,
	}
	_emit_settings_applied(changed_ids)
	print("[设置][apply_ok] path=%s changed=%s。" % [_settings_path, ",".join(changed_ids)])
	return {
		"ok": true,
		"path": _settings_path,
		"settings": get_settings_snapshot(),
	}


func _emit_settings_applied(changed_setting_ids: Array[String]) -> void:
	for setting_id: String in changed_setting_ids:
		setting_changed.emit(setting_id, _settings[setting_id])
	settings_applied.emit(get_settings_snapshot())


func _validate_settings(settings: Dictionary) -> Dictionary:
	var fields_result: Dictionary = _validate_exact_fields(settings, REQUIRED_SETTING_FIELDS, "settings")
	if not bool(fields_result.get("ok", false)):
		return fields_result
	var normalized: Dictionary = {}
	for setting_id: String in [SETTING_MASTER_VOLUME, SETTING_AMBIENCE_VOLUME, SETTING_UI_PHONE_VOLUME]:
		var volume_result: Dictionary = _read_finite_number(settings[setting_id])
		if not bool(volume_result.get("ok", false)):
			return _make_error("invalid_setting_type", "设置项 %s 必须是数值。" % setting_id)
		var volume: float = float(volume_result["value"])
		if volume < MIN_VOLUME or volume > MAX_VOLUME:
			return _make_error("setting_out_of_range", "设置项 %s 必须在 %.2f 到 %.2f 之间。" % [setting_id, MIN_VOLUME, MAX_VOLUME])
		normalized[setting_id] = volume
	if typeof(settings[SETTING_WINDOW_MODE]) != TYPE_STRING or not [WINDOW_MODE_WINDOWED, WINDOW_MODE_FULLSCREEN].has(String(settings[SETTING_WINDOW_MODE])):
		return _make_error("invalid_window_mode", "设置项 window_mode 只能是 windowed 或 fullscreen。")
	normalized[SETTING_WINDOW_MODE] = String(settings[SETTING_WINDOW_MODE])
	var text_speed_result: Dictionary = _read_finite_number(settings[SETTING_TEXT_SPEED])
	if not bool(text_speed_result.get("ok", false)):
		return _make_error("invalid_setting_type", "设置项 text_speed 必须是数值倍率。")
	var text_speed: float = float(text_speed_result["value"])
	if text_speed < MIN_TEXT_SPEED or text_speed > MAX_TEXT_SPEED:
		return _make_error("setting_out_of_range", "设置项 text_speed 必须在 %.2f 到 %.2f 倍之间。" % [MIN_TEXT_SPEED, MAX_TEXT_SPEED])
	normalized[SETTING_TEXT_SPEED] = text_speed
	var font_size_result: Dictionary = _read_exact_integer(settings[SETTING_FONT_SIZE])
	if not bool(font_size_result.get("ok", false)) or not [FONT_SIZE_DEFAULT, FONT_SIZE_LARGE].has(int(font_size_result.get("value", -1))):
		return _make_error("invalid_font_size", "设置项 font_size 只能是 100 或 125。")
	normalized[SETTING_FONT_SIZE] = int(font_size_result["value"])
	for setting_id: String in [SETTING_REDUCE_FLASHING, SETTING_CRT_ENABLED]:
		if typeof(settings[setting_id]) != TYPE_BOOL:
			return _make_error("invalid_setting_type", "设置项 %s 必须是布尔值。" % setting_id)
		normalized[setting_id] = bool(settings[setting_id])
	return {"ok": true, "settings": normalized}


func _validate_exact_fields(data: Dictionary, required_fields: Array[String], section_name: String) -> Dictionary:
	for field_name: String in required_fields:
		if not data.has(field_name):
			return _make_error("missing_field", "%s缺少必填字段：%s。" % [section_name, field_name])
	for field_name_variant: Variant in data.keys():
		if typeof(field_name_variant) != TYPE_STRING or not required_fields.has(String(field_name_variant)):
			return _make_error("unknown_field", "%s包含当前格式不允许的字段：%s。" % [section_name, str(field_name_variant)])
	return {"ok": true}


func _write_settings_document(settings: Dictionary) -> Dictionary:
	var directory_result: Dictionary = _ensure_parent_directory()
	if not bool(directory_result.get("ok", false)):
		return directory_result
	var document: Dictionary = {
		"format_version": FORMAT_VERSION,
		"settings": settings.duplicate(true),
	}
	var document_result: Dictionary = validate_document(document)
	if not bool(document_result.get("ok", false)):
		return document_result
	var temporary_path: String = _get_temporary_path()
	var backup_path: String = _get_backup_path()
	var write_result: Dictionary = _write_text(temporary_path, JSON.stringify(document, "\t"))
	if not bool(write_result.get("ok", false)):
		return write_result
	# 重新读取临时文件，确保写入介质中的 JSON 和 schema 同样完整合法。
	var verify_result: Dictionary = _read_document(temporary_path)
	if not bool(verify_result.get("ok", false)):
		_remove_file_if_exists(temporary_path)
		return verify_result
	var verify_schema_result: Dictionary = validate_document(verify_result["document"] as Dictionary)
	if not bool(verify_schema_result.get("ok", false)):
		_remove_file_if_exists(temporary_path)
		return _with_path(verify_schema_result, temporary_path)
	return _replace_with_backup(temporary_path, _settings_path, backup_path)


func _replace_with_backup(temporary_path: String, target_path: String, backup_path: String) -> Dictionary:
	_remove_file_if_exists(backup_path)
	var target_existed: bool = FileAccess.file_exists(target_path)
	if target_existed:
		var backup_result: Error = DirAccess.rename_absolute(target_path, backup_path)
		if backup_result != OK:
			_remove_file_if_exists(temporary_path)
			return _make_error("backup_rename_failed", "保存失败：无法保护原有设置，旧设置未被覆盖。")
	if _replace_failure_for_verification:
		var injected_restore_result: Dictionary = _restore_backup_if_needed(backup_path, target_path, target_existed)
		_remove_file_if_exists(temporary_path)
		if not bool(injected_restore_result.get("ok", false)):
			return injected_restore_result
		return _make_error("replace_failed", "保存失败：测试注入了替换失败，已保留原有设置。")
	var replace_result: Error = DirAccess.rename_absolute(temporary_path, target_path)
	if replace_result != OK:
		var restore_result: Dictionary = _restore_backup_if_needed(backup_path, target_path, target_existed)
		_remove_file_if_exists(temporary_path)
		if not bool(restore_result.get("ok", false)):
			return restore_result
		return _make_error("replace_failed", "保存失败：无法替换设置文件，已尝试恢复原有设置。")
	if target_existed:
		_remove_file_if_exists(backup_path)
	return {"ok": true, "path": target_path}


func _restore_backup_if_needed(backup_path: String, target_path: String, target_existed: bool) -> Dictionary:
	if not target_existed:
		return {"ok": true}
	var restore_result: Error = DirAccess.rename_absolute(backup_path, target_path)
	if restore_result != OK:
		return _make_error("backup_restore_failed", "保存替换失败且无法恢复原有设置；请勿关闭游戏并立即检查磁盘。")
	return {"ok": true}


func _read_document(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _make_error("file_open_failed", "无法打开设置文件：%s。" % path)
	var source_text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(source_text)
	if parse_error != OK:
		return _make_error("invalid_json", "设置 JSON 损坏，已拒绝读取。")
	if not json.data is Dictionary:
		return _make_error("top_level_not_object", "设置文件顶层必须是对象，已拒绝读取。")
	return {"ok": true, "document": (json.data as Dictionary).duplicate(true)}


func _write_text(path: String, source_text: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _make_error("temporary_write_failed", "无法创建临时设置文件。")
	file.store_string(source_text)
	file.flush()
	file.close()
	return {"ok": true, "path": path}


func _ensure_parent_directory() -> Dictionary:
	var parent_directory: String = _settings_path.get_base_dir()
	var make_directory_result: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent_directory))
	if make_directory_result != OK:
		return _make_error("settings_directory_create_failed", "无法创建设置文件目录：%s。" % parent_directory)
	return {"ok": true}


func _get_temporary_path() -> String:
	return "%s.tmp" % _settings_path


func _get_backup_path() -> String:
	return "%s.bak" % _settings_path


func _is_safe_user_file_path(path: String) -> bool:
	var normalized: String = path.replace("\\", "/")
	return normalized.begins_with("user://") and normalized.ends_with(".json") and not normalized.contains("..")


func _remove_file_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		var remove_result: Error = DirAccess.remove_absolute(path)
		if remove_result != OK:
			push_error("[设置][cleanup_failed] path=%s error=%d。" % [path, remove_result])


func _read_finite_number(value: Variant) -> Dictionary:
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number):
		return {"ok": false}
	return {"ok": true, "value": number}


func _read_exact_integer(value: Variant) -> Dictionary:
	var number_result: Dictionary = _read_finite_number(value)
	if not bool(number_result.get("ok", false)):
		return {"ok": false}
	var number: float = float(number_result["value"])
	if number != floor(number):
		return {"ok": false}
	if number < -9_223_372_036_854_775_808.0 or number > 9_223_372_036_854_775_807.0:
		return {"ok": false}
	return {"ok": true, "value": int(number)}


## 开发验证可选地在 `--` 后传入 `--settings-verification-path=user://...json`，
## 以隔离一次完整 Headless 批跑的 Autoload。它不是测试文件特例，发布构建拒绝此参数。
func _apply_verification_path_from_command_line() -> Dictionary:
	const ARGUMENT_PREFIX: String = "--settings-verification-path="
	var requested_paths: Array[String] = []
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with(ARGUMENT_PREFIX):
			requested_paths.append(argument.trim_prefix(ARGUMENT_PREFIX))
	if requested_paths.is_empty():
		return {"ok": true}
	if not OS.is_debug_build():
		return _make_error("verification_path_unavailable", "设置验证路径仅可在调试或编辑器构建中使用。")
	if requested_paths.size() != 1:
		return _make_error("invalid_settings_path", "设置验证路径参数只能提供一次。")
	return set_settings_path_for_verification(requested_paths[0])


func _with_path(result: Dictionary, path: String) -> Dictionary:
	var with_path: Dictionary = result.duplicate(true)
	with_path["path"] = path
	return with_path


func _make_backup_recovery_error(error_code: String, backup_path: String, message: String, cause_error_code: String) -> Dictionary:
	var result: Dictionary = _make_error(error_code, "%s 备份路径：%s。" % [message, backup_path])
	result["backup_path"] = backup_path
	result["cause_error_code"] = cause_error_code
	return result


func _make_error(error_code: String, message: String) -> Dictionary:
	printerr("[设置][%s] path=%s %s" % [error_code, _settings_path, message])
	return {
		"ok": false,
		"error_code": error_code,
		"message": message,
		"path": _settings_path,
	}
