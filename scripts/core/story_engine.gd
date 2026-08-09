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
const BROADCAST_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/broadcast_system.gd")
const COMPUTER_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/computer_system.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")

signal message_unlocked(message: Dictionary)
signal broadcast_state_changed()
signal player_broadcast_sent(record: Dictionary)
signal dialogue_changed(snapshot: Dictionary)
signal statement_revealed(statement: Dictionary)
signal fact_confirmed(fact: Dictionary)
signal computer_entries_changed(category: String)

var _scheduler: EventScheduler = EventScheduler.new()
var _condition_state_by_id: Dictionary = {}
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
var _is_test_story_configured: bool = false
var _story_event_by_id: Dictionary = {}
var _message_by_id: Dictionary = {}
var _broadcast_fact_ids_by_id: Dictionary = {}
var _statement_by_id: Dictionary = {}
var _fact_by_id: Dictionary = {}
var _revealed_statement_ids: Dictionary = {}
var _confirmed_fact_ids: Dictionary = {}
var _dialogue_node_by_id: Dictionary = {}
var _active_dialogue_event_id: String = ""
var _active_dialogue_node_id: String = ""
var _completed_dialogue_event_ids: Dictionary = {}


func _init() -> void:
	_scheduler.event_ready.connect(_on_scheduler_event_ready)
	_scheduler.event_queued.connect(_on_scheduler_event_queued)
	_scheduler.event_expired.connect(_on_scheduler_event_expired)
	_scheduler.scheduler_error.connect(_on_scheduler_error)
	_broadcast_system.connect(&"available_broadcasts_changed", Callable(self, "_on_available_broadcasts_changed"))
	_broadcast_system.connect(&"player_broadcast_sent", Callable(self, "_on_player_broadcast_sent"))
	_broadcast_system.connect(&"broadcast_error", Callable(self, "_on_broadcast_error"))
	_computer_system.connect(&"entries_changed", Callable(self, "_on_computer_entries_changed"))
	_computer_system.connect(&"source_unlocked", Callable(self, "_on_computer_source_unlocked"))
	_computer_system.connect(&"source_read", Callable(self, "_on_computer_source_read"))


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
	var computer_phone_result_value: Variant = _computer_system.call(&"set_phone_system", _phone_system)
	if not computer_phone_result_value is Dictionary or not bool((computer_phone_result_value as Dictionary).get("ok", false)):
		return _make_error("computer_phone_bind_failed", "ComputerSystem 未能绑定 PhoneSystem 来电记录。")
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
	for field_name: String in ["events", "checklist_entries", "news_entries", "messages", "broadcasts", "dialogue_nodes", "statements", "facts"]:
		if not checked_content.has(field_name) or typeof(checked_content[field_name]) != TYPE_ARRAY:
			return _make_error("invalid_story_content", "测试剧情缺少已校验数组字段：%s。" % field_name)
	var next_event_by_id: Dictionary = {}
	var next_message_by_id: Dictionary = {}
	var next_dialogue_node_by_id: Dictionary = {}
	var next_statement_by_id: Dictionary = {}
	var next_fact_by_id: Dictionary = {}
	var next_broadcast_fact_ids_by_id: Dictionary = {}
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
	for raw_broadcast: Variant in checked_content["broadcasts"] as Array:
		if not raw_broadcast is Dictionary:
			return _make_error("invalid_story_content", "测试剧情 broadcasts 中包含非对象项目。")
		var broadcast: Dictionary = raw_broadcast as Dictionary
		var broadcast_id: String = String(broadcast["id"])
		next_broadcast_fact_ids_by_id[broadcast_id] = (broadcast["fact_ids"] as Array).duplicate(true)
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
	var schedule_result: Dictionary = schedule_events(checked_content["events"] as Array)
	if not bool(schedule_result.get("ok", false)):
		return schedule_result
	var broadcasts: Array = checked_content["broadcasts"] as Array
	var broadcast_result_value: Variant = _broadcast_system.call(&"configure_drafts", broadcasts)
	if not broadcast_result_value is Dictionary:
		return _make_error("invalid_broadcast_system_result", "BroadcastSystem.configure_drafts() 必须返回带 ok 的 Dictionary。")
	var broadcast_result: Dictionary = broadcast_result_value as Dictionary
	if not bool(broadcast_result.get("ok", false)):
		return broadcast_result
	_story_event_by_id = next_event_by_id
	_message_by_id = next_message_by_id
	_broadcast_fact_ids_by_id = next_broadcast_fact_ids_by_id
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
	return {"ok": true, "event_count": _story_event_by_id.size()}


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
	_condition_state_by_id[condition_id] = is_met
	return {"ok": true}


