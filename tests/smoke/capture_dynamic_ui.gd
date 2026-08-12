extends SceneTree

## 第三阶段动态界面视觉验收脚本。
##
## 必须用带渲染设备的 Godot 控制台入口执行；Headless 只负责行为测试，不能代替
## hover、过渡中间帧、背景亮灭素材和设备呼吸光的实际画面检查。

const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase3"
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")

var _font_restore_records: Array[Dictionary] = []


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
	if not _complete_authoritative_warren_dialogue_and_broadcast(main):
		return
	await _wait_frames(3)

	if not _show_view(game_screen, "studio"):
		return
	await create_timer(0.10).timeout
	if not _save_viewport("transition_return_mid.png"):
		return
	await create_timer(0.18).timeout

	if not _show_view(game_screen, "computer"):
		return
	await create_timer(0.30).timeout
	if not _save_viewport("computer_glow_a.png"):
		return
	if not _save_viewport("computer_broadcast_workspace.png"):
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

	Input.warp_mouse(Vector2(1910.0, 1070.0))
	_apply_font_scale(game_screen, 1.25)
	for large_font_view_id: String in ["studio", "phone", "computer", "door"]:
		if not _show_view(game_screen, large_font_view_id):
			return
		await _wait_frames(3)
		if not _save_viewport("large_font_%s.png" % large_font_view_id):
			return
	_restore_font_scale()

	var restore_result: Variant = game_screen.call(&"set_motion_enabled", true)
	if not _is_ok_result(restore_result):
		_fail("无法恢复动态效果：%s。" % str(restore_result))
		return
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock"))
	if game_clock == null or not bool(game_clock.call(
		&"advance_ticks_for_verification",
		GAME_CLOCK_SCRIPT.SHIFT_DURATION_TICKS
	)):
		_fail("无法把 GameClock 推进到 02:00。")
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


func _apply_font_scale(node: Node, scale_factor: float) -> void:
	_font_restore_records.clear()
	_apply_font_scale_recursive(node, scale_factor)


func _apply_font_scale_recursive(node: Node, scale_factor: float) -> void:
	if node is Label or node is Button or node is RichTextLabel:
		var control: Control = node as Control
		var previous_size: int = control.get_theme_font_size(&"font_size")
		_font_restore_records.append({
			"control": control,
			"had_override": control.has_theme_font_size_override(&"font_size"),
			"previous_size": previous_size,
		})
		control.add_theme_font_size_override(
			&"font_size",
			maxi(previous_size + 1, roundi(float(previous_size) * scale_factor))
		)
	for child: Node in node.get_children():
		_apply_font_scale_recursive(child, scale_factor)


func _restore_font_scale() -> void:
	for record: Dictionary in _font_restore_records:
		var control: Control = record["control"] as Control
		if not is_instance_valid(control):
			continue
		if bool(record["had_override"]):
			control.add_theme_font_size_override(&"font_size", int(record["previous_size"]))
		else:
			control.remove_theme_font_size_override(&"font_size")
	_font_restore_records.clear()


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
	if not bool(phone_system.call(&"answer_call", int(current_tick_value))):
		_fail("无法通过 PhoneSystem 接听沃伦来电。")
		return false
	if not bool(phone_system.call(&"enter_dialogue_choice")):
		_fail("无法通过 PhoneSystem 进入沃伦对话选择。")
		return false
	var dialogue_result: Variant = story_engine.call(&"begin_active_call_dialogue")
	if not _is_ok_result(dialogue_result):
		_fail("无法通过 StoryEngine 开始沃伦预制对话：%s。" % str(dialogue_result))
		return false
	return true


func _complete_authoritative_warren_dialogue_and_broadcast(main: Control) -> bool:
	var story_engine: RefCounted = main.get("_story_engine") as RefCounted
	var phone_system: RefCounted = main.get("_phone_system") as RefCounted
	if story_engine == null or phone_system == null:
		_fail("无法取得完成沃伦对话所需的运行时。")
		return false
	var first_choice: Variant = story_engine.call(&"select_dialogue_option", "opt_warren_song")
	if not _is_ok_result(first_choice):
		_fail("无法通过 StoryEngine 提交沃伦第一轮回应：%s。" % str(first_choice))
		return false
	var final_choice: Variant = story_engine.call(&"select_dialogue_option", "opt_warren_follow_report")
	if not _is_ok_result(final_choice) or not bool((final_choice as Dictionary).get("reached_terminal", false)):
		_fail("沃伦终止台词未能由 StoryEngine 正确生成：%s。" % str(final_choice))
		return false
	if not bool(phone_system.call(&"exit_dialogue_choice")):
		_fail("无法通过 PhoneSystem 退出终止对话状态。")
		return false
	var broadcast_result: Variant = story_engine.call(&"send_player_broadcast", "broadcast_bridge_tanker_fire")
	if not _is_ok_result(broadcast_result):
		_fail("无法通过 StoryEngine 发送已解锁的预制广播稿：%s。" % str(broadcast_result))
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
