## 玩家预制广播的最小权威状态。
##
## 本系统只接受已经过 ContentValidator 校验的稿件，并保证单次稿件不会被
## 快速重复点击伪造为多条记录。电话线路和 02:00 的未授权播出都不经过这里。
class_name BroadcastSystem
extends RefCounted

signal available_broadcasts_changed()
signal player_broadcast_sent(record: Dictionary)
signal broadcast_error(broadcast_id: String, error_code: String, message: String)

var _draft_by_id: Dictionary = {}
var _unlocked_draft_ids: Dictionary = {}
var _sent_broadcast_ids: Dictionary = {}
var _sent_exclusive_group_ids: Dictionary = {}
var _player_records: Array[Dictionary] = []

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "broadcast_system"


## 只能在一局开始、剧情内容校验完成后配置。调用者保留原始 JSON 不会改变内部状态。
func configure_drafts(drafts: Array) -> Dictionary:
	if not _draft_by_id.is_empty() or not _player_records.is_empty():
		return _make_error("", "already_configured", "广播稿已配置，不能在同一局中覆盖权威状态。")
	if drafts.is_empty():
		return _make_error("", "empty_broadcast_drafts", "测试剧情至少需要一条预制广播稿。")
	for raw_draft: Variant in drafts:
		if not raw_draft is Dictionary:
			return _make_error("", "invalid_broadcast_draft", "广播稿必须是对象。")
		var draft: Dictionary = raw_draft as Dictionary
		var validation: Dictionary = _validate_runtime_draft(draft)
		if not bool(validation.get("ok", false)):
			return validation
		var broadcast_id: String = String(draft["id"])
		if _draft_by_id.has(broadcast_id):
			return _make_error(broadcast_id, "duplicate_broadcast_id", "广播稿 ID 重复。")
		_draft_by_id[broadcast_id] = draft.duplicate(true)
	return {"ok": true}


## 短信或已经接通的来电通过稳定 ID 解锁稿件。未知来源 ID 是无害的 no-op，
## 因为内容交叉引用已经在启动时严格校验；这里不从显示正文推断状态。
func unlock_for_source_id(source_id: String) -> Dictionary:
	if source_id.is_empty():
		return _make_error("", "invalid_unlock_source_id", "解锁来源 ID 不能为空。")
	var unlocked_count: int = 0
	for broadcast_id_variant: Variant in _draft_by_id.keys():
		var broadcast_id: String = String(broadcast_id_variant)
		if _unlocked_draft_ids.has(broadcast_id):
			continue
		var draft: Dictionary = _draft_by_id[broadcast_id] as Dictionary
		var message_ids: Array = draft["unlock_message_ids"] as Array
		var event_ids: Array = draft["unlock_event_ids"] as Array
		if not message_ids.has(source_id) and not event_ids.has(source_id):
			continue
		_unlocked_draft_ids[broadcast_id] = true
		unlocked_count += 1
	if unlocked_count > 0:
		available_broadcasts_changed.emit()
		print("[广播][%s] 已解锁 %d 条预制稿件。" % [source_id, unlocked_count])
	return {"ok": true, "unlocked_count": unlocked_count}


