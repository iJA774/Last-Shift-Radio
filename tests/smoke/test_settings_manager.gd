extends SceneTree
## 第八阶段 SettingsManager 专项冒烟。
##
## 所有可写边界都只使用独立实例与 user://settings_manager_smoke/。Autoload 仅
## 验证公开合同，不重载、重置或改写产品路径 user://settings.json，因此可由统一
## Headless 批处理直接执行而无需额外命令行参数。

const SETTINGS_MANAGER_SCRIPT: GDScript = preload("res://scripts/systems/settings_manager.gd")
const TEST_DIRECTORY: String = "user://settings_manager_smoke"
const AUTOLOAD_VERIFICATION_SETTINGS_PATH: String = "%s/settings_smoke_autoload.json" % TEST_DIRECTORY
const INSTANCE_SETTINGS_PATH: String = "%s/instance_settings.json" % TEST_DIRECTORY
const BACKUP_RECOVERY_SETTINGS_PATH: String = "%s/backup_recovery_settings.json" % TEST_DIRECTORY

var _has_failed: bool = false


func _init() -> void:
	call_deferred(&"_run_tests")


func _run_tests() -> void:
	# SceneTree 的 _init 早于 Autoload _ready；延后一帧才能验证实际单例路径。
	await process_frame
	_cleanup_test_directory()
	_test_autoload_contract()
	_test_first_run_setters_and_restart_persistence()
	_test_strict_rejections_keep_confirmed_state()
	_test_startup_backup_recovery()
	_test_atomic_replace_failure_keeps_old_file_and_memory()
	_cleanup_test_directory()
	if _has_failed:
		push_error("[测试][SettingsManager] 失败。")
		quit(1)
		return
	print("[测试][SettingsManager] 通过：独立路径、重启持久化、严格拒绝与原子替换保护均符合第八阶段契约。")
	quit(0)


func _test_autoload_contract() -> void:
	var autoload: Variant = root.get_node_or_null(NodePath("SettingsManager"))
	_assert_true(autoload != null, "SettingsManager 必须作为全局 Autoload 存在。")
	if autoload == null:
		return
	for method_name: StringName in [&"load_settings", &"save_settings", &"reset_to_defaults", &"get_settings_snapshot", &"is_settings_loaded"]:
		_assert_true(autoload.has_method(method_name), "SettingsManager Autoload 缺少 %s() 合同。" % String(method_name))
	for signal_name: StringName in [&"setting_changed", &"settings_applied"]:
		_assert_true(autoload.has_signal(signal_name), "SettingsManager Autoload 缺少 %s 信号。" % String(signal_name))
	var snapshot_value: Variant = autoload.call(&"get_settings_snapshot")
	_assert_true(snapshot_value is Dictionary, "SettingsManager Autoload 必须公开 Dictionary 设置快照。")
	# 不调用 Autoload 的 load/reset/set：专项测试绝不改写产品路径 user://settings.json。


