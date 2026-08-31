class_name TaskSystem
extends RefCounted

## 通用任务/目标的确定性权威。
##
## 只消费 StoryEngine 已提交的 world_state；模型不能直接改变 task 状态。
## requirement tree 支持叶子，以及 mode=all/any 的最小组合。状态只允许
## pending -> active -> completed/failed，终态不可回退。restore 不重放业务信号。

signal task_transition_committed(record: Dictionary)

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "task_system"
const STATUS_PENDING: String = "pending"
const STATUS_ACTIVE: String = "active"
const STATUS_COMPLETED: String = "completed"
const STATUS_FAILED: String = "failed"
const STATUSES: PackedStringArray = [STATUS_PENDING, STATUS_ACTIVE, STATUS_COMPLETED, STATUS_FAILED]
const GROUP_MODES: PackedStringArray = ["all", "any"]
const REQUIREMENT_TYPES: PackedStringArray = [
	"statement_revealed",
	"fact_confirmed",
	"condition_true",
	"interaction_answered",
	"interaction_completed",
	"broadcast_sent",
	"message_read",
	"dialogue_completed",
	"information_available",
	"interaction_outcome_committed",
]
const WORLD_ARRAY_FIELDS: PackedStringArray = [
	"statement_revealed_ids",
	"fact_confirmed_ids",
	"interaction_answered_ids",
	"interaction_completed_ids",
	"broadcast_sent_ids",
	"message_read_ids",
	"dialogue_completed_ids",
	"information_available_task_ids",
	"interaction_outcome_event_ids",
]

var _is_configured: bool = false
var _task_by_id: Dictionary = {}
var _state_by_task_id: Dictionary = {}
var _transitions: Array[Dictionary] = []
var _transition_by_id: Dictionary = {}


