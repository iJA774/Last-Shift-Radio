extends SceneTree

## 发布任务待决、推迟、放弃和严格快照的领域回归。
const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const AGENT_DIALOGUE_TEST_DRIVER_SCRIPT: GDScript = preload("res://tests/smoke/agent_dialogue_test_driver.gd")

var _has_failed: bool = false


func _init() -> void:
	var content: Dictionary = _load_content()
	if not content.is_empty():
		_test_abandon_is_scoped(content)
		_test_defer_abandon_and_snapshot(content)
	if _has_failed:
		print("[测试][BroadcastDecisionFlow] 失败。")
		quit(1)
		return
	print("[测试][BroadcastDecisionFlow] 通过：推迟重待决、放弃永久性、多待决和快照通知契约成立。")
	quit(0)


func _test_abandon_is_scoped(content: Dictionary) -> void:
	var story: StoryEngine = STORY_ENGINE_SCRIPT.new() as StoryEngine
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new() as PhoneSystem
	_assert_ok(story.set_phone_system(phone), "作用域测试必须绑定电话上下文。")
	_assert_ok(story.configure_test_night_story(_make_focused_content(content)), "作用域测试必须配置剧情。")
	_prepare_agent_task_prerequisites(story, phone)
	var before_b: Dictionary = _find_task(story.get_broadcast_tasks(), "task_broadcast_wagon_witness_request")
	_assert_true(not before_b.is_empty() and String(before_b.get("decision_status", "")) == "pending", "放弃 A 前任务 B 必须独立处于待决。")
	_assert_ok(story.abandon_broadcast_task("task_broadcast_bridge_closure"), "任务 A 必须可被单独放弃。")
	var tasks_after: Array = story.get_broadcast_tasks()
	_assert_true(not _has_task(tasks_after, "task_broadcast_bridge_closure"), "放弃 A 后任务 A 不得继续存在。")
	var after_b: Dictionary = _find_task(tasks_after, "task_broadcast_wagon_witness_request")
	_assert_true(not after_b.is_empty(), "放弃 A 后任务 B 必须仍存在。")
	_assert_equal(String(after_b.get("decision_status", "")), String(before_b.get("decision_status", "")), "放弃 A 不得改变任务 B 的待决状态。")
	_assert_equal(bool(after_b.get("is_sent", true)), bool(before_b.get("is_sent", true)), "放弃 A 不得改变任务 B 的发送状态。")
	_assert_true(story.has_pending_broadcast_decision(), "任务 B 仍待决时，放弃 A 不得解除全局待决。")
	_assert_ok(story.defer_broadcast_task("task_broadcast_wagon_witness_request"), "放弃 A 后任务 B 仍必须可推迟。")
	_assert_ok(story.send_broadcast_task("task_broadcast_wagon_witness_request", ["info_wagon_martha_route"]), "放弃 A 后任务 B 仍必须可发送。")


