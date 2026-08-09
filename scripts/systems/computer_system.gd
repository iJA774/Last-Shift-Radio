class_name ComputerSystem
extends RefCounted

## 电脑信息显示模型。
##
## 此类只维护“来源已解锁 / 玩家已阅读”的展示状态。它不会把角色陈述推导成
## 剧情事实，也不会向 PhoneSystem 写入任何数据；来电页的每一条记录都必须由
## PhoneSystem 已生成的真实记录派生而来。

signal entries_changed(category: String)
signal source_unlocked(category: String, entry: Dictionary)
signal source_read(category: String, source_id: String, statement_ids: Array[String])

const CATEGORY_CHECKLIST: String = "checklist"
const CATEGORY_NEWS: String = "news"
const CATEGORY_MESSAGES: String = "messages"
const CATEGORY_CALL_LOG: String = "call_log"

const STATIC_CATEGORIES: Array[String] = [
	CATEGORY_CHECKLIST,
	CATEGORY_NEWS,
	CATEGORY_MESSAGES,
]

const ALL_CATEGORIES: Array[String] = [
	CATEGORY_CHECKLIST,
	CATEGORY_NEWS,
	CATEGORY_MESSAGES,
	CATEGORY_CALL_LOG,
]

var _content_entries_by_category: Dictionary = {
	CATEGORY_CHECKLIST: [],
	CATEGORY_NEWS: [],
	CATEGORY_MESSAGES: [],
}
var _unlocked_source_ids_by_category: Dictionary = {
	CATEGORY_CHECKLIST: {},
	CATEGORY_NEWS: {},
	CATEGORY_MESSAGES: {},
	CATEGORY_CALL_LOG: {},
}
var _read_source_ids_by_category: Dictionary = {
	CATEGORY_CHECKLIST: {},
	CATEGORY_NEWS: {},
	CATEGORY_MESSAGES: {},
	CATEGORY_CALL_LOG: {},
}
var _call_records_by_source_id: Dictionary = {}
var _call_record_order: Array[String] = []
var _phone_system: RefCounted = null
var _is_content_configured: bool = false
var _current_minute: int = -1
var _last_error: Dictionary = {}

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "computer_system"


## 接收已经通过内容管线校验的展示来源。这里仍在边界复核 ID、解锁时间和
## statement_ids/fact_ids 的形状，避免 UI 或外部脚本把可变输入直接带入状态。
func configure_content(
	checklist_entries: Array,
	news_entries: Array,
	messages: Array
) -> Dictionary:
	var seen_source_ids: Dictionary = {}
	var next_entries_by_category: Dictionary = {}
	var category_inputs: Dictionary = {
		CATEGORY_CHECKLIST: checklist_entries,
		CATEGORY_NEWS: news_entries,
		CATEGORY_MESSAGES: messages,
	}

	for category: String in STATIC_CATEGORIES:
		var validation: Dictionary = _validate_content_entries(
			category,
			category_inputs[category] as Array,
			seen_source_ids
		)
		if not bool(validation.get("ok", false)):
			return validation
		next_entries_by_category[category] = validation["entries"]

	_content_entries_by_category = next_entries_by_category
	_unlocked_source_ids_by_category[CATEGORY_CHECKLIST] = {}
	_unlocked_source_ids_by_category[CATEGORY_NEWS] = {}
	_unlocked_source_ids_by_category[CATEGORY_MESSAGES] = {}
	_read_source_ids_by_category[CATEGORY_CHECKLIST] = {}
	_read_source_ids_by_category[CATEGORY_NEWS] = {}
	_read_source_ids_by_category[CATEGORY_MESSAGES] = {}
	_is_content_configured = true
	_current_minute = -1
	_last_error = {}

	return _make_success({"configured_categories": STATIC_CATEGORIES.duplicate()})


## 电话记录保持 PhoneSystem 所有权。本方法只订阅它的记录信号，并在绑定时同步
## 它已经生成的快照；不会根据剧情事件预先创建“未来来电”。
func set_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("invalid_phone_system", "电话系统不能为空。")
	if not phone_system.has_method(&"get_call_records"):
		return _make_error("invalid_phone_system", "电话系统缺少 get_call_records 接口。")
	if not phone_system.has_signal(&"call_record_created"):
		return _make_error("invalid_phone_system", "电话系统缺少 call_record_created 信号。")

	var records_value: Variant = phone_system.call(&"get_call_records")
	if not records_value is Array:
		return _make_error("invalid_phone_records", "电话系统返回的来电记录必须是数组。", CATEGORY_CALL_LOG)
	var record_validation: Dictionary = _validate_call_records(records_value as Array)
	if not bool(record_validation.get("ok", false)):
		return record_validation

	if _phone_system == phone_system:
		return _synchronize_call_log_from_phone(true)

	var new_connection: Callable = Callable(self, "_on_phone_call_record_created")
	var connect_error: Error = phone_system.connect(&"call_record_created", new_connection)
	if connect_error != OK:
		return _make_error(
			"phone_signal_connect_failed",
			"无法订阅电话记录信号，错误码=%d。" % int(connect_error),
			CATEGORY_CALL_LOG
		)

	_disconnect_phone_system()
	_phone_system = phone_system
	_call_records_by_source_id = {}
	_call_record_order = []
	_unlocked_source_ids_by_category[CATEGORY_CALL_LOG] = {}
	_read_source_ids_by_category[CATEGORY_CALL_LOG] = {}

	var normalized_records: Array[Dictionary] = record_validation["records"] as Array[Dictionary]
	var synchronization: Dictionary = _store_call_records(normalized_records, true)
	if not bool(synchronization.get("ok", false)):
		return synchronization
	_last_error = {}
	return _make_success({"bound_phone_system": true, "call_record_count": _call_record_order.size()})


