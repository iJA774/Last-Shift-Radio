extends SceneTree

## 来电页摘要烟测。
##
## 只接受 StoryEngine 装饰到 call_log 的 revealed_statement_ids，并逐项复核
## get_statement_snapshot().is_revealed 后展示正文。验证不同电话追问分支互不泄露，
## 漏接电话也不会获得隐藏摘要或逐字稿。

const COMPUTER_INFORMATION_VIEW_SCRIPT: GDScript = preload("res://scripts/ui/computer_information_view.gd")
const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

const BRIDGE_SUMMARY: String = "年轻司机声称封桥消息后仍按临时路牌经过北桥。"
const VEHICLE_SUMMARY: String = "年轻司机称一辆旧旅行车从后方超过他，正向城南驶去。"

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var validated_story: Dictionary = _load_validated_story()
	if not validated_story.is_empty():
		await _test_branch_summary(validated_story, "opt_southbound_confirm", BRIDGE_SUMMARY, VEHICLE_SUMMARY)
		await _test_branch_summary(validated_story, "opt_southbound_vehicle", VEHICLE_SUMMARY, BRIDGE_SUMMARY)
		await _test_missed_call_has_no_summary(validated_story)
	_finish()


func _test_branch_summary(
	validated_story: Dictionary,
	option_id: String,
	expected_summary: String,
	hidden_summary: String
) -> void:
	var runtime: Dictionary = _make_southbound_runtime(validated_story)
	var engine: StoryEngine = runtime["engine"] as StoryEngine
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	_assert_ok(engine.advance_to_game_tick(60), "年轻司机来电必须触发。")
	_assert_true(phone.answer_call(60), "年轻司机来电必须能接听。")
	_assert_true(phone.enter_dialogue_choice(), "年轻司机来电必须能进入选择。")
	_assert_ok(engine.begin_active_call_dialogue(), "年轻司机对话必须能开始。")
	_assert_ok(engine.select_dialogue_option(option_id), "分支 %s 必须可提交。" % option_id)
	_assert_true(phone.exit_dialogue_choice(), "取得线索后电话必须能恢复已接通。")
	_assert_true(phone.finish_call(61), "结束通话后必须生成真实来电记录。")

	var call_entry: Dictionary = _get_single_call_entry(engine)
	_assert_equal(String(call_entry.get("event_id", "")), "call_09_southbound", "摘要必须来自真实年轻司机记录。")
	var text: String = await _render_opened_call_log(engine, phone, call_entry)
	_assert_true(text.contains("本通已记录摘要"), "打开有追问的真实来电记录必须显示摘要标题。")
	_assert_true(text.contains(expected_summary), "来电摘要必须只显示本分支实际取得的线索。")
	_assert_true(not text.contains(hidden_summary), "来电摘要不得泄露另一追问分支的线索。")
	_assert_true(text.contains("本记录不包含通话逐字稿。"), "来电摘要必须明确不是逐字稿。")
	_cleanup_runtime(engine)


func _test_missed_call_has_no_summary(validated_story: Dictionary) -> void:
	var runtime: Dictionary = _make_southbound_runtime(validated_story)
	var engine: StoryEngine = runtime["engine"] as StoryEngine
	var phone: PhoneSystem = runtime["phone"] as PhoneSystem
	_assert_ok(engine.advance_to_game_tick(60), "漏接测试必须先触发年轻司机来电。")
	_assert_ok(engine.advance_to_game_tick(120), "响铃超时后必须生成漏接记录。")
	var call_entry: Dictionary = _get_single_call_entry(engine)
	_assert_equal(String(call_entry.get("outcome", "")), "missed", "漏接记录必须保留 PhoneSystem 真实结果。")
	_assert_true((call_entry.get("revealed_statement_ids", []) as Array).is_empty(), "漏接记录不得携带已揭示电话陈述。")
	var text: String = await _render_opened_call_log(engine, phone, call_entry)
	_assert_true(text.contains("未记录可核对线索。"), "漏接来电打开后必须说明没有可核对线索。")
	_assert_true(not text.contains(BRIDGE_SUMMARY) and not text.contains(VEHICLE_SUMMARY), "漏接来电不得显示任何隐藏分支摘要。")
	_assert_true(not text.contains("给你报个路况"), "漏接来电不得显示对话逐字稿。")
	_cleanup_runtime(engine)


func _make_southbound_runtime(validated_story: Dictionary) -> Dictionary:
	var story: Dictionary = validated_story.duplicate(true)
	for raw_event: Variant in story["events"] as Array:
		var event_data: Dictionary = raw_event as Dictionary
		if String(event_data["id"]) == "call_09_southbound":
			event_data["window_start_minute"] = 1
			event_data["window_end_minute"] = 2
		else:
			event_data["window_start_minute"] = 50
			event_data["window_end_minute"] = 59
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(engine.set_phone_system(phone), "StoryEngine 必须绑定 PhoneSystem。")
	_assert_ok(engine.configure_test_night_story(story), "StoryEngine 必须配置聚焦剧情。")
	return {"engine": engine, "phone": phone}


func _get_single_call_entry(engine: StoryEngine) -> Dictionary:
	var entries: Array[Dictionary] = engine.get_computer_entries("call_log")
	_assert_equal(entries.size(), 1, "聚焦剧情必须只有一条真实来电记录。")
	return entries[0] if not entries.is_empty() else {}


func _render_opened_call_log(engine: StoryEngine, phone: PhoneSystem, entry: Dictionary) -> String:
	var view: ComputerInformationView = COMPUTER_INFORMATION_VIEW_SCRIPT.new()
	root.add_child(view)
	await process_frame
	_assert_ok(view.bind_phone_system(phone), "来电摘要 UI 必须绑定 PhoneSystem。")
	_assert_ok(view.bind_story_engine(engine), "来电摘要 UI 必须要求并绑定 StoryEngine 陈述快照接口。")
	_assert_ok(view.show_entry_content("call_log", String(entry.get("id", ""))), "打开真实来电记录必须成功。")
	await process_frame
	var text: String = _collect_label_text(view)
	root.remove_child(view)
	view.queue_free()
	await process_frame
	return text


func _collect_label_text(node: Node) -> String:
	var segments: PackedStringArray = PackedStringArray()
	_collect_label_segments(node, segments)
	return "\n".join(segments)


func _collect_label_segments(node: Node, segments: PackedStringArray) -> void:
	if node is Label:
		var label: Label = node as Label
		if not label.text.strip_edges().is_empty():
			segments.append(label.text)
	for child: Node in node.get_children():
		_collect_label_segments(child, segments)


func _cleanup_runtime(engine: StoryEngine) -> void:
	if engine != null:
		engine.release_runtime()


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_result: Dictionary = loader.call(&"load_json", STORY_PATH) as Dictionary
	_assert_ok(load_result, "测试剧情必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation: Dictionary = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH) as Dictionary
	_assert_ok(validation, "测试剧情必须通过严格校验。")
	return validation if bool(validation.get("ok", false)) else {}


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][ComputerCallLogSummaries] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _finish() -> void:
	if _has_failed:
		print("[测试][ComputerCallLogSummaries] 失败。")
		quit(1)
		return
	print("[测试][ComputerCallLogSummaries] 通过：分支摘要仅显示实际揭示陈述，漏接不显示隐藏线索。")
	quit(0)
