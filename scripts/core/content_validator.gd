## incoming_call_events v1 的严格结构校验器。
##
## 校验通过后才返回深拷贝事件；任一条损坏即拒绝整个文档，调用方不得将
## 部分事件交给 StoryEngine。条件数据尚未在本阶段加载，因此这里只验证
## condition_ids 的稳定 ID 形状，不假设不存在的条件目录。
extends RefCounted
class_name ContentValidator

const CONTENT_FORMAT_VERSION: int = 1
const CONTENT_KIND: String = "incoming_call_events"
const SHIFT_DURATION_MINUTES: int = 60

const SUPPORTED_EVENT_KINDS: PackedStringArray = ["incoming_call"]
const SUPPORTED_PRIORITIES: PackedStringArray = ["main", "normal"]
const SUPPORTED_BUSY_POLICIES: PackedStringArray = ["queue", "expire"]
const SUPPORTED_EXPIRY_POLICIES: PackedStringArray = ["mark_missed"]

const TOP_LEVEL_REQUIRED_FIELDS: PackedStringArray = [
	"content_format_version",
	"content_kind",
	"events",
]
const EVENT_REQUIRED_FIELDS: PackedStringArray = [
	"id",
	"kind",
	"priority",
	"window_start_minute",
	"window_end_minute",
	"when_busy",
	"on_expire",
	"condition_ids",
	"caller_display_name",
	"caller_number",
]


func validate_incoming_call_events(document: Variant, source_path: String) -> Dictionary:
	if typeof(document) != TYPE_DICTIONARY:
		return _make_error(
			source_path,
			"",
			"$",
			"invalid_top_level_type",
			"内容顶层必须是 JSON 对象。"
		)
	var root: Dictionary = document as Dictionary
	for field_name: String in TOP_LEVEL_REQUIRED_FIELDS:
		if not root.has(field_name):
			return _make_error(source_path, "", field_name, "missing_field", "内容顶层缺少必填字段：%s。" % field_name)

	var version_result: Dictionary = _read_exact_integer(root["content_format_version"])
	if not bool(version_result["ok"]) or int(version_result["value"]) != CONTENT_FORMAT_VERSION:
		return _make_error(
			source_path,
			"",
			"content_format_version",
			"invalid_content_format_version",
			"content_format_version 必须精确为整数 1。"
		)
	if typeof(root["content_kind"]) != TYPE_STRING or String(root["content_kind"]) != CONTENT_KIND:
		return _make_error(
			source_path,
			"",
			"content_kind",
			"invalid_content_kind",
			"content_kind 必须精确为 incoming_call_events。"
		)
	if typeof(root["events"]) != TYPE_ARRAY:
		return _make_error(source_path, "", "events", "invalid_events_type", "events 必须是数组。")

	var event_ids: Dictionary = {}
	var validated_events: Array[Dictionary] = []
	var raw_events: Array = root["events"] as Array
	for raw_event: Variant in raw_events:
		if typeof(raw_event) != TYPE_DICTIONARY:
			return _make_error(source_path, "", "events", "invalid_event_type", "events 中的每一项必须是对象。")
		var event_data: Dictionary = raw_event as Dictionary
		var validation: Dictionary = _validate_event(event_data, source_path, event_ids)
		if not bool(validation["ok"]):
			return validation
		var validated_event: Dictionary = validation["event"] as Dictionary
		var event_id: String = String(validated_event["id"])
		event_ids[event_id] = true
		validated_events.append(validated_event)

	return {
		"ok": true,
		"source_path": source_path,
		"events": validated_events,
	}


