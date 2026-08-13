extends SceneTree

## 第七阶段剧情域快照冒烟。
##
## 在 01:23 条件来电响铃时冻结一局已经阅读/确认/播出过的夜班，销毁并重建
## StoryEngine + PhoneSystem 后严格比较状态；随后继续推进，确保不会重放旧事实、
## 广播或调度事件，并覆盖几个必须原子拒绝的损坏剧情域状态。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	var content: Dictionary = _load_story()
	if not content.is_empty():
		_test_ringing_snapshot_round_trip(content)
	if _has_failed:
		push_error("[测试][StoryDomainSnapshots] 失败。")
		quit(1)
		return
	print("[测试][StoryDomainSnapshots] 通过：剧情、电脑、广播、真实来电记录与 02:00 可严格往返。")
	quit(0)


func _load_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_result: Dictionary = loader.call(&"load_json", STORY_PATH) as Dictionary
	_assert_ok(load_result, "测试剧情 JSON 必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation: Dictionary = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH) as Dictionary
	_assert_ok(validation, "测试剧情必须通过内容校验。")
	if not bool(validation.get("ok", false)):
		return {}
	return validation


func _test_ringing_snapshot_round_trip(content: Dictionary) -> void:
	var source: Dictionary = _make_runtime(content)
	var source_story: StoryEngine = source["story"] as StoryEngine
	var source_phone: PhoneSystem = source["phone"] as PhoneSystem
	_prepare_0123_ringing_state(source_story, source_phone)
	if _has_failed:
		return

	_assert_equal(String(source_phone.get_state_name()), "RINGING", "01:23 保存边界必须仍在响铃。")
	_assert_equal(source_phone.get_active_event_id(), "call_04_dog_walker", "01:23 应保存同一通条件来电。")
	_assert_true(source_story.is_condition_met("condition_wagon_witness_request_sent"), "保存前必须保留已发送广播设置的条件。")
	_assert_true(source_story.is_statement_revealed("statement_warren_tanker_fire_claim"), "保存前必须有已揭示来源陈述。")
	_assert_true(source_story.is_fact_confirmed("fact_accounts_conflict"), "保存前必须有根据陈述确认的事实。")
	_assert_equal(source_story.get_player_broadcast_records().size(), 1, "保存前应有一条真实完成的玩家发布任务记录。")
	var saved_publication: Dictionary = source_story.get_player_broadcast_records()[0]
	_assert_equal(String(saved_publication.get("task_id", "")), "task_broadcast_wagon_witness_request", "保存前玩家记录必须使用稳定 task_id。")
	_assert_equal(saved_publication.get("information_item_ids", []), ["info_wagon_martha_route"], "保存前玩家记录必须精确保存所选信息项。")
	_assert_true(_is_call_record_read(source_story, "call_01_warren"), "保存前必须保留真实来电摘要的已读状态。")

	var source_story_snapshot: Dictionary = _json_round_trip(source_story.create_snapshot(), "剧情快照")
	var source_phone_snapshot: Dictionary = _json_round_trip(source_phone.create_snapshot(), "电话快照")
	if source_story_snapshot.is_empty() or source_phone_snapshot.is_empty():
		return
	_assert_equal(int(source_phone_snapshot["snapshot_current_tick"]), 1380, "响铃快照必须绑定 01:23 的精确 tick。")
	var active_call: Dictionary = source_phone_snapshot["active_call"] as Dictionary
	_assert_true(int(active_call["ringing_ticks_remaining"]) > 0, "响铃快照必须保留正的剩余响铃 tick。")
	_test_phone_forced_end_mismatch(source_phone_snapshot)

	var destination: Dictionary = _make_runtime(content, false)
	var destination_story: StoryEngine = destination["story"] as StoryEngine
	var destination_phone: PhoneSystem = destination["phone"] as PhoneSystem
	var event_by_id: Dictionary = destination_story.get_scheduler().get_configured_events_by_id()
	var phone_context: Dictionary = {"current_game_tick": 1380, "event_by_id": event_by_id}
	_assert_ok(destination_phone.restore_snapshot(source_phone_snapshot, phone_context), "响铃 PhoneSystem 快照必须可恢复。")
	_assert_ok(destination_story.set_phone_system(destination_phone), "恢复后的电话必须先绑定剧情。")
	var story_context: Dictionary = {
		"phone_system": destination_phone,
		"call_record_event_ids": _call_record_ids(destination_phone),
		"current_game_tick": 1380,
	}
	_assert_ok(destination_story.validate_snapshot(source_story_snapshot, story_context), "电话已恢复后剧情快照必须通过完整校验。")
	_assert_ok(destination_story.restore_snapshot(source_story_snapshot, story_context), "剧情域快照必须可恢复。")
	_assert_equal(_json_round_trip(destination_story.create_snapshot(), "恢复后的剧情快照"), source_story_snapshot, "恢复后的剧情快照必须和冻结瞬间完全一致。")
	_assert_equal(_json_round_trip(destination_phone.create_snapshot(), "恢复后的电话快照"), source_phone_snapshot, "恢复后的电话快照必须和冻结瞬间完全一致。")
	_assert_equal(destination_phone.get_active_event_id(), "call_04_dog_walker", "读取后必须继续原来的条件来电。")
	_assert_equal(destination_phone.get_active_call_snapshot(), source_phone.get_active_call_snapshot(), "读取后响铃来显与截止 tick 必须一致。")
	_assert_true(_is_call_record_read(destination_story, "call_01_warren"), "读取后必须保留来电摘要已读状态。")

	_test_atomic_rejections(destination_story, destination_phone, story_context)

	var repeated_statement_signals: int = 0
	var repeated_fact_signals: int = 0
	var repeated_broadcast_signals: int = 0
	var repeated_event_signals: int = 0
	destination_story.statement_revealed.connect(func(_statement: Dictionary) -> void: repeated_statement_signals += 1)
	destination_story.fact_confirmed.connect(func(_fact: Dictionary) -> void: repeated_fact_signals += 1)
	destination_story.player_broadcast_sent.connect(func(_record: Dictionary) -> void: repeated_broadcast_signals += 1)
	destination_story.event_ready.connect(func(_event: Dictionary) -> void: repeated_event_signals += 1)
	_assert_ok(destination_story.advance_to_game_tick(1381), "读取后应能继续推进到下一个 tick。")
	_assert_equal(repeated_statement_signals, 0, "恢复后推进不得重复派发既有陈述。")
	_assert_equal(repeated_fact_signals, 0, "恢复后推进不得重复确认既有事实。")
	_assert_equal(repeated_broadcast_signals, 0, "恢复后推进不得重复记账既有广播。")
	_assert_equal(repeated_event_signals, 0, "恢复后推进不得重新触发已在响铃的事件。")
	_assert_ok(destination_story.advance_to_game_tick(1439), "响铃截止前应继续保留活动线路。")
	_assert_equal(destination_phone.get_active_event_id(), "call_04_dog_walker", "响铃截止前不能凭空漏接。")
	_assert_ok(destination_story.advance_to_game_tick(1440), "响铃截止 tick 必须能正常推进。")
	_assert_equal(_count_call_records(destination_phone, "call_04_dog_walker"), 1, "恢复后响铃只应生成一条真实漏接记录。")
	_assert_ok(destination_story.advance_to_game_tick(3600), "恢复后必须仍能进入 02:00 收束。")
	_assert_true(destination_story.is_ending_forced(), "02:00 后 StoryEngine 必须处于收束状态。")
	var ending_snapshot: Dictionary = destination_story.create_snapshot()
	_assert_true(bool(ending_snapshot["is_ending_forced"]), "结尾快照必须显式记录收束状态。")
	_assert_equal(int(ending_snapshot["current_game_tick"]), 3600, "结尾快照必须固定在 02:00 tick。")
	_assert_ok(destination_story.validate_snapshot(ending_snapshot, {
		"phone_system": destination_phone,
		"call_record_event_ids": _call_record_ids(destination_phone),
		"current_game_tick": 3600,
	}), "02:00 结尾快照必须符合严格剧情合同。")


func _prepare_0123_ringing_state(story: StoryEngine, phone: PhoneSystem) -> void:
	_assert_ok(story.advance_to_game_tick(60), "01:01 应触发沃伦来电。")
	_assert_true(phone.answer_call(60), "沃伦来电应能接听。")
	_assert_true(phone.enter_dialogue_choice(), "沃伦来电应能进入对话选择。")
	_assert_ok(story.begin_active_call_dialogue(), "沃伦对话应能开始。")
	_assert_ok(story.select_dialogue_option("opt_warren_song"), "沃伦第一轮应能选择。")
	_assert_ok(story.select_dialogue_option("opt_warren_follow_report"), "沃伦追问应能完成对话。")
	_assert_true(phone.exit_dialogue_choice(), "沃伦终止台词后应返回接通状态。")
	_assert_true(phone.finish_call(60), "沃伦来电应结束并写入真实记录。")
	_assert_ok(story.advance_to_game_tick(480), "01:08 应触发错号来电。")
	_assert_true(phone.answer_call(480), "错号来电应能接听。")
	_assert_true(phone.finish_call(480), "错号来电应结束并写入真实记录。")
	_assert_ok(story.advance_to_game_tick(720), "01:12 应解锁警方短信。")
	_assert_ok(story.mark_computer_entry_read("news", "news_north_bridge_closure"), "应能阅读基础新闻。")
	_assert_ok(story.mark_computer_entry_read("messages", "message_01_miller"), "应能阅读警方短信并确认冲突事实。")
	_assert_ok(story.mark_computer_entry_read("call_log", "call_01_warren"), "应能阅读真实沃伦来电摘要。")
	var bridge_after_warren: Dictionary = _find_broadcast_task(story.get_broadcast_tasks(), "task_broadcast_bridge_closure")
	_assert_true(not bool(bridge_after_warren.get("prerequisites_met", true)), "01:12 时只完成沃伦，北桥任务不得绕过 A+B 最低对话门槛。")
	_assert_ok(story.advance_to_game_tick(1020), "01:17 应触发玛莎来电。")
	_assert_true(phone.answer_call(1020), "玛莎来电应能接听。")
	_assert_true(phone.enter_dialogue_choice(), "玛莎来电应能进入对话选择。")
	_assert_ok(story.begin_active_call_dialogue(), "玛莎对话应能开始。")
	_assert_ok(story.select_dialogue_option("opt_martha_vehicle"), "玛莎车辆追问应能选择。")
	_assert_ok(story.select_dialogue_option("opt_martha_follow_request"), "玛莎征集请求应能完成对话。")
	_assert_true(phone.exit_dialogue_choice(), "玛莎终止台词后应返回接通状态。")
	_assert_true(phone.finish_call(1020), "玛莎来电应结束并写入真实记录。")
	var wagon_information_ids: Array[String] = ["info_wagon_martha_route"]
	_assert_ok(story.send_broadcast_task("task_broadcast_wagon_witness_request", wagon_information_ids), "应能发送会设置条件的寻车发布任务。")
	_assert_ok(story.advance_to_game_tick(1380), "01:23 应触发条件来电并进入响铃。")


func _test_atomic_rejections(story: StoryEngine, phone: PhoneSystem, context: Dictionary) -> void:
	var baseline: Dictionary = story.create_snapshot()
	var corrupt_statement: Dictionary = baseline.duplicate(true)
	corrupt_statement["revealed_statement_ids"] = ["statement_not_in_content"]
	_assert_true(not bool(story.restore_snapshot(corrupt_statement, context).get("ok", false)), "未知陈述 ID 必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "未知陈述 ID 恢复失败后必须原子保留状态。")

	var corrupt_fact: Dictionary = baseline.duplicate(true)
	corrupt_fact["confirmed_fact_ids"] = ["fact_bridge_accident_before_shift"]
	_assert_true(not bool(story.restore_snapshot(corrupt_fact, context).get("ok", false)), "不满足事实规则的集合必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "事实规则失败后必须原子保留状态。")

	var corrupt_broadcast: Dictionary = baseline.duplicate(true)
	var broadcast_snapshot: Dictionary = corrupt_broadcast["broadcast"] as Dictionary
	var broadcast_records: Array = broadcast_snapshot["player_records"] as Array
	if not broadcast_records.is_empty():
		(broadcast_records[0] as Dictionary)["body"] = "被篡改的播放器记录"
	_assert_true(not bool(story.restore_snapshot(corrupt_broadcast, context).get("ok", false)), "广播记录与稿件冲突必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "广播记录冲突失败后必须原子保留状态。")

	var corrupt_computer: Dictionary = baseline.duplicate(true)
	var computer_snapshot: Dictionary = corrupt_computer["computer"] as Dictionary
	var read_state: Dictionary = computer_snapshot["read_source_ids"] as Dictionary
	(read_state["news"] as Array).append("news_hockey_third_period")
	_assert_true(not bool(story.restore_snapshot(corrupt_computer, context).get("ok", false)), "电脑已读未解锁来源必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "电脑已读状态失败后必须原子保留状态。")

	var extra_computer_field: Dictionary = baseline.duplicate(true)
	(extra_computer_field["computer"] as Dictionary)["unexpected_field"] = true
	_assert_true(not bool(story.restore_snapshot(extra_computer_field, context).get("ok", false)), "电脑快照未知顶层字段必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "电脑未知字段失败后必须原子保留状态。")

	var extra_broadcast_field: Dictionary = baseline.duplicate(true)
	(extra_broadcast_field["broadcast"] as Dictionary)["unexpected_field"] = true
	_assert_true(not bool(story.restore_snapshot(extra_broadcast_field, context).get("ok", false)), "广播快照未知顶层字段必须拒绝恢复。")
	_assert_equal(story.create_snapshot(), baseline, "广播未知字段失败后必须原子保留状态。")
	_assert_equal(phone.get_active_event_id(), "call_04_dog_walker", "失败恢复不得影响原有响铃线路。")


func _test_phone_forced_end_mismatch(phone_snapshot: Dictionary) -> void:
	# 01:23 的电话不能伪装成已经被 02:00 强制结束。PhoneSystem 在底层先拒绝，
	# StoryEngine 仍会在已恢复对象上交叉核对 forced_end 与 ending_forced，形成双层边界。
	var forced_phone_snapshot: Dictionary = phone_snapshot.duplicate(true)
	forced_phone_snapshot["state"] = "IDLE"
	forced_phone_snapshot["forced_end"] = true
	forced_phone_snapshot["active_call"] = null
	var isolated_phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	# 该错误不依赖特定内容事件；只需要有效 event 映射让 PhoneSystem 进入其严格合同。
	var probe_story: StoryEngine = STORY_ENGINE_SCRIPT.new()
	_assert_ok(probe_story.configure_test_night_story(_load_story()), "强制结束损坏夹具必须能配置当前内容。")
	var event_by_id: Dictionary = probe_story.get_scheduler().get_configured_events_by_id()
	var mismatch_result: Dictionary = isolated_phone.restore_snapshot(forced_phone_snapshot, {"current_game_tick": 1380, "event_by_id": event_by_id})
	_assert_true(not bool(mismatch_result.get("ok", false)), "02:00 前的 forced_end 电话快照必须拒绝恢复。")
	_assert_equal(String(mismatch_result.get("error_code", "")), "forced_end_before_ending", "提前强制结束必须返回稳定错误码。")


func _make_runtime(content: Dictionary, bind_phone_before_configure: bool = true) -> Dictionary:
	var story: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	if bind_phone_before_configure:
		_assert_ok(story.set_phone_system(phone), "新夜班应能先绑定电话。")
	_assert_ok(story.configure_test_night_story(content), "新夜班应能配置已验证内容。")
	return {"story": story, "phone": phone}


func _find_broadcast_task(tasks: Array[Dictionary], task_id: String) -> Dictionary:
	for task: Dictionary in tasks:
		if String(task.get("id", "")) == task_id:
			return task
	return {}


func _call_record_ids(phone: PhoneSystem) -> Array[String]:
	var ids: Array[String] = []
	for record: Dictionary in phone.get_call_records():
		ids.append(String(record["event_id"]))
	return ids


func _count_call_records(phone: PhoneSystem, event_id: String) -> int:
	var count: int = 0
	for record: Dictionary in phone.get_call_records():
		if String(record["event_id"]) == event_id:
			count += 1
	return count


func _is_call_record_read(story: StoryEngine, event_id: String) -> bool:
	for entry: Dictionary in story.get_computer_entries("call_log"):
		if String(entry["event_id"]) == event_id:
			return bool(entry["read"])
	return false


func _json_round_trip(snapshot: Dictionary, label: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(JSON.stringify(snapshot))
	_assert_true(parsed is Dictionary, "%s必须可 JSON 序列化并解析回对象。" % label)
	if not parsed is Dictionary:
		return {}
	return parsed as Dictionary


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][StoryDomainSnapshots] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])
