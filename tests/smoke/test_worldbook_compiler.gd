extends SceneTree

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const WORLD_BOOK_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/worldbook_validator.gd")
const WORLD_BOOK_COMPILER_SCRIPT: GDScript = preload("res://scripts/core/worldbook_compiler.gd")
const DEFAULT_MANIFEST_PATH: String = "res://worldbooks/default/manifest.json"
const LEGACY_STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	var worldbook_validator: WorldBookValidator = WORLD_BOOK_VALIDATOR_SCRIPT.new() as WorldBookValidator
	var validation: Dictionary = worldbook_validator.load_and_validate(DEFAULT_MANIFEST_PATH)
	_assert_ok(validation, "官方 default WorldBook 必须先通过 Validator。")
	if not bool(validation.get("ok", false)):
		_finish()
		return
	var compiler: WorldBookCompiler = WORLD_BOOK_COMPILER_SCRIPT.new() as WorldBookCompiler
	var compile_result: Dictionary = compiler.compile(validation)
	_assert_ok(compile_result, "官方 default WorldBook 必须成功编译。")
	if not bool(compile_result.get("ok", false)):
		_finish()
		return
	var compiled: Dictionary = compile_result["compiled"] as Dictionary
	var runtime_story: Dictionary = compiled["runtime_story"] as Dictionary
	_test_worldbook_identity_contract(compiled)
	_test_existing_v2_contract(runtime_story)
	_test_exact_runtime_equivalence(runtime_story)
	_test_actor_registration_contract(compiled)
	_test_semantic_requirements_preserved(runtime_story)
	_test_no_executable_fields(compiled)
	_finish()


func _test_worldbook_identity_contract(compiled: Dictionary) -> void:
	_assert_equal(String(compiled.get("worldbook_id", "")), "last_shift_radio_default", "Compiler 必须显式携带稳定 worldbook_id。")
	_assert_true(typeof(compiled.get("worldbook_version")) == TYPE_INT, "Compiler 必须显式携带 int worldbook_version。")
	_assert_equal(int(compiled.get("worldbook_version", 0)), 1, "Compiler 必须保持 default WorldBook authored version。")


func _test_existing_v2_contract(runtime_story: Dictionary) -> void:
	var validator = CONTENT_VALIDATOR_SCRIPT.new()
	var result: Dictionary = validator.validate_test_night_story(runtime_story, "compiled://last_shift_radio_default")
	_assert_ok(result, "Compiled runtime_story 必须继续通过现有 Agent Dialogue v2 严格合同。")


func _test_exact_runtime_equivalence(runtime_story: Dictionary) -> void:
	var loader = CONTENT_LOADER_SCRIPT.new()
	var load_result: Dictionary = loader.load_json(LEGACY_STORY_PATH)
	_assert_ok(load_result, "必须能读取当前正式 test_night_story.json 作为迁移等价基线。")
	if not bool(load_result.get("ok", false)):
		return
	var validator = CONTENT_VALIDATOR_SCRIPT.new()
	var runtime_validation: Dictionary = validator.validate_test_night_story(runtime_story, "compiled://last_shift_radio_default")
	var baseline_validation: Dictionary = validator.validate_test_night_story(load_result["data"], LEGACY_STORY_PATH)
	_assert_ok(runtime_validation, "Compiler 产物必须能规范化为 v2 等价比较基线。")
	_assert_ok(baseline_validation, "当前正式 test_night_story.json 必须能规范化为 v2 等价比较基线。")
	if not bool(runtime_validation.get("ok", false)) or not bool(baseline_validation.get("ok", false)):
		return
	var normalized_runtime: Dictionary = _extract_runtime_story(runtime_validation)
	var normalized_baseline: Dictionary = _extract_runtime_story(baseline_validation)
	var first_difference: Dictionary = _find_first_difference(normalized_runtime, normalized_baseline, "runtime_story")
	_assert_true(
		first_difference.is_empty(),
		"官方 default WorldBook 编译结果必须与当前正式 v2 gameplay 数据逐字段等价；首个差异=%s。" % str(first_difference)
	)


func _extract_runtime_story(validation: Dictionary) -> Dictionary:
	return {
		"content_format_version": validation["content_format_version"],
		"content_kind": validation["content_kind"],
		"conditions": validation["conditions"],
		"events": validation["events"],
		"checklist_entries": validation["checklist_entries"],
		"news_entries": validation["news_entries"],
		"messages": validation["messages"],
		"broadcast_tasks": validation["broadcast_tasks"],
		"actors": validation["actors"],
		"statements": validation["statements"],
		"facts": validation["facts"],
	}