## 运行时销毁前释放 PhoneSystem 订阅。电脑自身的静态内容、已读状态和已经由
## PhoneSystem 真实产生的历史快照均保留在本对象中；本方法绝不补造或重置它们。
## 同一对象可重复释放，供上层生命周期清理安全调用。
func release_runtime() -> Dictionary:
	var had_phone_system: bool = _phone_system != null
	_disconnect_phone_system()
	_phone_system = null
	_last_error = {}
	return _make_success({"released_phone_system": had_phone_system})


## 用整数分钟推进静态信息源；同一时间重复推进是幂等的，倒退会被明确拒绝。
func advance_to_minute(current_minute: int) -> Dictionary:
	if not _is_content_configured:
		return _make_error("content_not_configured", "电脑内容尚未配置，不能推进信息解锁。")
	if current_minute < 0:
		return _make_error("invalid_minute", "电脑信息解锁分钟不能为负数。")
	if current_minute < _current_minute:
		return _make_error(
			"time_reversal",
			"电脑信息时间不能倒退：当前=%d，请求=%d。" % [_current_minute, current_minute]
		)

	var newly_unlocked: Array[Dictionary] = []
	var changed_categories: Dictionary = {}
	for category: String in STATIC_CATEGORIES:
		var category_entries: Array[Dictionary] = _content_entries_by_category[category] as Array[Dictionary]
		var unlocked_ids: Dictionary = _unlocked_source_ids_by_category[category] as Dictionary
		for entry: Dictionary in category_entries:
			var source_id: String = String(entry["id"])
			if unlocked_ids.has(source_id):
				continue
			if int(entry["unlock_minute"]) > current_minute:
				continue
			unlocked_ids[source_id] = true
			var snapshot: Dictionary = _make_entry_snapshot(category, entry, source_id)
			newly_unlocked.append(snapshot)
			changed_categories[category] = true
			_source_unlocked_snapshot(category, snapshot)

	_current_minute = current_minute
	for category: String in STATIC_CATEGORIES:
		if changed_categories.has(category):
			entries_changed.emit(category)
	_last_error = {}
	return _make_success({
		"current_minute": _current_minute,
		"newly_unlocked": newly_unlocked,
	})


## 只返回已解锁的静态来源或 PhoneSystem 已真实生成的来电记录。
## 每个元素都是独立只读快照，调用方的修改不会反向影响电脑状态。
func get_entries(category: String) -> Array[Dictionary]:
	if not _require_category(category):
		return []
	if category == CATEGORY_CALL_LOG:
		_synchronize_call_log_from_phone(true)
		return _get_call_log_snapshots()
	if not _is_content_configured:
		_make_error("content_not_configured", "电脑内容尚未配置，不能读取静态信息页。", category)
		return []

	var entries: Array[Dictionary] = []
	var category_entries: Array[Dictionary] = _content_entries_by_category[category] as Array[Dictionary]
	var unlocked_ids: Dictionary = _unlocked_source_ids_by_category[category] as Dictionary
	for entry: Dictionary in category_entries:
		var source_id: String = String(entry["id"])
		if unlocked_ids.has(source_id):
			entries.append(_make_entry_snapshot(category, entry, source_id))
	return entries


func get_unread_count(category: String) -> int:
	if not _require_category(category):
		return 0
	if category == CATEGORY_CALL_LOG:
		_synchronize_call_log_from_phone(true)
	var entries: Array[Dictionary] = get_entries(category)
	var unread_count: int = 0
	for entry: Dictionary in entries:
		if not bool(entry["read"]):
			unread_count += 1
	return unread_count


