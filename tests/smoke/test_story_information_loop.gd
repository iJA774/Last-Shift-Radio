extends SceneTree

## 第六阶段信息闭环冒烟：电脑来源的解锁/阅读、电话追问的分歧陈述、
## 必要陈述齐备后的事实确认、漏接不伪造来源，以及 02:00 权威结尾事实。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const AGENT_DIALOGUE_TEST_DRIVER_SCRIPT: GDScript = preload("res://tests/smoke/agent_dialogue_test_driver.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	var validated_story: Dictionary = _load_validated_story()
	if not validated_story.is_empty():
		_test_strict_information_contract(validated_story)
		_test_computer_read_and_southbound_choices(validated_story)
		_test_warren_accident_account_conflict(validated_story)
		_test_missed_call_does_not_reveal_statement(validated_story)
		_test_ending_facts_remain_authoritative(validated_story)
		_test_runtime_release_unsubscribes_computer(validated_story)

	if _has_failed:
		print("[测试][StoryInformationLoop] 失败。")
		quit(1)
		return
	print("[测试][StoryInformationLoop] 通过：来源阅读、分支陈述、事实确认、漏接与 02:00 均符合契约。")
	quit(0)


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_result: Dictionary = loader.call(&"load_json", STORY_PATH) as Dictionary
	_assert_ok(load_result, "测试夜班 JSON 必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation: Dictionary = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH) as Dictionary
	_assert_ok(validation, "测试夜班必须通过第六阶段严格内容校验。")
	return validation


func _test_strict_information_contract(validated_story: Dictionary) -> void:
	_assert_equal((validated_story["news_entries"] as Array).size(), 5, "测试夜班必须提供至少 5 条地方新闻。")
	var malformed_topics: Dictionary = validated_story.duplicate(true)
	for raw_news: Variant in malformed_topics["news_entries"] as Array:
		var news: Dictionary = raw_news as Dictionary
		news["topic_ids"] = ["north_bridge"]
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var topic_result: Dictionary = validator.call(&"validate_test_night_story", malformed_topics, "memory://only_bridge_news") as Dictionary
	_assert_error_code(topic_result, "insufficient_non_bridge_news", "至少两条非北桥新闻是严格契约。")

	var malformed_agent_event: Dictionary = validated_story.duplicate(true)
	var first_event: Dictionary = (malformed_agent_event["events"] as Array)[0] as Dictionary
	first_event.erase("available_statement_ids")
	var agent_event_result: Dictionary = validator.call(&"validate_test_night_story", malformed_agent_event, "memory://missing_available_statements") as Dictionary
	_assert_error_code(agent_event_result, "missing_field", "每个 v2 来电必须显式声明 available_statement_ids。")


func _test_computer_read_and_southbound_choices(validated_story: Dictionary) -> void:
	var story_for_bridge: Dictionary = _make_single_target_story(validated_story, "call_09_southbound")
	var bridge_engine: StoryEngine = _make_engine(story_for_bridge)
	_assert_equal(bridge_engine.get_computer_entries("news").size(), 1, "开局必须立即解锁基础北桥新闻。")
	_assert_equal(bridge_engine.get_computer_entries("messages").size(), 2, "聚焦测试中的交接与警方短信必须立即解锁。")
	_assert_true(not bridge_engine.is_statement_revealed("statement_miller_bridge_closure"), "来源已解锁不等于玩家已经读到陈述。")
	_assert_true(not bridge_engine.is_fact_confirmed("fact_accounts_conflict"), "单一已解锁来源不得确认矛盾事实。")
	var bridge_task_before_read: Dictionary = _find_broadcast_task(bridge_engine.get_broadcast_tasks(), "task_broadcast_bridge_closure")
	_assert_true(not _task_has_information(bridge_task_before_read, "info_bridge_official_closure"), "米勒短信尚未阅读时，官方封桥信息不得提前进入可选信息集合。")
	_assert_true(not bool(bridge_task_before_read.get("prerequisites_met", true)), "信息来源已解锁不能代替 A+B 必要对话门槛。")
	_assert_ok(bridge_engine.mark_computer_entry_read("messages", "message_01_miller"), "阅读警方短信必须成功。")
	_assert_true(bridge_engine.is_statement_revealed("statement_miller_bridge_closure"), "阅读电脑来源后必须揭示其陈述。")
	var bridge_task_after_read: Dictionary = _find_broadcast_task(bridge_engine.get_broadcast_tasks(), "task_broadcast_bridge_closure")
	_assert_true(_task_has_information(bridge_task_after_read, "info_bridge_official_closure"), "阅读米勒短信后必须只增加对应官方信息项。")
	_assert_true(not bool(bridge_task_after_read.get("prerequisites_met", true)), "收集到官方短信信息后仍不得绕过 A+B 必要对话门槛。")
	_assert_true(not bridge_engine.is_fact_confirmed("fact_accounts_conflict"), "只读警方短信仍不足以确认冲突事实。")
	_assert_ok(bridge_engine.advance_to_game_tick(60), "年轻司机来电必须按聚焦时间窗触发。")
	var bridge_phone: PhoneSystem = bridge_engine._phone_system as PhoneSystem
	_assert_equal(bridge_phone.get_active_event_id(), "call_09_southbound", "聚焦测试必须只触发年轻司机来电。")
	_assert_true(bridge_phone.answer_call(60), "年轻司机来电应可接听。")
	_assert_true(bridge_phone.enter_dialogue_choice(), "年轻司机来电应可进入选择。")
	var dialogue_driver: RefCounted = AGENT_DIALOGUE_TEST_DRIVER_SCRIPT.new()
	_assert_ok(dialogue_driver.call(&"commit_active_call", bridge_engine, "call_09_southbound", "southbound", ["statement_southbound_bridge_claim"], "我刚按临时路牌经过了自己认作北桥的桥。"), "年轻司机北桥 ActorTurn 必须可提交。")
	_assert_true(bridge_engine.is_statement_revealed("statement_southbound_bridge_claim"), "追问北桥必须揭示经过北桥的来源陈述。")
	var bridge_task_after_southbound: Dictionary = _find_broadcast_task(bridge_engine.get_broadcast_tasks(), "task_broadcast_bridge_closure")
	_assert_true(_task_has_information(bridge_task_after_southbound, "info_bridge_southbound_crossing"), "南向司机桥面陈述真实揭示后，必须增加对应可选信息项。")
	_assert_true(not bool(bridge_task_after_southbound.get("prerequisites_met", true)), "只取得 C 和米勒信息仍不能替代 A+B 最低必要对话门槛。")
	_assert_true(not bridge_engine.is_statement_revealed("statement_southbound_wagon_sighting"), "未追问车辆不得伪造车辆目击陈述。")
	_assert_true(not bridge_engine.is_fact_confirmed("fact_accounts_conflict"), "封桥与通行主张不能错误确认事故诱因描述冲突。")
	_assert_true(bridge_engine.is_fact_confirmed("fact_bridge_traffic_after_closure"), "必要陈述齐备后才确认封桥后通行主张。")

	var story_for_vehicle: Dictionary = _make_single_target_story(validated_story, "call_09_southbound")
	var vehicle_engine: StoryEngine = _make_engine(story_for_vehicle)
	_assert_ok(vehicle_engine.advance_to_game_tick(60), "车辆分支的年轻司机来电必须触发。")
	var vehicle_phone: PhoneSystem = vehicle_engine._phone_system as PhoneSystem
	_assert_true(vehicle_phone.answer_call(60), "车辆分支应可接听。")
	_assert_true(vehicle_phone.enter_dialogue_choice(), "车辆分支应可进入选择。")
	_assert_ok(dialogue_driver.call(&"commit_active_call", vehicle_engine, "call_09_southbound", "southbound", ["statement_southbound_wagon_sighting"], "一辆旧旅行车从后方超过我，正往城南方向开。"), "年轻司机车辆 ActorTurn 必须可提交。")
	_assert_true(vehicle_engine.is_statement_revealed("statement_southbound_wagon_sighting"), "追问车辆必须揭示旅行车目击陈述。")
	_assert_true(not vehicle_engine.is_statement_revealed("statement_southbound_bridge_claim"), "车辆追问不能伪造北桥经过陈述。")


func _test_warren_accident_account_conflict(validated_story: Dictionary) -> void:
	var story: Dictionary = _make_single_target_story(validated_story, "call_01_warren")
	var official_only_engine: StoryEngine = _make_engine(story)
	_assert_ok(official_only_engine.mark_computer_entry_read("messages", "message_01_miller"), "官方封桥短信必须可阅读。")
	_assert_true(not official_only_engine.is_fact_confirmed("fact_accounts_conflict"), "只读官方结构受损信息不能确认事故诱因冲突。")
	_assert_ok(official_only_engine.advance_to_game_tick(60), "沃伦来电必须按聚焦时间窗触发。")
	var official_only_phone: PhoneSystem = official_only_engine._phone_system as PhoneSystem
	_assert_true(official_only_phone.answer_call(60), "沃伦来电应可接听。")
	_assert_true(official_only_phone.enter_dialogue_choice(), "沃伦来电应可进入选择。")
	var dialogue_driver: RefCounted = AGENT_DIALOGUE_TEST_DRIVER_SCRIPT.new()
	_assert_ok(dialogue_driver.call(&"commit_active_call", official_only_engine, "call_01_warren", "warren", [], "我没有亲眼看见，还是等官方消息吧。"), "不披露传闻的沃伦 ActorTurn 必须可提交。")
	_assert_true(not official_only_engine.is_statement_revealed("statement_warren_tanker_fire_claim"), "安抚/等待官方消息路径不得取得油罐车诱因陈述。")
	_assert_true(not official_only_engine.is_fact_confirmed("fact_accounts_conflict"), "没有油罐车来源陈述时不得确认事故诱因冲突。")

	var report_engine: StoryEngine = _make_engine(story)
	_assert_ok(report_engine.mark_computer_entry_read("messages", "message_01_miller"), "正向路径也必须先取得官方封桥来源。")
	_assert_ok(report_engine.advance_to_game_tick(60), "正向路径的沃伦来电必须触发。")
	var report_phone: PhoneSystem = report_engine._phone_system as PhoneSystem
	_assert_true(report_phone.answer_call(60), "正向路径的沃伦来电应可接听。")
	_assert_true(report_phone.enter_dialogue_choice(), "正向路径的沃伦来电应可进入选择。")
	_assert_ok(dialogue_driver.call(&"commit_active_call", report_engine, "call_01_warren", "warren", ["statement_warren_tanker_fire_claim"], "酒吧有人说北桥附近一辆油罐车起火；我没有亲眼看见。"), "披露传闻的沃伦 ActorTurn 必须可提交。")
	_assert_true(report_engine.is_statement_revealed("statement_warren_tanker_fire_claim"), "追问桥边事故才必须揭示沃伦的油罐车传闻陈述。")
	_assert_true(report_engine.is_fact_confirmed("fact_accounts_conflict"), "官方结构受损与沃伦油罐车说法齐备后才确认来源描述冲突。")


func _test_missed_call_does_not_reveal_statement(validated_story: Dictionary) -> void:
	var story: Dictionary = _make_single_target_story(validated_story, "call_09_southbound")
	var engine: StoryEngine = _make_engine(story)
	_assert_ok(engine.advance_to_game_tick(60), "漏接测试必须先让年轻司机来电响铃。")
	_assert_ok(engine.advance_to_game_tick(120), "响铃超时后必须生成真实漏接记录。")
	_assert_true(not engine.is_statement_revealed("statement_southbound_bridge_claim"), "漏接电话绝不能揭示北桥经过陈述。")
	_assert_true(not engine.is_statement_revealed("statement_southbound_wagon_sighting"), "漏接电话绝不能揭示车辆目击陈述。")
	var call_entries: Array[Dictionary] = engine.get_computer_entries("call_log")
	_assert_equal(call_entries.size(), 1, "漏接电话必须由 PhoneSystem 生成一条真实来电记录。")
	if not call_entries.is_empty():
		_assert_equal(String(call_entries[0]["event_id"]), "call_09_southbound", "来电记录必须保持原始 event_id。")
		_assert_equal((call_entries[0]["revealed_statement_ids"] as Array).size(), 0, "漏接记录不得被装饰成已获得电话陈述。")


func _test_ending_facts_remain_authoritative(validated_story: Dictionary) -> void:
	var story: Dictionary = _make_single_target_story(validated_story, "call_11_final_amy")
	var engine: StoryEngine = _make_engine(story)
	_assert_ok(engine.advance_to_game_tick(60), "艾米来电必须按聚焦时间窗触发。")
	var phone: PhoneSystem = engine._phone_system as PhoneSystem
	_assert_true(phone.answer_call(60), "艾米来电应可接听。")
	_assert_true(phone.enter_dialogue_choice(), "艾米来电应可进入选择。")
	var dialogue_driver: RefCounted = AGENT_DIALOGUE_TEST_DRIVER_SCRIPT.new()
	_assert_ok(dialogue_driver.call(&"commit_active_call", engine, "call_11_final_amy", "amy", ["statement_amy_unauthorized_broadcast"], "收音机里有个像你一样的声音让我们继续开，但桥面根本过不去。"), "艾米 committed ActorTurn 必须可提交。")
	_assert_true(engine.is_statement_revealed("statement_amy_unauthorized_broadcast"), "艾米来电可以揭示她听见过的来源陈述。")
	_assert_true(not engine.is_fact_confirmed("fact_unauthorized_broadcast"), "02:00 前角色陈述不能确认 Studio A 未授权播出。")
	_assert_true(not engine.is_fact_confirmed("fact_anomaly_cause_unknown"), "02:00 前不得确认异常成因未知。")
	_assert_ok(engine.force_ending_at_0200(), "02:00 必须强制收束。")
	_assert_true(engine.is_fact_confirmed("fact_unauthorized_broadcast"), "02:00 结尾事件必须确认未授权播出事实。")
	_assert_true(engine.is_fact_confirmed("fact_anomaly_cause_unknown"), "02:00 结尾事件必须确认异常成因未知。")
	var read_after_ending: Dictionary = engine.mark_computer_entry_read("news", "news_north_bridge_closure")
	_assert_error_code(read_after_ending, "ending_forced", "02:00 后公共阅读接口必须冻结，不得只依赖 UI 锁定。")


func _test_runtime_release_unsubscribes_computer(validated_story: Dictionary) -> void:
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.set_phone_system(phone), "运行时释放测试必须先绑定电话系统。")
	_assert_ok(engine.configure_test_night_story(validated_story), "运行时释放测试必须配置剧情。")
	_assert_ok(engine.release_runtime(), "释放运行时必须同时解除 ComputerSystem 的电话订阅。")
	var probe_call: Dictionary = {
		"id": "call_release_probe",
		"caller_display_name": "释放探针",
		"caller_number": "555-0900",
	}
	_assert_true(phone.begin_incoming_call(probe_call, 0, 60), "释放后的独立 PhoneSystem 仍应可生成探针来电。")
	_assert_true(phone.answer_call(0), "释放后的探针来电仍应可接听。")
	_assert_true(phone.finish_call(0), "释放后的探针来电仍应能生成真实记录。")
	_assert_equal(engine.get_computer_entries("call_log").size(), 0, "已释放的 ComputerSystem 不得再同步旧 PhoneSystem 的新记录。")


