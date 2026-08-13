extends SceneTree

## 测试夜班剧情与麦克风发布任务专项烟测。
## 覆盖完整内容交叉引用、任务最低对话门槛、已揭示信息多选、等待后续相关电话、
## 一次性任务记账、寻车条件来电，以及 02:00 异常记录同玩家任务记录的严格区分。

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
	print("[测试][TestNightStory] 通过：统一发布任务、最低对话门槛、可选信息、条件来电与异常记录契约成立。")
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
	_assert_ok(validation, "test_night_story.json 必须通过完整严格校验。")
	if not bool(validation.get("ok", false)):
		return {}
	return validation


func _test_content_shape_and_rejections(validated_story: Dictionary) -> void:
	_assert_equal((validated_story["events"] as Array).size(), 11, "测试剧情必须有 11 通来电。")
	_assert_equal((validated_story["messages"] as Array).size(), 6, "测试剧情必须有 6 条短信。")
	_assert_equal((validated_story["broadcast_tasks"] as Array).size(), 2, "测试剧情必须有 2 个统一麦克风发布任务。")
	var bridge_task: Dictionary = _find_definition(validated_story["broadcast_tasks"] as Array, TASK_BRIDGE)
	_assert_true(not bridge_task.is_empty(), "必须配置北桥封锁发布任务。")
	_assert_equal(bridge_task["required_dialogue_event_ids"], ["call_01_warren", "call_06_trucker"], "北桥任务最低门槛必须精确要求沃伦与东侧卡车司机。")
	_assert_equal(bridge_task["related_dialogue_event_ids"], ["call_01_warren", "call_06_trucker", "call_09_southbound"], "南向年轻司机必须是可等待的相关对话，而不是最低必需对话。")
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

	var unknown_related_dialogue: Dictionary = validated_story.duplicate(true)
	var invalid_task: Dictionary = (unknown_related_dialogue["broadcast_tasks"] as Array)[0] as Dictionary
	invalid_task["related_dialogue_event_ids"] = ["call_missing", "call_06_trucker", "call_09_southbound"]
	_assert_error(
		validator.call(&"validate_test_night_story", unknown_related_dialogue, "memory://unknown_related_dialogue"),
		"unknown_dialogue_event_id",
		TASK_BRIDGE,
		"related_dialogue_event_ids",
		"发布任务引用不存在的相关对话必须被拒绝。"
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
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "A+B 门槛测试必须绑定 PhoneSystem。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "A+B 门槛测试必须配置完整剧情。")

	_complete_warren(engine, phone)
	var after_a: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_equal(int(after_a.get("completed_required_dialogue_count", -1)), 1, "完成 A=沃伦后，北桥任务必要通话进度必须为 1/2。")
	_assert_true(not bool(after_a.get("prerequisites_met", true)), "只完成 A 时不得满足发布门槛。")
	_assert_equal(_available_information_ids(after_a), [INFO_WARREN], "A 路径只追问到沃伦传闻时只能收集 1 号信息。")
	var premature: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN]) as Dictionary
	_assert_error_code(premature, "broadcast_task_prerequisites_unmet", "只完成 A 时，即使已有 1 号信息也必须拒绝发布。")

	_complete_trucker(engine, phone)
	var after_b: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_equal(int(after_b.get("completed_required_dialogue_count", -1)), 2, "完成 B=卡车司机后，北桥任务必要通话进度必须为 2/2。")
	_assert_true(bool(after_b.get("prerequisites_met", false)), "完成 A+B 后必须满足最低对话门槛。")
	_assert_true(bool(after_b.get("is_publishable", false)), "A+B 后且已有信息时任务必须可发布。")
	_assert_equal(_available_information_ids(after_b), [INFO_TRUCKER, INFO_WARREN], "未读取米勒短信、未等待 C 时必须恰好可选 1/2 两条电话信息。")
	var empty_selection: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, []) as Dictionary
	_assert_error_code(empty_selection, "broadcast_task_empty_selection", "达到 A+B 门槛后仍必须至少选择一条已收集信息。")
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
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "等待 C 测试必须绑定 PhoneSystem。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "等待 C 测试必须配置完整剧情。")
	_complete_warren(engine, phone)
	_complete_trucker(engine, phone)
	var ready_before_c: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_true(bool(ready_before_c.get("is_publishable", false)), "A+B 后玩家必须已经可以选择立即发布。")
	_assert_equal(_available_information_ids(ready_before_c), [INFO_TRUCKER, INFO_WARREN], "等待 C 前只应有 1/2 两条电话信息。")

	_complete_southbound(engine, phone)
	var after_c: Dictionary = _find_task_snapshot(engine, TASK_BRIDGE)
	_assert_true(bool(after_c.get("prerequisites_met", false)), "等待 C 不应改变已经满足的 A+B 最低门槛。")
	_assert_equal(_available_information_ids(after_c), [INFO_TRUCKER, INFO_SOUTHBOUND, INFO_WARREN], "完成 C 后必须额外出现第 3 条南向司机信息。")
	var send_result: Dictionary = engine.call(&"send_broadcast_task", TASK_BRIDGE, [INFO_WARREN, INFO_TRUCKER, INFO_SOUTHBOUND]) as Dictionary
	_assert_ok(send_result, "等待 C 后必须能一次发布 1/2/3 三条已收集信息。")
	var record: Dictionary = send_result.get("record", {}) as Dictionary
	_assert_equal(record.get("information_item_ids", []), [INFO_WARREN, INFO_TRUCKER, INFO_SOUTHBOUND], "等待路径的玩家记录必须精确保存所选 1/2/3 信息。")


