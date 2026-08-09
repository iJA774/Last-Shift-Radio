extends SceneTree

## 第七阶段端到端存读档验证。
## 覆盖响铃状态、已读/陈述/事实/广播、三槽 JSON 拒绝、替换失败保旧档、
## Connected/DialogueChoice 禁存，以及存档界面和 02:00 均不暂停/不滞留。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const SAVE_DIRECTORY: String = "user://phase7_smoke_slots"

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	_cleanup_test_slots()
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(game_clock != null, "测试运行时必须存在 GameClock 自动加载节点。")
	if game_clock == null:
		_finish()
		return
	var app: Control = await _create_and_start_app()
	if app == null:
		_finish()
		return
	var save_manager: SaveManager = app.get("_save_manager") as SaveManager
	_assert_true(save_manager != null, "Main 必须创建 SaveManager。")
	if save_manager == null:
		_finish()
		return
	_assert_true(bool(save_manager.set_save_directory(SAVE_DIRECTORY).get("ok", false)), "测试必须能注入 user:// 内的隔离目录。")
	var phone: RefCounted = app.get("_phone_system") as RefCounted
	var story: RefCounted = app.get("_story_engine") as RefCounted
	var screen: GameScreen = app.get("_game_screen") as GameScreen
	_assert_true(phone != null and story != null and screen != null, "新班次必须具备完整运行时。")
	if phone == null or story == null or screen == null:
		_finish()
		return

	# 01:01 第一通电话：Connected 与 DialogueChoice 均必须被 SaveManager 拒绝。
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 60)), "必须推进至第一通电话响铃。")
	_assert_equal(String(phone.call(&"get_state_name")), "RINGING", "01:01 必须真实响铃。")
	_assert_true(bool(phone.call(&"answer_call", int(game_clock.call(&"get_current_game_tick")))), "必须接通第一通电话。")
	_assert_save_rejected(save_manager, app, "Connected 时 SaveManager 必须拒绝写档。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "必须进入对话选择状态。")
	_assert_save_rejected(save_manager, app, "DialogueChoice 时 SaveManager 必须拒绝写档。")
	_assert_true(bool(story.call(&"begin_active_call_dialogue").get("ok", false)), "必须开始预制对话。")
	_assert_true(bool(story.call(&"select_dialogue_option", "opt_warren_song").get("ok", false)), "第一轮应能选择沃伦对话。")
	_assert_true(bool(story.call(&"select_dialogue_option", "opt_warren_follow_report").get("ok", false)), "第二轮应能追问沃伦。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "终止对白后必须退出对话选择。")
	_assert_true(bool(phone.call(&"finish_call", int(game_clock.call(&"get_current_game_tick")))), "第一通电话必须正常结束。")
	_assert_true(bool(story.call(&"send_player_broadcast", "broadcast_bridge_tanker_fire").get("ok", false)), "第一条广播必须由真实完成来电解锁。")

	# 01:17 玛莎来电，追问得到来源陈述，并发送带 condition 的广播，以确保 01:23 触发第四通。
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 960)), "必须推进至玛莎来电窗口。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_03_martha", "01:17 必须是玛莎来电。")
	_assert_true(bool(phone.call(&"answer_call", int(game_clock.call(&"get_current_game_tick")))), "必须接通玛莎。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "玛莎电话必须进入选择。")
	_assert_true(bool(story.call(&"begin_active_call_dialogue").get("ok", false)), "必须开始玛莎对话。")
	_assert_true(bool(story.call(&"select_dialogue_option", "opt_martha_vehicle").get("ok", false)), "追问车辆应揭示来源陈述。")
	_assert_true(bool(story.call(&"select_dialogue_option", "opt_martha_follow_request").get("ok", false)), "玛莎第二轮必须终止。")
	_assert_true(bool(phone.call(&"exit_dialogue_choice")), "玛莎终止对白后必须恢复接通。")
	_assert_true(bool(phone.call(&"finish_call", int(game_clock.call(&"get_current_game_tick")))), "玛莎通话必须结束。")
	_assert_true(bool(story.call(&"send_player_broadcast", "broadcast_wagon_witness_request").get("ok", false)), "征集目击广播必须成功发送。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 360)), "必须推进至 01:23。")
	_assert_equal(String(phone.call(&"get_state_name")), "RINGING", "01:23 条件来电必须正在响铃。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_04_dog_walker", "01:23 必须保存正在响铃的河边遛狗者来电。")

	# 已读来源与展示位置都是独立持久状态。
	_assert_true(bool(story.call(&"mark_computer_entry_read", "checklist", "checklist_north_bridge_closure").get("ok", false)), "必须能阅读清单来源。")
	_assert_true(bool(story.call(&"mark_computer_entry_read", "news", "news_north_bridge_closure").get("ok", false)), "必须能阅读新闻来源。")
	_assert_true(bool(screen.show_view(GameScreen.VIEW_COMPUTER).get("ok", false)), "必须能切换至电脑视图。")
	var computer: Control = screen.get_node(NodePath("ViewHost/ComputerCloseup")) as Control
	_assert_true(computer != null and bool(computer.call(&"select_category", "news").get("ok", false)), "保存前必须显示新闻页签。")

	var save_result: Dictionary = save_manager.save_slot("slot_1", app.get("_content_validation_result") as Dictionary, game_clock, story, phone, screen)
	_assert_true(bool(save_result.get("ok", false)), "RINGING 状态必须能够成功写入槽位。")
	var saved_document: Dictionary = save_result.get("document", {}) as Dictionary
	var saved_tick: int = int((saved_document["game_clock_state"] as Dictionary)["current_game_tick"])
	_assert_true(saved_tick >= 1_380 and saved_tick < 1_440, "保存必须落在 01:23 的响铃窗口。")
	_assert_equal(String((saved_document["phone_state"] as Dictionary)["state"]), "RINGING", "电话快照必须保存响铃状态。")
	_assert_equal(String(((saved_document["phone_state"] as Dictionary)["active_call"] as Dictionary)["event_id"]), "call_04_dog_walker", "电话快照必须保存活动来电 ID。")

	# 打开保存覆盖层时，GameClock 继续推进；覆盖层不会暂停剧情。
	screen.get_node(NodePath("SaveButton")).emit_signal(&"pressed")
	await process_frame
	_assert_true(screen.is_save_panel_open(), "点击存档入口必须显示覆盖式三槽页。")
	var tick_before_overlay_advance: int = int(game_clock.call(&"get_current_game_tick"))
	_assert_true(tick_before_overlay_advance >= saved_tick, "保存覆盖层打开期间时钟不得倒退。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 1)), "存档覆盖层打开时仍必须可推进故事时间。")
	_assert_equal(int(game_clock.call(&"get_current_game_tick")), tick_before_overlay_advance + 1, "存档覆盖层不得暂停游戏时间。")
	screen.get_node(NodePath("SaveButton")).emit_signal(&"pressed")
	await process_frame
	_assert_true(not screen.is_save_panel_open(), "再次点击存档入口必须关闭覆盖层。")

	# 临时替换失败必须恢复旧档，而非覆盖已有的完整槽位。
	save_manager.set_replace_failure_for_verification(true)
	var replace_failure: Dictionary = save_manager.save_slot("slot_1", app.get("_content_validation_result") as Dictionary, game_clock, story, phone, screen)
	save_manager.set_replace_failure_for_verification(false)
	_assert_true(not bool(replace_failure.get("ok", false)) and String(replace_failure.get("error_code", "")) == "replace_failed", "替换失败注入必须报告失败。")
	var preserved_result: Dictionary = save_manager.load_slot("slot_1", "test_night_story", 1)
	_assert_true(bool(preserved_result.get("ok", false)), "替换失败后旧档仍必须可读。")
	if bool(preserved_result.get("ok", false)):
		_assert_equal(int(((preserved_result["document"] as Dictionary)["game_clock_state"] as Dictionary)["current_game_tick"]), saved_tick, "替换失败不得破坏旧档时刻。")

	# 单独损坏 JSON 必须停留在读取侧并明确拒绝。
	var damaged_path: String = "%s/slot_2.json" % SAVE_DIRECTORY
	var damaged_file: FileAccess = FileAccess.open(damaged_path, FileAccess.WRITE)
	_assert_true(damaged_file != null, "测试必须能在 user:// 隔离槽位写入损坏 JSON。")
	if damaged_file != null:
		damaged_file.store_string("{not valid json")
		damaged_file.close()
	var damaged_result: Dictionary = save_manager.load_slot("slot_2", "test_night_story", 1)
	_assert_true(not bool(damaged_result.get("ok", false)) and String(damaged_result.get("error_code", "")) == "invalid_json", "损坏 JSON 必须被严格拒绝。")
	var unknown_field_document: Dictionary = saved_document.duplicate(true)
	unknown_field_document["future_extension"] = true
	var unknown_field_result: Dictionary = save_manager.validate_document(unknown_field_document, "test_night_story", 1)
	_assert_true(not bool(unknown_field_result.get("ok", false)) and String(unknown_field_result.get("error_code", "")) == "unknown_top_level_field", "未知顶层字段必须被严格拒绝。")
	var wrong_version_document: Dictionary = saved_document.duplicate(true)
	wrong_version_document["save_format_version"] = 2
	var wrong_version_result: Dictionary = save_manager.validate_document(wrong_version_document, "test_night_story", 1)
	_assert_true(not bool(wrong_version_result.get("ok", false)) and String(wrong_version_result.get("error_code", "")) == "unsupported_save_format_version", "错误存档版本必须被严格拒绝。")
	var missing_field_document: Dictionary = saved_document.duplicate(true)
	missing_field_document.erase("phone_state")
	var missing_field_result: Dictionary = save_manager.validate_document(missing_field_document, "test_night_story", 1)
	_assert_true(not bool(missing_field_result.get("ok", false)) and String(missing_field_result.get("error_code", "")) == "missing_field", "缺少必填字段的存档必须被严格拒绝。")
	var invalid_date_document: Dictionary = saved_document.duplicate(true)
	invalid_date_document["saved_at_utc"] = "2026-02-31T01:02:03Z"
	var invalid_date_result: Dictionary = save_manager.validate_document(invalid_date_document, "test_night_story", 1)
	_assert_true(not bool(invalid_date_result.get("ok", false)) and String(invalid_date_result.get("error_code", "")) == "invalid_saved_at_utc", "不存在的 UTC 日期必须被严格拒绝。")

	# 完全销毁旧运行时后，从主菜单读取同一槽位；恢复必须返回原始 01:23 状态。
	app.call(&"_show_main_menu")
	_assert_true(not bool(game_clock.call(&"is_running")), "彻底销毁运行时后 GameClock 不得脱离剧情独自运行。")
	root.remove_child(app)
	app.queue_free()
	await process_frame
	var loaded_app: Control = MAIN_SCENE.instantiate() as Control
	root.add_child(loaded_app)
	await process_frame
	var loaded_manager: SaveManager = loaded_app.get("_save_manager") as SaveManager
	_assert_true(loaded_manager != null and bool(loaded_manager.set_save_directory(SAVE_DIRECTORY).get("ok", false)), "新 Main 必须连接同一 user:// 测试目录。")
	loaded_app.call(&"request_load_game")
	await process_frame
	_assert_equal(String(loaded_app.call(&"get_application_state_name")), "LOAD_SLOTS", "主菜单读取必须先进入三槽页。")
	loaded_app.call(&"_on_load_slot_requested", "slot_1")
	await process_frame
	_assert_equal(String(loaded_app.call(&"get_application_state_name")), "SHIFT", "严格校验成功后必须创建并恢复新运行时。")
	var restored_phone: RefCounted = loaded_app.get("_phone_system") as RefCounted
	var restored_story: RefCounted = loaded_app.get("_story_engine") as RefCounted
	var restored_screen: GameScreen = loaded_app.get("_game_screen") as GameScreen
	_assert_true(restored_phone != null and restored_story != null and restored_screen != null, "读取后必须获得全新的完整运行时。")
	_assert_equal(int(game_clock.call(&"get_current_game_tick")), saved_tick, "读取后时钟必须精确恢复到保存时刻。")
	_assert_equal(String(restored_phone.call(&"get_state_name")), "RINGING", "读取后电话必须继续原来的响铃状态。")
	_assert_equal(String(restored_phone.call(&"get_active_event_id")), "call_04_dog_walker", "读取后不得重新触发或替换活动来电。")
	_assert_equal(restored_screen.get_current_view_id(), GameScreen.VIEW_COMPUTER, "读取后必须回到保存时的固定视图。")
	var restored_computer: Control = restored_screen.get_node(NodePath("ViewHost/ComputerCloseup")) as Control
	_assert_equal(String(restored_computer.call(&"get_active_category")), "news", "读取后必须回到保存时的电脑页签。")
	_assert_true(not (restored_story.call(&"get_revealed_statements") as Array).is_empty(), "读取后必须保留已取得的来源陈述。")
	_assert_true(not (restored_story.call(&"get_confirmed_facts") as Array).is_empty(), "读取后必须保留已确认事实。")
	_assert_equal((restored_story.call(&"get_player_broadcast_records") as Array).size(), 2, "读取后不得重复或丢失玩家广播记录。")

	# 读取后的保存覆盖层也不能挡住 02:00；收束会立即关闭它且不重复电话/广播/事实。
	restored_screen.get_node(NodePath("SaveButton")).emit_signal(&"pressed")
	await process_frame
	_assert_true(restored_screen.is_save_panel_open(), "恢复后必须仍能打开保存覆盖层。")
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", int(game_clock.call(&"get_remaining_game_ticks")))), "恢复后必须可继续推进至 02:00。")
	await process_frame
	_assert_true(not restored_screen.is_save_panel_open(), "02:00 必须立即关闭存档覆盖层。")
	_assert_true(bool(restored_story.call(&"is_ending_forced")), "恢复后 02:00 必须正常强制收束。")
	_assert_equal(_count_event_records(restored_phone.call(&"get_call_records") as Array, "call_04_dog_walker"), 1, "读取后不得重复来电记录或凭空漏接。")
	_assert_equal((restored_story.call(&"get_player_broadcast_records") as Array).size(), 2, "推进至 02:00 不得重复玩家广播。")
	_assert_unique_ids(restored_story.call(&"get_confirmed_facts") as Array, "事实确认不得重复。")

	root.remove_child(loaded_app)
	loaded_app.queue_free()
	_cleanup_test_slots()
	_finish()


func _create_and_start_app() -> Control:
	var app: Control = MAIN_SCENE.instantiate() as Control
	root.add_child(app)
	await process_frame
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"confirm_content_notice")
	await process_frame
	if String(app.call(&"get_application_state_name")) != "SHIFT":
		_assert_true(false, "测试班次必须成功开始。")
		return null
	return app


func _assert_save_rejected(save_manager: SaveManager, app: Control, message: String) -> void:
	var result: Dictionary = save_manager.save_slot(
		"slot_1",
		app.get("_content_validation_result") as Dictionary,
		root.get_node(NodePath("GameClock")) as Node,
		app.get("_story_engine") as RefCounted,
		app.get("_phone_system") as RefCounted,
		app.get("_game_screen") as GameScreen
	)
	_assert_true(not bool(result.get("ok", false)) and String(result.get("error_code", "")) == "save_blocked", message)


func _count_event_records(records: Array, event_id: String) -> int:
	var count: int = 0
	for raw_record: Variant in records:
		if raw_record is Dictionary and String((raw_record as Dictionary).get("event_id", "")) == event_id:
			count += 1
	return count


func _assert_unique_ids(entries: Array, message: String) -> void:
	var seen: Dictionary = {}
	for entry: Variant in entries:
		if not entry is Dictionary:
			_assert_true(false, "%s：返回了非对象。" % message)
			return
		var entry_id: String = String((entry as Dictionary).get("id", ""))
		if entry_id.is_empty() or seen.has(entry_id):
			_assert_true(false, "%s：发现重复或空 ID。" % message)
			return
		seen[entry_id] = true


func _cleanup_test_slots() -> void:
	for suffix: String in ["slot_1.json", "slot_1.tmp", "slot_1.bak", "slot_2.json", "slot_3.json"]:
		var path: String = "%s/%s" % [SAVE_DIRECTORY, suffix]
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _finish() -> void:
	if _has_failed:
		print("[测试][SaveLoadCycle] 失败。")
		quit(1)
		return
	print("[测试][SaveLoadCycle] 通过：响铃往返、信息状态、三槽拒绝、替换保护与 02:00 收束均符合第七阶段契约。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][SaveLoadCycle] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