## 玩家唯一的发送入口。成功后记录必须同时包含稳定 ID、来源、游戏 tick、正文与
## is_unauthorized=false；任何失败都不写入半条记录。
func send_player_broadcast(broadcast_id: String, sent_at_tick: int) -> Dictionary:
	if sent_at_tick < 0:
		return _make_error(broadcast_id, "invalid_sent_at_tick", "广播发送 tick 不能小于零。")
	if not _draft_by_id.has(broadcast_id):
		return _make_error(broadcast_id, "unknown_broadcast_id", "不存在该预制广播稿。")
	if not _unlocked_draft_ids.has(broadcast_id):
		return _make_error(broadcast_id, "broadcast_not_unlocked", "该广播稿尚未解锁，不能发送。")
	if _sent_broadcast_ids.has(broadcast_id):
		return _make_error(broadcast_id, "broadcast_already_sent", "该预制广播稿本局已发送，不能重复记账。")
	var draft: Dictionary = _draft_by_id[broadcast_id] as Dictionary
	var exclusive_group_id: String = String(draft["exclusive_group_id"])
	if not exclusive_group_id.is_empty() and _sent_exclusive_group_ids.has(exclusive_group_id):
		return _make_error(broadcast_id, "broadcast_exclusive_group_sent", "同一封桥口径组已有一条稿件播出，不能重复播报相互排斥的口径。")
	var record: Dictionary = {
		"broadcast_id": broadcast_id,
		"source": String(draft["source"]),
		"sent_at_tick": sent_at_tick,
		"body": String(draft["body"]),
		"is_unauthorized": false,
	}
	_sent_broadcast_ids[broadcast_id] = true
	if not exclusive_group_id.is_empty():
		_sent_exclusive_group_ids[exclusive_group_id] = broadcast_id
	_player_records.append(record)
	var public_record: Dictionary = _make_read_only_copy(record)
	player_broadcast_sent.emit(public_record)
	available_broadcasts_changed.emit()
	print("[广播][%s] 玩家已发送，tick=%d。" % [broadcast_id, sent_at_tick])
	return {
		"ok": true,
		"record": public_record,
		"sets_condition_id": String(draft["sets_condition_id"]),
	}


func get_available_drafts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for broadcast_id_variant: Variant in _draft_by_id.keys():
		var broadcast_id: String = String(broadcast_id_variant)
		if not _unlocked_draft_ids.has(broadcast_id):
			continue
		var draft: Dictionary = (_draft_by_id[broadcast_id] as Dictionary).duplicate(true)
		var exclusive_group_id: String = String(draft["exclusive_group_id"])
		var is_sent: bool = _sent_broadcast_ids.has(broadcast_id)
		var is_exclusive_group_sent: bool = not exclusive_group_id.is_empty() and _sent_exclusive_group_ids.has(exclusive_group_id)
		draft["is_sent"] = is_sent
		draft["is_available_to_send"] = not is_sent and not is_exclusive_group_sent
		if is_sent:
			draft["disabled_reason"] = "本稿件已发送。"
		elif is_exclusive_group_sent:
			draft["disabled_reason"] = "已播出另一条封桥口径，本稿不再可发送。"
		else:
			draft["disabled_reason"] = ""
		draft.make_read_only()
		result.append(draft)
	result.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return String(first["id"]) < String(second["id"])
	)
	return result


func get_player_broadcast_records() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for record: Dictionary in _player_records:
		result.append(_make_read_only_copy(record))
	return result


func is_broadcast_sent(broadcast_id: String) -> bool:
	return _sent_broadcast_ids.has(broadcast_id)


## 保存的广播状态只引用内容中已配置的稳定 ID；稿件正文和定义始终由内容包提供。
## 返回值完全 JSON 安全，且固定排序使手动槽位内容可复核。
func create_snapshot() -> Dictionary:
	var unlocked_draft_ids: Array[String] = _sorted_dictionary_keys(_unlocked_draft_ids)
	var sent_broadcast_ids: Array[String] = _sorted_dictionary_keys(_sent_broadcast_ids)
	var sent_exclusive_group_ids: Array[String] = _sorted_dictionary_keys(_sent_exclusive_group_ids)
	var player_records: Array[Dictionary] = []
	for record: Dictionary in _player_records:
		player_records.append(record.duplicate(true))
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"unlocked_draft_ids": unlocked_draft_ids,
		"sent_broadcast_ids": sent_broadcast_ids,
		"sent_exclusive_group_ids": sent_exclusive_group_ids,
		"player_records": player_records,
	}
	snapshot.make_read_only()
	return snapshot