func _test_wagon_task_condition_flow(validated_story: Dictionary) -> void:
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "寻车任务测试必须绑定 PhoneSystem。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "寻车任务测试必须配置完整剧情。")
	_assert_ok(engine.call(&"advance_to_game_tick", 1020), "01:17 应触发玛莎来电。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_03_martha", "玛莎必须成为当前活动线路。")
	_assert_true(bool(phone.call(&"answer_call", 1020)), "玛莎来电应可接听。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "玛莎通话应可进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "玛莎来电必须能开始预制对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_martha_vehicle"), "追问玛莎车辆信息必须可提交。")
	var finish_result: Dictionary = engine.call(&"select_dialogue_option", "opt_martha_follow_request") as Dictionary
	_assert_ok(finish_result, "玛莎第二轮必须可完成。")
	_assert_true(bool(finish_result.get("reached_terminal", false)), "玛莎第二轮后必须抵达终止节点。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "玛莎终止对白后必须回到 Connected。")
	_assert_true(bool(phone.call(&"finish_call", 1020)), "玛莎通话必须正常结束。")
	var wagon_task: Dictionary = _find_task_snapshot(engine, TASK_WAGON)
	_assert_true(bool(wagon_task.get("is_publishable", false)), "完成玛莎对话并揭示路线后，寻车任务必须可发布。")
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
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "条件失效测试必须连接电话系统。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "条件失效测试必须配置完整剧情。")
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


func _complete_warren(engine: RefCounted, phone: RefCounted) -> void:
	_assert_ok(engine.call(&"advance_to_game_tick", 60), "01:01 应触发 A=沃伦来电。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_01_warren", "A 必须是沃伦。")
	_assert_true(bool(phone.call(&"answer_call", 60)), "A=沃伦必须可接听。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "A=沃伦必须能进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "A=沃伦必须能开始预制对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_warren_song"), "A 第一轮必须可提交。")
	var finish_result: Dictionary = engine.call(&"select_dialogue_option", "opt_warren_follow_report") as Dictionary
	_assert_ok(finish_result, "A 第二轮必须可追问事故传闻。")
	_assert_true(bool(finish_result.get("reached_terminal", false)), "A 必须真实抵达终止节点后才算完成对话。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "A 终止对白后必须回到 Connected。")
	_assert_true(bool(phone.call(&"finish_call", 60)), "A 通话必须正常结束。")


func _complete_trucker(engine: RefCounted, phone: RefCounted) -> void:
	_assert_ok(engine.call(&"advance_to_game_tick", 1980), "01:33 应推进到 B=东侧卡车司机时间窗。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_06_trucker", "B 必须是东侧卡车司机；之前非必要来电应按真实窗口处理。")
	_assert_true(bool(phone.call(&"answer_call", 1980)), "B=卡车司机必须可接听。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "B=卡车司机必须能进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "B=卡车司机必须能开始预制对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_trucker_closure"), "B 第一轮必须可确认官方封闭通知。")
	var finish_result: Dictionary = engine.call(&"select_dialogue_option", "opt_trucker_follow_wait") as Dictionary
	_assert_ok(finish_result, "B 第二轮必须可让司机等待现场人员处理。")
	_assert_true(bool(finish_result.get("reached_terminal", false)), "B 必须真实抵达终止节点后才算完成对话。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "B 终止对白后必须回到 Connected。")
	_assert_true(bool(phone.call(&"finish_call", 1980)), "B 通话必须正常结束。")


func _complete_southbound(engine: RefCounted, phone: RefCounted) -> void:
	_assert_ok(engine.call(&"advance_to_game_tick", 2940), "01:49 应推进到 C=南向年轻司机时间窗。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_09_southbound", "C 必须是南向年轻司机；中间来电应按真实窗口处理。")
	_assert_true(bool(phone.call(&"answer_call", 2940)), "C=南向年轻司机必须可接听。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "C=南向年轻司机必须能进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "C=南向年轻司机必须能开始预制对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_southbound_confirm"), "C 第一轮必须确认他指的是北桥并揭示 3 号信息。")
	var finish_result: Dictionary = engine.call(&"select_dialogue_option", "opt_southbound_follow_bridge") as Dictionary
	_assert_ok(finish_result, "C 第二轮必须可完成桥面位置追问。")
	_assert_true(bool(finish_result.get("reached_terminal", false)), "C 必须真实抵达终止节点。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "C 终止对白后必须回到 Connected。")
	_assert_true(bool(phone.call(&"finish_call", 2940)), "C 通话必须正常结束。")


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
