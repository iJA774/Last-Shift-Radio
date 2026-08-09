extends SceneTree

## 第五阶段剧情与玩家广播专项烟测。
## 覆盖完整内容交叉引用、短信解锁、封桥口径互斥、寻车条件来电、预制对话与
## 02:00 异常记录同玩家记录的严格区分；不依赖 UI 伪造任何权威状态。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	var validated_story: Dictionary = _load_validated_story()
	if not validated_story.is_empty():
		_test_content_shape_and_rejections(validated_story)
		_test_unqualified_conditional_call_is_not_missed(validated_story)
		_test_tanker_choice_records(validated_story)
		_test_broadcast_dialogue_and_condition_flow(validated_story)
	if _has_failed:
		print("[测试][TestNightStory] 失败。")
		quit(1)
		return
	print("[测试][TestNightStory] 通过：测试剧情、广播、条件来电、对话与异常记录契约成立。")
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
	_assert_equal((validated_story["broadcasts"] as Array).size(), 3, "测试剧情必须有 3 条预制广播稿。")
	var event_ids: Dictionary = {}
	for event_data: Dictionary in validated_story["events"] as Array:
		event_ids[String(event_data["id"])] = true
	for required_id: String in ["call_01_warren", "call_04_dog_walker", "call_10_ronnie_2", "call_11_final_amy"]:
		_assert_true(event_ids.has(required_id), "测试剧情缺少必要事件：%s。" % required_id)

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

	var unknown_broadcast: Dictionary = validated_story.duplicate(true)
	var miller_message: Dictionary = (unknown_broadcast["messages"] as Array)[1] as Dictionary
	miller_message["unlocks_broadcast_ids"] = ["broadcast_missing"]
	_assert_error(
		validator.call(&"validate_test_night_story", unknown_broadcast, "memory://unknown_broadcast"),
		"unknown_broadcast_id",
		"message_01_miller",
		"unlocks_broadcast_ids",
		"短信引用未知广播稿必须被完整拒绝。"
	)

	var bad_dialogue_link: Dictionary = validated_story.duplicate(true)
	var first_node: Dictionary = (bad_dialogue_link["dialogue_nodes"] as Array)[0] as Dictionary
	var first_option: Dictionary = (first_node["options"] as Array)[0] as Dictionary
	first_option["next_node_id"] = "dlg_missing_node"
	_assert_error(
		validator.call(&"validate_test_night_story", bad_dialogue_link, "memory://bad_dialogue_link"),
		"unknown_dialogue_node_id",
		"dlg_warren_open",
		"options.next_node_id",
		"悬空对话分支必须被完整拒绝。"
	)

	var bad_group: Dictionary = validated_story.duplicate(true)
	var first_broadcast: Dictionary = (bad_group["broadcasts"] as Array)[0] as Dictionary
	first_broadcast["exclusive_group_id"] = "桥梁口径"
	_assert_error(
		validator.call(&"validate_test_night_story", bad_group, "memory://bad_group"),
		"invalid_exclusive_group_id",
		"broadcast_bridge_tanker_fire",
		"exclusive_group_id",
		"互斥组 ID 非稳定英文标识符必须被拒绝。"
	)