## 验证先于恢复完成；不配置内容或任何 ID/记录不一致时均明确拒绝，绝不补默认值。
func validate_snapshot(snapshot: Dictionary, _context: Dictionary = {}) -> Dictionary:
	if _draft_by_id.is_empty():
		return _make_error("", "snapshot_content_not_configured", "广播稿尚未配置，不能校验存档。")
	var top_level_validation: Dictionary = _validate_snapshot_envelope(snapshot)
	if not bool(top_level_validation.get("ok", false)):
		return top_level_validation
	var unlocked_result: Dictionary = _validate_snapshot_id_array(snapshot["unlocked_draft_ids"], "unlocked_draft_ids")
	if not bool(unlocked_result.get("ok", false)):
		return unlocked_result
	var sent_result: Dictionary = _validate_snapshot_id_array(snapshot["sent_broadcast_ids"], "sent_broadcast_ids")
	if not bool(sent_result.get("ok", false)):
		return sent_result
	var group_result: Dictionary = _validate_snapshot_group_id_array(snapshot["sent_exclusive_group_ids"])
	if not bool(group_result.get("ok", false)):
		return group_result
	if not snapshot["player_records"] is Array:
		return _make_error("", "invalid_snapshot_records", "广播存档的 player_records 必须是数组。")

	var unlocked_ids: Array[String] = unlocked_result["ids"] as Array[String]
	var sent_ids: Array[String] = sent_result["ids"] as Array[String]
	var group_ids: Array[String] = group_result["ids"] as Array[String]
	var unlocked_lookup: Dictionary = _string_array_to_lookup(unlocked_ids)
	var sent_lookup: Dictionary = _string_array_to_lookup(sent_ids)
	for broadcast_id: String in sent_ids:
		if not unlocked_lookup.has(broadcast_id):
			return _make_error(broadcast_id, "snapshot_sent_not_unlocked", "已发送广播必须同时属于已解锁稿件。")

	var expected_groups: Dictionary = {}
	for broadcast_id: String in sent_ids:
		var draft: Dictionary = _draft_by_id[broadcast_id] as Dictionary
		var group_id: String = String(draft["exclusive_group_id"])
		if group_id.is_empty():
			continue
		if expected_groups.has(group_id):
			return _make_error(broadcast_id, "snapshot_exclusive_group_conflict", "存档中同一互斥组包含多条已发送稿件。")
		expected_groups[group_id] = broadcast_id
	var expected_group_ids: Array[String] = _sorted_dictionary_keys(expected_groups)
	if expected_group_ids != group_ids:
		return _make_error("", "snapshot_exclusive_group_mismatch", "广播存档的互斥组状态与已发送稿件不一致。")

	var records_result: Dictionary = _validate_snapshot_records(snapshot["player_records"] as Array, sent_lookup)
	if not bool(records_result.get("ok", false)):
		return records_result
	var normalized: Dictionary = {
		"unlocked_draft_ids": unlocked_ids,
		"sent_broadcast_ids": sent_ids,
		"sent_exclusive_group_ids": group_ids,
		"player_records": records_result["records"],
	}
	return {"ok": true, "normalized": normalized}


## 恢复不会触发广播发送、解锁或可用列表信号；上层只在整个运行时原子恢复后刷新 UI。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	var next_unlocked: Dictionary = _string_array_to_lookup(normalized["unlocked_draft_ids"] as Array[String])
	var next_sent: Dictionary = _string_array_to_lookup(normalized["sent_broadcast_ids"] as Array[String])
	var next_groups: Dictionary = {}
	for group_id: String in normalized["sent_exclusive_group_ids"] as Array[String]:
		for broadcast_id: String in normalized["sent_broadcast_ids"] as Array[String]:
			var draft: Dictionary = _draft_by_id[broadcast_id] as Dictionary
			if String(draft["exclusive_group_id"]) == group_id:
				next_groups[group_id] = broadcast_id
				break
	var next_records: Array[Dictionary] = []
	for record: Dictionary in normalized["player_records"] as Array[Dictionary]:
		next_records.append(record.duplicate(true))

	_unlocked_draft_ids = next_unlocked
	_sent_broadcast_ids = next_sent
	_sent_exclusive_group_ids = next_groups
	_player_records = next_records
	return {"ok": true}


