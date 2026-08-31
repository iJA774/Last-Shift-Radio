extends SceneTree

## Autonomous Actor Loop 的纯确定性合同测试；不访问网络，也不依赖 LLM endpoint。

const OPPORTUNITY_BUILDER_SCRIPT: GDScript = preload("res://scripts/systems/opportunity_builder.gd")
const DIRECTOR_TRIGGER_POLICY_SCRIPT: GDScript = preload("res://scripts/systems/director_trigger_policy.gd")
const ACTOR_SCHEDULER_SCRIPT: GDScript = preload("res://scripts/systems/actor_scheduler.gd")

var _has_failed: bool = false


class FakeStory:
	extends RefCounted
	var conditions: Dictionary = {}
	var delivery_state: Dictionary = {"available": true, "requests": []}

	func is_condition_met(condition_id: String) -> bool:
		return bool(conditions.get(condition_id, false))

	func get_delivery_state() -> Dictionary:
		return delivery_state.duplicate(true)


func _init() -> void:
	_test_opportunity_builder_from_committed_signal()
	_test_trigger_policy_dedupe_and_cooldown()
	_test_actor_scheduler_authored_order_goal_pairing_and_cooldown()
	if _has_failed:
		print("[测试][AutonomousActorLoop] 失败。")
		quit(1)
		return
	print("[测试][AutonomousActorLoop] 通过：Opportunity、Director trigger 与 Actor scheduling 确定性合同成立。")
	quit(0)


func _test_opportunity_builder_from_committed_signal() -> void:
	var builder: OpportunityBuilder = OPPORTUNITY_BUILDER_SCRIPT.new() as OpportunityBuilder
	_assert_ok(builder.configure(_compiled_definition()), "OpportunityBuilder 必须接受已编译 WorldBook authored definitions。")
	var story: FakeStory = FakeStory.new()
	story.conditions["condition_wagon_witness_request_sent"] = false
	var trigger: Dictionary = {"kind": "signal_committed", "source_id": "task_broadcast_wagon_witness_request"}
	var blocked: Dictionary = builder.build_candidates(trigger, story)
	_assert_ok(blocked, "条件未成立时构造候选不应报错。")
	_assert_equal((blocked.get("candidates", []) as Array).size(), 0, "未满足 authored condition 时不得暴露 Martha opportunity。")

	story.conditions["condition_wagon_witness_request_sent"] = true
	var opened: Dictionary = builder.build_candidates(trigger, story)
	_assert_ok(opened, "玩家广播 committed 且条件成立后应能构造候选。")
	var candidates: Array = opened.get("candidates", []) as Array
	_assert_equal(candidates.size(), 1, "Martha witness chain 必须成为唯一匹配候选。")
	if candidates.size() == 1:
		_assert_equal(String((candidates[0] as Dictionary).get("id", "")), "opportunity_martha_witness_chain", "OpportunityBuilder 只能返回 authored ID。")
	_assert_equal(
		builder.get_actor_disclosable_claim_ids("martha", "opportunity_martha_witness_chain"),
		["statement_martha_route"],
		"自主决策 claim 白名单只能来自该 Actor 在 opportunity authored event 中的 Statement。"
	)

	story.delivery_state = {
		"available": true,
		"requests": [
			{"source_opportunity_id": "opportunity_martha_witness_chain"},
		],
	}
	var consumed: Dictionary = builder.build_candidates(trigger, story)
	_assert_ok(consumed, "已消费 opportunity 的重评估不应报错。")
	_assert_equal((consumed.get("candidates", []) as Array).size(), 0, "已有 DeliveryRequest 的 source_opportunity_id 必须确定性去重。")