## 只有已解锁或已生成的来源可以被阅读；重复打开不会重复发出 source_read。
func mark_entry_read(category: String, source_id: String) -> Dictionary:
	if not _require_category(category):
		return _last_error_snapshot()
	if not _is_valid_stable_id(source_id):
		return _make_error("invalid_source_id", "来源 ID 必须是非空英文 snake_case 稳定 ID。", category, source_id)
	if category == CATEGORY_CALL_LOG:
		var call_sync: Dictionary = _synchronize_call_log_from_phone(true)
		if not bool(call_sync.get("ok", false)):
			return call_sync
	if not _is_source_present(category, source_id):
		return _make_error("unknown_source_id", "找不到指定的信息来源，不能标记为已读。", category, source_id)
	if not _is_source_currently_unlocked(category, source_id):
		return _make_error("source_not_unlocked", "信息来源尚未解锁，不能标记为已读。", category, source_id)

	var entry: Dictionary = _get_internal_source_entry(category, source_id)
	var statement_ids: Array[String] = _statement_ids_for_entry(entry)
	var read_ids: Dictionary = _read_source_ids_by_category[category] as Dictionary
	var newly_read: bool = not read_ids.has(source_id)
	if newly_read:
		read_ids[source_id] = true
	var snapshot: Dictionary = _make_entry_snapshot(category, entry, source_id)
	if newly_read:
		var signal_statement_ids: Array[String] = _copy_string_array(statement_ids)
		source_read.emit(category, source_id, signal_statement_ids)
		entries_changed.emit(category)
	_last_error = {}
	return _make_success({
		"newly_read": newly_read,
		"source_id": source_id,
		"statement_ids": _copy_string_array(statement_ids),
		"entry": snapshot,
	})


func is_source_unlocked(category: String, source_id: String) -> bool:
	if not _require_category(category):
		return false
	if not _is_valid_stable_id(source_id):
		_make_error("invalid_source_id", "来源 ID 必须是非空英文 snake_case 稳定 ID。", category, source_id)
		return false
	if category == CATEGORY_CALL_LOG:
		_synchronize_call_log_from_phone(true)
	if not _is_source_present(category, source_id):
		_make_error("unknown_source_id", "找不到指定的信息来源。", category, source_id)
		return false
	_last_error = {}
	return _is_source_currently_unlocked(category, source_id)


func is_source_read(category: String, source_id: String) -> bool:
	if not _require_category(category):
		return false
	if not _is_valid_stable_id(source_id):
		_make_error("invalid_source_id", "来源 ID 必须是非空英文 snake_case 稳定 ID。", category, source_id)
		return false
	if category == CATEGORY_CALL_LOG:
		_synchronize_call_log_from_phone(true)
	if not _is_source_present(category, source_id):
		_make_error("unknown_source_id", "找不到指定的信息来源。", category, source_id)
		return false
	var read_ids: Dictionary = _read_source_ids_by_category[category] as Dictionary
	_last_error = {}
	return read_ids.has(source_id)


func get_last_error() -> Dictionary:
	return _last_error_snapshot()


## 电脑快照只保存动态可见性和已读状态；来电逐字内容/原始记录仍只由 PhoneSystem 持有。
## call_record_event_ids 是对 PhoneSystem 真实记录的严格关联，而不是另一份记录副本。
func create_snapshot() -> Dictionary:
	if _phone_system != null:
		_synchronize_call_log_from_phone(false)
	var unlocked_source_ids: Dictionary = {}
	var read_source_ids: Dictionary = {}
	for category: String in STATIC_CATEGORIES:
		unlocked_source_ids[category] = _sorted_dictionary_keys(_unlocked_source_ids_by_category[category] as Dictionary)
		read_source_ids[category] = _sorted_dictionary_keys(_read_source_ids_by_category[category] as Dictionary)
	read_source_ids[CATEGORY_CALL_LOG] = _sorted_dictionary_keys(_read_source_ids_by_category[CATEGORY_CALL_LOG] as Dictionary)
	var call_record_event_ids: Array[String] = _call_record_order.duplicate()
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"current_minute": _current_minute,
		"unlocked_source_ids": unlocked_source_ids,
		"read_source_ids": read_source_ids,
		"call_record_event_ids": call_record_event_ids,
	}
	snapshot.make_read_only()
	return snapshot


