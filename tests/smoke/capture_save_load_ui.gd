extends SceneTree

## 第七阶段存档 UI 视觉留档：主菜单读取入口与班次内三槽覆盖层。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts"


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var main: Control = MAIN_SCENE.instantiate() as Control
	if main == null:
		push_error("[测试][SaveCapture] 无法实例化 Main。")
		quit(1)
		return
	root.add_child(main)
	await process_frame
	await process_frame
	if not _save_viewport("phase7_main_menu_load_1920x1080.png"):
		quit(1)
		return
	main.call(&"request_load_game")
	await create_timer(0.30).timeout
	if not _save_viewport("phase7_load_slots_1920x1080.png"):
		quit(1)
		return
	_apply_font_scale(main, 1.25)
	await process_frame
	if not _save_viewport("phase7_load_slots_125pct_1920x1080.png"):
		quit(1)
		return
	main.call(&"return_to_main_menu")
	await process_frame
	main.call(&"request_start_shift")
	await process_frame
	main.call(&"finish_loading_for_verification")
	await process_frame
	var screen: GameScreen = main.get("_game_screen") as GameScreen
	if screen == null:
		push_error("[测试][SaveCapture] 新班次没有 GameScreen。")
		quit(1)
		return
	screen.call(&"_open_save_panel")
	# 存档页自身有 0.25 秒渐入；等待其完成，避免视觉留档把底层值班画面误认为旧版 UI。
	await create_timer(0.30).timeout
	if not _save_viewport("phase7_save_slots_1920x1080.png"):
		quit(1)
		return
	_apply_font_scale(main, 1.25)
	await process_frame
	await process_frame
	if not _save_viewport("phase7_save_slots_125pct_1920x1080.png"):
		quit(1)
		return
	print("[测试][SaveCapture] 已生成第七阶段主菜单读取入口、读取槽位页与默认/125% 保存覆盖层截图。")
	quit(0)


func _save_viewport(file_name: String) -> bool:
	var absolute_directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		push_error("[测试][SaveCapture] 无法创建截图目录，错误码=%d。" % directory_error)
		return false
	var output_path: String = "%s/%s" % [absolute_directory, file_name]
	var image: Image = root.get_texture().get_image()
	var save_error: Error = image.save_png(output_path)
	if save_error != OK:
		push_error("[测试][SaveCapture] 无法保存截图，错误码=%d。" % save_error)
		return false
	return true


func _apply_font_scale(node: Node, scale_factor: float) -> void:
	if node is Label or node is Button:
		var control: Control = node as Control
		var current_size: int = control.get_theme_font_size(&"font_size")
		control.add_theme_font_size_override(&"font_size", maxi(current_size + 1, roundi(float(current_size) * scale_factor)))
	for child: Node in node.get_children():
		_apply_font_scale(child, scale_factor)