func _validate_snapshot_envelope(snapshot: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = [
		"snapshot_version",
		"system_id",
		"unlocked_draft_ids",
		"sent_broadcast_ids",
		"sent_exclusive_group_ids",
		"player_records",
	]
	if snapshot.size() != required_fields.size():
		return _make_error("", "snapshot_fields_invalid", "广播存档字段缺失或包含未知字段。")
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return _make_error("", "snapshot_missing_field", "广播存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_snapshot_integer(snapshot["snapshot_version"], "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result.get("ok", false)):
		return _make_error("", "snapshot_version_unsupported", "广播存档版本不受支持。")
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SYSTEM_ID:
		return _make_error("", "snapshot_system_id_mismatch", "广播存档所属系统不匹配。")
	return {"ok": true}


func _validate_snapshot_id_array(value: Variant, field_name: String) -> Dictionary:
	if not value is Array:
		return _make_error("", "invalid_snapshot_id_array", "广播存档字段 %s 必须是数组。" % field_name)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not _draft_by_id.has(String(raw_id)):
			return _make_error(String(raw_id), "snapshot_unknown_broadcast_id", "广播存档引用了不存在的稿件 ID。")
		var broadcast_id: String = String(raw_id)
		if seen.has(broadcast_id):
			return _make_error(broadcast_id, "snapshot_duplicate_broadcast_id", "广播存档不能包含重复稿件 ID。")
		seen[broadcast_id] = true
		ids.append(broadcast_id)
	ids.sort()
	return {"ok": true, "ids": ids}


func _validate_snapshot_group_id_array(value: Variant) -> Dictionary:
	if not value is Array:
		return _make_error("", "invalid_snapshot_group_array", "广播存档字段 sent_exclusive_group_ids 必须是数组。")
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or String(raw_id).is_empty():
			return _make_error(String(raw_id), "snapshot_invalid_exclusive_group", "广播存档互斥组 ID 无效。")
		var group_id: String = String(raw_id)
		if seen.has(group_id):
			return _make_error(group_id, "snapshot_duplicate_exclusive_group", "广播存档不能包含重复互斥组 ID。")
		seen[group_id] = true
		ids.append(group_id)
	ids.sort()
	return {"ok": true, "ids": ids}


func _validate_snapshot_records(raw_records: Array, sent_lookup: Dictionary) -> Dictionary:
	var records: Array[Dictionary] = []
	var record_ids: Dictionary = {}
	for raw_record: Variant in raw_records:
		if not raw_record is Dictionary:
			return _make_error("", "invalid_snapshot_record", "广播存档记录必须是对象。")
		var record: Dictionary = raw_record as Dictionary
		for field_name: String in ["broadcast_id", "source", "sent_at_tick", "body", "is_unauthorized"]:
			if not record.has(field_name):
				return _make_error("", "snapshot_record_missing_field", "广播存档记录缺少字段：%s。" % field_name)
		if not record["broadcast_id"] is String or not sent_lookup.has(String(record["broadcast_id"])):
			return _make_error(String(record.get("broadcast_id", "")), "snapshot_record_unsent_id", "广播记录必须对应一条已发送稿件。")
		var broadcast_id: String = String(record["broadcast_id"])
		if record_ids.has(broadcast_id):
			return _make_error(broadcast_id, "snapshot_duplicate_record", "同一已发送广播只能有一条记录。")
		if not record["source"] is String or not record["body"] is String:
			return _make_error(broadcast_id, "snapshot_invalid_record", "广播存档记录字段类型或发送 tick 无效。")
		var tick_result: Dictionary = _read_snapshot_integer(record["sent_at_tick"], "sent_at_tick", 0)
		if not bool(tick_result.get("ok", false)):
			return _make_error(broadcast_id, "snapshot_invalid_record", "广播存档记录字段类型或发送 tick 无效。")
		if typeof(record["is_unauthorized"]) != TYPE_BOOL or bool(record["is_unauthorized"]):
			return _make_error(broadcast_id, "snapshot_unauthorized_record", "玩家广播存档不能包含未授权播出记录。")
		var draft: Dictionary = _draft_by_id[broadcast_id] as Dictionary
		if String(record["source"]) != String(draft["source"]) or String(record["body"]) != String(draft["body"]):
			return _make_error(broadcast_id, "snapshot_record_content_mismatch", "广播存档记录与当前稿件定义不一致。")
		var normalized: Dictionary = {
			"broadcast_id": broadcast_id,
			"source": String(record["source"]),
			"sent_at_tick": int(tick_result["value"]),
			"body": String(record["body"]),
			"is_unauthorized": false,
		}
		records.append(normalized)
		record_ids[broadcast_id] = true
	if record_ids.size() != sent_lookup.size():
		return _make_error("", "snapshot_record_sent_mismatch", "广播记录必须与已发送稿件一一对应。")
	for broadcast_id_variant: Variant in sent_lookup.keys():
		if not record_ids.has(String(broadcast_id_variant)):
			return _make_error(String(broadcast_id_variant), "snapshot_missing_record", "已发送广播缺少对应记录。")
	records.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return String(first["broadcast_id"]) < String(second["broadcast_id"])
	)
	return {"ok": true, "records": records}


