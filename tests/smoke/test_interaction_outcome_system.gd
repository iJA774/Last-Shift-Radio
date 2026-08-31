extends SceneTree

const OUTCOME_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/interaction_outcome_system.gd")

var _has_failed: bool = false
var _restore_commit_count: int = 0


func _init() -> void:
	_test_commit_idempotency_and_metrics()
	_test_snapshot_history_validation()
	if _has_failed:
		print("[测试][InteractionOutcomeSystem] 失败。")
		quit(1)
		return
	print("[测试][InteractionOutcomeSystem] 通过：确定性 disposition、metric delta、幂等与严格 snapshot 合同成立。")
	quit(0)


func _test_commit_idempotency_and_metrics() -> void:
	var system: InteractionOutcomeSystem = OUTCOME_SYSTEM_SCRIPT.new() as InteractionOutcomeSystem
	_assert_ok(system.configure(_actors()), "InteractionOutcomeSystem 必须从 authored Actor 初始 trust/stress 配置 authority。")
	var input: Dictionary = _input("call_alpha", "session_alpha", "ronnie", "interaction_completed", "answer", 20)
	var result: Dictionary = system.commit_interaction_outcome(input, {"trust": 0.2, "stress": -0.1, "suspicion": 0.3})
	_assert_ok(result, "合法 completed interaction 必须提交 OutcomeRecord。")
	_assert_true(not bool(result.get("duplicate", true)), "首次 Outcome commit 不得标记 duplicate。")
	if bool(result.get("ok", false)):
		var record: Dictionary = result["record"] as Dictionary
		_assert_equal(String(record["outcome_id"]), "interaction_outcome_call_alpha", "outcome_id 必须从 event_id 确定性派生。")
		_assert_equal(String(record["disposition"]), "cooperated", "answer speech_act 必须确定性映射为 cooperated。")
		_assert_true(is_equal_approx(float((record["metric_after"] as Dictionary)["trust"]), 0.7), "trust delta 必须由 authority 确定性提交。")
		_assert_true(is_equal_approx(float((record["metric_after"] as Dictionary)["stress"]), 0.3), "stress delta 必须由 authority 确定性提交。")
		_assert_true(is_equal_approx(float((record["metric_after"] as Dictionary)["suspicion"]), 0.3), "suspicion delta 必须由 authority 确定性提交。")
	var duplicate: Dictionary = system.commit_interaction_outcome(input, {"trust": 0.2, "stress": -0.1, "suspicion": 0.3})
	_assert_ok(duplicate, "完全相同的 Outcome 重复提交必须幂等返回既有结果。")
	_assert_true(bool(duplicate.get("duplicate", false)), "重复 Outcome 必须标记 duplicate。")
	_assert_error_code(system.commit_interaction_outcome(input, {"trust": 0.9}), "interaction_outcome_conflict", "同一 event_id 不得以不同 authoritative effects 伪装成幂等重试。")
	var conflict_input: Dictionary = input.duplicate(true)
	conflict_input["created_at_tick"] = 21
	_assert_error_code(system.commit_interaction_outcome(conflict_input), "interaction_outcome_conflict", "同一 event_id 不得映射到不同 terminal input。")
	_assert_error_code(system.commit_interaction_outcome(_input("call_bad_actor", "session_bad", "missing", "interaction_completed", "answer", 22)), "interaction_outcome_actor_unknown", "Outcome 不得引用未知 Actor。")
	_assert_error_code(system.commit_interaction_outcome(_input("call_bad_reason", "session_bad_reason", "ronnie", "unsupported", "answer", 22)), "interaction_outcome_reason_invalid", "Outcome terminal_reason 必须来自有限集合。")
	_assert_error_code(system.commit_interaction_outcome(_input("call_bad_delta", "session_bad_delta", "ronnie", "interaction_completed", "answer", 22), {"trust": 1.5}), "interaction_outcome_effect_invalid", "authority metric delta 必须限制在 -1..1。")


func _test_snapshot_history_validation() -> void:
	var system: InteractionOutcomeSystem = OUTCOME_SYSTEM_SCRIPT.new() as InteractionOutcomeSystem
	_assert_ok(system.configure(_actors()), "snapshot 测试必须配置同一 Actor authority。")
	_assert_ok(system.commit_interaction_outcome(_input("call_first", "session_first", "martha", "interaction_completed", "refuse", 30), {"trust": -0.2, "stress": 0.2}), "第一条 Outcome 必须提交。")
	_assert_ok(system.commit_interaction_outcome(_input("call_second", "session_second", "martha", "phone_ended", "uncertain", 31), {"suspicion": 0.4}), "第二条 Outcome 必须基于前一条 metric_after 提交。")
	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot, {"current_game_tick": 31}), "合法 Outcome snapshot 必须从 authored 初值完整 replay。")

	var restored: InteractionOutcomeSystem = OUTCOME_SYSTEM_SCRIPT.new() as InteractionOutcomeSystem
	_assert_ok(restored.configure(_actors()), "恢复目标必须配置相同 Actor 集合。")
	_restore_commit_count = 0
	restored.interaction_outcome_committed.connect(_on_restore_commit)
	_assert_ok(restored.restore_snapshot(snapshot, {"current_game_tick": 31}), "Outcome snapshot 必须可无副作用恢复。")
	_assert_equal(_restore_commit_count, 0, "restore_snapshot 不得重放 interaction_outcome_committed。")
	_assert_equal(restored.get_outcome_event_ids(), ["call_first", "call_second"], "恢复后 Outcome event IDs 必须保持。")

	var future_snapshot: Dictionary = snapshot.duplicate(true)
	((future_snapshot["outcomes"] as Array)[1] as Dictionary)["created_at_tick"] = 32
	_assert_error_code(restored.validate_snapshot(future_snapshot, {"current_game_tick": 31}), "interaction_outcome_snapshot_future", "Outcome snapshot 不得包含未来记录。")
	var history_snapshot: Dictionary = snapshot.duplicate(true)
	var second_record: Dictionary = (history_snapshot["outcomes"] as Array)[1] as Dictionary
	(second_record["metric_before"] as Dictionary)["trust"] = 0.99
	_assert_error_code(restored.validate_snapshot(history_snapshot, {"current_game_tick": 31}), "interaction_outcome_snapshot_before_mismatch", "metric_before 必须与前序 Outcome history 精确衔接。")
	var summary_snapshot: Dictionary = snapshot.duplicate(true)
	((summary_snapshot["actor_metrics"] as Dictionary)["martha"] as Dictionary)["stress"] = 0.0
	_assert_error_code(restored.validate_snapshot(summary_snapshot, {"current_game_tick": 31}), "interaction_outcome_snapshot_metric_history_mismatch", "actor_metrics 汇总必须与 Outcome history 一致。")


func _actors() -> Array:
	return [
		{"id": "ronnie", "initial_state": {"trust": 0.5, "stress": 0.4}},
		{"id": "martha", "initial_state": {"trust": 0.6, "stress": 0.3}},
	]


func _input(event_id: String, session_id: String, actor_id: String, reason: String, speech_act: String, tick: int) -> Dictionary:
	return {
		"event_id": event_id,
		"session_id": session_id,
		"actor_id": actor_id,
		"terminal_reason": reason,
		"last_speech_act": speech_act,
		"asserted_claim_ids": [],
		"created_at_tick": tick,
	}


func _on_restore_commit(_record: Dictionary) -> void:
	_restore_commit_count += 1


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
	push_error("[测试][InteractionOutcomeSystem] %s" % message)
