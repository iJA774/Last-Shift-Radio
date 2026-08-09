class_name SaveManager
extends RefCounted
## 三槽本地存档的文件边界。
##
## SaveManager 不读取任一运行时对象的私有成员。它只组合各系统明确提供的
## create_snapshot / validate_snapshot / restore_snapshot 契约，并负责 JSON 的完整
## 校验和可恢复的替换写入。剧情内容本身仍由 Main 在恢复时先加载并校验。

const SAVE_FORMAT_VERSION: int = 1
const SLOT_IDS: Array[String] = ["slot_1", "slot_2", "slot_3"]
const DEFAULT_SAVE_DIRECTORY: String = "user://saves"

const REQUIRED_TOP_LEVEL_FIELDS: Array[String] = [
	"save_format_version",
	"saved_at_utc",
	"content_kind",
	"content_format_version",
	"game_clock_state",
	"story_state",
	"phone_state",
	"game_screen_state",
]

var _save_directory: String = DEFAULT_SAVE_DIRECTORY
var _replace_failure_for_verification: bool = false


func _init(save_directory: String = DEFAULT_SAVE_DIRECTORY) -> void:
	var directory_result: Dictionary = set_save_directory(save_directory)
	if not bool(directory_result.get("ok", false)):
		push_error("[存档][init_directory_error] %s" % String(directory_result.get("message", "存档目录初始化失败。")))
		_save_directory = DEFAULT_SAVE_DIRECTORY


## 测试只能注入 user:// 内的隔离目录；玩家流程不会调用此接口。
func set_save_directory(save_directory: String) -> Dictionary:
	if not _is_safe_user_directory(save_directory):
		return _make_error("", "", "invalid_save_directory", "存档目录必须位于 user:// 内，且不能包含父级路径。")
	_save_directory = save_directory.trim_suffix("/")
	return {"ok": true, "save_directory": _save_directory}


func get_save_directory() -> String:
	return _save_directory


func get_slot_ids() -> Array[String]:
	return SLOT_IDS.duplicate()


## 只供 Headless 覆盖“替换失败不得破坏旧档”的边界，绝不接入玩家 UI。
func set_replace_failure_for_verification(is_enabled: bool) -> void:
	_replace_failure_for_verification = is_enabled


func get_slot_summaries(expected_content_kind: String, expected_content_format_version: int) -> Array[Dictionary]:
	var summaries: Array[Dictionary] = []
	for slot_id: String in SLOT_IDS:
		var summary: Dictionary = {
			"slot_id": slot_id,
			"exists": false,
			"is_valid": false,
			"saved_at_utc": "",
			"display_time": "",
			"message": "空槽位",
			"error_code": "",
		}
		var path: String = _get_slot_path(slot_id)
		if FileAccess.file_exists(path):
			summary["exists"] = true
			var load_result: Dictionary = load_slot(slot_id, expected_content_kind, expected_content_format_version)
			if bool(load_result.get("ok", false)):
				var document: Dictionary = load_result["document"] as Dictionary
				summary["is_valid"] = true
				summary["saved_at_utc"] = String(document["saved_at_utc"])
				summary["display_time"] = _format_clock_snapshot(document["game_clock_state"] as Dictionary)
				summary["message"] = "可读取"
			else:
				summary["message"] = "损坏或不兼容：%s" % String(load_result.get("message", "无法读取。"))
				summary["error_code"] = String(load_result.get("error_code", "invalid_slot"))
		summaries.append(summary)
	return summaries


