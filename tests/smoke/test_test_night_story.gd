extends SceneTree

## 正式测试夜班 Agent Dialogue v2 / 麦克风发布任务专项烟测。
##
## 不再通过 option graph 推进正式剧情；测试直接模拟 StoryEngine 已接受的 committed
## ActorTurn，验证 Statement → Fact → semantic requirement → Broadcast Task 权威链。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

const TASK_BRIDGE: String = "task_broadcast_bridge_closure"
const TASK_WAGON: String = "task_broadcast_wagon_witness_request"
const INFO_WARREN: String = "info_bridge_tanker_fire"
const INFO_TRUCKER: String = "info_bridge_east_queue"
const INFO_SOUTHBOUND: String = "info_bridge_southbound_crossing"
const INFO_WAGON: String = "info_wagon_martha_route"

var _has_failed: bool = false


func _init() -> void:
	var validated_story: Dictionary = _load_validated_story()
	if not validated_story.is_empty():
		_test_content_shape_and_rejections(validated_story)
		_test_bridge_task_minimum_gate_and_send_once(validated_story)
		_test_bridge_task_waits_for_optional_c(validated_story)
		_test_wagon_task_condition_flow(validated_story)
		_test_unqualified_conditional_call_is_not_missed(validated_story)
	if _has_failed:
		print("[测试][TestNightStory] 失败。")
		quit(1)
		return
	print("[测试][TestNightStory] 通过：Agent Dialogue v2 内容、semantic requirements、可选信息与条件来电契约成立。")
	quit(0)


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_value: Variant = loader.call(&"load_json", STORY_PATH)
	_assert_true(load_value is Dictionary, "内容读取器必须返回 Dictionary。")
	if not load_value is Dictionary:
		return {}
	var load_result: Dictionary = load_value as Dictionary
	_assert_ok(load_result, "test_night_story.json 必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_value: Variant = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH)
	_assert_true(validation_value is Dictionary, "内容校验器必须返回 Dictionary。")
	if not validation_value is Dictionary:
		return {}
	var validation: Dictionary = validation_value as Dictionary
	_assert_ok(validation, "test_night_story.json 必须通过完整严格 v2 校验。")
	if not bool(validation.get("ok", false)):
		return {}
	return validation


func _test_content_shape_and_rejections(validated_story: Dictionary) -> void:
	_assert_equal(int(validated_story.get("content_format_version", -1)), 2, "正式测试夜班必须启用 content_format_version=2。")
	_assert_equal((validated_story["events"] as Array).size(), 11, "测试剧情必须有 11 通来电。")
	_assert_equal((validated_story["actors"] as Array).size(), 10, "Agent Dialogue v2 必须精确声明 10 个持久 Actor。")
	_assert_equal((validated_story["messages"] as Array).size(), 6, "测试剧情必须有 6 条短信。")
	_assert_equal((validated_story["broadcast_tasks"] as Array).size(), 2, "测试剧情必须有 2 个统一麦克风发布任务。")
	_assert_true(not validated_story.has("dialogue_nodes"), "正式 v2 内容不得继续携带 dialogue_nodes。")

	var ronnie_events: Array[String] = []
	for raw_event: Variant in validated_story["events"] as Array:
		var event: Dictionary = raw_event as Dictionary
		_assert_true(not event.has("dialogue_start_id"), "v2 来电不得携带 dialogue_start_id：%s。" % String(event.get("id", "")))
		if String(event.get("actor_id", "")) == "ronnie":
			ronnie_events.append(String(event.get("id", "")))
	ronnie_events.sort()
	_assert_equal(ronnie_events, ["call_07_ronnie_1", "call_10_ronnie_2"], "Ronnie 两通电话必须共用唯一 actor_id=ronnie。")

	var bridge_task: Dictionary = _find_definition(validated_story["broadcast_tasks"] as Array, TASK_BRIDGE)
	_assert_true(not bridge_task.is_empty(), "必须配置北桥封锁发布任务。")
	_assert_equal(
		bridge_task["requirements"],
		[
			{"type": "interaction_answered", "id": "call_01_warren"},
			{"type": "interaction_answered", "id": "call_06_trucker"},
		],
		"北桥最低门槛必须保持为 Warren + Trucker 实际参与，而不是强制 Statement reveal。"
	)
	_assert_equal(bridge_task["related_event_ids"], ["call_01_warren", "call_06_trucker", "call_09_southbound"], "南向年轻司机必须继续是可等待的相关事件。")
	_assert_equal((bridge_task["information_items"] as Array).size(), 4, "北桥任务必须同时允许电话信息与米勒短信信息成为可选项。")

	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var unknown_condition: Dictionary = validated_story.duplicate(true)
	var conditional_event: Dictionary = (unknown_condition["events"] as Array)[3] as Dictionary
	conditional_event["condition_ids"] = ["condition_missing"]
	_assert_error(
		validator.call(&"validate_test_night_story", unknown_condition, "memory://unknown_condition"),
		"unknown_condition_id",
		"call_04_dog_walker",
		"condition_ids",
		"未声明条件必须被完整拒绝。"
	)

	var unknown_related_event: Dictionary = validated_story.duplicate(true)
	var invalid_task: Dictionary = (unknown_related_event["broadcast_tasks"] as Array)[0] as Dictionary
	invalid_task["related_event_ids"] = ["call_missing", "call_06_trucker", "call_09_southbound"]
	_assert_error(
		validator.call(&"validate_test_night_story", unknown_related_event, "memory://unknown_related_event"),
		"unknown_event_id",
		TASK_BRIDGE,
		"related_event_ids",
		"发布任务引用不存在的相关事件必须被拒绝。"
	)

	var legacy_requirement: Dictionary = validated_story.duplicate(true)
	var legacy_task: Dictionary = (legacy_requirement["broadcast_tasks"] as Array)[0] as Dictionary
	legacy_task["required_dialogue_event_ids"] = ["call_01_warren", "call_06_trucker"]
	_assert_error(
		validator.call(&"validate_test_night_story", legacy_requirement, "memory://legacy_requirement"),
		"legacy_dialogue_requirement_forbidden",
		TASK_BRIDGE,
		"required_dialogue_event_ids",
		"v2 任务重新引入 terminal-dialogue 门槛必须被拒绝。"
	)

	var unknown_statement: Dictionary = validated_story.duplicate(true)
	var statement_task: Dictionary = (unknown_statement["broadcast_tasks"] as Array)[0] as Dictionary
	var statement_item: Dictionary = (statement_task["information_items"] as Array)[0] as Dictionary
	statement_item["statement_ids"] = ["statement_missing"]
	_assert_error(
		validator.call(&"validate_test_night_story", unknown_statement, "memory://unknown_statement"),
		"unknown_statement_id",
		INFO_WARREN,
		"statement_ids",
		"信息项引用不存在的稳定陈述必须被拒绝。"
	)

	var duplicate_information_id: Dictionary = validated_story.duplicate(true)
	var first_task: Dictionary = (duplicate_information_id["broadcast_tasks"] as Array)[0] as Dictionary
	var second_task: Dictionary = (duplicate_information_id["broadcast_tasks"] as Array)[1] as Dictionary
	var first_information_id: String = String(((first_task["information_items"] as Array)[0] as Dictionary)["id"])
	var second_information: Dictionary = (second_task["information_items"] as Array)[0] as Dictionary
	second_information["id"] = first_information_id
	_assert_error(
		validator.call(&"validate_test_night_story", duplicate_information_id, "memory://duplicate_information_id"),
		"duplicate_information_item_id",
		first_information_id,
		"information_items.id",
		"信息项 ID 必须在所有发布任务之间全局唯一。"
	)


func _test_bridge_task_minimum_gate_and_send_once(validated_story: Dictionary) -> void:
	var runtime: Dictionary = _make_story_runtime(validated_story)
	var engine: RefCounted = runtime["engine"] as RefCounted
	var phone: RefCounted = runtime["phone"] as RefCounted

	_complete_agent_call(engine, phone, 60, "call_01_warren", "warren", ["statement_warren_tanker_fire_claim"], "酒吧有人说北桥那边一辆油罐车翻了还冒烟；我没亲眼看见。")
	var after_a: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_equal(int(after_a.get("satisfied_requirement_count", -1)), 1, "完成 A=沃伦后，北桥 semantic requirement 进度必须为 1/2。")
	_assert_true(not bool(after_a.get("prerequisites_met", true)), "只完成 A 时不得满足发布门槛。")
	_assert_equal(_available_information_ids(after_a), [INFO_WARREN], "A 路径揭示沃伦传闻时只能收集 1 号信息。")
	var premature: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN]) as Dictionary
	_assert_error_code(premature, "broadcast_task_prerequisites_unmet", "只完成 A 时，即使已有 1 号信息也必须拒绝发布。")

	_complete_agent_call(engine, phone, 1980, "call_06_trucker", "trucker", ["statement_trucker_bridge_queue"], "北桥东侧堵得像停车场，大家都停在封闭区域前等着。")
	var after_b: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_equal(int(after_b.get("satisfied_requirement_count", -1)), 2, "完成 B=卡车司机后，北桥 semantic requirement 进度必须为 2/2。")
	_assert_true(bool(after_b.get("prerequisites_met", false)), "完成 A+B 后必须满足最低 interaction_answered 门槛。")
	_assert_true(bool(after_b.get("is_publishable", false)), "A+B 后且已有信息时任务必须可发布。")
	_assert_equal(_available_information_ids(after_b), [INFO_TRUCKER, INFO_WARREN], "未读取米勒短信、未等待 C 时必须恰好可选 1/2 两条电话信息。")
	var empty_selection: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, []) as Dictionary
	_assert_error_code(empty_selection, "information_selection_count_invalid", "达到 A+B 门槛后仍必须至少选择一条已收集信息。")
	var duplicate_selection: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN, INFO_WARREN]) as Dictionary
	_assert_error_code(duplicate_selection, "broadcast_task_duplicate_information", "同一信息项不得在一次任务发布中重复选择。")
	var unavailable_selection: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN, INFO_SOUTHBOUND]) as Dictionary
	_assert_error_code(unavailable_selection, "broadcast_task_information_unavailable", "尚未完成 C 时不得选择未真正收集的南向司机信息。")
	_assert_equal((engine.call(&"get_player_broadcast_records") as Array).size(), 0, "三种非法选择被拒绝后都不得提前生成玩家发布记录。")

	var send_result: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN, INFO_TRUCKER]) as Dictionary
	_assert_ok(send_result, "A+B 后必须能一次发布 1/2 两条已收集信息。")
	var record: Dictionary = send_result.get("record", {}) as Dictionary
	_assert_equal(String(record.get("task_id", "")), TASK_BRIDGE, "玩家发布记录必须保存稳定 task_id。")
	_assert_equal(record.get("information_item_ids", []), [INFO_WARREN, INFO_TRUCKER], "玩家发布记录必须保存本次实际选择的信息项 IDs。")
	_assert_true(String(record.get("body", "")).contains("油罐车") and String(record.get("body", "")).contains("东侧入口"), "一次任务记录正文必须由本次选择的多条信息组合而成。")
	_assert_true(not bool(record.get("is_unauthorized", true)), "玩家任务发布不得标成未授权播出。")
	var repeat_result: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN]) as Dictionary
	_assert_error_code(repeat_result, "broadcast_task_already_sent", "同一发布任务完成后不得再次发布。")
	_assert_equal((engine.call(&"get_player_broadcast_records") as Array).size(), 1, "重复发布被拒绝后不得增加玩家广播记录。")


