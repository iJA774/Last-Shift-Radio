## incoming_call_events v1 的严格结构校验器。
##
## 校验通过后才返回深拷贝事件；任一条损坏即拒绝整个文档，调用方不得将
## 部分事件交给 StoryEngine。条件数据尚未在本阶段加载，因此这里只验证
## condition_ids 的稳定 ID 形状，不假设不存在的条件目录。
extends RefCounted
class_name ContentValidator

const CONTENT_FORMAT_VERSION: int = 1
const CONTENT_KIND: String = "incoming_call_events"
const TEST_NIGHT_CONTENT_KIND: String = "test_night_story"
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

const TEST_NIGHT_REQUIRED_FIELDS: PackedStringArray = [
	"content_format_version",
	"content_kind",
	"conditions",
	"events",
	"messages",
	"broadcasts",
	"dialogue_nodes",
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


## 第五阶段完整测试夜班的严格入口。
##
## 不把多个 JSON 文件在运行时松散拼接：来电、短信、广播、条件与对话树必须在
## 同一份文档内同时通过结构和交叉引用校验，任一项目损坏即拒绝开始新游戏。
func validate_test_night_story(document: Variant, source_path: String) -> Dictionary:
	if typeof(document) != TYPE_DICTIONARY:
		return _make_error(source_path, "", "$", "invalid_top_level_type", "内容顶层必须是 JSON 对象。")
	var root: Dictionary = document as Dictionary
	for field_name: String in TEST_NIGHT_REQUIRED_FIELDS:
		if not root.has(field_name):
			return _make_error(source_path, "", field_name, "missing_field", "测试剧情顶层缺少必填字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(root["content_format_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != CONTENT_FORMAT_VERSION:
		return _make_error(source_path, "", "content_format_version", "invalid_content_format_version", "content_format_version 必须精确为整数 1。")
	if typeof(root["content_kind"]) != TYPE_STRING or String(root["content_kind"]) != TEST_NIGHT_CONTENT_KIND:
		return _make_error(source_path, "", "content_kind", "invalid_content_kind", "content_kind 必须精确为 test_night_story。")
	for array_field: String in ["conditions", "events", "messages", "broadcasts", "dialogue_nodes"]:
		if typeof(root[array_field]) != TYPE_ARRAY:
			return _make_error(source_path, "", array_field, "invalid_array_field", "%s 必须是数组。" % array_field)

	var call_document: Dictionary = {
		"content_format_version": CONTENT_FORMAT_VERSION,
		"content_kind": CONTENT_KIND,
		"events": root["events"],
	}
	var call_result: Dictionary = validate_incoming_call_events(call_document, source_path)
	if not bool(call_result.get("ok", false)):
		return call_result
	var events: Array[Dictionary] = call_result["events"] as Array[Dictionary]
	var condition_result: Dictionary = _validate_test_conditions(root["conditions"] as Array, source_path)
	if not bool(condition_result.get("ok", false)):
		return condition_result
	var condition_ids: Dictionary = condition_result["ids"] as Dictionary
	var event_result: Dictionary = _validate_test_events(events, condition_ids, source_path)
	if not bool(event_result.get("ok", false)):
		return event_result
	var event_by_id: Dictionary = event_result["by_id"] as Dictionary
	var message_result: Dictionary = _validate_test_messages(root["messages"] as Array, source_path)
	if not bool(message_result.get("ok", false)):
		return message_result
	var message_by_id: Dictionary = message_result["by_id"] as Dictionary
	var broadcast_result: Dictionary = _validate_test_broadcasts(root["broadcasts"] as Array, condition_ids, source_path)
	if not bool(broadcast_result.get("ok", false)):
		return broadcast_result
	var broadcast_by_id: Dictionary = broadcast_result["by_id"] as Dictionary
	var reference_result: Dictionary = _validate_test_unlock_references(
		event_by_id,
		message_by_id,
		broadcast_by_id,
		condition_ids,
		source_path
	)
	if not bool(reference_result.get("ok", false)):
		return reference_result
	var dialogue_result: Dictionary = _validate_test_dialogue_nodes(
		root["dialogue_nodes"] as Array,
		event_by_id,
		source_path
	)
	if not bool(dialogue_result.get("ok", false)):
		return dialogue_result

	return {
		"ok": true,
		"source_path": source_path,
		"content_format_version": CONTENT_FORMAT_VERSION,
		"content_kind": TEST_NIGHT_CONTENT_KIND,
		"conditions": (condition_result["conditions"] as Array[Dictionary]).duplicate(true),
		"events": events.duplicate(true),
		"messages": (message_result["messages"] as Array[Dictionary]).duplicate(true),
		"broadcasts": (broadcast_result["broadcasts"] as Array[Dictionary]).duplicate(true),
		"dialogue_nodes": (dialogue_result["nodes"] as Array[Dictionary]).duplicate(true),
	}


func _validate_test_conditions(raw_conditions: Array, source_path: String) -> Dictionary:
	if raw_conditions.is_empty():
		return _make_error(source_path, "", "conditions", "empty_conditions", "测试剧情必须声明条件 ID。")
	var ids: Dictionary = {}
	var conditions: Array[Dictionary] = []
	for raw_condition: Variant in raw_conditions:
		if not raw_condition is Dictionary:
			return _make_error(source_path, "", "conditions", "invalid_condition_type", "conditions 中的每一项必须是对象。")
		var condition: Dictionary = raw_condition as Dictionary
		if not condition.has("id") or typeof(condition["id"]) != TYPE_STRING or not _is_stable_id(String(condition["id"])):
			return _make_error(source_path, "", "conditions.id", "invalid_condition_id", "条件 ID 必须是英文 snake_case 标识符。")
		var condition_id: String = String(condition["id"])
		if ids.has(condition_id):
			return _make_error(source_path, condition_id, "conditions.id", "duplicate_condition_id", "条件 ID 在同一内容文件中重复。")
		ids[condition_id] = true
		conditions.append(condition.duplicate(true))
	return {"ok": true, "ids": ids, "conditions": conditions}


func _validate_test_events(events: Array[Dictionary], condition_ids: Dictionary, source_path: String) -> Dictionary:
	if events.size() != 11:
		return _make_error(source_path, "", "events", "invalid_event_count", "测试剧情必须精确包含 11 通来电事件。")
	var by_id: Dictionary = {}
	for event_data: Dictionary in events:
		var event_id: String = String(event_data["id"])
		for field_name: String in ["dialogue_start_id", "unlocks_broadcast_ids"]:
			if not event_data.has(field_name):
				return _make_error(source_path, event_id, field_name, "missing_field", "事件缺少测试剧情字段：%s。" % field_name)
		if typeof(event_data["dialogue_start_id"]) != TYPE_STRING or not _is_stable_id(String(event_data["dialogue_start_id"])):
			return _make_error(source_path, event_id, "dialogue_start_id", "invalid_dialogue_start_id", "dialogue_start_id 必须是英文 snake_case ID。")
		if typeof(event_data["unlocks_broadcast_ids"]) != TYPE_ARRAY:
			return _make_error(source_path, event_id, "unlocks_broadcast_ids", "invalid_unlock_broadcast_ids", "unlocks_broadcast_ids 必须是数组。")
		for broadcast_id: Variant in event_data["unlocks_broadcast_ids"] as Array:
			if typeof(broadcast_id) != TYPE_STRING or not _is_stable_id(String(broadcast_id)):
				return _make_error(source_path, event_id, "unlocks_broadcast_ids", "invalid_broadcast_id", "事件解锁的广播 ID 必须是英文 snake_case ID。")
		for condition_id: Variant in event_data["condition_ids"] as Array:
			if not condition_ids.has(String(condition_id)):
				return _make_error(source_path, event_id, "condition_ids", "unknown_condition_id", "事件引用了未声明的条件 ID：%s。" % String(condition_id))
		by_id[event_id] = event_data.duplicate(true)
	return {"ok": true, "by_id": by_id}


func _validate_test_messages(raw_messages: Array, source_path: String) -> Dictionary:
	if raw_messages.is_empty():
		return _make_error(source_path, "", "messages", "empty_messages", "测试剧情必须提供短信内容。")
	var by_id: Dictionary = {}
	var messages: Array[Dictionary] = []
	for raw_message: Variant in raw_messages:
		if not raw_message is Dictionary:
			return _make_error(source_path, "", "messages", "invalid_message_type", "messages 中的每一项必须是对象。")
		var message: Dictionary = raw_message as Dictionary
		var provisional_id: String = _read_event_id_or_empty(message)
		for field_name: String in ["id", "sender", "body", "unlock_minute", "unlocks_broadcast_ids"]:
			if not message.has(field_name):
				return _make_error(source_path, provisional_id, field_name, "missing_field", "短信缺少必填字段：%s。" % field_name)
		if typeof(message["id"]) != TYPE_STRING or not _is_stable_id(String(message["id"])):
			return _make_error(source_path, provisional_id, "id", "invalid_message_id", "短信 ID 必须是英文 snake_case 标识符。")
		var message_id: String = String(message["id"])
		if by_id.has(message_id):
			return _make_error(source_path, message_id, "id", "duplicate_message_id", "短信 ID 在同一内容文件中重复。")
		for field_name: String in ["sender", "body"]:
			if typeof(message[field_name]) != TYPE_STRING or String(message[field_name]).strip_edges().is_empty():
				return _make_error(source_path, message_id, field_name, "invalid_message_text", "%s 必须是非空字符串。" % field_name)
		var minute_result: Dictionary = _read_exact_integer(message["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= SHIFT_DURATION_MINUTES:
			return _make_error(source_path, message_id, "unlock_minute", "invalid_unlock_minute", "短信解锁分钟必须是 0 至 59 的整数。")
		if typeof(message["unlocks_broadcast_ids"]) != TYPE_ARRAY:
			return _make_error(source_path, message_id, "unlocks_broadcast_ids", "invalid_unlock_broadcast_ids", "unlocks_broadcast_ids 必须是数组。")
		for broadcast_id: Variant in message["unlocks_broadcast_ids"] as Array:
			if typeof(broadcast_id) != TYPE_STRING or not _is_stable_id(String(broadcast_id)):
				return _make_error(source_path, message_id, "unlocks_broadcast_ids", "invalid_broadcast_id", "短信解锁的广播 ID 必须是英文 snake_case ID。")
		var normalized: Dictionary = message.duplicate(true)
		normalized["unlock_minute"] = int(minute_result["value"])
		by_id[message_id] = normalized
		messages.append(normalized)
	return {"ok": true, "by_id": by_id, "messages": messages}


func _validate_test_broadcasts(raw_broadcasts: Array, condition_ids: Dictionary, source_path: String) -> Dictionary:
	if raw_broadcasts.size() != 3:
		return _make_error(source_path, "", "broadcasts", "invalid_broadcast_count", "测试剧情必须精确包含 3 条预制广播稿。")
	var by_id: Dictionary = {}
	var broadcasts: Array[Dictionary] = []
	for raw_broadcast: Variant in raw_broadcasts:
		if not raw_broadcast is Dictionary:
			return _make_error(source_path, "", "broadcasts", "invalid_broadcast_type", "broadcasts 中的每一项必须是对象。")
		var broadcast: Dictionary = raw_broadcast as Dictionary
		var provisional_id: String = _read_event_id_or_empty(broadcast)
		for field_name: String in ["id", "source", "body", "unlock_message_ids", "unlock_event_ids", "sets_condition_id", "exclusive_group_id"]:
			if not broadcast.has(field_name):
				return _make_error(source_path, provisional_id, field_name, "missing_field", "广播稿缺少必填字段：%s。" % field_name)
		if typeof(broadcast["id"]) != TYPE_STRING or not _is_stable_id(String(broadcast["id"])):
			return _make_error(source_path, provisional_id, "id", "invalid_broadcast_id", "广播稿 ID 必须是英文 snake_case 标识符。")
		var broadcast_id: String = String(broadcast["id"])
		if by_id.has(broadcast_id):
			return _make_error(source_path, broadcast_id, "id", "duplicate_broadcast_id", "广播稿 ID 在同一内容文件中重复。")
		for field_name: String in ["source", "body"]:
			if typeof(broadcast[field_name]) != TYPE_STRING or String(broadcast[field_name]).strip_edges().is_empty():
				return _make_error(source_path, broadcast_id, field_name, "invalid_broadcast_text", "%s 必须是非空字符串。" % field_name)
		for field_name: String in ["unlock_message_ids", "unlock_event_ids"]:
			if typeof(broadcast[field_name]) != TYPE_ARRAY:
				return _make_error(source_path, broadcast_id, field_name, "invalid_unlock_source_ids", "%s 必须是数组。" % field_name)
			for source_id: Variant in broadcast[field_name] as Array:
				if typeof(source_id) != TYPE_STRING or not _is_stable_id(String(source_id)):
					return _make_error(source_path, broadcast_id, field_name, "invalid_unlock_source_id", "%s 中的 ID 必须是英文 snake_case。" % field_name)
		if (broadcast["unlock_message_ids"] as Array).is_empty() and (broadcast["unlock_event_ids"] as Array).is_empty():
			return _make_error(source_path, broadcast_id, "unlock_message_ids/unlock_event_ids", "missing_unlock_source", "每条广播稿必须有短信或来电解锁来源。")
		if typeof(broadcast["sets_condition_id"]) != TYPE_STRING:
			return _make_error(source_path, broadcast_id, "sets_condition_id", "invalid_sets_condition_id", "sets_condition_id 必须是字符串。")
		var condition_id: String = String(broadcast["sets_condition_id"])
		if not condition_id.is_empty() and (not _is_stable_id(condition_id) or not condition_ids.has(condition_id)):
			return _make_error(source_path, broadcast_id, "sets_condition_id", "unknown_condition_id", "广播稿引用了未声明的条件 ID。")
		if typeof(broadcast["exclusive_group_id"]) != TYPE_STRING:
			return _make_error(source_path, broadcast_id, "exclusive_group_id", "invalid_exclusive_group_id", "exclusive_group_id 必须是字符串。")
		var exclusive_group_id: String = String(broadcast["exclusive_group_id"])
		if not exclusive_group_id.is_empty() and not _is_stable_id(exclusive_group_id):
			return _make_error(source_path, broadcast_id, "exclusive_group_id", "invalid_exclusive_group_id", "exclusive_group_id 必须为空或英文 snake_case ID。")
		by_id[broadcast_id] = broadcast.duplicate(true)
		broadcasts.append(broadcast.duplicate(true))
	return {"ok": true, "by_id": by_id, "broadcasts": broadcasts}


func _validate_test_unlock_references(event_by_id: Dictionary, message_by_id: Dictionary, broadcast_by_id: Dictionary, _condition_ids: Dictionary, source_path: String) -> Dictionary:
	for event_id_variant: Variant in event_by_id.keys():
		var event_id: String = String(event_id_variant)
		var event_data: Dictionary = event_by_id[event_id] as Dictionary
		for broadcast_id_variant: Variant in event_data["unlocks_broadcast_ids"] as Array:
			var broadcast_id: String = String(broadcast_id_variant)
			if not broadcast_by_id.has(broadcast_id):
				return _make_error(source_path, event_id, "unlocks_broadcast_ids", "unknown_broadcast_id", "事件引用了不存在的广播稿：%s。" % broadcast_id)
			var draft: Dictionary = broadcast_by_id[broadcast_id] as Dictionary
			if not (draft["unlock_event_ids"] as Array).has(event_id):
				return _make_error(source_path, event_id, "unlocks_broadcast_ids", "unlock_reference_mismatch", "事件与广播稿的来电解锁引用必须双向一致。")
	for message_id_variant: Variant in message_by_id.keys():
		var message_id: String = String(message_id_variant)
		var message: Dictionary = message_by_id[message_id] as Dictionary
		for broadcast_id_variant: Variant in message["unlocks_broadcast_ids"] as Array:
			var broadcast_id: String = String(broadcast_id_variant)
			if not broadcast_by_id.has(broadcast_id):
				return _make_error(source_path, message_id, "unlocks_broadcast_ids", "unknown_broadcast_id", "短信引用了不存在的广播稿：%s。" % broadcast_id)
			var draft: Dictionary = broadcast_by_id[broadcast_id] as Dictionary
			if not (draft["unlock_message_ids"] as Array).has(message_id):
				return _make_error(source_path, message_id, "unlocks_broadcast_ids", "unlock_reference_mismatch", "短信与广播稿的短信解锁引用必须双向一致。")
	for broadcast_id_variant: Variant in broadcast_by_id.keys():
		var broadcast_id: String = String(broadcast_id_variant)
		var draft: Dictionary = broadcast_by_id[broadcast_id] as Dictionary
		for event_id_variant: Variant in draft["unlock_event_ids"] as Array:
			var event_id: String = String(event_id_variant)
			if not event_by_id.has(event_id):
				return _make_error(source_path, broadcast_id, "unlock_event_ids", "unknown_event_id", "广播稿引用了不存在的来电事件：%s。" % event_id)
			if not (event_by_id[event_id] as Dictionary)["unlocks_broadcast_ids"].has(broadcast_id):
				return _make_error(source_path, broadcast_id, "unlock_event_ids", "unlock_reference_mismatch", "广播稿与事件的来电解锁引用必须双向一致。")
		for message_id_variant: Variant in draft["unlock_message_ids"] as Array:
			var message_id: String = String(message_id_variant)
			if not message_by_id.has(message_id):
				return _make_error(source_path, broadcast_id, "unlock_message_ids", "unknown_message_id", "广播稿引用了不存在的短信：%s。" % message_id)
			if not (message_by_id[message_id] as Dictionary)["unlocks_broadcast_ids"].has(broadcast_id):
				return _make_error(source_path, broadcast_id, "unlock_message_ids", "unlock_reference_mismatch", "广播稿与短信的解锁引用必须双向一致。")
	return {"ok": true}


func _validate_test_dialogue_nodes(raw_nodes: Array, event_by_id: Dictionary, source_path: String) -> Dictionary:
	var node_by_id: Dictionary = {}
	var option_ids: Dictionary = {}
	var nodes: Array[Dictionary] = []
	for raw_node: Variant in raw_nodes:
		if not raw_node is Dictionary:
			return _make_error(source_path, "", "dialogue_nodes", "invalid_dialogue_node_type", "dialogue_nodes 中的每一项必须是对象。")
		var node: Dictionary = raw_node as Dictionary
		var provisional_id: String = _read_event_id_or_empty(node)
		for field_name: String in ["id", "event_id", "speaker", "text", "is_terminal", "options"]:
			if not node.has(field_name):
				return _make_error(source_path, provisional_id, field_name, "missing_field", "对话节点缺少必填字段：%s。" % field_name)
		if typeof(node["id"]) != TYPE_STRING or not _is_stable_id(String(node["id"])):
			return _make_error(source_path, provisional_id, "id", "invalid_dialogue_node_id", "对话节点 ID 必须是英文 snake_case 标识符。")
		var node_id: String = String(node["id"])
		if node_by_id.has(node_id):
			return _make_error(source_path, node_id, "id", "duplicate_dialogue_node_id", "对话节点 ID 在同一内容文件中重复。")
		if typeof(node["event_id"]) != TYPE_STRING or not event_by_id.has(String(node["event_id"])):
			return _make_error(source_path, node_id, "event_id", "unknown_event_id", "对话节点引用了不存在的来电事件。")
		for field_name: String in ["speaker", "text"]:
			if typeof(node[field_name]) != TYPE_STRING or String(node[field_name]).strip_edges().is_empty():
				return _make_error(source_path, node_id, field_name, "invalid_dialogue_text", "%s 必须是非空字符串。" % field_name)
		if typeof(node["is_terminal"]) != TYPE_BOOL or typeof(node["options"]) != TYPE_ARRAY:
			return _make_error(source_path, node_id, "is_terminal/options", "invalid_dialogue_shape", "is_terminal 必须是 bool，options 必须是数组。")
		var options: Array = node["options"] as Array
		if bool(node["is_terminal"]) and not options.is_empty():
			return _make_error(source_path, node_id, "options", "terminal_has_options", "终止对话节点不能再包含选项。")
		if not bool(node["is_terminal"]) and options.is_empty():
			return _make_error(source_path, node_id, "options", "nonterminal_missing_options", "非终止对话节点至少需要一个选项。")
		for raw_option: Variant in options:
			if not raw_option is Dictionary:
				return _make_error(source_path, node_id, "options", "invalid_dialogue_option_type", "对话选项必须是对象。")
			var option: Dictionary = raw_option as Dictionary
			for field_name: String in ["id", "text", "next_node_id"]:
				if not option.has(field_name):
					return _make_error(source_path, node_id, "options.%s" % field_name, "missing_field", "对话选项缺少必填字段：%s。" % field_name)
			if typeof(option["id"]) != TYPE_STRING or not _is_stable_id(String(option["id"])):
				return _make_error(source_path, node_id, "options.id", "invalid_dialogue_option_id", "对话选项 ID 必须是英文 snake_case 标识符。")
			var option_id: String = String(option["id"])
			if option_ids.has(option_id):
				return _make_error(source_path, node_id, "options.id", "duplicate_dialogue_option_id", "对话选项 ID 在同一内容文件中重复。")
			option_ids[option_id] = true
			if typeof(option["text"]) != TYPE_STRING or String(option["text"]).strip_edges().is_empty() or typeof(option["next_node_id"]) != TYPE_STRING or not _is_stable_id(String(option["next_node_id"])):
				return _make_error(source_path, node_id, "options", "invalid_dialogue_option", "对话选项正文和 next_node_id 必须有效。")
		node_by_id[node_id] = node.duplicate(true)
		nodes.append(node.duplicate(true))

	for event_id_variant: Variant in event_by_id.keys():
		var event_id: String = String(event_id_variant)
		var start_id: String = String((event_by_id[event_id] as Dictionary)["dialogue_start_id"])
		if not node_by_id.has(start_id):
			return _make_error(source_path, event_id, "dialogue_start_id", "unknown_dialogue_node_id", "来电引用了不存在的对话入口。")
		if String((node_by_id[start_id] as Dictionary)["event_id"]) != event_id:
			return _make_error(source_path, event_id, "dialogue_start_id", "dialogue_event_mismatch", "来电对话入口必须属于同一事件。")
	for node_id_variant: Variant in node_by_id.keys():
		var node_id: String = String(node_id_variant)
		var node: Dictionary = node_by_id[node_id] as Dictionary
		for option: Dictionary in node["options"] as Array:
			var next_node_id: String = String(option["next_node_id"])
			if not node_by_id.has(next_node_id):
				return _make_error(source_path, node_id, "options.next_node_id", "unknown_dialogue_node_id", "对话选项引用了不存在的后继节点。")
			if String((node_by_id[next_node_id] as Dictionary)["event_id"]) != String(node["event_id"]):
				return _make_error(source_path, node_id, "options.next_node_id", "cross_event_dialogue_link", "对话选项不能跳转到另一通来电。")
	var reachable: Dictionary = {}
	for event_id_variant: Variant in event_by_id.keys():
		var event_id: String = String(event_id_variant)
		var start_id: String = String((event_by_id[event_id] as Dictionary)["dialogue_start_id"])
		var visit_result: Dictionary = _visit_dialogue_node(start_id, node_by_id, reachable, {}, source_path)
		if not bool(visit_result.get("ok", false)):
			return visit_result
	for node_id_variant: Variant in node_by_id.keys():
		var node_id: String = String(node_id_variant)
		if not reachable.has(node_id):
			return _make_error(source_path, node_id, "dialogue_nodes", "unreachable_dialogue_node", "对话节点无法从任何来电入口到达。")
	var round_result: Dictionary = _validate_dialogue_round_counts(event_by_id, node_by_id, source_path)
	if not bool(round_result.get("ok", false)):
		return round_result
	return {"ok": true, "nodes": nodes}


func _visit_dialogue_node(node_id: String, node_by_id: Dictionary, reachable: Dictionary, visiting: Dictionary, source_path: String) -> Dictionary:
	if visiting.has(node_id):
		return _make_error(source_path, node_id, "options.next_node_id", "dialogue_cycle", "对话树不能包含循环，必须能在有限选择后结束。")
	if reachable.has(node_id):
		return {"ok": true}
	visiting[node_id] = true
	var node: Dictionary = node_by_id[node_id] as Dictionary
	for option: Dictionary in node["options"] as Array:
		var result: Dictionary = _visit_dialogue_node(String(option["next_node_id"]), node_by_id, reachable, visiting, source_path)
		if not bool(result.get("ok", false)):
			return result
	visiting.erase(node_id)
	reachable[node_id] = true
	return {"ok": true}


## 除用户明确指定唯一回应的 final Amy 外，每通测试电话都至少需要两轮
## 玩家选择、最多四轮；避免一按钮即结束，也避免将 MVP 变成冗长对话树。
func _validate_dialogue_round_counts(event_by_id: Dictionary, node_by_id: Dictionary, source_path: String) -> Dictionary:
	for event_id_variant: Variant in event_by_id.keys():
		var event_id: String = String(event_id_variant)
		var event_data: Dictionary = event_by_id[event_id] as Dictionary
		var depths: Array[int] = []
		_collect_dialogue_choice_depths(String(event_data["dialogue_start_id"]), node_by_id, 0, depths)
		if depths.is_empty():
			return _make_error(source_path, event_id, "dialogue_start_id", "dialogue_missing_terminal", "对话入口无法到达终止节点。")
		var minimum_rounds: int = 2
		var maximum_rounds: int = 4
		if event_id == "call_11_final_amy":
			minimum_rounds = 1
			maximum_rounds = 1
		for depth: int in depths:
			if depth < minimum_rounds or depth > maximum_rounds:
				return _make_error(
					source_path,
					event_id,
					"dialogue_nodes",
					"invalid_dialogue_round_count",
					"对话选择轮数必须在 %d 至 %d 之间，当前路径为 %d 轮。" % [minimum_rounds, maximum_rounds, depth]
				)
	return {"ok": true}


func _collect_dialogue_choice_depths(node_id: String, node_by_id: Dictionary, depth: int, depths: Array[int]) -> void:
	var node: Dictionary = node_by_id[node_id] as Dictionary
	if bool(node["is_terminal"]):
		depths.append(depth)
		return
	for option: Dictionary in node["options"] as Array:
		_collect_dialogue_choice_depths(String(option["next_node_id"]), node_by_id, depth + 1, depths)


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
