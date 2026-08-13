extends SceneTree

## GameScreen 的剧情意图路由验证。
##
## 只经由电话与电脑近景公开信号提交操作，确认 UI 不会直接写入对话、广播或
## 电话记录；并覆盖终止台词后禁止同一通电话重新开始预制对话。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var story_content: Dictionary = _load_validated_story()
	if story_content.is_empty():
		_finish()
		return
	var clock = GAME_CLOCK_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var story_engine: RefCounted = STORY_ENGINE_SCRIPT.new()
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	root.add_child(clock)
	root.add_child(screen)
	await process_frame

	_assert_ok(story_engine.call(&"set_phone_system", phone), "StoryEngine 必须接受 PhoneSystem。")
	_assert_ok(story_engine.call(&"configure_test_night_story", story_content), "StoryEngine 必须接受已校验测试剧情。")
	_assert_ok(screen.bind_runtime(story_engine, phone, clock), "GameScreen 必须绑定剧情、电话与时钟。")
	_assert_ok(story_engine.call(&"connect_game_clock", clock), "StoryEngine 必须连接测试时钟。")
	clock.start_shift()
	_assert_true(clock.advance_ticks_for_verification(60), "时钟必须推进至沃伦来电窗口。")
	_assert_equal(phone.call(&"get_state_name"), "RINGING", "沃伦来电必须通过 StoryEngine 进入响铃。")

	var phone_closeup: Control = screen.get_node_or_null(NodePath("ViewHost/PhoneCloseup")) as Control
	var computer_closeup: Control = screen.get_node_or_null(NodePath("ViewHost/ComputerCloseup")) as Control
	var studio_overview: Control = screen.get_node_or_null(NodePath("ViewHost/StudioOverview")) as Control
	_assert_true(phone_closeup != null and computer_closeup != null and studio_overview != null, "GameScreen 必须持有电话、电脑与工作室总览。")
	if phone_closeup == null or computer_closeup == null or studio_overview == null:
		_cleanup(clock, story_engine, screen)
		_finish()
		return

	phone_closeup.emit_signal(&"answer_requested")
	_assert_equal(phone.call(&"get_state_name"), "DIALOGUE_CHOICE", "接听后必须由 GameScreen 自动进入首段权威对白的 DialogueChoice。")
	var opening_snapshot: Dictionary = story_engine.call(&"get_active_dialogue_snapshot") as Dictionary
	_assert_equal(String(opening_snapshot.get("node_id", "")), "dlg_warren_open", "开始预制对话必须由 StoryEngine 提供稳定入口。")
	var dialogue_label: Label = phone_closeup.get_node_or_null(NodePath("DialogueScroll/DialogueScrollContent/DialogueHintLabel")) as Label
	_assert_true(dialogue_label != null, "电话近景必须保留对话信息标签。")
	if dialogue_label != null:
		_assert_true(not dialogue_label.text.contains("[ 对话结束 ]"), "未到终止节点时不得显示对话结束标记。")

	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_warren_song")
	if dialogue_label != null:
		_assert_true(not dialogue_label.text.contains("[ 对话结束 ]"), "中间分支节点不得伪造对话结束标记。")
	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_warren_follow_report")
	var terminal_snapshot: Dictionary = story_engine.call(&"get_active_dialogue_snapshot") as Dictionary
	_assert_true(bool(terminal_snapshot.get("is_terminal", false)), "末个对话选项必须显示终止台词。")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "终止台词后 GameScreen 必须恢复为已接通，保留结束通话操作。")
	phone_closeup.emit_signal(&"dialogue_choice_requested")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "同一通电话的终止台词不得重新开始预制对话。")
	if dialogue_label != null:
		var expected_terminal_text: String = "%s：\n%s\n[ 对话结束 ]" % [String(terminal_snapshot.get("speaker", "")), String(terminal_snapshot.get("text", ""))]
		_assert_equal(dialogue_label.text, expected_terminal_text, "终止台词出现时必须在原信息末行追加精确结束标记。")
		_assert_equal(dialogue_label.text.count("[ 对话结束 ]"), 1, "结束标记不得重复追加。")
	# 通话完成必须经公开信号走低信息量短通知，而不是由测试直接伪造面板状态。
	phone_closeup.emit_signal(&"finish_call_requested")
	var system_message_panel: PanelContainer = screen.get_node_or_null(NodePath("SystemMessagePanel")) as PanelContainer
	var system_message: Label = screen.get_node_or_null(NodePath("SystemMessagePanel/SystemMessage")) as Label
	_assert_true(system_message_panel != null and system_message != null, "GameScreen 必须保留唯一的系统提示条。")
	_assert_true(system_message_panel != null and system_message_panel.visible, "结束通话成功后提示条必须立即开始显示。")
	_assert_true(system_message != null and system_message.text == "结束通话成功。", "结束通话必须显示准确的成功提示。")
	var timing: Dictionary = screen.get_transient_notice_timing_snapshot()
	_assert_equal(String(timing.get("mode", "")), "transient", "结束通话成功必须使用短通知模式。")
	_assert_true(float(timing.get("max_lifetime_seconds", 9.0)) <= 2.0, "短通知完整生命周期不得超过两秒。")
	_assert_equal(float(timing.get("alpha", 1.0)), 0.0, "短通知初始必须从完全透明开始渐入。")
	# 新短通知开始后，旧回调即使抵达原定结束时间也不得关掉新内容。
	await create_timer(0.38).timeout
	screen.show_transient_notice("第二条短通知。")
	await create_timer(1.70).timeout
	timing = screen.get_transient_notice_timing_snapshot()
	_assert_equal(String(timing.get("mode", "")), "transient", "旧短通知回调不得关闭新短通知。")
	_assert_true(system_message_panel != null and system_message_panel.visible, "新短通知在自身两秒内必须保持可见。")
	await create_timer(0.35).timeout
	timing = screen.get_transient_notice_timing_snapshot()
	_assert_equal(String(timing.get("mode", "")), "hidden", "短通知完整生命周期结束后必须自动隐藏。")
	_assert_true(system_message_panel != null and not system_message_panel.visible, "短通知渐出完成后不得留下黑色空框。")
	# 常驻错误应取消短通知 Tween，并且其信息不能被旧回调在两秒后隐藏。
	screen.show_transient_notice("将被错误提示替换。")
	await create_timer(0.10).timeout
	screen.show_system_error("需要玩家处理的错误。")
	await create_timer(2.05).timeout
	timing = screen.get_transient_notice_timing_snapshot()
	_assert_equal(String(timing.get("mode", "")), "persistent", "严重错误必须切换为常驻提示模式。")
	_assert_true(system_message_panel != null and system_message_panel.visible, "严重错误不得被短通知旧回调自动隐藏。")
	_assert_true(system_message != null and system_message.text.contains("需要玩家处理的错误。"), "常驻错误必须保留原有可读内容。")

	_assert_true(not computer_closeup.has_signal(&"broadcast_requested"), "电脑不得保留玩家发布任务意图入口。")
	var microphone_panel: Control = studio_overview.get_node_or_null(NodePath("MicrophonePanel")) as Control
	_assert_true(microphone_panel != null and microphone_panel.has_signal(&"broadcast_requested"), "中央麦克风必须提供发布任务意图入口。")
	var warren_only_information: Array[String] = ["info_bridge_tanker_fire"]
	if microphone_panel != null:
		microphone_panel.emit_signal(&"broadcast_requested", "task_broadcast_bridge_closure", warren_only_information)
	_assert_equal((story_engine.call(&"get_player_broadcast_records") as Array).size(), 0, "只完成 A=沃伦时，中央麦克风意图必须由 StoryEngine 因最低对话门槛不足而拒绝。")

	var trucker_target_tick: int = 33 * GameClockService.GAME_TICKS_PER_MINUTE
	var current_tick_before_trucker: int = int(clock.get_current_game_tick())
	_assert_true(current_tick_before_trucker <= trucker_target_tick, "UI 短通知验收不得在触发 B 前越过 01:33。")
	if current_tick_before_trucker < trucker_target_tick:
		_assert_true(clock.advance_ticks_for_verification(trucker_target_tick - current_tick_before_trucker), "时钟必须推进到 01:33 的 B=卡车司机窗口。")
	_assert_equal(String(phone.call(&"get_active_event_id")), "call_06_trucker", "跨过非必要窗口后必须真实触发 B=卡车司机。")
	phone_closeup.emit_signal(&"answer_requested")
	_assert_equal(phone.call(&"get_state_name"), "DIALOGUE_CHOICE", "B 接听后必须进入权威预制对话。")
	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_trucker_closure")
	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_trucker_follow_wait")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "B 终止对白后必须恢复已接通状态。")
	phone_closeup.emit_signal(&"finish_call_requested")
	var selected_bridge_information: Array[String] = ["info_bridge_tanker_fire", "info_bridge_east_queue"]
	if microphone_panel != null:
		microphone_panel.emit_signal(&"broadcast_requested", "task_broadcast_bridge_closure", selected_bridge_information)
	var player_records: Array = story_engine.call(&"get_player_broadcast_records") as Array
	_assert_equal(player_records.size(), 1, "A+B 后中央麦克风双参数任务意图必须只生成一条权威玩家发布记录。")
	if microphone_panel != null:
		microphone_panel.emit_signal(&"broadcast_requested", "task_broadcast_bridge_closure", selected_bridge_information)
	_assert_equal(
		(story_engine.call(&"get_player_broadcast_records") as Array).size(),
		1,
		"重复发布同一任务必须由 StoryEngine 拒绝，不能重复记录。"
	)

	_cleanup(clock, story_engine, screen)
	_finish()


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


func _finish() -> void:
	if _has_failed:
		print("[测试][GameScreenStoryRouting] 失败。")
		quit(1)
		return
	print("[测试][GameScreenStoryRouting] 通过：对话、终止锁定和中央麦克风公告均经 GameScreen 路由。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][GameScreenStoryRouting] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