func _test_broadcast_dialogue_and_condition_flow(validated_story: Dictionary) -> void:
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "StoryEngine 必须接受 PhoneSystem。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "StoryEngine 必须接受已校验测试剧情。")
	_assert_equal((engine.call(&"get_available_broadcasts") as Array).size(), 0, "官方短信前不应显示可播出稿件。")

	_assert_ok(engine.call(&"advance_to_game_tick", 60), "01:01 应能触发沃伦来电。")
	_assert_true(bool(phone.call(&"answer_call", 60)), "沃伦来电应可接听。")
	_assert_equal((engine.call(&"get_available_broadcasts") as Array).size(), 0, "仅接通沃伦但未读完对话时不得提前解锁油罐车稿。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "沃伦通话应可进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "沃伦来电必须能开始预制对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_warren_song"), "沃伦第一轮选项必须可提交。")
	var warren_finish: Dictionary = engine.call(&"select_dialogue_option", "opt_warren_follow_report") as Dictionary
	_assert_ok(warren_finish, "沃伦第二轮选项必须可提交。")
	_assert_true(bool(warren_finish["reached_terminal"]), "沃伦第二轮后必须抵达终止台词。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "沃伦终止台词后必须回到 Connected。")
	var repeated_dialogue: Dictionary = engine.call(&"begin_active_call_dialogue") as Dictionary
	_assert_error_code(repeated_dialogue, "dialogue_already_started", "同一通电话的预制对话不得从入口重复开始。")
	_assert_true(bool(phone.call(&"finish_call", 60)), "沃伦来电应可正常结束。")
	_assert_ok(engine.call(&"advance_to_game_tick", 480), "01:08 应能触发错号来电。")
	_assert_true(bool(phone.call(&"answer_call", 480)), "错号来电应可接听。")
	_assert_true(bool(phone.call(&"finish_call", 480)), "错号来电应可正常结束。")
	_assert_ok(engine.call(&"advance_to_game_tick", 720), "01:12 应能解锁警员短信。")
	var closure_drafts: Array = engine.call(&"get_available_broadcasts") as Array
	_assert_equal(closure_drafts.size(), 2, "警员短信必须解锁两种封桥口径。")
	var send_closure: Dictionary = engine.call(&"send_player_broadcast", "broadcast_bridge_structural_closure") as Dictionary
	_assert_ok(send_closure, "结构受损封桥稿必须可发送。")
	var closure_record: Dictionary = send_closure["record"] as Dictionary
	_assert_equal(String(closure_record["broadcast_id"]), "broadcast_bridge_structural_closure", "玩家记录必须保存稳定 broadcast_id。")
	_assert_equal(String(closure_record["source"]), "Studio A", "玩家记录必须保存来源。")
	_assert_equal(int(closure_record["sent_at_tick"]), 720, "玩家记录必须保存发送游戏 tick。")
	_assert_true(not bool(closure_record["is_unauthorized"]), "玩家发送的记录不得标为未授权。")
	_assert_true(closure_record.is_read_only(), "玩家公开记录必须是只读快照。")
	var blocked_other_closure: Dictionary = engine.call(&"send_player_broadcast", "broadcast_bridge_tanker_fire") as Dictionary
	_assert_error_code(blocked_other_closure, "broadcast_exclusive_group_sent", "封桥口径互斥时必须明确拒绝另一稿。")
	var repeated_closure: Dictionary = engine.call(&"send_player_broadcast", "broadcast_bridge_structural_closure") as Dictionary
	_assert_error_code(repeated_closure, "broadcast_already_sent", "重复点击同一稿件不得重复记录。")
	_assert_equal((engine.call(&"get_player_broadcast_records") as Array).size(), 1, "重复点击不得增加玩家播出记录。")

	_assert_ok(engine.call(&"advance_to_game_tick", 1020), "01:17 应能触发玛莎来电。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_03_martha", "玛莎必须成为当前活动线路。")
	_assert_true(bool(phone.call(&"answer_call", 1020)), "玛莎来电应可接听。")
	_assert_equal((engine.call(&"get_available_broadcasts") as Array).size(), 2, "未完成玛莎对话时不得提前解锁寻车稿。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "玛莎通话应可进入对话选择。")
	var dialogue_begin: Dictionary = engine.call(&"begin_active_call_dialogue") as Dictionary
	_assert_ok(dialogue_begin, "已接通的玛莎来电必须能开始预制对话。")
	var opening_snapshot: Dictionary = dialogue_begin["snapshot"] as Dictionary
	_assert_equal(String(opening_snapshot["node_id"]), "dlg_martha_open", "玛莎对话必须从稳定入口开始。")
	var dialogue_choice: Dictionary = engine.call(&"select_dialogue_option", "opt_martha_vehicle") as Dictionary
	_assert_ok(dialogue_choice, "玛莎对话选项必须可提交。")
	_assert_true(not bool(dialogue_choice["reached_terminal"]), "玛莎第一轮选择后必须保留第二轮预制选择。")
	var dialogue_second_choice: Dictionary = engine.call(&"select_dialogue_option", "opt_martha_follow_request") as Dictionary
	_assert_ok(dialogue_second_choice, "玛莎第二轮对话选项必须可提交。")
	_assert_true(bool(dialogue_second_choice["reached_terminal"]), "玛莎的第二轮选择后必须抵达终止台词。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "终止台词后电话必须回到 Connected。")
	_assert_true(bool(phone.call(&"finish_call", 1020)), "玛莎通话应可正常结束。")
	var wagon_drafts: Array = engine.call(&"get_available_broadcasts") as Array
	_assert_equal(wagon_drafts.size(), 3, "接通玛莎后必须解锁寻车广播稿。")
	var wagon_result: Dictionary = engine.call(&"send_player_broadcast", "broadcast_wagon_witness_request") as Dictionary
	_assert_ok(wagon_result, "寻车广播稿必须可发送。")
	_assert_true(bool(engine.call(&"is_condition_met", "condition_wagon_witness_request_sent")), "寻车广播必须通过稳定条件 ID 解锁后续来电。")
	_assert_ok(engine.call(&"advance_to_game_tick", 1380), "01:23 应能处理条件来电。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_04_dog_walker", "播出寻车稿后条件来电必须触发。")

	_assert_ok(engine.call(&"force_ending_at_0200", 3600), "02:00 必须能强制收束。")
	var player_records: Array = engine.call(&"get_player_broadcast_records") as Array
	_assert_equal(player_records.size(), 2, "两次玩家真实播出必须保留。")
	var unauthorized: Dictionary = engine.call(&"get_unauthorized_broadcast_record") as Dictionary
	_assert_equal(String(unauthorized["broadcast_id"]), "broadcast_unauthorized_north_bridge_open", "异常播出必须使用独立稳定 ID。")
	_assert_true(bool(unauthorized["is_unauthorized"]), "02:00 异常播出必须标为未授权。")
	_assert_equal(int(unauthorized["sent_at_tick"]), 3600, "02:00 异常播出必须使用精确 tick。")
	_assert_true(unauthorized.is_read_only(), "异常播出公开记录必须是只读快照。")


func _test_unqualified_conditional_call_is_not_missed(validated_story: Dictionary) -> void:
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "条件失效测试必须连接电话系统。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "条件失效测试必须配置完整剧情。")
	# 不发送寻车稿，直接越过 call_04 的窗口。其他事件的漏接不影响断言；
	# 关键是 dog walker 从未具备触发资格，因而不得生成电话状态机记录。
	_assert_ok(engine.call(&"advance_to_game_tick", 1680), "越过条件来电窗口的时间推进必须成功。")
	var records: Array = phone.call(&"get_call_records") as Array
	for raw_record: Variant in records:
		if raw_record is Dictionary:
			_assert_true(String((raw_record as Dictionary).get("event_id", "")) != "call_04_dog_walker", "未播出寻车稿时不得生成 call_04_dog_walker 漏接记录。")
	_assert_equal(
		String((engine.call(&"get_scheduler") as EventScheduler).get_event_status("call_04_dog_walker")),
		"suppressed_condition_unmet",
		"未取得条件资格的来电必须标记为安静失效。"
	)


func _test_tanker_choice_records(validated_story: Dictionary) -> void:
	var engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.call(&"set_phone_system", phone), "油罐车口径测试必须连接电话系统。")
	_assert_ok(engine.call(&"configure_test_night_story", validated_story), "油罐车口径测试必须配置完整剧情。")
	_assert_ok(engine.call(&"advance_to_game_tick", 60), "油罐车口径测试必须触发沃伦来电。")
	_assert_true(bool(phone.call(&"answer_call", 60)), "油罐车口径测试必须接通沃伦。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "油罐车口径测试必须进入对话选择。")
	_assert_ok(engine.call(&"begin_active_call_dialogue"), "油罐车口径测试必须开始沃伦对话。")
	_assert_ok(engine.call(&"select_dialogue_option", "opt_warren_sober"), "油罐车口径测试必须提交第一轮回应。")
	var final_choice: Dictionary = engine.call(&"select_dialogue_option", "opt_warren_follow_caution") as Dictionary
	_assert_ok(final_choice, "油罐车口径测试必须提交第二轮回应。")
	_assert_true(bool(final_choice.get("reached_terminal", false)), "沃伦第二轮回应必须结束预制对话。")
	var tanker_result: Dictionary = engine.call(&"send_player_broadcast", "broadcast_bridge_tanker_fire") as Dictionary
	_assert_ok(tanker_result, "沃伦对话完成后，未核实油罐车口径必须可发送。")
	var tanker_record: Dictionary = tanker_result.get("record", {}) as Dictionary
	_assert_equal(String(tanker_record.get("broadcast_id", "")), "broadcast_bridge_tanker_fire", "油罐车口径必须生成稳定玩家记录。")
	_assert_true(not bool(tanker_record.get("is_unauthorized", true)), "油罐车口径必须是玩家授权播出。")


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
