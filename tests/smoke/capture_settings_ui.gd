extends SceneTree

## 第八阶段 1920×1080 视觉验收：设置面板、125% 字体、CRT off、
## 减少闪烁与静音均在真实 SettingsManager 信号链上即时生效。
## 请使用带渲染设备的 Godot 控制台入口运行；Headless 不替代视觉检查。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase8"
const SETTINGS_PATH: String = "user://phase8_capture_settings.json"

var _settings_manager: Node = null
var _original_settings_path: String = ""


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	_settings_manager = root.get_node_or_null(NodePath("SettingsManager")) as Node
	if _settings_manager == null:
		_fail("找不到 SettingsManager 自动加载节点。")
		return
	_original_settings_path = String(_settings_manager.call(&"get_settings_path"))
	_cleanup_capture_settings()
	if not _is_ok(_settings_manager.call(&"set_settings_path_for_verification", SETTINGS_PATH)) or not _is_ok(_settings_manager.call(&"load_settings")):
		_fail("无法准备隔离设置文件。")
		return
	for result: Variant in [
		_settings_manager.call(&"set_font_size", 100),
		_settings_manager.call(&"set_text_speed", 1.0),
		_settings_manager.call(&"set_reduce_flashing_enabled", false),
		_settings_manager.call(&"set_crt_enabled", true),
		_settings_manager.call(&"set_master_volume", 1.0),
	]:
		if not _is_ok(result):
			_fail("无法应用设置视觉夹具：%s。" % str(result))
			return
	if not _prepare_output_directory():
		return
	var app: Control = MAIN_SCENE.instantiate() as Control
	root.add_child(app)
	await _wait_frames(3)
	var menu_settings: Button = app.get_node_or_null(NodePath("ScreenHost/MainMenu/Content/MenuPanel/Margin/Layout/SettingsButton")) as Button
	if menu_settings == null:
		_fail("主菜单缺少设置按钮。")
		return
	menu_settings.emit_signal(&"pressed")
	await create_timer(0.30).timeout
	if not _save_viewport("settings_menu_100_1920x1080.png"):
		return
	var menu_panel: SettingsPanel = app.get_node_or_null(NodePath("OverlayHost/SettingsPanel")) as SettingsPanel
	if menu_panel != null:
		var master: HSlider = menu_panel.get_node_or_null(NodePath("Controls/MasterSlider")) as HSlider
		for volume: float in [0.0, 0.5, 1.0]:
			master.value = volume
			await _wait_frames(2)
			if not _save_viewport("settings_volume_%d_1920x1080.png" % roundi(volume * 100.0)):
				return
		(menu_panel.get_node(NodePath("Controls/DisableCrtButton")) as Button).emit_signal(&"pressed")
		(menu_panel.get_node(NodePath("Controls/ReduceFlashingButton")) as Button).emit_signal(&"pressed")
		await _wait_frames(2)
		if not _save_viewport("settings_toggle_on_1920x1080.png"):
			return
		_settings_manager.call(&"set_font_size", 125)
		await _wait_frames(3)
		if not _save_viewport("settings_menu_125_1920x1080.png"):
			return
	if menu_panel != null:
		(menu_panel.get_node(NodePath("Controls/CloseButton")) as Button).emit_signal(&"pressed")
		menu_panel.call(&"finish_fade_for_verification")
	await _wait_frames(2)

	app.call(&"request_start_shift")
	await _wait_frames(2)
	app.call(&"finish_loading_for_verification")
	await _wait_frames(4)
	var screen: GameScreen = app.get("_game_screen") as GameScreen
	if screen == null:
		_fail("无法取得 GameScreen。")
		return
	screen.toggle_control_bar()
	(screen.get_node(NodePath("ShiftControlBar/Backdrop/MenuArt/ActionHotspots/SettingsButton")) as Button).emit_signal(&"pressed")
	await _wait_frames(3)
	if not _save_viewport("settings_shift_125_1920x1080.png"):
		return
	var shift_panel: SettingsPanel = screen.get_node_or_null(NodePath("SettingsPanel")) as SettingsPanel
	if shift_panel != null:
		(shift_panel.get_node(NodePath("Controls/CloseButton")) as Button).emit_signal(&"pressed")
		shift_panel.call(&"finish_fade_for_verification")
	await _wait_frames(2)

	if not _is_ok(screen.show_view(GameScreen.VIEW_COMPUTER)):
		_fail("无法切换至电脑视图。")
		return
	await _wait_frames(4)
	if not _is_ok(_settings_manager.call(&"set_crt_enabled", false)):
		_fail("无法关闭 CRT。")
		return
	await _wait_frames(3)
	if not _save_viewport("computer_crt_off_125_1920x1080.png"):
		return

	if not _is_ok(screen.show_view(GameScreen.VIEW_PHONE)):
		_fail("无法切换至电话视图。")
		return
	await _wait_frames(3)
	if not _is_ok(_settings_manager.call(&"set_reduce_flashing_enabled", true)):
		_fail("无法开启减少闪烁。")
		return
	await _wait_frames(3)
	if not _save_viewport("phone_reduce_flashing_125_1920x1080.png"):
		return

	if not _is_ok(_settings_manager.call(&"set_master_volume", 0.0)):
		_fail("无法设置主音量静音。")
		return
	await _wait_frames(2)
	if not _save_viewport("phone_master_muted_125_1920x1080.png"):
		return

	root.remove_child(app)
	app.queue_free()
	await process_frame
	_restore_settings_path()
	print("[测试][SettingsCapture] 已生成设置、CRT off、减少闪烁和静音的 1920×1080 验收截图。")
	quit(0)


func _wait_frames(frame_count: int) -> void:
	for _index: int in frame_count:
		await process_frame


func _prepare_output_directory() -> bool:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	if directory_error == OK:
		return true
	_fail("无法创建截图目录，错误码=%d。" % directory_error)
	return false


func _save_viewport(file_name: String) -> bool:
	var image: Image = root.get_texture().get_image()
	var path: String = ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name])
	var save_error: Error = image.save_png(path)
	if save_error == OK:
		return true
	_fail("无法保存截图 %s，错误码=%d。" % [path, save_error])
	return false


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


func _fail(message: String) -> void:
	_restore_settings_path()
	push_error("[测试][SettingsCapture] %s" % message)
	quit(1)
