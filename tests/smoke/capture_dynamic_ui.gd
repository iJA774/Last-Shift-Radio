extends SceneTree

## 第三阶段动态界面视觉验收脚本。
##
## 必须用带渲染设备的 Godot 控制台入口执行；Headless 只负责行为测试，不能代替
## hover、过渡中间帧、背景亮灭素材和设备呼吸光的实际画面检查。

const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase3"
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")


func _init() -> void:
	call_deferred("_capture_dynamic_ui")


func _capture_dynamic_ui() -> void:
	root.size = Vector2i(1920, 1080)
	var main_scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	if main_scene == null:
		_fail("无法加载主场景。")
		return
	var main: Control = main_scene.instantiate() as Control
	root.add_child(main)
	await _wait_frames(4)
	main.call(&"request_start_shift")
	await _wait_frames(2)
	main.call(&"finish_loading_for_verification")
	await _wait_frames(3)

	var game_screen: Control = main.get("_game_screen") as Control
	if game_screen == null or not game_screen.has_method(&"show_view") or not game_screen.has_method(&"set_motion_enabled"):
		_fail("主场景缺少 GameScreen 动态验收接口。")
		return
	if not _prepare_output_directory():
		return
	if not _prepare_authoritative_warren_dialogue(main):
		return

	Input.warp_mouse(Vector2(1910.0, 1070.0))
	await _wait_frames(3)
	if not _save_viewport("studio_default.png"):
		return
	var table_lamp: Control = game_screen.get_node_or_null(
		NodePath("ViewHost/StudioOverview/TableLampMaterialSwitch")
	) as Control
	if table_lamp == null or not _is_ok_result(table_lamp.call(&"trigger_flicker_for_verification")):
		_fail("无法触发总览台灯背景灭灯验收帧。")
		return
	await process_frame
	if not _save_viewport("studio_lamp_off.png"):
		return
	await create_timer(0.24).timeout

	var computer_hotspot: Button = game_screen.get_node_or_null(
		NodePath("ViewHost/StudioOverview/ComputerHotspot")
	) as Button
	if computer_hotspot == null:
		_fail("工作室总览缺少电脑设备热点。")
		return
	Input.warp_mouse(computer_hotspot.get_global_rect().get_center())
	await _wait_frames(3)
	if not _save_viewport("studio_computer_hover.png"):
		return
	computer_hotspot.button_down.emit()
	await create_timer(0.05).timeout
	if not _save_viewport("studio_computer_pressed.png"):
		return
	computer_hotspot.button_up.emit()

	if not _show_view(game_screen, "phone"):
		return
	await create_timer(0.08).timeout
	if not _save_viewport("transition_phone_mid.png"):
		return
	await create_timer(0.18).timeout
	if not _save_viewport("phone_settled.png"):
		return
	if not _save_viewport("phone_story_dialogue.png"):
		return
	if not _complete_authoritative_warren_dialogue(main):
		return
	await _wait_frames(3)

	if not _show_view(game_screen, "studio"):
		return
	await create_timer(0.10).timeout
	if not _save_viewport("transition_return_mid.png"):
		return
	await create_timer(0.18).timeout
	if not _complete_authoritative_trucker_dialogue(main):
		return
	await _wait_frames(2)
	var microphone_hotspot: Button = game_screen.get_node_or_null(
		NodePath("ViewHost/StudioOverview/MicrophoneHotspot")
	) as Button
	var microphone_panel: Control = game_screen.get_node_or_null(
		NodePath("ViewHost/StudioOverview/MicrophonePanel")
	) as Control
	if microphone_hotspot == null or microphone_panel == null:
		_fail("工作室总览缺少中央麦克风验收控件。")
		return
	microphone_hotspot.pressed.emit()
	await _wait_frames(2)
	if not _save_viewport("microphone_broadcast_panel.png"):
		return
	var selected_information_ids: Array[String] = ["info_bridge_tanker_fire", "info_bridge_east_queue"]
	microphone_panel.emit_signal(&"broadcast_requested", "task_broadcast_bridge_closure", selected_information_ids)
	await _wait_frames(2)
	if not _save_viewport("microphone_broadcast_feedback.png"):
		return
	microphone_panel.emit_signal(&"close_requested")
	await _wait_frames(2)

	if not _show_view(game_screen, "computer"):
		return
	await create_timer(0.30).timeout
	if not _save_viewport("computer_glow_a.png"):
		return
	if not _save_viewport("computer_information_terminal.png"):
		return
	await create_timer(1.70).timeout
	if not _save_viewport("computer_glow_b.png"):
		return

	if not _show_view(game_screen, "door"):
		return
	await create_timer(0.36).timeout
	if not _save_viewport("door_default.png"):
		return
	var street_lamp: Control = game_screen.get_node_or_null(
		NodePath("ViewHost/DoorWindowCloseup/StreetLampMaterialSwitch")
	) as Control
	if street_lamp == null or not _is_ok_result(street_lamp.call(&"trigger_flicker_for_verification")):
		_fail("无法触发门外路灯背景灭灯验收帧。")
		return
	await process_frame
	if not _save_viewport("door_street_lamp_off.png"):
		return
	await create_timer(0.24).timeout

	var motion_result: Variant = game_screen.call(&"set_motion_enabled", false)
	if not _is_ok_result(motion_result):
		_fail("无法启用减少动态：%s。" % str(motion_result))
		return
	await _wait_frames(2)
	if not _save_viewport("door_motion_disabled.png"):
		return

	var restore_result: Variant = game_screen.call(&"set_motion_enabled", true)
	if not _is_ok_result(restore_result):
		_fail("无法恢复动态效果：%s。" % str(restore_result))
		return
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock"))
	if game_clock == null:
		_fail("无法取得推进到 02:00 所需的 GameClock。")
		return
	var remaining_ticks_value: Variant = game_clock.call(&"get_remaining_game_ticks")
	if typeof(remaining_ticks_value) != TYPE_INT or not bool(game_clock.call(
		&"advance_ticks_for_verification",
		int(remaining_ticks_value)
	)):
		_fail("无法把 GameClock 精确推进到 02:00。")
		return
	await _wait_frames(3)
	if not _save_viewport("ending_locked.png"):
		return

	print("[测试][DynamicUI] 已生成热点、过渡、背景亮灭、设备微动和减少动态的 1920×1080 验收帧。")
	quit(0)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _prepare_output_directory() -> bool:
	var output_directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error == OK:
		return true
	_fail("无法创建截图目录：%s，错误码=%d。" % [output_directory, directory_error])
	return false