func _test_first_run_setters_and_restart_persistence() -> void:
	var manager: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(manager.set_settings_path_for_verification(INSTANCE_SETTINGS_PATH), "测试实例必须接受隔离 user:// 路径。")
	var changed_ids: Array[String] = []
	var applied_snapshots: Array[Dictionary] = []
	manager.connect(&"setting_changed", func(setting_id: String, _value: Variant) -> void: changed_ids.append(setting_id))
	manager.connect(&"settings_applied", func(settings: Dictionary) -> void: applied_snapshots.append(settings.duplicate(true)))
	var first_load: Dictionary = manager.load_settings()
	_assert_ok(first_load, "首次加载必须写入确认默认设置。")
	_assert_true(bool(first_load.get("created_defaults", false)), "首次加载必须明确标记 created_defaults。")
	_assert_equal(manager.get_settings_snapshot(), _default_settings(), "首次加载必须得到完整默认设置。")
	_assert_equal(applied_snapshots.size(), 1, "首次加载必须广播一次完整设置。")
	var mutable_snapshot: Dictionary = manager.get_settings_snapshot()
	mutable_snapshot["master_volume"] = 0.01
	_assert_equal(manager.get_master_volume(), 1.0, "设置快照必须是深拷贝，外部修改不得回写。")

	_assert_ok(manager.set_master_volume(0.25), "主音量边界内值必须可保存。")
	_assert_ok(manager.set_ambience_volume(0.5), "环境音量边界内值必须可保存。")
	_assert_ok(manager.set_ui_phone_volume(0.75), "UI/电话音量边界内值必须可保存。")
	_assert_ok(manager.set_fullscreen(true), "全屏开关必须映射为 fullscreen 模式。")
	_assert_ok(manager.set_text_speed(2.5), "文字速度倍率必须可保存。")
	_assert_ok(manager.set_font_size(125), "125% 字体档必须可保存。")
	_assert_ok(manager.set_reduce_flashing_enabled(true), "减少闪烁开关必须可保存。")
	_assert_ok(manager.set_crt_enabled(false), "CRT 开关必须可保存。")
	_assert_equal(changed_ids, ["master_volume", "ambience_volume", "ui_phone_volume", "window_mode", "text_speed", "font_size", "reduce_flashing", "crt_enabled"], "每次变更必须按稳定字段 ID 发出信号。")
	_assert_equal(applied_snapshots.size(), 9, "首次加载和八次成功变更必须各广播一次完整设置。")
	_assert_equal(manager.get_window_mode(), "fullscreen", "set_fullscreen(true) 必须设置 fullscreen。")
	_assert_true(manager.is_fullscreen(), "fullscreen getter 必须返回 true。")
	_assert_equal(manager.get_text_speed(), 2.5, "文字速度 getter 必须返回倍率。")
	_assert_equal(manager.get_font_size(), 125, "字体 getter 必须返回百分比。")
	_assert_true(manager.is_reduce_flashing_enabled(), "减少闪烁 getter 必须返回持久化值。")
	_assert_true(not manager.is_crt_enabled(), "CRT getter 必须返回持久化值。")

	var restarted: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(restarted.set_settings_path_for_verification(INSTANCE_SETTINGS_PATH), "重启实例必须使用相同隔离路径。")
	var restart_result: Dictionary = restarted.load_settings()
	_assert_ok(restart_result, "重启实例必须读取已保存设置。")
	_assert_true(not bool(restart_result.get("created_defaults", true)), "已有设置文件重启读取不得伪报创建默认值。")
	_assert_equal(restarted.get_settings_snapshot(), manager.get_settings_snapshot(), "重启后必须完整保留全部设置。")
	(manager as Node).free()
	(restarted as Node).free()


func _test_strict_rejections_keep_confirmed_state() -> void:
	var manager: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(manager.set_settings_path_for_verification(INSTANCE_SETTINGS_PATH), "严格校验实例必须使用隔离路径。")
	_assert_ok(manager.load_settings(), "严格校验前必须读取一份确认设置。")
	var confirmed_snapshot: Dictionary = manager.get_settings_snapshot()
	_assert_true(not bool(manager.set_master_volume(-0.01).get("ok", false)), "低于零的音量必须被拒绝。")
	_assert_true(not bool(manager.set_text_speed(4.01).get("ok", false)), "超出上限的文字倍率必须被拒绝。")
	_assert_true(not bool(manager.set_font_size(110).get("ok", false)), "未验证字体百分比必须被拒绝。")
	_assert_equal(manager.get_settings_snapshot(), confirmed_snapshot, "setter 校验失败不得改变确认内存状态。")

	var cases: Array[Dictionary] = [
		{"name": "损坏 JSON", "text": "{", "error_code": "invalid_json"},
		{"name": "错误版本", "document": {"format_version": 2, "settings": _default_settings()}, "error_code": "unsupported_format_version"},
		{"name": "缺少字段", "document": {"format_version": 1}, "error_code": "missing_field"},
		{"name": "未知字段", "document": {"format_version": 1, "settings": _settings_with("extra", true)}, "error_code": "unknown_field"},
		{"name": "类型错误", "document": {"format_version": 1, "settings": _settings_with("reduce_flashing", "true")}, "error_code": "invalid_setting_type"},
		{"name": "范围错误", "document": {"format_version": 1, "settings": _settings_with("ui_phone_volume", 1.01)}, "error_code": "setting_out_of_range"},
	]
	for test_case: Dictionary in cases:
		_write_invalid_case(test_case)
		var failed_load: Dictionary = manager.load_settings()
		_assert_true(not bool(failed_load.get("ok", false)), "%s必须被严格拒绝。" % String(test_case["name"]))
		_assert_equal(String(failed_load.get("error_code", "")), String(test_case["error_code"]), "%s必须返回可定位错误码。" % String(test_case["name"]))
		_assert_true(not manager.is_settings_loaded(), "%s后不得伪报设置已加载。" % String(test_case["name"]))
		_assert_equal(manager.get_settings_snapshot(), confirmed_snapshot, "%s后必须保留进程内确认设置。" % String(test_case["name"]))
	# 损坏文件不能让普通保存或单项 setter 静默覆盖；只有显式恢复操作可以修复。
	_assert_true(not bool(manager.save_settings().get("ok", false)), "损坏文件加载失败后普通保存必须拒绝覆盖。")
	_assert_true(not bool(manager.set_master_volume(0.4).get("ok", false)), "损坏文件加载失败后单项修改必须拒绝覆盖。")
	_assert_ok(manager.reset_to_defaults(), "显式恢复默认值必须能替换损坏文件。")
	_assert_true(manager.is_settings_loaded(), "显式恢复默认值后必须回到已加载状态。")
	_assert_equal(manager.get_settings_snapshot(), _default_settings(), "显式恢复必须使用完整默认设置。")
	(manager as Node).free()


