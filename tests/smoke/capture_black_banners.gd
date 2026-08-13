extends SceneTree
## 1920×1080 横幅视觉验收：正常主菜单、主壳错误横幅、夜班提示横幅。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts/banners"

var _failed: bool = false


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var main: Control = MAIN_SCENE.instantiate() as Control
	if main == null:
		_fail("无法实例化主场景。")
	else:
		root.add_child(main)
		await _wait_frames(3)
		await _save_viewport("main_menu_retired_font_size_cleaned_1920x1080.png")
		main.call("_show_shell_error", "这是用于验收纯黑横幅的故障提示。")
		await _wait_frames(2)
		await _save_viewport("main_shell_error_black_bar_1920x1080.png")
		main.queue_free()
		await process_frame
	var game_screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	if game_screen == null:
		_fail("无法实例化夜班界面。")
	else:
		root.add_child(game_screen)
		await _wait_frames(3)
		game_screen.show_system_error("这是用于验收纯黑横幅的故障提示。")
		await _wait_frames(2)
		await _save_viewport("game_system_message_black_bar_1920x1080.png")
		game_screen.queue_free()
	if _failed:
		quit(1)
		return
	print("[测试][BlackBannerCapture] 已生成主菜单与夜班纯黑横幅截图。")
	quit(0)


func _save_viewport(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		_fail("无法创建横幅截图目录。")
		return
	var image: Image = root.get_texture().get_image()
	if image == null or image.is_empty() or image.save_png("%s/%s" % [directory, file_name]) != OK:
		_fail("无法保存横幅截图：%s。" % file_name)


func _wait_frames(count: int) -> void:
	for _index: int in count:
		await process_frame


func _fail(message: String) -> void:
	_failed = true
	push_error("[测试][BlackBannerCapture] %s" % message)
