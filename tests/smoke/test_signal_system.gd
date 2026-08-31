extends SceneTree

const SIGNAL_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/signal_system.gd")
const ACTOR_AGENT_SCRIPT: GDScript = preload("res://scripts/agents/actor_agent.gd")

var _has_failed: bool = false
var _committed_count: int = 0
var _perception_events: Array[String] = []
var _restore_committed_count: int = 0
var _restore_perception_count: int = 0


func _init() -> void:
	_test_broadcast_signal_commit_and_dedupe()
	_test_delivery_feedback_signal()
	_test_actor_perception_commit()
	if _has_failed:
		print("[测试][SignalSystem] 失败。")
		quit(1)
		return
	print("[测试][SignalSystem] 通过：广播/Delivery→Signal→Actor perception 与 snapshot 合同成立。")
	quit(0)


func _test_broadcast_signal_commit_and_dedupe() -> void:
	var system: SignalSystem = SIGNAL_SYSTEM_SCRIPT.new() as SignalSystem
	_assert_true(system != null, "必须能创建 SignalSystem。")
	if system == null:
		return
	_assert_ok(system.configure(["ronnie", "martha"], _broadcast_tasks()), "SignalSystem 必须接受有限 Actor/广播定义。")
	system.signal_committed.connect(_on_signal_committed)
	system.actor_signal_perceived.connect(_on_actor_signal_perceived)

	var broadcast_record: Dictionary = {
		"task_id": "task_test_broadcast",
		"information_item_ids": ["info_test_a"],
		"sent_at_tick": 600,
		"body": "这段自然语言不应进入 SignalRecord。",
	}
	var commit_result: Dictionary = system.commit_player_broadcast(broadcast_record)
	_assert_ok(commit_result, "已提交玩家广播必须能生成 SignalRecord。")
	_assert_true(not bool(commit_result.get("duplicate", true)), "第一次 signal commit 不得标记 duplicate。")
	if bool(commit_result.get("ok", false)):
		var record: Dictionary = commit_result["record"] as Dictionary
		_assert_equal(String(record["signal_id"]), "signal_player_broadcast_task_test_broadcast", "signal_id 必须从稳定 task_id 确定性派生。")
		_assert_equal(String(record["signal_type"]), "player_broadcast", "第一版 Signal 类型必须是 player_broadcast。")
		_assert_equal(int(record["created_at_tick"]), 600, "SignalRecord 必须保留 committed tick。")
		_assert_true(not record.has("body"), "SignalRecord 不得复制广播自然语言正文。")
		_assert_true(not (record["payload"] as Dictionary).has("body"), "Signal payload 不得复制广播自然语言正文。")
		_assert_equal((record["payload"] as Dictionary)["information_item_ids"], ["info_test_a"], "Signal payload 只传播稳定 information item IDs。")
		_assert_equal(record["committed_recipients"], ["martha", "ronnie"], "确定性 audience 必须提交排序后的 Actor recipients。")
	_assert_equal(_committed_count, 1, "首次广播只能提交一条 SignalRecord。")
	_assert_equal(_perception_events, ["martha:signal_player_broadcast_task_test_broadcast", "ronnie:signal_player_broadcast_task_test_broadcast"], "每个 committed recipient 必须恰好收到一次 perception 事件。")

	var duplicate_result: Dictionary = system.commit_player_broadcast(broadcast_record)
	_assert_ok(duplicate_result, "重复收到同一 committed broadcast 时 SignalSystem 必须幂等。")
	_assert_true(bool(duplicate_result.get("duplicate", false)), "重复 signal commit 必须标记 duplicate。")
	_assert_equal(_committed_count, 1, "幂等重复不得再次发 signal_committed。")
	_assert_equal(_perception_events.size(), 2, "幂等重复不得再次触发 Actor perception。")

	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot), "SignalSystem 自身快照必须通过严格校验。")
	var restored: SignalSystem = SIGNAL_SYSTEM_SCRIPT.new() as SignalSystem
	_assert_ok(restored.configure(["ronnie", "martha"], _broadcast_tasks()), "恢复目标必须先配置同一世界定义。")
	_restore_committed_count = 0
	_restore_perception_count = 0
	restored.signal_committed.connect(_on_restored_signal_committed)
	restored.actor_signal_perceived.connect(_on_restored_actor_signal_perceived)
	_assert_ok(restored.restore_snapshot(snapshot), "SignalSystem committed state 必须可恢复。")
	_assert_equal(_restore_committed_count, 0, "读档不得重新广播历史 signal_committed。")
	_assert_equal(_restore_perception_count, 0, "读档不得再次触发历史 Actor perception。")
	_assert_equal(restored.get_actor_perceived_signal_ids("ronnie"), ["signal_player_broadcast_task_test_broadcast"], "恢复后 Actor 的 deterministic perception 查询必须保持。")

	var invalid_snapshot: Dictionary = snapshot.duplicate(true)
	var invalid_records: Array = invalid_snapshot["records"] as Array
	((invalid_records[0] as Dictionary)["committed_recipients"] as Array).append("actor_missing")
	var invalid_result: Dictionary = restored.validate_snapshot(invalid_snapshot)
	_assert_error_code(invalid_result, "signal_snapshot_recipients_mismatch", "存档不得伪造或扩张 committed recipients。")