func _make_single_target_story(validated_story: Dictionary, target_event_id: String) -> Dictionary:
	var story: Dictionary = validated_story.duplicate(true)
	for raw_event: Variant in story["events"] as Array:
		var event_data: Dictionary = raw_event as Dictionary
		if String(event_data["id"]) == target_event_id:
			event_data["window_start_minute"] = 1
			event_data["window_end_minute"] = 2
		else:
			event_data["window_start_minute"] = 50
			event_data["window_end_minute"] = 59
	for raw_message: Variant in story["messages"] as Array:
		var message: Dictionary = raw_message as Dictionary
		if String(message["id"]) == "message_01_miller":
			message["unlock_minute"] = 0
	return story


func _make_engine(story: Dictionary) -> StoryEngine:
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.set_phone_system(phone), "StoryEngine 必须能绑定 PhoneSystem。")
	_assert_ok(engine.configure_test_night_story(story), "StoryEngine 必须能配置聚焦剧情。")
	return engine


func _find_broadcast_task(tasks: Array[Dictionary], task_id: String) -> Dictionary:
	for task: Dictionary in tasks:
		if String(task.get("id", "")) == task_id:
			return task
	return {}


func _task_has_information(task: Dictionary, information_item_id: String) -> bool:
	for raw_item: Variant in task.get("available_information_items", []) as Array:
		if raw_item is Dictionary and String((raw_item as Dictionary).get("id", "")) == information_item_id:
			return true
	return false


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_error_code(result: Variant, error_code: String, message: String) -> void:
	_assert_true(result is Dictionary and not bool((result as Dictionary).get("ok", false)), message)
	if result is Dictionary:
		_assert_equal(String((result as Dictionary).get("error_code", "")), error_code, "%s error_code 错误。" % message)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][StoryInformationLoop] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
