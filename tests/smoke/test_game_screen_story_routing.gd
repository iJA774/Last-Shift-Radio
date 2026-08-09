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
	_assert_true(phone_closeup != null and computer_closeup != null, "GameScreen 必须持有电话与电脑近景。")
	if phone_closeup == null or computer_closeup == null:
		_cleanup(clock, story_engine, screen)
		_finish()
		return

	phone_closeup.emit_signal(&"answer_requested")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "电话近景接听意图必须只经 GameScreen 转交。")
	phone_closeup.emit_signal(&"dialogue_choice_requested")
	_assert_equal(phone.call(&"get_state_name"), "DIALOGUE_CHOICE", "开始预制对话必须先令电话进入 DialogueChoice。")
	var opening_snapshot: Dictionary = story_engine.call(&"get_active_dialogue_snapshot") as Dictionary
	_assert_equal(String(opening_snapshot.get("node_id", "")), "dlg_warren_open", "开始预制对话必须由 StoryEngine 提供稳定入口。")

	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_warren_song")
	phone_closeup.emit_signal(&"dialogue_option_requested", "opt_warren_follow_report")
	var terminal_snapshot: Dictionary = story_engine.call(&"get_active_dialogue_snapshot") as Dictionary
	_assert_true(bool(terminal_snapshot.get("is_terminal", false)), "末个对话选项必须显示终止台词。")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "终止台词后 GameScreen 必须恢复为已接通，保留结束通话操作。")
	phone_closeup.emit_signal(&"dialogue_choice_requested")
	_assert_equal(phone.call(&"get_state_name"), "CONNECTED", "同一通电话的终止台词不得重新开始预制对话。")

	_assert_ok(screen.show_view(GameScreen.VIEW_COMPUTER), "必须能进入播出工作台。")
	computer_closeup.emit_signal(&"broadcast_requested", "broadcast_bridge_tanker_fire")
	var player_records: Array = story_engine.call(&"get_player_broadcast_records") as Array
	_assert_equal(player_records.size(), 1, "电脑广播意图必须只生成一条权威玩家播出记录。")
	computer_closeup.emit_signal(&"broadcast_requested", "broadcast_bridge_tanker_fire")
	_assert_equal(
		(story_engine.call(&"get_player_broadcast_records") as Array).size(),
		1,
		"重复广播意图必须由 StoryEngine 拒绝，不能重复记录。"
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
	print("[测试][GameScreenStoryRouting] 通过：对话、终止锁定和玩家广播均经 GameScreen 路由。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][GameScreenStoryRouting] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
