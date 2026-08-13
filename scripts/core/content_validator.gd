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
const ENDING_ONLY_FACT_IDS: PackedStringArray = ["fact_unauthorized_broadcast", "fact_anomaly_cause_unknown"]
const NORTH_BRIDGE_TOPIC_ID: String = "north_bridge"
const REQUIRED_TEST_FACT_IDS: PackedStringArray = [
	"fact_bridge_accident_before_shift",
	"fact_bridge_closed",
	"fact_accounts_conflict",
	"fact_same_wagon_recurs",
	"fact_wagon_positions_conflict",
	"fact_bridge_traffic_after_closure",
	"fact_unauthorized_broadcast",
	"fact_anomaly_cause_unknown",
]

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
	"checklist_entries",
	"news_entries",
	"messages",
	"broadcast_tasks",
	"dialogue_nodes",
	"statements",
	"facts",
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
	for array_field: String in ["conditions", "events", "checklist_entries", "news_entries", "messages", "broadcast_tasks", "dialogue_nodes", "statements", "facts"]:
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
	var checklist_result: Dictionary = _validate_test_information_entries(root["checklist_entries"] as Array, "checklist_entries", false, source_path)
	if not bool(checklist_result.get("ok", false)):
		return checklist_result
	var news_result: Dictionary = _validate_test_information_entries(root["news_entries"] as Array, "news_entries", true, source_path)
	if not bool(news_result.get("ok", false)):
		return news_result
	var message_result: Dictionary = _validate_test_messages(root["messages"] as Array, source_path)
	if not bool(message_result.get("ok", false)):
		return message_result
	var message_by_id: Dictionary = message_result["by_id"] as Dictionary
	var source_ids_result: Dictionary = _combine_test_source_ids(event_by_id, checklist_result["by_id"] as Dictionary, news_result["by_id"] as Dictionary, message_by_id, source_path)
	if not bool(source_ids_result.get("ok", false)):
		return source_ids_result
	var statement_result: Dictionary = _validate_test_statements(root["statements"] as Array, source_ids_result["source_ids"] as Dictionary, source_path)
	if not bool(statement_result.get("ok", false)):
		return statement_result
	var fact_result: Dictionary = _validate_test_facts(root["facts"] as Array, statement_result["by_id"] as Dictionary, source_path)
	if not bool(fact_result.get("ok", false)):
		return fact_result
	var information_reference_result: Dictionary = _validate_test_information_references(
		[checklist_result["entries"], news_result["entries"], message_result["messages"]],
		statement_result["by_id"] as Dictionary,
		fact_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(information_reference_result.get("ok", false)):
		return information_reference_result
	var broadcast_task_result: Dictionary = _validate_test_broadcast_tasks(
		root["broadcast_tasks"] as Array,
		event_by_id,
		statement_result["by_id"] as Dictionary,
		condition_ids,
		fact_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(broadcast_task_result.get("ok", false)):
		return broadcast_task_result
	var dialogue_result: Dictionary = _validate_test_dialogue_nodes(
		root["dialogue_nodes"] as Array,
		event_by_id,
		statement_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(dialogue_result.get("ok", false)):
		return dialogue_result
	var statement_coverage_result: Dictionary = _validate_statement_reveal_coverage(
		[checklist_result["entries"], news_result["entries"], message_result["messages"]],
		dialogue_result["nodes"] as Array[Dictionary],
		statement_result["by_id"] as Dictionary,
		source_path
	)
	if not bool(statement_coverage_result.get("ok", false)):
		return statement_coverage_result

	return {
		"ok": true,
		"source_path": source_path,
		"content_format_version": CONTENT_FORMAT_VERSION,
		"content_kind": TEST_NIGHT_CONTENT_KIND,
		"conditions": (condition_result["conditions"] as Array[Dictionary]).duplicate(true),
		"events": events.duplicate(true),
		"checklist_entries": (checklist_result["entries"] as Array[Dictionary]).duplicate(true),
		"news_entries": (news_result["entries"] as Array[Dictionary]).duplicate(true),
		"messages": (message_result["messages"] as Array[Dictionary]).duplicate(true),
		"broadcast_tasks": (broadcast_task_result["tasks"] as Array[Dictionary]).duplicate(true),
		"dialogue_nodes": (dialogue_result["nodes"] as Array[Dictionary]).duplicate(true),
		"statements": (statement_result["statements"] as Array[Dictionary]).duplicate(true),
		"facts": (fact_result["facts"] as Array[Dictionary]).duplicate(true),
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
		if not event_data.has("dialogue_start_id"):
			return _make_error(source_path, event_id, "dialogue_start_id", "missing_field", "事件缺少测试剧情字段：dialogue_start_id。")
		if typeof(event_data["dialogue_start_id"]) != TYPE_STRING or not _is_stable_id(String(event_data["dialogue_start_id"])):
			return _make_error(source_path, event_id, "dialogue_start_id", "invalid_dialogue_start_id", "dialogue_start_id 必须是英文 snake_case ID。")
		for condition_id: Variant in event_data["condition_ids"] as Array:
			if not condition_ids.has(String(condition_id)):
				return _make_error(source_path, event_id, "condition_ids", "unknown_condition_id", "事件引用了未声明的条件 ID：%s。" % String(condition_id))
		by_id[event_id] = event_data.duplicate(true)
	return {"ok": true, "by_id": by_id}


## 清单、地方新闻和短信都是电脑可阅读的来源。解锁与阅读由 ComputerSystem
## 管理；本校验器只固化来源文本、稳定 ID 及其可关联的陈述/事实 ID。
func _validate_test_information_entries(raw_entries: Array, collection_name: String, requires_source: bool, source_path: String) -> Dictionary:
	if collection_name == "news_entries" and raw_entries.size() < 5:
		return _make_error(source_path, "", collection_name, "insufficient_news_entries", "测试剧情至少需要 5 条地方新闻。")
	if collection_name == "checklist_entries" and raw_entries.is_empty():
		return _make_error(source_path, "", collection_name, "empty_checklist_entries", "测试剧情必须提供值班清单。")
	var by_id: Dictionary = {}
	var entries: Array[Dictionary] = []
	var non_bridge_news_count: int = 0
	for raw_entry: Variant in raw_entries:
		if not raw_entry is Dictionary:
			return _make_error(source_path, "", collection_name, "invalid_information_entry_type", "%s 中的每一项必须是对象。" % collection_name)
		var entry: Dictionary = raw_entry as Dictionary
		var provisional_id: String = _read_event_id_or_empty(entry)
		var required_fields: PackedStringArray = ["id", "title", "body", "unlock_minute", "statement_ids", "fact_ids"]
		if collection_name == "news_entries":
			required_fields.append("topic_ids")
		for field_name: String in required_fields:
			if not entry.has(field_name):
				return _make_error(source_path, provisional_id, "%s.%s" % [collection_name, field_name], "missing_field", "%s 条目缺少必填字段：%s。" % [collection_name, field_name])
		if requires_source and not entry.has("source"):
			return _make_error(source_path, provisional_id, "%s.source" % collection_name, "missing_field", "地方新闻缺少来源字段：source。")
		if typeof(entry["id"]) != TYPE_STRING or not _is_stable_id(String(entry["id"])):
			return _make_error(source_path, provisional_id, "%s.id" % collection_name, "invalid_information_entry_id", "%s 条目 ID 必须是英文 snake_case 标识符。" % collection_name)
		var entry_id: String = String(entry["id"])
		if by_id.has(entry_id):
			return _make_error(source_path, entry_id, "%s.id" % collection_name, "duplicate_information_entry_id", "%s 条目 ID 在同一内容文件中重复。" % collection_name)
		for text_field: String in ["title", "body"]:
			if typeof(entry[text_field]) != TYPE_STRING or String(entry[text_field]).strip_edges().is_empty():
				return _make_error(source_path, entry_id, "%s.%s" % [collection_name, text_field], "invalid_information_entry_text", "%s 必须是非空字符串。" % text_field)
		if requires_source and (typeof(entry["source"]) != TYPE_STRING or String(entry["source"]).strip_edges().is_empty()):
			return _make_error(source_path, entry_id, "%s.source" % collection_name, "invalid_information_entry_source", "新闻来源 source 必须是非空字符串。")
		var minute_result: Dictionary = _read_exact_integer(entry["unlock_minute"])
		if not bool(minute_result.get("ok", false)) or int(minute_result["value"]) < 0 or int(minute_result["value"]) >= SHIFT_DURATION_MINUTES:
			return _make_error(source_path, entry_id, "%s.unlock_minute" % collection_name, "invalid_unlock_minute", "电脑条目解锁分钟必须是 0 至 59 的整数。")
		for id_field: String in ["statement_ids", "fact_ids"]:
			var id_array_result: Dictionary = _validate_stable_id_array(entry[id_field], source_path, entry_id, "%s.%s" % [collection_name, id_field])
			if not bool(id_array_result.get("ok", false)):
				return id_array_result
		if collection_name == "news_entries":
			var topic_ids_result: Dictionary = _validate_stable_id_array(entry["topic_ids"], source_path, entry_id, "news_entries.topic_ids")
			if not bool(topic_ids_result.get("ok", false)):
				return topic_ids_result
			if (entry["topic_ids"] as Array).is_empty():
				return _make_error(source_path, entry_id, "news_entries.topic_ids", "empty_news_topics", "地方新闻至少需要一个明确 topic_id。")
			if not (entry["topic_ids"] as Array).has(NORTH_BRIDGE_TOPIC_ID):
				non_bridge_news_count += 1
		var normalized: Dictionary = entry.duplicate(true)
		normalized["unlock_minute"] = int(minute_result["value"])
		by_id[entry_id] = normalized
		entries.append(normalized)
	if collection_name == "news_entries" and non_bridge_news_count < 2:
		return _make_error(source_path, "", "news_entries.topic_ids", "insufficient_non_bridge_news", "测试剧情至少需要 2 条不含 north_bridge topic_id 的地方新闻。")
	return {"ok": true, "by_id": by_id, "entries": entries}


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
		for field_name: String in ["id", "sender", "body", "unlock_minute", "statement_ids", "fact_ids"]:
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
		for id_field: String in ["statement_ids", "fact_ids"]:
			var id_array_result: Dictionary = _validate_stable_id_array(message[id_field], source_path, message_id, id_field)
			if not bool(id_array_result.get("ok", false)):
				return id_array_result
		var normalized: Dictionary = message.duplicate(true)
		normalized["unlock_minute"] = int(minute_result["value"])
		by_id[message_id] = normalized
		messages.append(normalized)
	return {"ok": true, "by_id": by_id, "messages": messages}


func _combine_test_source_ids(event_by_id: Dictionary, checklist_by_id: Dictionary, news_by_id: Dictionary, message_by_id: Dictionary, source_path: String) -> Dictionary:
	var source_ids: Dictionary = {}
	for source_collection: Dictionary in [event_by_id, checklist_by_id, news_by_id, message_by_id]:
		for source_id_variant: Variant in source_collection.keys():
			var source_id: String = String(source_id_variant)
			if source_ids.has(source_id):
				return _make_error(source_path, source_id, "id", "duplicate_source_id", "来电事件与电脑来源条目之间不能复用稳定 ID。")
			source_ids[source_id] = true
	return {"ok": true, "source_ids": source_ids}


## 陈述是“某个来源说过什么”的最小原子；不代表该陈述已经得到事实确认。
func _validate_test_statements(raw_statements: Array, source_ids: Dictionary, source_path: String) -> Dictionary:
	if raw_statements.is_empty():
		return _make_error(source_path, "", "statements", "empty_statements", "测试剧情必须声明来源陈述。")
	var by_id: Dictionary = {}
	var statements: Array[Dictionary] = []
	for raw_statement: Variant in raw_statements:
		if not raw_statement is Dictionary:
			return _make_error(source_path, "", "statements", "invalid_statement_type", "statements 中的每一项必须是对象。")
		var statement: Dictionary = raw_statement as Dictionary
		var provisional_id: String = _read_event_id_or_empty(statement)
		for field_name: String in ["id", "source_id", "body"]:
			if not statement.has(field_name):
				return _make_error(source_path, provisional_id, "statements.%s" % field_name, "missing_field", "陈述缺少必填字段：%s。" % field_name)
		if typeof(statement["id"]) != TYPE_STRING or not _is_stable_id(String(statement["id"])):
			return _make_error(source_path, provisional_id, "statements.id", "invalid_statement_id", "陈述 ID 必须是英文 snake_case 标识符。")
		var statement_id: String = String(statement["id"])
		if by_id.has(statement_id):
			return _make_error(source_path, statement_id, "statements.id", "duplicate_statement_id", "陈述 ID 在同一内容文件中重复。")
		if typeof(statement["source_id"]) != TYPE_STRING or not source_ids.has(String(statement["source_id"])):
			return _make_error(source_path, statement_id, "statements.source_id", "unknown_statement_source_id", "陈述必须引用已有的电脑来源条目或电话事件 ID。")
		if typeof(statement["body"]) != TYPE_STRING or String(statement["body"]).strip_edges().is_empty():
			return _make_error(source_path, statement_id, "statements.body", "invalid_statement_body", "陈述正文必须是非空字符串。")
		var normalized: Dictionary = statement.duplicate(true)
		by_id[statement_id] = normalized
		statements.append(normalized)
	return {"ok": true, "by_id": by_id, "statements": statements}


## 事实只在所有 required_statement_ids 都已经揭示时确认；initially_confirmed
## 仅适用于开局已知的基线事实，不会由任何单个角色陈述直接改写。
func _validate_test_facts(raw_facts: Array, statement_by_id: Dictionary, source_path: String) -> Dictionary:
	if raw_facts.is_empty():
		return _make_error(source_path, "", "facts", "empty_facts", "测试剧情必须声明稳定事实 ID。")
	var by_id: Dictionary = {}
	var facts: Array[Dictionary] = []
	for raw_fact: Variant in raw_facts:
		if not raw_fact is Dictionary:
			return _make_error(source_path, "", "facts", "invalid_fact_type", "facts 中的每一项必须是对象。")
		var fact: Dictionary = raw_fact as Dictionary
		var provisional_id: String = _read_event_id_or_empty(fact)
		for field_name: String in ["id", "initially_confirmed", "required_statement_ids"]:
			if not fact.has(field_name):
				return _make_error(source_path, provisional_id, "facts.%s" % field_name, "missing_field", "事实缺少必填字段：%s。" % field_name)
		if typeof(fact["id"]) != TYPE_STRING or not _is_stable_id(String(fact["id"])):
			return _make_error(source_path, provisional_id, "facts.id", "invalid_fact_id", "事实 ID 必须是英文 snake_case 标识符。")
		var fact_id: String = String(fact["id"])
		if by_id.has(fact_id):
			return _make_error(source_path, fact_id, "facts.id", "duplicate_fact_id", "事实 ID 在同一内容文件中重复。")
		if typeof(fact["initially_confirmed"]) != TYPE_BOOL:
			return _make_error(source_path, fact_id, "facts.initially_confirmed", "invalid_initially_confirmed", "initially_confirmed 必须是 bool。")
		var statement_ids_result: Dictionary = _validate_stable_id_array(fact["required_statement_ids"], source_path, fact_id, "facts.required_statement_ids")
		if not bool(statement_ids_result.get("ok", false)):
			return statement_ids_result
		for statement_id_variant: Variant in fact["required_statement_ids"] as Array:
			if not statement_by_id.has(String(statement_id_variant)):
				return _make_error(source_path, fact_id, "facts.required_statement_ids", "unknown_required_statement_id", "事实引用了不存在的必要陈述：%s。" % String(statement_id_variant))
		if not bool(fact["initially_confirmed"]) and (fact["required_statement_ids"] as Array).is_empty() and not ENDING_ONLY_FACT_IDS.has(fact_id):
			return _make_error(source_path, fact_id, "facts.required_statement_ids", "missing_fact_evidence", "未初始确认的事实至少需要一条必要陈述。")
		var normalized: Dictionary = fact.duplicate(true)
		by_id[fact_id] = normalized
		facts.append(normalized)
	for required_fact_id: String in REQUIRED_TEST_FACT_IDS:
		if not by_id.has(required_fact_id):
			return _make_error(source_path, required_fact_id, "facts.id", "missing_required_fact_id", "测试剧情缺少既定稳定事实 ID：%s。" % required_fact_id)
	for fact_id_variant: Variant in by_id.keys():
		if not REQUIRED_TEST_FACT_IDS.has(String(fact_id_variant)):
			return _make_error(source_path, String(fact_id_variant), "facts.id", "unknown_test_fact_id", "测试剧情不能声明既定集合之外的事实 ID。")
	return {"ok": true, "by_id": by_id, "facts": facts}


func _validate_test_information_references(entry_collections: Array, statement_by_id: Dictionary, fact_by_id: Dictionary, source_path: String) -> Dictionary:
	for raw_collection: Variant in entry_collections:
		if not raw_collection is Array:
			return _make_error(source_path, "", "information_entries", "invalid_information_entry_collection", "内部校验错误：电脑来源集合必须是数组。")
		for raw_entry: Variant in raw_collection as Array:
			if not raw_entry is Dictionary:
				return _make_error(source_path, "", "information_entries", "invalid_information_entry", "内部校验错误：电脑来源条目必须是对象。")
			var entry: Dictionary = raw_entry as Dictionary
			var entry_id: String = String(entry["id"])
			for statement_id_variant: Variant in entry["statement_ids"] as Array:
				var statement_id: String = String(statement_id_variant)
				if not statement_by_id.has(statement_id):
					return _make_error(source_path, entry_id, "statement_ids", "unknown_statement_id", "电脑来源条目引用了不存在的陈述：%s。" % statement_id)
				if String((statement_by_id[statement_id] as Dictionary)["source_id"]) != entry_id:
					return _make_error(source_path, entry_id, "statement_ids", "statement_source_mismatch", "电脑来源条目只能关联以自身 ID 为 source_id 的陈述。")
			for fact_id_variant: Variant in entry["fact_ids"] as Array:
				if not fact_by_id.has(String(fact_id_variant)):
					return _make_error(source_path, entry_id, "fact_ids", "unknown_fact_id", "电脑来源条目引用了不存在的事实：%s。" % String(fact_id_variant))
	return {"ok": true}


func _validate_test_broadcast_tasks(raw_tasks: Array, event_by_id: Dictionary, statement_by_id: Dictionary, condition_ids: Dictionary, fact_by_id: Dictionary, source_path: String) -> Dictionary:
	if raw_tasks.is_empty():
		return _make_error(source_path, "", "broadcast_tasks", "empty_broadcast_tasks", "测试剧情至少需要一个麦克风发布任务。")
	var task_ids: Dictionary = {}
	var information_item_ids: Dictionary = {}
	var tasks: Array[Dictionary] = []
	for raw_task: Variant in raw_tasks:
		if not raw_task is Dictionary:
			return _make_error(source_path, "", "broadcast_tasks", "invalid_broadcast_task_type", "broadcast_tasks 中的每一项必须是对象。")
		var task: Dictionary = raw_task as Dictionary
		var provisional_id: String = _read_event_id_or_empty(task)
		for field_name: String in ["id", "name", "channel", "source", "related_dialogue_event_ids", "required_dialogue_event_ids", "sets_condition_id", "information_items"]:
			if not task.has(field_name):
				return _make_error(source_path, provisional_id, field_name, "missing_field", "发布任务缺少必填字段：%s。" % field_name)
		if typeof(task["id"]) != TYPE_STRING or not _is_stable_id(String(task["id"])):
			return _make_error(source_path, provisional_id, "id", "invalid_broadcast_task_id", "发布任务 ID 必须是英文 snake_case 标识符。")
		var task_id: String = String(task["id"])
		if task_ids.has(task_id):
			return _make_error(source_path, task_id, "id", "duplicate_broadcast_task_id", "发布任务 ID 在同一内容文件中重复。")
		task_ids[task_id] = true
		for text_field: String in ["name", "source"]:
			if typeof(task[text_field]) != TYPE_STRING or String(task[text_field]).strip_edges().is_empty():
				return _make_error(source_path, task_id, text_field, "invalid_broadcast_task_text", "%s 必须是非空字符串。" % text_field)
		if typeof(task["channel"]) != TYPE_STRING or String(task["channel"]) != "microphone":
			return _make_error(source_path, task_id, "channel", "invalid_broadcast_task_channel", "当前发布任务 channel 必须精确为 microphone。")
		var related_result: Dictionary = _validate_stable_id_array(task["related_dialogue_event_ids"], source_path, task_id, "related_dialogue_event_ids")
		if not bool(related_result.get("ok", false)):
			return related_result
		var required_result: Dictionary = _validate_stable_id_array(task["required_dialogue_event_ids"], source_path, task_id, "required_dialogue_event_ids")
		if not bool(required_result.get("ok", false)):
			return required_result
		var related_ids: Array = task["related_dialogue_event_ids"] as Array
		var required_ids: Array = task["required_dialogue_event_ids"] as Array
		if related_ids.is_empty() or required_ids.is_empty():
			return _make_error(source_path, task_id, "related_dialogue_event_ids/required_dialogue_event_ids", "empty_dialogue_prerequisites", "发布任务必须声明至少一个相关对话和至少一个必需对话。")
		for event_id_variant: Variant in related_ids:
			var event_id: String = String(event_id_variant)
			if not event_by_id.has(event_id):
				return _make_error(source_path, task_id, "related_dialogue_event_ids", "unknown_dialogue_event_id", "发布任务引用了不存在的相关来电：%s。" % event_id)
			if String((event_by_id[event_id] as Dictionary).get("dialogue_start_id", "")).is_empty():
				return _make_error(source_path, task_id, "related_dialogue_event_ids", "event_without_dialogue", "发布任务的相关来电必须包含预制对话：%s。" % event_id)
		for event_id_variant: Variant in required_ids:
			if not related_ids.has(String(event_id_variant)):
				return _make_error(source_path, task_id, "required_dialogue_event_ids", "required_dialogue_not_related", "必需对话必须同时属于 related_dialogue_event_ids。")
		if typeof(task["sets_condition_id"]) != TYPE_STRING:
			return _make_error(source_path, task_id, "sets_condition_id", "invalid_sets_condition_id", "sets_condition_id 必须是字符串。")
		var condition_id: String = String(task["sets_condition_id"])
		if not condition_id.is_empty() and (not _is_stable_id(condition_id) or not condition_ids.has(condition_id)):
			return _make_error(source_path, task_id, "sets_condition_id", "unknown_condition_id", "发布任务引用了未声明的条件 ID。")
		if typeof(task["information_items"]) != TYPE_ARRAY or (task["information_items"] as Array).is_empty():
			return _make_error(source_path, task_id, "information_items", "empty_information_items", "发布任务至少需要一个可选信息项。")
		for raw_item: Variant in task["information_items"] as Array:
			if not raw_item is Dictionary:
				return _make_error(source_path, task_id, "information_items", "invalid_information_item_type", "发布任务的信息项必须是对象。")
			var item: Dictionary = raw_item as Dictionary
			for field_name: String in ["id", "source_label", "body", "statement_ids", "fact_ids"]:
				if not item.has(field_name):
					return _make_error(source_path, task_id, "information_items.%s" % field_name, "missing_field", "发布任务信息项缺少字段：%s。" % field_name)
			if typeof(item["id"]) != TYPE_STRING or not _is_stable_id(String(item["id"])):
				return _make_error(source_path, task_id, "information_items.id", "invalid_information_item_id", "信息项 ID 必须是英文 snake_case 标识符。")
			var item_id: String = String(item["id"])
			if information_item_ids.has(item_id):
				return _make_error(source_path, item_id, "information_items.id", "duplicate_information_item_id", "信息项 ID 必须在整份内容中唯一。")
			information_item_ids[item_id] = true
			for text_field: String in ["source_label", "body"]:
				if typeof(item[text_field]) != TYPE_STRING or String(item[text_field]).strip_edges().is_empty():
					return _make_error(source_path, item_id, text_field, "invalid_information_item_text", "%s 必须是非空字符串。" % text_field)
			var statement_ids_result: Dictionary = _validate_stable_id_array(item["statement_ids"], source_path, item_id, "statement_ids")
			if not bool(statement_ids_result.get("ok", false)):
				return statement_ids_result
			if (item["statement_ids"] as Array).is_empty():
				return _make_error(source_path, item_id, "statement_ids", "empty_information_statements", "每个任务信息项至少需要一个已揭示陈述作为可用前提。")
			for statement_id_variant: Variant in item["statement_ids"] as Array:
				if not statement_by_id.has(String(statement_id_variant)):
					return _make_error(source_path, item_id, "statement_ids", "unknown_statement_id", "信息项引用了不存在的陈述：%s。" % String(statement_id_variant))
			var fact_ids_result: Dictionary = _validate_stable_id_array(item["fact_ids"], source_path, item_id, "fact_ids")
			if not bool(fact_ids_result.get("ok", false)):
				return fact_ids_result
			for fact_id_variant: Variant in item["fact_ids"] as Array:
				if not fact_by_id.has(String(fact_id_variant)):
					return _make_error(source_path, item_id, "fact_ids", "unknown_fact_id", "信息项引用了不存在的事实：%s。" % String(fact_id_variant))
		tasks.append(task.duplicate(true))
	return {"ok": true, "tasks": tasks}


func _validate_test_dialogue_nodes(raw_nodes: Array, event_by_id: Dictionary, statement_by_id: Dictionary, source_path: String) -> Dictionary:
	var node_by_id: Dictionary = {}
	var option_ids: Dictionary = {}
	var nodes: Array[Dictionary] = []
	for raw_node: Variant in raw_nodes:
		if not raw_node is Dictionary:
			return _make_error(source_path, "", "dialogue_nodes", "invalid_dialogue_node_type", "dialogue_nodes 中的每一项必须是对象。")
		var node: Dictionary = raw_node as Dictionary
		var provisional_id: String = _read_event_id_or_empty(node)
		for field_name: String in ["id", "event_id", "speaker", "text", "is_terminal", "options", "reveals_statement_ids"]:
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
		var node_statement_ids_result: Dictionary = _validate_statement_reveal_ids(node["reveals_statement_ids"], statement_by_id, String(node["event_id"]), source_path, node_id, "reveals_statement_ids")
		if not bool(node_statement_ids_result.get("ok", false)):
			return node_statement_ids_result
		var options: Array = node["options"] as Array
		if bool(node["is_terminal"]) and not options.is_empty():
			return _make_error(source_path, node_id, "options", "terminal_has_options", "终止对话节点不能再包含选项。")
		if not bool(node["is_terminal"]) and options.is_empty():
			return _make_error(source_path, node_id, "options", "nonterminal_missing_options", "非终止对话节点至少需要一个选项。")
		for raw_option: Variant in options:
			if not raw_option is Dictionary:
				return _make_error(source_path, node_id, "options", "invalid_dialogue_option_type", "对话选项必须是对象。")
			var option: Dictionary = raw_option as Dictionary
			for field_name: String in ["id", "text", "next_node_id", "reveals_statement_ids"]:
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
			var option_statement_ids_result: Dictionary = _validate_statement_reveal_ids(option["reveals_statement_ids"], statement_by_id, String(node["event_id"]), source_path, node_id, "options.reveals_statement_ids")
			if not bool(option_statement_ids_result.get("ok", false)):
				return option_statement_ids_result
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


## 每条陈述都必须由所属来源的“阅读”或“对话推进”明确揭示。否则虽然
## source_id 有效，却永远无法在游戏中取得，是损坏内容而不是可忽略的闲置数据。
func _validate_statement_reveal_coverage(
	entry_collections: Array,
	dialogue_nodes: Array[Dictionary],
	statement_by_id: Dictionary,
	source_path: String
) -> Dictionary:
	var revealed_by_content: Dictionary = {}
	for raw_collection: Variant in entry_collections:
		for raw_entry: Variant in raw_collection as Array:
			var entry: Dictionary = raw_entry as Dictionary
			for statement_id_variant: Variant in entry["statement_ids"] as Array:
				revealed_by_content[String(statement_id_variant)] = true
	for node: Dictionary in dialogue_nodes:
		for statement_id_variant: Variant in node["reveals_statement_ids"] as Array:
			revealed_by_content[String(statement_id_variant)] = true
		for option: Dictionary in node["options"] as Array:
			for statement_id_variant: Variant in option["reveals_statement_ids"] as Array:
				revealed_by_content[String(statement_id_variant)] = true
	for statement_id_variant: Variant in statement_by_id.keys():
		var statement_id: String = String(statement_id_variant)
		if not revealed_by_content.has(statement_id):
			return _make_error(source_path, statement_id, "statements.id", "unrevealed_statement", "陈述没有被所属电脑来源或对话节点/选项引用，玩家无法获得它。")
	return {"ok": true}


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


func _validate_stable_id_array(value: Variant, source_path: String, entry_id: String, field_name: String) -> Dictionary:
	if typeof(value) != TYPE_ARRAY:
		return _make_error(source_path, entry_id, field_name, "invalid_stable_id_array", "%s 必须是数组。" % field_name)
	var seen_ids: Dictionary = {}
	for raw_id: Variant in value as Array:
		if typeof(raw_id) != TYPE_STRING or not _is_stable_id(String(raw_id)):
			return _make_error(source_path, entry_id, field_name, "invalid_stable_id", "%s 中的每一项必须是英文 snake_case ID。" % field_name)
		var stable_id: String = String(raw_id)
		if seen_ids.has(stable_id):
			return _make_error(source_path, entry_id, field_name, "duplicate_stable_id", "%s 不能包含重复 ID。" % field_name)
		seen_ids[stable_id] = true
	return {"ok": true}


func _validate_statement_reveal_ids(
	value: Variant,
	statement_by_id: Dictionary,
	event_id: String,
	source_path: String,
	node_id: String,
	field_name: String
) -> Dictionary:
	var shape_result: Dictionary = _validate_stable_id_array(value, source_path, node_id, field_name)
	if not bool(shape_result.get("ok", false)):
		return shape_result
	for statement_id_variant: Variant in value as Array:
		var statement_id: String = String(statement_id_variant)
		if not statement_by_id.has(statement_id):
			return _make_error(source_path, node_id, field_name, "unknown_statement_id", "对话揭示了不存在的陈述：%s。" % statement_id)
		var statement: Dictionary = statement_by_id[statement_id] as Dictionary
		if String(statement["source_id"]) != event_id:
			return _make_error(source_path, node_id, field_name, "statement_source_mismatch", "电话对话只能揭示以本通 event_id 为来源的陈述。")
	return {"ok": true}


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