func _show_view(game_screen: Control, view_id: String) -> bool:
	var result: Variant = game_screen.call(&"show_view", view_id)
	if _is_ok_result(result):
		return true
	_fail("无法切换到视图 %s：%s。" % [view_id, str(result)])
	return false


## 视觉验收通过 StoryEngine / PhoneSystem 的公开接口建立真实剧情状态，
## 不直接给电话或电脑 UI 注入伪造文本。
func _prepare_authoritative_warren_dialogue(main: Control) -> bool:
	var story_engine: RefCounted = main.get("_story_engine") as RefCounted
	var phone_system: RefCounted = main.get("_phone_system") as RefCounted
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	if story_engine == null or phone_system == null or game_clock == null:
		_fail("无法取得已启动夜班的 StoryEngine、PhoneSystem 或 GameClock。")
		return false
	# 只能经 GameClock 推进，避免 StoryEngine 提前到 01:01 后又被仍停在 01:00
	# 的时钟信号回退。GameClock 会把同一整数 tick 广播给 StoryEngine。
	if not bool(game_clock.call(&"advance_ticks_for_verification", 60)):
		_fail("无法通过 GameClock 推进到沃伦来电。")
		return false
	var current_tick_value: Variant = game_clock.call(&"get_current_game_tick")
	if typeof(current_tick_value) != TYPE_INT:
		_fail("GameClock 未返回沃伦来电时的整数 tick。")
		return false
	var game_screen: Control = main.get("_game_screen") as Control
	if game_screen == null:
		_fail("无法取得接听沃伦来电所需的 GameScreen。")
		return false
	game_screen.call(&"_on_answer_requested")
	if String(phone_system.call(&"get_state_name")) != "DIALOGUE_CHOICE":
		_fail("沃伦来电未进入 Agent 自由会话状态。")
		return false
	return true


func _complete_authoritative_warren_dialogue(main: Control) -> bool:
	var story_engine: RefCounted = main.get("_story_engine") as RefCounted
	var phone_system: RefCounted = main.get("_phone_system") as RefCounted
	if story_engine == null or phone_system == null:
		_fail("无法取得完成沃伦对话所需的运行时。")
		return false
	if not _commit_active_coordinator_turn(main, story_engine, ["statement_warren_tanker_fire_claim"], "酒吧有人说北桥附近一辆油罐车冒烟；我没有亲眼看见。"):
		return false
	if not bool(phone_system.call(&"exit_dialogue_choice")):
		_fail("无法通过 PhoneSystem 退出终止对话状态。")
		return false
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	if game_clock == null:
		_fail("无法取得结束沃伦通话所需的 GameClock。")
		return false
	var current_tick_value: Variant = game_clock.call(&"get_current_game_tick")
	if typeof(current_tick_value) != TYPE_INT or not bool(phone_system.call(&"finish_call", int(current_tick_value))):
		_fail("无法通过 PhoneSystem 正常结束沃伦通话。")
		return false
	return true


