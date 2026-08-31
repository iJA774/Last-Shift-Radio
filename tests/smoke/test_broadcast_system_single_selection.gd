extends SceneTree

## 广播任务选择模式与存档合同验证。
## StoryEngine 会先校验剧情资格；本脚本直接覆盖 BroadcastSystem，确保其它调用者
## 也不能绕开任务配置的单选/多选规则，且快照会按当前任务定义严格验证。

const BROADCAST_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/broadcast_system.gd")

var _has_failed: bool = false


func _init() -> void:
	_test_single_selection_contract()
	_test_multiple_selection_contract()
	if _has_failed:
		print("[测试][BroadcastSystemSelectionModes] 失败。")
		quit(1)
		return
	print("[测试][BroadcastSystemSelectionModes] 通过：单选、多选与对应存档合同成立。")
	quit(0)


func _test_single_selection_contract() -> void:
	var system: BroadcastSystem = BROADCAST_SYSTEM_SCRIPT.new()
	var task: Dictionary = {
		"id": "task_single_selection_probe",
		"name": "单选验证",
		"selection_mode": "single",
		"source": "Studio A",
		"sets_condition_id": "",
		"information_items": [
			{"id": "info_probe_one", "body": "第一条。"},
			{"id": "info_probe_two", "body": "第二条。"},
		],
	}
	_assert_ok(system.configure_tasks([task]), "单选验证任务必须可以配置。")
	_assert_error_code(
		system.send_task_publication("task_single_selection_probe", [], 0),
		"information_selection_count_invalid",
		"BroadcastSystem 必须拒绝空选择。"
	)
	_assert_error_code(
		system.send_task_publication("task_single_selection_probe", ["info_probe_one", "info_probe_two"], 0),
		"information_selection_count_invalid",
		"BroadcastSystem 必须拒绝多项选择。"
	)
	var sent_result: Dictionary = system.send_task_publication("task_single_selection_probe", ["info_probe_two"], 0)
	_assert_ok(sent_result, "BroadcastSystem 必须接受恰好一项的选择。")
	var record: Dictionary = sent_result.get("record", {}) as Dictionary
	_assert_equal(record.get("information_item_ids", []), ["info_probe_two"], "发送记录必须只保留单个信息项。")
	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	var records: Array = snapshot["player_records"] as Array
	if not records.is_empty():
		(records[0] as Dictionary)["information_item_ids"] = ["info_probe_one", "info_probe_two"]
		(records[0] as Dictionary)["body"] = "第一条。\n\n第二条。"
	_assert_error_code(
		system.validate_snapshot(snapshot),
		"information_selection_count_invalid",
		"存档中的多项历史选择必须被严格拒绝。"
	)


func _test_multiple_selection_contract() -> void:
	var system: BroadcastSystem = BROADCAST_SYSTEM_SCRIPT.new()
	var task: Dictionary = {
		"id": "task_multiple_selection_probe",
		"name": "多选验证",
		"selection_mode": "multiple",
		"source": "Studio A",
		"sets_condition_id": "",
		"information_items": [
			{"id": "info_multiple_one", "body": "第一条。"},
			{"id": "info_multiple_two", "body": "第二条。"},
		],
	}
	_assert_ok(system.configure_tasks([task]), "多选验证任务必须可以配置。")
	_assert_error_code(
		system.send_task_publication("task_multiple_selection_probe", [], 0),
		"information_selection_count_invalid",
		"多选任务必须拒绝空选择。"
	)
	var sent_result: Dictionary = system.send_task_publication("task_multiple_selection_probe", ["info_multiple_two", "info_multiple_one"], 0)
	_assert_ok(sent_result, "多选任务必须接受两项已收集信息。")
	var record: Dictionary = sent_result.get("record", {}) as Dictionary
	_assert_equal(record.get("information_item_ids", []), ["info_multiple_one", "info_multiple_two"], "多选记录必须按任务定义顺序规范化信息项。")
	_assert_equal(String(record.get("body", "")), "第一条。\n\n第二条。", "多选记录正文必须组合全部实际选择的信息。")
	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot), "多选历史记录必须可通过严格快照校验。")


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s。" % [message, str(result)])


func _assert_error_code(result: Dictionary, expected_code: String, message: String) -> void:
	_assert_true(not bool(result.get("ok", true)), "%s 不应成功。" % message)
	_assert_equal(String(result.get("error_code", "")), expected_code, message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][BroadcastSystemSingleSelection] %s" % message)