## 同步抓取当刻的全部快照；仅 IDLE/RINGING 可写入。
func save_slot(
	slot_id: String,
	content_metadata: Dictionary,
	game_clock: Object,
	story_engine: Object,
	phone_system: Object,
	game_screen: Object
) -> Dictionary:
	var slot_result: Dictionary = _validate_slot_id(slot_id)
	if not bool(slot_result.get("ok", false)):
		return slot_result
	var metadata_result: Dictionary = _validate_content_metadata(content_metadata)
	if not bool(metadata_result.get("ok", false)):
		return _with_slot(metadata_result, slot_id)
	if phone_system == null or not phone_system.has_method(&"can_save") or not phone_system.has_method(&"get_save_block_reason"):
		return _make_error(slot_id, _get_slot_path(slot_id), "missing_phone_save_contract", "PhoneSystem 缺少 can_save() 或 get_save_block_reason() 存档接口。")
	if not bool(phone_system.call(&"can_save")):
		return _make_error(slot_id, _get_slot_path(slot_id), "save_blocked", String(phone_system.call(&"get_save_block_reason")))

	var snapshots_result: Dictionary = _collect_snapshots(game_clock, story_engine, phone_system, game_screen)
	if not bool(snapshots_result.get("ok", false)):
		return _with_slot(snapshots_result, slot_id)
	var document: Dictionary = {
		"save_format_version": SAVE_FORMAT_VERSION,
		"saved_at_utc": "%sZ" % Time.get_datetime_string_from_system(true, false),
		"content_kind": String(content_metadata["content_kind"]),
		"content_format_version": int(content_metadata["content_format_version"]),
		"game_clock_state": snapshots_result["game_clock_state"],
		"story_state": snapshots_result["story_state"],
		"phone_state": snapshots_result["phone_state"],
		"game_screen_state": snapshots_result["game_screen_state"],
	}
	var document_result: Dictionary = validate_document(document, String(content_metadata["content_kind"]), int(content_metadata["content_format_version"]))
	if not bool(document_result.get("ok", false)):
		return _with_slot(document_result, slot_id)
	var write_result: Dictionary = _write_document_safely(slot_id, document)
	if not bool(write_result.get("ok", false)):
		return write_result
	print("[存档][write_ok] slot_id=%s path=%s saved_at_utc=%s。" % [slot_id, _get_slot_path(slot_id), String(document["saved_at_utc"])])
	return {"ok": true, "slot_id": slot_id, "path": _get_slot_path(slot_id), "document": document.duplicate(true)}


## 只执行文件读取与纯文档结构校验，不会修改当前运行时。
func load_slot(slot_id: String, expected_content_kind: String, expected_content_format_version: int) -> Dictionary:
	var slot_result: Dictionary = _validate_slot_id(slot_id)
	if not bool(slot_result.get("ok", false)):
		return slot_result
	if not _is_expected_content_supported(expected_content_kind, expected_content_format_version):
		return _make_error(slot_id, _get_slot_path(slot_id), "unknown_content_version", "当前版本不支持该剧情内容版本，拒绝读取存档。")
	var path: String = _get_slot_path(slot_id)
	if not FileAccess.file_exists(path):
		return _make_error(slot_id, path, "slot_empty", "该槽位没有存档。")
	var read_result: Dictionary = _read_document(path, slot_id)
	if not bool(read_result.get("ok", false)):
		return read_result
	var validation: Dictionary = validate_document(read_result["document"] as Dictionary, expected_content_kind, expected_content_format_version)
	if not bool(validation.get("ok", false)):
		return _with_slot(validation, slot_id, path)
	return {"ok": true, "slot_id": slot_id, "path": path, "document": (read_result["document"] as Dictionary).duplicate(true)}


