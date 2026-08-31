## 《末班电台》的权威剧情状态。
##
## 本类协调 GameClock、事件调度、PhoneSystem、ComputerSystem 与 BroadcastSystem，
## 并唯一管理预制对话、来源陈述、轻量事实、广播条件、整数游戏时间和 02:00
## 强制收束。ComputerSystem 只维护来源解锁/已读，电话记录仍由 PhoneSystem 生成；
## 当前阶段不包含存档或存档状态导入导出。
extends RefCounted
class_name StoryEngine

signal event_ready(event: Dictionary)
signal event_queued(event: Dictionary)
signal event_expired(event: Dictionary)
signal ending_forced(end_tick: int)
signal story_time_advanced(previous_tick: int, current_tick: int, current_minute: int)
signal story_error(error_code: String, message: String)

const TICKS_PER_GAME_MINUTE: int = 60
const ENDING_TICK: int = 60 * TICKS_PER_GAME_MINUTE
const ENDING_ONLY_FACT_IDS: PackedStringArray = ["fact_unauthorized_broadcast", "fact_anomaly_cause_unknown"]
const SNAPSHOT_VERSION: int = 6
const SNAPSHOT_SYSTEM_ID: String = "story_engine"
const BROADCAST_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/broadcast_system.gd")
const COMPUTER_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/computer_system.gd")
const SIGNAL_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/signal_system.gd")
const DELIVERY_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/delivery_system.gd")
const TASK_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/task_system.gd")
const INTERACTION_OUTCOME_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/interaction_outcome_system.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")

signal message_unlocked(message: Dictionary)
signal broadcast_state_changed()
## 仅在一个可发布任务首次进入或因新信息重新进入待决时发出；读取存档绝不补发。
signal broadcast_decision_required(task: Dictionary)
signal player_broadcast_sent(record: Dictionary)
signal world_signal_committed(record: Dictionary)
signal actor_signal_perceived(actor_id: String, signal_id: String)
signal world_delivery_committed(record: Dictionary)
signal world_delivery_queued(record: Dictionary)
signal world_delivery_rejected(record: Dictionary)
signal task_state_changed(task_id: String, status: String)
signal interaction_outcome_committed(record: Dictionary)
signal dialogue_changed(snapshot: Dictionary)
signal agent_turn_committed(record: Dictionary)
signal interaction_state_changed(event_id: String)
signal statement_revealed(statement: Dictionary)
signal fact_confirmed(fact: Dictionary)
signal computer_entries_changed(category: String)

var _scheduler: EventScheduler = EventScheduler.new()
var _condition_state_by_id: Dictionary = {}
## 内容中声明的所有条件均在此集合中占位，即使当前为 false；这使存档不会因
## “缺字段即 false”而吞掉内容差异。
var _declared_condition_ids: Dictionary = {}
var _game_clock: Node = null
var _phone_system: RefCounted = null
var _current_game_tick: int = 0
var _current_minute: int = 0
var _is_ending_forced: bool = false
var _unauthorized_broadcast_record: Dictionary = {}
## 使用显式 preload 的 RefCounted 接口，不能依赖编辑器先刷新 class_name 缓存。
var _broadcast_system: RefCounted = BROADCAST_SYSTEM_SCRIPT.new()
## ComputerSystem 仅持有来源解锁/已读；陈述和事实状态仍由本类唯一确认。
var _computer_system: RefCounted = COMPUTER_SYSTEM_SCRIPT.new()
var _signal_system: RefCounted = SIGNAL_SYSTEM_SCRIPT.new()
var _delivery_system: RefCounted = DELIVERY_SYSTEM_SCRIPT.new()
var _task_system: RefCounted = TASK_SYSTEM_SCRIPT.new()
var _interaction_outcome_system: RefCounted = INTERACTION_OUTCOME_SYSTEM_SCRIPT.new()
var _is_test_story_configured: bool = false
var _story_event_by_id: Dictionary = {}
var _message_by_id: Dictionary = {}
var _broadcast_task_by_id: Dictionary = {}
var _statement_by_id: Dictionary = {}
var _fact_by_id: Dictionary = {}
var _revealed_statement_ids: Dictionary = {}
var _confirmed_fact_ids: Dictionary = {}
var _dialogue_node_by_id: Dictionary = {}
var _active_dialogue_event_id: String = ""
var _active_dialogue_node_id: String = ""
var _completed_dialogue_event_ids: Dictionary = {}
## Agent Dialogue v2 的内容与互动事实。旧 dialogue 字段仅在迁移期服务 v1 smoke，
## 正式 v2 gameplay 不读取它们。
var _actor_definition_by_id: Dictionary = {}
var _answered_interaction_event_ids: Dictionary = {}
var _completed_interaction_event_ids: Dictionary = {}
var _committed_agent_turn_keys: Dictionary = {}
var _active_agent_session_id: String = ""
var _active_agent_event_id: String = ""
var _active_agent_actor_id: String = ""
var _active_agent_last_speech_act: String = ""
var _active_agent_asserted_claim_ids: Array[String] = []
## task_id -> { status, available_information_item_ids }。这是“此刻必须处理/已推迟/已放弃”
## 的唯一权威，不由 UI 以通知是否显示来推断。
var _broadcast_decision_by_task_id: Dictionary = {}


func _init() -> void:
	_scheduler.event_ready.connect(_on_scheduler_event_ready)
	_scheduler.event_queued.connect(_on_scheduler_event_queued)
	_scheduler.event_expired.connect(_on_scheduler_event_expired)
	_scheduler.scheduler_error.connect(_on_scheduler_error)
	_broadcast_system.connect(&"publication_state_changed", Callable(self, "_on_broadcast_publication_state_changed"))
	_broadcast_system.connect(&"player_broadcast_sent", Callable(self, "_on_player_broadcast_sent"))
	_broadcast_system.connect(&"broadcast_error", Callable(self, "_on_broadcast_error"))
	_computer_system.connect(&"entries_changed", Callable(self, "_on_computer_entries_changed"))
	_computer_system.connect(&"source_unlocked", Callable(self, "_on_computer_source_unlocked"))
	_computer_system.connect(&"source_read", Callable(self, "_on_computer_source_read"))
	_signal_system.connect(&"signal_committed", Callable(self, "_on_world_signal_committed"))
	_signal_system.connect(&"actor_signal_perceived", Callable(self, "_on_actor_signal_perceived"))
	_delivery_system.connect(&"delivery_committed", Callable(self, "_on_delivery_committed"))
	_delivery_system.connect(&"delivery_queued", Callable(self, "_on_delivery_queued"))
	_delivery_system.connect(&"delivery_rejected", Callable(self, "_on_delivery_rejected"))
	var delivery_computer_bind: Variant = _delivery_system.call(&"set_computer_system", _computer_system)
	if not delivery_computer_bind is Dictionary or not bool((delivery_computer_bind as Dictionary).get("ok", false)):
		push_error("[剧情] DeliverySystem 未能绑定 ComputerSystem authority。")


## 注入 GameClock。只依赖稳定信号和 get_current_game_tick()，不硬编码节点路径。
func connect_game_clock(game_clock: Node) -> Dictionary:
	if not is_instance_valid(game_clock):
		return _make_error("invalid_game_clock", "GameClock 实例无效。")
	if not game_clock.has_signal(&"game_time_advanced") or not game_clock.has_signal(&"ending_time_reached"):
		return _make_error("invalid_game_clock_contract", "GameClock 缺少 game_time_advanced 或 ending_time_reached 信号。")
	if not game_clock.has_method(&"get_current_game_tick"):
		return _make_error("invalid_game_clock_contract", "GameClock 缺少 get_current_game_tick() 方法。")

	_disconnect_game_clock()
	_game_clock = game_clock
	var time_callback: Callable = Callable(self, "_on_game_time_advanced")
	var ending_callback: Callable = Callable(self, "_on_ending_time_reached")
	var time_result: Error = _game_clock.connect(&"game_time_advanced", time_callback)
	if time_result != OK:
		_game_clock = null
		return _make_error("game_clock_connect_failed", "无法连接 GameClock 的 game_time_advanced 信号。")
	var ending_result: Error = _game_clock.connect(&"ending_time_reached", ending_callback)
	if ending_result != OK:
		_game_clock.disconnect(&"game_time_advanced", time_callback)
		_game_clock = null
		return _make_error("game_clock_connect_failed", "无法连接 GameClock 的 ending_time_reached 信号。")

	var tick_value: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_value) != TYPE_INT:
		_disconnect_game_clock()
		return _make_error("invalid_game_clock_tick", "GameClock.get_current_game_tick() 必须返回整数 tick。")
	return advance_to_game_tick(int(tick_value))


## 注入电话状态机。要求 PhoneSystem 提供约定的公开方法，避免场景节点耦合。
func set_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("invalid_phone_system", "PhoneSystem 实例不能为空。")
	var required_methods: PackedStringArray = [
		"begin_incoming_call",
		"force_end_at_0200",
		"is_busy",
		"advance_to_tick",
		"record_expired_call",
	]
	for method_name: String in required_methods:
		if not phone_system.has_method(method_name):
			return _make_error("invalid_phone_system_contract", "PhoneSystem 缺少 %s() 方法。" % method_name)
	_disconnect_phone_system()
	_phone_system = phone_system
	if _phone_system.has_signal(&"call_became_idle"):
		var idle_callback: Callable = Callable(self, "_on_phone_became_idle")
		if not _phone_system.is_connected(&"call_became_idle", idle_callback):
			var connect_result: Error = _phone_system.connect(&"call_became_idle", idle_callback)
			if connect_result != OK:
				_phone_system = null
				return _make_error("phone_signal_connect_failed", "无法连接 PhoneSystem 的 call_became_idle 信号。")
	if _phone_system.has_signal(&"state_changed"):
		var state_callback: Callable = Callable(self, "_on_phone_state_changed")
		if not _phone_system.is_connected(&"state_changed", state_callback):
			var state_connect_result: Error = _phone_system.connect(&"state_changed", state_callback)
			if state_connect_result != OK:
				_disconnect_phone_system()
				_phone_system = null
				return _make_error("phone_signal_connect_failed", "无法连接 PhoneSystem 的 state_changed 信号。")
	if _phone_system.has_signal(&"call_record_created"):
		var record_callback: Callable = Callable(self, "_on_phone_call_record_created")
		if not _phone_system.is_connected(&"call_record_created", record_callback):
			var record_connect_result: Error = _phone_system.connect(&"call_record_created", record_callback)
			if record_connect_result != OK:
				_disconnect_phone_system()
				_phone_system = null
				return _make_error("phone_signal_connect_failed", "无法连接 PhoneSystem 的 call_record_created 信号。")
	var computer_phone_result_value: Variant = _computer_system.call(&"set_phone_system", _phone_system)
	if not computer_phone_result_value is Dictionary or not bool((computer_phone_result_value as Dictionary).get("ok", false)):
		return _make_error("computer_phone_bind_failed", "ComputerSystem 未能绑定 PhoneSystem 来电记录。")
	var delivery_phone_result_value: Variant = _delivery_system.call(&"set_phone_system", _phone_system)
	if not delivery_phone_result_value is Dictionary or not bool((delivery_phone_result_value as Dictionary).get("ok", false)):
		return _make_error("delivery_phone_bind_failed", "DeliverySystem 未能绑定 PhoneSystem authority。")
	return {"ok": true}


## 配置第五阶段完整测试剧情。调用方必须先通过
## ContentValidator.validate_test_night_story()；本方法仍在边界处检查必要形状，
## 避免未经校验的任意 Dictionary 扩散进 StoryEngine。
func configure_test_night_story(content: Dictionary) -> Dictionary:
	if _is_test_story_configured:
		return _make_error("story_already_configured", "测试剧情已配置，不能在同一局中覆盖权威内容。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能配置测试剧情。")
	# 此公共入口自行重跑完整严格校验，避免任意调用方跳过 Main 的启动校验后
	# 让一半事件或一半广播稿进入运行时。
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_value: Variant = validator.call(&"validate_test_night_story", content, "memory://story_engine_config")
	if not validation_value is Dictionary:
		return _make_error("invalid_content_validator_result", "ContentValidator.validate_test_night_story() 必须返回带 ok 的 Dictionary。")
	var validation: Dictionary = validation_value as Dictionary
	if not bool(validation.get("ok", false)):
		return _make_error("invalid_story_content", "测试剧情运行时校验失败：%s" % String(validation.get("message", "未知错误。")))
	var checked_content: Dictionary = validation
	if checked_content.has("actors"):
		return _configure_agent_story_v2(checked_content)
	for field_name: String in ["events", "checklist_entries", "news_entries", "messages", "broadcast_tasks", "dialogue_nodes", "statements", "facts"]:
		if not checked_content.has(field_name) or typeof(checked_content[field_name]) != TYPE_ARRAY:
			return _make_error("invalid_story_content", "测试剧情缺少已校验数组字段：%s。" % field_name)
	var next_event_by_id: Dictionary = {}
	var next_message_by_id: Dictionary = {}
	var next_dialogue_node_by_id: Dictionary = {}
	var next_statement_by_id: Dictionary = {}
	var next_fact_by_id: Dictionary = {}
	var next_broadcast_task_by_id: Dictionary = {}
	var next_declared_condition_ids: Dictionary = {}
	for raw_event: Variant in checked_content["events"] as Array:
		if not raw_event is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 events 中包含非对象项目。")
		var event_data: Dictionary = raw_event as Dictionary
		if not event_data.has("id") or not event_data.has("dialogue_start_id"):
			return _make_error("invalid_story_content", "测试剧情事件缺少 id 或 dialogue_start_id。")
		var event_id: String = String(event_data["id"])
		if next_event_by_id.has(event_id):
			return _make_error("invalid_story_content", "测试剧情 events 中出现重复 ID。")
		next_event_by_id[event_id] = event_data.duplicate(true)
		for raw_condition_id: Variant in event_data.get("condition_ids", []) as Array:
			next_declared_condition_ids[String(raw_condition_id)] = true
	for raw_message: Variant in checked_content["messages"] as Array:
		if not raw_message is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 messages 中包含非对象项目。")
		var message: Dictionary = raw_message as Dictionary
		if not message.has("id") or not message.has("unlock_minute"):
			return _make_error("invalid_story_content", "测试剧情短信缺少 id 或 unlock_minute。")
		var message_id: String = String(message["id"])
		if next_message_by_id.has(message_id):
			return _make_error("invalid_story_content", "测试剧情 messages 中出现重复 ID。")
		next_message_by_id[message_id] = message.duplicate(true)
	for raw_node: Variant in checked_content["dialogue_nodes"] as Array:
		if not raw_node is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 dialogue_nodes 中包含非对象项目。")
		var node: Dictionary = raw_node as Dictionary
		if not node.has("id"):
			return _make_error("invalid_story_content", "测试剧情对话节点缺少 id。")
		var node_id: String = String(node["id"])
		if next_dialogue_node_by_id.has(node_id):
			return _make_error("invalid_story_content", "测试剧情 dialogue_nodes 中出现重复 ID。")
		next_dialogue_node_by_id[node_id] = node.duplicate(true)
	for raw_statement: Variant in checked_content["statements"] as Array:
		if not raw_statement is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 statements 中包含非对象项目。")
		var statement: Dictionary = raw_statement as Dictionary
		if not statement.has("id"):
			return _make_error("invalid_story_content", "测试剧情陈述缺少 id。")
		var statement_id: String = String(statement["id"])
		if next_statement_by_id.has(statement_id):
			return _make_error("invalid_story_content", "测试剧情 statements 中出现重复 ID。")
		next_statement_by_id[statement_id] = statement.duplicate(true)
	for raw_fact: Variant in checked_content["facts"] as Array:
		if not raw_fact is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 facts 中包含非对象项目。")
		var fact: Dictionary = raw_fact as Dictionary
		if not fact.has("id"):
			return _make_error("invalid_story_content", "测试剧情事实缺少 id。")
		var fact_id: String = String(fact["id"])
		if next_fact_by_id.has(fact_id):
			return _make_error("invalid_story_content", "测试剧情 facts 中出现重复 ID。")
		next_fact_by_id[fact_id] = fact.duplicate(true)
	for raw_task: Variant in checked_content["broadcast_tasks"] as Array:
		if not raw_task is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 broadcast_tasks 中包含非对象项目。")
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = String(task["id"])
		if next_broadcast_task_by_id.has(task_id):
			return _make_error("invalid_story_content", "测试剧情 broadcast_tasks 中出现重复 ID。")
		next_broadcast_task_by_id[task_id] = task.duplicate(true)
		var task_condition_id: String = String(task.get("sets_condition_id", ""))
		if not task_condition_id.is_empty():
			next_declared_condition_ids[task_condition_id] = true
	# 到这里尚未写入任何 StoryEngine 或 BroadcastSystem 内容。所有轻量边界检查
	# 成功后才登记事件、配置广播稿并一次性提交运行时映射。
	var computer_result_value: Variant = _computer_system.call(
		&"configure_content",
		checked_content["checklist_entries"],
		checked_content["news_entries"],
		checked_content["messages"]
	)
	if not computer_result_value is Dictionary or not bool((computer_result_value as Dictionary).get("ok", false)):
		return _make_error("computer_content_config_failed", "ComputerSystem 未能配置已校验的信息来源。")
	var dynamic_sources_value: Variant = _computer_system.call(&"configure_dynamic_message_sources", [])
	if not dynamic_sources_value is Dictionary or not bool((dynamic_sources_value as Dictionary).get("ok", false)):
		return _make_error("computer_dynamic_sources_config_failed", "ComputerSystem 未能配置空动态消息来源集合。")
	var delivery_config_value: Variant = _delivery_system.call(&"configure", [], checked_content["events"] as Array)
	if not delivery_config_value is Dictionary or not bool((delivery_config_value as Dictionary).get("ok", false)):
		return _make_error("delivery_content_config_failed", "DeliverySystem 未能配置 legacy 空 Actor 集合。")
	var schedule_result: Dictionary = schedule_events(checked_content["events"] as Array)
	if not bool(schedule_result.get("ok", false)):
		return schedule_result
	var broadcast_tasks: Array = checked_content["broadcast_tasks"] as Array
	var broadcast_result_value: Variant = _broadcast_system.call(&"configure_tasks", broadcast_tasks)
	if not broadcast_result_value is Dictionary:
		return _make_error("invalid_broadcast_system_result", "BroadcastSystem.configure_tasks() 必须返回带 ok 的 Dictionary。")
	var broadcast_result: Dictionary = broadcast_result_value as Dictionary

	var signal_config_value: Variant = _signal_system.call(&"configure", [], broadcast_tasks)
	if not signal_config_value is Dictionary or not bool((signal_config_value as Dictionary).get("ok", false)):
		return _make_error("signal_content_config_failed", "SignalSystem 未能配置已校验的 v1 广播来源。")
	var task_config_value: Variant = _task_system.call(&"configure", _build_task_definitions(broadcast_tasks))
	if not task_config_value is Dictionary or not bool((task_config_value as Dictionary).get("ok", false)):
		return _make_error("task_content_config_failed", "TaskSystem 未能配置 legacy 发布任务：%s" % _snapshot_message(task_config_value))
	var outcome_config_value: Variant = _interaction_outcome_system.call(&"configure", [])
	if not outcome_config_value is Dictionary or not bool((outcome_config_value as Dictionary).get("ok", false)):
		return _make_error("interaction_outcome_config_failed", "InteractionOutcomeSystem 未能配置 legacy 空 Actor authority。")
	if not bool(broadcast_result.get("ok", false)):
		return broadcast_result
	_story_event_by_id = next_event_by_id
	_message_by_id = next_message_by_id
	_broadcast_task_by_id = next_broadcast_task_by_id
	_declared_condition_ids = next_declared_condition_ids
	_condition_state_by_id = {}
	for condition_id_variant: Variant in _declared_condition_ids:
		_condition_state_by_id[String(condition_id_variant)] = false
	_dialogue_node_by_id = next_dialogue_node_by_id
	_statement_by_id = next_statement_by_id
	_fact_by_id = next_fact_by_id
	_is_test_story_configured = true
	for fact_id_variant: Variant in _fact_by_id.keys():
		var configured_fact: Dictionary = _fact_by_id[fact_id_variant] as Dictionary
		if bool(configured_fact["initially_confirmed"]):
			_confirm_fact(String(fact_id_variant))
	var initial_computer_advance_value: Variant = _computer_system.call(&"advance_to_minute", _current_minute)
	if not initial_computer_advance_value is Dictionary or not bool((initial_computer_advance_value as Dictionary).get("ok", false)):
		return _make_error("computer_initial_advance_failed", "ComputerSystem 未能解锁开局电脑信息。")
	_refresh_broadcast_decisions(false)
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	return {"ok": true, "event_count": _story_event_by_id.size()}