func _test_trigger_policy_dedupe_and_cooldown() -> void:
	var policy: DirectorTriggerPolicy = DIRECTOR_TRIGGER_POLICY_SCRIPT.new() as DirectorTriggerPolicy
	_assert_ok(policy.enqueue_trigger("signal_committed", "task_one", 100), "首个 committed trigger 必须入队。")
	var duplicate: Dictionary = policy.enqueue_trigger("signal_committed", "task_one", 100)
	_assert_ok(duplicate, "重复 trigger 必须幂等。")
	_assert_true(bool(duplicate.get("duplicate", false)), "重复 trigger 必须显式标记 duplicate。")
	_assert_equal(policy.get_pending_count(), 1, "重复 trigger 不得制造第二条 pending planning request。")
	var first_ready: Dictionary = policy.take_ready_trigger(100)
	_assert_true(bool(first_ready.get("ready", false)), "第一条 trigger 不应被初始 cooldown 阻塞。")
	_assert_equal(String(first_ready.get("plan_context_id", "")), "director_context_1", "Director context ID 必须来自确定性 serial。")
	_assert_ok(policy.mark_attempt_completed(100), "Director attempt 完成后必须记录 cooldown 基线。")

	_assert_ok(policy.enqueue_trigger("interaction_completed", "call_test", 101), "第二种 committed trigger 必须可入队。")
	var cooling: Dictionary = policy.take_ready_trigger(110)
	_assert_true(not bool(cooling.get("ready", true)), "30 tick cooldown 内不得再次调用 Director。")
	_assert_equal(String(cooling.get("reason", "")), "cooldown", "cooldown 阻塞必须可审计。")
	var second_ready: Dictionary = policy.take_ready_trigger(130)
	_assert_true(bool(second_ready.get("ready", false)), "cooldown 到期后 pending trigger 必须可继续。")
	_assert_equal(String(second_ready.get("plan_context_id", "")), "director_context_2", "Context serial 必须稳定递增。")
	_assert_ok(policy.mark_attempt_completed(130), "第二次 Director attempt 必须更新 cooldown 基线。")
	_assert_ok(policy.enqueue_trigger("fact_confirmed", "fact_test", 135), "尚未规划的 committed trigger 必须可留在 pending queue。")
	var snapshot: Dictionary = policy.create_snapshot().duplicate(true)
	_assert_ok(policy.validate_snapshot(snapshot, {"current_game_tick": 140}), "Director trigger/cooldown 状态必须可严格存档。")
	var restored: DirectorTriggerPolicy = DIRECTOR_TRIGGER_POLICY_SCRIPT.new() as DirectorTriggerPolicy
	_assert_ok(restored.restore_snapshot(snapshot, {"current_game_tick": 140}), "DirectorTriggerPolicy 必须恢复 pending trigger 而不重放世界事件。")
	_assert_equal(restored.get_pending_count(), 1, "读档后尚未规划的 committed trigger 不能丢失。")
	var restored_cooling: Dictionary = restored.take_ready_trigger(140)
	_assert_true(not bool(restored_cooling.get("ready", true)), "恢复后 Director cooldown 必须继续生效。")
	var restored_ready: Dictionary = restored.take_ready_trigger(160)
	_assert_true(bool(restored_ready.get("ready", false)), "恢复后 cooldown 到期必须继续处理原 pending trigger。")
	_assert_equal(String(restored_ready.get("plan_context_id", "")), "director_context_3", "恢复后 context serial 必须精确接续，不得回退或随机化。")
	var tampered: Dictionary = snapshot.duplicate(true)
	((tampered["pending_triggers"] as Array)[0] as Dictionary)["created_at_tick"] = 999
	_assert_error_code(restored.validate_snapshot(tampered, {"current_game_tick": 140}), "director_trigger_snapshot_trigger_invalid", "存档不得包含来自未来 tick 的 pending trigger。")


