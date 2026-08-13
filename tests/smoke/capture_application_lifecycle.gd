extends SceneTree

## 应用页面视觉验收：主菜单、加载页和独立结束页均为 1920×1080。
## 请使用带渲染设备的 Godot 控制台入口执行；Headless 不替代本脚本。

const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase4"
const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var main: Control = MAIN_SCENE.instantiate() as Control
	main.set("ending_transition_delay_seconds", 0.10)
	root.add_child(main)
	await _wait_frames(3)
	if not _prepare_output_directory() or not _save_viewport("main_menu_1920x1080.png"):
		quit(1)
		return
	main.call(&"request_start_shift")
	# 越过 0.5 秒渐入后再留档，确保截图记录完整可见的 2 秒停留阶段。
	await create_timer(0.60).timeout
	if not _save_viewport("loading_1920x1080.png"):
		quit(1)
		return
	main.call(&"finish_loading_for_verification")
	await _wait_frames(3)
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	if game_clock == null or not bool(game_clock.call(&"advance_ticks_for_verification", int(game_clock.call(&"get_remaining_game_ticks")))):
		push_error("[测试][ApplicationLifecycleCapture] 无法推进到 02:00。")
		quit(1)
		return
	await create_timer(0.16).timeout
	if not _save_viewport("ending_1920x1080.png"):
		quit(1)
		return
	# 夜班返回主界面复用相同加载画面，但目标必须是 MAIN_MENU，不能启动新班次。
	main.call(&"return_to_main_menu")
	await _wait_frames(2)
	main.call(&"request_start_shift")
	await _wait_frames(2)
	main.call(&"finish_loading_for_verification")
	await _wait_frames(2)
	main.call(&"return_to_main_menu")
	await create_timer(0.60).timeout
	if not _save_viewport("return_to_menu_loading_1920x1080.png"):
		quit(1)
		return
	main.call(&"finish_loading_for_verification")
	await _wait_frames(2)
	print("[测试][ApplicationLifecycleCapture] 已生成第四阶段 1920×1080 应用页面截图。")
	quit(0)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _prepare_output_directory() -> bool:
	var output_directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error == OK:
		return true
	push_error("[测试][ApplicationLifecycleCapture] 无法创建截图目录：%s，错误码=%d。" % [output_directory, directory_error])
	return false

func _save_viewport(file_name: String) -> bool:
	var output_path: String = "%s/%s" % [OUTPUT_DIRECTORY, file_name]
	var image: Image = root.get_texture().get_image()
	var save_error: Error = image.save_png(ProjectSettings.globalize_path(output_path))
	if save_error == OK:
		return true
	push_error("[测试][ApplicationLifecycleCapture] 无法保存截图：%s，错误码=%d。" % [output_path, save_error])
	return false