func _configure_agent_story_v2(checked_content: Dictionary) -> Dictionary:
	for field_name: String in ["events", "checklist_entries", "news_entries", "messages", "broadcast_tasks", "actors", "statements", "facts"]:
		if not checked_content.has(field_name) or not checked_content[field_name] is Array:
			return _make_error("invalid_story_content", "Agent Dialogue v2 剧情缺少已校验数组字段：%s。" % field_name)
	var next_event_by_id: Dictionary = {}
	var next_message_by_id: Dictionary = {}
	var next_statement_by_id: Dictionary = {}
	var next_fact_by_id: Dictionary = {}
	var next_broadcast_task_by_id: Dictionary = {}
	var next_actor_by_id: Dictionary = {}
	var next_declared_condition_ids: Dictionary = {}
	for raw_condition: Variant in checked_content.get("conditions", []) as Array:
		if raw_condition is Dictionary:
			next_declared_condition_ids[String((raw_condition as Dictionary).get("id", ""))] = true
	for raw_event: Variant in checked_content["events"] as Array:
		var event_data: Dictionary = raw_event as Dictionary
		var event_id: String = String(event_data["id"])
		next_event_by_id[event_id] = event_data.duplicate(true)
		for raw_condition_id: Variant in event_data.get("condition_ids", []) as Array:
			next_declared_condition_ids[String(raw_condition_id)] = true
	for raw_actor: Variant in checked_content["actors"] as Array:
		var actor: Dictionary = raw_actor as Dictionary
		next_actor_by_id[String(actor["id"])] = actor.duplicate(true)
	for raw_message: Variant in checked_content["messages"] as Array:
		var message: Dictionary = raw_message as Dictionary
		next_message_by_id[String(message["id"])] = message.duplicate(true)
	for raw_statement: Variant in checked_content["statements"] as Array:
		var statement: Dictionary = raw_statement as Dictionary
		next_statement_by_id[String(statement["id"])] = statement.duplicate(true)
	for raw_fact: Variant in checked_content["facts"] as Array:
		var fact: Dictionary = raw_fact as Dictionary
		next_fact_by_id[String(fact["id"])] = fact.duplicate(true)
	for raw_task: Variant in checked_content["broadcast_tasks"] as Array:
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = String(task["id"])
		next_broadcast_task_by_id[task_id] = task.duplicate(true)
		var task_condition_id: String = String(task.get("sets_condition_id", ""))
		if not task_condition_id.is_empty():
			next_declared_condition_ids[task_condition_id] = true

	var computer_result_value: Variant = _computer_system.call(
		&"configure_content",
		checked_content["checklist_entries"],
		checked_content["news_entries"],
		checked_content["messages"]
	)
	if not computer_result_value is Dictionary or not bool((computer_result_value as Dictionary).get("ok", false)):
		return _make_error("computer_content_config_failed", "ComputerSystem 未能配置 Agent Dialogue v2 信息来源。")
	var dynamic_sources_value: Variant = _computer_system.call(&"configure_dynamic_message_sources", checked_content["actors"] as Array)
	if not dynamic_sources_value is Dictionary or not bool((dynamic_sources_value as Dictionary).get("ok", false)):
		return _make_error("computer_dynamic_sources_config_failed", "ComputerSystem 未能配置动态消息 Actor 来源。")
	var delivery_config_value: Variant = _delivery_system.call(&"configure", checked_content["actors"] as Array, checked_content["events"] as Array)
	if not delivery_config_value is Dictionary or not bool((delivery_config_value as Dictionary).get("ok", false)):
		return _make_error("delivery_content_config_failed", "DeliverySystem 未能配置 Agent/来电 authority。")
	var schedule_result: Dictionary = schedule_events(checked_content["events"] as Array)
	if not bool(schedule_result.get("ok", false)):
		return schedule_result
	var broadcast_result_value: Variant = _broadcast_system.call(&"configure_tasks", checked_content["broadcast_tasks"] as Array)
	if not broadcast_result_value is Dictionary or not bool((broadcast_result_value as Dictionary).get("ok", false)):
		return _make_error("broadcast_content_config_failed", "BroadcastSystem 未能配置 Agent Dialogue v2 发布任务。")
	var signal_actor_ids: Array = next_actor_by_id.keys()
	var signal_config_value: Variant = _signal_system.call(&"configure", signal_actor_ids, checked_content["broadcast_tasks"] as Array)
	if not signal_config_value is Dictionary or not bool((signal_config_value as Dictionary).get("ok", false)):
		return _make_error("signal_content_config_failed", "SignalSystem 未能配置 Agent Dialogue v2 Actor/广播来源。")
	var task_config_value: Variant = _task_system.call(&"configure", _build_task_definitions(checked_content["broadcast_tasks"] as Array))
	if not task_config_value is Dictionary or not bool((task_config_value as Dictionary).get("ok", false)):
		return _make_error("task_content_config_failed", "TaskSystem 未能配置 Agent Dialogue v2 任务 authority：%s" % _snapshot_message(task_config_value))
	var outcome_config_value: Variant = _interaction_outcome_system.call(&"configure", checked_content["actors"] as Array)
	if not outcome_config_value is Dictionary or not bool((outcome_config_value as Dictionary).get("ok", false)):
		return _make_error("interaction_outcome_config_failed", "InteractionOutcomeSystem 未能配置 Actor authority：%s" % _snapshot_message(outcome_config_value))

	_story_event_by_id = next_event_by_id
	_message_by_id = next_message_by_id
	_broadcast_task_by_id = next_broadcast_task_by_id
	_actor_definition_by_id = next_actor_by_id
	_statement_by_id = next_statement_by_id
	_fact_by_id = next_fact_by_id
	_declared_condition_ids = next_declared_condition_ids
	_condition_state_by_id = {}
	for condition_id_variant: Variant in _declared_condition_ids:
		_condition_state_by_id[String(condition_id_variant)] = false
	_dialogue_node_by_id = {}
	_active_dialogue_event_id = ""
	_active_dialogue_node_id = ""
	_completed_dialogue_event_ids = {}
	_answered_interaction_event_ids = {}
	_completed_interaction_event_ids = {}
	_committed_agent_turn_keys = {}
	_active_agent_session_id = ""
	_active_agent_event_id = ""
	_active_agent_actor_id = ""
	_active_agent_last_speech_act = ""
	_active_agent_asserted_claim_ids = []
	_is_test_story_configured = true
	for fact_id_variant: Variant in _fact_by_id.keys():
		var configured_fact: Dictionary = _fact_by_id[fact_id_variant] as Dictionary
		if bool(configured_fact["initially_confirmed"]):
			_confirm_fact(String(fact_id_variant))
	var initial_computer_advance_value: Variant = _computer_system.call(&"advance_to_minute", _current_minute)
	if not initial_computer_advance_value is Dictionary or not bool((initial_computer_advance_value as Dictionary).get("ok", false)):
		return _make_error("computer_initial_advance_failed", "ComputerSystem 未能解锁 Agent Dialogue v2 开局电脑信息。")
	_refresh_broadcast_decisions(false)
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	return {"ok": true, "event_count": _story_event_by_id.size(), "actor_count": _actor_definition_by_id.size(), "agent_dialogue_v2": true}


func schedule_event(event_data: Dictionary) -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")
	return _scheduler.schedule_event(event_data)


func schedule_events(event_definitions: Array) -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，拒绝继续调度事件。")
	return _scheduler.schedule_events(event_definitions)


## 直接按整数 tick 推进，供 GameClock 信号和 Headless 验证共同使用。
func advance_to_game_tick(current_tick: int) -> Dictionary:
	if current_tick < _current_game_tick:
		return _make_error("time_reversed", "StoryEngine 的游戏时间不能倒退。")
	if current_tick < 0:
		return _make_error("invalid_game_tick", "游戏 tick 不能小于 0。")
	if _is_ending_forced:
		_current_game_tick = current_tick
		_current_minute = current_tick / TICKS_PER_GAME_MINUTE
		return {"ok": true, "ignored_after_ending": true}

	var previous_tick: int = _current_game_tick
	_current_game_tick = current_tick
	_current_minute = current_tick / TICKS_PER_GAME_MINUTE
	if current_tick >= ENDING_TICK:
		force_ending_at_0200(ENDING_TICK)
		return {"ok": true, "forced_ending": true}

	if _is_test_story_configured:
		var computer_advance_value: Variant = _computer_system.call(&"advance_to_minute", _current_minute)
		if not computer_advance_value is Dictionary or not bool((computer_advance_value as Dictionary).get("ok", false)):
			return _make_error("computer_advance_failed", "ComputerSystem 未能推进电脑信息解锁时间。")
	_advance_phone_to_tick(current_tick)
	if not _is_phone_busy():
		_dispatch_next_queued_event()
	var processing_result: Dictionary = _scheduler.advance_to_minute(_current_minute, _is_phone_busy(), _is_condition_met)
	if not bool(processing_result["ok"]):
		return processing_result
	story_time_advanced.emit(previous_tick, _current_game_tick, _current_minute)
	return processing_result


## 由电话状态机空闲信号或集成方显式调用。
func dispatch_next_queued_event_if_idle() -> Dictionary:
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能派发队列事件。")
	if _is_phone_busy():
		return {"ok": true, "dispatched": false, "reason": "phone_busy"}
	return _dispatch_next_queued_event()


func force_ending_at_0200(end_tick: int = ENDING_TICK) -> Dictionary:
	if _is_ending_forced:
		return {"ok": true, "already_forced": true}
	if end_tick != ENDING_TICK:
		return _make_error("invalid_ending_tick", "ending_forced 必须使用精确的 02:00 tick（3600）。")

	_is_ending_forced = true
	_clear_active_dialogue()
	_current_game_tick = max(_current_game_tick, end_tick)
	_current_minute = _current_game_tick / TICKS_PER_GAME_MINUTE
	# 02:00 同样是一个真实的整数分钟边界。若不先推进电脑来源，结尾快照会
	# 把剧情写在 60 分钟而电脑停在上一分钟，读取时只能靠错误默认值掩盖。
	if _is_test_story_configured:
		var computer_advance_value: Variant = _computer_system.call(&"advance_to_minute", _current_minute)
		if not computer_advance_value is Dictionary or not bool((computer_advance_value as Dictionary).get("ok", false)):
			return _make_error("computer_ending_advance_failed", "02:00 时 ComputerSystem 未能推进到结束分钟。")
	var scheduler_result: Dictionary = _scheduler.force_ending()
	if not bool(scheduler_result["ok"]):
		return scheduler_result
	_unauthorized_broadcast_record = {
		"broadcast_id": "broadcast_unauthorized_north_bridge_open",
		"fact_id": "fact_unauthorized_broadcast",
		"sent_at_tick": end_tick,
		"time_tick": end_tick,
		"source": "Studio A",
		"body": "北桥已经恢复通行。请保持车速，不要停车。",
		"is_unauthorized": true,
	}
	_unauthorized_broadcast_record.make_read_only()
	# Studio A 的未授权播出以及其成因未知，都是 02:00 权威事件本身确认的
	# 结尾事实。艾米的来电只能揭示“她听见了什么”，不能抢先确认电台发生了什么。
	for fact_id: String in ENDING_ONLY_FACT_IDS:
		_confirm_fact(fact_id)
	# queued Delivery 只是已经批准但尚未进入电话世界的决定。02:00 必须先取消它们，
	# 否则 PhoneSystem force_end 触发 idle 信号时可能把队头动态来电重新启动。
	var delivery_cancel_value: Variant = _delivery_system.call(&"cancel_queued_deliveries", end_tick)
	if not delivery_cancel_value is Dictionary or not bool((delivery_cancel_value as Dictionary).get("ok", false)):
		return _make_error("delivery_force_end_failed", "02:00 时 DeliverySystem 未能取消 queued delivery。")
	var phone_force_failed: bool = false
	if _phone_system != null:
		var phone_result: Variant = _phone_system.call(&"force_end_at_0200", end_tick)
		if typeof(phone_result) == TYPE_BOOL:
			phone_force_failed = not bool(phone_result)
		elif typeof(phone_result) == TYPE_DICTIONARY:
			phone_force_failed = not bool((phone_result as Dictionary).get("ok", false))
		else:
			phone_force_failed = true
	ending_forced.emit(end_tick)
	print("[剧情][ending_forced] 02:00 强制收束已执行。")
	if phone_force_failed:
		return _make_error("phone_force_end_failed", "PhoneSystem 未能在 02:00 终止当前线路。")
	return {"ok": true, "already_forced": false}


func set_condition_state(condition_id: String, is_met: bool) -> Dictionary:
	if condition_id.is_empty() or condition_id.begins_with("_") or condition_id != condition_id.to_lower() or not condition_id.is_valid_identifier() or not condition_id.is_valid_ascii_identifier():
		return _make_error("invalid_condition_id", "条件 ID 必须是英文 snake_case 标识符。")
	if _is_test_story_configured and not _declared_condition_ids.has(condition_id):
		return _make_error("unknown_condition_id", "当前内容没有声明该条件 ID。")
	_condition_state_by_id[condition_id] = is_met
	if _is_test_story_configured:
		var task_refresh: Dictionary = _refresh_task_system()
		if not bool(task_refresh.get("ok", false)):
			return task_refresh
	return {"ok": true}


func is_condition_met(condition_id: String) -> bool:
	return _is_condition_met(condition_id)


func is_ending_forced() -> bool:
	return _is_ending_forced


func get_current_game_tick() -> int:
	return _current_game_tick


func get_current_minute() -> int:
	return _current_minute


func is_agent_dialogue_v2() -> bool:
	return _is_test_story_configured and not _actor_definition_by_id.is_empty()


func get_actor_definitions() -> Array[Dictionary]:
	var actors: Array[Dictionary] = []
	for actor_id: String in _sorted_dictionary_keys(_actor_definition_by_id):
		var actor: Dictionary = (_actor_definition_by_id[actor_id] as Dictionary).duplicate(true)
		actor.make_read_only()
		actors.append(actor)
	return actors


## 只返回当前线路 Actor 可见的作者数据。Statement body 是 claim 的权威 meaning；
## Actor 不能通过该接口看到其它来电、未来事件或全局 Fact 真相。
func get_active_agent_call_context() -> Dictionary:
	if not is_agent_dialogue_v2():
		return _make_error("agent_dialogue_not_configured", "当前剧情未启用 Agent Dialogue v2。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 已强制收束，不能构建 Agent call context。")
	if _phone_system == null or not _phone_system.has_method(&"get_active_event_id") or not _phone_system.has_method(&"get_state_name"):
		return _make_error("phone_contract_invalid", "Agent call context 需要 PhoneSystem 活动事件与状态接口。")
	var event_id_value: Variant = _phone_system.call(&"get_active_event_id")
	var state_name_value: Variant = _phone_system.call(&"get_state_name")
	if not event_id_value is String or not state_name_value is String:
		return _make_error("phone_contract_invalid", "PhoneSystem 返回的活动事件或状态无效。")
	var event_id: String = String(event_id_value)
	if event_id.is_empty():
		return _make_error("agent_call_event_missing", "当前线路没有可用于 Agent Dialogue 的剧情事件。")
	if String(state_name_value) != "DIALOGUE_CHOICE":
		return _make_error("agent_call_state_invalid", "Agent Dialogue 只在 PhoneSystem 的 DIALOGUE_CHOICE 等待状态工作。")
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		return event_result
	var event_data: Dictionary = event_result["event"] as Dictionary
	if not event_data.has("actor_id") or not event_data.has("available_statement_ids"):
		return _make_error("agent_call_event_invalid", "当前事件缺少 Agent Dialogue v2 字段。")
	var actor_id: String = String(event_data["actor_id"])
	if not _actor_definition_by_id.has(actor_id):
		return _make_error("agent_call_actor_missing", "当前来电引用不存在的 Actor：%s。" % actor_id)
	var disclosable_claims: Array[Dictionary] = []
	for raw_statement_id: Variant in event_data["available_statement_ids"] as Array:
		var statement_id: String = String(raw_statement_id)
		if not _statement_by_id.has(statement_id):
			return _make_error("agent_call_statement_missing", "当前来电引用不存在的 Statement：%s。" % statement_id)
		var statement: Dictionary = _statement_by_id[statement_id] as Dictionary
		if String(statement.get("source_id", "")) != event_id:
			return _make_error("agent_call_statement_source_mismatch", "当前来电只能披露来源属于自身事件的 Statement。")
		var claim: Dictionary = {
			"id": statement_id,
			"meaning": String(statement["body"]),
		}
		if statement.has("semantic_guard"):
			claim["semantic_guard"] = (statement["semantic_guard"] as Dictionary).duplicate(true)
		disclosable_claims.append(claim)
	var fallback_turn: Dictionary = {
		"speech_act": "end_call",
		"utterance": String(event_data.get("fallback_utterance", "线路里只剩下一阵杂音，对方很快挂断了。")),
		"asserted_claim_ids": [],
		"withheld_claim_ids": [],
		"session_intent": "end",
		"world_action": null,
	}
	return {
		"ok": true,
		"event_id": event_id,
		"actor_id": actor_id,
		"caller_display_name": String(event_data.get("caller_display_name", "")),
		"call_reason": String(event_data.get("call_reason", "")),
		"opening_intent": String(event_data.get("opening_intent", "")),
		"disclosable_claims": disclosable_claims,
		"world_constraints": {
			"current_game_tick": _current_game_tick,
			"ending_tick": ENDING_TICK,
			"channel": "phone",
			"event_id": event_id,
		},
		"deterministic_fallback_turn": fallback_turn,
	}


## ConversationSession 建立后由 InteractionCoordinator 调用。事件级 patch 是作者规则，
## 只返回给 AgentRuntime 更新 Actor canonical state；本方法本身不让模型维护状态。
func begin_agent_interaction(session_id: String, event_id: String, actor_id: String) -> Dictionary:
	if not is_agent_dialogue_v2():
		return _make_error("agent_dialogue_not_configured", "当前剧情未启用 Agent Dialogue v2。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 后不能开始 Agent interaction。")
	if session_id.strip_edges().is_empty() or event_id.strip_edges().is_empty() or actor_id.strip_edges().is_empty():
		return _make_error("agent_interaction_id_invalid", "session_id/event_id/actor_id 必须非空。")
	if not _active_agent_session_id.is_empty():
		return _make_error("agent_interaction_already_active", "当前已经存在活动 Agent interaction。")
	var line_result: Dictionary = _validate_agent_phone_event(event_id, actor_id)
	if not bool(line_result.get("ok", false)):
		return line_result
	_active_agent_session_id = session_id
	_active_agent_event_id = event_id
	_active_agent_actor_id = actor_id
	_active_agent_last_speech_act = ""
	_active_agent_asserted_claim_ids = []
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		_active_agent_session_id = ""
		_active_agent_event_id = ""
		_active_agent_actor_id = ""
		_active_agent_last_speech_act = ""
		_active_agent_asserted_claim_ids = []
		return event_result
	var event_data: Dictionary = event_result["event"] as Dictionary
	var state_patch: Dictionary = {}
	if event_data.has("session_state_patch"):
		state_patch = (event_data["session_state_patch"] as Dictionary).duplicate(true)
	interaction_state_changed.emit(event_id)
	return {"ok": true, "state_patch": state_patch}


## TurnSemanticGuard 的 world-specific read-only validator。claim 白名单已经在 AgentRuntime
## 校验，这里再次以 StoryEngine 的来源权验证当前事件，防止绕过协调器直接提交。
func validate_agent_turn_semantics(actor_turn: Dictionary, matched_claims: Array) -> Dictionary:
	if _active_agent_session_id.is_empty() or _active_agent_event_id.is_empty():
		return _make_error("agent_interaction_inactive", "没有活动 Agent interaction 可验证 ActorTurn。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 后 ActorTurn 一律失效。")
	for raw_claim: Variant in matched_claims:
		if not raw_claim is Dictionary:
			return _make_error("agent_turn_claim_invalid", "语义校验收到无效 claim 定义。")
		var claim: Dictionary = raw_claim as Dictionary
		var statement_id: String = String(claim.get("id", ""))
		if not _statement_by_id.has(statement_id):
			return _make_error("agent_turn_unknown_statement", "ActorTurn 引用了 StoryEngine 不存在的 Statement。")
		var statement: Dictionary = _statement_by_id[statement_id] as Dictionary
		if String(statement.get("source_id", "")) != _active_agent_event_id:
			return _make_error("agent_turn_statement_source_invalid", "ActorTurn 试图披露不属于当前来电来源的 Statement。")
	if not actor_turn.has("utterance") or not actor_turn["utterance"] is String or String(actor_turn["utterance"]).strip_edges().is_empty():
		return _make_error("agent_turn_utterance_invalid", "ActorTurn utterance 必须是非空字符串。")
	return {"ok": true}


## Agent Dialogue 的唯一世界提交入口。它只接受当前 active call/session 的已验证 Turn，
## 再由 StoryEngine 揭示 Statement、派生 Fact、刷新 Task；LLM 永远不直接写这些字典。
func commit_agent_turn(request: Dictionary) -> Dictionary:
	if not is_agent_dialogue_v2():
		return _make_error("agent_dialogue_not_configured", "当前剧情未启用 Agent Dialogue v2。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 后不能提交 ActorTurn。")
	for field_name: String in ["session_id", "event_id", "actor_id", "request_serial", "turn_index", "actor_turn"]:
		if not request.has(field_name):
			return _make_error("agent_turn_request_invalid", "commit_agent_turn 缺少字段：%s。" % field_name)
	if not request["session_id"] is String or not request["event_id"] is String or not request["actor_id"] is String:
		return _make_error("agent_turn_request_invalid", "commit_agent_turn 的 session/event/actor ID 必须为字符串。")
	if typeof(request["request_serial"]) != TYPE_INT or int(request["request_serial"]) <= 0 or typeof(request["turn_index"]) != TYPE_INT or int(request["turn_index"]) < 0:
		return _make_error("agent_turn_request_invalid", "request_serial 必须 > 0，turn_index 必须 >= 0。")
	if not request["actor_turn"] is Dictionary:
		return _make_error("agent_turn_request_invalid", "actor_turn 必须是对象。")
	var session_id: String = String(request["session_id"])
	var event_id: String = String(request["event_id"])
	var actor_id: String = String(request["actor_id"])
	if session_id != _active_agent_session_id or event_id != _active_agent_event_id or actor_id != _active_agent_actor_id:
		return _make_error("agent_turn_session_mismatch", "ActorTurn 不属于当前活动 Agent interaction。")
	var line_result: Dictionary = _validate_agent_phone_event(event_id, actor_id)
	if not bool(line_result.get("ok", false)):
		return line_result
	var commit_key: String = "%s:%d" % [session_id, int(request["request_serial"])]
	if _committed_agent_turn_keys.has(commit_key):
		return _make_error("agent_turn_duplicate_commit", "同一模型响应不能重复提交。")
	var actor_turn: Dictionary = request["actor_turn"] as Dictionary
	if not actor_turn.has("asserted_claim_ids") or not actor_turn["asserted_claim_ids"] is Array:
		return _make_error("agent_turn_claims_invalid", "ActorTurn 缺少 asserted_claim_ids。")
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		return event_result
	var event_data: Dictionary = event_result["event"] as Dictionary
	var allowed_statement_ids: Array = event_data["available_statement_ids"] as Array
	var asserted_ids: Array[String] = []
	for raw_statement_id: Variant in actor_turn["asserted_claim_ids"] as Array:
		if not raw_statement_id is String:
			return _make_error("agent_turn_claims_invalid", "asserted_claim_ids 只能包含字符串。")
		var statement_id: String = String(raw_statement_id)
		if asserted_ids.has(statement_id):
			return _make_error("agent_turn_claim_duplicate", "ActorTurn 不能重复声明同一 Statement。")
		if not allowed_statement_ids.has(statement_id) or not _statement_by_id.has(statement_id):
			return _make_error("agent_turn_claim_not_disclosable", "ActorTurn 试图提交当前来电未授权的 Statement：%s。" % statement_id)
		var statement: Dictionary = _statement_by_id[statement_id] as Dictionary
		if String(statement.get("source_id", "")) != event_id:
			return _make_error("agent_turn_statement_source_invalid", "ActorTurn Statement 来源与当前来电不一致。")
		asserted_ids.append(statement_id)
	var reveal_result: Dictionary = _reveal_statement_ids(asserted_ids, event_id)
	if not bool(reveal_result.get("ok", false)):
		return reveal_result
	_committed_agent_turn_keys[commit_key] = true
	_answered_interaction_event_ids[event_id] = true
	_active_agent_last_speech_act = String(actor_turn.get("speech_act", ""))
	_active_agent_asserted_claim_ids = asserted_ids.duplicate()
	var record: Dictionary = {
		"session_id": session_id,
		"event_id": event_id,
		"actor_id": actor_id,
		"request_serial": int(request["request_serial"]),
		"turn_index": int(request["turn_index"]),
		"asserted_claim_ids": asserted_ids.duplicate(),
		"speech_act": String(actor_turn.get("speech_act", "")),
		"session_intent": String(actor_turn.get("session_intent", "continue")),
	}
	agent_turn_committed.emit(record.duplicate(true))
	interaction_state_changed.emit(event_id)
	_refresh_broadcast_decisions(true)
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	return {"ok": true, "record": record, "newly_revealed_statement_ids": reveal_result.get("newly_revealed_statement_ids", [])}


