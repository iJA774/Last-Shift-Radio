extends SceneTree

const OUTPUT_DIRECTORY: String = "res://tests/artifacts"
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")


func _init() -> void:
	call_deferred("_capture_main_ui")


func _capture_main_ui() -> void:
	root.size = Vector2i(1920, 1080)
	var main_scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	if main_scene == null:
		push_error("[测试][UI] 无法加载主场景。")
		quit(1)
		return
	var main: Control = main_scene.instantiate() as Control
	root.add_child(main)
	await process_frame
	await process_frame
	main.call(&"request_start_shift")
	await process_frame
	main.call(&"confirm_content_notice")
	await process_frame
	await process_frame

	var output_directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		push_error("[测试][UI] 无法创建截图目录：%s，错误码=%d。" % [output_directory, directory_error])
		quit(1)
		return
	var game_screen: Control = main.get("_game_screen") as Control
	if game_screen == null or not game_screen.has_method(&"show_view"):
		push_error("[测试][UI] 主场景缺少 GameScreen.show_view()。")
		quit(1)
		return
	if not _save_viewport("phase2_studio_1920x1080.png"):
		quit(1)
		return

	if not _show_view(game_screen, "phone"):
		quit(1)
		return
	await process_frame
	if not _save_viewport("phase2_phone_1920x1080.png"):
		quit(1)
		return

	if not _show_view(game_screen, "computer"):
		quit(1)
		return
	await process_frame
	if not _save_viewport("phase2_computer_1920x1080.png"):
		quit(1)
		return

	if not _show_view(game_screen, "door"):
		quit(1)
		return
	await process_frame
	if not _save_viewport("phase2_door_1920x1080.png"):
		quit(1)
		return

	var game_clock: Node = root.get_node("GameClock")
	if not bool(game_clock.call("advance_ticks_for_verification", GAME_CLOCK_SCRIPT.SHIFT_DURATION_TICKS)):
		push_error("[测试][UI] 无法把 GameClock 推进到 02:00。")
		quit(1)
		return
	await process_frame
	await process_frame
	if not _save_viewport("phase2_ending_1920x1080.png"):
		quit(1)
		return
	print("[测试][UI] 已生成第二阶段四视图和 02:00 收束的 1920×1080 截图。")
	quit(0)


func _show_view(game_screen: Control, view_id: String) -> bool:
	var result: Variant = game_screen.call(&"show_view", view_id)
	if result is Dictionary and bool((result as Dictionary).get("ok", false)):
		return true
	push_error("[测试][UI] 无法切换到视图 %s：%s。" % [view_id, str(result)])
	return false


func _save_viewport(file_name: String) -> bool:
	var output_path: String = "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var output_absolute_path: String = ProjectSettings.globalize_path(output_path)
	var image: Image = root.get_texture().get_image()
	var save_error: Error = image.save_png(output_absolute_path)
	if save_error != OK:
		push_error("[测试][UI] 无法保存截图：%s，错误码=%d。" % [output_absolute_path, save_error])
		return false
	return true
