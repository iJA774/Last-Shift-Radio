class_name DeliverySystem
extends RefCounted

## Actor / Director 已批准意图到真实世界提交之间的确定性边界。
##
## 模型永远不能直接调用 PhoneSystem / ComputerSystem。调用方只能提交有限动作意图；
## 本系统分配稳定 delivery ID、执行 authority 检查、保存 queued/committed/rejected 状态，
## 并且在 restore 时只恢复已经做出的决定，绝不重新请求模型或重放历史提交。

signal delivery_queued(record: Dictionary)
signal delivery_committed(record: Dictionary)
signal delivery_rejected(record: Dictionary)
signal delivery_cancelled(record: Dictionary)
signal delivery_state_changed(record: Dictionary)

const SNAPSHOT_VERSION: int = 1
const SYSTEM_ID: String = "delivery_system"
const MAX_GAME_TICK: int = 3_600
const CALL_RING_TIMEOUT_TICKS: int = 60

const ACTION_CALL_STATION: String = "call_station"
const ACTION_SEND_MESSAGE: String = "send_message"
const TARGET_PHONE: String = "phone_system"
const TARGET_COMPUTER: String = "computer_system"

const STATUS_PENDING: String = "pending"
const STATUS_QUEUED: String = "queued"
const STATUS_COMMITTED: String = "committed"
const STATUS_REJECTED: String = "rejected"
const STATUS_CANCELLED: String = "cancelled"
const STATUSES: PackedStringArray = [
	STATUS_PENDING,
	STATUS_QUEUED,
	STATUS_COMMITTED,
	STATUS_REJECTED,
	STATUS_CANCELLED,
]

var _is_configured: bool = false
var _actor_display_name_by_id: Dictionary = {}
var _actor_call_identity_by_id: Dictionary = {}
var _phone_system: RefCounted = null
var _computer_system: RefCounted = null
var _next_serial: int = 1
var _requests: Array[Dictionary] = []
var _request_by_id: Dictionary = {}
var _delivery_id_by_opportunity_id: Dictionary = {}
var _call_queue: Array[String] = []


## Actor 显示名来自正式 Actor authoring；来电号码只能从已校验 authored event 中派生。
## 同一 Actor 若在 authored events 中出现多个不同号码/来显，配置直接失败，不能由模型补全。
func configure(actor_definitions: Array, story_events: Array) -> Dictionary:
	if _is_configured or not _requests.is_empty():
		return _error("delivery_already_configured", "DeliverySystem 已配置，不能在同一局中覆盖世界定义。")
	var next_display_names: Dictionary = {}
	for raw_actor: Variant in actor_definitions:
		if not raw_actor is Dictionary:
			return _error("delivery_actor_invalid", "DeliverySystem actor_definitions 中每项必须是对象。")
		var actor: Dictionary = raw_actor as Dictionary
		if not actor.get("id") is String or not _is_valid_stable_id(String(actor["id"])):
			return _error("delivery_actor_invalid", "DeliverySystem Actor 必须有英文 snake_case 稳定 id。")
		var actor_id: String = String(actor["id"])
		if next_display_names.has(actor_id):
			return _error("delivery_actor_duplicate", "DeliverySystem Actor ID 重复：%s。" % actor_id)
		if not actor.get("display_name") is String or String(actor["display_name"]).strip_edges().is_empty():
			return _error("delivery_actor_invalid", "DeliverySystem Actor %s 缺少非空 display_name。" % actor_id)
		next_display_names[actor_id] = String(actor["display_name"])

	var next_call_identities: Dictionary = {}
	for raw_event: Variant in story_events:
		if not raw_event is Dictionary:
			return _error("delivery_event_invalid", "DeliverySystem story_events 中每项必须是对象。")
		var event_data: Dictionary = raw_event as Dictionary
		var actor_id: String = String(event_data.get("actor_id", ""))
		if actor_id.is_empty():
			continue
		if not next_display_names.has(actor_id):
			return _error("delivery_event_actor_unknown", "剧情事件引用了 DeliverySystem 未注册 Actor：%s。" % actor_id)
		if not event_data.get("caller_display_name") is String or String(event_data["caller_display_name"]).strip_edges().is_empty():
			return _error("delivery_event_caller_invalid", "Actor %s 的剧情来电缺少 caller_display_name。" % actor_id)
		if not event_data.get("caller_number") is String or String(event_data["caller_number"]).strip_edges().is_empty():
			return _error("delivery_event_caller_invalid", "Actor %s 的剧情来电缺少 caller_number。" % actor_id)
		var identity: Dictionary = {
			"caller_display_name": String(event_data["caller_display_name"]),
			"caller_number": String(event_data["caller_number"]),
		}
		if next_call_identities.has(actor_id) and (next_call_identities[actor_id] as Dictionary) != identity:
			return _error("delivery_actor_call_identity_conflict", "Actor %s 的 authored 来电身份不唯一，不能用于动态来电。" % actor_id)
		next_call_identities[actor_id] = identity

	_actor_display_name_by_id = next_display_names
	_actor_call_identity_by_id = next_call_identities
	_is_configured = true
	return {
		"ok": true,
		"actor_count": _actor_display_name_by_id.size(),
		"callable_actor_count": _actor_call_identity_by_id.size(),
	}


