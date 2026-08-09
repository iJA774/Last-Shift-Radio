extends SceneTree

## 内容入口的无 UI 冒烟测试。每项失败都会以退出码 1 结束，避免 Main 在
## 损坏内容下假装成功启动。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")

const FIXTURE_ROOT: String = "res://tests/fixtures/content/"
const FOUNDATION_PATH: String = "res://data/story/foundation_events.json"

var _loader: ContentLoader = CONTENT_LOADER_SCRIPT.new()
var _validator: ContentValidator = CONTENT_VALIDATOR_SCRIPT.new()
var _has_failed: bool = false


func _init() -> void:
	_test_valid_fixture()
	_test_foundation_events()
	_test_file_not_found()
	_test_json_syntax_error()
	_test_invalid_top_level_type()
	_test_validation_errors()
	_test_json_number_behavior()

	if _has_failed:
		print("[测试][ContentPipeline] 失败。")
		quit(1)
		return
	print("[测试][ContentPipeline] 通过：读取、JSON 解析与 incoming_call_events v1 严格校验成立。")
	quit(0)


func _test_valid_fixture() -> void:
	var result: Dictionary = _load_and_validate("valid_events.json")
	_assert_ok(result, "有效 JSON 必须读取并通过校验。")
	if not bool(result.get("ok", false)):
		return
	var events: Array[Dictionary] = result["events"] as Array[Dictionary]
	_assert_equal(events.size(), 2, "有效夹具必须返回完整的两条事件。")
	if events.is_empty():
		return
	_assert_equal(typeof(events[0]["window_start_minute"]), TYPE_INT, "校验成功后的分钟必须规范为 int。")
	_assert_equal(String(events[1]["id"]), "call_fixture_main", "校验结果必须保留稳定事件 ID。")
	var original_data: Dictionary = _load_data("valid_events.json")
	if not original_data.is_empty():
		var original_events: Array = original_data["events"] as Array
		var original_event: Dictionary = original_events[0] as Dictionary
		original_event["caller_display_name"] = "外部修改"
		_assert_equal(
			String(events[0]["caller_display_name"]),
			"夹具测试线路 A",
			"校验成功结果必须是独立深拷贝，不能受原始数据后续修改影响。"
		)


func _test_foundation_events() -> void:
	var load_result: Dictionary = _loader.load_json(FOUNDATION_PATH)
	_assert_ok(load_result, "foundation_events.json 必须可读取。")
	if not bool(load_result.get("ok", false)):
		return
	var validation: Dictionary = _validator.validate_incoming_call_events(load_result["data"], FOUNDATION_PATH)
	_assert_ok(validation, "foundation_events.json 必须通过内容校验。")
	if not bool(validation.get("ok", false)):
		return
	var events: Array[Dictionary] = validation["events"] as Array[Dictionary]
	_assert_equal(events.size(), 2, "foundation_events.json 只能保留两条系统测试线路。")
	_assert_equal(String(events[0]["id"]), "call_system_smoke_normal", "第一条系统测试线路 ID 不正确。")
	_assert_equal(String(events[1]["id"]), "call_system_smoke_main", "第二条系统测试线路 ID 不正确。")


func _test_json_syntax_error() -> void:
	var result: Dictionary = _loader.load_json(FIXTURE_ROOT + "malformed_syntax.json")
	_assert_error(result, "json_syntax_error", "", "$", "语法损坏 JSON 必须在读取层明确拒绝。")


func _test_file_not_found() -> void:
	var missing_path: String = FIXTURE_ROOT + "does_not_exist.json"
	var result: Dictionary = _loader.load_json(missing_path)
	_assert_error(result, "file_not_found", "", "$", "不存在的内容文件必须由读取层明确拒绝。")
	_assert_equal(String(result.get("source_path", "")), missing_path, "缺失文件错误必须保留原始 source_path。")


func _test_invalid_top_level_type() -> void:
	var result: Dictionary = _load_and_validate("top_level_array.json")
	_assert_error(result, "invalid_top_level_type", "", "$", "顶层数组必须由校验层明确拒绝。")


func _test_validation_errors() -> void:
	_assert_fixture_error("missing_field.json", "missing_field", "call_missing_number", "caller_number")
	_assert_fixture_error("wrong_type.json", "invalid_window_start", "call_wrong_type", "window_start_minute")
	_assert_fixture_error("duplicate_id.json", "duplicate_event_id", "call_duplicate", "id")
	_assert_fixture_error("unknown_policy.json", "invalid_when_busy", "call_unknown_policy", "when_busy")
	_assert_fixture_error("wrong_version.json", "invalid_content_format_version", "", "content_format_version")
	_assert_fixture_error("fractional_minute.json", "invalid_window_start", "call_fractional_minute", "window_start_minute")
	_assert_fixture_error("invalid_condition_id.json", "invalid_condition_id", "call_invalid_condition", "condition_ids")


