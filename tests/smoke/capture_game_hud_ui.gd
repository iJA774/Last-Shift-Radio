extends SceneTree
## 游戏内悬浮 HUD 的视觉留档。
##
## 此脚本必须在带渲染设备的 Godot 控制台入口执行。它通过 GameClock 推进到
## 第一通真实来电，确保独立时间牌、ESC 控制栏和纯展示来电提示同时可见。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts"
const SETTINGS_PATH: String = "user://game_hud_capture_settings.json"

var _settings_manager: Node = null
var _original_settings_path: String = ""


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	_settings_manager = root.get_node_or_null(NodePath("SettingsManager")) as Node
	if _settings_manager == null:
		_fail("找不到 SettingsManager，无法隔离 HUD 验收。")
		return
	_original_settings_path = String(_settings_manager.call(&"get_settings_path"))
	_cleanup_capture_settings()
	if not _is_ok(_settings_manager.call(&"set_settings_path_for_verification", SETTINGS_PATH)) or not _is_ok(_settings_manager.call(&"load_settings")):
		_fail("无法准备隔离 HUD 设置文件。")
		return
	var main: Control = MAIN_SCENE.instantiate() as Control
	if main == null:
		_fail("无法实例化主场景。")
		return
	root.add_child(main)
	await _wait_frames(3)
	main.call(&"request_start_shift")
	await _wait_frames(2)
	main.call(&"finish_loading_for_verification")
	await _wait_frames(3)
	var screen: GameScreen = main.get("_game_screen") as GameScreen
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	if screen == null or game_clock == null:
		_fail("无法取得夜班界面或游戏时钟。")
		return
	if not bool(game_clock.call(&"advance_ticks_for_verification", 60)):
		_fail("无法推进到首通来电。")
		return
	await _wait_frames(3)
	var global_status: GlobalStatus = screen.get_node_or_null(NodePath("GlobalStatus")) as GlobalStatus
	if global_status == null or not global_status.is_ringing():
		_fail("首通来电时必须显示独立来电提示。")
		return
	if not _save_viewport("hud_ringing_1920x1080.png"):
		return
	if not _is_ok(global_status.advance_ringing_blink_for_verification(1)):
		_fail("无法切换来电灭图截图。")
		return
	await _wait_frames(1)
	if not _save_viewport("hud_ringing_dim_1920x1080.png"):
		return
	global_status.advance_ringing_blink_for_verification(1)
	if not _is_ok(screen.toggle_control_bar()):
		_fail("无法打开 ESC 控制栏截图。")
		return
	await _wait_frames(2)
	if not _save_viewport("hud_control_bar_ringing_1920x1080.png"):
		return
	screen.toggle_control_bar()
	root.remove_child(main)
	main.queue_free()
	await process_frame
	_restore_settings_path()
	print("[测试][GameHudCapture] 已生成独立时间牌、ESC 控制栏与响铃提示的 1920×1080 截图。")
	quit(0)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _save_viewport(file_name: String) -> bool:
	var absolute_directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		_fail("无法创建截图目录，错误码=%d。" % directory_error)
		return false
	var viewport_texture: ViewportTexture = root.get_texture()
	if viewport_texture == null:
		_fail("当前运行模式没有可用的渲染纹理；请使用带渲染设备的 Godot 控制台入口执行截图。")
		return false
	var image: Image = viewport_texture.get_image()
	if image == null or image.is_empty():
		_fail("当前运行模式没有生成有效画面；请使用带渲染设备的 Godot 控制台入口执行截图。")
		return false
	var output_path: String = "%s/%s" % [absolute_directory, file_name]
	var save_error: Error = image.save_png(output_path)
	if save_error != OK:
		_fail("无法保存截图：%s，错误码=%d。" % [output_path, save_error])
		return false
	return true


func _fail(message: String) -> void:
	_restore_settings_path()
	push_error("[测试][GameHudCapture] %s" % message)
	quit(1)


func _restore_settings_path() -> void:
	if _settings_manager != null and not _original_settings_path.is_empty():
		_settings_manager.call(&"set_settings_path_for_verification", _original_settings_path)
		_settings_manager.call(&"load_settings")
	_cleanup_capture_settings()


func _cleanup_capture_settings() -> void:
	for path: String in [SETTINGS_PATH, "%s.tmp" % SETTINGS_PATH, "%s.bak" % SETTINGS_PATH]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)


func _is_ok(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))