## 完成内容加载和对象构造后，由 Main 在任何状态替换前执行系统级严格校验。
## Main 按依赖顺序恢复隔离的新对象时使用。仍只调用对象的公开校验合同，
## 绝不访问其私有状态；例如 StoryEngine 必须在 PhoneSystem 已恢复并绑定后校验。
func validate_component_snapshot(component_name: String, target: Object, snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if target == null or not target.has_method(&"validate_snapshot"):
		return _make_error("", "", "missing_snapshot_contract", "%s 缺少 validate_snapshot() 存档接口。" % component_name)
	var result: Variant = target.callv(&"validate_snapshot", [snapshot, context])
	if not _is_ok_result(result):
		return _make_error("", "", "runtime_snapshot_invalid", "%s 存档状态校验失败：%s" % [component_name, _describe_result(result)])
	return {"ok": true}


func _collect_snapshots(game_clock: Object, story_engine: Object, phone_system: Object, game_screen: Object) -> Dictionary:
	var mappings: Array[Dictionary] = [
		{"key": "game_clock_state", "name": "GameClock", "object": game_clock},
		{"key": "story_state", "name": "StoryEngine", "object": story_engine},
		{"key": "phone_state", "name": "PhoneSystem", "object": phone_system},
		{"key": "game_screen_state", "name": "GameScreen", "object": game_screen},
	]
	var result: Dictionary = {"ok": true}
	for mapping: Dictionary in mappings:
		var target: Object = mapping["object"] as Object
		if target == null or not target.has_method(&"create_snapshot"):
			return _make_error("", "", "missing_snapshot_contract", "%s 缺少 create_snapshot() 存档接口。" % String(mapping["name"]))
		var raw_snapshot: Variant = target.call(&"create_snapshot")
		var snapshot_result: Dictionary = _unwrap_snapshot_result(raw_snapshot, String(mapping["name"]))
		if not bool(snapshot_result.get("ok", false)):
			return snapshot_result
		result[String(mapping["key"])] = snapshot_result["snapshot"]
	return result


func validate_document(document: Dictionary, expected_content_kind: String, expected_content_format_version: int) -> Dictionary:
	if document.is_empty():
		return _make_error("", "", "empty_document", "存档顶层对象不能为空。")
	for field_name: String in REQUIRED_TOP_LEVEL_FIELDS:
		if not document.has(field_name):
			return _make_error("", "", "missing_field", "存档缺少必填字段：%s。" % field_name)
	for field_name_variant: Variant in document.keys():
		if typeof(field_name_variant) != TYPE_STRING or not REQUIRED_TOP_LEVEL_FIELDS.has(String(field_name_variant)):
			return _make_error("", "", "unknown_top_level_field", "存档包含当前格式不允许的顶层字段：%s。" % str(field_name_variant))
	var save_version_result: Dictionary = _read_exact_integer(document["save_format_version"])
	if not bool(save_version_result.get("ok", false)) or int(save_version_result["value"]) != SAVE_FORMAT_VERSION:
		return _make_error("", "", "unsupported_save_format_version", "存档格式版本不受支持，拒绝读取。")
	if not _is_valid_utc_timestamp(document["saved_at_utc"]):
		return _make_error("", "", "invalid_saved_at_utc", "存档保存时间必须是可解析的 ISO 8601 UTC 时间戳（以 Z 结尾）。")
	if not _is_expected_content_supported(expected_content_kind, expected_content_format_version):
		return _make_error("", "", "unknown_content_version", "当前版本不支持请求的剧情内容版本。")
	if typeof(document["content_kind"]) != TYPE_STRING or String(document["content_kind"]) != expected_content_kind:
		return _make_error("", "", "unknown_content_kind", "存档剧情内容类型不匹配，拒绝读取。")
	var content_version_result: Dictionary = _read_exact_integer(document["content_format_version"])
	if not bool(content_version_result.get("ok", false)) or int(content_version_result["value"]) != expected_content_format_version:
		return _make_error("", "", "unknown_content_version", "存档剧情内容版本不匹配，拒绝读取。")
	for field_name: String in ["game_clock_state", "story_state", "phone_state", "game_screen_state"]:
		if not document[field_name] is Dictionary or (document[field_name] as Dictionary).is_empty():
			return _make_error("", "", "invalid_snapshot_shape", "存档字段 %s 必须是非空对象。" % field_name)
	return {"ok": true}


func _write_document_safely(slot_id: String, document: Dictionary) -> Dictionary:
	var directory_result: Dictionary = _ensure_save_directory(slot_id)
	if not bool(directory_result.get("ok", false)):
		return directory_result
	var path: String = _get_slot_path(slot_id)
	var temporary_path: String = _get_temporary_path(slot_id)
	var backup_path: String = _get_backup_path(slot_id)
	var json_text: String = JSON.stringify(document, "\t")
	var write_result: Dictionary = _write_text(temporary_path, json_text, slot_id)
	if not bool(write_result.get("ok", false)):
		return write_result
	# 写完后从磁盘重新完整解析和校验，绝不把仅在内存里合法的数据当成成功。
	var verify_result: Dictionary = _read_document(temporary_path, slot_id)
	if not bool(verify_result.get("ok", false)):
		_remove_file_if_exists(temporary_path)
		return verify_result
	var schema_result: Dictionary = validate_document(verify_result["document"] as Dictionary, String(document["content_kind"]), int(document["content_format_version"]))
	if not bool(schema_result.get("ok", false)):
		_remove_file_if_exists(temporary_path)
		return _with_slot(schema_result, slot_id, temporary_path)
	return _replace_with_backup(slot_id, temporary_path, path, backup_path)


func _replace_with_backup(slot_id: String, temporary_path: String, target_path: String, backup_path: String) -> Dictionary:
	_remove_file_if_exists(backup_path)
	var target_existed: bool = FileAccess.file_exists(target_path)
	if target_existed:
		var backup_result: Error = DirAccess.rename_absolute(target_path, backup_path)
		if backup_result != OK:
			_remove_file_if_exists(temporary_path)
			return _make_error(slot_id, target_path, "backup_rename_failed", "保存失败：无法保护原有存档，旧档未被覆盖。")
	if _replace_failure_for_verification:
		var injected_restore: Dictionary = _restore_backup_if_needed(slot_id, backup_path, target_path, target_existed)
		_remove_file_if_exists(temporary_path)
		if not bool(injected_restore.get("ok", false)):
			return injected_restore
		return _make_error(slot_id, target_path, "replace_failed", "保存失败：测试注入了替换失败，已保留原有存档。")
	var replace_result: Error = DirAccess.rename_absolute(temporary_path, target_path)
	if replace_result != OK:
		var restore_result: Dictionary = _restore_backup_if_needed(slot_id, backup_path, target_path, target_existed)
		_remove_file_if_exists(temporary_path)
		if not bool(restore_result.get("ok", false)):
			return restore_result
		return _make_error(slot_id, target_path, "replace_failed", "保存失败：无法替换槽位文件，已尝试恢复原有存档。")
	if target_existed:
		_remove_file_if_exists(backup_path)
	return {"ok": true, "slot_id": slot_id, "path": target_path}


func _restore_backup_if_needed(slot_id: String, backup_path: String, target_path: String, target_existed: bool) -> Dictionary:
	if not target_existed:
		return {"ok": true}
	var restore_result: Error = DirAccess.rename_absolute(backup_path, target_path)
	if restore_result != OK:
		return _make_error(slot_id, target_path, "backup_restore_failed", "保存替换失败且无法恢复原有存档；请勿关闭游戏并立即检查磁盘。")
	return {"ok": true}


func _read_document(path: String, slot_id: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _make_error(slot_id, path, "file_open_failed", "无法打开存档文件。")
	var source_text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(source_text)
	if parse_error != OK:
		return _make_error(slot_id, path, "invalid_json", "存档 JSON 损坏，已拒绝读取。")
	var data: Variant = json.data
	if not data is Dictionary:
		return _make_error(slot_id, path, "top_level_not_object", "存档顶层必须是对象，已拒绝读取。")
	return {"ok": true, "document": (data as Dictionary).duplicate(true)}


func _write_text(path: String, text_value: String, slot_id: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _make_error(slot_id, path, "temporary_write_failed", "无法创建临时存档文件。")
	file.store_string(text_value)
	file.flush()
	file.close()
	return {"ok": true}


func _ensure_save_directory(slot_id: String) -> Dictionary:
	var error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_save_directory))
	if error != OK:
		return _make_error(slot_id, _save_directory, "save_directory_create_failed", "无法创建 user:// 存档目录。")
	return {"ok": true}


func _validate_slot_id(slot_id: String) -> Dictionary:
	if not SLOT_IDS.has(slot_id):
		return _make_error(slot_id, "", "invalid_slot_id", "存档槽位无效，只支持槽位 1 至 3。")
	return {"ok": true}


func _validate_content_metadata(content_metadata: Dictionary) -> Dictionary:
	if not content_metadata.has("content_kind") or not content_metadata.has("content_format_version"):
		return _make_error("", "", "missing_content_metadata", "当前剧情缺少 content_kind 或 content_format_version，不能保存。")
	if typeof(content_metadata["content_kind"]) != TYPE_STRING or typeof(content_metadata["content_format_version"]) != TYPE_INT:
		return _make_error("", "", "invalid_content_metadata", "当前剧情内容元数据类型无效，不能保存。")
	if not _is_expected_content_supported(String(content_metadata["content_kind"]), int(content_metadata["content_format_version"])):
		return _make_error("", "", "unknown_content_version", "当前剧情内容版本不受存档系统支持。")
	return {"ok": true}


func _is_expected_content_supported(content_kind: String, content_format_version: int) -> bool:
	# 当前 MVP 只有这一份经校验的夜班内容；未来内容版本必须显式扩展此处。
	return content_kind == "test_night_story" and content_format_version == 1


func _unwrap_snapshot_result(raw_value: Variant, component_name: String) -> Dictionary:
	if not raw_value is Dictionary:
		return _make_error("", "", "invalid_snapshot_result", "%s.create_snapshot() 必须返回 Dictionary。" % component_name)
	var result: Dictionary = raw_value as Dictionary
	if result.has("ok"):
		if not bool(result.get("ok", false)):
			return _make_error("", "", "snapshot_failed", "%s 快照失败：%s" % [component_name, _describe_result(result)])
		if not result.get("snapshot") is Dictionary:
			return _make_error("", "", "invalid_snapshot_result", "%s 快照结果缺少 snapshot 对象。" % component_name)
		return {"ok": true, "snapshot": (result["snapshot"] as Dictionary).duplicate(true)}
	return {"ok": true, "snapshot": result.duplicate(true)}


func _format_clock_snapshot(clock_snapshot: Dictionary) -> String:
	var tick_result: Dictionary = _read_exact_integer(clock_snapshot.get("current_game_tick", clock_snapshot.get("game_tick", -1)))
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return "时刻未知"
	var absolute_minutes: int = 60 + int(tick_result["value"]) / 60
	return "%02d:%02d" % [absolute_minutes / 60, absolute_minutes % 60]


func _get_slot_path(slot_id: String) -> String:
	return "%s/%s.json" % [_save_directory, slot_id]


func _get_temporary_path(slot_id: String) -> String:
	return "%s/%s.tmp" % [_save_directory, slot_id]


func _get_backup_path(slot_id: String) -> String:
	return "%s/%s.bak" % [_save_directory, slot_id]


func _is_safe_user_directory(path: String) -> bool:
	var normalized: String = path.replace("\\", "/").trim_suffix("/")
	return normalized.begins_with("user://") and not normalized.contains("..") and normalized.length() > "user://".length()


func _remove_file_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		var remove_error: Error = DirAccess.remove_absolute(path)
		if remove_error != OK:
			push_error("[存档][cleanup_failed] path=%s error=%d。" % [path, remove_error])


## JSON 解析会把数值读为 float；这里仍只接受有限且数学上精确的整数，避免
## 1.5、NaN 或过大值伪装成版本/tick。
func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	if number < -9_223_372_036_854_775_808.0 or number > 9_223_372_036_854_775_807.0:
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _is_valid_utc_timestamp(value: Variant) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var timestamp: String = String(value)
	var expression: RegEx = RegEx.new()
	if expression.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") != OK:
		push_error("[存档][utc_regex_compile_failed] 内部 UTC 校验正则无法编译。")
		return false
	if expression.search(timestamp) == null:
		return false
	# Time 接受无时区的 ISO 主体；Z 已由上面的形状检查明确限定为 UTC。
	var parsed: Dictionary = Time.get_datetime_dict_from_datetime_string(timestamp.left(-1), false)
	for field_name: String in ["year", "month", "day", "hour", "minute", "second"]:
		if not parsed.has(field_name) or typeof(parsed[field_name]) != TYPE_INT:
			return false
	var year: int = int(parsed["year"])
	var month: int = int(parsed["month"])
	var day: int = int(parsed["day"])
	var hour: int = int(parsed["hour"])
	var minute: int = int(parsed["minute"])
	var second: int = int(parsed["second"])
	if year < 1 or month < 1 or month > 12 or hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
		return false
	var days_in_month: Array[int] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and _is_leap_year(year):
		days_in_month[1] = 29
	return day >= 1 and day <= days_in_month[month - 1]


func _is_leap_year(year: int) -> bool:
	return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0


func _with_slot(result: Dictionary, slot_id: String, path: String = "") -> Dictionary:
	var enriched: Dictionary = result.duplicate(true)
	enriched["slot_id"] = slot_id
	if not path.is_empty():
		enriched["path"] = path
	elif not enriched.has("path"):
		enriched["path"] = _get_slot_path(slot_id)
	return enriched


func _make_error(slot_id: String, path: String, error_code: String, message: String) -> Dictionary:
	printerr("[存档][%s][%s] slot_id=%s path=%s" % [error_code, message, slot_id, path])
	return {"ok": false, "slot_id": slot_id, "path": path, "error_code": error_code, "message": message}


func _is_ok_result(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))


func _describe_result(result: Variant) -> String:
	if result is Dictionary:
		return String((result as Dictionary).get("message", str(result)))
	return str(result)
