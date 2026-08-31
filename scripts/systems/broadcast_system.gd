## 玩家通过麦克风执行发布任务的最小权威记账状态。
##
## 本系统不判断“是否完成了哪些对话”或“哪些陈述已经揭示”；这些剧情资格全部由
## StoryEngine 负责。本系统只接受已校验的任务定义，保证每个任务本局最多发布一次，
## 并用稳定 task_id / information_item_ids 生成可严格校验的玩家播出记录。
class_name BroadcastSystem
extends RefCounted

signal publication_state_changed()
signal player_broadcast_sent(record: Dictionary)
signal broadcast_error(task_id: String, error_code: String, message: String)

const SNAPSHOT_VERSION: int = 2
const SYSTEM_ID: String = "broadcast_system"

var _task_by_id: Dictionary = {}
var _sent_task_ids: Dictionary = {}
var _player_records: Array[Dictionary] = []


func configure_tasks(tasks: Array) -> Dictionary:
	if not _task_by_id.is_empty() or not _player_records.is_empty():
		return _make_error("", "already_configured", "发布任务已配置，不能在同一局中覆盖权威状态。")
	if tasks.is_empty():
		return _make_error("", "empty_broadcast_tasks", "测试剧情至少需要一个麦克风发布任务。")
	for raw_task: Variant in tasks:
		if not raw_task is Dictionary:
			return _make_error("", "invalid_broadcast_task", "发布任务必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		var validation: Dictionary = _validate_runtime_task(task)
		if not bool(validation.get("ok", false)):
			return validation
		var task_id: String = String(task["id"])
		if _task_by_id.has(task_id):
			return _make_error(task_id, "duplicate_task_id", "发布任务 ID 重复。")
		_task_by_id[task_id] = task.duplicate(true)
	return {"ok": true}


## StoryEngine 已经完成资格校验后调用。这里仍严格检查所选信息项是否属于该任务，
## 防止 UI 或其它调用者把任意正文写入播出记录。
func send_task_publication(task_id: String, information_item_ids: Array[String], sent_at_tick: int) -> Dictionary:
	if sent_at_tick < 0:
		return _make_error(task_id, "invalid_sent_at_tick", "广播发送 tick 不能小于零。")
	if not _task_by_id.has(task_id):
		return _make_error(task_id, "unknown_task_id", "不存在该麦克风发布任务。")
	if _sent_task_ids.has(task_id):
		return _make_error(task_id, "task_already_published", "该发布任务本局已经完成，不能重复记账。")
	var selection_result: Dictionary = _normalize_information_selection(task_id, information_item_ids)
	if not bool(selection_result.get("ok", false)):
		return selection_result
	var normalized_ids: Array[String] = selection_result["ids"] as Array[String]
	var task: Dictionary = _task_by_id[task_id] as Dictionary
	var body: String = _compose_body(task, normalized_ids)
	var record: Dictionary = {
		"task_id": task_id,
		"information_item_ids": normalized_ids.duplicate(),
		"source": String(task["source"]),
		"sent_at_tick": sent_at_tick,
		"body": body,
		"is_unauthorized": false,
	}
	_sent_task_ids[task_id] = true
	_player_records.append(record)
	var public_record: Dictionary = _make_read_only_copy(record)
	player_broadcast_sent.emit(public_record)
	publication_state_changed.emit()
	print("[广播任务][%s] 玩家已发布，items=%s，tick=%d。" % [task_id, str(normalized_ids), sent_at_tick])
	return {
		"ok": true,
		"record": public_record,
		"sets_condition_id": String(task["sets_condition_id"]),
	}


func is_task_sent(task_id: String) -> bool:
	return _sent_task_ids.has(task_id)


func get_player_broadcast_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _player_records:
		result.append(_make_read_only_copy(record))
	return result


func create_snapshot() -> Dictionary:
	var sent_task_ids: Array[String] = _sorted_dictionary_keys(_sent_task_ids)
	var player_records: Array[Dictionary] = []
	for record: Dictionary in _player_records:
		player_records.append(record.duplicate(true))
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"sent_task_ids": sent_task_ids,
		"player_records": player_records,
	}
	snapshot.make_read_only()
	return snapshot


