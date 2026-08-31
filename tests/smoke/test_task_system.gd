extends SceneTree

const TASK_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/task_system.gd")

var _has_failed: bool = false
var _restored_transition_count: int = 0


func _init() -> void:
	_test_requirement_groups_and_lifecycle()
	_test_failure_and_snapshot_contract()
	if _has_failed:
		print("[测试][TaskSystem] 失败。")
		quit(1)
		return
	print("[测试][TaskSystem] 通过：requirement tree、单向状态机、幂等 transition 与严格 snapshot 合同成立。")
	quit(0)


func _test_requirement_groups_and_lifecycle() -> void:
	var system: TaskSystem = TASK_SYSTEM_SCRIPT.new() as TaskSystem
	_assert_ok(system.configure([{
		"id": "task_alpha",
		"activation": {
			"mode": "all",
			"requirements": [
				{"type": "statement_revealed", "id": "statement_alpha"},
				{
					"mode": "any",
					"requirements": [
						{"type": "fact_confirmed", "id": "fact_alpha"},
						{"type": "message_read", "id": "message_alpha"},
					],
				},
			],
		},
		"completion": {"type": "broadcast_sent", "id": "task_alpha"},
	}]), "TaskSystem 必须接受 all/any requirement tree。")

	var world: Dictionary = _world_state()
	_assert_ok(system.refresh(world, 1), "未满足 activation 时 refresh 仍必须成功。")
	_assert_equal(String(system.get_task_state("task_alpha").get("status", "")), "pending", "未满足 activation 时 task 必须保持 pending。")
	world["statement_revealed_ids"] = ["statement_alpha"]
	world["message_read_ids"] = ["message_alpha"]
	var activate: Dictionary = system.refresh(world, 2)
	_assert_ok(activate, "满足 all + nested any 后必须激活 task。")
	_assert_equal((activate.get("transitions", []) as Array).size(), 1, "activation 只能提交一条 transition。")
	_assert_equal(String(system.get_task_state("task_alpha").get("status", "")), "active", "满足 activation 后 task 必须 active。")
	var duplicate_refresh: Dictionary = system.refresh(world, 3)
	_assert_ok(duplicate_refresh, "重复 refresh 必须幂等。")
	_assert_equal((duplicate_refresh.get("transitions", []) as Array).size(), 0, "重复 refresh 不得重放 activation transition。")
	world["broadcast_sent_ids"] = ["task_alpha"]
	var complete: Dictionary = system.refresh(world, 4)
	_assert_ok(complete, "满足 completion 后必须完成 task。")
	_assert_equal(String(system.get_task_state("task_alpha").get("status", "")), "completed", "task 必须单向进入 completed。")
	_assert_equal((system.get_transition_records() as Array).size(), 2, "正常生命周期必须只有 pending→active→completed 两条 transition。")
	_assert_ok(system.refresh(world, 5), "completed task 后续 refresh 仍必须安全。")
	_assert_equal((system.get_transition_records() as Array).size(), 2, "completed 终态不得重复提交 transition。")


func _test_failure_and_snapshot_contract() -> void:
	var system: TaskSystem = TASK_SYSTEM_SCRIPT.new() as TaskSystem
	_assert_ok(system.configure([{
		"id": "task_failure",
		"activation": {"type": "condition_true", "id": "condition_ready"},
		"completion": {"type": "interaction_outcome_committed", "id": "call_failure"},
	}]), "failure 测试必须配置 task。")
	var world: Dictionary = _world_state()
	world["condition_state_by_id"] = {"condition_ready": true}
	_assert_ok(system.refresh(world, 10), "满足 condition_true 后必须激活 task。")
	var failure: Dictionary = system.fail_task("task_failure", 11, "player_abandoned")
	_assert_ok(failure, "active task 必须可进入 failed。")
	_assert_true(not bool(failure.get("duplicate", true)), "首次 fail_task 不得标记 duplicate。")
	var duplicate_failure: Dictionary = system.fail_task("task_failure", 11, "player_abandoned")
	_assert_ok(duplicate_failure, "相同 failed commit 必须幂等。")
	_assert_true(bool(duplicate_failure.get("duplicate", false)), "重复 failed commit 必须标记 duplicate。")
	_assert_error_code(system.fail_task("task_failure", 12, "different_reason"), "task_failure_conflict", "failed 终态不得被不同 reason 重写。")

	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot, {"current_game_tick": 11, "world_state": world}), "合法 Task snapshot 必须通过 transition replay 与 world-state 校验。")
	var restored: TaskSystem = TASK_SYSTEM_SCRIPT.new() as TaskSystem
	_assert_ok(restored.configure([{
		"id": "task_failure",
		"activation": {"type": "condition_true", "id": "condition_ready"},
		"completion": {"type": "interaction_outcome_committed", "id": "call_failure"},
	}]), "恢复目标必须配置同一 task 定义。")
	_restored_transition_count = 0
	restored.task_transition_committed.connect(_on_restored_transition)
	_assert_ok(restored.restore_snapshot(snapshot, {"current_game_tick": 11, "world_state": world}), "Task snapshot 必须可无副作用恢复。")
	_assert_equal(_restored_transition_count, 0, "restore_snapshot 不得重放 task_transition_committed。")
	_assert_equal(String(restored.get_task_state("task_failure").get("status", "")), "failed", "恢复后必须保留 failed 终态。")

	var future_snapshot: Dictionary = snapshot.duplicate(true)
	((future_snapshot["transitions"] as Array)[1] as Dictionary)["created_at_tick"] = 12
	_assert_error_code(restored.validate_snapshot(future_snapshot, {"current_game_tick": 11, "world_state": world}), "task_snapshot_transition_future", "Task snapshot 不得包含未来 transition。")
	var mismatch_snapshot: Dictionary = snapshot.duplicate(true)
	(mismatch_snapshot["states"] as Dictionary)["task_failure"] = "active"
	_assert_error_code(restored.validate_snapshot(mismatch_snapshot, {"current_game_tick": 11, "world_state": world}), "task_snapshot_state_transition_mismatch", "Task state 必须与 transition replay 结果一致。")


func _world_state() -> Dictionary:
	return {
		"statement_revealed_ids": [],
		"fact_confirmed_ids": [],
		"condition_state_by_id": {},
		"interaction_answered_ids": [],
		"interaction_completed_ids": [],
		"broadcast_sent_ids": [],
		"message_read_ids": [],
		"dialogue_completed_ids": [],
		"information_available_task_ids": [],
		"interaction_outcome_event_ids": [],
	}


func _on_restored_transition(_record: Dictionary) -> void:
	_restored_transition_count += 1


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
	push_error("[测试][TaskSystem] %s" % message)