## 必须在内容已配置后校验。静态条目的解锁集合由存档分钟和内容定义共同决定，
## 因而缺一条或多一条都会被拒绝，避免静默地把时间线补成“看起来合理”。
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _is_content_configured:
		return _make_error("snapshot_content_not_configured", "电脑内容尚未配置，不能校验存档。")
	var envelope: Dictionary = _validate_snapshot_envelope(snapshot)
	if not bool(envelope.get("ok", false)):
		return envelope
	var minute_result: Dictionary = _read_snapshot_integer(snapshot["current_minute"], "current_minute", -1)
	if not bool(minute_result.get("ok", false)):
		return _make_error("invalid_snapshot_minute", "电脑存档的 current_minute 必须是不小于 -1 的整数。")
	var snapshot_minute: int = int(minute_result["value"])
	var unlocked_value: Variant = snapshot["unlocked_source_ids"]
	var read_value: Variant = snapshot["read_source_ids"]
	if not unlocked_value is Dictionary or not read_value is Dictionary:
		return _make_error("invalid_snapshot_source_state", "电脑存档的来源状态必须是对象。")
	var unlocked_raw: Dictionary = unlocked_value as Dictionary
	var read_raw: Dictionary = read_value as Dictionary
	var normalized_unlocked: Dictionary = {}
	var normalized_read: Dictionary = {}
	for category: String in STATIC_CATEGORIES:
		var unlocked_result: Dictionary = _validate_static_snapshot_category(
			category,
			unlocked_raw,
			snapshot_minute,
			false
		)
		if not bool(unlocked_result.get("ok", false)):
			return unlocked_result
		var read_result: Dictionary = _validate_static_snapshot_category(
			category,
			read_raw,
			snapshot_minute,
			true
		)
		if not bool(read_result.get("ok", false)):
			return read_result
		var unlocked_ids: Array[String] = unlocked_result["ids"] as Array[String]
		var read_ids: Array[String] = read_result["ids"] as Array[String]
		for source_id: String in read_ids:
			if not unlocked_ids.has(source_id):
				return _make_error("snapshot_read_not_unlocked", "电脑存档的已读条目必须已解锁。", category, source_id)
		normalized_unlocked[category] = unlocked_ids
		normalized_read[category] = read_ids

	if unlocked_raw.size() != STATIC_CATEGORIES.size():
		return _make_error("snapshot_unexpected_category", "电脑存档 unlocked_source_ids 只能包含静态信息分类。")
	if read_raw.size() != ALL_CATEGORIES.size() or not read_raw.has(CATEGORY_CALL_LOG):
		return _make_error("snapshot_unexpected_category", "电脑存档 read_source_ids 必须且只能包含四个电脑页签。")
	var phone_records_result: Dictionary = _resolve_snapshot_phone_records(context)
	if not bool(phone_records_result.get("ok", false)):
		return phone_records_result
	var call_ids_result: Dictionary = _validate_call_record_event_ids(snapshot["call_record_event_ids"])
	if not bool(call_ids_result.get("ok", false)):
		return call_ids_result
	var call_record_event_ids: Array[String] = call_ids_result["ids"] as Array[String]
	var phone_record_ids: Array[String] = phone_records_result["event_ids"] as Array[String]
	if call_record_event_ids != phone_record_ids:
		return _make_error("snapshot_call_record_mismatch", "电脑存档引用的来电记录与 PhoneSystem 真实记录不一致。", CATEGORY_CALL_LOG)
	var call_read_result: Dictionary = _validate_call_log_read_ids(read_raw[CATEGORY_CALL_LOG], call_record_event_ids)
	if not bool(call_read_result.get("ok", false)):
		return call_read_result
	normalized_read[CATEGORY_CALL_LOG] = call_read_result["ids"]
	return _make_success({
		"normalized": {
			"current_minute": snapshot_minute,
			"unlocked_source_ids": normalized_unlocked,
			"read_source_ids": normalized_read,
			"call_record_event_ids": call_record_event_ids,
			"call_records": phone_records_result["records"],
			"phone_system": phone_records_result.get("phone_system", null),
		},
	})


## 恢复前完整校验，随后一次性替换本系统动态集合。不会补发 source_unlocked、
## source_read 或 entries_changed；上层在所有系统完成恢复后统一刷新可见 UI。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	var next_unlocked: Dictionary = {}
	var next_read: Dictionary = {}
	for category: String in STATIC_CATEGORIES:
		next_unlocked[category] = _string_array_to_lookup(normalized["unlocked_source_ids"][category] as Array[String])
		next_read[category] = _string_array_to_lookup(normalized["read_source_ids"][category] as Array[String])
	next_unlocked[CATEGORY_CALL_LOG] = _string_array_to_lookup(normalized["call_record_event_ids"] as Array[String])
	next_read[CATEGORY_CALL_LOG] = _string_array_to_lookup(normalized["read_source_ids"][CATEGORY_CALL_LOG] as Array[String])
	var next_call_records_by_id: Dictionary = {}
	var next_call_order: Array[String] = []
	for record: Dictionary in normalized["call_records"] as Array[Dictionary]:
		var event_id: String = String(record["event_id"])
		next_call_records_by_id[event_id] = record.duplicate(true)
		next_call_order.append(event_id)
	var target_phone: RefCounted = normalized.get("phone_system", null) as RefCounted

	# 正常恢复路径在 StoryEngine.set_phone_system() 中已绑定。若单独使用
	# ComputerSystem，则仅在所有输入校验成功后无信号绑定，避免无效存档污染现状。
	if target_phone != null and target_phone != _phone_system:
		var bind_result: Dictionary = _bind_phone_system_silently(target_phone)
		if not bool(bind_result.get("ok", false)):
			return bind_result
	_current_minute = int(normalized["current_minute"])
	_unlocked_source_ids_by_category = next_unlocked
	_read_source_ids_by_category = next_read
	_call_records_by_source_id = next_call_records_by_id
	_call_record_order = next_call_order
	_last_error = {}
	return _make_success()