func complete_agent_interaction(session_id: String, event_id: String, reason: String) -> Dictionary:
	if session_id != _active_agent_session_id or event_id != _active_agent_event_id:
		return _make_error("agent_interaction_session_mismatch", "结束请求不属于当前 Agent interaction。")
	if reason.strip_edges().is_empty():
		return _make_error("agent_interaction_reason_invalid", "结束 Agent interaction 必须提供原因。")
	var actor_id: String = _active_agent_actor_id
	var outcome_input: Dictionary = {
		"event_id": event_id,
		"session_id": session_id,
		"actor_id": actor_id,
		"terminal_reason": reason,
		"last_speech_act": _active_agent_last_speech_act,
		"asserted_claim_ids": _active_agent_asserted_claim_ids.duplicate(),
		"created_at_tick": _current_game_tick,
	}
	var outcome_value: Variant = _interaction_outcome_system.call(&"commit_interaction_outcome", outcome_input)
	if not outcome_value is Dictionary or not bool((outcome_value as Dictionary).get("ok", false)):
		return _make_error("interaction_outcome_commit_failed", "InteractionOutcomeSystem 未能提交交互终态：%s" % _snapshot_message(outcome_value))
	var outcome_result: Dictionary = outcome_value as Dictionary
	var outcome_record: Dictionary = outcome_result["record"] as Dictionary
	var signal_value: Variant = _signal_system.call(&"commit_interaction_outcome", outcome_record)
	if not signal_value is Dictionary or not bool((signal_value as Dictionary).get("ok", false)):
		return _make_error("interaction_outcome_signal_failed", "InteractionOutcome 已提交，但 SignalSystem 未能提交对应 Observation：%s" % _snapshot_message(signal_value))
	_completed_interaction_event_ids[event_id] = true
	_active_agent_session_id = ""
	_active_agent_event_id = ""
	_active_agent_actor_id = ""
	_active_agent_last_speech_act = ""
	_active_agent_asserted_claim_ids = []
	interaction_outcome_committed.emit(outcome_record.duplicate(true))
	interaction_state_changed.emit(event_id)
	_refresh_broadcast_decisions(true)
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	return {
		"ok": true,
		"event_id": event_id,
		"outcome_record": outcome_record.duplicate(true),
		"actor_state_patch": (outcome_result.get("actor_state_patch", {}) as Dictionary).duplicate(true),
	}


func get_interaction_state(event_id: String) -> Dictionary:
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		return {}
	return {
		"event_id": event_id,
		"answered": _answered_interaction_event_ids.has(event_id),
		"completed": _completed_interaction_event_ids.has(event_id),
	}


func _validate_agent_phone_event(event_id: String, actor_id: String) -> Dictionary:
	if _phone_system == null or not _phone_system.has_method(&"get_active_event_id") or not _phone_system.has_method(&"get_state_name") or not _phone_system.has_method(&"is_forced_ended"):
		return _make_error("phone_contract_invalid", "Agent interaction 需要 PhoneSystem 的活动事件、状态与强制结束接口。")
	if bool(_phone_system.call(&"is_forced_ended")):
		return _make_error("ending_forced", "电话线路已被 02:00 强制终止。")
	var active_event_value: Variant = _phone_system.call(&"get_active_event_id")
	var state_name_value: Variant = _phone_system.call(&"get_state_name")
	if not active_event_value is String or String(active_event_value) != event_id:
		return _make_error("agent_interaction_event_mismatch", "Agent interaction event 与当前 PhoneSystem 线路不一致。")
	if not state_name_value is String or String(state_name_value) != "DIALOGUE_CHOICE":
		return _make_error("agent_interaction_phone_state_invalid", "Agent interaction 只能在 DIALOGUE_CHOICE 状态提交。")
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		return event_result
	var event_data: Dictionary = event_result["event"] as Dictionary
	if String(event_data.get("actor_id", "")) != actor_id:
		return _make_error("agent_interaction_actor_mismatch", "当前线路事件与 Actor ID 不一致。")
	return {"ok": true}


## authored 来电直接使用 WorldBook 编译事件；delivery_call_* 则只从已经 committed 的
## DeliveryRequest 与 authored Actor identity 构造只读 synthetic context。动态来电不继承
## 原 authored event 的 Statement 白名单，避免把旧来源 Statement 偷渡到新的动态 source ID。
func _resolve_agent_event_data(event_id: String) -> Dictionary:
	if _story_event_by_id.has(event_id):
		return {"ok": true, "event": (_story_event_by_id[event_id] as Dictionary).duplicate(true), "dynamic": false}
	if not event_id.begins_with("delivery_call_"):
		return _make_error("agent_interaction_event_unknown", "Agent interaction 引用了不存在的剧情事件。")
	if _delivery_system == null or not _delivery_system.has_method(&"get_request") or not _delivery_system.has_method(&"get_call_metadata_for_delivery"):
		return _make_error("agent_dynamic_call_contract_invalid", "动态 Agent 来电需要 DeliverySystem request/call metadata 接口。")
	var request_value: Variant = _delivery_system.call(&"get_request", event_id)
	if not request_value is Dictionary or (request_value as Dictionary).is_empty():
		return _make_error("agent_dynamic_call_missing", "当前 delivery_call_* 没有真实 DeliveryRequest。")
	var request: Dictionary = request_value as Dictionary
	if String(request.get("action_id", "")) != "call_station" or String(request.get("status", "")) != "committed":
		return _make_error("agent_dynamic_call_not_committed", "动态 Agent 来电必须来自 committed call_station DeliveryRequest。")
	var actor_id: String = String(request.get("actor_id", ""))
	if not _actor_definition_by_id.has(actor_id):
		return _make_error("agent_call_actor_missing", "动态来电引用不存在的 Actor：%s。" % actor_id)
	var metadata_value: Variant = _delivery_system.call(&"get_call_metadata_for_delivery", event_id)
	if not metadata_value is Dictionary or (metadata_value as Dictionary).is_empty():
		return _make_error("agent_dynamic_call_metadata_missing", "动态来电缺少 authored caller identity。")
	var metadata: Dictionary = metadata_value as Dictionary
	if String(metadata.get("actor_id", "")) != actor_id:
		return _make_error("agent_dynamic_call_actor_mismatch", "动态来电的 Delivery actor 与 caller identity 不一致。")
	var topic: String = ""
	var arguments: Dictionary = request.get("arguments", {}) as Dictionary
	if arguments.has("topic"):
		topic = String(arguments["topic"])
	return {
		"ok": true,
		"dynamic": true,
		"event": {
			"id": event_id,
			"actor_id": actor_id,
			"available_statement_ids": [],
			"caller_display_name": String(metadata.get("caller_display_name", "")),
			"call_reason": topic,
			"opening_intent": "follow_up",
			"fallback_utterance": "线路里只剩下一阵杂音，对方很快挂断了。",
		},
	}


func get_scheduler() -> EventScheduler:
	return _scheduler


## 剧情快照只保存运行时事实与子系统状态；所有对白、新闻正文、事件定义及
## 广播稿定义仍由当前已校验内容包提供。SaveManager 必须先配置内容、恢复并绑定
## PhoneSystem，再调用本系统恢复，以便 ComputerSystem 严格引用真实来电记录。
func create_snapshot() -> Dictionary:
	var active_dialogue: Variant = null
	if not _active_dialogue_event_id.is_empty() or not _active_dialogue_node_id.is_empty():
		active_dialogue = {
			"event_id": _active_dialogue_event_id,
			"node_id": _active_dialogue_node_id,
		}
	var unauthorized_record: Variant = null
	if not _unauthorized_broadcast_record.is_empty():
		unauthorized_record = _unauthorized_broadcast_record.duplicate(true)
	var snapshot: Dictionary = {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SNAPSHOT_SYSTEM_ID,
		"current_game_tick": _current_game_tick,
		"current_minute": _current_minute,
		"condition_state_by_id": _sorted_bool_state(_condition_state_by_id),
		"revealed_statement_ids": _sorted_dictionary_keys(_revealed_statement_ids),
		"confirmed_fact_ids": _sorted_dictionary_keys(_confirmed_fact_ids),
		"completed_dialogue_event_ids": _sorted_dictionary_keys(_completed_dialogue_event_ids),
		"answered_interaction_event_ids": _sorted_dictionary_keys(_answered_interaction_event_ids),
		"completed_interaction_event_ids": _sorted_dictionary_keys(_completed_interaction_event_ids),
		"active_dialogue": active_dialogue,
		"is_ending_forced": _is_ending_forced,
		"unauthorized_broadcast_record": unauthorized_record,
		"broadcast_decisions": _create_broadcast_decisions_snapshot(),
		"scheduler": _scheduler.create_snapshot(),
		"computer": _computer_system.call(&"create_snapshot"),
		"broadcast": _broadcast_system.call(&"create_snapshot"),
		"signal": _signal_system.call(&"create_snapshot"),
		"delivery": _delivery_system.call(&"create_snapshot"),
		"task": _task_system.call(&"create_snapshot"),
		"interaction_outcome": _interaction_outcome_system.call(&"create_snapshot"),
	}
	snapshot.make_read_only()
	return snapshot


