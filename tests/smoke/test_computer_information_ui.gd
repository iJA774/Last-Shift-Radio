extends SceneTree

## 第六阶段电脑信息终端集成烟测。
##
## 使用真实 StoryEngine、ComputerSystem 与 PhoneSystem 验证：五页签的未读文字、
## 打开条目才经 GameScreen 标记已读、真实来电记录不含逐字稿，以及 02:00 从任意
## 信息页立即锁至播出记录。此脚本不做截图或图形验收。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

const INFORMATION_CATEGORIES: Array[String] = ["checklist", "news", "messages", "call_log"]
const PAGE_CATEGORIES: Array[String] = ["checklist", "news", "messages", "call_log", "broadcast"]

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var story_content: Dictionary = _load_validated_story()
	if story_content.is_empty():
		_finish()
		return
	var clock: Node = GAME_CLOCK_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var story_engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	root.add_child(clock)
	root.add_child(screen)
	await process_frame

	_assert_ok(story_engine.call(&"set_phone_system", phone), "StoryEngine 必须绑定 PhoneSystem。")
	_assert_ok(story_engine.call(&"configure_test_night_story", story_content), "StoryEngine 必须配置已校验夜班内容。")
	_assert_ok(screen.bind_runtime(story_engine, phone, clock), "GameScreen 必须绑定真实运行时。")

	var computer_closeup: Control = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup")) as Control
	var information_view: Control = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup/TerminalSurface/InformationView")) as Control
	_assert_true(computer_closeup != null and information_view != null, "GameScreen 必须拥有独立电脑信息终端。")
	if computer_closeup == null or information_view == null:
		_cleanup(clock, story_engine, screen)
		_finish()
		return

	_test_closeup_page_model(story_engine, computer_closeup)
	_test_tabs_and_initial_unread(information_view)
	_test_open_routes_read_intent(story_engine, computer_closeup, information_view)
	_test_call_log_remains_phone_authoritative(phone, computer_closeup, information_view)
	_test_new_content_does_not_change_active_page(story_engine, information_view)
	_test_ending_forces_broadcast_page(story_engine, phone, screen, information_view)

	_cleanup(clock, story_engine, screen)
	_finish()


func _test_tabs_and_initial_unread(information_view: Control) -> void:
	var snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
	_assert_equal(String(snapshot.get("active_category", "")), "checklist", "电脑默认页必须是值班清单。")
	var unread: Dictionary = snapshot.get("unread_by_category", {}) as Dictionary
	_assert_true(int(unread.get("checklist", 0)) >= 1, "初始值班清单必须有可见未读条目。")
	_assert_true(int(unread.get("news", 0)) >= 1, "初始地方新闻必须有可见未读条目。")
	_assert_true(int(unread.get("messages", 0)) >= 1, "初始短信必须有可见未读条目。")
	for category: String in INFORMATION_CATEGORIES:
		var tab_name: String = "%sTab" % category.capitalize()
		var tab: Button = information_view.find_child(tab_name, true, false) as Button
		var tab_label: Label = information_view.find_child("%sLabel" % tab_name, true, false) as Label
		_assert_true(tab != null and tab_label != null and tab_label.text.contains("未读"), "%s 页签必须用文字显示未读数量。" % category)
	var first_entry_ids: Dictionary[String, String] = {}
	for category: String in ["checklist", "news", "messages"]:
		_assert_ok(information_view.call(&"select_category", category), "%s 必须能显示独立内容。" % category)
		var information_snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
		var visible_ids: PackedStringArray = information_snapshot.get("visible_entry_ids", PackedStringArray()) as PackedStringArray
		_assert_true(not visible_ids.is_empty(), "%s 页必须显示已解锁的独立来源。" % category)
		if not visible_ids.is_empty():
			first_entry_ids[category] = visible_ids[0]
	_assert_true(
		first_entry_ids.get("checklist", "") != first_entry_ids.get("news", "")
			and first_entry_ids.get("news", "") != first_entry_ids.get("messages", ""),
		"清单、新闻与短信页不能复用同一内容条目。"
	)
	for category: String in PAGE_CATEGORIES:
		_assert_ok(information_view.call(&"select_category", category), "必须能切换到 %s 页签。" % category)
		var category_snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
		_assert_equal(String(category_snapshot.get("active_category", "")), category, "切换后必须保留当前电脑页签。")
	_assert_ok(information_view.call(&"select_category", "news"), "阅读测试前必须能停留在新闻页。")