func validate_snapshot(snapshot: Dictionary, _context: Dictionary = {}) -> Dictionary:
	if _task_by_id.is_empty():
		return _make_error("", "snapshot_content_not_configured", "发布任务尚未配置，不能校验存档。")
	var envelope: Dictionary = _validate_snapshot_envelope(snapshot)
	if not bool(envelope.get("ok", false)):
		return envelope
	var sent_result: Dictionary = _validate_snapshot_task_id_array(snapshot["sent_task_ids"])
	if not bool(sent_result.get("ok", false)):
		return sent_result
	if not snapshot["player_records"] is Array:
		return _make_error("", "invalid_snapshot_records", "广播存档的 player_records 必须是数组。")
	var sent_ids: Array[String] = sent_result["ids"] as Array[String]
	var records_result: Dictionary = _validate_snapshot_records(snapshot["player_records"] as Array, _string_array_to_lookup(sent_ids))
	if not bool(records_result.get("ok", false)):
		return records_result
	return {
		"ok": true,
		"normalized": {
			"sent_task_ids": sent_ids,
			"player_records": records_result["records"],
		},
	}


## 恢复不触发业务信号；上层会在整个运行时原子恢复完成后统一刷新 UI。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	_sent_task_ids = _string_array_to_lookup(normalized["sent_task_ids"] as Array[String])
	var next_records: Array[Dictionary] = []
	for raw_record: Variant in normalized["player_records"] as Array:
		var record: Dictionary = raw_record as Dictionary
		next_records.append(record.duplicate(true))
	_player_records = next_records
	return {"ok": true}