## 在任何字段写入前，先校验剧情本体和三个嵌套系统。返回 normalized 状态供
## restore_snapshot() 一次性提交；无效档案不会重放任何解锁、陈述、事实、广播
## 或调度信号。
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("snapshot_story_not_configured", "测试剧情尚未配置，不能校验存档。")
	var envelope: Dictionary = _validate_snapshot_envelope(snapshot)
	if not bool(envelope.get("ok", false)):
		return envelope
	var tick_result: Dictionary = _validate_snapshot_integer(snapshot["current_game_tick"], "current_game_tick", 0, ENDING_TICK)
	if not bool(tick_result.get("ok", false)):
		return tick_result
	var minute_result: Dictionary = _validate_snapshot_integer(snapshot["current_minute"], "current_minute", 0, ENDING_TICK / TICKS_PER_GAME_MINUTE)
	if not bool(minute_result.get("ok", false)):
		return minute_result
	var current_tick: int = int(tick_result["value"])
	var current_minute: int = int(minute_result["value"])
	if current_minute != current_tick / TICKS_PER_GAME_MINUTE:
		return _make_error("snapshot_tick_minute_mismatch", "剧情存档的 current_minute 必须等于 current_game_tick / 60。")
	if context.has("current_game_tick"):
		var context_tick_result: Dictionary = _validate_snapshot_integer(context["current_game_tick"], "context.current_game_tick", 0, ENDING_TICK)
		if not bool(context_tick_result.get("ok", false)):
			return context_tick_result
		if int(context_tick_result["value"]) != current_tick:
			return _make_error("snapshot_phone_tick_mismatch", "剧情存档时间与已恢复 PhoneSystem 时间不一致。")

	var conditions_result: Dictionary = _validate_condition_snapshot(snapshot["condition_state_by_id"])
	if not bool(conditions_result.get("ok", false)):
		return conditions_result
	var statements_result: Dictionary = _validate_known_id_array(snapshot["revealed_statement_ids"], _statement_by_id, "revealed_statement_ids", "statement")
	if not bool(statements_result.get("ok", false)):
		return statements_result
	var facts_result: Dictionary = _validate_known_id_array(snapshot["confirmed_fact_ids"], _fact_by_id, "confirmed_fact_ids", "fact")
	if not bool(facts_result.get("ok", false)):
		return facts_result
	var completed_result: Dictionary = _validate_completed_dialogue_ids(snapshot["completed_dialogue_event_ids"])
	if not bool(completed_result.get("ok", false)):
		return completed_result
	var answered_interactions_result: Dictionary = _validate_interaction_event_ids(
		snapshot["answered_interaction_event_ids"],
		"answered_interaction_event_ids"
	)
	if not bool(answered_interactions_result.get("ok", false)):
		return answered_interactions_result
	var completed_interactions_result: Dictionary = _validate_interaction_event_ids(
		snapshot["completed_interaction_event_ids"],
		"completed_interaction_event_ids"
	)
	if not bool(completed_interactions_result.get("ok", false)):
		return completed_interactions_result
	var decisions_result: Dictionary = _validate_broadcast_decisions_snapshot(snapshot["broadcast_decisions"], statements_result["ids"] as Array[String])
	if not bool(decisions_result.get("ok", false)):
		return decisions_result
	var active_dialogue_result: Dictionary = _validate_active_dialogue(snapshot["active_dialogue"])
	if not bool(active_dialogue_result.get("ok", false)):
		return active_dialogue_result
	if typeof(snapshot["is_ending_forced"]) != TYPE_BOOL:
		return _make_error("invalid_snapshot_ending", "剧情存档的 is_ending_forced 必须是布尔值。")
	var is_ending_forced: bool = bool(snapshot["is_ending_forced"])
	if is_ending_forced != (current_tick == ENDING_TICK):
		return _make_error("snapshot_ending_tick_mismatch", "02:00 剧情状态必须与精确结束 tick 一致。")
	var unauthorized_result: Dictionary = _validate_unauthorized_broadcast_record(snapshot["unauthorized_broadcast_record"], is_ending_forced)
	if not bool(unauthorized_result.get("ok", false)):
		return unauthorized_result
	if is_ending_forced and not bool(active_dialogue_result["is_empty"]):
		return _make_error("snapshot_ending_dialogue_active", "02:00 收束后不能保留活动对话。")

	var revealed_lookup: Dictionary = _string_array_to_lookup(statements_result["ids"] as Array[String])
	var facts_validation: Dictionary = _validate_confirmed_facts(facts_result["ids"] as Array[String], revealed_lookup, is_ending_forced)
	if not bool(facts_validation.get("ok", false)):
		return facts_validation

	if not snapshot["scheduler"] is Dictionary or not snapshot["computer"] is Dictionary or not snapshot["broadcast"] is Dictionary or not snapshot["signal"] is Dictionary or not snapshot["delivery"] is Dictionary or not snapshot["task"] is Dictionary or not snapshot["interaction_outcome"] is Dictionary:
		return _make_error("invalid_snapshot_subsystem", "剧情存档的 scheduler、computer、broadcast、signal、delivery、task、interaction_outcome 必须是对象。")
	var scheduler_context: Dictionary = {"event_by_id": _story_event_by_id}
	var scheduler_validation: Dictionary = _scheduler.validate_snapshot(snapshot["scheduler"] as Dictionary, scheduler_context)
	if not bool(scheduler_validation.get("ok", false)):
		return _make_error("scheduler_snapshot_invalid", "事件调度器存档校验失败：%s" % String(scheduler_validation.get("message", "未知错误。")))
	var computer_context: Dictionary = {"current_game_tick": current_tick}
	if context.has("phone_system"):
		computer_context["phone_system"] = context["phone_system"]
	if context.has("call_record_event_ids"):
		computer_context["call_record_event_ids"] = context["call_record_event_ids"]
	var computer_validation_value: Variant = _computer_system.call(&"validate_snapshot", snapshot["computer"], computer_context)
	if not computer_validation_value is Dictionary or not bool((computer_validation_value as Dictionary).get("ok", false)):
		return _make_error("computer_snapshot_invalid", "电脑系统存档校验失败：%s" % _snapshot_message(computer_validation_value))
	var computer_validation: Dictionary = computer_validation_value as Dictionary
	if int((computer_validation["normalized"] as Dictionary)["current_minute"]) != current_minute:
		return _make_error("snapshot_computer_minute_mismatch", "电脑存档分钟必须与剧情时间一致。")
	var phone_scheduler_result: Dictionary = _validate_phone_scheduler_relationship(
		context,
		scheduler_validation["normalized_snapshot"] as Dictionary,
		is_ending_forced
	)
	if not bool(phone_scheduler_result.get("ok", false)):
		return phone_scheduler_result
	var broadcast_validation_value: Variant = _broadcast_system.call(&"validate_snapshot", snapshot["broadcast"])
	if not broadcast_validation_value is Dictionary or not bool((broadcast_validation_value as Dictionary).get("ok", false)):
		return _make_error("broadcast_snapshot_invalid", "广播系统存档校验失败：%s" % _snapshot_message(broadcast_validation_value))
	var broadcast_validation: Dictionary = broadcast_validation_value as Dictionary
	var signal_validation_value: Variant = _signal_system.call(&"validate_snapshot", snapshot["signal"])
	if not signal_validation_value is Dictionary or not bool((signal_validation_value as Dictionary).get("ok", false)):
		return _make_error("signal_snapshot_invalid", "SignalSystem 存档校验失败：%s" % _snapshot_message(signal_validation_value))
	var signal_validation: Dictionary = signal_validation_value as Dictionary
	var delivery_context: Dictionary = {"current_game_tick": current_tick}
	var delivery_validation_value: Variant = _delivery_system.call(&"validate_snapshot", snapshot["delivery"], delivery_context)
	if not delivery_validation_value is Dictionary or not bool((delivery_validation_value as Dictionary).get("ok", false)):
		return _make_error("delivery_snapshot_invalid", "DeliverySystem 存档校验失败：%s" % _snapshot_message(delivery_validation_value))
	var delivery_validation: Dictionary = delivery_validation_value as Dictionary
	var normalized_delivery_requests: Array[Dictionary] = (delivery_validation["normalized"] as Dictionary)["requests"] as Array[Dictionary]
	var outcome_context: Dictionary = {"current_game_tick": current_tick}
	var outcome_validation_value: Variant = _interaction_outcome_system.call(&"validate_snapshot", snapshot["interaction_outcome"], outcome_context)
	if not outcome_validation_value is Dictionary or not bool((outcome_validation_value as Dictionary).get("ok", false)):
		return _make_error("interaction_outcome_snapshot_invalid", "InteractionOutcomeSystem 存档校验失败：%s" % _snapshot_message(outcome_validation_value))
	var outcome_validation: Dictionary = outcome_validation_value as Dictionary
	var normalized_outcomes: Array[Dictionary] = (outcome_validation["normalized"] as Dictionary)["outcomes"] as Array[Dictionary]
	var outcome_by_event_id: Dictionary = {}
	for outcome_record: Dictionary in normalized_outcomes:
		outcome_by_event_id[String(outcome_record["event_id"])] = outcome_record
	var completed_interaction_ids: Array[String] = completed_interactions_result["ids"] as Array[String]
	if outcome_by_event_id.size() != completed_interaction_ids.size():
		return _make_error("snapshot_interaction_outcome_count_mismatch", "每个 completed interaction 必须且只能拥有一条 InteractionOutcome。")
	for completed_event_id: String in completed_interaction_ids:
		if not outcome_by_event_id.has(completed_event_id):
			return _make_error("snapshot_interaction_outcome_missing", "completed interaction 缺少 InteractionOutcome：%s。" % completed_event_id)

	var normalized_broadcast: Dictionary = broadcast_validation["normalized"] as Dictionary
	var normalized_computer: Dictionary = computer_validation["normalized"] as Dictionary
	var snapshot_task_world_state: Dictionary = _build_snapshot_task_world_state(
		statements_result["ids"] as Array[String],
		facts_result["ids"] as Array[String],
		conditions_result["states"] as Dictionary,
		answered_interactions_result["ids"] as Array[String],
		completed_interaction_ids,
		completed_result["ids"] as Array[String],
		normalized_broadcast,
		normalized_computer,
		outcome_by_event_id
	)
	var task_context: Dictionary = {"current_game_tick": current_tick, "world_state": snapshot_task_world_state}
	var task_validation_value: Variant = _task_system.call(&"validate_snapshot", snapshot["task"], task_context)
	if not task_validation_value is Dictionary or not bool((task_validation_value as Dictionary).get("ok", false)):
		return _make_error("task_snapshot_invalid", "TaskSystem 存档校验失败：%s" % _snapshot_message(task_validation_value))
	var task_validation: Dictionary = task_validation_value as Dictionary
	var task_broadcast_relationship: Dictionary = _validate_task_broadcast_relationship(
		decisions_result["states"] as Dictionary,
		task_validation["normalized"] as Dictionary
	)
	if not bool(task_broadcast_relationship.get("ok", false)):
		return task_broadcast_relationship
	var delivery_computer_relationship: Dictionary = _validate_delivery_computer_relationship(
		normalized_delivery_requests,
		normalized_computer
	)
	if not bool(delivery_computer_relationship.get("ok", false)):
		return delivery_computer_relationship
	var delivery_phone_relationship: Dictionary = _validate_delivery_phone_relationship(context, normalized_delivery_requests)
	if not bool(delivery_phone_relationship.get("ok", false)):
		return delivery_phone_relationship
	var interaction_delivery_relationship: Dictionary = _validate_dynamic_interaction_delivery_relationship(
		answered_interactions_result["ids"] as Array[String],
		completed_interactions_result["ids"] as Array[String],
		normalized_delivery_requests
	)
	if not bool(interaction_delivery_relationship.get("ok", false)):
		return interaction_delivery_relationship
	var normalized_broadcast_records: Array[Dictionary] = normalized_broadcast["player_records"] as Array[Dictionary]
	var normalized_signal_records: Array[Dictionary] = (signal_validation["normalized"] as Dictionary)["records"] as Array[Dictionary]
	var broadcast_record_by_task: Dictionary = {}
	for broadcast_record: Dictionary in normalized_broadcast_records:
		broadcast_record_by_task[String(broadcast_record["task_id"])] = broadcast_record
	var signal_record_by_task: Dictionary = {}
	var delivery_request_by_id: Dictionary = {}
	for delivery_request: Dictionary in normalized_delivery_requests:
		delivery_request_by_id[String(delivery_request["delivery_id"])] = delivery_request
	for completed_event_id: String in completed_interaction_ids:
		var completed_outcome: Dictionary = outcome_by_event_id[completed_event_id] as Dictionary
		var expected_outcome_actor_id: String = ""
		if _story_event_by_id.has(completed_event_id):
			expected_outcome_actor_id = String((_story_event_by_id[completed_event_id] as Dictionary).get("actor_id", ""))
		elif delivery_request_by_id.has(completed_event_id):
			var outcome_delivery: Dictionary = delivery_request_by_id[completed_event_id] as Dictionary
			if String(outcome_delivery["action_id"]) == "call_station" and String(outcome_delivery["status"]) == "committed":
				expected_outcome_actor_id = String(outcome_delivery["actor_id"])
		if expected_outcome_actor_id.is_empty() or String(completed_outcome["actor_id"]) != expected_outcome_actor_id:
			return _make_error("snapshot_interaction_outcome_actor_mismatch", "InteractionOutcome Actor 必须与 completed interaction 的真实来源一致：%s。" % completed_event_id)
	var delivery_signal_by_id: Dictionary = {}
	var phone_terminal_signal_by_event: Dictionary = {}
	var message_read_signal_by_source: Dictionary = {}
	var outcome_signal_by_event: Dictionary = {}
	var task_transition_signal_by_id: Dictionary = {}
	var task_transition_by_id: Dictionary = {}
	for raw_transition: Variant in (task_validation["normalized"] as Dictionary)["transitions"] as Array:
		var transition: Dictionary = raw_transition as Dictionary
		task_transition_by_id[String(transition["transition_id"])] = transition
	var read_message_ids: Array[String] = ((normalized_computer["read_source_ids"] as Dictionary)["messages"] as Array[String]).duplicate()
	var read_message_lookup: Dictionary = _string_array_to_lookup(read_message_ids)
	var snapshot_phone_system: RefCounted = _phone_system
	if context.has("phone_system"):
		snapshot_phone_system = context["phone_system"] as RefCounted
	var phone_records_value: Variant = snapshot_phone_system.call(&"get_call_records") if snapshot_phone_system != null else null
	if not phone_records_value is Array:
		return _make_error("snapshot_phone_context_invalid", "剧情存档校验无法读取 PhoneSystem 来电记录。")
	var phone_record_by_event: Dictionary = {}
	for raw_phone_record: Variant in phone_records_value as Array:
		if not raw_phone_record is Dictionary:
			return _make_error("snapshot_phone_context_invalid", "PhoneSystem 来电记录必须是对象。")
		var phone_record: Dictionary = raw_phone_record as Dictionary
		var phone_event_id: String = String(phone_record.get("event_id", ""))
		if phone_event_id.is_empty() or phone_record_by_event.has(phone_event_id):
			return _make_error("snapshot_phone_record_duplicate", "PhoneSystem 来电记录 event_id 无效或重复。")
		phone_record_by_event[phone_event_id] = phone_record
	var expected_phone_terminal_actor_by_event: Dictionary = {}
	if is_agent_dialogue_v2():
		for raw_phone_event_id: Variant in phone_record_by_event.keys():
			var phone_event_id: String = String(raw_phone_event_id)
			var expected_phone_actor_id: String = ""
			if _story_event_by_id.has(phone_event_id):
				expected_phone_actor_id = String((_story_event_by_id[phone_event_id] as Dictionary).get("actor_id", ""))
			elif delivery_request_by_id.has(phone_event_id):
				var phone_delivery: Dictionary = delivery_request_by_id[phone_event_id] as Dictionary
				if String(phone_delivery["action_id"]) == "call_station" and String(phone_delivery["status"]) == "committed":
					expected_phone_actor_id = String(phone_delivery["actor_id"])
			if not expected_phone_actor_id.is_empty():
				expected_phone_terminal_actor_by_event[phone_event_id] = expected_phone_actor_id
	for signal_record: Dictionary in normalized_signal_records:
		var signal_source_id: String = String(signal_record["source_id"])
		match String(signal_record["signal_type"]):
			"player_broadcast":
				if not broadcast_record_by_task.has(signal_source_id):
					return _make_error("snapshot_signal_without_broadcast", "玩家广播 SignalRecord 必须对应一条真实 committed 玩家广播：%s。" % signal_source_id)
				var source_broadcast: Dictionary = broadcast_record_by_task[signal_source_id] as Dictionary
				var signal_information_ids: Array = ((signal_record["payload"] as Dictionary)["information_item_ids"] as Array)
				if int(signal_record["created_at_tick"]) != int(source_broadcast["sent_at_tick"]) or signal_information_ids != (source_broadcast["information_item_ids"] as Array):
					return _make_error("snapshot_signal_broadcast_mismatch", "SignalRecord 必须与来源玩家广播的 tick/information IDs 精确一致：%s。" % signal_source_id)
				signal_record_by_task[signal_source_id] = signal_record
			"delivery_outcome":
				if not delivery_request_by_id.has(signal_source_id):
					return _make_error("snapshot_signal_without_delivery", "Delivery feedback SignalRecord 缺少真实 DeliveryRequest：%s。" % signal_source_id)
				var source_delivery: Dictionary = delivery_request_by_id[signal_source_id] as Dictionary
				var delivery_status: String = String(source_delivery["status"])
				if delivery_status != "committed" and delivery_status != "rejected":
					return _make_error("snapshot_signal_delivery_status_mismatch", "只有 committed/rejected DeliveryRequest 可以拥有 feedback SignalRecord：%s。" % signal_source_id)
				var signal_payload: Dictionary = signal_record["payload"] as Dictionary
				if String(signal_payload["status"]) != delivery_status or String(signal_payload["action_id"]) != String(source_delivery["action_id"]):
					return _make_error("snapshot_signal_delivery_payload_mismatch", "Delivery feedback SignalRecord 的 status/action_id 与真实 DeliveryRequest 不一致：%s。" % signal_source_id)
				if String(signal_payload["source_opportunity_id"]) != String(source_delivery["source_opportunity_id"]) or String(signal_payload["source_director_plan_id"]) != String(source_delivery["source_director_plan_id"]):
					return _make_error("snapshot_signal_delivery_source_mismatch", "Delivery feedback SignalRecord 的 source IDs 与真实 DeliveryRequest 不一致：%s。" % signal_source_id)
				var signal_recipients: Array = signal_record["committed_recipients"] as Array
				if signal_recipients != [String(source_delivery["actor_id"])]:
					return _make_error("snapshot_signal_delivery_recipient_mismatch", "Delivery feedback 只能提交给发起该 DeliveryRequest 的 Actor：%s。" % signal_source_id)
				if int(signal_record["created_at_tick"]) < int(source_delivery["created_at_tick"]):
					return _make_error("snapshot_signal_delivery_tick_mismatch", "Delivery feedback SignalRecord 不能早于 DeliveryRequest 创建时间：%s。" % signal_source_id)
				delivery_signal_by_id[signal_source_id] = signal_record
			"phone_terminal":
				if not phone_record_by_event.has(signal_source_id) or not expected_phone_terminal_actor_by_event.has(signal_source_id):
					return _make_error("snapshot_phone_terminal_without_record", "phone_terminal Signal 缺少真实 Agent 来电记录：%s。" % signal_source_id)
				var source_phone_record: Dictionary = phone_record_by_event[signal_source_id] as Dictionary
				var phone_payload: Dictionary = signal_record["payload"] as Dictionary
				if String(phone_payload["outcome"]) != String(source_phone_record.get("outcome", "")):
					return _make_error("snapshot_phone_terminal_outcome_mismatch", "phone_terminal Signal 与来电记录 outcome 不一致：%s。" % signal_source_id)
				var expected_phone_actor_id: String = String(expected_phone_terminal_actor_by_event[signal_source_id])
				if String(phone_payload["actor_id"]) != expected_phone_actor_id:
					return _make_error("snapshot_phone_terminal_actor_mismatch", "phone_terminal Signal Actor 与来电来源不一致：%s。" % signal_source_id)
				var minimum_terminal_tick: int = int(source_phone_record.get("time", 0)) + int(source_phone_record.get("duration_ticks", 0))
				if int(signal_record["created_at_tick"]) < minimum_terminal_tick:
					return _make_error("snapshot_phone_terminal_tick_mismatch", "phone_terminal Signal 不能早于来电记录能够证明的终态下界：%s。" % signal_source_id)
				if String(source_phone_record.get("outcome", "")) == "missed" and int(signal_record["created_at_tick"]) != minimum_terminal_tick:
					return _make_error("snapshot_phone_terminal_tick_mismatch", "missed 来电的 phone_terminal tick 必须与响铃开始加持续时间精确一致：%s。" % signal_source_id)
				phone_terminal_signal_by_event[signal_source_id] = signal_record
			"message_read":
				if not read_message_lookup.has(signal_source_id):
					return _make_error("snapshot_message_read_signal_mismatch", "message_read Signal 对应的短信并未处于已读状态：%s。" % signal_source_id)
				message_read_signal_by_source[signal_source_id] = signal_record
			"interaction_outcome":
				if not outcome_by_event_id.has(signal_source_id):
					return _make_error("snapshot_outcome_signal_without_outcome", "interaction_outcome Signal 缺少真实 Outcome：%s。" % signal_source_id)
				var source_outcome: Dictionary = outcome_by_event_id[signal_source_id] as Dictionary
				var outcome_payload: Dictionary = signal_record["payload"] as Dictionary
				if int(signal_record["created_at_tick"]) != int(source_outcome["created_at_tick"]) \
				or String(outcome_payload["outcome_id"]) != String(source_outcome["outcome_id"]) \
				or String(outcome_payload["actor_id"]) != String(source_outcome["actor_id"]) \
				or String(outcome_payload["disposition"]) != String(source_outcome["disposition"]) \
				or String(outcome_payload["terminal_reason"]) != String(source_outcome["terminal_reason"]) \
				or (outcome_payload["metric_deltas"] as Dictionary) != (source_outcome["metric_deltas"] as Dictionary):
					return _make_error("snapshot_outcome_signal_mismatch", "interaction_outcome Signal 与真实 Outcome 不一致：%s。" % signal_source_id)
				outcome_signal_by_event[signal_source_id] = signal_record
			"task_transition":
				var transition_payload: Dictionary = signal_record["payload"] as Dictionary
				var transition_id: String = String(transition_payload["transition_id"])
				if not task_transition_by_id.has(transition_id):
					return _make_error("snapshot_task_signal_without_transition", "task_transition Signal 缺少真实 Task transition：%s。" % transition_id)
				var source_transition: Dictionary = task_transition_by_id[transition_id] as Dictionary
				if signal_source_id != String(source_transition["task_id"]) \
				or int(signal_record["created_at_tick"]) != int(source_transition["created_at_tick"]) \
				or String(transition_payload["from_status"]) != String(source_transition["from_status"]) \
				or String(transition_payload["to_status"]) != String(source_transition["to_status"]) \
				or String(transition_payload["reason"]) != String(source_transition["reason"]):
					return _make_error("snapshot_task_signal_mismatch", "task_transition Signal 与真实 Task transition 不一致：%s。" % transition_id)
				var expected_task_recipients: Array[String] = _get_task_transition_recipients(String(source_transition["task_id"]))
				if (signal_record["committed_recipients"] as Array) != expected_task_recipients:
					return _make_error("snapshot_task_signal_recipients_mismatch", "task_transition Signal recipients 与任务关联 Actor 不一致：%s。" % transition_id)
				task_transition_signal_by_id[transition_id] = signal_record
			_:
				return _make_error("snapshot_signal_type_invalid", "剧情存档含 StoryEngine 不支持的 SignalRecord 类型。")
	if signal_record_by_task.size() != broadcast_record_by_task.size():
		return _make_error("snapshot_broadcast_signal_count_mismatch", "每条 committed 玩家广播都必须且只能对应一条 SignalRecord。")
	for delivery_request: Dictionary in normalized_delivery_requests:
		var delivery_id: String = String(delivery_request["delivery_id"])
		var has_feedback: bool = delivery_signal_by_id.has(delivery_id)
		var requires_feedback: bool = ["committed", "rejected"].has(String(delivery_request["status"]))
		if has_feedback != requires_feedback:
			return _make_error("snapshot_delivery_signal_presence_mismatch", "每条 committed/rejected DeliveryRequest 都必须且只能对应一条 feedback SignalRecord：%s。" % delivery_id)
	if is_agent_dialogue_v2() and phone_terminal_signal_by_event.size() != expected_phone_terminal_actor_by_event.size():
		return _make_error("snapshot_phone_terminal_signal_count_mismatch", "每条 Agent 电话终态记录必须且只能对应一条 phone_terminal Signal。")
	if message_read_signal_by_source.size() != read_message_lookup.size():
		return _make_error("snapshot_message_read_signal_count_mismatch", "每条已读短信必须且只能对应一条 message_read Signal。")
	if outcome_signal_by_event.size() != outcome_by_event_id.size():
		return _make_error("snapshot_outcome_signal_count_mismatch", "每条 InteractionOutcome 必须且只能对应一条 interaction_outcome Signal。")
	if task_transition_signal_by_id.size() != task_transition_by_id.size():
		return _make_error("snapshot_task_signal_count_mismatch", "每条 Task transition 必须且只能对应一条 task_transition Signal。")
	var sent_task_lookup: Dictionary = _string_array_to_lookup(normalized_broadcast["sent_task_ids"] as Array[String])
	var decision_relationship: Dictionary = _validate_broadcast_decision_relationship(
		decisions_result["states"] as Dictionary,
		sent_task_lookup,
		revealed_lookup,
		_string_array_to_lookup(facts_result["ids"] as Array[String]),
		conditions_result["states"] as Dictionary,
		_string_array_to_lookup(completed_result["ids"] as Array[String]),
		_string_array_to_lookup(answered_interactions_result["ids"] as Array[String]),
		_string_array_to_lookup(completed_interactions_result["ids"] as Array[String]),
		_string_array_to_lookup(((computer_validation["normalized"] as Dictionary)["read_source_ids"] as Dictionary)["messages"] as Array[String])
	)
	if not bool(decision_relationship.get("ok", false)):
		return decision_relationship
	for record: Dictionary in (broadcast_validation["normalized"] as Dictionary)["player_records"] as Array[Dictionary]:
		if int(record["sent_at_tick"]) > current_tick:
			return _make_error("snapshot_broadcast_time_invalid", "广播记录发送时间不能晚于剧情存档时间。")
	for signal_record: Dictionary in (signal_validation["normalized"] as Dictionary)["records"] as Array[Dictionary]:
		if int(signal_record["created_at_tick"]) > current_tick:
			return _make_error("snapshot_signal_time_invalid", "SignalRecord 创建时间不能晚于剧情存档时间。")
	if bool((scheduler_validation["normalized_snapshot"] as Dictionary)["ending_forced"]) != is_ending_forced:
		return _make_error("snapshot_scheduler_ending_mismatch", "调度器与剧情的 02:00 收束状态不一致。")

	return {
		"ok": true,
		"normalized": {
			"current_game_tick": current_tick,
			"current_minute": current_minute,
			"condition_state_by_id": conditions_result["states"],
			"revealed_statement_ids": statements_result["ids"],
			"confirmed_fact_ids": facts_result["ids"],
			"completed_dialogue_event_ids": completed_result["ids"],
			"answered_interaction_event_ids": answered_interactions_result["ids"],
			"completed_interaction_event_ids": completed_interactions_result["ids"],
			"active_dialogue": active_dialogue_result["value"],
			"is_ending_forced": is_ending_forced,
			"unauthorized_broadcast_record": unauthorized_result["record"],
			"broadcast_decisions": decisions_result["states"],
		},
		"subsystem_context": {
			"scheduler": scheduler_context,
			"computer": computer_context,
			"broadcast": {},
			"signal": {},
			"delivery": delivery_context,
			"task": task_context,
			"interaction_outcome": outcome_context,
		},
	}


## 先对全部嵌套状态完成校验，再恢复它们。理论上的二次恢复失败会用进入前的
## 快照回滚，确保不会留下“半个已读、半条队列”的运行时；成功路径不会派发业务信号。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	var old_scheduler_snapshot: Dictionary = _scheduler.create_snapshot()
	var old_computer_snapshot_value: Variant = _computer_system.call(&"create_snapshot")
	var old_broadcast_snapshot_value: Variant = _broadcast_system.call(&"create_snapshot")
	var old_signal_snapshot_value: Variant = _signal_system.call(&"create_snapshot")
	var old_delivery_snapshot_value: Variant = _delivery_system.call(&"create_snapshot")
	var old_task_snapshot_value: Variant = _task_system.call(&"create_snapshot")
	var old_outcome_snapshot_value: Variant = _interaction_outcome_system.call(&"create_snapshot")
	if not old_computer_snapshot_value is Dictionary \
	or not old_broadcast_snapshot_value is Dictionary \
	or not old_signal_snapshot_value is Dictionary \
	or not old_delivery_snapshot_value is Dictionary \
	or not old_task_snapshot_value is Dictionary \
	or not old_outcome_snapshot_value is Dictionary:
		return _make_error("snapshot_internal_contract", "剧情子系统无法生成回滚快照。")
	var subsystem_context: Dictionary = validation["subsystem_context"] as Dictionary
	var scheduler_restore: Dictionary = _scheduler.restore_snapshot(snapshot["scheduler"] as Dictionary, subsystem_context["scheduler"] as Dictionary)
	if not bool(scheduler_restore.get("ok", false)):
		return scheduler_restore
	var computer_restore_value: Variant = _computer_system.call(&"restore_snapshot", snapshot["computer"], subsystem_context["computer"])
	if not computer_restore_value is Dictionary or not bool((computer_restore_value as Dictionary).get("ok", false)):
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("computer_snapshot_restore_failed", "电脑系统恢复失败，调度器已回滚。")
	var broadcast_restore_value: Variant = _broadcast_system.call(&"restore_snapshot", snapshot["broadcast"], subsystem_context["broadcast"])
	if not broadcast_restore_value is Dictionary or not bool((broadcast_restore_value as Dictionary).get("ok", false)):
		_computer_system.call(&"restore_snapshot", old_computer_snapshot_value as Dictionary, subsystem_context["computer"])
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("broadcast_snapshot_restore_failed", "广播系统恢复失败，已回滚剧情子系统。")
	var signal_restore_value: Variant = _signal_system.call(&"restore_snapshot", snapshot["signal"], subsystem_context["signal"])
	if not signal_restore_value is Dictionary or not bool((signal_restore_value as Dictionary).get("ok", false)):
		_broadcast_system.call(&"restore_snapshot", old_broadcast_snapshot_value as Dictionary, subsystem_context["broadcast"])
		_computer_system.call(&"restore_snapshot", old_computer_snapshot_value as Dictionary, subsystem_context["computer"])
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("signal_snapshot_restore_failed", "SignalSystem 恢复失败，已回滚剧情子系统。")
	var delivery_restore_value: Variant = _delivery_system.call(&"restore_snapshot", snapshot["delivery"], subsystem_context["delivery"])
	if not delivery_restore_value is Dictionary or not bool((delivery_restore_value as Dictionary).get("ok", false)):
		_signal_system.call(&"restore_snapshot", old_signal_snapshot_value as Dictionary, subsystem_context["signal"])
		_broadcast_system.call(&"restore_snapshot", old_broadcast_snapshot_value as Dictionary, subsystem_context["broadcast"])
		_computer_system.call(&"restore_snapshot", old_computer_snapshot_value as Dictionary, subsystem_context["computer"])
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("delivery_snapshot_restore_failed", "DeliverySystem 恢复失败，已回滚剧情子系统。")
	var outcome_restore_value: Variant = _interaction_outcome_system.call(&"restore_snapshot", snapshot["interaction_outcome"], subsystem_context["interaction_outcome"])
	if not outcome_restore_value is Dictionary or not bool((outcome_restore_value as Dictionary).get("ok", false)):
		_delivery_system.call(&"restore_snapshot", old_delivery_snapshot_value as Dictionary, {})
		_signal_system.call(&"restore_snapshot", old_signal_snapshot_value as Dictionary, {})
		_broadcast_system.call(&"restore_snapshot", old_broadcast_snapshot_value as Dictionary, {})
		_computer_system.call(&"restore_snapshot", old_computer_snapshot_value as Dictionary, {})
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("interaction_outcome_snapshot_restore_failed", "InteractionOutcomeSystem 恢复失败，已回滚剧情子系统。")
	var task_restore_value: Variant = _task_system.call(&"restore_snapshot", snapshot["task"], subsystem_context["task"])
	if not task_restore_value is Dictionary or not bool((task_restore_value as Dictionary).get("ok", false)):
		_interaction_outcome_system.call(&"restore_snapshot", old_outcome_snapshot_value as Dictionary, {})
		_delivery_system.call(&"restore_snapshot", old_delivery_snapshot_value as Dictionary, {})
		_signal_system.call(&"restore_snapshot", old_signal_snapshot_value as Dictionary, {})
		_broadcast_system.call(&"restore_snapshot", old_broadcast_snapshot_value as Dictionary, {})
		_computer_system.call(&"restore_snapshot", old_computer_snapshot_value as Dictionary, {})
		_scheduler.restore_snapshot(old_scheduler_snapshot)
		return _make_error("task_snapshot_restore_failed", "TaskSystem 恢复失败，已回滚剧情子系统。")
	var normalized: Dictionary = validation["normalized"] as Dictionary
	_current_game_tick = int(normalized["current_game_tick"])
	_current_minute = int(normalized["current_minute"])
	_condition_state_by_id = (normalized["condition_state_by_id"] as Dictionary).duplicate(true)
	_revealed_statement_ids = _string_array_to_lookup(normalized["revealed_statement_ids"] as Array[String])
	_confirmed_fact_ids = _string_array_to_lookup(normalized["confirmed_fact_ids"] as Array[String])
	_completed_dialogue_event_ids = _string_array_to_lookup(normalized["completed_dialogue_event_ids"] as Array[String])
	_answered_interaction_event_ids = _string_array_to_lookup(normalized["answered_interaction_event_ids"] as Array[String])
	_completed_interaction_event_ids = _string_array_to_lookup(normalized["completed_interaction_event_ids"] as Array[String])
	_broadcast_decision_by_task_id = (normalized["broadcast_decisions"] as Dictionary).duplicate(true)
	var restored_dialogue: Variant = normalized["active_dialogue"]
	if restored_dialogue == null:
		_active_dialogue_event_id = ""
		_active_dialogue_node_id = ""
	else:
		var dialogue_state: Dictionary = restored_dialogue as Dictionary
		_active_dialogue_event_id = String(dialogue_state["event_id"])
		_active_dialogue_node_id = String(dialogue_state["node_id"])
	_is_ending_forced = bool(normalized["is_ending_forced"])
	# 活动 Agent interaction 不属于可存世界状态；读档成功后必须从干净会话边界继续。
	_committed_agent_turn_keys = {}
	_active_agent_session_id = ""
	_active_agent_event_id = ""
	_active_agent_actor_id = ""
	_active_agent_last_speech_act = ""
	_active_agent_asserted_claim_ids = []
	var restored_unauthorized: Variant = normalized["unauthorized_broadcast_record"]
	if restored_unauthorized == null:
		_unauthorized_broadcast_record = {}
	else:
		_unauthorized_broadcast_record = (restored_unauthorized as Dictionary).duplicate(true)
		_unauthorized_broadcast_record.make_read_only()
	return {"ok": true}