func _validate_snapshot_envelope(snapshot: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = [
		"snapshot_version",
		"system_id",
		"current_minute",
		"unlocked_source_ids",
		"read_source_ids",
		"call_record_event_ids",
	]
	if snapshot.size() != required_fields.size():
		return _make_error("snapshot_fields_invalid", "电脑存档字段缺失或包含未知字段。")
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return _make_error("snapshot_missing_field", "电脑存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_snapshot_integer(snapshot["snapshot_version"], "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result.get("ok", false)):
		return _make_error("snapshot_version_unsupported", "电脑存档版本不受支持。")
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SYSTEM_ID:
		return _make_error("snapshot_system_id_mismatch", "电脑存档所属系统不匹配。")
	return _make_success()


func _validate_static_snapshot_category(category: String, raw_state: Dictionary, snapshot_minute: int, is_read: bool) -> Dictionary:
	if not raw_state.has(category) or not raw_state[category] is Array:
		return _make_error("snapshot_missing_category", "电脑存档缺少分类：%s。" % category, category)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	var allowed_by_id: Dictionary = {}
	var expected_unlocked: Dictionary = {}
	for entry: Dictionary in _content_entries_by_category[category] as Array[Dictionary]:
		var source_id: String = String(entry["id"])
		allowed_by_id[source_id] = true
		if int(entry["unlock_minute"]) <= snapshot_minute:
			expected_unlocked[source_id] = true
	for raw_id: Variant in raw_state[category] as Array:
		if not raw_id is String or not allowed_by_id.has(String(raw_id)):
			return _make_error("snapshot_unknown_source_id", "电脑存档引用了不存在或错误分类的信息来源。", category, String(raw_id))
		var source_id: String = String(raw_id)
		if seen.has(source_id):
			return _make_error("snapshot_duplicate_source_id", "电脑存档不能包含重复来源 ID。", category, source_id)
		seen[source_id] = true
		ids.append(source_id)
	if not is_read and seen != expected_unlocked:
		return _make_error("snapshot_unlocked_time_mismatch", "电脑存档已解锁条目与保存分钟的内容定义不一致。", category)
	ids.sort()
	return _make_success({"ids": ids})


func _resolve_snapshot_phone_records(context: Dictionary) -> Dictionary:
	var phone_system: RefCounted = null
	if context.has("phone_system"):
		var provided_phone: Variant = context["phone_system"]
		if provided_phone is RefCounted:
			phone_system = provided_phone as RefCounted
		else:
			return _make_error("invalid_snapshot_phone_system", "电脑存档恢复上下文的 phone_system 无效。", CATEGORY_CALL_LOG)
	elif _phone_system != null:
		phone_system = _phone_system
	if phone_system != null:
		if not phone_system.has_method(&"get_call_records"):
			return _make_error("invalid_snapshot_phone_system", "PhoneSystem 缺少 get_call_records()。", CATEGORY_CALL_LOG)
		var records_value: Variant = phone_system.call(&"get_call_records")
		if not records_value is Array:
			return _make_error("invalid_phone_records", "PhoneSystem 返回的来电记录必须是数组。", CATEGORY_CALL_LOG)
		var validation: Dictionary = _validate_call_records(records_value as Array)
		if not bool(validation.get("ok", false)):
			return validation
		var event_ids: Array[String] = []
		for record: Dictionary in validation["records"] as Array[Dictionary]:
			event_ids.append(String(record["event_id"]))
		return _make_success({"records": validation["records"], "event_ids": event_ids, "phone_system": phone_system})

	# 单元测试或已绑定对象的离线恢复可只提供真实记录 ID，但不能用它凭空构造记录。
	if not context.has("call_record_event_ids") or not context["call_record_event_ids"] is Array:
		return _make_error("snapshot_phone_context_missing", "电脑存档恢复需要 PhoneSystem 或真实来电记录 ID 上下文。", CATEGORY_CALL_LOG)
	var ids_result: Dictionary = _validate_call_record_event_ids(context["call_record_event_ids"])
	if not bool(ids_result.get("ok", false)):
		return ids_result
	var records: Array[Dictionary] = []
	for event_id: String in ids_result["ids"] as Array[String]:
		if not _call_records_by_source_id.has(event_id):
			return _make_error("snapshot_call_record_missing", "当前电脑没有可验证的真实来电记录。", CATEGORY_CALL_LOG, event_id)
		records.append((_call_records_by_source_id[event_id] as Dictionary).duplicate(true))
	return _make_success({"records": records, "event_ids": ids_result["ids"]})


func _validate_call_record_event_ids(value: Variant) -> Dictionary:
	if not value is Array:
		return _make_error("invalid_snapshot_call_records", "电脑存档的 call_record_event_ids 必须是数组。", CATEGORY_CALL_LOG)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not _is_valid_stable_id(String(raw_id)):
			return _make_error("invalid_snapshot_call_record_id", "电脑存档的来电记录 ID 无效。", CATEGORY_CALL_LOG, String(raw_id))
		var event_id: String = String(raw_id)
		if seen.has(event_id):
			return _make_error("snapshot_duplicate_call_record", "电脑存档不能包含重复来电记录 ID。", CATEGORY_CALL_LOG, event_id)
		seen[event_id] = true
		ids.append(event_id)
	return _make_success({"ids": ids})


func _validate_call_log_read_ids(value: Variant, call_record_event_ids: Array[String]) -> Dictionary:
	if not value is Array:
		return _make_error("invalid_snapshot_call_log_read", "电脑存档的来电已读状态必须是数组。", CATEGORY_CALL_LOG)
	var valid_ids: Dictionary = _string_array_to_lookup(call_record_event_ids)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not valid_ids.has(String(raw_id)):
			return _make_error("snapshot_read_not_unlocked", "电脑存档的来电已读记录必须对应真实来电。", CATEGORY_CALL_LOG, String(raw_id))
		var event_id: String = String(raw_id)
		if seen.has(event_id):
			return _make_error("snapshot_duplicate_source_id", "电脑存档不能包含重复来电已读 ID。", CATEGORY_CALL_LOG, event_id)
		seen[event_id] = true
		ids.append(event_id)
	ids.sort()
	return _make_success({"ids": ids})


func _bind_phone_system_silently(phone_system: RefCounted) -> Dictionary:
	if phone_system == null or not phone_system.has_method(&"get_call_records") or not phone_system.has_signal(&"call_record_created"):
		return _make_error("invalid_phone_system", "电话系统缺少恢复电脑记录所需接口。", CATEGORY_CALL_LOG)
	_disconnect_phone_system()
	_phone_system = phone_system
	var callback: Callable = Callable(self, "_on_phone_call_record_created")
	var connect_error: Error = _phone_system.connect(&"call_record_created", callback)
	if connect_error != OK:
		_phone_system = null
		return _make_error("phone_signal_connect_failed", "无法订阅恢复后的电话记录信号。", CATEGORY_CALL_LOG)
	return _make_success()


func _string_array_to_lookup(ids: Array[String]) -> Dictionary:
	var lookup: Dictionary = {}
	for source_id: String in ids:
		lookup[source_id] = true
	return lookup


func _sorted_dictionary_keys(source: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id: Variant in source.keys():
		ids.append(String(raw_id))
	ids.sort()
	return ids


## JSON 读取会把数字变为 float；只接收可精确表示的整数，禁止把分数分钟截断。
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


func _validate_content_entries(category: String, raw_entries: Array, seen_source_ids: Dictionary) -> Dictionary:
	var normalized_entries: Array[Dictionary] = []
	for raw_entry: Variant in raw_entries:
		if not raw_entry is Dictionary:
			return _make_error("invalid_entry_type", "电脑内容条目必须是对象。", category)
		var entry: Dictionary = raw_entry as Dictionary
		if not entry.has("id"):
			return _make_error("missing_source_id", "电脑内容条目缺少必填字段 id。", category)
		var source_value: Variant = entry["id"]
		if not source_value is String:
			return _make_error("invalid_source_id", "电脑内容条目的 id 必须是字符串。", category)
		var source_id: String = source_value
		if not _is_valid_stable_id(source_id):
			return _make_error("invalid_source_id", "电脑内容条目的 id 必须是非空英文 snake_case 稳定 ID。", category, source_id)
		if seen_source_ids.has(source_id):
			return _make_error("duplicate_source_id", "电脑内容条目的 id 不能重复。", category, source_id)
		if not entry.has("unlock_minute"):
			return _make_error("missing_unlock_minute", "电脑内容条目缺少必填字段 unlock_minute。", category, source_id)
		var unlock_value: Variant = entry["unlock_minute"]
		if not unlock_value is int:
			return _make_error("invalid_unlock_minute", "电脑内容条目的 unlock_minute 必须是整数。", category, source_id)
		var unlock_minute: int = unlock_value
		if unlock_minute < 0:
			return _make_error("invalid_unlock_minute", "电脑内容条目的 unlock_minute 不能为负数。", category, source_id)

		var normalized_entry: Dictionary = entry.duplicate(true)
		for field_name: String in ["statement_ids", "fact_ids"]:
			var id_validation: Dictionary = _validate_optional_identifier_array(entry, field_name, category, source_id)
			if not bool(id_validation.get("ok", false)):
				return id_validation
			normalized_entry[field_name] = id_validation["values"]
		normalized_entry["id"] = source_id
		normalized_entry["unlock_minute"] = unlock_minute
		normalized_entries.append(normalized_entry)
		seen_source_ids[source_id] = true

	normalized_entries.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		var first_minute: int = int(first["unlock_minute"])
		var second_minute: int = int(second["unlock_minute"])
		if first_minute == second_minute:
			return String(first["id"]) < String(second["id"])
		return first_minute < second_minute
	)
	return {"ok": true, "entries": normalized_entries}


func _validate_optional_identifier_array(entry: Dictionary, field_name: String, category: String, source_id: String) -> Dictionary:
	if not entry.has(field_name):
		return {"ok": true, "values": []}
	var raw_values: Variant = entry[field_name]
	if not raw_values is Array:
		return _make_error(
			"invalid_%s" % field_name,
			"电脑内容条目的 %s 必须是字符串数组。" % field_name,
			category,
			source_id
		)
	var values: Array[String] = []
	var seen_ids: Dictionary = {}
	for raw_value: Variant in raw_values as Array:
		if not raw_value is String or not _is_valid_stable_id(raw_value as String):
			return _make_error(
				"invalid_%s" % field_name,
				"电脑内容条目的 %s 只能包含英文 snake_case 稳定 ID。" % field_name,
				category,
				source_id
			)
		var value: String = raw_value
		if seen_ids.has(value):
			return _make_error(
				"duplicate_%s" % field_name,
				"电脑内容条目的 %s 不能包含重复 ID。" % field_name,
				category,
				source_id
			)
		seen_ids[value] = true
		values.append(value)
	return {"ok": true, "values": values}


func _validate_call_records(raw_records: Array) -> Dictionary:
	var normalized_records: Array[Dictionary] = []
	var seen_source_ids: Dictionary = {}
	for raw_record: Variant in raw_records:
		if not raw_record is Dictionary:
			return _make_error("invalid_call_record", "电话系统中的来电记录必须是对象。", CATEGORY_CALL_LOG)
		var record: Dictionary = raw_record as Dictionary
		for field_name: String in ["event_id", "caller_name", "caller_number", "outcome", "time", "duration_ticks"]:
			if not record.has(field_name):
				return _make_error(
					"invalid_call_record",
					"电话系统来电记录缺少必填字段 %s。" % field_name,
					CATEGORY_CALL_LOG
				)
		var event_value: Variant = record["event_id"]
		if not event_value is String or not _is_valid_stable_id(event_value as String):
			return _make_error("invalid_call_record", "电话系统来电记录的 event_id 无效。", CATEGORY_CALL_LOG)
		var event_id: String = event_value
		if seen_source_ids.has(event_id):
			return _make_error("duplicate_call_record", "电话系统返回了重复 event_id 的来电记录。", CATEGORY_CALL_LOG, event_id)
		if not record["caller_name"] is String or String(record["caller_name"]).strip_edges().is_empty():
			return _make_error("invalid_call_record", "电话系统来电记录的 caller_name 必须是非空字符串。", CATEGORY_CALL_LOG, event_id)
		if not record["caller_number"] is String or String(record["caller_number"]).strip_edges().is_empty():
			return _make_error("invalid_call_record", "电话系统来电记录的 caller_number 必须是非空字符串。", CATEGORY_CALL_LOG, event_id)
		if not record["outcome"] is String or String(record["outcome"]).strip_edges().is_empty():
			return _make_error("invalid_call_record", "电话系统来电记录的 outcome 必须是非空字符串。", CATEGORY_CALL_LOG, event_id)
		if not record["time"] is int or int(record["time"]) < 0:
			return _make_error("invalid_call_record", "电话系统来电记录的 time 必须是非负整数。", CATEGORY_CALL_LOG, event_id)
		if not record["duration_ticks"] is int or int(record["duration_ticks"]) < 0:
			return _make_error("invalid_call_record", "电话系统来电记录的 duration_ticks 必须是非负整数。", CATEGORY_CALL_LOG, event_id)
		var normalized: Dictionary = record.duplicate(true)
		normalized["event_id"] = event_id
		normalized_records.append(normalized)
		seen_source_ids[event_id] = true
	return {"ok": true, "records": normalized_records}


func _synchronize_call_log_from_phone(emit_events: bool) -> Dictionary:
	if _phone_system == null:
		return _make_success({"synchronized_records": 0})
	var records_value: Variant = _phone_system.call(&"get_call_records")
	if not records_value is Array:
		return _make_error("invalid_phone_records", "电话系统返回的来电记录必须是数组。", CATEGORY_CALL_LOG)
	var validation: Dictionary = _validate_call_records(records_value as Array)
	if not bool(validation.get("ok", false)):
		return validation
	return _store_call_records(validation["records"] as Array[Dictionary], emit_events)


func _store_call_records(records: Array[Dictionary], emit_events: bool) -> Dictionary:
	var newly_created: Array[Dictionary] = []
	for record: Dictionary in records:
		var source_id: String = String(record["event_id"])
		if _call_records_by_source_id.has(source_id):
			var stored_record: Dictionary = _call_records_by_source_id[source_id] as Dictionary
			if stored_record != record:
				return _make_error(
					"call_record_conflict",
					"同一来电记录 ID 的内容发生变化，拒绝覆盖电话原始记录。",
					CATEGORY_CALL_LOG,
					source_id
				)
			continue
		_call_records_by_source_id[source_id] = record.duplicate(true)
		_call_record_order.append(source_id)
		var unlocked_ids: Dictionary = _unlocked_source_ids_by_category[CATEGORY_CALL_LOG] as Dictionary
		unlocked_ids[source_id] = true
		newly_created.append(_make_entry_snapshot(CATEGORY_CALL_LOG, record, source_id))

	if emit_events and not newly_created.is_empty():
		for snapshot: Dictionary in newly_created:
			_source_unlocked_snapshot(CATEGORY_CALL_LOG, snapshot)
		entries_changed.emit(CATEGORY_CALL_LOG)
	_last_error = {}
	return _make_success({"synchronized_records": newly_created.size(), "new_entries": newly_created})


func _on_phone_call_record_created(record: Dictionary) -> void:
	var validation: Dictionary = _validate_call_records([record])
	if not bool(validation.get("ok", false)):
		return
	_store_call_records(validation["records"] as Array[Dictionary], true)


func _get_call_log_snapshots() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for source_id: String in _call_record_order:
		var record: Dictionary = _call_records_by_source_id[source_id] as Dictionary
		entries.append(_make_entry_snapshot(CATEGORY_CALL_LOG, record, source_id))
	return entries


func _get_internal_source_entry(category: String, source_id: String) -> Dictionary:
	if category == CATEGORY_CALL_LOG:
		return _call_records_by_source_id[source_id] as Dictionary
	var category_entries: Array[Dictionary] = _content_entries_by_category[category] as Array[Dictionary]
	for entry: Dictionary in category_entries:
		if String(entry["id"]) == source_id:
			return entry
	return {}


func _is_source_present(category: String, source_id: String) -> bool:
	if category == CATEGORY_CALL_LOG:
		return _call_records_by_source_id.has(source_id)
	if not _is_content_configured:
		return false
	var category_entries: Array[Dictionary] = _content_entries_by_category[category] as Array[Dictionary]
	for entry: Dictionary in category_entries:
		if String(entry["id"]) == source_id:
			return true
	return false


func _is_source_currently_unlocked(category: String, source_id: String) -> bool:
	var unlocked_ids: Dictionary = _unlocked_source_ids_by_category[category] as Dictionary
	return unlocked_ids.has(source_id)


func _make_entry_snapshot(category: String, source_entry: Dictionary, source_id: String) -> Dictionary:
	var snapshot: Dictionary = source_entry.duplicate(true)
	# 静态内容本来就有 id；PhoneSystem 原始记录以 event_id 为键。为让四类
	# 信息页都能用同一条目选择契约，来电装饰快照额外暴露同值 id，不改写
	# event_id/outcome/time，也不补造通话正文。
	if category == CATEGORY_CALL_LOG:
		snapshot["id"] = source_id
	snapshot["source_id"] = source_id
	snapshot["category"] = category
	snapshot["source_type"] = category
	snapshot["unlocked"] = _is_source_currently_unlocked(category, source_id)
	var read_ids: Dictionary = _read_source_ids_by_category[category] as Dictionary
	snapshot["read"] = read_ids.has(source_id)
	if not snapshot.has("statement_ids"):
		snapshot["statement_ids"] = []
	if not snapshot.has("fact_ids"):
		snapshot["fact_ids"] = []
	snapshot.make_read_only()
	return snapshot


func _statement_ids_for_entry(entry: Dictionary) -> Array[String]:
	if not entry.has("statement_ids") or not entry["statement_ids"] is Array:
		return []
	var statement_ids: Array[String] = []
	for raw_id: Variant in entry["statement_ids"] as Array:
		if raw_id is String:
			statement_ids.append(raw_id)
	return statement_ids


func _source_unlocked_snapshot(category: String, entry: Dictionary) -> void:
	var signal_snapshot: Dictionary = entry.duplicate(true)
	signal_snapshot.make_read_only()
	source_unlocked.emit(category, signal_snapshot)


func _disconnect_phone_system() -> void:
	if _phone_system == null:
		return
	var callback: Callable = Callable(self, "_on_phone_call_record_created")
	if _phone_system.is_connected(&"call_record_created", callback):
		_phone_system.disconnect(&"call_record_created", callback)


func _require_category(category: String) -> bool:
	if ALL_CATEGORIES.has(category):
		return true
	_make_error("unknown_category", "未知的电脑信息分类。", category)
	return false


func _is_valid_stable_id(value: String) -> bool:
	return not value.is_empty() and not value.begins_with("_") and value.is_valid_identifier() and value == value.to_lower()


func _copy_string_array(values: Array[String]) -> Array[String]:
	var copy: Array[String] = []
	for value: String in values:
		copy.append(value)
	return copy


func _make_success(extra: Dictionary = {}) -> Dictionary:
	var result: Dictionary = {"ok": true}
	for key: Variant in extra:
		result[key] = extra[key]
	result.make_read_only()
	return result


func _make_error(error_code: String, message: String, category: String = "", source_id: String = "") -> Dictionary:
	var error: Dictionary = {
		"ok": false,
		"error_code": error_code,
		"message": message,
		"category": category,
		"source_id": source_id,
	}
	error.make_read_only()
	_last_error = error
	printerr("[电脑][%s][%s][%s] %s" % [category, source_id, error_code, message])
	return error


func _last_error_snapshot() -> Dictionary:
	if _last_error.is_empty():
		return {}
	var snapshot: Dictionary = _last_error.duplicate(true)
	snapshot.make_read_only()
	return snapshot