func _test_actor_scheduler_authored_order_goal_pairing_and_cooldown() -> void:
	var scheduler: ActorScheduler = ACTOR_SCHEDULER_SCRIPT.new() as ActorScheduler
	var candidates: Array = [
		{
			"id": "opportunity_martha_witness_chain",
			"summary": "test",
			"actor_ids": ["martha", "dog_walker"],
			"event_ids": ["call_03_martha", "call_04_dog_walker"],
			"condition_ids": ["condition_wagon_witness_request_sent"],
			"goal_ids": ["find_danny_safely", "report_wagon_observation"],
		},
	]
	var actors: Dictionary = {
		"martha": {"state": {"available_goal_ids": ["find_danny_safely"]}},
		"dog_walker": {"state": {"available_goal_ids": ["report_wagon_observation"]}},
	}
	var plan_snapshot: Dictionary = {
		"serial": 3,
		"context_id": "director_context_3",
		"plan": {
			"selected_opportunity_ids": ["opportunity_martha_witness_chain"],
			"actor_goal_ids": {
				"martha": "find_danny_safely",
				"dog_walker": "report_wagon_observation",
			},
			"pacing_note": "test",
		},
	}
	var scheduled: Dictionary = scheduler.build_decisions(plan_snapshot, candidates, actors, 200, {"requests": []})
	_assert_ok(scheduled, "合法 Director plan 必须形成 decision opportunity。")
	var decisions: Array = scheduled.get("decisions", []) as Array
	_assert_equal(decisions.size(), 1, "一个 authored opportunity 第一版只能调度一个 Actor。")
	if decisions.size() == 1:
		var decision: Dictionary = decisions[0] as Dictionary
		_assert_equal(String(decision.get("actor_id", "")), "martha", "同一 opportunity 必须保持 WorldBook actor_ids authored 顺序。")
		_assert_equal(String(decision.get("goal_id", "")), "find_danny_safely", "调度 goal 必须属于该 opportunity 且属于 Actor available_goal_ids。")
		_assert_equal(String(decision.get("director_plan_id", "")), "director_plan_3", "Delivery source Director plan ID 必须是确定性 serial ID。")

	_assert_ok(scheduler.mark_pending("martha"), "Actor request 开始时必须进入 pending guard。")
	var blocked_pending: Dictionary = scheduler.build_decisions(plan_snapshot, candidates, actors, 201, {"requests": []})
	_assert_equal((blocked_pending.get("decisions", []) as Array).size(), 1, "Martha pending 时 authored 次序中的下一个合法 Actor 可以获得同一尚未消费机会。")
	if (blocked_pending.get("decisions", []) as Array).size() == 1:
		_assert_equal(String(((blocked_pending.get("decisions", []) as Array)[0] as Dictionary).get("actor_id", "")), "dog_walker", "pending guard 必须阻止同一 Actor re-entry。")
	_assert_ok(scheduler.mark_completed("martha", 205), "Actor decision 完成后必须进入 cooldown。")
	var cooling: Dictionary = scheduler.build_decisions(plan_snapshot, candidates, actors, 220, {"requests": []})
	if (cooling.get("decisions", []) as Array).size() > 0:
		_assert_true(String(((cooling.get("decisions", []) as Array)[0] as Dictionary).get("actor_id", "")) != "martha", "cooldown 内 Martha 不得再次获得 decision opportunity。")
	var after_cooldown: Dictionary = scheduler.build_decisions(plan_snapshot, candidates, actors, 235, {"requests": []})
	_assert_ok(after_cooldown, "Actor cooldown 到期后调度应恢复。")
	var consumed: Dictionary = scheduler.build_decisions(
		plan_snapshot,
		candidates,
		actors,
		235,
		{"requests": [{"source_opportunity_id": "opportunity_martha_witness_chain"}]}
	)
	_assert_equal((consumed.get("decisions", []) as Array).size(), 0, "Delivery 已消费 opportunity 后 Scheduler 不得重复调度。")

	var invalid_pair_plan: Dictionary = plan_snapshot.duplicate(true)
	(invalid_pair_plan["plan"] as Dictionary)["actor_goal_ids"] = {"martha": "report_wagon_observation"}
	var invalid_pair: Dictionary = scheduler.build_decisions(invalid_pair_plan, candidates, actors, 235, {"requests": []})
	_assert_equal((invalid_pair.get("decisions", []) as Array).size(), 0, "ActorScheduler 必须拒绝 opportunity goal 与 Actor available goal 不匹配的 pair。")

	var scheduler_snapshot: Dictionary = scheduler.create_snapshot().duplicate(true)
	_assert_true(not scheduler_snapshot.has("pending_actor_ids"), "ActorScheduler 存档不得序列化无法恢复的 in-flight model request。")
	_assert_ok(scheduler.validate_snapshot(scheduler_snapshot, {"current_game_tick": 235, "actor_ids": ["martha", "dog_walker"]}), "Actor cooldown 状态必须通过严格存档校验。")
	var restored_scheduler: ActorScheduler = ACTOR_SCHEDULER_SCRIPT.new() as ActorScheduler
	_assert_ok(restored_scheduler.restore_snapshot(scheduler_snapshot, {"current_game_tick": 235, "actor_ids": ["martha", "dog_walker"]}), "ActorScheduler 必须恢复 cooldown 且清空 transient pending request。")
	_assert_true(not restored_scheduler.has_pending_requests(), "读档后不得伪造已经失去网络请求的 pending Actor。")
	var restored_decision: Dictionary = restored_scheduler.build_decisions(plan_snapshot, candidates, actors, 235, {"requests": []})
	_assert_ok(restored_decision, "恢复后的 ActorScheduler 必须仍能正常调度。")
	var bad_scheduler_snapshot: Dictionary = scheduler_snapshot.duplicate(true)
	(bad_scheduler_snapshot["last_completed_tick_by_actor"] as Dictionary)["actor_missing"] = 200
	_assert_error_code(
		restored_scheduler.validate_snapshot(bad_scheduler_snapshot, {"current_game_tick": 235, "actor_ids": ["martha", "dog_walker"]}),
		"actor_scheduler_snapshot_actor_unknown",
		"ActorScheduler 存档不得引用当前 WorldBook 不存在的 Actor。"
	)


func _compiled_definition() -> Dictionary:
	return {
		"opportunities": [
			{
				"id": "opportunity_martha_witness_chain",
				"summary": "玛莎目击链测试",
				"actor_ids": ["martha", "dog_walker"],
				"event_ids": ["call_03_martha", "call_04_dog_walker"],
				"condition_ids": ["condition_wagon_witness_request_sent"],
				"goal_ids": ["find_danny_safely", "report_wagon_observation"],
			},
		],
		"events": [
			{"id": "call_03_martha", "actor_id": "martha", "available_statement_ids": ["statement_martha_route"]},
			{"id": "call_04_dog_walker", "actor_id": "dog_walker", "available_statement_ids": ["statement_dog_walker_wagon"]},
		],
		"tasks": [
			{
				"id": "task_broadcast_wagon_witness_request",
				"related_event_ids": ["call_03_martha"],
				"sets_condition_id": "condition_wagon_witness_request_sent",
			},
		],
		"facts": [
			{"id": "fact_test", "required_statement_ids": ["statement_martha_route"]},
		],
	}


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
	push_error("[测试][AutonomousActorLoop] %s" % message)