func set_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _error("delivery_phone_invalid", "DeliverySystem PhoneSystem 不能为空。")
	for method_name: String in ["begin_incoming_call", "is_busy", "is_forced_ended"]:
		if not phone_system.has_method(method_name):
			return _error("delivery_phone_contract_invalid", "PhoneSystem 缺少 %s()。" % method_name)
	_phone_system = phone_system
	return {"ok": true}


func set_computer_system(computer_system: RefCounted) -> Dictionary:
	if computer_system == null or not computer_system.has_method(&"commit_dynamic_message"):
		return _error("delivery_computer_contract_invalid", "ComputerSystem 缺少 commit_dynamic_message() 动态消息 authority。")
	_computer_system = computer_system
	return {"ok": true}


## 上游 ActorAction validator 使用的只读世界校验。这里不分配 serial、不改变 queue/status，
## 只判断该结构化 intent 在当前确定性 authority 下是否允许进入正式提交入口。
func validate_request_intent(
	actor_id: String,
	action_id: String,
	arguments: Dictionary,
	source_opportunity_id: String = "",
	source_director_plan_id: String = ""
) -> Dictionary:
	if not _is_configured:
		return _error("delivery_not_configured", "DeliverySystem 尚未配置。")
	if not _actor_display_name_by_id.has(actor_id):
		return _error("delivery_actor_unknown", "DeliveryRequest 引用了未注册 Actor：%s。" % actor_id)
	var arguments_result: Dictionary = _validate_arguments(action_id, arguments)
	if not bool(arguments_result.get("ok", false)):
		return arguments_result
	for source_pair: Array in [["source_opportunity_id", source_opportunity_id], ["source_director_plan_id", source_director_plan_id]]:
		var source_name: String = String(source_pair[0])
		var source_id: String = String(source_pair[1])
		if not source_id.is_empty() and not _is_valid_stable_id(source_id):
			return _error("delivery_source_id_invalid", "%s 必须为空或英文 snake_case 稳定 ID。" % source_name)
	var normalized_arguments: Dictionary = arguments_result["arguments"] as Dictionary
	if not source_opportunity_id.is_empty() and _delivery_id_by_opportunity_id.has(source_opportunity_id):
		var existing_id: String = String(_delivery_id_by_opportunity_id[source_opportunity_id])
		var existing: Dictionary = _request_by_id[existing_id] as Dictionary
		if String(existing["actor_id"]) != actor_id or String(existing["action_id"]) != action_id or (existing["arguments"] as Dictionary) != normalized_arguments:
			return _error("delivery_opportunity_conflict", "同一 source_opportunity_id 不能映射到不同 DeliveryRequest。")
		return {"ok": true, "duplicate": true, "arguments": normalized_arguments.duplicate(true)}
	match action_id:
		ACTION_CALL_STATION:
			if not _actor_call_identity_by_id.has(actor_id):
				return _error("delivery_actor_not_callable", "Actor %s 没有 authored 来电身份，不能主动呼叫电台。" % actor_id)
			if _phone_system == null:
				return _error("delivery_phone_unavailable", "DeliverySystem 尚未绑定 PhoneSystem。")
			var forced_value: Variant = _phone_system.call(&"is_forced_ended")
			if typeof(forced_value) != TYPE_BOOL:
				return _error("delivery_phone_contract_invalid", "PhoneSystem.is_forced_ended() 必须返回 bool。")
			if bool(forced_value):
				return _error("ending_forced", "02:00 后不能创建主动来电 DeliveryRequest。")
		ACTION_SEND_MESSAGE:
			if _computer_system == null:
				return _error("delivery_computer_unavailable", "DeliverySystem 尚未绑定 ComputerSystem。")
	return {"ok": true, "duplicate": false, "arguments": normalized_arguments.duplicate(true)}


