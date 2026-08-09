extends SceneTree

## 第四阶段应用页面视觉验收：主菜单、内容提示和独立结束页均为 1920×1080。
## 请使用带渲染设备的 Godot 控制台入口执行；Headless 不替代本脚本。

const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase4"
const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const LARGE_FONT_SCALE: float = 1.25

var _font_restore_records: Array[Dictionary] = []


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
	if not await _capture_large_font_page(main, "large_font_main_menu.png", "主菜单"):
		quit(1)
		return

	main.call(&"request_start_shift")
	await _wait_frames(3)
	if not _save_viewport("content_notice_1920x1080.png"):
		quit(1)
		return
	if not await _capture_large_font_page(main, "large_font_content_notice.png", "内容提示"):
		quit(1)
		return

	main.call(&"confirm_content_notice")
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
	if not await _capture_large_font_page(main, "large_font_ending.png", "结束页"):
		quit(1)
		return
	print("[测试][ApplicationLifecycleCapture] 已生成第四阶段默认与放大字体 1920×1080 应用页面截图。")
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


func _capture_large_font_page(main: Control, file_name: String, page_name: String) -> bool:
	_apply_font_scale(main, LARGE_FONT_SCALE)
	await _wait_frames(3)
	var layout_ok: bool = _verify_large_font_layout(main, page_name)
	var save_ok: bool = _save_viewport(file_name)
	_restore_font_scale()
	return layout_ok and save_ok


func _apply_font_scale(node: Node, scale_factor: float) -> void:
	_font_restore_records.clear()
	_apply_font_scale_recursive(node, scale_factor)


func _apply_font_scale_recursive(node: Node, scale_factor: float) -> void:
	if node is Label or node is Button:
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


func _verify_large_font_layout(root_control: Control, page_name: String) -> bool:
	var failures: PackedStringArray = []
	_collect_large_font_layout_failures(root_control, page_name, failures)
	if failures.is_empty():
		return true
	for failure: String in failures:
		push_error("[测试][ApplicationLifecycleCapture] %s" % failure)
	return false


func _collect_large_font_layout_failures(node: Node, page_name: String, failures: PackedStringArray) -> void:
	if node is Control:
		var control: Control = node as Control
		if control.is_visible_in_tree() and control.size.x > 0.0 and control.size.y > 0.0:
			var rect: Rect2 = control.get_global_rect()
			var viewport_size: Vector2 = Vector2(root.size)
			if rect.position.x < -1.0 or rect.position.y < -1.0 or rect.end.x > viewport_size.x + 1.0 or rect.end.y > viewport_size.y + 1.0:
				failures.append("放大字体%s存在越出视口的控件：%s，rect=%s。" % [page_name, control.get_path(), rect])
			if control is Label or control is Button:
				var minimum_size: Vector2 = control.get_combined_minimum_size()
				if minimum_size.x > control.size.x + 1.0 or minimum_size.y > control.size.y + 1.0:
					failures.append("放大字体%s存在最小尺寸溢出/可能文本裁切：%s，minimum=%s，size=%s。" % [page_name, control.get_path(), minimum_size, control.size])
	for child: Node in node.get_children():
		_collect_large_font_layout_failures(child, page_name, failures)