func configure(task_definitions: Array) -> Dictionary:
	if _is_configured or not _task_by_id.is_empty() or not _transitions.is_empty():
		return _error("task_system_already_configured", "TaskSystem 已配置，不能在同一局中覆盖任务定义。")
	var next_tasks: Dictionary = {}
	for raw_task: Variant in task_definitions:
		if not raw_task is Dictionary:
			return _error("task_definition_invalid", "TaskSystem task definition 必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		var fields: PackedStringArray = ["id", "activation", "completion"]
		if task.size() != fields.size():
			return _error("task_definition_fields_invalid", "TaskSystem task definition 字段缺失或包含未知字段。")
		for field_name: String in fields:
			if not task.has(field_name):
				return _error("task_definition_missing_field", "TaskSystem task definition 缺少字段：%s。" % field_name)
		if not task["id"] is String or not _is_stable_id(String(task["id"])):
			return _error("task_id_invalid", "TaskSystem task id 必须是英文 snake_case。")
		var task_id: String = String(task["id"])
		if next_tasks.has(task_id):
			return _error("task_id_duplicate", "TaskSystem task id 重复：%s。" % task_id)
		var activation_result: Dictionary = _validate_requirement_node(task["activation"], "activation")
		if not bool(activation_result.get("ok", false)):
			return activation_result
		var completion_result: Dictionary = _validate_requirement_node(task["completion"], "completion")
		if not bool(completion_result.get("ok", false)):
			return completion_result
		next_tasks[task_id] = {
			"id": task_id,
			"activation": (activation_result["node"] as Dictionary).duplicate(true),
			"completion": (completion_result["node"] as Dictionary).duplicate(true),
		}
	_task_by_id = next_tasks
	_state_by_task_id = {}
	for task_id: String in _sorted_keys(_task_by_id):
		_state_by_task_id[task_id] = STATUS_PENDING
	_is_configured = true
	return {"ok": true, "task_count": _task_by_id.size()}


func evaluate_requirements(requirements: Variant, world_state: Dictionary) -> Dictionary:
	var world_result: Dictionary = _validate_world_state(world_state)
	if not bool(world_result.get("ok", false)):
		return world_result
	var node: Dictionary = {}
	if requirements is Array:
		var requirement_array: Array = requirements as Array
		if requirement_array.is_empty():
			return {"ok": true, "satisfied": true}
		node = {"mode": "all", "requirements": requirement_array.duplicate(true)}
	elif requirements is Dictionary:
		node = (requirements as Dictionary).duplicate(true)
	else:
		return _error("task_requirement_node_invalid", "requirements 必须是 requirement/group 对象或 requirement 数组。")
	var validation: Dictionary = _validate_requirement_node(node, "requirements")
	if not bool(validation.get("ok", false)):
		return validation
	return {"ok": true, "satisfied": _evaluate_node(validation["node"] as Dictionary, world_state)}


func refresh(world_state: Dictionary, current_tick: int) -> Dictionary:
	if not _is_configured:
		return _error("task_system_not_configured", "TaskSystem 尚未配置。")
	if current_tick < 0:
		return _error("task_tick_invalid", "TaskSystem current_tick 不能为负数。")
	var world_result: Dictionary = _validate_world_state(world_state)
	if not bool(world_result.get("ok", false)):
		return world_result
	var committed: Array[Dictionary] = []
	for task_id: String in _sorted_keys(_task_by_id):
		var task: Dictionary = _task_by_id[task_id] as Dictionary
		var status: String = String(_state_by_task_id[task_id])
		if status == STATUS_PENDING and _evaluate_node(task["activation"] as Dictionary, world_state):
			var active_result: Dictionary = _commit_transition(task_id, STATUS_PENDING, STATUS_ACTIVE, current_tick, "activation_requirements_met")
			if not bool(active_result.get("ok", false)):
				return active_result
			if not bool(active_result.get("duplicate", false)):
				committed.append((active_result["record"] as Dictionary).duplicate(true))
			status = STATUS_ACTIVE
		if status == STATUS_ACTIVE and _evaluate_node(task["completion"] as Dictionary, world_state):
			var completed_result: Dictionary = _commit_transition(task_id, STATUS_ACTIVE, STATUS_COMPLETED, current_tick, "completion_requirements_met")
			if not bool(completed_result.get("ok", false)):
				return completed_result
			if not bool(completed_result.get("duplicate", false)):
				committed.append((completed_result["record"] as Dictionary).duplicate(true))
	return {"ok": true, "transitions": committed}


func fail_task(task_id: String, current_tick: int, reason: String) -> Dictionary:
	if not _is_configured:
		return _error("task_system_not_configured", "TaskSystem 尚未配置。")
	if not _task_by_id.has(task_id):
		return _error("task_unknown", "TaskSystem 不存在 task：%s。" % task_id)
	if current_tick < 0 or reason.strip_edges().is_empty():
		return _error("task_failure_invalid", "Task failure 需要非负 tick 和非空 reason。")
	var status: String = String(_state_by_task_id[task_id])
	if status == STATUS_COMPLETED:
		return _error("task_already_completed", "已完成 task 不能再失败：%s。" % task_id)
	if status == STATUS_FAILED:
		var transition_id: String = _transition_id(task_id, STATUS_FAILED)
		if _transition_by_id.has(transition_id) and String((_transition_by_id[transition_id] as Dictionary)["reason"]) == reason:
			return {"ok": true, "duplicate": true, "record": _read_only_record(_transition_by_id[transition_id] as Dictionary)}
		return _error("task_failure_conflict", "同一 task 的 failed 终态不能用不同 reason 重写。")
	return _commit_transition(task_id, status, STATUS_FAILED, current_tick, reason)


func get_task_state(task_id: String) -> Dictionary:
	if not _task_by_id.has(task_id):
		return {}
	var result: Dictionary = {"task_id": task_id, "status": String(_state_by_task_id[task_id])}
	result.make_read_only()
	return result


func get_state_summary() -> Dictionary:
	var states: Dictionary = {}
	for task_id: String in _sorted_keys(_state_by_task_id):
		states[task_id] = String(_state_by_task_id[task_id])
	return {"available": true, "states": states, "transitions": get_transition_records()}


func get_transition_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _transitions:
		result.append(_read_only_record(record))
	return result


func create_snapshot() -> Dictionary:
	var states: Dictionary = {}
	for task_id: String in _sorted_keys(_state_by_task_id):
		states[task_id] = String(_state_by_task_id[task_id])
	var transitions: Array[Dictionary] = []
	for record: Dictionary in _transitions:
		transitions.append(record.duplicate(true))
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"states": states,
		"transitions": transitions,
	}
	snapshot.make_read_only()
	return snapshot