func _test_closeup_page_model(story_engine: RefCounted, computer_closeup: Control) -> void:
	_assert_true(computer_closeup.has_method(&"select_category"), "电脑近景必须公开 select_category()。")
	_assert_true(computer_closeup.has_method(&"get_active_category"), "电脑近景必须公开 get_active_category()。")
	_assert_equal(String(computer_closeup.call(&"get_active_category")), "checklist", "电脑近景必须默认停在清单页。")
	var before_entries: Array = story_engine.call(&"get_computer_entries", "news") as Array
	_assert_true(not before_entries.is_empty() and not bool((before_entries[0] as Dictionary).get("read", true)), "切页前新闻来源必须保持未读。")
	_assert_ok(computer_closeup.call(&"select_category", "news"), "电脑近景必须接受稳定新闻页 ID。")
	_assert_equal(String(computer_closeup.call(&"get_active_category")), "news", "电脑近景切页后必须能查询当前页。")
	_assert_ok(computer_closeup.call(&"select_category", "checklist"), "电脑近景必须能切回清单页。")
	var after_entries: Array = story_engine.call(&"get_computer_entries", "news") as Array
	_assert_true(not bool((after_entries[0] as Dictionary).get("read", true)), "仅切换电脑页面不得自动把新闻标为已读。")
	var invalid_result: Dictionary = computer_closeup.call(&"select_category", "social_feed") as Dictionary
	_assert_true(not bool(invalid_result.get("ok", true)), "电脑近景必须拒绝未知页签 ID。")
	_assert_equal(String(computer_closeup.call(&"get_active_category")), "checklist", "拒绝未知页签后必须保留原页面。")


func _test_open_routes_read_intent(story_engine: RefCounted, computer_closeup: Control, information_view: Control) -> void:
	var before_entries: Array = story_engine.call(&"get_computer_entries", "news") as Array
	_assert_true(not before_entries.is_empty(), "新闻页必须存在初始解锁来源。")
	if before_entries.is_empty():
		return
	var news_id: String = String((before_entries[0] as Dictionary).get("id", ""))
	_assert_equal(news_id, "news_north_bridge_closure", "基础新闻必须使用北桥封闭的稳定 ID。")
	_assert_true(not bool((before_entries[0] as Dictionary).get("read", true)), "打开前新闻不得自动标为已读。")
	var unread_before: int = int(story_engine.call(&"get_computer_unread_count", "news"))

	# 只从电脑近景信号提交意图，验证 UI 本身没有直接写 StoryEngine。
	computer_closeup.emit_signal(&"computer_entry_open_requested", "news", news_id)
	await process_frame
	var after_entries: Array = story_engine.call(&"get_computer_entries", "news") as Array
	_assert_true(bool((after_entries[0] as Dictionary).get("read", false)), "打开新闻后必须由 GameScreen 转交 StoryEngine 标记已读。")
	_assert_equal(
		int(story_engine.call(&"get_computer_unread_count", "news")),
		unread_before - 1,
		"只打开一条新闻时，新闻未读数必须恰好减少一。"
	)
	var snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
	_assert_equal(String(snapshot.get("active_category", "")), "news", "阅读后必须停留在当前新闻页。")
	_assert_true((snapshot.get("visible_entry_ids", PackedStringArray()) as PackedStringArray).has(news_id), "当前新闻页必须仍显示被打开的条目。")


func _test_call_log_remains_phone_authoritative(phone: RefCounted, computer_closeup: Control, information_view: Control) -> void:
	var call_event: Dictionary = {
		"id": "call_ui_record",
		"caller_display_name": "UI 验收来电者",
		"caller_number": "555-0198",
	}
	_assert_true(bool(phone.call(&"begin_incoming_call", call_event, 20, 4)), "PhoneSystem 必须能够创建真实测试来电。")
	_assert_true(bool(phone.call(&"answer_call", 21)), "真实测试来电必须能接听。")
	_assert_true(bool(phone.call(&"finish_call", 22)), "真实测试来电必须能正常结束。")
	await process_frame
	_assert_ok(information_view.call(&"select_category", "call_log"), "必须能打开来电记录页。")
	var snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
	_assert_true((snapshot.get("visible_entry_ids", PackedStringArray()) as PackedStringArray).has("call_ui_record"), "来电页只能在 PhoneSystem 生成记录后显示该来源。")
	_assert_equal(int((snapshot.get("unread_by_category", {}) as Dictionary).get("call_log", -1)), 1, "新生成来电记录必须独立计为未读。")
	computer_closeup.emit_signal(&"computer_entry_open_requested", "call_log", "call_ui_record")
	await process_frame
	var records: Array = phone.call(&"get_call_records") as Array
	_assert_equal(records.size(), 1, "阅读来电记录不得制造或重复 PhoneSystem 记录。")
	_assert_equal(String((records[0] as Dictionary).get("outcome", "")), "answered", "电脑阅读不得改写真实来电结果。")
	_assert_equal(int((information_view.call(&"get_ui_snapshot") as Dictionary).get("unread_by_category", {}).get("call_log", -1)), 0, "打开真实来电记录后才可将其标为已读。")


