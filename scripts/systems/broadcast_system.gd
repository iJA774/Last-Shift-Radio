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