func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _is_configured:
		return _error("task_snapshot_not_configured", "TaskSystem 尚未配置，不能校验存档。")
	var fields: PackedStringArray = ["snapshot_version", "system_id", "states", "transitions"]
	if snapshot.size() != fields.size():
		return _error("task_snapshot_fields_invalid", "TaskSystem 存档字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not snapshot.has(field_name):
			return _error("task_snapshot_missing_field", "TaskSystem 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("task_snapshot_version_unsupported", "TaskSystem 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("task_snapshot_system_mismatch", "TaskSystem 存档 system_id 不匹配。")
	if not snapshot["states"] is Dictionary or not snapshot["transitions"] is Array:
		return _error("task_snapshot_shape_invalid", "TaskSystem states 必须是对象且 transitions 必须是数组。")
	var raw_states: Dictionary = snapshot["states"] as Dictionary
	if raw_states.size() != _task_by_id.size():
		return _error("task_snapshot_state_set_mismatch", "TaskSystem 存档必须包含当前定义的完整 task 状态集合。")
	for task_id: String in _sorted_keys(_task_by_id):
		if not raw_states.has(task_id) or not raw_states[task_id] is String or not STATUSES.has(String(raw_states[task_id])):
			return _error("task_snapshot_state_invalid", "TaskSystem 存档状态无效：%s。" % task_id)

	var replay_states: Dictionary = {}
	for task_id: String in _sorted_keys(_task_by_id):
		replay_states[task_id] = STATUS_PENDING
	var normalized_transitions: Array[Dictionary] = []
	var seen_transition_ids: Dictionary = {}
	var max_tick: int = -1
	if context.has("current_game_tick"):
		var context_tick_result: Dictionary = _read_exact_integer(context["current_game_tick"])
		if not bool(context_tick_result.get("ok", false)) or int(context_tick_result["value"]) < 0:
			return _error("task_snapshot_context_invalid", "TaskSystem context.current_game_tick 必须是非负整数。")
		max_tick = int(context_tick_result["value"])
	for raw_record: Variant in snapshot["transitions"] as Array:
		var record_result: Dictionary = _validate_transition_record(raw_record)
		if not bool(record_result.get("ok", false)):
			return record_result
		var record: Dictionary = record_result["record"] as Dictionary
		var transition_id: String = String(record["transition_id"])
		if seen_transition_ids.has(transition_id):
			return _error("task_snapshot_transition_duplicate", "TaskSystem 存档含重复 transition_id：%s。" % transition_id)
		seen_transition_ids[transition_id] = true
		if max_tick >= 0 and int(record["created_at_tick"]) > max_tick:
			return _error("task_snapshot_transition_future", "Task transition 不能晚于剧情存档时间。")
		var task_id: String = String(record["task_id"])
		var expected_from: String = String(replay_states[task_id])
		if String(record["from_status"]) != expected_from:
			return _error("task_snapshot_transition_order_invalid", "Task transition 的 from_status 与前序状态不一致：%s。" % task_id)
		var next_status: String = String(record["to_status"])
		if not _is_legal_transition(expected_from, next_status):
			return _error("task_snapshot_transition_illegal", "TaskSystem 存档含非法状态转换：%s -> %s。" % [expected_from, next_status])
		replay_states[task_id] = next_status
		normalized_transitions.append(record)
	for task_id: String in _sorted_keys(_task_by_id):
		if String(raw_states[task_id]) != String(replay_states[task_id]):
			return _error("task_snapshot_state_transition_mismatch", "Task 状态与 transition 历史不一致：%s。" % task_id)

	if context.has("world_state"):
		if not context["world_state"] is Dictionary:
			return _error("task_snapshot_context_invalid", "TaskSystem context.world_state 必须是对象。")
		var world_state: Dictionary = context["world_state"] as Dictionary
		var world_result: Dictionary = _validate_world_state(world_state)
		if not bool(world_result.get("ok", false)):
			return world_result
		for task_id: String in _sorted_keys(_task_by_id):
			var status: String = String(replay_states[task_id])
			var task: Dictionary = _task_by_id[task_id] as Dictionary
			if status == STATUS_PENDING and _evaluate_node(task["activation"] as Dictionary, world_state):
				return _error("task_snapshot_refresh_missing", "Task %s 已满足 activation，但存档仍为 pending。" % task_id)
			if status == STATUS_ACTIVE and _evaluate_node(task["completion"] as Dictionary, world_state):
				return _error("task_snapshot_refresh_missing", "Task %s 已满足 completion，但存档仍为 active。" % task_id)
	return {"ok": true, "normalized": {"states": replay_states, "transitions": normalized_transitions}}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	_state_by_task_id = (normalized["states"] as Dictionary).duplicate(true)
	_transitions.clear()
	_transition_by_id.clear()
	for raw_record: Variant in normalized["transitions"] as Array:
		var record: Dictionary = (raw_record as Dictionary).duplicate(true)
		_transitions.append(record)
		_transition_by_id[String(record["transition_id"])] = record
	return {"ok": true}


func _commit_transition(task_id: String, from_status: String, to_status: String, current_tick: int, reason: String) -> Dictionary:
	if not _is_legal_transition(from_status, to_status):
		return _error("task_transition_illegal", "Task 非法状态转换：%s -> %s。" % [from_status, to_status])
	if String(_state_by_task_id.get(task_id, "")) != from_status:
		return _error("task_transition_state_conflict", "Task 当前状态与提交转换不一致：%s。" % task_id)
	var transition_id: String = _transition_id(task_id, to_status)
	var record: Dictionary = {
		"transition_id": transition_id,
		"task_id": task_id,
		"from_status": from_status,
		"to_status": to_status,
		"created_at_tick": current_tick,
		"reason": reason,
	}
	if _transition_by_id.has(transition_id):
		var existing: Dictionary = _transition_by_id[transition_id] as Dictionary
		if existing != record:
			return _error("task_transition_id_conflict", "同一 transition_id 不能映射到不同 Task transition。")
		return {"ok": true, "duplicate": true, "record": _read_only_record(existing)}
	_state_by_task_id[task_id] = to_status
	_transitions.append(record)
	_transition_by_id[transition_id] = record
	var public_record: Dictionary = _read_only_record(record)
	task_transition_committed.emit(public_record)
	return {"ok": true, "duplicate": false, "record": public_record}


func _validate_transition_record(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _error("task_snapshot_transition_invalid", "Task transition 必须是对象。")
	var record: Dictionary = value as Dictionary
	var fields: PackedStringArray = ["transition_id", "task_id", "from_status", "to_status", "created_at_tick", "reason"]
	if record.size() != fields.size():
		return _error("task_snapshot_transition_fields_invalid", "Task transition 字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not record.has(field_name):
			return _error("task_snapshot_transition_missing_field", "Task transition 缺少字段：%s。" % field_name)
	if not record["task_id"] is String or not _task_by_id.has(String(record["task_id"])):
		return _error("task_snapshot_transition_task_unknown", "Task transition 引用了未知 task。")
	var task_id: String = String(record["task_id"])
	if not record["from_status"] is String or not record["to_status"] is String:
		return _error("task_snapshot_transition_status_invalid", "Task transition 状态必须是字符串。")
	var from_status: String = String(record["from_status"])
	var to_status: String = String(record["to_status"])
	if not STATUSES.has(from_status) or not STATUSES.has(to_status):
		return _error("task_snapshot_transition_status_invalid", "Task transition 含未知状态。")
	if not record["transition_id"] is String or String(record["transition_id"]) != _transition_id(task_id, to_status):
		return _error("task_snapshot_transition_id_invalid", "Task transition_id 与 task/to_status 不一致。")
	var tick_result: Dictionary = _read_exact_integer(record["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0:
		return _error("task_snapshot_transition_tick_invalid", "Task transition created_at_tick 必须是非负整数。")
	if not record["reason"] is String or String(record["reason"]).strip_edges().is_empty():
		return _error("task_snapshot_transition_reason_invalid", "Task transition reason 必须是非空字符串。")
	var normalized_record: Dictionary = record.duplicate(true)
	normalized_record["created_at_tick"] = int(tick_result["value"])
	return {"ok": true, "record": normalized_record}


func _validate_requirement_node(value: Variant, path: String) -> Dictionary:
	if not value is Dictionary:
		return _error("task_requirement_node_invalid", "%s 必须是 requirement 或 group 对象。" % path)
	var node: Dictionary = value as Dictionary
	if node.has("type") or node.has("id"):
		if node.size() != 2 or not node.has("type") or not node.has("id"):
			return _error("task_requirement_leaf_fields_invalid", "%s leaf 必须且只能包含 type/id。" % path)
		if not node["type"] is String or not REQUIREMENT_TYPES.has(String(node["type"])):
			return _error("task_requirement_type_invalid", "%s 使用了不支持的 requirement type。" % path)
		if not node["id"] is String or not _is_stable_id(String(node["id"])):
			return _error("task_requirement_id_invalid", "%s requirement id 必须是英文 snake_case。" % path)
		return {"ok": true, "node": {"type": String(node["type"]), "id": String(node["id"])}}
	if node.size() != 2 or not node.has("mode") or not node.has("requirements"):
		return _error("task_requirement_group_fields_invalid", "%s group 必须且只能包含 mode/requirements。" % path)
	if not node["mode"] is String or not GROUP_MODES.has(String(node["mode"])):
		return _error("task_requirement_group_mode_invalid", "%s group.mode 必须是 all 或 any。" % path)
	if not node["requirements"] is Array or (node["requirements"] as Array).is_empty():
		return _error("task_requirement_group_empty", "%s group.requirements 必须是非空数组。" % path)
	var children: Array[Dictionary] = []
	for index: int in range((node["requirements"] as Array).size()):
		var child_result: Dictionary = _validate_requirement_node((node["requirements"] as Array)[index], "%s.requirements[%d]" % [path, index])
		if not bool(child_result.get("ok", false)):
			return child_result
		children.append((child_result["node"] as Dictionary).duplicate(true))
	return {"ok": true, "node": {"mode": String(node["mode"]), "requirements": children}}


func _evaluate_node(node: Dictionary, world_state: Dictionary) -> bool:
	if node.has("type"):
		return _evaluate_leaf(String(node["type"]), String(node["id"]), world_state)
	var mode: String = String(node["mode"])
	var requirements: Array = node["requirements"] as Array
	if mode == "all":
		for raw_child: Variant in requirements:
			if not _evaluate_node(raw_child as Dictionary, world_state):
				return false
		return true
	for raw_child: Variant in requirements:
		if _evaluate_node(raw_child as Dictionary, world_state):
			return true
	return false


func _evaluate_leaf(requirement_type: String, requirement_id: String, world_state: Dictionary) -> bool:
	match requirement_type:
		"statement_revealed":
			return (world_state["statement_revealed_ids"] as Array).has(requirement_id)
		"fact_confirmed":
			return (world_state["fact_confirmed_ids"] as Array).has(requirement_id)
		"condition_true":
			return bool((world_state["condition_state_by_id"] as Dictionary).get(requirement_id, false))
		"interaction_answered":
			return (world_state["interaction_answered_ids"] as Array).has(requirement_id)
		"interaction_completed":
			return (world_state["interaction_completed_ids"] as Array).has(requirement_id)
		"broadcast_sent":
			return (world_state["broadcast_sent_ids"] as Array).has(requirement_id)
		"message_read":
			return (world_state["message_read_ids"] as Array).has(requirement_id)
		"dialogue_completed":
			return (world_state["dialogue_completed_ids"] as Array).has(requirement_id)
		"information_available":
			return (world_state["information_available_task_ids"] as Array).has(requirement_id)
		"interaction_outcome_committed":
			return (world_state["interaction_outcome_event_ids"] as Array).has(requirement_id)
	return false


func _validate_world_state(world_state: Dictionary) -> Dictionary:
	if not world_state.has("condition_state_by_id") or not world_state["condition_state_by_id"] is Dictionary:
		return _error("task_world_state_invalid", "Task world_state 缺少 condition_state_by_id。")
	for field_name: String in WORLD_ARRAY_FIELDS:
		if not world_state.has(field_name) or not world_state[field_name] is Array:
			return _error("task_world_state_invalid", "Task world_state 缺少数组字段：%s。" % field_name)
		for raw_id: Variant in world_state[field_name] as Array:
			if not raw_id is String:
				return _error("task_world_state_invalid", "Task world_state.%s 只能包含字符串 ID。" % field_name)
	return {"ok": true}


func _is_legal_transition(from_status: String, to_status: String) -> bool:
	if from_status == STATUS_PENDING:
		return to_status == STATUS_ACTIVE or to_status == STATUS_FAILED
	if from_status == STATUS_ACTIVE:
		return to_status == STATUS_COMPLETED or to_status == STATUS_FAILED
	return false


func _transition_id(task_id: String, to_status: String) -> String:
	return "task_transition_%s_%s" % [task_id, to_status]


func _is_stable_id(value: String) -> bool:
	return not value.is_empty() and not value.begins_with("_") and value == value.to_lower() and value.is_valid_identifier() and value.is_valid_ascii_identifier()


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number) or number < float(-9223372036854775807) or number > float(9223372036854775807):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _sorted_keys(dictionary: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for raw_key: Variant in dictionary.keys():
		keys.append(String(raw_key))
	keys.sort()
	return keys


func _read_only_record(record: Dictionary) -> Dictionary:
	var copy: Dictionary = record.duplicate(true)
	copy.make_read_only()
	return copy


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