func _validate_snapshot_envelope(snapshot: Dictionary) -> Dictionary:
	var expected_fields: PackedStringArray = [
		"snapshot_version", "system_id", "current_game_tick", "current_minute",
		"condition_state_by_id", "revealed_statement_ids", "confirmed_fact_ids",
		"completed_dialogue_event_ids", "answered_interaction_event_ids",
		"completed_interaction_event_ids", "active_dialogue", "is_ending_forced",
		"unauthorized_broadcast_record", "broadcast_decisions", "scheduler", "computer", "broadcast", "signal", "delivery",
		"task", "interaction_outcome",
	]
	if snapshot.size() != expected_fields.size():
		return _make_error("snapshot_fields_invalid", "剧情存档字段缺失或包含未知字段。")
	for field_name: String in expected_fields:
		if not snapshot.has(field_name):
			return _make_error("snapshot_missing_field", "剧情存档缺少字段：%s。" % field_name)
	var version_result: Dictionary = _validate_snapshot_integer(snapshot["snapshot_version"], "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result.get("ok", false)):
		return _make_error("snapshot_version_unsupported", "剧情存档版本不受支持。")
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SNAPSHOT_SYSTEM_ID:
		return _make_error("snapshot_system_id_mismatch", "剧情存档所属系统不匹配。")
	return {"ok": true}


func _create_broadcast_decisions_snapshot() -> Dictionary:
	var states: Dictionary = {}
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		var state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
		states[task_id] = {
			"status": String(state.get("status", "unseen")),
			"available_information_item_ids": (state.get("available_information_item_ids", []) as Array).duplicate(true),
		}
	return states


func _validate_broadcast_decisions_snapshot(value: Variant, revealed_statement_ids: Array[String]) -> Dictionary:
	if not value is Dictionary:
		return _make_error("snapshot_broadcast_decisions_invalid", "剧情存档的 broadcast_decisions 必须是对象。")
	var raw_states: Dictionary = value as Dictionary
	if raw_states.size() != _broadcast_task_by_id.size():
		return _make_error("snapshot_broadcast_decisions_invalid", "剧情存档必须包含当前内容的全部发布任务决策状态。")
	var revealed_lookup: Dictionary = _string_array_to_lookup(revealed_statement_ids)
	var states: Dictionary = {}
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		if not raw_states.has(task_id) or not raw_states[task_id] is Dictionary:
			return _make_error("snapshot_broadcast_decisions_invalid", "发布任务决策状态缺少有效任务 ID：%s。" % task_id)
		var state: Dictionary = raw_states[task_id] as Dictionary
		if state.size() != 2 or not state.has("status") or not state.has("available_information_item_ids"):
			return _make_error("snapshot_broadcast_decisions_invalid", "发布任务 %s 的决策字段不完整或包含未知字段。" % task_id)
		if typeof(state["status"]) != TYPE_STRING or not ["unseen", "pending", "deferred", "abandoned", "sent"].has(String(state["status"])):
			return _make_error("snapshot_broadcast_decision_status_invalid", "发布任务 %s 包含未知决策状态。" % task_id)
		if not state["available_information_item_ids"] is Array:
			return _make_error("snapshot_broadcast_decisions_invalid", "发布任务 %s 的信息项状态必须是数组。" % task_id)
		var seen: Dictionary = {}
		var ids: Array[String] = []
		for raw_id: Variant in state["available_information_item_ids"] as Array:
			if not raw_id is String or seen.has(String(raw_id)):
				return _make_error("snapshot_broadcast_decisions_invalid", "发布任务 %s 的信息项状态含有重复或无效 ID。" % task_id)
			seen[String(raw_id)] = true
			ids.append(String(raw_id))
		var expected_ids: Array[String] = _get_available_information_item_ids(task_id, revealed_lookup)
		if ids != expected_ids:
			return _make_error("snapshot_broadcast_decision_information_mismatch", "发布任务 %s 的信息项状态与已揭示剧情不一致。" % task_id)
		states[task_id] = {"status": String(state["status"]), "available_information_item_ids": ids}
	return {"ok": true, "states": states}


func _validate_broadcast_decision_relationship(
	states: Dictionary,
	sent_lookup: Dictionary,
	revealed_lookup: Dictionary,
	confirmed_lookup: Dictionary,
	condition_states: Dictionary,
	completed_dialogue_lookup: Dictionary,
	answered_interaction_lookup: Dictionary,
	completed_interaction_lookup: Dictionary,
	read_message_lookup: Dictionary
) -> Dictionary:
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		var state: Dictionary = states[task_id] as Dictionary
		var status: String = String(state["status"])
		var is_sent: bool = sent_lookup.has(task_id)
		if (status == "sent") != is_sent:
			return _make_error("snapshot_broadcast_decision_sent_mismatch", "发布任务 %s 的决策状态与玩家播出记录不一致。" % task_id)
		if status == "abandoned" and is_sent:
			return _make_error("snapshot_broadcast_decision_abandoned_sent", "已放弃的发布任务不能同时拥有玩家播出记录。")
		if is_sent:
			continue
		var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
		var prerequisites_met: bool = _are_snapshot_task_prerequisites_met(
			task,
			sent_lookup,
			revealed_lookup,
			confirmed_lookup,
			condition_states,
			completed_dialogue_lookup,
			answered_interaction_lookup,
			completed_interaction_lookup,
			read_message_lookup
		)
		var is_publishable: bool = prerequisites_met and not _get_available_information_item_ids(task_id, revealed_lookup).is_empty()
		if is_publishable:
			if status != "pending" and status != "deferred" and status != "abandoned":
				return _make_error("snapshot_broadcast_decision_state_mismatch", "可发布任务 %s 不能保留未初始化的决策状态。" % task_id)
		elif status != "unseen":
			return _make_error("snapshot_broadcast_decision_state_mismatch", "未达到发布门槛的任务 %s 不能处于待决、推迟或放弃状态。" % task_id)
	return {"ok": true}


## Broadcast UI decision 与 TaskSystem 是同一任务的两个只读投影；存档必须证明它们没有分叉。
func _validate_task_broadcast_relationship(decision_states: Dictionary, normalized_task: Dictionary) -> Dictionary:
	if not normalized_task.has("states") or not normalized_task["states"] is Dictionary \
	or not normalized_task.has("transitions") or not normalized_task["transitions"] is Array:
		return _make_error("snapshot_task_relationship_invalid", "TaskSystem normalized snapshot 缺少 states/transitions。")
	var task_states: Dictionary = normalized_task["states"] as Dictionary
	var failed_reason_by_task: Dictionary = {}
	for raw_transition: Variant in normalized_task["transitions"] as Array:
		if not raw_transition is Dictionary:
			return _make_error("snapshot_task_relationship_invalid", "TaskSystem normalized transition 必须是对象。")
		var transition: Dictionary = raw_transition as Dictionary
		if String(transition.get("to_status", "")) == "failed":
			failed_reason_by_task[String(transition.get("task_id", ""))] = String(transition.get("reason", ""))
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		if not decision_states.has(task_id) or not task_states.has(task_id):
			return _make_error("snapshot_task_relationship_invalid", "发布任务与 TaskSystem 状态集合不一致：%s。" % task_id)
		var decision: Dictionary = decision_states[task_id] as Dictionary
		var decision_status: String = String(decision.get("status", ""))
		var task_status: String = String(task_states[task_id])
		var expected_task_status: String = ""
		match decision_status:
			"unseen":
				expected_task_status = "pending"
			"pending":
				expected_task_status = "active"
			"deferred":
				expected_task_status = "active"
			"sent":
				expected_task_status = "completed"
			"abandoned":
				expected_task_status = "failed"
				if String(failed_reason_by_task.get(task_id, "")) != "player_abandoned":
					return _make_error("snapshot_task_abandon_reason_mismatch", "abandoned 发布任务必须由 player_abandoned Task transition 进入 failed：%s。" % task_id)
			_:
				return _make_error("snapshot_task_relationship_invalid", "发布任务决策状态无法映射到 TaskSystem：%s。" % task_id)
		if task_status != expected_task_status:
			return _make_error("snapshot_task_broadcast_state_mismatch", "发布任务 %s 的 decision=%s 与 TaskSystem=%s 不一致。" % [task_id, decision_status, task_status])
	return {"ok": true}


func _are_snapshot_task_prerequisites_met(
	task: Dictionary,
	sent_lookup: Dictionary,
	revealed_lookup: Dictionary,
	confirmed_lookup: Dictionary,
	condition_states: Dictionary,
	completed_dialogue_lookup: Dictionary,
	answered_interaction_lookup: Dictionary,
	completed_interaction_lookup: Dictionary,
	read_message_lookup: Dictionary
) -> bool:
	if task.has("requirements"):
		for raw_requirement: Variant in task["requirements"] as Array:
			var requirement: Dictionary = raw_requirement as Dictionary
			var requirement_id: String = String(requirement["id"])
			match String(requirement["type"]):
				"statement_revealed":
					if not revealed_lookup.has(requirement_id): return false
				"fact_confirmed":
					if not confirmed_lookup.has(requirement_id): return false
				"condition_true":
					if not bool(condition_states.get(requirement_id, false)): return false
				"interaction_answered":
					if not answered_interaction_lookup.has(requirement_id): return false
				"interaction_completed":
					if not completed_interaction_lookup.has(requirement_id): return false
				"broadcast_sent":
					if not sent_lookup.has(requirement_id): return false
				"message_read":
					if not read_message_lookup.has(requirement_id): return false
				_:
					return false
		return true
	for raw_event_id: Variant in task.get("required_dialogue_event_ids", []) as Array:
		if not completed_dialogue_lookup.has(String(raw_event_id)):
			return false
	return true


func _validate_snapshot_integer(value: Variant, field_name: String, minimum: int, maximum: int) -> Dictionary:
	var parsed: int = 0
	if typeof(value) == TYPE_INT:
		parsed = int(value)
	elif typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), floor(float(value))):
		parsed = int(value)
	else:
		return _make_error("snapshot_invalid_integer", "剧情存档字段 %s 必须是 %d 到 %d 的整数。" % [field_name, minimum, maximum])
	if parsed < minimum or parsed > maximum:
		return _make_error("snapshot_invalid_integer", "剧情存档字段 %s 必须是 %d 到 %d 的整数。" % [field_name, minimum, maximum])
	return {"ok": true, "value": parsed}