func _test_bridge_task_waits_for_optional_c(validated_story: Dictionary) -> void:
	var runtime: Dictionary = _make_story_runtime(validated_story)
	var engine: RefCounted = runtime["engine"] as RefCounted
	var phone: RefCounted = runtime["phone"] as RefCounted
	_complete_agent_call(engine, phone, 60, "call_01_warren", "warren", ["statement_warren_tanker_fire_claim"], "北桥那边有人说油罐车翻了还冒烟，我没亲眼见。")
	_complete_agent_call(engine, phone, 1980, "call_06_trucker", "trucker", ["statement_trucker_bridge_queue"], "北桥东边严重拥堵，封闭区域前全是车。")
	var ready_before_c: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_true(bool(ready_before_c.get("is_publishable", false)), "A+B 后玩家必须已经可以选择立即发布。")
	_assert_equal(_available_information_ids(ready_before_c), [INFO_TRUCKER, INFO_WARREN], "等待 C 前只应有 1/2 两条电话信息。")

	_complete_agent_call(engine, phone, 2940, "call_09_southbound", "southbound", ["statement_southbound_bridge_claim"], "我按临时路牌驶过北桥，已经下桥到城南路口了。")
	var after_c: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_true(bool(after_c.get("prerequisites_met", false)), "等待 C 不应改变已经满足的 A+B 最低门槛。")
	_assert_equal(_available_information_ids(after_c), [INFO_TRUCKER, INFO_SOUTHBOUND, INFO_WARREN], "完成 C 后必须额外出现第 3 条南向司机信息。")
	var send_result: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN, INFO_TRUCKER, INFO_SOUTHBOUND]) as Dictionary
	_assert_ok(send_result, "等待 C 后必须能一次发布 1/2/3 三条已收集信息。")
	var record: Dictionary = send_result.get("record", {}) as Dictionary
	_assert_equal(record.get("information_item_ids", []), [INFO_WARREN, INFO_TRUCKER, INFO_SOUTHBOUND], "等待路径的玩家记录必须精确保存所选 1/2/3 信息。")