func _validate_event(event_data: Dictionary, source_path: String, event_ids: Dictionary) -> Dictionary:
	var provisional_event_id: String = _read_event_id_or_empty(event_data)
	for field_name: String in EVENT_REQUIRED_FIELDS:
		if not event_data.has(field_name):
			return _make_error(
				source_path,
				provisional_event_id,
				field_name,
				"missing_field",
				"事件缺少必填字段：%s。" % field_name
			)

	if typeof(event_data["id"]) != TYPE_STRING or not _is_stable_id(String(event_data["id"])):
		return _make_error(source_path, provisional_event_id, "id", "invalid_event_id", "事件 ID 必须是英文 snake_case 标识符。")
	var event_id: String = String(event_data["id"])
	if event_ids.has(event_id):
		return _make_error(source_path, event_id, "id", "duplicate_event_id", "事件 ID 在同一内容文件中重复。")

	if typeof(event_data["kind"]) != TYPE_STRING or not SUPPORTED_EVENT_KINDS.has(String(event_data["kind"])):
		return _make_error(source_path, event_id, "kind", "invalid_kind", "kind 必须是 incoming_call。")
	if typeof(event_data["priority"]) != TYPE_STRING or not SUPPORTED_PRIORITIES.has(String(event_data["priority"])):
		return _make_error(source_path, event_id, "priority", "invalid_priority", "priority 必须是 main 或 normal。")
	if typeof(event_data["when_busy"]) != TYPE_STRING or not SUPPORTED_BUSY_POLICIES.has(String(event_data["when_busy"])):
		return _make_error(source_path, event_id, "when_busy", "invalid_when_busy", "when_busy 必须是 queue 或 expire。")
	if typeof(event_data["on_expire"]) != TYPE_STRING or not SUPPORTED_EXPIRY_POLICIES.has(String(event_data["on_expire"])):
		return _make_error(source_path, event_id, "on_expire", "invalid_on_expire", "on_expire 必须是 mark_missed。")
	if String(event_data["priority"]) == "main" and String(event_data["when_busy"]) != "queue":
		return _make_error(source_path, event_id, "when_busy", "main_event_must_queue", "主线事件占线时必须使用 queue 策略。")

	var window_start_result: Dictionary = _read_exact_integer(event_data["window_start_minute"])
	if not bool(window_start_result["ok"]):
		return _make_error(source_path, event_id, "window_start_minute", "invalid_window_start", "window_start_minute 必须是数学上精确的整数分钟。")
	var window_end_result: Dictionary = _read_exact_integer(event_data["window_end_minute"])
	if not bool(window_end_result["ok"]):
		return _make_error(source_path, event_id, "window_end_minute", "invalid_window_end", "window_end_minute 必须是数学上精确的整数分钟。")
	var window_start: int = int(window_start_result["value"])
	var window_end: int = int(window_end_result["value"])
	if window_start < 0 or window_end < window_start or window_end >= SHIFT_DURATION_MINUTES:
		return _make_error(
			source_path,
			event_id,
			"window_start_minute/window_end_minute",
			"invalid_time_window",
			"事件时间窗必须满足 0 <= 开始 <= 结束 < 60。"
		)

	if typeof(event_data["condition_ids"]) != TYPE_ARRAY:
		return _make_error(source_path, event_id, "condition_ids", "invalid_condition_ids", "condition_ids 必须是数组。")
	var condition_ids: Array = event_data["condition_ids"] as Array
	for condition_id_variant: Variant in condition_ids:
		if typeof(condition_id_variant) != TYPE_STRING or not _is_stable_id(String(condition_id_variant)):
			return _make_error(
				source_path,
				event_id,
				"condition_ids",
				"invalid_condition_id",
				"condition_ids 中的每一项必须是英文 snake_case 字符串 ID。"
			)

	for caller_field: String in ["caller_display_name", "caller_number"]:
		if typeof(event_data[caller_field]) != TYPE_STRING:
			return _make_error(source_path, event_id, caller_field, "invalid_caller_field_type", "%s 必须是字符串。" % caller_field)
		if String(event_data[caller_field]).strip_edges().is_empty():
			return _make_error(source_path, event_id, caller_field, "empty_caller_field", "%s 不能是空白文本。" % caller_field)

	var normalized_event: Dictionary = event_data.duplicate(true)
	normalized_event["window_start_minute"] = window_start
	normalized_event["window_end_minute"] = window_end
	normalized_event["condition_ids"] = condition_ids.duplicate(true)
	return {"ok": true, "event": normalized_event}


func _read_event_id_or_empty(event_data: Dictionary) -> String:
	if event_data.has("id") and typeof(event_data["id"]) == TYPE_STRING:
		return String(event_data["id"])
	return ""


func _is_stable_id(candidate: String) -> bool:
	return (
		not candidate.is_empty()
		and not candidate.begins_with("_")
		and candidate == candidate.to_lower()
		and candidate.is_valid_identifier()
		and candidate.is_valid_ascii_identifier()
	)


## Godot 的 JSON 数字会依运行时以 int 或 float 形式给出。只有没有小数部分的
## 有限数值可进入运行时事件；成功后立即规范成 int，避免下游比较混用数字类型。
func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	if number < -9_223_372_036_854_775_808.0 or number > 9_223_372_036_854_775_807.0:
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _make_error(
	source_path: String,
	event_id: String,
	field_name: String,
	error_code: String,
	message: String
) -> Dictionary:
	return {
		"ok": false,
		"source_path": source_path,
		"event_id": event_id,
		"field": field_name,
		"error_code": error_code,
		"message": message,
	}