func _validate_condition_snapshot(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return _make_error("snapshot_invalid_conditions", "剧情存档的 condition_state_by_id 必须是对象。")
	var raw_states: Dictionary = value as Dictionary
	if raw_states.size() != _declared_condition_ids.size():
		return _make_error("snapshot_condition_set_mismatch", "剧情存档必须包含当前内容声明的完整条件集合。")
	var normalized: Dictionary = {}
	for condition_id_variant: Variant in _declared_condition_ids:
		var condition_id: String = String(condition_id_variant)
		if not raw_states.has(condition_id) or typeof(raw_states[condition_id]) != TYPE_BOOL:
			return _make_error("snapshot_condition_invalid", "剧情存档缺少或错误声明条件：%s。" % condition_id)
		normalized[condition_id] = bool(raw_states[condition_id])
	for raw_condition_id: Variant in raw_states:
		if not raw_condition_id is String or not _declared_condition_ids.has(String(raw_condition_id)):
			return _make_error("snapshot_condition_unknown", "剧情存档含有当前内容未声明的条件。")
	return {"ok": true, "states": normalized}


func _validate_known_id_array(value: Variant, definitions: Dictionary, field_name: String, display_name: String) -> Dictionary:
	if not value is Array:
		return _make_error("snapshot_invalid_id_array", "剧情存档字段 %s 必须是数组。" % field_name)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String or not definitions.has(String(raw_id)):
			return _make_error("snapshot_unknown_%s" % display_name, "剧情存档引用了当前内容不存在的%s ID。" % display_name)
		var stable_id: String = String(raw_id)
		if seen.has(stable_id):
			return _make_error("snapshot_duplicate_%s" % display_name, "剧情存档不能包含重复%s ID。" % display_name)
		seen[stable_id] = true
		ids.append(stable_id)
	ids.sort()
	return {"ok": true, "ids": ids}


func _validate_completed_dialogue_ids(value: Variant) -> Dictionary:
	var result: Dictionary = _validate_known_id_array(value, _story_event_by_id, "completed_dialogue_event_ids", "对话事件")
	if not bool(result.get("ok", false)):
		return result
	for event_id: String in result["ids"] as Array[String]:
		var event_data: Dictionary = _story_event_by_id[event_id] as Dictionary
		if not event_data.has("dialogue_start_id") or String(event_data["dialogue_start_id"]).is_empty():
			return _make_error("snapshot_completed_dialogue_invalid", "已完成对话必须属于包含预制对话的来电事件。")
	return result


func _validate_interaction_event_ids(value: Variant, field_name: String) -> Dictionary:
	if not value is Array:
		return _make_error("snapshot_known_ids_invalid", "剧情存档的 %s 必须是数组。" % field_name)
	var ids: Array[String] = []
	var seen: Dictionary = {}
	for raw_id: Variant in value as Array:
		if not raw_id is String:
			return _make_error("snapshot_known_id_invalid", "剧情存档的 %s 只能包含字符串 ID。" % field_name)
		var event_id: String = String(raw_id)
		if seen.has(event_id):
			return _make_error("snapshot_known_id_duplicate", "剧情存档的 %s 含重复 ID：%s。" % [field_name, event_id])
		seen[event_id] = true
		if _story_event_by_id.has(event_id):
			var event_data: Dictionary = _story_event_by_id[event_id] as Dictionary
			if not event_data.has("actor_id") or String(event_data["actor_id"]).is_empty():
				return _make_error("snapshot_interaction_event_invalid", "Agent interaction 状态只能引用绑定 Actor 的来电事件。")
		elif not _is_structural_delivery_call_id(event_id):
			return _make_error("snapshot_interaction_event_unknown", "Agent interaction 状态引用了未知事件：%s。" % event_id)
		ids.append(event_id)
	ids.sort()
	return {"ok": true, "ids": ids}


func _is_structural_delivery_call_id(event_id: String) -> bool:
	const PREFIX: String = "delivery_call_"
	if not event_id.begins_with(PREFIX) or not event_id.is_valid_ascii_identifier():
		return false
	var last_separator: int = event_id.rfind("_")
	if last_separator <= PREFIX.length() or last_separator >= event_id.length() - 1:
		return false
	var actor_id: String = event_id.substr(PREFIX.length(), last_separator - PREFIX.length())
	var serial_text: String = event_id.substr(last_separator + 1)
	return not actor_id.is_empty() and actor_id.is_valid_ascii_identifier() and serial_text.is_valid_int() and int(serial_text) > 0


func _validate_active_dialogue(value: Variant) -> Dictionary:
	if value == null:
		return {"ok": true, "is_empty": true, "value": null}
	if not value is Dictionary:
		return _make_error("snapshot_active_dialogue_invalid", "剧情存档的 active_dialogue 必须为 null 或对象。")
	var dialogue: Dictionary = value as Dictionary
	if dialogue.size() != 2 or not dialogue.has("event_id") or not dialogue.has("node_id") or not dialogue["event_id"] is String or not dialogue["node_id"] is String:
		return _make_error("snapshot_active_dialogue_invalid", "活动对话必须只包含 event_id 与 node_id 字符串。")
	var event_id: String = String(dialogue["event_id"])
	var node_id: String = String(dialogue["node_id"])
	if not _story_event_by_id.has(event_id) or not _dialogue_node_by_id.has(node_id):
		return _make_error("snapshot_active_dialogue_unknown", "活动对话引用了当前内容不存在的事件或节点。")
	if not _dialogue_node_belongs_to_event(node_id, event_id):
		return _make_error("snapshot_dialogue_node_mismatch", "活动对话节点不属于指定来电事件。")
	return {"ok": true, "is_empty": false, "value": {"event_id": event_id, "node_id": node_id}}


func _validate_confirmed_facts(confirmed_fact_ids: Array[String], revealed_lookup: Dictionary, is_ending_forced: bool) -> Dictionary:
	var expected: Dictionary = {}
	for fact_id_variant: Variant in _fact_by_id:
		var fact_id: String = String(fact_id_variant)
		var fact: Dictionary = _fact_by_id[fact_id] as Dictionary
		if ENDING_ONLY_FACT_IDS.has(fact_id):
			if is_ending_forced:
				expected[fact_id] = true
			continue
		if bool(fact["initially_confirmed"]):
			expected[fact_id] = true
			continue
		var has_all_required: bool = true
		for required_id_variant: Variant in fact["required_statement_ids"] as Array:
			if not revealed_lookup.has(String(required_id_variant)):
				has_all_required = false
				break
		if has_all_required:
			expected[fact_id] = true
	if _string_array_to_lookup(confirmed_fact_ids) != expected:
		return _make_error("snapshot_fact_rule_mismatch", "剧情存档的已确认事实不满足当前内容事实规则。")
	return {"ok": true}


## PhoneSystem 已先恢复时，调度器的 triggered 状态必须能由一条真实电话记录或
## 当前活动线路解释；否则坏档可能在继续推进时重新开始同一来电。
func _validate_phone_scheduler_relationship(context: Dictionary, scheduler_snapshot: Dictionary, story_is_ending_forced: bool) -> Dictionary:
	var phone_system: RefCounted = _phone_system
	if context.has("phone_system"):
		if not context["phone_system"] is RefCounted:
			return _make_error("snapshot_phone_context_invalid", "剧情存档恢复上下文的 PhoneSystem 无效。")
		phone_system = context["phone_system"] as RefCounted
	if phone_system == null or not phone_system.has_method(&"get_active_event_id") or not phone_system.has_method(&"get_call_records") or not phone_system.has_method(&"is_forced_ended"):
		return _make_error("snapshot_phone_context_missing", "剧情存档校验需要已恢复 PhoneSystem 的真实线路状态。")
	var active_value: Variant = phone_system.call(&"get_active_event_id")
	var records_value: Variant = phone_system.call(&"get_call_records")
	var forced_value: Variant = phone_system.call(&"is_forced_ended")
	if not active_value is String or not records_value is Array or typeof(forced_value) != TYPE_BOOL:
		return _make_error("snapshot_phone_context_invalid", "PhoneSystem 返回的活动线路或来电记录无效。")
	if bool(forced_value) != story_is_ending_forced:
		return _make_error("snapshot_phone_forced_end_mismatch", "PhoneSystem 的强制结束状态必须与剧情 02:00 收束状态一致。")
	var active_event_id: String = String(active_value)
	var resolved_event_ids: Dictionary = {}
	for raw_record: Variant in records_value as Array:
		if not raw_record is Dictionary or not (raw_record as Dictionary).get("event_id") is String:
			return _make_error("snapshot_phone_context_invalid", "PhoneSystem 来电记录缺少稳定 event_id。")
		var record_event_id: String = String((raw_record as Dictionary)["event_id"])
		if _story_event_by_id.has(record_event_id):
			resolved_event_ids[record_event_id] = true
	if not active_event_id.is_empty() and _story_event_by_id.has(active_event_id):
		resolved_event_ids[active_event_id] = true
	var statuses: Dictionary = scheduler_snapshot["event_status_by_id"] as Dictionary
	if not active_event_id.is_empty() and _story_event_by_id.has(active_event_id) and String(statuses.get(active_event_id, "")) != "triggered":
		return _make_error("snapshot_active_call_scheduler_mismatch", "当前活动来电必须对应调度器的 triggered 事件。")
	for event_id_variant: Variant in statuses:
		var event_id: String = String(event_id_variant)
		var status: String = String(statuses[event_id])
		if status == "triggered" and not resolved_event_ids.has(event_id):
			return _make_error("snapshot_triggered_event_unresolved", "调度器已触发事件缺少真实电话记录或活动线路。")
	for record_event_id_variant: Variant in resolved_event_ids:
		var record_event_id: String = String(record_event_id_variant)
		var record_status: String = String(statuses.get(record_event_id, ""))
		if record_status != "triggered" and record_status != "expired":
			return _make_error("snapshot_phone_record_scheduler_mismatch", "真实电话记录与调度器事件状态不一致。")
	return {"ok": true}


## ComputerSystem 的动态 messages 不是第二套 Delivery 真相。每条动态消息必须精确对应
## 一条 committed send_message request；反过来每条 committed send_message 也必须已经存在于电脑。
func _validate_delivery_computer_relationship(delivery_requests: Array[Dictionary], computer_normalized: Dictionary) -> Dictionary:
	if not computer_normalized.get("dynamic_messages") is Array:
		return _make_error("snapshot_delivery_computer_context_invalid", "ComputerSystem normalized state 缺少 dynamic_messages。")
	var request_by_id: Dictionary = {}
	for request: Dictionary in delivery_requests:
		request_by_id[String(request["delivery_id"])] = request
	var message_by_id: Dictionary = {}
	for raw_message: Variant in computer_normalized["dynamic_messages"] as Array:
		if not raw_message is Dictionary or not (raw_message as Dictionary).get("id") is String:
			return _make_error("snapshot_delivery_computer_context_invalid", "动态消息缺少稳定 Delivery ID。")
		var message: Dictionary = raw_message as Dictionary
		var delivery_id: String = String(message["id"])
		if message_by_id.has(delivery_id):
			return _make_error("snapshot_delivery_message_duplicate", "同一 Delivery message 不能在 ComputerSystem 出现两次：%s。" % delivery_id)
		if not request_by_id.has(delivery_id):
			return _make_error("snapshot_message_without_delivery", "动态电脑消息缺少对应 DeliveryRequest：%s。" % delivery_id)
		var request: Dictionary = request_by_id[delivery_id] as Dictionary
		if String(request["action_id"]) != "send_message" or String(request["status"]) != "committed":
			return _make_error("snapshot_message_delivery_status_mismatch", "只有 committed send_message 才能拥有动态电脑消息：%s。" % delivery_id)
		if String(message.get("source_actor_id", "")) != String(request["actor_id"]):
			return _make_error("snapshot_message_delivery_actor_mismatch", "动态电脑消息 Actor 与 DeliveryRequest 不一致：%s。" % delivery_id)
		if String(message.get("body", "")) != String((request["arguments"] as Dictionary).get("body", "")):
			return _make_error("snapshot_message_delivery_body_mismatch", "动态电脑消息正文与 DeliveryRequest 不一致：%s。" % delivery_id)
		if int(message.get("created_at_tick", -1)) != int(request["created_at_tick"]):
			return _make_error("snapshot_message_delivery_tick_mismatch", "动态电脑消息 tick 与 DeliveryRequest 不一致：%s。" % delivery_id)
		message_by_id[delivery_id] = true
	for request: Dictionary in delivery_requests:
		if String(request["action_id"]) != "send_message":
			continue
		var delivery_id: String = String(request["delivery_id"])
		var should_exist: bool = String(request["status"]) == "committed"
		if message_by_id.has(delivery_id) != should_exist:
			return _make_error("snapshot_delivery_message_presence_mismatch", "send_message Delivery 与 ComputerSystem committed state 不一致：%s。" % delivery_id)
	return {"ok": true}


## PhoneSystem 只结构化放行 delivery_call_*；真正的来源授权在这里完成。
## committed call 必须恰好对应当前活动线路或一条真实 call record；其它状态不得出现在电话世界。
func _validate_delivery_phone_relationship(context: Dictionary, delivery_requests: Array[Dictionary]) -> Dictionary:
	var phone_system: RefCounted = _phone_system
	if context.has("phone_system"):
		if not context["phone_system"] is RefCounted:
			return _make_error("snapshot_delivery_phone_context_invalid", "Delivery 电话校验上下文的 PhoneSystem 无效。")
		phone_system = context["phone_system"] as RefCounted
	if phone_system == null or not phone_system.has_method(&"get_active_event_id") or not phone_system.has_method(&"get_active_call_snapshot") or not phone_system.has_method(&"get_call_records"):
		return _make_error("snapshot_delivery_phone_context_missing", "Delivery 电话校验需要 PhoneSystem 的活动线路与真实记录。")
	var active_id_value: Variant = phone_system.call(&"get_active_event_id")
	var active_snapshot_value: Variant = phone_system.call(&"get_active_call_snapshot")
	var records_value: Variant = phone_system.call(&"get_call_records")
	if not active_id_value is String or not active_snapshot_value is Dictionary or not records_value is Array:
		return _make_error("snapshot_delivery_phone_context_invalid", "PhoneSystem 返回的 Delivery 电话观察状态无效。")
	var call_request_by_id: Dictionary = {}
	for request: Dictionary in delivery_requests:
		if String(request["action_id"]) == "call_station":
			call_request_by_id[String(request["delivery_id"])] = request
	var observed: Dictionary = {}
	var active_id: String = String(active_id_value)
	if active_id.begins_with("delivery_call_"):
		if not call_request_by_id.has(active_id):
			return _make_error("snapshot_phone_call_without_delivery", "活动动态来电缺少对应 DeliveryRequest：%s。" % active_id)
		var active_request: Dictionary = call_request_by_id[active_id] as Dictionary
		if String(active_request["status"]) != "committed":
			return _make_error("snapshot_phone_delivery_status_mismatch", "活动动态来电对应的 DeliveryRequest 必须 committed：%s。" % active_id)
		var active_call: Dictionary = active_snapshot_value as Dictionary
		if String(active_call.get("event_id", "")) != active_id:
			return _make_error("snapshot_phone_active_delivery_id_mismatch", "PhoneSystem 活动快照与 active event ID 不一致。")
		var active_identity_result: Dictionary = _validate_delivery_call_identity(active_request, active_call)
		if not bool(active_identity_result.get("ok", false)):
			return active_identity_result
		if int(active_call.get("ringing_started_tick", -1)) < int(active_request["created_at_tick"]):
			return _make_error("snapshot_phone_delivery_tick_mismatch", "动态来电不能早于 DeliveryRequest 创建时间：%s。" % active_id)
		observed[active_id] = true
	for raw_record: Variant in records_value as Array:
		if not raw_record is Dictionary:
			return _make_error("snapshot_delivery_phone_context_invalid", "PhoneSystem call_records 含非对象项。")
		var record: Dictionary = raw_record as Dictionary
		var event_id: String = String(record.get("event_id", ""))
		if not event_id.begins_with("delivery_call_"):
			continue
		if observed.has(event_id):
			return _make_error("snapshot_delivery_phone_duplicate", "同一动态来电不能同时活动且已有终态记录：%s。" % event_id)
		if not call_request_by_id.has(event_id):
			return _make_error("snapshot_phone_call_without_delivery", "动态来电记录缺少对应 DeliveryRequest：%s。" % event_id)
		var request: Dictionary = call_request_by_id[event_id] as Dictionary
		if String(request["status"]) != "committed":
			return _make_error("snapshot_phone_delivery_status_mismatch", "动态来电记录对应的 DeliveryRequest 必须 committed：%s。" % event_id)
		var identity_result: Dictionary = _validate_delivery_call_identity(request, record)
		if not bool(identity_result.get("ok", false)):
			return identity_result
		if int(record.get("time", -1)) < int(request["created_at_tick"]):
			return _make_error("snapshot_phone_delivery_tick_mismatch", "动态来电记录不能早于 DeliveryRequest 创建时间：%s。" % event_id)
		observed[event_id] = true
	for request: Dictionary in delivery_requests:
		if String(request["action_id"]) != "call_station":
			continue
		var delivery_id: String = String(request["delivery_id"])
		var should_exist: bool = String(request["status"]) == "committed"
		if observed.has(delivery_id) != should_exist:
			return _make_error("snapshot_delivery_phone_presence_mismatch", "call_station Delivery 与 PhoneSystem committed state 不一致：%s。" % delivery_id)
	return {"ok": true}


## interaction ID 对 delivery_call_* 的结构放行必须在 Delivery snapshot 校验后再次落到真实 request。
## 这样坏档不能仅靠伪造一个看起来合法的动态 ID 污染 answered/completed canonical state。
func _validate_dynamic_interaction_delivery_relationship(
	answered_ids: Array[String],
	completed_ids: Array[String],
	delivery_requests: Array[Dictionary]
) -> Dictionary:
	var committed_call_ids: Dictionary = {}
	for request: Dictionary in delivery_requests:
		if String(request["action_id"]) == "call_station" and String(request["status"]) == "committed":
			committed_call_ids[String(request["delivery_id"])] = true
	for ids: Array[String] in [answered_ids, completed_ids]:
		for event_id: String in ids:
			if not event_id.begins_with("delivery_call_"):
				continue
			if not committed_call_ids.has(event_id):
				return _make_error("snapshot_dynamic_interaction_without_delivery", "动态 Agent interaction 缺少 committed call_station DeliveryRequest：%s。" % event_id)
	return {"ok": true}


func _validate_delivery_call_identity(request: Dictionary, phone_value: Dictionary) -> Dictionary:
	var identity_value: Variant = _delivery_system.call(&"get_actor_call_identity", String(request["actor_id"]))
	if not identity_value is Dictionary or (identity_value as Dictionary).is_empty():
		return _make_error("snapshot_delivery_call_identity_missing", "call_station Actor 没有 authored 来电身份：%s。" % String(request["actor_id"]))
	var identity: Dictionary = identity_value as Dictionary
	if String(phone_value.get("caller_name", "")) != String(identity.get("caller_display_name", "")) or String(phone_value.get("caller_number", "")) != String(identity.get("caller_number", "")):
		return _make_error("snapshot_delivery_call_identity_mismatch", "动态来电来显与 Actor authored 身份不一致：%s。" % String(request["delivery_id"]))
	return {"ok": true}


func _validate_unauthorized_broadcast_record(value: Variant, is_ending_forced: bool) -> Dictionary:
	if not is_ending_forced:
		if value != null:
			return _make_error("snapshot_unauthorized_before_ending", "02:00 前不能保存未授权播出记录。")
		return {"ok": true, "record": null}
	if not value is Dictionary:
		return _make_error("snapshot_missing_unauthorized_record", "02:00 后必须保存未授权播出记录。")
	var record: Dictionary = value as Dictionary
	var expected: Dictionary = {
		"broadcast_id": "broadcast_unauthorized_north_bridge_open",
		"fact_id": "fact_unauthorized_broadcast",
		"sent_at_tick": ENDING_TICK,
		"time_tick": ENDING_TICK,
		"source": "Studio A",
		"body": "北桥已经恢复通行。请保持车速，不要停车。",
		"is_unauthorized": true,
	}
	if record.size() != expected.size():
		return _make_error("snapshot_unauthorized_record_invalid", "未授权播出记录字段不完整或包含未知字段。")
	for field_name: String in expected:
		if not record.has(field_name):
			return _make_error("snapshot_unauthorized_record_invalid", "未授权播出记录与 02:00 权威事件不一致。")
		if field_name == "sent_at_tick" or field_name == "time_tick":
			var tick_result: Dictionary = _validate_snapshot_integer(record[field_name], field_name, ENDING_TICK, ENDING_TICK)
			if not bool(tick_result.get("ok", false)):
				return _make_error("snapshot_unauthorized_record_invalid", "未授权播出记录与 02:00 权威事件不一致。")
		elif record[field_name] != expected[field_name]:
			return _make_error("snapshot_unauthorized_record_invalid", "未授权播出记录与 02:00 权威事件不一致。")
	return {"ok": true, "record": expected}


func _dialogue_node_belongs_to_event(node_id: String, event_id: String) -> bool:
	if not _story_event_by_id.has(event_id):
		return false
	var event_data: Dictionary = _story_event_by_id[event_id] as Dictionary
	var start_node_id: String = String(event_data.get("dialogue_start_id", ""))
	var pending_node_ids: Array[String] = [start_node_id]
	var visited: Dictionary = {}
	while not pending_node_ids.is_empty():
		var current_node_id: String = pending_node_ids.pop_back()
		if current_node_id == node_id:
			return true
		if visited.has(current_node_id) or not _dialogue_node_by_id.has(current_node_id):
			continue
		visited[current_node_id] = true
		var node: Dictionary = _dialogue_node_by_id[current_node_id] as Dictionary
		for option: Dictionary in node["options"] as Array:
			pending_node_ids.append(String(option["next_node_id"]))
	return false


func _sorted_bool_state(source: Dictionary) -> Dictionary:
	var sorted_ids: Array[String] = _sorted_dictionary_keys(source)
	var result: Dictionary = {}
	for stable_id: String in sorted_ids:
		result[stable_id] = bool(source[stable_id])
	return result


func _sorted_dictionary_keys(source: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_id: Variant in source:
		ids.append(String(raw_id))
	ids.sort()
	return ids


func _string_array_to_lookup(ids: Array[String]) -> Dictionary:
	var lookup: Dictionary = {}
	for stable_id: String in ids:
		lookup[stable_id] = true
	return lookup


func _snapshot_message(value: Variant) -> String:
	if value is Dictionary:
		return String((value as Dictionary).get("message", "未知错误。"))
	return "返回值不是有效结果。"


## 中央麦克风的统一发布任务只读接口。任务资格只由 StoryEngine 的权威剧情状态派生：
## required_dialogue_event_ids 必须全部完成；information_items 只有其 statement_ids
## 全部真正揭示后才会出现在 available_information_items 中。UI 不自行推断这些状态。
func get_broadcast_tasks() -> Array[Dictionary]:
	var tasks: Array[Dictionary] = []
	var task_ids: Array[String] = _sorted_dictionary_keys(_broadcast_task_by_id)
	for task_id: String in task_ids:
		var task_snapshot: Dictionary = _build_broadcast_task_snapshot(task_id)
		if not bool(task_snapshot.get("is_abandoned", false)):
			tasks.append(task_snapshot)
	return tasks


func abandon_broadcast_task(task_id: String) -> Dictionary:
	var state_result: Dictionary = _get_actionable_broadcast_decision(task_id, true)
	if not bool(state_result.get("ok", false)):
		return state_result
	_broadcast_decision_by_task_id[task_id] = {
		"status": "abandoned",
		"available_information_item_ids": (state_result["available_information_item_ids"] as Array[String]).duplicate(),
	}
	var failure_value: Variant = _task_system.call(&"fail_task", task_id, _current_game_tick, "player_abandoned")
	if not failure_value is Dictionary or not bool((failure_value as Dictionary).get("ok", false)):
		return _make_error("task_abandon_commit_failed", "发布任务 UI 已进入 abandoned，但 TaskSystem 未能提交 failed：%s" % _snapshot_message(failure_value))
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	print("[剧情][%s] 发布任务已永久放弃；不再显示、通知、触发或发送。" % task_id)
	broadcast_state_changed.emit()
	return {"ok": true, "task_id": task_id, "decision": "abandoned", "message": "已放弃本局发布任务；它不会再次出现。"}


func defer_broadcast_task(task_id: String) -> Dictionary:
	var state_result: Dictionary = _get_actionable_broadcast_decision(task_id, false)
	if not bool(state_result.get("ok", false)):
		return state_result
	_broadcast_decision_by_task_id[task_id] = {
		"status": "deferred",
		"available_information_item_ids": (state_result["available_information_item_ids"] as Array[String]).duplicate(),
	}
	print("[剧情][%s] 发布任务已推迟；解除待决暂停，等待新的可用信息。" % task_id)
	broadcast_state_changed.emit()
	return {"ok": true, "task_id": task_id, "decision": "deferred", "message": "已推迟广播；新的相关信息到达时会再次提醒。"}


func has_pending_broadcast_decision() -> bool:
	for state_value: Variant in _broadcast_decision_by_task_id.values():
		if state_value is Dictionary and String((state_value as Dictionary).get("status", "")) == "pending":
			return true
	return false


func _get_actionable_broadcast_decision(task_id: String, allow_deferred: bool) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "测试剧情尚未配置，不能处理发布任务。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能处理发布任务。")
	if not _broadcast_task_by_id.has(task_id):
		return _make_error("unknown_broadcast_task", "不存在发布任务：%s。" % task_id)
	var state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
	var status: String = String(state.get("status", ""))
	if status != "pending" and (not allow_deferred or status != "deferred"):
		return _make_error("broadcast_task_not_pending", "该发布任务当前不在待处理状态。")
	return {"ok": true, "available_information_item_ids": state.get("available_information_item_ids", []) as Array}


## 玩家公告记录的只读接口；不包含 02:00 的异常记录。fact_ids 仅来自本次实际选择
## 的 information_item_ids，而不是任务中尚未播出的其它可选信息。
func get_player_broadcast_records() -> Array[Dictionary]:
	var result: Variant = _broadcast_system.call(&"get_player_broadcast_records")
	if not result is Array:
		_make_error("invalid_broadcast_system_result", "BroadcastSystem.get_player_broadcast_records() 必须返回 Array。")
		return []
	var records: Array[Dictionary] = []
	for raw_record: Variant in result as Array:
		if not raw_record is Dictionary:
			continue
		var record: Dictionary = (raw_record as Dictionary).duplicate(true)
		var task_id: String = String(record.get("task_id", ""))
		var fact_lookup: Dictionary = {}
		if _broadcast_task_by_id.has(task_id):
			var selected_ids: Array = record.get("information_item_ids", []) as Array
			var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
			for raw_item: Variant in task["information_items"] as Array:
				var item: Dictionary = raw_item as Dictionary
				if not selected_ids.has(String(item["id"])):
					continue
				for fact_id_variant: Variant in item["fact_ids"] as Array:
					fact_lookup[String(fact_id_variant)] = true
		record["fact_ids"] = _sorted_dictionary_keys(fact_lookup)
		record.make_read_only()
		records.append(record)
	return records


## SignalSystem 的只读世界观察接口；返回 committed SignalRecord，不暴露可写内部状态。
## Actor 感知查询也只来自已提交 recipients；AgentRuntime 用它授权 canonical state 更新。
func get_signal_state() -> Dictionary:
	var result: Variant = _signal_system.call(&"get_state_summary")
	if result is Dictionary:
		return (result as Dictionary).duplicate(true)
	return {"available": false, "records": []}


func get_actor_perceived_signal_ids(actor_id: String) -> Array[String]:
	var result: Variant = _signal_system.call(&"get_actor_perceived_signal_ids", actor_id)
	var ids: Array[String] = []
	if result is Array:
		for raw_id: Variant in result as Array:
			if raw_id is String:
				ids.append(String(raw_id))
	return ids


## DeliverySystem 只读世界观察接口。DirectorContext / 调试 UI 只能读取结构化请求状态。
func get_delivery_state() -> Dictionary:
	var result: Variant = _delivery_system.call(&"get_state_summary")
	if result is Dictionary:
		return (result as Dictionary).duplicate(true)
	return {"available": false, "requests": []}


## ActorAction external validator 使用的只读世界校验。它与正式提交经过同一个 DeliverySystem
## 合同，但不会分配 delivery serial、改变 Phone/Computer 或写入 committed state。
func validate_delivery_request(
	actor_id: String,
	action_id: String,
	arguments: Dictionary,
	source_opportunity_id: String = "",
	source_director_plan_id: String = ""
) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "剧情尚未配置，不能校验 DeliveryRequest。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束后不能创建 DeliveryRequest。")
	var result: Variant = _delivery_system.call(
		&"validate_request_intent",
		actor_id,
		action_id,
		arguments,
		source_opportunity_id,
		source_director_plan_id
	)
	if not result is Dictionary:
		return _make_error("invalid_delivery_system_result", "DeliverySystem.validate_request_intent() 必须返回 Dictionary。")
	return result as Dictionary


## Actor / Director approved intent 的唯一世界提交入口。模型不得绕过这里直接调用电话或电脑。
func submit_delivery_request(
	actor_id: String,
	action_id: String,
	arguments: Dictionary,
	source_opportunity_id: String = "",
	source_director_plan_id: String = ""
) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "剧情尚未配置，不能提交 DeliveryRequest。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束后不能提交 DeliveryRequest。")
	var result: Variant = _delivery_system.call(
		&"submit_delivery_request",
		actor_id,
		action_id,
		arguments,
		_current_game_tick,
		source_opportunity_id,
		source_director_plan_id
	)
	if not result is Dictionary:
		return _make_error("invalid_delivery_system_result", "DeliverySystem.submit_delivery_request() 必须返回 Dictionary。")
	return result as Dictionary


