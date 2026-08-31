class_name ActorScheduler
extends RefCounted

## 把 Director 已验证 plan 转成有限、确定性的 Actor decision opportunity。
## 一个 authored opportunity 第一版只调度一个 Actor，避免同一 source_opportunity_id 产生竞争提交。

const ACTOR_DECISION_COOLDOWN_TICKS: int = 30
const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "actor_scheduler"

var _pending_actor_ids: Dictionary = {}
var _last_completed_tick_by_actor: Dictionary = {}


func reset() -> void:
	_pending_actor_ids.clear()
	_last_completed_tick_by_actor.clear()


func build_decisions(
	plan_snapshot: Dictionary,
	candidate_opportunities: Array,
	actor_snapshots: Dictionary,
	current_tick: int,
	delivery_state: Dictionary
) -> Dictionary:
	if current_tick < 0:
		return _error("actor_scheduler_tick_invalid", "ActorScheduler current_tick 不能为负数。")
	if not plan_snapshot.get("plan") is Dictionary:
		return _error("actor_scheduler_plan_invalid", "ActorScheduler 需要包含 plan 的 Director plan snapshot。")
	var serial_value: Variant = plan_snapshot.get("serial")
	if typeof(serial_value) != TYPE_INT or int(serial_value) < 1:
		return _error("actor_scheduler_plan_invalid", "Director plan snapshot serial 必须是正整数。")
	var plan: Dictionary = plan_snapshot["plan"] as Dictionary
	if not plan.get("selected_opportunity_ids") is Array or not plan.get("actor_goal_ids") is Dictionary:
		return _error("actor_scheduler_plan_invalid", "Director plan 缺少 selected_opportunity_ids/actor_goal_ids。")

	var opportunity_by_id: Dictionary = {}
	for raw_opportunity: Variant in candidate_opportunities:
		if not raw_opportunity is Dictionary:
			return _error("actor_scheduler_candidate_invalid", "ActorScheduler candidate opportunity 必须是对象。")
		var opportunity: Dictionary = raw_opportunity as Dictionary
		var opportunity_id: String = String(opportunity.get("id", ""))
		if opportunity_id.is_empty() or opportunity_by_id.has(opportunity_id):
			return _error("actor_scheduler_candidate_invalid", "ActorScheduler candidate opportunity ID 为空或重复。")
		for field_name: String in ["actor_ids", "goal_ids"]:
			if not opportunity.get(field_name) is Array:
				return _error("actor_scheduler_candidate_invalid", "Opportunity %s.%s 必须是数组。" % [opportunity_id, field_name])
		opportunity_by_id[opportunity_id] = opportunity.duplicate(true)

	var consumed_ids: Dictionary = _collect_consumed_opportunity_ids(delivery_state)
	var selected_ids: Array[String] = []
	for raw_id: Variant in plan["selected_opportunity_ids"] as Array:
		if not raw_id is String:
			return _error("actor_scheduler_plan_invalid", "Director selected_opportunity_ids 只能包含字符串。")
		selected_ids.append(String(raw_id))
	selected_ids.sort()
	var actor_goal_ids: Dictionary = plan["actor_goal_ids"] as Dictionary
	var decisions: Array[Dictionary] = []
	for opportunity_id: String in selected_ids:
		if consumed_ids.has(opportunity_id):
			continue
		if not opportunity_by_id.has(opportunity_id):
			return _error("actor_scheduler_opportunity_missing", "Director 选择的 opportunity 不在本轮候选中：%s。" % opportunity_id)
		var opportunity: Dictionary = opportunity_by_id[opportunity_id] as Dictionary
		var eligible_actor_ids: Array[String] = []
		for raw_actor_id: Variant in opportunity["actor_ids"] as Array:
			var actor_id: String = String(raw_actor_id)
			if not actor_goal_ids.has(actor_id):
				continue
			var goal_id: String = String(actor_goal_ids[actor_id])
			if not (opportunity["goal_ids"] as Array).has(goal_id):
				continue
			if not actor_snapshots.has(actor_id) or not actor_snapshots[actor_id] is Dictionary:
				continue
			var actor_snapshot: Dictionary = actor_snapshots[actor_id] as Dictionary
			var state: Dictionary = actor_snapshot.get("state", {}) as Dictionary
			if not (state.get("available_goal_ids", []) as Array).has(goal_id):
				continue
			if _pending_actor_ids.has(actor_id) or _is_actor_cooling_down(actor_id, current_tick):
				continue
			# WorldBook actor_ids 的 authored 顺序本身就是稳定顺序；保留它可以让作者控制
			# 同一 Opportunity 中谁优先获得第一次 decision opportunity。
			eligible_actor_ids.append(actor_id)
		if eligible_actor_ids.is_empty():
			continue
		var selected_actor_id: String = eligible_actor_ids[0]
		var selected_goal_id: String = String(actor_goal_ids[selected_actor_id])
		decisions.append({
			"decision_id": "decision_%s_%s" % [opportunity_id, selected_actor_id],
			"opportunity_id": opportunity_id,
			"actor_id": selected_actor_id,
			"goal_id": selected_goal_id,
			"director_plan_id": "director_plan_%d" % int(serial_value),
			"opportunity": opportunity.duplicate(true),
		})
	return {"ok": true, "decisions": decisions}