func _find_first_difference(actual: Variant, expected: Variant, path: String) -> Dictionary:
	if typeof(actual) != typeof(expected):
		return {
			"path": path,
			"reason": "type_mismatch",
			"actual_type": type_string(typeof(actual)),
			"expected_type": type_string(typeof(expected)),
			"actual": actual,
			"expected": expected,
		}
	if actual is Dictionary:
		var actual_dictionary: Dictionary = actual as Dictionary
		var expected_dictionary: Dictionary = expected as Dictionary
		var actual_keys: Array = actual_dictionary.keys()
		var expected_keys: Array = expected_dictionary.keys()
		actual_keys.sort()
		expected_keys.sort()
		if actual_keys != expected_keys:
			return {"path": path, "reason": "key_set_mismatch", "actual_keys": actual_keys, "expected_keys": expected_keys}
		for raw_key: Variant in actual_keys:
			var dictionary_child: Dictionary = _find_first_difference(actual_dictionary[raw_key], expected_dictionary[raw_key], "%s.%s" % [path, String(raw_key)])
			if not dictionary_child.is_empty():
				return dictionary_child
		return {}
	if actual is Array:
		var actual_array: Array = actual as Array
		var expected_array: Array = expected as Array
		if actual_array.size() != expected_array.size():
			return {"path": path, "reason": "array_size_mismatch", "actual": actual_array.size(), "expected": expected_array.size()}
		for index: int in range(actual_array.size()):
			var array_child: Dictionary = _find_first_difference(actual_array[index], expected_array[index], "%s[%d]" % [path, index])
			if not array_child.is_empty():
				return array_child
		return {}
	if actual != expected:
		return {"path": path, "reason": "value_mismatch", "actual": actual, "expected": expected}
	return {}


func _test_actor_registration_contract(compiled: Dictionary) -> void:
	var actors: Array = compiled["actors"] as Array
	_assert_equal(actors.size(), 10, "default WorldBook 必须声明 10 个 Actor。")
	var event_by_id: Dictionary = {}
	for raw_event: Variant in compiled["events"] as Array:
		var event: Dictionary = raw_event as Dictionary
		event_by_id[String(event["id"])] = event
	_assert_true(event_by_id.has("call_07_ronnie_1") and event_by_id.has("call_10_ronnie_2"), "Ronnie 两通正式电话必须仍存在。")
	if event_by_id.has("call_07_ronnie_1") and event_by_id.has("call_10_ronnie_2"):
		_assert_equal(String((event_by_id["call_07_ronnie_1"] as Dictionary)["actor_id"]), "ronnie", "Ronnie 第一通必须绑定 actor_id=ronnie。")
		_assert_equal(String((event_by_id["call_10_ronnie_2"] as Dictionary)["actor_id"]), "ronnie", "Ronnie 第二通必须复用 actor_id=ronnie。")

	var actor_ids: Dictionary = {}
	for raw_actor: Variant in actors:
		actor_ids[String((raw_actor as Dictionary)["id"])] = true
	_assert_equal(actor_ids.size(), 10, "Compiler 不得让 Director 或事件隐式创建额外 Actor。")


func _test_semantic_requirements_preserved(runtime_story: Dictionary) -> void:
	var task_by_id: Dictionary = {}
	for raw_task: Variant in runtime_story["broadcast_tasks"] as Array:
		var task: Dictionary = raw_task as Dictionary
		task_by_id[String(task["id"])] = task
	_assert_true(task_by_id.has("task_broadcast_bridge_closure"), "北桥广播 Task 必须保留。")
	if task_by_id.has("task_broadcast_bridge_closure"):
		var task: Dictionary = task_by_id["task_broadcast_bridge_closure"] as Dictionary
		_assert_true(not task.has("required_dialogue_event_ids"), "v2 Compiler 不得重新引入 required_dialogue_event_ids。")
		var requirements: Array = task["requirements"] as Array
		_assert_equal(requirements.size(), 2, "北桥广播 Task 的 semantic requirements 数量必须保持。")
		if requirements.size() == 2:
			_assert_equal(String((requirements[0] as Dictionary)["type"]), "interaction_answered", "Task requirement 必须继续使用语义类型。")


func _test_no_executable_fields(compiled: Dictionary) -> void:
	var forbidden_path: String = _find_forbidden_executable_field(compiled, "compiled")
	_assert_equal(forbidden_path, "", "CompiledWorldDefinition 不得包含 script/scene/code/plugin 等可执行入口。")


func _find_forbidden_executable_field(value: Variant, path: String) -> String:
	if value is Dictionary:
		for raw_key: Variant in (value as Dictionary).keys():
			var key: String = String(raw_key)
			if ["script", "script_path", "scene", "scene_path", "code", "plugin", "executable"].has(key):
				return "%s.%s" % [path, key]
			var dictionary_child: String = _find_forbidden_executable_field((value as Dictionary)[raw_key], "%s.%s" % [path, key])
			if not dictionary_child.is_empty():
				return dictionary_child
	elif value is Array:
		for index: int in range((value as Array).size()):
			var array_child: String = _find_forbidden_executable_field((value as Array)[index], "%s[%d]" % [path, index])
			if not array_child.is_empty():
				return array_child
	return ""


func _finish() -> void:
	if _has_failed:
		print("[测试][WorldBookCompiler] 失败。")
		quit(1)
		return
	print("[测试][WorldBookCompiler] 通过：default WorldBook 与正式 v2 runtime 等价。")
	quit(0)


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][WorldBookCompiler] %s" % message)
