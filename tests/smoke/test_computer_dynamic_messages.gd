extends SceneTree

const COMPUTER_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/computer_system.gd")

var _has_failed: bool = false
var _unlock_count: int = 0
var _restore_unlock_count: int = 0


func _init() -> void:
	_test_dynamic_message_commit_snapshot_and_restore()
	if _has_failed:
		print("[测试][ComputerDynamicMessages] 失败。")
		quit(1)
		return
	print("[测试][ComputerDynamicMessages] 通过：动态消息 authority、幂等与 restore-no-replay 合同成立。")
	quit(0)


func _test_dynamic_message_commit_snapshot_and_restore() -> void:
	var computer: ComputerSystem = COMPUTER_SYSTEM_SCRIPT.new() as ComputerSystem
	_assert_ok(computer.configure_content([], [], []), "ComputerSystem 必须允许空 authored messages 基线。")
	_assert_ok(computer.configure_dynamic_message_sources(_actors()), "动态消息来源必须由正式 Actor authoring 配置。")
	_assert_ok(computer.advance_to_minute(2), "ComputerSystem 必须推进至动态消息提交分钟。")
	computer.source_unlocked.connect(_on_source_unlocked)

	var message: Dictionary = {
		"id": "delivery_message_martha_1",
		"source_actor_id": "martha",
		"sender": "Martha",
		"body": "The broadcast reached me.",
	}
	var first: Dictionary = computer.commit_dynamic_message(message, 120)
	_assert_ok(first, "正式 Delivery 动态消息必须能提交到 ComputerSystem。")
	_assert_true(not bool(first.get("duplicate", true)), "首次动态消息提交不得标记 duplicate。")
	_assert_equal(_unlock_count, 1, "首次动态消息必须走正常 source_unlocked 信号。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_MESSAGES).size(), 1, "动态消息必须通过正常 messages 查询可见。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_MESSAGES), 1, "新动态消息必须计入未读。")
	var visible: Dictionary = computer.get_entries(ComputerSystem.CATEGORY_MESSAGES)[0] as Dictionary
	_assert_equal(String(visible.get("source_id", "")), "delivery_message_martha_1", "动态消息 source_id 必须保留 Delivery stable ID。")
	_assert_equal(String(visible.get("sender", "")), "Martha", "动态消息 sender 必须来自 Actor authoring。")
	_assert_equal(String(visible.get("body", "")), "The broadcast reached me.", "动态消息正文必须保留已批准 Delivery 文本。")

	var duplicate: Dictionary = computer.commit_dynamic_message(message, 120)
	_assert_ok(duplicate, "完全相同的动态消息重复提交必须幂等。")
	_assert_true(bool(duplicate.get("duplicate", false)), "重复动态消息必须标记 duplicate。")
	_assert_equal(_unlock_count, 1, "幂等重复不得重发 source_unlocked。")

	var forged_sender: Dictionary = message.duplicate(true)
	forged_sender["id"] = "delivery_message_martha_2"
	forged_sender["sender"] = "Fake Martha"
	_assert_error_code(computer.commit_dynamic_message(forged_sender, 120), "dynamic_message_sender_mismatch", "模型/调用方不得伪造动态消息 sender。")
	var foreign_actor: Dictionary = message.duplicate(true)
	foreign_actor["id"] = "delivery_message_missing_2"
	foreign_actor["source_actor_id"] = "missing"
	_assert_error_code(computer.commit_dynamic_message(foreign_actor, 120), "dynamic_message_actor_unknown", "动态消息不得引用不存在的 Actor。")

	_assert_ok(computer.mark_entry_read(ComputerSystem.CATEGORY_MESSAGES, "delivery_message_martha_1"), "动态消息必须沿用正常已读接口。")
	var snapshot: Dictionary = computer.create_snapshot().duplicate(true)
	_assert_equal(int(snapshot.get("snapshot_version", 0)), 2, "动态消息进入正式存档后 ComputerSystem snapshot 必须提升为 v2。")
	_assert_equal((snapshot.get("dynamic_messages", []) as Array).size(), 1, "Computer snapshot 必须保存动态消息 committed state。")
	_assert_ok(computer.validate_snapshot(snapshot, {"current_game_tick": 120, "call_record_event_ids": []}), "Computer 动态消息 snapshot 必须通过严格校验。")

	var tampered: Dictionary = snapshot.duplicate(true)
	((tampered["dynamic_messages"] as Array)[0] as Dictionary)["sender"] = "Forged"
	_assert_error_code(
		computer.validate_snapshot(tampered, {"current_game_tick": 120, "call_record_event_ids": []}),
		"snapshot_dynamic_message_sender_mismatch",
		"存档不得篡改动态消息 Actor sender。"
	)

	var restored: ComputerSystem = COMPUTER_SYSTEM_SCRIPT.new() as ComputerSystem
	_assert_ok(restored.configure_content([], [], []), "恢复目标必须配置同一 authored Computer content。")
	_assert_ok(restored.configure_dynamic_message_sources(_actors()), "恢复目标必须配置同一 Actor 来源。")
	_restore_unlock_count = 0
	restored.source_unlocked.connect(_on_restored_source_unlocked)
	_assert_ok(restored.restore_snapshot(snapshot, {"current_game_tick": 120, "call_record_event_ids": []}), "动态消息 committed/read state 必须可恢复。")
	_assert_equal(_restore_unlock_count, 0, "restore 不得重放动态消息 arrival/source_unlocked。")
	_assert_equal(restored.get_entries(ComputerSystem.CATEGORY_MESSAGES).size(), 1, "恢复后动态消息必须继续通过正常 UI 查询可见。")
	_assert_equal(restored.get_unread_count(ComputerSystem.CATEGORY_MESSAGES), 0, "动态消息已读状态必须随 snapshot 恢复。")


func _actors() -> Array:
	return [{"id": "martha", "display_name": "Martha"}]


func _on_source_unlocked(category: String, _entry: Dictionary) -> void:
	if category == ComputerSystem.CATEGORY_MESSAGES:
		_unlock_count += 1


func _on_restored_source_unlocked(category: String, _entry: Dictionary) -> void:
	if category == ComputerSystem.CATEGORY_MESSAGES:
		_restore_unlock_count += 1


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_error_code(result: Dictionary, expected_code: String, message: String) -> void:
	_assert_true(not bool(result.get("ok", true)), "%s 不应成功。 result=%s" % [message, str(result)])
	_assert_equal(String(result.get("error_code", "")), expected_code, message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][ComputerDynamicMessages] %s" % message)