func _normalize_information_selection(task_id: String, raw_ids: Array[String]) -> Dictionary:
	var task: Dictionary = _task_by_id[task_id] as Dictionary
	var selection_mode: String = String(task["selection_mode"])
	if raw_ids.is_empty() or (selection_mode == "single" and raw_ids.size() != 1):
		return _make_error(task_id, "information_selection_count_invalid", "该任务要求选择%s条已收集信息。" % ("恰好一" if selection_mode == "single" else "至少一"))
	var selected_lookup: Dictionary = {}
	for information_id: String in raw_ids:
		if information_id.is_empty():
			return _make_error(task_id, "invalid_information_item_id", "所选信息项 ID 不能为空。")
		if selected_lookup.has(information_id):
			return _make_error(task_id, "duplicate_information_item_id", "同一信息项不能重复选择。")
		selected_lookup[information_id] = true
	var normalized: Array[String] = []
	for raw_item: Variant in task["information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		var information_id: String = String(item["id"])
		if selected_lookup.has(information_id):
			normalized.append(information_id)
			selected_lookup.erase(information_id)
	if not selected_lookup.is_empty():
		return _make_error(task_id, "unknown_information_item_id", "所选信息项不属于该发布任务。")
	return {"ok": true, "ids": normalized}


func _compose_body(task: Dictionary, information_item_ids: Array[String]) -> String:
	var selected_lookup: Dictionary = _string_array_to_lookup(information_item_ids)
	var paragraphs: PackedStringArray = []
	for raw_item: Variant in task["information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		if selected_lookup.has(String(item["id"])):
			paragraphs.append(String(item["body"]))
	return "\n\n".join(paragraphs)


func _validate_snapshot_envelope(snapshot: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = ["snapshot_version", "system_id", "sent_task_ids", "player_records"]
	if snapshot.size() != required_fields.size():
		return _make_error("", "snapshot_fields_invalid", "广播存档字段缺失或包含未知字段。")
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return _make_error("", "snapshot_missing_field", "广播存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_snapshot_integer(snapshot["snapshot_version"], SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result.get("ok", false)):
		return _make_error("", "snapshot_version_unsupported", "广播存档版本不受支持。")
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SYSTEM_ID:
		return _make_error("", "snapshot_system_id_mismatch", "广播存档所属系统不匹配。")
	return {"ok": true}


func _validate_snapshot_task_id_array(value: Variant) -> Dictionary:
	if not value is Array:
		return _make_error("", "invalid_snapshot_task_ids", "广播存档字段 sent_task_ids 必须是数组。")
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not _task_by_id.has(String(raw_id)):
			return _make_error(String(raw_id), "snapshot_unknown_task_id", "广播存档引用了不存在的发布任务 ID。")
		var task_id: String = String(raw_id)
		if seen.has(task_id):
			return _make_error(task_id, "snapshot_duplicate_task_id", "广播存档不能包含重复发布任务 ID。")
		seen[task_id] = true
		ids.append(task_id)
	ids.sort()
	return {"ok": true, "ids": ids}


func _validate_snapshot_records(raw_records: Array, sent_lookup: Dictionary) -> Dictionary:
	var records: Array[Dictionary] = []
	var record_task_ids: Dictionary = {}
	for raw_record: Variant in raw_records:
		if not raw_record is Dictionary:
			return _make_error("", "invalid_snapshot_record", "广播存档记录必须是对象。")
		var record: Dictionary = raw_record as Dictionary
		var expected_fields: PackedStringArray = ["task_id", "information_item_ids", "source", "sent_at_tick", "body", "is_unauthorized"]
		if record.size() != expected_fields.size():
			return _make_error("", "snapshot_record_fields_invalid", "玩家广播记录字段缺失或包含未知字段。")
		for field_name: String in expected_fields:
			if not record.has(field_name):
				return _make_error("", "snapshot_record_missing_field", "广播存档记录缺少字段：%s。" % field_name)
		if not record["task_id"] is String or not sent_lookup.has(String(record["task_id"])):
			return _make_error(String(record.get("task_id", "")), "snapshot_record_unsent_task", "广播记录必须对应一个已发布任务。")
		var task_id: String = String(record["task_id"])
		if record_task_ids.has(task_id):
			return _make_error(task_id, "snapshot_duplicate_record", "同一发布任务只能有一条玩家广播记录。")
		if not record["information_item_ids"] is Array:
			return _make_error(task_id, "snapshot_invalid_information_ids", "广播记录的 information_item_ids 必须是数组。")
		var raw_information_ids: Array[String] = []
		for raw_information_id: Variant in record["information_item_ids"] as Array:
			if not raw_information_id is String:
				return _make_error(task_id, "snapshot_invalid_information_id", "广播记录的信息项 ID 必须是字符串。")
			raw_information_ids.append(String(raw_information_id))
		var selection_result: Dictionary = _normalize_information_selection(task_id, raw_information_ids)
		if not bool(selection_result.get("ok", false)):
			return selection_result
		var information_ids: Array[String] = selection_result["ids"] as Array[String]
		if not record["source"] is String or not record["body"] is String:
			return _make_error(task_id, "snapshot_invalid_record", "广播记录的来源和正文必须是字符串。")
		var tick_result: Dictionary = _read_snapshot_integer(record["sent_at_tick"], 0)
		if not bool(tick_result.get("ok", false)):
			return _make_error(task_id, "snapshot_invalid_record", "广播记录发送 tick 无效。")
		if typeof(record["is_unauthorized"]) != TYPE_BOOL or bool(record["is_unauthorized"]):
			return _make_error(task_id, "snapshot_unauthorized_record", "玩家广播存档不能包含未授权播出记录。")
		var task: Dictionary = _task_by_id[task_id] as Dictionary
		var expected_body: String = _compose_body(task, information_ids)
		if String(record["source"]) != String(task["source"]) or String(record["body"]) != expected_body:
			return _make_error(task_id, "snapshot_record_content_mismatch", "广播记录与当前任务/信息项定义不一致。")
		var normalized: Dictionary = {
			"task_id": task_id,
			"information_item_ids": information_ids.duplicate(),
			"source": String(record["source"]),
			"sent_at_tick": int(tick_result["value"]),
			"body": expected_body,
			"is_unauthorized": false,
		}
		records.append(normalized)
		record_task_ids[task_id] = true
	if record_task_ids.size() != sent_lookup.size():
		return _make_error("", "snapshot_record_sent_mismatch", "玩家广播记录必须与已发布任务一一对应。")
	records.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return String(first["task_id"]) < String(second["task_id"])
	)
	return {"ok": true, "records": records}


func _validate_runtime_task(task: Dictionary) -> Dictionary:
	for field_name: String in ["id", "name", "selection_mode", "source", "sets_condition_id"]:
		if not task.has(field_name) or typeof(task[field_name]) != TYPE_STRING:
			return _make_error("", "invalid_broadcast_task", "发布任务缺少字符串字段：%s。" % field_name)
	if String(task["id"]).is_empty() or String(task["name"]).strip_edges().is_empty() or String(task["source"]).strip_edges().is_empty():
		return _make_error(String(task["id"]), "invalid_broadcast_task", "发布任务 ID、名称和来源不能为空。")
	if not ["single", "multiple"].has(String(task["selection_mode"])):
		return _make_error(String(task["id"]), "invalid_selection_mode", "发布任务 selection_mode 必须为 single 或 multiple。")
	if not task.has("information_items") or typeof(task["information_items"]) != TYPE_ARRAY or (task["information_items"] as Array).is_empty():
		return _make_error(String(task["id"]), "invalid_broadcast_task", "发布任务至少需要一个 information_items 条目。")
	var item_ids: Dictionary = {}
	for raw_item: Variant in task["information_items"] as Array:
		if not raw_item is Dictionary:
			return _make_error(String(task["id"]), "invalid_information_item", "任务信息项必须是对象。")
		var item: Dictionary = raw_item as Dictionary
		for field_name: String in ["id", "body"]:
			if not item.has(field_name) or typeof(item[field_name]) != TYPE_STRING or String(item[field_name]).strip_edges().is_empty():
				return _make_error(String(task["id"]), "invalid_information_item", "任务信息项缺少有效字段：%s。" % field_name)
		var item_id: String = String(item["id"])
		if item_ids.has(item_id):
			return _make_error(String(task["id"]), "duplicate_information_item_id", "同一任务中的信息项 ID 不能重复。")
		item_ids[item_id] = true
	return {"ok": true}


func _read_snapshot_integer(value: Variant, minimum: int, maximum: int = -1) -> Dictionary:
	var parsed: int = 0
	if typeof(value) == TYPE_INT:
		parsed = int(value)
	elif typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), floor(float(value))):
		parsed = int(value)
	else:
		return {"ok": false}
	if parsed < minimum or (maximum >= 0 and parsed > maximum):
		return {"ok": false}
	return {"ok": true, "value": parsed}


func _string_array_to_lookup(ids: Array[String]) -> Dictionary:
	var lookup: Dictionary = {}
	for stable_id: String in ids:
		lookup[stable_id] = true
	return lookup


func _sorted_dictionary_keys(source: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id: Variant in source.keys():
		ids.append(String(raw_id))
	ids.sort()
	return ids


func _make_read_only_copy(source: Dictionary) -> Dictionary:
	var copy: Dictionary = source.duplicate(true)
	copy.make_read_only()
	return copy


func _make_error(task_id: String, error_code: String, message: String) -> Dictionary:
	broadcast_error.emit(task_id, error_code, message)
	printerr("[广播任务][%s][%s] %s" % [task_id, error_code, message])
	return {"ok": false, "task_id": task_id, "error_code": error_code, "message": message}