func _test_wagon_task_condition_flow(validated_story: Dictionary) -> void:
	var runtime: Dictionary = _make_story_runtime(validated_story)
	var engine: RefCounted = runtime["engine"] as RefCounted
	var phone: RefCounted = runtime["phone"] as RefCounted
	_complete_agent_call(engine, phone, 1020, "call_03_martha", "martha", ["statement_martha_wagon_route"], "丹尼开的是深色旧旅行车，右后灯接触不好，常从北桥回城南。")
	var wagon_task: Dictionary = _find_task_snapshot(engine, TASK_WAGON)
	_assert_true(bool(wagon_task.get("is_publishable", false)), "玛莎 interaction 已回答且路线 Statement 已揭示后，寻车任务必须可发布。")
	_assert_equal(_available_information_ids(wagon_task), [INFO_WAGON], "寻车任务必须只显示真正收集的玛莎信息。")
	_assert_ok(engine.call(&"send_broadcast_task", TASK_WAGON, [INFO_WAGON]), "寻车任务必须可发送。")
	_assert_true(bool(engine.call(&"is_condition_met", "condition_wagon_witness_request_sent")), "寻车任务必须通过稳定条件 ID 解锁后续来电。")
	_assert_ok(engine.call(&"advance_to_game_tick", 1380), "01:23 应能处理条件来电。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_04_dog_walker", "发布寻车任务后条件来电必须触发。")

	_assert_ok(engine.call(&"force_ending_at_0200", 3600), "02:00 必须能强制收束。")
	var player_records: Array = engine.call(&"get_player_broadcast_records") as Array
	_assert_equal(player_records.size(), 1, "这一局只应保留一次玩家真实任务发布。")
	var unauthorized: Dictionary = engine.call(&"get_unauthorized_broadcast_record") as Dictionary
	_assert_equal(String(unauthorized["broadcast_id"]), "broadcast_unauthorized_north_bridge_open", "02:00 异常播出仍必须使用独立稳定 broadcast_id。")
	_assert_true(bool(unauthorized["is_unauthorized"]), "02:00 异常播出必须标为未授权。")
	_assert_equal(int(unauthorized["sent_at_tick"]), 3600, "02:00 异常播出必须使用精确 tick。")
	_assert_true(unauthorized.is_read_only(), "异常播出公开记录必须是只读快照。")