func _test_atomic_replace_failure_keeps_old_file_and_memory() -> void:
	var manager: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(manager.set_settings_path_for_verification(INSTANCE_SETTINGS_PATH), "原子替换实例必须使用隔离路径。")
	_assert_ok(manager.load_settings(), "原子替换前必须加载确认设置。")
	_assert_ok(manager.set_master_volume(0.2), "原子替换前必须有旧设置。")
	var previous_document: Dictionary = _read_document_for_test(INSTANCE_SETTINGS_PATH)
	var previous_snapshot: Dictionary = manager.get_settings_snapshot()
	manager.set_replace_failure_for_verification(true)
	var replacement_result: Dictionary = manager.set_master_volume(0.8)
	manager.set_replace_failure_for_verification(false)
	_assert_true(not bool(replacement_result.get("ok", false)), "替换失败必须明确返回失败。")
	_assert_equal(String(replacement_result.get("error_code", "")), "replace_failed", "替换失败必须给出稳定错误码。")
	_assert_equal(manager.get_settings_snapshot(), previous_snapshot, "替换失败不得提交新的内存设置。")
	_assert_equal(_read_document_for_test(INSTANCE_SETTINGS_PATH), previous_document, "替换失败不得破坏旧设置文件。")
	_assert_true(not FileAccess.file_exists("%s.tmp" % INSTANCE_SETTINGS_PATH), "替换失败后临时文件必须清理。")
	_assert_true(not FileAccess.file_exists("%s.bak" % INSTANCE_SETTINGS_PATH), "旧文件恢复后不得遗留备份文件。")
	(manager as Node).free()