## Actor / Director 只能把已经过上游有限动作校验的结构化意图交到这里。
## source_opportunity_id 非空时同时充当幂等键：同一 opportunity 不会分配第二个 delivery serial。
func submit_delivery_request(
	actor_id: String,
	action_id: String,
	arguments: Dictionary,
	current_tick: int,
	source_opportunity_id: String = "",
	source_director_plan_id: String = ""
) -> Dictionary:
	if current_tick < 0 or current_tick > MAX_GAME_TICK:
		return _error("delivery_tick_invalid", "DeliveryRequest current_tick 必须是有效游戏 tick。")
	var intent_result: Dictionary = validate_request_intent(
		actor_id,
		action_id,
		arguments,
		source_opportunity_id,
		source_director_plan_id
	)
	if not bool(intent_result.get("ok", false)):
		return intent_result
	if bool(intent_result.get("duplicate", false)):
		var existing_id: String = String(_delivery_id_by_opportunity_id[source_opportunity_id])
		return {"ok": true, "duplicate": true, "record": _read_only(_request_by_id[existing_id] as Dictionary)}
	var normalized_arguments: Dictionary = intent_result["arguments"] as Dictionary

	var serial: int = _next_serial
	_next_serial += 1
	var delivery_id: String = _make_delivery_id(action_id, actor_id, serial)
	var target_system: String = TARGET_PHONE if action_id == ACTION_CALL_STATION else TARGET_COMPUTER
	var request: Dictionary = {
		"delivery_id": delivery_id,
		"actor_id": actor_id,
		"action_id": action_id,
		"created_at_tick": current_tick,
		"arguments": normalized_arguments.duplicate(true),
		"status": STATUS_PENDING,
		"target_system": target_system,
		"source_opportunity_id": source_opportunity_id,
		"source_director_plan_id": source_director_plan_id,
	}
	_requests.append(request)
	_request_by_id[delivery_id] = request
	if not source_opportunity_id.is_empty():
		_delivery_id_by_opportunity_id[source_opportunity_id] = delivery_id

	var attempt: Dictionary = _attempt_request(request, current_tick)
	if not bool(attempt.get("ok", false)):
		return attempt
	return {"ok": true, "duplicate": false, "record": _read_only(request)}