func is_condition_met(condition_id: String) -> bool:
	return _is_condition_met(condition_id)


func is_ending_forced() -> bool:
	return _is_ending_forced


func get_current_game_tick() -> int:
	return _current_game_tick


func get_current_minute() -> int:
	return _current_minute


func get_scheduler() -> EventScheduler:
	return _scheduler


## 电脑播出工作台的只读稿件接口。UI 只能展示此返回值并提交其中的 broadcast_id。
func get_available_broadcasts() -> Array[Dictionary]:
	var result: Variant = _broadcast_system.call(&"get_available_drafts")
	if not result is Array:
		_make_error("invalid_broadcast_system_result", "BroadcastSystem.get_available_drafts() 必须返回 Array。")
		return []
	var drafts: Array[Dictionary] = []
	for raw_draft: Variant in result as Array:
		if raw_draft is Dictionary:
			drafts.append(raw_draft as Dictionary)
	return drafts


## 电脑播出工作台的只读玩家记录接口；不包含 02:00 的异常记录。
func get_player_broadcast_records() -> Array[Dictionary]:
	var result: Variant = _broadcast_system.call(&"get_player_broadcast_records")
	if not result is Array:
		_make_error("invalid_broadcast_system_result", "BroadcastSystem.get_player_broadcast_records() 必须返回 Array。")
		return []
	var records: Array[Dictionary] = []
	for raw_record: Variant in result as Array:
		if raw_record is Dictionary:
			var record: Dictionary = (raw_record as Dictionary).duplicate(true)
			var broadcast_id: String = String(record.get("broadcast_id", ""))
			if _broadcast_fact_ids_by_id.has(broadcast_id):
				record["fact_ids"] = (_broadcast_fact_ids_by_id[broadcast_id] as Array).duplicate(true)
			record.make_read_only()
			records.append(record)
	return records


## 玩家发送预制稿件的唯一意图入口。02:00 后与未解锁/重复/互斥稿件均明确拒绝。
func send_player_broadcast(broadcast_id: String) -> Dictionary:
	if not _is_test_story_configured:
		return _make_error("story_not_configured", "测试剧情尚未配置，不能发送广播。")
	if _is_ending_forced:
		return _make_error("ending_forced", "02:00 强制收束已发生，不能发送玩家广播。")
	var result_value: Variant = _broadcast_system.call(&"send_player_broadcast", broadcast_id, _current_game_tick)
	if not result_value is Dictionary:
		return _make_error("invalid_broadcast_system_result", "BroadcastSystem.send_player_broadcast() 必须返回带 ok 的 Dictionary。")
	var result: Dictionary = result_value as Dictionary
	if not bool(result.get("ok", false)):
		return result
	var condition_id: String = String(result.get("sets_condition_id", ""))
	if not condition_id.is_empty():
		var condition_result: Dictionary = set_condition_state(condition_id, true)
		if not bool(condition_result.get("ok", false)):
			return condition_result
		print("[剧情][%s] 玩家广播已设置条件。" % condition_id)
	return result


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
			var unlock_result: Dictionary = _unlock_broadcasts_for_completed_dialogue(_active_dialogue_event_id)
			if not bool(unlock_result.get("ok", false)):
				return unlock_result
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


## 结尾电脑页读取的唯一播出记录来源。收束前返回空字典。
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
	dispatch_next_queued_event_if_idle()