func _test_defer_abandon_and_snapshot(content: Dictionary) -> void:
	var story: StoryEngine = STORY_ENGINE_SCRIPT.new() as StoryEngine
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new() as PhoneSystem
	_assert_ok(story.set_phone_system(phone), "快照来源必须绑定电话上下文。")
	var focused_content: Dictionary = _make_focused_content(content)
	_assert_ok(story.configure_test_night_story(focused_content), "必须配置测试剧情。")
	var notices: Array[String] = []
	story.broadcast_decision_required.connect(func(task: Dictionary) -> void: notices.append(String(task.get("id", ""))) )
	_prepare_agent_task_prerequisites(story, phone)
	_assert_true(story.has_pending_broadcast_decision(), "两个可发布任务首次出现时必须进入待决。")
	_assert_true(notices.has("task_broadcast_bridge_closure") and notices.has("task_broadcast_wagon_witness_request"), "两个首次待决任务都必须发出独立通知。")
	_assert_ok(story.defer_broadcast_task("task_broadcast_bridge_closure"), "待决北桥任务必须可推迟。")
	_assert_true(story.has_pending_broadcast_decision(), "多个待决任务中推迟一个后，另一个待决任务仍必须保持暂停条件。")
	_assert_ok(story.defer_broadcast_task("task_broadcast_wagon_witness_request"), "待决寻车任务必须可推迟。")
	_assert_true(not story.has_pending_broadcast_decision(), "全部任务推迟后不得残留待决状态。")
	_assert_ok(
		story.send_broadcast_task("task_broadcast_wagon_witness_request", ["info_wagon_martha_route"]),
		"推迟任务必须仍允许玩家主动发送。"
	)
	_assert_equal(story.get_player_broadcast_records().size(), 1, "推迟后主动发送必须生成一条玩家播出记录。")
	var notices_before_repeat: int = notices.size()
	story._refresh_broadcast_decisions(true)
	_assert_equal(notices.size(), notices_before_repeat, "推迟任务没有新增信息时不得再次通知或复活。")
	story._revealed_statement_ids["statement_miller_bridge_closure"] = true
	story._evaluate_unconfirmed_facts()
	story._refresh_broadcast_decisions(true)
	_assert_true(story.has_pending_broadcast_decision(), "推迟任务取得新增可用信息后必须重新待决。")
	_assert_equal(notices.size(), notices_before_repeat + 1, "新增可用信息必须恰好产生一次重新待决通知。")
	_assert_ok(story.abandon_broadcast_task("task_broadcast_bridge_closure"), "重新待决任务必须可永久放弃。")
	_assert_true(not _has_task(story.get_broadcast_tasks(), "task_broadcast_bridge_closure"), "放弃任务不得继续出现在麦克风任务快照。")
	var notices_before_abandoned_update: int = notices.size()
	story._revealed_statement_ids["statement_southbound_bridge_claim"] = true
	story._evaluate_unconfirmed_facts()
	story._refresh_broadcast_decisions(true)
	_assert_equal(notices.size(), notices_before_abandoned_update, "已放弃任务即使得到新信息也不得再次通知。")
	_assert_true(not story.has_pending_broadcast_decision(), "放弃唯一重新待决任务后不得残留暂停条件。")
	var snapshot: Dictionary = story.create_snapshot().duplicate(true)
	var phone_snapshot: Dictionary = phone.create_snapshot().duplicate(true)
	var restored: StoryEngine = STORY_ENGINE_SCRIPT.new() as StoryEngine
	var restored_phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new() as PhoneSystem
	_assert_ok(restored.set_phone_system(restored_phone), "恢复目标必须绑定电话上下文。")
	_assert_ok(restored.configure_test_night_story(focused_content), "恢复目标必须配置同一内容。")
	_assert_ok(restored_phone.restore_snapshot(phone_snapshot, {
		"current_game_tick": 180,
		"event_by_id": restored.get_scheduler().get_configured_events_by_id(),
	}), "恢复目标必须先恢复真实电话记录。")
	var restore_notices: Array[String] = []
	restored.broadcast_decision_required.connect(func(task: Dictionary) -> void: restore_notices.append(String(task.get("id", ""))) )
	_assert_ok(restored.restore_snapshot(snapshot, {"phone_system": restored_phone, "current_game_tick": 180}), "任务决策快照必须严格恢复。")
	_assert_equal(restore_notices.size(), 0, "恢复快照不得伪造历史任务通知。")
	_assert_true(not _has_task(restored.get_broadcast_tasks(), "task_broadcast_bridge_closure"), "放弃状态必须随快照往返且不复活。")


func _make_focused_content(content: Dictionary) -> Dictionary:
	var focused: Dictionary = content.duplicate(true)
	var minute_by_event_id: Dictionary = {
		"call_01_warren": 1,
		"call_06_trucker": 2,
		"call_03_martha": 3,
	}
	for raw_event: Variant in focused["events"] as Array:
		var event: Dictionary = raw_event as Dictionary
		var event_id: String = String(event["id"])
		var minute: int = int(minute_by_event_id.get(event_id, 50))
		event["window_start_minute"] = minute
		event["window_end_minute"] = minute + 1
	return focused


func _prepare_agent_task_prerequisites(story: StoryEngine, phone: PhoneSystem) -> void:
	var driver: RefCounted = AGENT_DIALOGUE_TEST_DRIVER_SCRIPT.new()
	_assert_ok(driver.call(&"complete_scheduled_call", story, phone, 60, "call_01_warren", "warren", ["statement_warren_tanker_fire_claim"], "酒吧有人说北桥附近一辆油罐车冒烟；我没有亲眼看见。"), "沃伦 interaction 必须由公开 Agent 提交入口完成。")
	_assert_ok(driver.call(&"complete_scheduled_call", story, phone, 120, "call_06_trucker", "trucker", ["statement_trucker_bridge_queue"], "北桥东侧入口堵死了，前面全是刹车灯。"), "卡车司机 interaction 必须由公开 Agent 提交入口完成。")
	_assert_ok(driver.call(&"complete_scheduled_call", story, phone, 180, "call_03_martha", "martha", ["statement_martha_wagon_route"], "丹尼开的是深色旧旅行车，常走北桥回城。"), "玛莎 interaction 必须由公开 Agent 提交入口完成。")


func _load_content() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var loaded: Dictionary = loader.call(&"load_json", "res://data/story/test_night_story.json") as Dictionary
	_assert_ok(loaded, "必须读取测试剧情。")
	if not bool(loaded.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validated: Dictionary = validator.call(&"validate_test_night_story", loaded["data"], "res://data/story/test_night_story.json") as Dictionary
	_assert_ok(validated, "测试剧情必须通过严格校验。")
	return validated if bool(validated.get("ok", false)) else {}


func _has_task(tasks: Array, task_id: String) -> bool:
	for raw_task: Variant in tasks:
		if raw_task is Dictionary and String((raw_task as Dictionary).get("id", "")) == task_id:
			return true
	return false


func _find_task(tasks: Array, task_id: String) -> Dictionary:
	for raw_task: Variant in tasks:
		if raw_task is Dictionary and String((raw_task as Dictionary).get("id", "")) == task_id:
			return raw_task as Dictionary
	return {}


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s。" % [message, str(result)])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][BroadcastDecisionFlow] %s" % message)