## 玩家执行麦克风发布任务的唯一意图入口。最低门槛未满足、信息未揭示、重复任务或 02:00 后请求都会拒绝。
func send_broadcast_task(task_id: String, information_item_ids: Array) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "测试剧情尚未配置，不能执行发布任务。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能执行玩家发布任务。")
	if not _broadcast_task_by_id.has(task_id):
		return _make_error("unknown_broadcast_task", "不存在发布任务：%s。" % task_id)
	var task_snapshot: Dictionary = _build_broadcast_task_snapshot(task_id)
	if bool(task_snapshot.get("is_abandoned", false)):
		return _make_error("broadcast_task_abandoned", "该发布任务已在本局永久放弃，不能发送。")
	if bool(task_snapshot["is_sent"]):
		return _make_error("broadcast_task_already_sent", "该发布任务本局已经完成，不能重复发布。")
	if not bool(task_snapshot["prerequisites_met"]):
		return _make_error("broadcast_task_prerequisites_unmet", "该发布任务尚未完成最低必要对话。")
	var selected_ids: Array[String] = []
	for raw_information_id: Variant in information_item_ids:
		if not raw_information_id is String:
			return _make_error("broadcast_task_information_invalid", "所选信息项 ID 必须是字符串。")
		selected_ids.append(String(raw_information_id))
	var selection_mode: String = String(task_snapshot.get("selection_mode", ""))
	if selected_ids.is_empty() or (selection_mode == "single" and selected_ids.size() != 1):
		return _make_error("information_selection_count_invalid", "该任务要求选择%s条已经收集的信息。" % ("恰好一" if selection_mode == "single" else "至少一"))
	var available_lookup: Dictionary = {}
	for raw_item: Variant in task_snapshot["available_information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		available_lookup[String(item["id"])] = true
	var seen_selection: Dictionary = {}
	for information_id: String in selected_ids:
		if seen_selection.has(information_id):
			return _make_error("broadcast_task_duplicate_information", "同一信息项不能重复选择。")
		seen_selection[information_id] = true
		if not available_lookup.has(information_id):
			return _make_error("broadcast_task_information_unavailable", "所选信息尚未在剧情中真正揭示，不能发布：%s。" % information_id)
	var result_value: Variant = _broadcast_system.call(&"send_task_publication", task_id, selected_ids, _current_game_tick)
	if not result_value is Dictionary:
		return _make_error("invalid_broadcast_system_result", "BroadcastSystem.send_task_publication() 必须返回带 ok 的 Dictionary。")
	var result: Dictionary = result_value as Dictionary
	if not bool(result.get("ok", false)):
		return result
	_broadcast_decision_by_task_id[task_id] = {
		"status": "sent",
		"available_information_item_ids": _get_available_information_item_ids(task_id, _revealed_statement_ids),
	}
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		return task_refresh
	var condition_id: String = String(result.get("sets_condition_id", ""))
	if not condition_id.is_empty():
		var condition_result: Dictionary = set_condition_state(condition_id, true)
		if not bool(condition_result.get("ok", false)):
			return condition_result
		print("[剧情][%s] 玩家发布任务已设置条件。" % condition_id)
	broadcast_state_changed.emit()
	return result


func _build_broadcast_task_snapshot(task_id: String) -> Dictionary:
	if _broadcast_task_by_id.has(task_id):
		var agent_task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
		if agent_task.has("requirements"):
			return _build_agent_broadcast_task_snapshot(task_id, agent_task)
	if not _broadcast_task_by_id.has(task_id):
		return {}
	var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
	var required_ids: Array = task["required_dialogue_event_ids"] as Array
	var completed_required_ids: Array[String] = []
	for event_id_variant: Variant in required_ids:
		var event_id: String = String(event_id_variant)
		if _completed_dialogue_event_ids.has(event_id):
			completed_required_ids.append(event_id)
	var available_items: Array[Dictionary] = []
	for raw_item: Variant in task["information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		var all_statements_revealed: bool = true
		for statement_id_variant: Variant in item["statement_ids"] as Array:
			if not _revealed_statement_ids.has(String(statement_id_variant)):
				all_statements_revealed = false
				break
		if all_statements_revealed:
			var public_item: Dictionary = item.duplicate(true)
			public_item.make_read_only()
			available_items.append(public_item)
	var is_sent_value: Variant = _broadcast_system.call(&"is_task_sent", task_id)
	var is_sent: bool = bool(is_sent_value) if typeof(is_sent_value) == TYPE_BOOL else false
	var decision_state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
	var decision_status: String = String(decision_state.get("status", "unseen"))
	var is_abandoned: bool = decision_status == "abandoned"
	var prerequisites_met: bool = completed_required_ids.size() == required_ids.size()
	var is_publishable: bool = prerequisites_met and not is_sent and not is_abandoned and not available_items.is_empty()
	var disabled_reason: String = ""
	if is_abandoned:
		disabled_reason = "该任务已在本局放弃。"
	elif is_sent:
		disabled_reason = "该任务已发布。"
	elif not prerequisites_met:
		disabled_reason = "必要通话尚未完成（%d/%d）。" % [completed_required_ids.size(), required_ids.size()]
	elif available_items.is_empty():
		disabled_reason = "必要通话已完成，但尚没有可发布的已揭示信息。"
	var snapshot: Dictionary = {
		"id": task_id,
		"name": String(task["name"]),
		"selection_mode": String(task["selection_mode"]),
		"channel": String(task["channel"]),
		"source": String(task["source"]),
		"related_dialogue_event_ids": (task["related_dialogue_event_ids"] as Array).duplicate(true),
		"required_dialogue_event_ids": required_ids.duplicate(true),
		"completed_required_dialogue_event_ids": completed_required_ids,
		"required_dialogue_count": required_ids.size(),
		"completed_required_dialogue_count": completed_required_ids.size(),
		"prerequisites_met": prerequisites_met,
		"available_information_items": available_items,
		"total_information_item_count": (task["information_items"] as Array).size(),
		"available_information_item_count": available_items.size(),
		"is_sent": is_sent,
		"is_abandoned": is_abandoned,
		"decision_status": decision_status,
		"is_publishable": is_publishable,
		"disabled_reason": disabled_reason,
	}
	snapshot.make_read_only()
	return snapshot


func _build_agent_broadcast_task_snapshot(task_id: String, task: Dictionary) -> Dictionary:
	var requirements: Array = task["requirements"] as Array
	var satisfied_requirements: Array[Dictionary] = []
	for raw_requirement: Variant in requirements:
		var requirement: Dictionary = raw_requirement as Dictionary
		if _is_semantic_requirement_met(requirement):
			satisfied_requirements.append(requirement.duplicate(true))
	var available_items: Array[Dictionary] = []
	for raw_item: Variant in task["information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		var all_statements_revealed: bool = true
		for statement_id_variant: Variant in item["statement_ids"] as Array:
			if not _revealed_statement_ids.has(String(statement_id_variant)):
				all_statements_revealed = false
				break
		if all_statements_revealed:
			var public_item: Dictionary = item.duplicate(true)
			public_item.make_read_only()
			available_items.append(public_item)
	var is_sent_value: Variant = _broadcast_system.call(&"is_task_sent", task_id)
	var is_sent: bool = bool(is_sent_value) if typeof(is_sent_value) == TYPE_BOOL else false
	var decision_state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
	var decision_status: String = String(decision_state.get("status", "unseen"))
	var is_abandoned: bool = decision_status == "abandoned"
	var prerequisites_met: bool = satisfied_requirements.size() == requirements.size()
	var is_publishable: bool = prerequisites_met and not is_sent and not is_abandoned and not available_items.is_empty()
	var disabled_reason: String = ""
	if is_abandoned:
		disabled_reason = "该任务已在本局放弃。"
	elif is_sent:
		disabled_reason = "该任务已发布。"
	elif not prerequisites_met:
		disabled_reason = "必要信息条件尚未满足（%d/%d）。" % [satisfied_requirements.size(), requirements.size()]
	elif available_items.is_empty():
		disabled_reason = "必要条件已满足，但尚没有可发布的已揭示信息。"
	var snapshot: Dictionary = {
		"id": task_id,
		"name": String(task["name"]),
		"selection_mode": String(task["selection_mode"]),
		"channel": String(task["channel"]),
		"source": String(task["source"]),
		"related_event_ids": (task["related_event_ids"] as Array).duplicate(true),
		"requirements": requirements.duplicate(true),
		"satisfied_requirements": satisfied_requirements,
		"requirement_count": requirements.size(),
		"satisfied_requirement_count": satisfied_requirements.size(),
		"prerequisites_met": prerequisites_met,
		"available_information_items": available_items,
		"total_information_item_count": (task["information_items"] as Array).size(),
		"available_information_item_count": available_items.size(),
		"is_sent": is_sent,
		"is_abandoned": is_abandoned,
		"decision_status": decision_status,
		"is_publishable": is_publishable,
		"disabled_reason": disabled_reason,
	}
	snapshot.make_read_only()
	return snapshot


func _build_task_definitions(broadcast_tasks: Array) -> Array[Dictionary]:
	var definitions: Array[Dictionary] = []
	for raw_task: Variant in broadcast_tasks:
		if not raw_task is Dictionary:
			continue
		var task: Dictionary = raw_task as Dictionary
		var task_id: String = String(task.get("id", ""))
		if task_id.is_empty():
			continue
		var activation_requirements: Array[Dictionary] = []
		if task.has("requirements") and task["requirements"] is Array:
			for raw_requirement: Variant in task["requirements"] as Array:
				if raw_requirement is Dictionary:
					activation_requirements.append((raw_requirement as Dictionary).duplicate(true))
		elif task.has("required_dialogue_event_ids") and task["required_dialogue_event_ids"] is Array:
			for raw_event_id: Variant in task["required_dialogue_event_ids"] as Array:
				activation_requirements.append({"type": "dialogue_completed", "id": String(raw_event_id)})
		# 任务只有在至少一个可发布信息项真正进入权威世界后才激活；这把旧 UI 的
		# “有可用信息”推断纳入 TaskSystem，而不改变现有 broadcast task ID。
		activation_requirements.append({"type": "information_available", "id": task_id})
		definitions.append({
			"id": task_id,
			"activation": {"mode": "all", "requirements": activation_requirements},
			"completion": {"type": "broadcast_sent", "id": task_id},
		})
	return definitions


func _build_task_world_state() -> Dictionary:
	var sent_task_ids: Array[String] = []
	var information_available_task_ids: Array[String] = []
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		var sent_value: Variant = _broadcast_system.call(&"is_task_sent", task_id)
		if typeof(sent_value) == TYPE_BOOL and bool(sent_value):
			sent_task_ids.append(task_id)
		if not _get_available_information_item_ids(task_id, _revealed_statement_ids).is_empty():
			information_available_task_ids.append(task_id)
	var read_message_ids: Array[String] = []
	var entries_value: Variant = _computer_system.call(&"get_entries", "messages")
	if entries_value is Array:
		for raw_entry: Variant in entries_value as Array:
			if not raw_entry is Dictionary:
				continue
			var entry: Dictionary = raw_entry as Dictionary
			if bool(entry.get("read", false)):
				var source_id: String = String(entry.get("id", entry.get("source_id", "")))
				if not source_id.is_empty() and not read_message_ids.has(source_id):
					read_message_ids.append(source_id)
	read_message_ids.sort()
	var outcome_event_ids: Array[String] = []
	var outcomes_value: Variant = _interaction_outcome_system.call(&"get_outcome_event_ids")
	if outcomes_value is Array:
		for raw_event_id: Variant in outcomes_value as Array:
			if raw_event_id is String:
				outcome_event_ids.append(String(raw_event_id))
	outcome_event_ids.sort()
	return {
		"statement_revealed_ids": _sorted_dictionary_keys(_revealed_statement_ids),
		"fact_confirmed_ids": _sorted_dictionary_keys(_confirmed_fact_ids),
		"condition_state_by_id": _sorted_bool_state(_condition_state_by_id),
		"interaction_answered_ids": _sorted_dictionary_keys(_answered_interaction_event_ids),
		"interaction_completed_ids": _sorted_dictionary_keys(_completed_interaction_event_ids),
		"broadcast_sent_ids": sent_task_ids,
		"message_read_ids": read_message_ids,
		"dialogue_completed_ids": _sorted_dictionary_keys(_completed_dialogue_event_ids),
		"information_available_task_ids": information_available_task_ids,
		"interaction_outcome_event_ids": outcome_event_ids,
	}


## Snapshot 校验不能读取当前运行时子系统状态；读取槽位时这些系统尚未 restore。
## 因此只从各子系统已经规范化的候选快照重建 TaskSystem 所需的只读 world_state。
func _build_snapshot_task_world_state(
	revealed_statement_ids: Array[String],
	confirmed_fact_ids: Array[String],
	condition_states: Dictionary,
	answered_interaction_ids: Array[String],
	completed_interaction_ids: Array[String],
	completed_dialogue_ids: Array[String],
	normalized_broadcast: Dictionary,
	normalized_computer: Dictionary,
	outcome_by_event_id: Dictionary
) -> Dictionary:
	var revealed_lookup: Dictionary = _string_array_to_lookup(revealed_statement_ids)
	var information_available_task_ids: Array[String] = []
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		if not _get_available_information_item_ids(task_id, revealed_lookup).is_empty():
			information_available_task_ids.append(task_id)
	var outcome_event_ids: Array[String] = _sorted_dictionary_keys(outcome_by_event_id)
	return {
		"statement_revealed_ids": revealed_statement_ids.duplicate(),
		"fact_confirmed_ids": confirmed_fact_ids.duplicate(),
		"condition_state_by_id": condition_states.duplicate(true),
		"interaction_answered_ids": answered_interaction_ids.duplicate(),
		"interaction_completed_ids": completed_interaction_ids.duplicate(),
		"broadcast_sent_ids": (normalized_broadcast["sent_task_ids"] as Array[String]).duplicate(),
		"message_read_ids": ((normalized_computer["read_source_ids"] as Dictionary)["messages"] as Array[String]).duplicate(),
		"dialogue_completed_ids": completed_dialogue_ids.duplicate(),
		"information_available_task_ids": information_available_task_ids,
		"interaction_outcome_event_ids": outcome_event_ids,
	}


func _get_task_transition_recipients(task_id: String) -> Array[String]:
	var recipients: Array[String] = []
	if not _broadcast_task_by_id.has(task_id):
		return recipients
	var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
	var related_ids: Array = task.get("related_event_ids", task.get("related_dialogue_event_ids", [])) as Array
	for raw_event_id: Variant in related_ids:
		var event_id: String = String(raw_event_id)
		if not _story_event_by_id.has(event_id):
			continue
		var event_data: Dictionary = _story_event_by_id[event_id] as Dictionary
		var actor_id: String = String(event_data.get("actor_id", ""))
		if not actor_id.is_empty() and _actor_definition_by_id.has(actor_id) and not recipients.has(actor_id):
			recipients.append(actor_id)
	recipients.sort()
	return recipients


func _refresh_task_system() -> Dictionary:
	var refresh_value: Variant = _task_system.call(&"refresh", _build_task_world_state(), _current_game_tick)
	if not refresh_value is Dictionary or not bool((refresh_value as Dictionary).get("ok", false)):
		return _make_error("task_refresh_failed", "TaskSystem 刷新失败：%s" % _snapshot_message(refresh_value))
	var refresh_result: Dictionary = refresh_value as Dictionary
	# 每次都对完整 transition 历史做幂等 Signal reconciliation；这样即使前一次
	# Observation 提交被内部错误打断，下一次 refresh 仍能补齐而不重放 Task transition。
	var transition_records_value: Variant = _task_system.call(&"get_transition_records")
	if not transition_records_value is Array:
		return _make_error("task_transition_contract_invalid", "TaskSystem.get_transition_records() 必须返回数组。")
	for raw_record: Variant in transition_records_value as Array:
		if not raw_record is Dictionary:
			return _make_error("task_transition_contract_invalid", "TaskSystem transition record 必须是对象。")
		var record: Dictionary = raw_record as Dictionary
		var signal_value: Variant = _signal_system.call(&"commit_task_transition", record, _get_task_transition_recipients(String(record["task_id"])))
		if not signal_value is Dictionary or not bool((signal_value as Dictionary).get("ok", false)):
			return _make_error("task_transition_signal_failed", "Task transition 已提交，但 SignalSystem reconciliation 失败：%s" % _snapshot_message(signal_value))
	for raw_transition: Variant in refresh_result.get("transitions", []) as Array:
		if raw_transition is Dictionary:
			var transition: Dictionary = raw_transition as Dictionary
			task_state_changed.emit(String(transition["task_id"]), String(transition["to_status"]))
	return refresh_result


func _is_semantic_requirement_met(requirement: Dictionary) -> bool:
	var evaluation_value: Variant = _task_system.call(&"evaluate_requirements", [requirement.duplicate(true)], _build_task_world_state())
	return evaluation_value is Dictionary and bool((evaluation_value as Dictionary).get("ok", false)) and bool((evaluation_value as Dictionary).get("satisfied", false))


func _are_task_requirements_met(task: Dictionary) -> bool:
	if not task.has("requirements") or not task["requirements"] is Array:
		return false
	for raw_requirement: Variant in task["requirements"] as Array:
		if not raw_requirement is Dictionary or not _is_semantic_requirement_met(raw_requirement as Dictionary):
			return false
	return true


func _get_available_information_item_ids(task_id: String, revealed_lookup: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	if not _broadcast_task_by_id.has(task_id):
		return ids
	var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
	for raw_item: Variant in task["information_items"] as Array:
		var item: Dictionary = raw_item as Dictionary
		var all_revealed: bool = true
		for statement_id_variant: Variant in item["statement_ids"] as Array:
			if not revealed_lookup.has(String(statement_id_variant)):
				all_revealed = false
				break
		if all_revealed:
			ids.append(String(item["id"]))
	return ids


func _refresh_broadcast_decisions(emit_notifications: bool) -> void:
	if is_agent_dialogue_v2():
		_refresh_agent_broadcast_decisions(emit_notifications)
		return
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		var current_ids: Array[String] = _get_available_information_item_ids(task_id, _revealed_statement_ids)
		var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
		var required_ids: Array = task["required_dialogue_event_ids"] as Array
		var prerequisites_met: bool = true
		for event_id_variant: Variant in required_ids:
			if not _completed_dialogue_event_ids.has(String(event_id_variant)):
				prerequisites_met = false
				break
		var is_sent: bool = bool(_broadcast_system.call(&"is_task_sent", task_id))
		var old_state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
		var old_status: String = String(old_state.get("status", "unseen"))
		var old_ids: Array = old_state.get("available_information_item_ids", []) as Array
		var has_new_information: bool = false
		for information_id: String in current_ids:
			if not old_ids.has(information_id):
				has_new_information = true
				break
		var next_status: String = old_status
		if is_sent:
			next_status = "sent"
		elif old_status == "abandoned":
			next_status = "abandoned"
		elif prerequisites_met and not current_ids.is_empty() and (old_status == "unseen" or (old_status == "deferred" and has_new_information)):
			next_status = "pending"
		_broadcast_decision_by_task_id[task_id] = {"status": next_status, "available_information_item_ids": current_ids.duplicate()}
		if next_status == "pending" and next_status != old_status and emit_notifications:
			var notice: Dictionary = _build_broadcast_task_snapshot(task_id)
			broadcast_decision_required.emit(notice)
			print("[剧情][%s] 发布任务进入待决状态，items=%s。" % [task_id, str(current_ids)])


func _refresh_agent_broadcast_decisions(emit_notifications: bool) -> void:
	for task_id: String in _sorted_dictionary_keys(_broadcast_task_by_id):
		var current_ids: Array[String] = _get_available_information_item_ids(task_id, _revealed_statement_ids)
		var task: Dictionary = _broadcast_task_by_id[task_id] as Dictionary
		var prerequisites_met: bool = _are_task_requirements_met(task)
		var is_sent: bool = bool(_broadcast_system.call(&"is_task_sent", task_id))
		var old_state: Dictionary = _broadcast_decision_by_task_id.get(task_id, {}) as Dictionary
		var old_status: String = String(old_state.get("status", "unseen"))
		var old_ids: Array = old_state.get("available_information_item_ids", []) as Array
		var has_new_information: bool = false
		for information_id: String in current_ids:
			if not old_ids.has(information_id):
				has_new_information = true
				break
		var next_status: String = old_status
		if is_sent:
			next_status = "sent"
		elif old_status == "abandoned":
			next_status = "abandoned"
		elif prerequisites_met and not current_ids.is_empty() and (old_status == "unseen" or (old_status == "deferred" and has_new_information)):
			next_status = "pending"
		_broadcast_decision_by_task_id[task_id] = {"status": next_status, "available_information_item_ids": current_ids.duplicate()}
		if next_status == "pending" and next_status != old_status and emit_notifications:
			var notice: Dictionary = _build_broadcast_task_snapshot(task_id)
			broadcast_decision_required.emit(notice)
			print("[剧情][%s] Agent semantic requirements 已满足，发布任务进入待决状态，items=%s。" % [task_id, str(current_ids)])


func get_unlocked_messages() -> Array[Dictionary]:
	return get_computer_entries("messages")


## 电脑 UI 只从 StoryEngine 的薄接口读取来源状态，不能自行维护另一份未读或
## 已读列表。call_log 始终由 ComputerSystem 从 PhoneSystem 已生成记录派生。
func get_computer_entries(category: String) -> Array[Dictionary]:
	var entries_value: Variant = _computer_system.call(&"get_entries", category)
	if not entries_value is Array:
		_make_error("invalid_computer_system_result", "ComputerSystem.get_entries() 必须返回 Array。")
		return []
	var entries: Array[Dictionary] = []
	for raw_entry: Variant in entries_value as Array:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = (raw_entry as Dictionary).duplicate(true)
		if category == "call_log":
			_decorate_call_log_entry(entry)
		entry.make_read_only()
		entries.append(entry)
	return entries


func get_computer_unread_count(category: String) -> int:
	var unread_count_value: Variant = _computer_system.call(&"get_unread_count", category)
	if typeof(unread_count_value) != TYPE_INT:
		_make_error("invalid_computer_system_result", "ComputerSystem.get_unread_count() 必须返回整数。")
		return 0
	return int(unread_count_value)


## 阅读来源由 ComputerSystem 原子记录；它的 source_read 信号会同步调用
## _reveal_statement_ids，因此返回成功时可直接查询新的陈述/事实状态。
func mark_computer_entry_read(category: String, source_id: String) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "测试剧情尚未配置，不能阅读电脑信息。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能再阅读电脑信息。")
	var result_value: Variant = _computer_system.call(&"mark_entry_read", category, source_id)
	if not result_value is Dictionary:
		return _make_error("invalid_computer_system_result", "ComputerSystem.mark_entry_read() 必须返回带 ok 的 Dictionary。")
	return result_value as Dictionary


func is_statement_revealed(statement_id: String) -> bool:
	return _revealed_statement_ids.has(statement_id)


func get_statement_snapshot(statement_id: String) -> Dictionary:
	if not _statement_by_id.has(statement_id):
		return {}
	var snapshot: Dictionary = (_statement_by_id[statement_id] as Dictionary).duplicate(true)
	snapshot["is_revealed"] = _revealed_statement_ids.has(statement_id)
	snapshot.make_read_only()
	return snapshot


func get_revealed_statements() -> Array[Dictionary]:
	var statements: Array[Dictionary] = []
	for statement_id_variant: Variant in _statement_by_id.keys():
		var statement_id: String = String(statement_id_variant)
		if _revealed_statement_ids.has(statement_id):
			statements.append(get_statement_snapshot(statement_id))
	statements.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return String(first["id"]) < String(second["id"])
	)
	return statements


func is_fact_confirmed(fact_id: String) -> bool:
	return _confirmed_fact_ids.has(fact_id)


func get_fact_snapshot(fact_id: String) -> Dictionary:
	if not _fact_by_id.has(fact_id):
		return {}
	var snapshot: Dictionary = (_fact_by_id[fact_id] as Dictionary).duplicate(true)
	snapshot["is_confirmed"] = _confirmed_fact_ids.has(fact_id)
	snapshot.make_read_only()
	return snapshot


func get_confirmed_facts() -> Array[Dictionary]:
	var facts: Array[Dictionary] = []
	for fact_id_variant: Variant in _fact_by_id.keys():
		var fact_id: String = String(fact_id_variant)
		if _confirmed_fact_ids.has(fact_id):
			facts.append(get_fact_snapshot(fact_id))
	facts.sort_custom(func(first: Dictionary, second: Dictionary) -> bool:
		return String(first["id"]) < String(second["id"])
	)
	return facts


## 电话近景在 PhoneSystem 已进入 DialogueChoice 后调用；它不会自行变更电话状态。
func begin_active_call_dialogue() -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "测试剧情尚未配置，不能开始对话。")
	if _phone_system == null or not _phone_system.has_method(&"get_active_event_id") or not _phone_system.has_method(&"get_state_name"):
		return _make_error("invalid_phone_system_contract", "PhoneSystem 缺少开始预制对话所需接口。")
	var event_id_value: Variant = _phone_system.call(&"get_active_event_id")
	if typeof(event_id_value) != TYPE_STRING or not _story_event_by_id.has(String(event_id_value)):
		return _make_error("missing_dialogue_event", "当前电话线路没有可用的测试剧情对话。")
	var event_id: String = String(event_id_value)
	if not _active_dialogue_event_id.is_empty():
		if _active_dialogue_event_id == event_id:
			return _make_error("dialogue_already_started", "本通电话的预制对话已经开始，不能从入口重复播放。")
		return _make_error("another_dialogue_active", "另一通电话的预制对话尚未清理，拒绝覆盖。")
	var state_value: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_value) != TYPE_STRING or String(state_value) != "DIALOGUE_CHOICE":
		return _make_error("invalid_dialogue_phone_state", "只有电话处于 DialogueChoice 时才能开始预制对话。")
	var event_data: Dictionary = _story_event_by_id[event_id] as Dictionary
	var start_node_id: String = String(event_data["dialogue_start_id"])
	if not _dialogue_node_by_id.has(start_node_id):
		return _make_error("missing_dialogue_node", "当前电话线路的对话入口不存在。")
	_active_dialogue_event_id = event_id
	_active_dialogue_node_id = start_node_id
	var start_reveal_result: Dictionary = _reveal_statement_ids(((_dialogue_node_by_id[start_node_id] as Dictionary)["reveals_statement_ids"] as Array), event_id)
	if not bool(start_reveal_result.get("ok", false)):
		_clear_active_dialogue()
		return start_reveal_result
	var snapshot: Dictionary = get_active_dialogue_snapshot()
	dialogue_changed.emit(snapshot)
	return {"ok": true, "snapshot": snapshot}