func _test_new_content_does_not_change_active_page(story_engine: RefCounted, information_view: Control) -> void:
	_assert_ok(information_view.call(&"select_category", "messages"), "新内容测试前必须能切到短信页。")
	var messages_before: int = int(story_engine.call(&"get_computer_unread_count", "messages"))
	_assert_ok(story_engine.call(&"advance_to_game_tick", 720), "StoryEngine 必须能推进到后续短信解锁时间。")
	await process_frame
	var snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
	_assert_equal(String(snapshot.get("active_category", "")), "messages", "收到新内容不得自动切换当前电脑页面。")
	var messages_after: int = int((snapshot.get("unread_by_category", {}) as Dictionary).get("messages", -1))
	_assert_true(messages_after > messages_before, "后续短信解锁后必须只增加未读数量。")


func _test_ending_forces_broadcast_page(
	story_engine: RefCounted,
	phone: RefCounted,
	screen: GameScreen,
	information_view: Control
) -> void:
	_assert_ok(information_view.call(&"select_category", "checklist"), "02:00 测试前必须可停留在非播出页。")
	_assert_ok(screen.show_view(GameScreen.VIEW_PHONE), "02:00 可从电话选择页开始收束测试。")
	var ending_call: Dictionary = {
		"id": "call_ui_ending",
		"caller_display_name": "收束测试来电者",
		"caller_number": "555-0197",
	}
	_assert_true(bool(phone.call(&"begin_incoming_call", ending_call, 721, 20)), "收束测试必须能让电话进入响铃。")
	_assert_true(bool(phone.call(&"answer_call", 722)), "收束测试必须能接听电话。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "收束测试必须能停在电话选择。")
	_assert_equal(String(phone.call(&"get_state_name")), "DIALOGUE_CHOICE", "02:00 前电话必须确实处于选择状态。")
	_assert_ok(story_engine.call(&"force_ending_at_0200", 3_600), "StoryEngine 必须在电话选择中强制收束。")
	var record: Dictionary = story_engine.call(&"get_unauthorized_broadcast_record") as Dictionary
	_assert_true(not record.is_empty(), "StoryEngine 强制收束后必须提供权威未授权播出记录。")
	_assert_ok(screen.show_ending(record), "02:00 必须可从任意信息页立即进入收束。")
	var snapshot: Dictionary = information_view.call(&"get_ui_snapshot") as Dictionary
	_assert_true(bool(phone.call(&"is_forced_ended")), "02:00 在电话选择中也必须强制终止 PhoneSystem。")
	_assert_equal(screen.get_current_view_id(), GameScreen.VIEW_COMPUTER, "02:00 必须立即切到电脑近景。")
	_assert_equal(String(snapshot.get("active_category", "")), "broadcast", "02:00 必须立即切到播出页。")
	_assert_true(bool(snapshot.get("is_ending_locked", false)), "02:00 后电脑信息页必须锁定。")
	var rejected_page: Dictionary = information_view.call(&"select_category", "news") as Dictionary
	_assert_true(not bool(rejected_page.get("ok", true)), "02:00 后不得返回其他信息页。")
	var back_button: Button = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup/BackButton")) as Button
	_assert_true(back_button != null and back_button.disabled, "02:00 后返回工作室按钮必须锁定。")


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var load_value: Variant = loader.call(&"load_json", STORY_PATH)
	_assert_true(load_value is Dictionary, "内容读取器必须返回 Dictionary。")
	if not load_value is Dictionary:
		return {}
	var load_result: Dictionary = load_value as Dictionary
	_assert_ok(load_result, "测试剧情必须可读取。")
	if not bool(load_result.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_value: Variant = validator.call(&"validate_test_night_story", load_result["data"], STORY_PATH)
	_assert_true(validation_value is Dictionary, "内容校验器必须返回 Dictionary。")
	if not validation_value is Dictionary:
		return {}
	var validation: Dictionary = validation_value as Dictionary
	_assert_ok(validation, "测试剧情必须通过严格校验。")
	return validation if bool(validation.get("ok", false)) else {}


func _cleanup(clock: Node, story_engine: RefCounted, screen: GameScreen) -> void:
	if screen != null and is_instance_valid(screen):
		screen.release_runtime()
	if story_engine != null:
		story_engine.call(&"release_runtime")
	if screen != null and is_instance_valid(screen) and screen.get_parent() == root:
		root.remove_child(screen)
		screen.queue_free()
	if is_instance_valid(clock) and clock.get_parent() == root:
		root.remove_child(clock)
		clock.free()


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][ComputerInformationUi] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _finish() -> void:
	if _has_failed:
		print("[测试][ComputerInformationUi] 失败。")
		quit(1)
		return
	print("[测试][ComputerInformationUi] 通过：页签、未读、阅读意图、真实来电记录与 02:00 收束均已连通。")
	quit(0)