func _test_unqualified_conditional_call_is_not_missed(validated_story: Dictionary) -> void:
	var runtime: Dictionary = _make_story_runtime(validated_story)
	var engine: RefCounted = runtime["engine"] as RefCounted
	var phone: RefCounted = runtime["phone"] as RefCounted
	# 不执行寻车发布任务，直接越过 call_04 的窗口。未取得资格的条件来电不得伪造漏接记录。
	_assert_ok(engine.call(&"advance_to_game_tick", 1680), "越过条件来电窗口的时间推进必须成功。")
	var records: Array = phone.call(&"get_call_records") as Array
	for raw_record: Variant in records:
		if raw_record is Dictionary:
			_assert_true(String((raw_record as Dictionary).get("event_id", "")) != "call_04_dog_walker", "未发布寻车任务时不得生成 call_04_dog_walker 漏接记录。")
	_assert_equal(
		String((engine.call(&"get_scheduler") as EventScheduler).get_event_status("call_04_dog_walker")),
		"suppressed_condition_unmet",
		"未取得条件资格的来电必须标记为安静失效。"
	)


func _make_story_runtime(validated_story: Dictionary) -> Dictionary:
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "测试剧情必须绑定 PhoneSystem。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "测试剧情必须配置完整 v2 内容。")
	_assert_true(bool(engine.call(&"is_agent_dialogue_v2")), "正式测试剧情必须被 StoryEngine 识别为 Agent Dialogue v2。")
	return {"engine": engine, "phone": phone}