## 选择当前节点的预制选项。到达终止节点后调用者应将 PhoneSystem 从
## DialogueChoice 切回 Connected，保留终止台词直至玩家正常结束通话。
func select_dialogue_option(option_id: String) -> Dictionary:
	if _active_dialogue_node_id.is_empty() or not _dialogue_node_by_id.has(_active_dialogue_node_id):
		return _make_error("no_active_dialogue", "当前没有可提交的预制对话选项。")
	var current_node: Dictionary = _dialogue_node_by_id[_active_dialogue_node_id] as Dictionary
	if bool(current_node["is_terminal"]):
		return _make_error("dialogue_already_terminal", "当前对话已经到达结尾，请结束通话。")
	for option: Dictionary in current_node["options"] as Array:
		if String(option["id"]) != option_id:
			continue
		var option_reveal_result: Dictionary = _reveal_statement_ids(option["reveals_statement_ids"] as Array, _active_dialogue_event_id)
		if not bool(option_reveal_result.get("ok", false)):
			return option_reveal_result
		_active_dialogue_node_id = String(option["next_node_id"])
		var successor_node: Dictionary = _dialogue_node_by_id[_active_dialogue_node_id] as Dictionary
		var successor_reveal_result: Dictionary = _reveal_statement_ids(successor_node["reveals_statement_ids"] as Array, _active_dialogue_event_id)
		if not bool(successor_reveal_result.get("ok", false)):
			return successor_reveal_result
		var snapshot: Dictionary = get_active_dialogue_snapshot()
		var reached_terminal: bool = bool(snapshot["is_terminal"])
		if reached_terminal:
			var completion_result: Dictionary = _mark_dialogue_completed(_active_dialogue_event_id)
			if not bool(completion_result.get("ok", false)):
				return completion_result
		dialogue_changed.emit(snapshot)
		return {"ok": true, "snapshot": snapshot, "reached_terminal": reached_terminal}
	return _make_error("unknown_dialogue_option", "当前对话节点不存在该选项。")


func get_active_dialogue_snapshot() -> Dictionary:
	if _active_dialogue_node_id.is_empty() or not _dialogue_node_by_id.has(_active_dialogue_node_id):
		return {}
	var node: Dictionary = _dialogue_node_by_id[_active_dialogue_node_id] as Dictionary
	var snapshot: Dictionary = {
		"event_id": _active_dialogue_event_id,
		"node_id": _active_dialogue_node_id,
		"speaker": String(node["speaker"]),
		"text": String(node["text"]),
		"is_terminal": bool(node["is_terminal"]),
		"options": (node["options"] as Array).duplicate(true),
	}
	snapshot.make_read_only()
	return snapshot


## 结尾电脑页读取的唯一夜班结束记录来源。收束前返回空字典。
func get_unauthorized_broadcast_record() -> Dictionary:
	if _unauthorized_broadcast_record.is_empty():
		return {}
	var record_copy: Dictionary = _unauthorized_broadcast_record.duplicate(true)
	record_copy.make_read_only()
	return record_copy


## 应用壳销毁一局运行时时调用。它只解除跨对象信号和引用，不重置或复活剧情。
## 保持幂等，避免旧 RefCounted 因 GameClock 或 PhoneSystem 的回调继续存活。
func release_runtime() -> Dictionary:
	var computer_release_value: Variant = _computer_system.call(&"release_runtime")
	_disconnect_game_clock()
	_disconnect_phone_system()
	_phone_system = null
	if not computer_release_value is Dictionary or not bool((computer_release_value as Dictionary).get("ok", false)):
		return _make_error("computer_release_failed", "ComputerSystem 未能解除本局 PhoneSystem 运行时连接。")
	return {"ok": true}


func _on_game_time_advanced(previous_tick: int, current_tick: int) -> void:
	# GameClock 会先发 ending_time_reached；若信号顺序异常，本方法仍自行守住 02:00。
	if previous_tick > current_tick:
		_make_error("time_reversed", "GameClock 发出了倒退的游戏时间信号。")
		return
	advance_to_game_tick(current_tick)


func _on_ending_time_reached(end_tick: int) -> void:
	force_ending_at_0200(end_tick)


func _on_phone_became_idle(_event_id: String) -> void:
	_clear_active_dialogue()
	# 02:00 强制结束活动线路也会发出空闲信号；此时绝不能再尝试派发队列。
	if _is_ending_forced:
		return
	# authored scheduler queue 先获得线路；只有它没有占用电话时，Delivery FIFO 才能尝试队头。
	var scheduler_dispatch: Dictionary = dispatch_next_queued_event_if_idle()
	if not bool(scheduler_dispatch.get("ok", false)) or _is_phone_busy():
		return
	var delivery_retry_value: Variant = _delivery_system.call(&"retry_queued_calls", _current_game_tick)
	if not delivery_retry_value is Dictionary or not bool((delivery_retry_value as Dictionary).get("ok", false)):
		_make_error("delivery_queue_retry_failed", "PhoneSystem 空闲后 DeliverySystem 未能继续 FIFO 队列。")


## 电话状态变化只用于清理已结束对话。剧情稿件不会在接听瞬间解锁，避免玩家
## 尚未读到来电正文时就在电脑提前看见“油罐车”或“寻车”信息。
func _on_phone_state_changed(_previous_state: int, current_state: int, event_id: String) -> void:
	if current_state == PhoneSystem.State.IDLE:
		_clear_active_dialogue()


func _on_phone_call_record_created(record: Dictionary) -> void:
	# Observation v2 只对存在 Actor identity 的 Agent Dialogue 来电发给该 Actor；legacy
	# 电话记录仍由 PhoneSystem/ComputerSystem 保存，但不会凭空制造 Actor audience。
	if not is_agent_dialogue_v2():
		return
	var event_id: String = String(record.get("event_id", ""))
	var outcome: String = String(record.get("outcome", ""))
	if event_id.is_empty() or outcome.is_empty():
		_make_error("phone_terminal_record_invalid", "PhoneSystem call_record_created 缺少 event_id/outcome。")
		return
	var event_result: Dictionary = _resolve_agent_event_data(event_id)
	if not bool(event_result.get("ok", false)):
		_make_error("phone_terminal_event_invalid", "电话终态无法解析对应 Agent 事件：%s。" % event_id)
		return
	var actor_id: String = String((event_result["event"] as Dictionary).get("actor_id", ""))
	if actor_id.is_empty():
		_make_error("phone_terminal_actor_missing", "电话终态事件缺少 Actor ID：%s。" % event_id)
		return
	var signal_value: Variant = _signal_system.call(&"commit_phone_terminal", event_id, outcome, actor_id, _current_game_tick)
	if not signal_value is Dictionary or not bool((signal_value as Dictionary).get("ok", false)):
		_make_error("phone_terminal_signal_failed", "SignalSystem 未能提交电话终态 Observation：%s" % _snapshot_message(signal_value))


func _dispatch_next_queued_event() -> Dictionary:
	var queue_result: Dictionary = _scheduler.take_next_queued_event()
	if not bool(queue_result["ok"]):
		return queue_result
	if not bool(queue_result["has_event"]):
		return {"ok": true, "dispatched": false}
	var event_data: Dictionary = queue_result["event"]
	# take_next_queued_event() 发出 event_ready；统一由 _on_scheduler_event_ready
	# 调用 PhoneSystem，避免同一来电被开始两次。
	return {"ok": true, "dispatched": true, "event": event_data}


func _on_scheduler_event_ready(event_data: Dictionary) -> void:
	if _is_ending_forced:
		return
	if not _begin_phone_call(event_data):
		_make_error("phone_begin_call_failed", "PhoneSystem 未能开始来电 %s。" % String(event_data["id"]))
		return
	event_ready.emit(event_data)


func _on_scheduler_event_queued(event_data: Dictionary) -> void:
	event_queued.emit(event_data)


func _on_scheduler_event_expired(event_data: Dictionary) -> void:
	if _phone_system != null:
		var record_result: Variant = _phone_system.call(&"record_expired_call", event_data, _current_game_tick)
		var record_succeeded: bool = false
		if typeof(record_result) == TYPE_BOOL:
			record_succeeded = bool(record_result)
		elif typeof(record_result) == TYPE_DICTIONARY:
			record_succeeded = bool((record_result as Dictionary).get("ok", false))
		if not record_succeeded:
			_make_error("phone_expired_record_failed", "PhoneSystem 未能为过期来电 %s 生成漏接记录。" % String(event_data["id"]))
			return
	event_expired.emit(event_data)


func _on_scheduler_error(_event_id: String, error_code: String, message: String) -> void:
	story_error.emit(error_code, message)


func _on_broadcast_publication_state_changed() -> void:
	broadcast_state_changed.emit()


func _on_player_broadcast_sent(record: Dictionary) -> void:
	var signal_result_value: Variant = _signal_system.call(&"commit_player_broadcast", record)
	if not signal_result_value is Dictionary or not bool((signal_result_value as Dictionary).get("ok", false)):
		var message: String = _snapshot_message(signal_result_value)
		story_error.emit("signal_commit_failed", "玩家广播已提交，但 SignalSystem 无法提交对应感知信号：%s" % message)
		push_error("[剧情][signal_commit_failed] %s" % message)
	player_broadcast_sent.emit(record)
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		_make_error(String(task_refresh.get("error_code", "task_refresh_failed")), String(task_refresh.get("message", "TaskSystem 刷新失败。")))


func _on_world_signal_committed(record: Dictionary) -> void:
	world_signal_committed.emit(record)


func _on_actor_signal_perceived(actor_id: String, signal_id: String) -> void:
	actor_signal_perceived.emit(actor_id, signal_id)


func _on_delivery_committed(record: Dictionary) -> void:
	_commit_delivery_feedback_signal(record)
	world_delivery_committed.emit(record)


func _on_delivery_queued(record: Dictionary) -> void:
	world_delivery_queued.emit(record)


func _on_delivery_rejected(record: Dictionary) -> void:
	_commit_delivery_feedback_signal(record)
	world_delivery_rejected.emit(record)


func _commit_delivery_feedback_signal(record: Dictionary) -> void:
	var signal_result_value: Variant = _signal_system.call(&"commit_delivery_outcome", record, _current_game_tick)
	if signal_result_value is Dictionary and bool((signal_result_value as Dictionary).get("ok", false)):
		return
	var message: String = _snapshot_message(signal_result_value)
	story_error.emit("delivery_feedback_signal_failed", "Delivery 已得出终态，但 SignalSystem 无法提交 Actor feedback：%s" % message)
	push_error("[剧情][delivery_feedback_signal_failed] %s" % message)


func _on_broadcast_error(broadcast_id: String, error_code: String, message: String) -> void:
	print("[剧情][广播][%s][%s] %s" % [broadcast_id, error_code, message])


func _on_computer_entries_changed(category: String) -> void:
	computer_entries_changed.emit(category)


## 解锁只表示“可查看”，绝不能被当作角色已经说过或玩家已经读过。
## 发布任务的信息项只在对应 statement 真正揭示后可用，因此短信到达本身不再解锁公告。
func _on_computer_source_unlocked(category: String, entry: Dictionary) -> void:
	if category != "messages":
		return
	var source_id: String = String(entry.get("source_id", entry.get("id", "")))
	if source_id.is_empty():
		_make_error("invalid_computer_source", "ComputerSystem 解锁的短信缺少稳定 source_id。")
		return
	var public_message: Dictionary = entry.duplicate(true)
	public_message.make_read_only()
	message_unlocked.emit(public_message)
	broadcast_state_changed.emit()
	print("[剧情][%s] 短信已解锁，minute=%d；发布任务等待玩家实际阅读/揭示信息。" % [source_id, _current_minute])


func _on_computer_source_read(category: String, source_id: String, statement_ids: Array[String]) -> void:
	if category == "call_log":
		# 电话陈述只会在真实接通并进入对话时揭示；阅读电话记录不能补造漏接内容。
		return
	var reveal_result: Dictionary = _reveal_statement_ids(statement_ids, source_id)
	if not bool(reveal_result.get("ok", false)):
		_make_error("computer_statement_reveal_failed", "阅读来源 %s 时无法揭示其关联陈述。" % source_id)
		return
	if category == "messages":
		var signal_value: Variant = _signal_system.call(&"commit_message_read", source_id, _current_game_tick)
		if not signal_value is Dictionary or not bool((signal_value as Dictionary).get("ok", false)):
			_make_error("message_read_signal_failed", "短信已读，但 SignalSystem 未能提交 message_read Observation：%s" % _snapshot_message(signal_value))
			return
	var task_refresh: Dictionary = _refresh_task_system()
	if not bool(task_refresh.get("ok", false)):
		_make_error(String(task_refresh.get("error_code", "task_refresh_failed")), String(task_refresh.get("message", "TaskSystem 刷新失败。")))


func _reveal_statement_ids(statement_ids: Array, expected_source_id: String) -> Dictionary:
	var newly_revealed_statement_ids: Array[String] = []
	for raw_statement_id: Variant in statement_ids:
		if typeof(raw_statement_id) != TYPE_STRING or not _statement_by_id.has(String(raw_statement_id)):
			return _make_error("unknown_statement_id", "运行时尝试揭示不存在的陈述。")
		var statement_id: String = String(raw_statement_id)
		var statement: Dictionary = _statement_by_id[statement_id] as Dictionary
		if String(statement["source_id"]) != expected_source_id:
			return _make_error("statement_source_mismatch", "运行时陈述来源与当前来源不一致。")
		if _revealed_statement_ids.has(statement_id):
			continue
		_revealed_statement_ids[statement_id] = true
		newly_revealed_statement_ids.append(statement_id)
		var snapshot: Dictionary = get_statement_snapshot(statement_id)
		statement_revealed.emit(snapshot)
		print("[剧情][%s] 来源陈述已揭示，source=%s。" % [statement_id, expected_source_id])
	_evaluate_unconfirmed_facts()
	_refresh_broadcast_decisions(true)
	broadcast_state_changed.emit()
	return {"ok": true, "newly_revealed_statement_ids": newly_revealed_statement_ids}


func _evaluate_unconfirmed_facts() -> void:
	for fact_id_variant: Variant in _fact_by_id.keys():
		var fact_id: String = String(fact_id_variant)
		if _confirmed_fact_ids.has(fact_id):
			continue
		var fact: Dictionary = _fact_by_id[fact_id] as Dictionary
		if ENDING_ONLY_FACT_IDS.has(fact_id):
			continue
		if bool(fact["initially_confirmed"]):
			_confirm_fact(fact_id)
			continue
		var has_all_required_statements: bool = true
		for statement_id_variant: Variant in fact["required_statement_ids"] as Array:
			if not _revealed_statement_ids.has(String(statement_id_variant)):
				has_all_required_statements = false
				break
		if has_all_required_statements:
			_confirm_fact(fact_id)


func _confirm_fact(fact_id: String) -> void:
	if _confirmed_fact_ids.has(fact_id) or not _fact_by_id.has(fact_id):
		return
	_confirmed_fact_ids[fact_id] = true
	var snapshot: Dictionary = get_fact_snapshot(fact_id)
	fact_confirmed.emit(snapshot)
	print("[剧情][%s] 事实已确认。" % fact_id)


func _decorate_call_log_entry(entry: Dictionary) -> void:
	var source_id: String = String(entry.get("source_id", entry.get("event_id", "")))
	var revealed_statement_ids: Array[String] = []
	for statement_id_variant: Variant in _statement_by_id.keys():
		var statement_id: String = String(statement_id_variant)
		var statement: Dictionary = _statement_by_id[statement_id] as Dictionary
		if String(statement["source_id"]) == source_id and _revealed_statement_ids.has(statement_id):
			revealed_statement_ids.append(statement_id)
	revealed_statement_ids.sort()
	var confirmed_fact_ids: Array[String] = []
	for fact_id_variant: Variant in _fact_by_id.keys():
		var fact_id: String = String(fact_id_variant)
		if not _confirmed_fact_ids.has(fact_id):
			continue
		var fact: Dictionary = _fact_by_id[fact_id] as Dictionary
		for statement_id_variant: Variant in fact["required_statement_ids"] as Array:
			var statement_id: String = String(statement_id_variant)
			if _statement_by_id.has(statement_id) and String((_statement_by_id[statement_id] as Dictionary)["source_id"]) == source_id:
				confirmed_fact_ids.append(fact_id)
				break
	confirmed_fact_ids.sort()
	entry["revealed_statement_ids"] = revealed_statement_ids
	entry["confirmed_fact_ids"] = confirmed_fact_ids


func _mark_dialogue_completed(event_id: String) -> Dictionary:
	if event_id.is_empty() or not _story_event_by_id.has(event_id):
		return _make_error("invalid_dialogue_event", "完成对话时缺少或引用了不存在的稳定事件 ID。")
	if _completed_dialogue_event_ids.has(event_id):
		return {"ok": true, "already_completed": true}
	_completed_dialogue_event_ids[event_id] = true
	_refresh_broadcast_decisions(true)
	broadcast_state_changed.emit()
	print("[剧情][%s] 预制对话完成；发布任务资格将从 completed_dialogue_event_ids 重新派生。" % event_id)
	return {"ok": true, "already_completed": false}


func _clear_active_dialogue() -> void:
	if _active_dialogue_node_id.is_empty() and _active_dialogue_event_id.is_empty():
		return
	_active_dialogue_event_id = ""
	_active_dialogue_node_id = ""
	dialogue_changed.emit({})


func _begin_phone_call(event_data: Dictionary) -> bool:
	if _phone_system == null:
		# 测试和纯调度阶段允许没有电话系统；事件仍由 StoryEngine 作为权威状态公开。
		return true
	var begin_result: Variant = _phone_system.call(&"begin_incoming_call", event_data, _current_game_tick, TICKS_PER_GAME_MINUTE)
	if typeof(begin_result) == TYPE_BOOL:
		return bool(begin_result)
	if typeof(begin_result) == TYPE_DICTIONARY:
		return bool((begin_result as Dictionary).get("ok", false))
	_make_error("invalid_phone_result", "PhoneSystem.begin_incoming_call() 必须返回 bool 或带 ok 的 Dictionary。")
	return false


func _is_phone_busy() -> bool:
	if _phone_system == null:
		return false
	var busy_result: Variant = _phone_system.call(&"is_busy")
	if typeof(busy_result) != TYPE_BOOL:
		_make_error("invalid_phone_busy_result", "PhoneSystem.is_busy() 必须返回 bool。")
		return true
	return bool(busy_result)


func _advance_phone_to_tick(current_tick: int) -> void:
	if _phone_system == null:
		return
	var advance_result: Variant = _phone_system.call(&"advance_to_tick", current_tick)
	if typeof(advance_result) != TYPE_BOOL:
		_make_error("invalid_phone_advance_result", "PhoneSystem.advance_to_tick() 必须返回 bool。")


func _is_condition_met(condition_id: String) -> bool:
	return bool(_condition_state_by_id.get(condition_id, false))


func _disconnect_game_clock() -> void:
	if _game_clock == null or not is_instance_valid(_game_clock):
		_game_clock = null
		return
	var time_callback: Callable = Callable(self, "_on_game_time_advanced")
	var ending_callback: Callable = Callable(self, "_on_ending_time_reached")
	if _game_clock.is_connected(&"game_time_advanced", time_callback):
		_game_clock.disconnect(&"game_time_advanced", time_callback)
	if _game_clock.is_connected(&"ending_time_reached", ending_callback):
		_game_clock.disconnect(&"ending_time_reached", ending_callback)
	_game_clock = null


func _disconnect_phone_system() -> void:
	if _phone_system == null:
		return
	var idle_callback: Callable = Callable(self, "_on_phone_became_idle")
	if _phone_system.has_signal(&"call_became_idle") and _phone_system.is_connected(&"call_became_idle", idle_callback):
		_phone_system.disconnect(&"call_became_idle", idle_callback)
	var state_callback: Callable = Callable(self, "_on_phone_state_changed")
	if _phone_system.has_signal(&"state_changed") and _phone_system.is_connected(&"state_changed", state_callback):
		_phone_system.disconnect(&"state_changed", state_callback)
	var record_callback: Callable = Callable(self, "_on_phone_call_record_created")
	if _phone_system.has_signal(&"call_record_created") and _phone_system.is_connected(&"call_record_created", record_callback):
		_phone_system.disconnect(&"call_record_created", record_callback)


func _make_error(error_code: String, message: String) -> Dictionary:
	story_error.emit(error_code, message)
	push_error("[剧情][%s] %s" % [error_code, message])
	return {"ok": false, "error_code": error_code, "message": message}