## 这里直接调用 Godot JSON.parse，记录并断言实际数值 Variant 形状。无论运行时
## 用 int 还是 float 表示 JSON 的 `1`，校验器都必须输出 int；`1.5` 必须拒绝。
func _test_json_number_behavior() -> void:
	var parser: JSON = JSON.new()
	var parse_error: Error = parser.parse(
		"{\"content_format_version\":1,\"content_kind\":\"incoming_call_events\",\"events\":[{\"id\":\"call_json_number_probe\",\"kind\":\"incoming_call\",\"priority\":\"normal\",\"window_start_minute\":1,\"window_end_minute\":2,\"when_busy\":\"expire\",\"on_expire\":\"mark_missed\",\"condition_ids\":[],\"caller_display_name\":\"数字解析测试线路\",\"caller_number\":\"000-0209\"}]}"
	)
	_assert_equal(parse_error, OK, "Godot JSON.parse 必须能解析整数探针。")
	if parse_error != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return
	var parsed_document: Dictionary = parser.data as Dictionary
	var parsed_events: Array = parsed_document["events"] as Array
	var parsed_event: Dictionary = parsed_events[0] as Dictionary
	print(
		"[测试][ContentPipeline] Godot JSON 数值类型：version=%s，window_start_minute=%s。" % [
			type_string(typeof(parsed_document["content_format_version"])),
			type_string(typeof(parsed_event["window_start_minute"])),
		]
	)
	var integer_result: Dictionary = _validator.validate_incoming_call_events(parsed_document, "memory://integer_probe")
	_assert_ok(integer_result, "JSON 整数字面量 1 必须通过校验。")
	if bool(integer_result.get("ok", false)):
		var integer_events: Array[Dictionary] = integer_result["events"] as Array[Dictionary]
		_assert_equal(typeof(integer_events[0]["window_start_minute"]), TYPE_INT, "JSON 整数字面量必须规范输出为 int。")

	var fractional_parser: JSON = JSON.new()
	var fractional_parse_error: Error = fractional_parser.parse(
		"{\"content_format_version\":1,\"content_kind\":\"incoming_call_events\",\"events\":[{\"id\":\"call_json_fraction_probe\",\"kind\":\"incoming_call\",\"priority\":\"normal\",\"window_start_minute\":1.5,\"window_end_minute\":2,\"when_busy\":\"expire\",\"on_expire\":\"mark_missed\",\"condition_ids\":[],\"caller_display_name\":\"数字解析测试线路\",\"caller_number\":\"000-0210\"}]}"
	)
	_assert_equal(fractional_parse_error, OK, "Godot JSON.parse 必须能解析小数字面量 1.5。")
	if fractional_parse_error == OK:
		var fractional_result: Dictionary = _validator.validate_incoming_call_events(fractional_parser.data, "memory://fraction_probe")
		_assert_error(
			fractional_result,
			"invalid_window_start",
			"call_json_fraction_probe",
			"window_start_minute",
			"JSON 小数字面量 1.5 必须被拒绝，不能截断。"
		)


func _load_and_validate(fixture_name: String) -> Dictionary:
	var load_result: Dictionary = _loader.load_json(FIXTURE_ROOT + fixture_name)
	if not bool(load_result.get("ok", false)):
		return load_result
	return _validator.validate_incoming_call_events(load_result["data"], FIXTURE_ROOT + fixture_name)


func _load_data(fixture_name: String) -> Dictionary:
	var load_result: Dictionary = _loader.load_json(FIXTURE_ROOT + fixture_name)
	if not bool(load_result.get("ok", false)) or typeof(load_result.get("data")) != TYPE_DICTIONARY:
		return {}
	return load_result["data"] as Dictionary


func _assert_fixture_error(fixture_name: String, error_code: String, event_id: String, field_name: String) -> void:
	var result: Dictionary = _load_and_validate(fixture_name)
	_assert_error(result, error_code, event_id, field_name, "%s 必须被完整拒绝。" % fixture_name)


func _assert_ok(result: Dictionary, message: String) -> void:
	if bool(result.get("ok", false)):
		return
	_has_failed = true
	push_error("[测试][ContentPipeline] %s 结果=%s。" % [message, str(result)])


func _assert_error(
	result: Dictionary,
	expected_code: String,
	expected_event_id: String,
	expected_field: String,
	message: String
) -> void:
	_assert_true(not bool(result.get("ok", false)), message)
	_assert_equal(String(result.get("error_code", "")), expected_code, "%s error_code 错误。" % message)
	_assert_equal(String(result.get("event_id", "")), expected_event_id, "%s event_id 错误。" % message)
	_assert_equal(String(result.get("field", "")), expected_field, "%s field 错误。" % message)
	_assert_true(not String(result.get("source_path", "")).is_empty(), "%s 必须携带 source_path。" % message)
	_assert_true(not String(result.get("message", "")).is_empty(), "%s 必须携带中文 message。" % message)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][ContentPipeline] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