func _complete_agent_call(
	engine: RefCounted,
	phone: RefCounted,
	tick: int,
	event_id: String,
	actor_id: String,
	asserted_statement_ids: Array,
	utterance: String
) -> void:
	_assert_ok(engine.call(&"advance_to_game_tick", tick), "%s 时间推进必须成功。" % event_id)
	_assert_equal(String(phone.call(&"get_active_event_id")), event_id, "%s 必须成为当前活动线路。" % event_id)
	_assert_true(bool(phone.call(&"answer_call", tick)), "%s 必须可接听。" % event_id)
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "%s 必须进入自由对话线路状态。" % event_id)
	var session_id: String = "test_%s" % event_id
	_assert_ok(engine.call(&"begin_agent_interaction", session_id, event_id, actor_id), "%s 必须能建立 Agent interaction。" % event_id)
	var actor_turn: Dictionary = {
		"speech_act": "answer",
		"utterance": utterance,
		"asserted_claim_ids": asserted_statement_ids.duplicate(),
		"withheld_claim_ids": [],
		"session_intent": "continue",
		"world_action": null,
	}
	var commit_result: Dictionary = engine.call(&"commit_agent_turn", {
		"session_id": session_id,
		"event_id": event_id,
		"actor_id": actor_id,
		"request_serial": 1,
		"turn_index": 1,
		"actor_turn": actor_turn,
	}) as Dictionary
	_assert_ok(commit_result, "%s committed ActorTurn 必须能由 StoryEngine 权威提交。" % event_id)
	_assert_ok(engine.call(&"complete_agent_interaction", session_id, event_id, "interaction_completed"), "%s Agent interaction 必须能正式完成。" % event_id)
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "%s 完成 interaction 后必须回到 Connected。" % event_id)
	_assert_true(bool(phone.call(&"finish_call", tick)), "%s 必须由 PhoneSystem 正式结束。" % event_id)


func _find_task_snapshot(engine: RefCounted, task_id: String) -> Dictionary:
	var tasks_value: Variant = engine.call(&"get_broadcast_tasks")
	_assert_true(tasks_value is Array, "StoryEngine.get_broadcast_tasks() 必须返回 Array。")
	if not tasks_value is Array:
		return {}
	return _find_definition(tasks_value as Array, task_id)


func _find_definition(items: Array, stable_id: String) -> Dictionary:
	for raw_item: Variant in items:
		if raw_item is Dictionary and String((raw_item as Dictionary).get("id", "")) == stable_id:
			return raw_item as Dictionary
	return {}


func _available_information_ids(task: Dictionary) -> Array[String]:
	var ids: Array[String] = []
	for raw_item: Variant in task.get("available_information_items", []) as Array:
		if raw_item is Dictionary:
			ids.append(String((raw_item as Dictionary).get("id", "")))
	ids.sort()
	return ids


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_error(result: Variant, error_code: String, event_id: String, field_name: String, message: String) -> void:
	_assert_true(result is Dictionary, "%s 结果类型无效。" % message)
	if not result is Dictionary:
		return
	var payload: Dictionary = result as Dictionary
	_assert_true(not bool(payload.get("ok", false)), message)
	_assert_equal(String(payload.get("error_code", "")), error_code, "%s error_code 不正确。" % message)
	_assert_equal(String(payload.get("event_id", "")), event_id, "%s event_id 不正确。" % message)
	_assert_equal(String(payload.get("field", "")), field_name, "%s field 不正确。" % message)


func _assert_error_code(result: Dictionary, error_code: String, message: String) -> void:
	_assert_true(not bool(result.get("ok", false)), message)
	_assert_equal(String(result.get("error_code", "")), error_code, "%s error_code 不正确。" % message)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][TestNightStory] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