func mark_pending(actor_id: String) -> Dictionary:
	if actor_id.strip_edges().is_empty():
		return _error("actor_scheduler_actor_invalid", "ActorScheduler actor_id 不能为空。")
	if _pending_actor_ids.has(actor_id):
		return _error("actor_scheduler_actor_pending", "Actor %s 已有未完成 autonomous request。" % actor_id)
	_pending_actor_ids[actor_id] = true
	return {"ok": true}


func mark_completed(actor_id: String, current_tick: int) -> Dictionary:
	if current_tick < 0:
		return _error("actor_scheduler_tick_invalid", "ActorScheduler completion tick 不能为负数。")
	_pending_actor_ids.erase(actor_id)
	_last_completed_tick_by_actor[actor_id] = current_tick
	return {"ok": true}


func clear_pending(actor_id: String) -> void:
	_pending_actor_ids.erase(actor_id)


func has_pending_requests() -> bool:
	return not _pending_actor_ids.is_empty()


func create_snapshot() -> Dictionary:
	var cooldowns: Dictionary = {}
	var actor_ids: Array = _last_completed_tick_by_actor.keys()
	actor_ids.sort()
	for raw_actor_id: Variant in actor_ids:
		cooldowns[String(raw_actor_id)] = int(_last_completed_tick_by_actor[raw_actor_id])
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"last_completed_tick_by_actor": cooldowns,
	}


func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var fields: PackedStringArray = ["snapshot_version", "system_id", "last_completed_tick_by_actor"]
	if snapshot.size() != fields.size():
		return _error("actor_scheduler_snapshot_fields_invalid", "ActorScheduler 存档字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not snapshot.has(field_name):
			return _error("actor_scheduler_snapshot_missing_field", "ActorScheduler 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("actor_scheduler_snapshot_version_invalid", "ActorScheduler 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("actor_scheduler_snapshot_system_invalid", "ActorScheduler 存档 system_id 不匹配。")
	if not snapshot["last_completed_tick_by_actor"] is Dictionary:
		return _error("actor_scheduler_snapshot_cooldown_invalid", "ActorScheduler cooldown 状态必须是对象。")
	var current_tick: int = 3600
	if context.has("current_game_tick"):
		var tick_result: Dictionary = _read_exact_integer(context["current_game_tick"])
		if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
			return _error("actor_scheduler_snapshot_context_invalid", "ActorScheduler current_game_tick 恢复上下文无效。")
		current_tick = int(tick_result["value"])
	var allowed_actor_ids: Array = context.get("actor_ids", []) as Array
	var normalized: Dictionary = {}
	for raw_actor_id: Variant in (snapshot["last_completed_tick_by_actor"] as Dictionary).keys():
		if not raw_actor_id is String or String(raw_actor_id).strip_edges().is_empty():
			return _error("actor_scheduler_snapshot_actor_invalid", "ActorScheduler cooldown Actor ID 无效。")
		var actor_id: String = String(raw_actor_id)
		if not allowed_actor_ids.is_empty() and not allowed_actor_ids.has(actor_id):
			return _error("actor_scheduler_snapshot_actor_unknown", "ActorScheduler cooldown 引用了当前世界不存在的 Actor：%s。" % actor_id)
		var completed_result: Dictionary = _read_exact_integer((snapshot["last_completed_tick_by_actor"] as Dictionary)[raw_actor_id])
		if not bool(completed_result.get("ok", false)) or int(completed_result["value"]) < 0 or int(completed_result["value"]) > current_tick:
			return _error("actor_scheduler_snapshot_tick_invalid", "ActorScheduler cooldown tick 超出当前世界时间：%s。" % actor_id)
		normalized[actor_id] = int(completed_result["value"])
	return {"ok": true, "normalized": {"last_completed_tick_by_actor": normalized}}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	_pending_actor_ids.clear()
	_last_completed_tick_by_actor = ((validation["normalized"] as Dictionary)["last_completed_tick_by_actor"] as Dictionary).duplicate(true)
	return {"ok": true}


func _is_actor_cooling_down(actor_id: String, current_tick: int) -> bool:
	if not _last_completed_tick_by_actor.has(actor_id):
		return false
	return current_tick - int(_last_completed_tick_by_actor[actor_id]) < ACTOR_DECISION_COOLDOWN_TICKS


func _collect_consumed_opportunity_ids(delivery_state: Dictionary) -> Dictionary:
	var consumed: Dictionary = {}
	for raw_request: Variant in delivery_state.get("requests", []) as Array:
		if not raw_request is Dictionary:
			continue
		var opportunity_id: String = String((raw_request as Dictionary).get("source_opportunity_id", ""))
		if not opportunity_id.is_empty():
			consumed[opportunity_id] = true
	return consumed


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
