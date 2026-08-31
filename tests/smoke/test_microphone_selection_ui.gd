extends SceneTree

## 中央麦克风的真实点击回归。
## 覆盖 StudioOverview -> GameScreen -> StoryEngine 的寻车单选发送链路，以及
## 含两条信息的单选任务首项初始化、互斥切换和稳定控件布局，防止选择时重建卡片。

const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const MICROPHONE_PANEL_SCRIPT: GDScript = preload("res://scripts/ui/microphone_broadcast_panel.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const AGENT_DIALOGUE_TEST_DRIVER_SCRIPT: GDScript = preload("res://tests/smoke/agent_dialogue_test_driver.gd")
const STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


class FakeStoryEngine extends RefCounted:
	signal broadcast_state_changed()
	var tasks: Array = []

	func get_broadcast_tasks() -> Array:
		return tasks.duplicate(true)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_single_two_item_panel()
	await _test_wagon_single_click_route()
	if _has_failed:
		print("[测试][MicrophoneSelectionUi] 失败。")
		quit(1)
		return
	print("[测试][MicrophoneSelectionUi] 通过：单选初始化、稳定切换与寻车任务真实发送链路成立。")
	quit(0)


func _test_single_two_item_panel() -> void:
	var fake_engine: FakeStoryEngine = FakeStoryEngine.new()
	fake_engine.tasks = [{
		"id": "task_single_two_items",
		"name": "两项单选夹具",
		"selection_mode": "single",
		"available_information_items": [
			{"id": "info_single_one", "source_label": "夹具 A", "body": "第一条信息。"},
			{"id": "info_single_two", "source_label": "夹具 B", "body": "第二条信息。"},
		],
		"is_sent": false,
		"is_publishable": true,
	}]
	var panel: MicrophoneBroadcastPanel = MICROPHONE_PANEL_SCRIPT.new() as MicrophoneBroadcastPanel
	root.add_child(panel)
	await process_frame
	_assert_ok(panel.bind_story_engine(fake_engine), "单选两项夹具必须能绑定面板。")
	await process_frame
	var first: Button = panel.find_child("InformationOption_info_single_one", true, false) as Button
	var second: Button = panel.find_child("InformationOption_info_single_two", true, false) as Button
	_assert_true(first != null and second != null, "单选两项夹具必须构建两个选择按钮。")
	if first != null and second != null:
		_assert_true(first.button_pressed and not second.button_pressed, "单选两项任务初始必须始终存在首个已选项。")
		var first_instance_id: int = first.get_instance_id()
		var second_instance_id: int = second.get_instance_id()
		var first_text: String = first.text
		var second_text: String = second.text
		var first_size: Vector2 = first.size
		var second_size: Vector2 = second.size
		var first_minimum_size: Vector2 = first.custom_minimum_size
		var second_minimum_size: Vector2 = second.custom_minimum_size
		var scroll: ScrollContainer = panel.find_child("TaskScroll", true, false) as ScrollContainer
		# 面板没有为选择切换重建滚动容器；初始滚动位置也必须原样保留。
		var scroll_position: int = scroll.scroll_vertical if scroll != null else 0
		second.button_pressed = true
		await process_frame
		_assert_true(not first.button_pressed and second.button_pressed, "单选两项任务切换后必须保持互斥。")
		_assert_equal(first.get_instance_id(), first_instance_id, "单选切换不得重建第一条信息控件。")
		_assert_equal(second.get_instance_id(), second_instance_id, "单选切换不得重建第二条信息控件。")
		_assert_equal(first.text, first_text, "单选切换不得改写第一条多行正文。")
		_assert_equal(second.text, second_text, "单选切换不得改写第二条多行正文。")
		_assert_equal(first.size, first_size, "单选切换后第一条信息尺寸必须稳定。")
		_assert_equal(second.size, second_size, "单选切换后第二条信息尺寸必须稳定。")
		_assert_equal(first.custom_minimum_size, first_minimum_size, "单选切换后第一条信息最小尺寸必须稳定。")
		_assert_equal(second.custom_minimum_size, second_minimum_size, "单选切换后第二条信息最小尺寸必须稳定。")
		if scroll != null:
			_assert_equal(scroll.scroll_vertical, scroll_position, "单选切换不得改变滚动位置。")
	var requested_id_batches: Array[Array] = []
	panel.broadcast_requested.connect(func(_task_id: String, information_item_ids: Array[String]) -> void:
		requested_id_batches.append(information_item_ids.duplicate())
	)
	var publish_button: Button = panel.find_child("PublishTask_task_single_two_items", true, false) as Button
	_assert_true(publish_button != null, "单选两项夹具必须提供发送按钮。")
	if publish_button != null:
		publish_button.emit_signal(&"pressed")
	_assert_equal(requested_id_batches, [["info_single_two"]], "真实点击单选任务发送按钮必须提交当前选中项。")
	root.remove_child(panel)
	panel.queue_free()


func _test_wagon_single_click_route() -> void:
	var story_content: Dictionary = _load_validated_story()
	if story_content.is_empty():
		return
	var clock: Node = GAME_CLOCK_SCRIPT.new()
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var story_engine: StoryEngine = STORY_ENGINE_SCRIPT.new() as StoryEngine
	var dialogue_driver: RefCounted = AGENT_DIALOGUE_TEST_DRIVER_SCRIPT.new()
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	root.add_child(clock)
	root.add_child(screen)
	await process_frame
	_assert_ok(story_engine.set_phone_system(phone), "寻车任务测试必须绑定 PhoneSystem。")
	_assert_ok(story_engine.configure_test_night_story(story_content), "寻车任务测试必须配置剧情。")
	_assert_ok(screen.bind_runtime(story_engine, phone, clock), "寻车任务测试必须绑定 GameScreen。")
	_assert_ok(story_engine.connect_game_clock(clock), "寻车任务测试必须连接时钟。")
	clock.call(&"start_shift")
	_assert_true(bool(clock.call(&"advance_ticks_for_verification", 1020)), "必须推进至玛莎来电窗口。")
	var overview: StudioOverview = screen.get_node_or_null(NodePath("ViewHost/StudioOverview")) as StudioOverview
	_assert_true(overview != null, "寻车任务测试必须取得工作室总览。")
	# 正式内容已经是 v2；这里只用 committed ActorTurn 准备广播信息，不把旧预制选项
	# 信号重新当作 PhoneCloseup 的 UI 合同。
	_assert_true(bool(phone.call(&"answer_call", 1020)), "玛莎来电必须能接听。")
	_assert_true(bool(phone.call(&"enter_dialogue_choice")), "v2 广播夹具必须进入自由对话线路状态。")
	_assert_ok(dialogue_driver.call(&"commit_active_call", story_engine, "call_03_martha", "martha", ["statement_martha_wagon_route"], "丹尼开的是深色旧旅行车，右后灯接触不好，常从北桥回城南。"), "v2 广播夹具必须通过 committed ActorTurn 揭示寻车信息。")
	# v2 不再存在玛莎预制 option；Statement 已由 committed ActorTurn 揭示。
	# committed ActorTurn 已完成 StoryEngine interaction。
	_assert_true(bool(phone.call(&"exit_dialogue_choice")) and bool(phone.call(&"finish_call", 1020)), "玛莎电话必须由 PhoneSystem 正式结束。")
	await process_frame
	if overview != null:
		overview.call(&"_on_microphone_hotspot_pressed")
	await process_frame
	var panel: MicrophoneBroadcastPanel = overview.get_node_or_null(NodePath("MicrophonePanel")) as MicrophoneBroadcastPanel if overview != null else null
	var option: Button = panel.find_child("InformationOption_info_wagon_martha_route", true, false) as Button if panel != null else null
	var publish_button: Button = panel.find_child("PublishTask_task_broadcast_wagon_witness_request", true, false) as Button if panel != null else null
	_assert_true(option != null and publish_button != null, "寻车单选任务可发布后必须构建信息项与发送按钮。")
	if option != null:
		_assert_true(option.button_pressed, "单项单选任务必须自动保持唯一信息项选中。")
	if publish_button != null:
		publish_button.emit_signal(&"pressed")
	var records: Array[Dictionary] = story_engine.get_player_broadcast_records()
	_assert_equal(records.size(), 1, "真实点击寻车发送按钮必须生成一条权威记录。")
	if not records.is_empty():
		_assert_equal((records[0] as Dictionary).get("information_item_ids", []), ["info_wagon_martha_route"], "寻车单选记录必须只保存唯一选项。")
	_assert_true(story_engine.is_condition_met("condition_wagon_witness_request_sent"), "真实寻车发送必须设置条件来解锁后续来电。")
	var feedback: Label = panel.find_child("FeedbackLabel", true, false) as Label if panel != null else null
	_assert_true(feedback != null and feedback.text == "信息已通过中央麦克风发送。", "寻车发送成功后必须显示中文成功反馈。")
	_cleanup(clock, story_engine, screen)


func _load_validated_story() -> Dictionary:
	var loader: RefCounted = CONTENT_LOADER_SCRIPT.new()
	var loaded: Dictionary = loader.call(&"load_json", STORY_PATH) as Dictionary
	_assert_ok(loaded, "寻车任务测试必须能读取剧情。")
	if not bool(loaded.get("ok", false)):
		return {}
	var validator: RefCounted = CONTENT_VALIDATOR_SCRIPT.new()
	var validated: Dictionary = validator.call(&"validate_test_night_story", loaded["data"], STORY_PATH) as Dictionary
	_assert_ok(validated, "寻车任务测试剧情必须通过严格校验。")
	return validated if bool(validated.get("ok", false)) else {}


func _cleanup(clock: Node, story_engine: StoryEngine, screen: GameScreen) -> void:
	if screen != null and is_instance_valid(screen):
		screen.release_runtime()
	if story_engine != null:
		story_engine.release_runtime()
	if screen != null and is_instance_valid(screen) and screen.get_parent() == root:
		root.remove_child(screen)
		screen.queue_free()
	if clock != null and is_instance_valid(clock) and clock.get_parent() == root:
		root.remove_child(clock)
		clock.free()


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s。" % [message, str(result)])


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][MicrophoneSelectionUi] %s" % message)