## PhoneSystem 变为空闲后由拥有当前 Story tick 的上层协调器调用。FIFO 队列只尝试队头；
## 若队头提交成功，电话立即再次 busy，因此不会越过它并启动第二条线路。
func retry_queued_calls(current_tick: int) -> Dictionary:
	if current_tick < 0 or current_tick > MAX_GAME_TICK:
		return _error("delivery_tick_invalid", "重试 Delivery queue 时 current_tick 无效。")
	var processed: int = 0
	while not _call_queue.is_empty():
		if _phone_system == null:
			return _error("delivery_phone_unavailable", "Delivery queue 缺少 PhoneSystem authority。")
		var busy_value: Variant = _phone_system.call(&"is_busy")
		if typeof(busy_value) != TYPE_BOOL:
			return _error("delivery_phone_contract_invalid", "PhoneSystem.is_busy() 必须返回 bool。")
		if bool(busy_value):
			break
		var delivery_id: String = _call_queue[0]
		if not _request_by_id.has(delivery_id):
			return _error("delivery_queue_corrupt", "Delivery queue 引用了不存在的 request。")
		var request: Dictionary = _request_by_id[delivery_id] as Dictionary
		if String(request["status"]) != STATUS_QUEUED:
			return _error("delivery_queue_corrupt", "Delivery queue 中的 request 必须处于 queued。")
		_call_queue.remove_at(0)
		processed += 1
		var result: Dictionary = _attempt_call_station(request, current_tick, false)
		if not bool(result.get("ok", false)):
			return result
		if String(request["status"]) == STATUS_COMMITTED:
			break
	return {"ok": true, "processed": processed, "remaining": _call_queue.size()}


func cancel_queued_deliveries(_current_tick: int) -> Dictionary:
	var cancelled: int = 0
	for delivery_id: String in _call_queue:
		if not _request_by_id.has(delivery_id):
			continue
		var request: Dictionary = _request_by_id[delivery_id] as Dictionary
		if String(request["status"]) != STATUS_QUEUED:
			continue
		_set_status(request, STATUS_CANCELLED)
		cancelled += 1
		delivery_cancelled.emit(_read_only(request))
	_call_queue.clear()
	return {"ok": true, "cancelled": cancelled}


func get_state_summary() -> Dictionary:
	var requests: Array[Dictionary] = []
	for request: Dictionary in _requests:
		requests.append(_read_only(request))
	return {
		"available": true,
		"requests": requests,
		"queued_call_ids": _call_queue.duplicate(),
		"next_serial": _next_serial,
	}


func get_request(delivery_id: String) -> Dictionary:
	if not _request_by_id.has(delivery_id):
		return {}
	return _read_only(_request_by_id[delivery_id] as Dictionary)


## 只暴露来自 authored events 的确定性来电身份。调用方不能通过 DeliveryRequest 覆盖它。
func get_actor_call_identity(actor_id: String) -> Dictionary:
	if not _actor_call_identity_by_id.has(actor_id):
		return {}
	var identity: Dictionary = (_actor_call_identity_by_id[actor_id] as Dictionary).duplicate(true)
	identity["actor_id"] = actor_id
	identity.make_read_only()
	return identity


## StoryEngine 用此只读接口把 Delivery committed call 与 PhoneSystem active/record 做交叉校验。
func get_call_metadata_for_delivery(delivery_id: String) -> Dictionary:
	if not _request_by_id.has(delivery_id):
		return {}
	var request: Dictionary = _request_by_id[delivery_id] as Dictionary
	if String(request["action_id"]) != ACTION_CALL_STATION:
		return {}
	var actor_id: String = String(request["actor_id"])
	if not _actor_call_identity_by_id.has(actor_id):
		return {}
	var identity: Dictionary = (_actor_call_identity_by_id[actor_id] as Dictionary).duplicate(true)
	identity["event_id"] = delivery_id
	identity["actor_id"] = actor_id
	return identity


func create_snapshot() -> Dictionary:
	var requests: Array[Dictionary] = []
	for request: Dictionary in _requests:
		requests.append(request.duplicate(true))
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SYSTEM_ID,
		"next_serial": _next_serial,
		"requests": requests,
		"call_queue": _call_queue.duplicate(),
	}
	snapshot.make_read_only()
	return snapshot