func _test_startup_backup_recovery() -> void:
	var source: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(source.set_settings_path_for_verification(BACKUP_RECOVERY_SETTINGS_PATH), "备份恢复源必须使用隔离路径。")
	_assert_ok(source.load_settings(), "备份恢复源必须先写入确认设置。")
	_assert_ok(source.set_master_volume(0.35), "备份恢复源必须写入可辨认旧值。")
	var expected_snapshot: Dictionary = source.get_settings_snapshot()
	var backup_path: String = "%s.bak" % BACKUP_RECOVERY_SETTINGS_PATH
	var move_to_backup_result: Error = DirAccess.rename_absolute(BACKUP_RECOVERY_SETTINGS_PATH, backup_path)
	_assert_equal(move_to_backup_result, OK, "必须能模拟 settings.json 已移入 .bak 的崩溃窗口。")
	_assert_true(not FileAccess.file_exists(BACKUP_RECOVERY_SETTINGS_PATH) and FileAccess.file_exists(backup_path), "模拟崩溃后应只有 .bak 存在。")
	(source as Node).free()

	var recovered: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(recovered.set_settings_path_for_verification(BACKUP_RECOVERY_SETTINGS_PATH), "恢复实例必须使用相同隔离路径。")
	var recovery_result: Dictionary = recovered.load_settings()
	_assert_ok(recovery_result, "settings.json 缺失且 .bak 有效时必须恢复旧设置。")
	_assert_true(bool(recovery_result.get("recovered_backup", false)), "恢复结果必须明确标记 recovered_backup。")
	_assert_equal(recovered.get_settings_snapshot(), expected_snapshot, "崩溃恢复不得退回默认设置或丢失旧设置。")
	_assert_true(FileAccess.file_exists(BACKUP_RECOVERY_SETTINGS_PATH) and not FileAccess.file_exists(backup_path), "有效 .bak 恢复后必须重新成为 settings.json。")
	(recovered as Node).free()

	var invalid_backup_file: FileAccess = FileAccess.open(backup_path, FileAccess.WRITE)
	if invalid_backup_file == null:
		_assert_true(false, "无法创建损坏备份夹具。")
		return
	invalid_backup_file.store_string("{")
	invalid_backup_file.flush()
	invalid_backup_file.close()
	if FileAccess.file_exists(BACKUP_RECOVERY_SETTINGS_PATH):
		var remove_target_result: Error = DirAccess.remove_absolute(BACKUP_RECOVERY_SETTINGS_PATH)
		_assert_equal(remove_target_result, OK, "损坏备份场景必须移除目标 settings.json。")
	var rejected: Variant = SETTINGS_MANAGER_SCRIPT.new()
	_assert_ok(rejected.set_settings_path_for_verification(BACKUP_RECOVERY_SETTINGS_PATH), "损坏备份恢复实例必须使用隔离路径。")
	var rejection_result: Dictionary = rejected.load_settings()
	_assert_true(not bool(rejection_result.get("ok", false)), "损坏 .bak 必须明确拒绝，不得建立默认设置。")
	_assert_equal(String(rejection_result.get("error_code", "")), "backup_invalid", "损坏 .bak 必须返回 backup_invalid。")
	_assert_true(not FileAccess.file_exists(BACKUP_RECOVERY_SETTINGS_PATH), "损坏 .bak 被拒绝后不得写入默认 settings.json。")
	_assert_true(FileAccess.file_exists(backup_path), "损坏 .bak 被拒绝后必须保留现场文件。")
	(rejected as Node).free()


func _write_invalid_case(test_case: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(INSTANCE_SETTINGS_PATH, FileAccess.WRITE)
	if file == null:
		_assert_true(false, "无法创建隔离测试设置文件。")
		return
	if test_case.has("text"):
		file.store_string(String(test_case["text"]))
	else:
		file.store_string(JSON.stringify(test_case["document"] as Dictionary))
	file.flush()
	file.close()


func _read_document_for_test(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		_assert_true(false, "无法读取隔离测试设置文件。")
		return {}
	var source_text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(source_text)
	if not parsed is Dictionary:
		_assert_true(false, "隔离测试设置文件必须可解析为对象。")
		return {}
	return (parsed as Dictionary).duplicate(true)


func _settings_with(setting_id: String, value: Variant) -> Dictionary:
	var settings: Dictionary = _default_settings()
	settings[setting_id] = value
	return settings


func _default_settings() -> Dictionary:
	return {
		"master_volume": 1.0,
		"ambience_volume": 1.0,
		"ui_phone_volume": 1.0,
		"window_mode": "windowed",
		"text_speed": 1.0,
		"font_size": 100,
		"reduce_flashing": false,
		"crt_enabled": true,
	}


func _cleanup_test_directory() -> void:
	for suffix: String in [
		"settings_smoke_autoload.json",
		"settings_smoke_autoload.json.tmp",
		"settings_smoke_autoload.json.bak",
		"instance_settings.json",
		"instance_settings.json.tmp",
		"instance_settings.json.bak",
		"backup_recovery_settings.json",
		"backup_recovery_settings.json.tmp",
		"backup_recovery_settings.json.bak",
	]:
		var path: String = "%s/%s" % [TEST_DIRECTORY, suffix]
		if FileAccess.file_exists(path):
			var remove_result: Error = DirAccess.remove_absolute(path)
			_assert_true(remove_result == OK, "无法清理隔离测试文件：%s。" % path)
	var directory_path: String = ProjectSettings.globalize_path(TEST_DIRECTORY)
	if DirAccess.dir_exists_absolute(directory_path):
		var remove_directory_result: Error = DirAccess.remove_absolute(directory_path)
		_assert_true(remove_directory_result == OK, "无法清理隔离测试目录。")


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][SettingsManager] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