## 电话状态变化只用于清理已结束对话。剧情稿件不会在接听瞬间解锁，避免玩家
## 尚未读到来电正文时就在电脑提前看见“油罐车”或“寻车”信息。
func _on_phone_state_changed(_previous_state: int, current_state: int, event_id: String) -> void:
	if current_state == PhoneSystem.State.IDLE:
		_clear_active_dialogue()


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


func _on_available_broadcasts_changed() -> void:
	broadcast_state_changed.emit()


func _on_player_broadcast_sent(record: Dictionary) -> void:
	player_broadcast_sent.emit(record)


func _on_broadcast_error(broadcast_id: String, error_code: String, message: String) -> void:
	print("[剧情][广播][%s][%s] %s" % [broadcast_id, error_code, message])


func _on_computer_entries_changed(category: String) -> void:
	computer_entries_changed.emit(category)


## 解锁只表示“可查看”，绝不能被当作角色已经说过或玩家已经读过。短信仍可
## 作为广播稿的既有解锁来源，但其 statement_ids 只能在玩家打开短信后揭示。
func _on_computer_source_unlocked(category: String, entry: Dictionary) -> void:
	if category != "messages":
		return
	var source_id: String = String(entry.get("source_id", entry.get("id", "")))
	if source_id.is_empty():
		_make_error("invalid_computer_source", "ComputerSystem 解锁的短信缺少稳定 source_id。")
		return
	var broadcast_result_value: Variant = _broadcast_system.call(&"unlock_for_source_id", source_id)
	if not broadcast_result_value is Dictionary or not bool((broadcast_result_value as Dictionary).get("ok", false)):
		_make_error("broadcast_unlock_failed", "短信 %s 未能解锁关联广播稿。" % source_id)
		return
	var public_message: Dictionary = entry.duplicate(true)
	public_message.make_read_only()
	message_unlocked.emit(public_message)
	print("[剧情][%s] 短信已解锁，minute=%d。" % [source_id, _current_minute])


func _on_computer_source_read(category: String, source_id: String, statement_ids: Array[String]) -> void:
	if category == "call_log":
		# 电话陈述只会在真实接通并进入对话时揭示；阅读电话记录不能补造漏接内容。
		return
	var reveal_result: Dictionary = _reveal_statement_ids(statement_ids, source_id)
	if not bool(reveal_result.get("ok", false)):
		_make_error("computer_statement_reveal_failed", "阅读来源 %s 时无法揭示其关联陈述。" % source_id)


func _reveal_statement_ids(statement_ids: Array, expected_source_id: String) -> Dictionary:
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
		var snapshot: Dictionary = get_statement_snapshot(statement_id)
		statement_revealed.emit(snapshot)
		print("[剧情][%s] 来源陈述已揭示，source=%s。" % [statement_id, expected_source_id])
	_evaluate_unconfirmed_facts()
	return {"ok": true}


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


func _unlock_broadcasts_for_completed_dialogue(event_id: String) -> Dictionary:
	if event_id.is_empty():
		return _make_error("invalid_dialogue_event", "完成对话时缺少稳定事件 ID。")
	if _completed_dialogue_event_ids.has(event_id):
		return {"ok": true, "already_unlocked": true}
	var unlock_result_value: Variant = _broadcast_system.call(&"unlock_for_source_id", event_id)
	if not unlock_result_value is Dictionary:
		return _make_error("invalid_broadcast_system_result", "BroadcastSystem.unlock_for_source_id() 必须返回带 ok 的 Dictionary。")
	var unlock_result: Dictionary = unlock_result_value as Dictionary
	if not bool(unlock_result.get("ok", false)):
		return _make_error("broadcast_unlock_failed", "完成来电 %s 后未能解锁关联广播稿。" % event_id)
	_completed_dialogue_event_ids[event_id] = true
	print("[剧情][%s] 预制对话完成，关联广播稿已按稳定 ID 解锁。" % event_id)
	return {"ok": true, "unlocked_count": int(unlock_result.get("unlocked_count", 0))}


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


func _make_error(error_code: String, message: String) -> Dictionary:
	story_error.emit(error_code, message)
	push_error("[剧情][%s] %s" % [error_code, message])
	return {"ok": false, "error_code": error_code, "message": message}