func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _is_configured:
		return _error("delivery_snapshot_not_configured", "DeliverySystem 尚未配置，不能校验存档。")
	var fields: PackedStringArray = ["snapshot_version", "system_id", "next_serial", "requests", "call_queue"]
	if snapshot.size() != fields.size():
		return _error("delivery_snapshot_fields_invalid", "DeliverySystem 存档字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not snapshot.has(field_name):
			return _error("delivery_snapshot_missing_field", "DeliverySystem 存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != SNAPSHOT_VERSION:
		return _error("delivery_snapshot_version_unsupported", "DeliverySystem 存档版本不受支持。")
	if not snapshot["system_id"] is String or String(snapshot["system_id"]) != SYSTEM_ID:
		return _error("delivery_snapshot_system_id_mismatch", "DeliverySystem 存档所属系统不匹配。")
	var serial_result: Dictionary = _read_exact_integer(snapshot["next_serial"])
	if not bool(serial_result.get("ok", false)) or int(serial_result["value"]) < 1:
		return _error("delivery_snapshot_next_serial_invalid", "DeliverySystem next_serial 必须是正整数。")
	if not snapshot["requests"] is Array or not snapshot["call_queue"] is Array:
		return _error("delivery_snapshot_collection_invalid", "DeliverySystem requests/call_queue 必须是数组。")
	var current_tick: int = MAX_GAME_TICK
	if context.has("current_game_tick"):
		var tick_result: Dictionary = _read_exact_integer(context["current_game_tick"])
		if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0 or int(tick_result["value"]) > MAX_GAME_TICK:
			return _error("delivery_snapshot_context_tick_invalid", "DeliverySystem 恢复上下文 current_game_tick 无效。")
		current_tick = int(tick_result["value"])

	var normalized_requests: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	var opportunity_lookup: Dictionary = {}
	var expected_queue: Array[String] = []
	var maximum_serial: int = 0
	for raw_request: Variant in snapshot["requests"] as Array:
		var request_result: Dictionary = _validate_snapshot_request(raw_request, current_tick)
		if not bool(request_result.get("ok", false)):
			return request_result
		var request: Dictionary = request_result["request"] as Dictionary
		var delivery_id: String = String(request["delivery_id"])
		if seen_ids.has(delivery_id):
			return _error("delivery_snapshot_duplicate_id", "DeliverySystem 存档含重复 delivery_id：%s。" % delivery_id)
		seen_ids[delivery_id] = true
		var opportunity_id: String = String(request["source_opportunity_id"])
		if not opportunity_id.is_empty():
			if opportunity_lookup.has(opportunity_id):
				return _error("delivery_snapshot_duplicate_opportunity", "同一 source_opportunity_id 只能对应一条 DeliveryRequest。")
			opportunity_lookup[opportunity_id] = delivery_id
		if String(request["status"]) == STATUS_QUEUED:
			if String(request["action_id"]) != ACTION_CALL_STATION:
				return _error("delivery_snapshot_queue_status_invalid", "当前只有 call_station 可以处于 queued。")
			expected_queue.append(delivery_id)
		maximum_serial = maxi(maximum_serial, int(request_result["serial"]))
		normalized_requests.append(request)
	var next_serial: int = int(serial_result["value"])
	if next_serial != maximum_serial + 1:
		return _error("delivery_snapshot_serial_mismatch", "DeliverySystem next_serial 必须精确接续已有 request serial。")
	var queue_result: Dictionary = _validate_queue(snapshot["call_queue"] as Array, seen_ids)
	if not bool(queue_result.get("ok", false)):
		return queue_result
	var normalized_queue: Array[String] = queue_result["ids"] as Array[String]
	if normalized_queue != expected_queue:
		return _error("delivery_snapshot_queue_mismatch", "DeliverySystem call_queue 必须与 queued request 的提交顺序精确一致。")
	return {
		"ok": true,
		"normalized": {
			"next_serial": next_serial,
			"requests": normalized_requests,
			"call_queue": normalized_queue,
		},
	}


## restore 只恢复已经做出的结构化决定，不会调用 PhoneSystem / ComputerSystem，也不会发业务信号。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var normalized: Dictionary = validation["normalized"] as Dictionary
	var next_requests: Array[Dictionary] = []
	var next_by_id: Dictionary = {}
	var next_opportunities: Dictionary = {}
	for raw_request: Dictionary in normalized["requests"] as Array[Dictionary]:
		var request: Dictionary = raw_request.duplicate(true)
		next_requests.append(request)
		next_by_id[String(request["delivery_id"])] = request
		var opportunity_id: String = String(request["source_opportunity_id"])
		if not opportunity_id.is_empty():
			next_opportunities[opportunity_id] = String(request["delivery_id"])
	_requests = next_requests
	_request_by_id = next_by_id
	_delivery_id_by_opportunity_id = next_opportunities
	_call_queue = (normalized["call_queue"] as Array[String]).duplicate()
	_next_serial = int(normalized["next_serial"])
	return {"ok": true}


func _attempt_request(request: Dictionary, current_tick: int) -> Dictionary:
	match String(request["action_id"]):
		ACTION_CALL_STATION:
			return _attempt_call_station(request, current_tick, true)
		ACTION_SEND_MESSAGE:
			return _attempt_send_message(request, current_tick)
	return _error("delivery_action_unsupported", "DeliverySystem 不支持该 action。")


func _attempt_call_station(request: Dictionary, current_tick: int, allow_queue: bool) -> Dictionary:
	if _phone_system == null:
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	var forced_value: Variant = _phone_system.call(&"is_forced_ended")
	var busy_value: Variant = _phone_system.call(&"is_busy")
	if typeof(forced_value) != TYPE_BOOL or typeof(busy_value) != TYPE_BOOL:
		_reject(request)
		return _error("delivery_phone_contract_invalid", "PhoneSystem forced/busy 查询必须返回 bool。")
	if bool(forced_value):
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	if bool(busy_value):
		if allow_queue:
			_set_status(request, STATUS_QUEUED)
			_call_queue.append(String(request["delivery_id"]))
			delivery_queued.emit(_read_only(request))
			return {"ok": true, "queued": true, "record": _read_only(request)}
		# retry_queued_calls() 在检查 idle 与 begin_incoming_call() 之间仍可能遇到同步状态变化。
		# 这种情况下保持原 request 为 queued，并重新放回 FIFO 队头，绝不丢失已批准意图。
		_call_queue.insert(0, String(request["delivery_id"]))
		return {"ok": true, "queued": true, "record": _read_only(request)}
	var actor_id: String = String(request["actor_id"])
	if not _actor_call_identity_by_id.has(actor_id):
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	var identity: Dictionary = _actor_call_identity_by_id[actor_id] as Dictionary
	var call_data: Dictionary = {
		"id": String(request["delivery_id"]),
		"caller_display_name": String(identity["caller_display_name"]),
		"caller_number": String(identity["caller_number"]),
	}
	var begin_value: Variant = _phone_system.call(&"begin_incoming_call", call_data, current_tick, CALL_RING_TIMEOUT_TICKS)
	var began: bool = false
	if typeof(begin_value) == TYPE_BOOL:
		began = bool(begin_value)
	elif begin_value is Dictionary:
		began = bool((begin_value as Dictionary).get("ok", false))
	else:
		_reject(request)
		return _error("delivery_phone_contract_invalid", "PhoneSystem.begin_incoming_call() 返回值无效。")
	if not began:
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	_set_status(request, STATUS_COMMITTED)
	delivery_committed.emit(_read_only(request))
	return {"ok": true, "committed": true, "record": _read_only(request)}


func _attempt_send_message(request: Dictionary, current_tick: int) -> Dictionary:
	if _computer_system == null:
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	var actor_id: String = String(request["actor_id"])
	var message: Dictionary = {
		"id": String(request["delivery_id"]),
		"source_actor_id": actor_id,
		"sender": String(_actor_display_name_by_id[actor_id]),
		"body": String((request["arguments"] as Dictionary)["body"]),
	}
	var commit_value: Variant = _computer_system.call(&"commit_dynamic_message", message, current_tick)
	if not commit_value is Dictionary:
		_reject(request)
		return _error("delivery_computer_contract_invalid", "ComputerSystem.commit_dynamic_message() 必须返回 Dictionary。")
	if not bool((commit_value as Dictionary).get("ok", false)):
		_reject(request)
		return {"ok": true, "record": _read_only(request)}
	_set_status(request, STATUS_COMMITTED)
	delivery_committed.emit(_read_only(request))
	return {"ok": true, "committed": true, "record": _read_only(request)}


func _reject(request: Dictionary) -> void:
	_set_status(request, STATUS_REJECTED)
	delivery_rejected.emit(_read_only(request))


func _set_status(request: Dictionary, status: String) -> void:
	request["status"] = status
	delivery_state_changed.emit(_read_only(request))


func _validate_arguments(action_id: String, arguments: Dictionary) -> Dictionary:
	match action_id:
		ACTION_CALL_STATION:
			if arguments.size() > 1 or (arguments.size() == 1 and not arguments.has("topic")):
				return _error("delivery_arguments_invalid", "call_station arguments 只能为空或包含 topic。")
			var normalized: Dictionary = {}
			if arguments.has("topic"):
				if not arguments["topic"] is String or String(arguments["topic"]).strip_edges().is_empty() or String(arguments["topic"]).length() > 128:
					return _error("delivery_arguments_invalid", "call_station.topic 必须是 1..128 字符字符串。")
				normalized["topic"] = String(arguments["topic"])
			return {"ok": true, "arguments": normalized}
		ACTION_SEND_MESSAGE:
			if arguments.size() != 1 or not arguments.has("body"):
				return _error("delivery_arguments_invalid", "send_message arguments 必须且只能包含 body。")
			if not arguments["body"] is String:
				return _error("delivery_arguments_invalid", "send_message.body 必须是字符串。")
			var body: String = String(arguments["body"])
			if body.strip_edges().is_empty() or body.length() > 2_000:
				return _error("delivery_arguments_invalid", "send_message.body 必须是 1..2000 字符非空文本。")
			return {"ok": true, "arguments": {"body": body}}
	return _error("delivery_action_unsupported", "DeliverySystem 只支持 call_station / send_message。")


func _validate_snapshot_request(value: Variant, current_tick: int) -> Dictionary:
	if not value is Dictionary:
		return _error("delivery_snapshot_request_invalid", "DeliveryRequest 必须是对象。")
	var request: Dictionary = value as Dictionary
	var fields: PackedStringArray = [
		"delivery_id", "actor_id", "action_id", "created_at_tick", "arguments", "status",
		"target_system", "source_opportunity_id", "source_director_plan_id",
	]
	if request.size() != fields.size():
		return _error("delivery_snapshot_request_fields_invalid", "DeliveryRequest 字段缺失或包含未知字段。")
	for field_name: String in fields:
		if not request.has(field_name):
			return _error("delivery_snapshot_request_missing_field", "DeliveryRequest 缺少字段：%s。" % field_name)
	if not request["actor_id"] is String or not _actor_display_name_by_id.has(String(request["actor_id"])):
		return _error("delivery_snapshot_actor_invalid", "DeliveryRequest actor_id 不属于当前正式 Actor。")
	if not request["action_id"] is String:
		return _error("delivery_snapshot_action_invalid", "DeliveryRequest action_id 必须是字符串。")
	var action_id: String = String(request["action_id"])
	if not request["arguments"] is Dictionary:
		return _error("delivery_snapshot_arguments_invalid", "DeliveryRequest arguments 必须是对象。")
	var arguments_result: Dictionary = _validate_arguments(action_id, request["arguments"] as Dictionary)
	if not bool(arguments_result.get("ok", false)):
		return arguments_result
	var tick_result: Dictionary = _read_exact_integer(request["created_at_tick"])
	if not bool(tick_result.get("ok", false)) or int(tick_result["value"]) < 0 or int(tick_result["value"]) > current_tick:
		return _error("delivery_snapshot_tick_invalid", "DeliveryRequest created_at_tick 不能晚于存档时间。")
	if not request["status"] is String or not STATUSES.has(String(request["status"])):
		return _error("delivery_snapshot_status_invalid", "DeliveryRequest status 不受支持。")
	var expected_target: String = TARGET_PHONE if action_id == ACTION_CALL_STATION else TARGET_COMPUTER
	if not request["target_system"] is String or String(request["target_system"]) != expected_target:
		return _error("delivery_snapshot_target_invalid", "DeliveryRequest target_system 与 action_id 不一致。")
	for source_name: String in ["source_opportunity_id", "source_director_plan_id"]:
		if not request[source_name] is String:
			return _error("delivery_snapshot_source_invalid", "DeliveryRequest %s 必须是字符串。" % source_name)
		var source_id: String = String(request[source_name])
		if not source_id.is_empty() and not _is_valid_stable_id(source_id):
			return _error("delivery_snapshot_source_invalid", "DeliveryRequest %s 不是稳定 ID。" % source_name)
	if not request["delivery_id"] is String:
		return _error("delivery_snapshot_id_invalid", "DeliveryRequest delivery_id 必须是字符串。")
	var actor_id: String = String(request["actor_id"])
	var delivery_id: String = String(request["delivery_id"])
	var serial_result: Dictionary = _serial_from_delivery_id(delivery_id, action_id, actor_id)
	if not bool(serial_result.get("ok", false)):
		return serial_result
	return {
		"ok": true,
		"serial": int(serial_result["serial"]),
		"request": {
			"delivery_id": delivery_id,
			"actor_id": actor_id,
			"action_id": action_id,
			"created_at_tick": int(tick_result["value"]),
			"arguments": (arguments_result["arguments"] as Dictionary).duplicate(true),
			"status": String(request["status"]),
			"target_system": expected_target,
			"source_opportunity_id": String(request["source_opportunity_id"]),
			"source_director_plan_id": String(request["source_director_plan_id"]),
		},
	}


func _validate_queue(raw_queue: Array, known_ids: Dictionary) -> Dictionary:
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in raw_queue:
		if not raw_id is String:
			return _error("delivery_snapshot_queue_invalid", "DeliverySystem call_queue 只能包含 delivery ID 字符串。")
		var delivery_id: String = String(raw_id)
		if not known_ids.has(delivery_id) or seen.has(delivery_id):
			return _error("delivery_snapshot_queue_invalid", "DeliverySystem call_queue 含未知或重复 delivery ID。")
		seen[delivery_id] = true
		ids.append(delivery_id)
	return {"ok": true, "ids": ids}


func _make_delivery_id(action_id: String, actor_id: String, serial: int) -> String:
	var kind: String = "call" if action_id == ACTION_CALL_STATION else "message"
	return "delivery_%s_%s_%d" % [kind, actor_id, serial]


func _serial_from_delivery_id(delivery_id: String, action_id: String, actor_id: String) -> Dictionary:
	var kind: String = "call" if action_id == ACTION_CALL_STATION else "message"
	var prefix: String = "delivery_%s_%s_" % [kind, actor_id]
	if not delivery_id.begins_with(prefix):
		return _error("delivery_snapshot_id_invalid", "DeliveryRequest delivery_id 与 action/actor 不一致。")
	var serial_text: String = delivery_id.substr(prefix.length())
	if serial_text.is_empty() or not serial_text.is_valid_int():
		return _error("delivery_snapshot_id_invalid", "DeliveryRequest delivery_id serial 无效。")
	var serial: int = serial_text.to_int()
	if serial < 1 or str(serial) != serial_text:
		return _error("delivery_snapshot_id_invalid", "DeliveryRequest delivery_id serial 必须是无前导零正整数。")
	return {"ok": true, "serial": serial}


func _is_valid_stable_id(value: String) -> bool:
	return not value.is_empty() and not value.begins_with("_") and value.is_valid_identifier() and value.is_valid_ascii_identifier() and value == value.to_lower()


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _read_only(record: Dictionary) -> Dictionary:
	var copy: Dictionary = record.duplicate(true)
	copy.make_read_only()
	return copy


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