func _string_array_to_lookup(ids: Array[String]) -> Dictionary:
	var lookup: Dictionary = {}
	for entry_id: String in ids:
		lookup[entry_id] = true
	return lookup


func _sorted_dictionary_keys(source: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id: Variant in source.keys():
		ids.append(String(raw_id))
	ids.sort()
	return ids


## Godot 的 JSON 解析器会把 JSON 数字读成 float；只接受数学上精确的整数，
## 既兼容自己写出的 JSON，又不允许 1.5 之类的关键时间偷偷截断。
func _read_snapshot_integer(value: Variant, _field_name: String, minimum: int, maximum: int = -1) -> Dictionary:
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


func _validate_runtime_draft(draft: Dictionary) -> Dictionary:
	var required_strings: PackedStringArray = ["id", "source", "body", "sets_condition_id", "exclusive_group_id"]
	for field_name: String in required_strings:
		if not draft.has(field_name) or typeof(draft[field_name]) != TYPE_STRING:
			return _make_error("", "invalid_broadcast_draft", "广播稿缺少字符串字段：%s。" % field_name)
	if String(draft["id"]).is_empty() or String(draft["source"]).strip_edges().is_empty() or String(draft["body"]).strip_edges().is_empty():
		return _make_error(String(draft["id"]), "invalid_broadcast_draft", "广播稿 ID、来源和正文不能为空。")
	for field_name: String in ["unlock_message_ids", "unlock_event_ids"]:
		if not draft.has(field_name) or typeof(draft[field_name]) != TYPE_ARRAY:
			return _make_error(String(draft["id"]), "invalid_broadcast_draft", "广播稿字段 %s 必须是数组。" % field_name)
	return {"ok": true}


func _make_read_only_copy(source: Dictionary) -> Dictionary:
	var copy: Dictionary = source.duplicate(true)
	copy.make_read_only()
	return copy


func _make_error(broadcast_id: String, error_code: String, message: String) -> Dictionary:
	broadcast_error.emit(broadcast_id, error_code, message)
	# 未解锁、重复点击和互斥口径都是玩家可见的拒绝结果，不是引擎异常；
	# 保留可定位开发日志，但不把通过按钮状态即可避免的操作记成 ERROR。
	printerr("[广播][%s][%s] %s" % [broadcast_id, error_code, message])
	return {"ok": false, "broadcast_id": broadcast_id, "error_code": error_code, "message": message}