func _test_delivery_feedback_signal() -> void:
	var system: SignalSystem = SIGNAL_SYSTEM_SCRIPT.new() as SignalSystem
	_assert_ok(system.configure(["ronnie", "martha"], _broadcast_tasks()), "Delivery feedback 测试必须先配置同一 Actor 集合。")
	var delivery_record: Dictionary = {
		"delivery_id": "delivery_message_ronnie_1",
		"actor_id": "ronnie",
		"action_id": "send_message",
		"created_at_tick": 700,
		"arguments": {"body": "这段正文不得进入 Signal payload。"},
		"status": "committed",
		"target_system": "computer_system",
		"source_opportunity_id": "opportunity_test_follow_up",
		"source_director_plan_id": "director_plan_1",
	}
	var commit_result: Dictionary = system.commit_delivery_outcome(delivery_record, 705)
	_assert_ok(commit_result, "committed Delivery 必须形成 source Actor 可感知的 feedback Signal。")
	if bool(commit_result.get("ok", false)):
		var record: Dictionary = commit_result["record"] as Dictionary
		_assert_equal(String(record.get("signal_id", "")), "signal_delivery_outcome_delivery_message_ronnie_1", "Delivery feedback signal_id 必须从稳定 delivery_id 确定性派生。")
		_assert_equal(String(record.get("signal_type", "")), "delivery_outcome", "Delivery feedback 必须使用独立 signal_type。")
		_assert_equal(int(record.get("created_at_tick", -1)), 705, "Delivery feedback 必须记录真实 outcome tick。")
		_assert_equal(record.get("committed_recipients", []), ["ronnie"], "Delivery feedback 只能反馈给发起动作的 Actor。")
		var payload: Dictionary = record.get("payload", {}) as Dictionary
		_assert_equal(String(payload.get("status", "")), "committed", "Delivery feedback 必须保留确定性终态。")
		_assert_equal(String(payload.get("action_id", "")), "send_message", "Delivery feedback 必须保留有限动作 ID。")
		_assert_true(not payload.has("body") and not payload.has("arguments"), "Delivery feedback 不得复制模型生成正文或任意 arguments。")
	_assert_equal(system.get_actor_perceived_signal_ids("ronnie"), ["signal_delivery_outcome_delivery_message_ronnie_1"], "source Actor 必须能查询 committed feedback perception。")
	_assert_equal(system.get_actor_perceived_signal_ids("martha"), [], "无关 Actor 不得自动获知另一 Actor 的 Delivery outcome。")

	var duplicate: Dictionary = system.commit_delivery_outcome(delivery_record, 705)
	_assert_ok(duplicate, "重复提交同一 Delivery outcome 必须幂等。")
	_assert_true(bool(duplicate.get("duplicate", false)), "重复 Delivery feedback 必须标记 duplicate。")
	var conflict: Dictionary = system.commit_delivery_outcome(delivery_record, 706)
	_assert_error_code(conflict, "signal_id_conflict", "同一 delivery_id 不得映射到不同 outcome tick 的 SignalRecord。")

	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot), "含 Delivery feedback 的 Signal snapshot 必须可自校验。")
	var restored: SignalSystem = SIGNAL_SYSTEM_SCRIPT.new() as SignalSystem
	_assert_ok(restored.configure(["ronnie", "martha"], _broadcast_tasks()), "Delivery feedback restore 目标必须配置同一世界。")
	_restore_committed_count = 0
	_restore_perception_count = 0
	restored.signal_committed.connect(_on_restored_signal_committed)
	restored.actor_signal_perceived.connect(_on_restored_actor_signal_perceived)
	_assert_ok(restored.restore_snapshot(snapshot), "Delivery feedback Signal 必须可恢复且不重放。")
	_assert_equal(_restore_committed_count, 0, "恢复 Delivery feedback 不得重发 signal_committed。")
	_assert_equal(_restore_perception_count, 0, "恢复 Delivery feedback 不得重放 Actor perception。")
	_assert_equal(restored.get_actor_perceived_signal_ids("ronnie"), ["signal_delivery_outcome_delivery_message_ronnie_1"], "恢复后 source Actor perception 查询必须保持。")


func _test_actor_perception_commit() -> void:
	var actor: ActorAgent = ACTOR_AGENT_SCRIPT.new() as ActorAgent
	_assert_ok(actor.configure("ronnie", {"display_name": "Ronnie"}, {"heard_signal_ids": []}), "Actor smoke 必须可配置 canonical heard_signal_ids。")
	var first_result: Dictionary = actor.record_signal_perception("signal_player_broadcast_task_test_broadcast")
	_assert_ok(first_result, "Actor 专用 perception commit 必须接受非空 signal_id。")
	_assert_true(not bool(first_result.get("already_perceived", true)), "Actor 首次感知不得标记为重复。")
	var second_result: Dictionary = actor.record_signal_perception("signal_player_broadcast_task_test_broadcast")
	_assert_ok(second_result, "Actor perception commit 必须幂等。")
	_assert_true(bool(second_result.get("already_perceived", false)), "Actor 重复感知必须标记 already_perceived。")
	_assert_equal((actor.create_snapshot()["state"] as Dictionary)["heard_signal_ids"], ["signal_player_broadcast_task_test_broadcast"], "Actor snapshot 必须持久化去重后的 heard_signal_ids。")


func _broadcast_tasks() -> Array:
	return [{
		"id": "task_test_broadcast",
		"information_items": [
			{"id": "info_test_a"},
			{"id": "info_test_b"},
		],
	}]


func _on_signal_committed(_record: Dictionary) -> void:
	_committed_count += 1


func _on_actor_signal_perceived(actor_id: String, signal_id: String) -> void:
	_perception_events.append("%s:%s" % [actor_id, signal_id])


func _on_restored_signal_committed(_record: Dictionary) -> void:
	_restore_committed_count += 1


func _on_restored_actor_signal_perceived(_actor_id: String, _signal_id: String) -> void:
	_restore_perception_count += 1


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
	push_error("[测试][SignalSystem] %s" % message)