func _complete_authoritative_trucker_dialogue(main: Control) -> bool:
	var story_engine: RefCounted = main.get("_story_engine") as RefCounted
	var phone_system: RefCounted = main.get("_phone_system") as RefCounted
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	if story_engine == null or phone_system == null or game_clock == null:
		_fail("无法取得完成卡车司机对话所需的运行时。")
		return false
	var current_tick_value: Variant = game_clock.call(&"get_current_game_tick")
	if typeof(current_tick_value) != TYPE_INT:
		_fail("GameClock 未返回推进 B 对话所需的整数 tick。")
		return false
	var target_tick: int = 33 * GAME_CLOCK_SCRIPT.GAME_TICKS_PER_MINUTE
	var current_tick: int = int(current_tick_value)
	if current_tick > target_tick:
		_fail("动态验收在完成 B 前已经越过 01:33，当前 tick=%d。" % current_tick)
		return false
	if current_tick < target_tick and not bool(game_clock.call(&"advance_ticks_for_verification", target_tick - current_tick)):
		_fail("无法通过 GameClock 推进到 01:33 的卡车司机来电。")
		return false
	if String(phone_system.call(&"get_active_event_id")) != "call_06_trucker":
		_fail("01:33 未得到预期的 call_06_trucker 活动线路。")
		return false
	var trucker_tick_value: Variant = game_clock.call(&"get_current_game_tick")
	var game_screen: Control = main.get("_game_screen") as Control
	if game_screen == null:
		_fail("无法取得接听卡车司机来电所需的 GameScreen。")
		return false
	game_screen.call(&"_on_answer_requested")
	if String(phone_system.call(&"get_state_name")) != "DIALOGUE_CHOICE":
		_fail("卡车司机来电未进入 Agent 自由会话状态。")
		return false
	if not _commit_active_coordinator_turn(main, story_engine, ["statement_trucker_bridge_queue"], "北桥东侧入口堵死了，前面全是刹车灯。"):
		return false
	if not bool(phone_system.call(&"exit_dialogue_choice")):
		_fail("无法退出卡车司机终止对话状态。")
		return false
	var finish_tick_value: Variant = game_clock.call(&"get_current_game_tick")
	if typeof(finish_tick_value) != TYPE_INT or not bool(phone_system.call(&"finish_call", int(finish_tick_value))):
		_fail("无法正常结束卡车司机通话。")
		return false
	return true


func _commit_active_coordinator_turn(main: Control, story_engine: RefCounted, asserted_statement_ids: Array, utterance: String) -> bool:
	var coordinator: RefCounted = main.get("_interaction_coordinator") as RefCounted
	if coordinator == null:
		_fail("动态验收缺少 InteractionCoordinator。")
		return false
	var session: Dictionary = coordinator.call(&"get_active_session_snapshot") as Dictionary
	if session.is_empty():
		_fail("动态验收没有活动 ConversationSession。")
		return false
	var commit_result: Variant = story_engine.call(&"commit_agent_turn", {
		"session_id": String(session["session_id"]),
		"event_id": String(session["event_id"]),
		"actor_id": String(session["actor_id"]),
		"request_serial": 1,
		"turn_index": int(session.get("turn_index", 0)) + 1,
		"actor_turn": {
			"speech_act": "answer",
			"utterance": utterance,
			"asserted_claim_ids": asserted_statement_ids.duplicate(),
			"withheld_claim_ids": [],
			"session_intent": "continue",
			"world_action": null,
		},
	})
	if not _is_ok_result(commit_result):
		_fail("动态验收无法提交 committed ActorTurn：%s。" % str(commit_result))
		return false
	return true


func _save_viewport(file_name: String) -> bool:
	var output_path: String = "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var image: Image = root.get_texture().get_image()
	var save_error: Error = image.save_png(ProjectSettings.globalize_path(output_path))
	if save_error == OK:
		return true
	_fail("无法保存截图：%s，错误码=%d。" % [output_path, save_error])
	return false


func _is_ok_result(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))


func _fail(message: String) -> void:
	push_error("[测试][DynamicUI] %s" % message)
	quit(1)
