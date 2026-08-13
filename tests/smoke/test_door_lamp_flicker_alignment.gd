extends SceneTree
## 门窗路灯闪烁的专项视觉回归。
##
## 亮、灭帧必须共享同一稳定底图；此检查在 1920×1080 实际渲染下输出亮帧、
## 熄灯帧和差分图，并拒绝任何越出透明暗化遮罩范围的画面变化。

const DOOR_SCENE: PackedScene = preload("res://scenes/studio/door_window_closeup.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts/door_flicker_alignment"
const MASK_ALPHA_BOUNDS: Rect2i = Rect2i(436, 249, 342, 642)
const MASK_SCREEN_BOUNDS: Rect2i = Rect2i(496, 282, 397, 738)
const SCREEN_BOUNDS_PADDING: int = 5

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	var can_capture_viewport: bool = DisplayServer.get_name().to_lower() != "headless"
	var closeup: Control = DOOR_SCENE.instantiate() as Control
	_assert_true(closeup != null, "门窗近景必须可实例化。")
	if closeup == null:
		_finish()
		return
	root.add_child(closeup)
	await process_frame
	if can_capture_viewport:
		await RenderingServer.frame_post_draw

	var background: TextureRect = closeup.get_node_or_null(NodePath("BackgroundZoom/Background")) as TextureRect
	var darkening_mask: TextureRect = closeup.get_node_or_null(NodePath("BackgroundZoom/StreetLampDarkeningMask")) as TextureRect
	var switch: Control = closeup.get_node_or_null(NodePath("StreetLampMaterialSwitch")) as Control
	_assert_true(background != null and darkening_mask != null and switch != null, "门窗近景必须包含稳定底图、局部暗化遮罩和路灯切换器。")
	if background == null or darkening_mask == null or switch == null:
		closeup.queue_free()
		_finish()
		return
	_assert_true(background.get_global_rect() == darkening_mask.get_global_rect(), "亮灯底图与局部暗化遮罩的节点 rect 必须完全一致。")
	_assert_true(background.visible and not darkening_mask.visible, "默认必须只显示稳定亮灯底图。")
	_assert_true(darkening_mask.texture != null and darkening_mask.texture.get_size() == Vector2(1672.0, 941.0), "暗化遮罩必须保留与稳定底图一致的像素画布。")
	var mask_image: Image = darkening_mask.texture.get_image() if darkening_mask.texture != null else Image.new()
	_assert_true(_get_alpha_bounds(mask_image) == MASK_ALPHA_BOUNDS, "暗化遮罩的透明像素锚点发生变化；请勿移动或扩大遮罩。")

	var lit_image: Image = Image.new()
	if can_capture_viewport:
		lit_image = root.get_texture().get_image()
		_assert_true(_save_image(lit_image, "door_lamp_lit_1920x1080.png"), "无法写出路灯亮灯验收图。")
	# 验收期间延长单次断电，确保 GPU 已提交熄灯帧前 Timer 不会恢复亮灯；不改变场景配置。
	switch.set("minimum_off_seconds", 1.0)
	switch.set("maximum_off_seconds", 1.0)
	var trigger_result: Variant = switch.call(&"trigger_flicker_for_verification")
	_assert_true(trigger_result is Dictionary and bool((trigger_result as Dictionary).get("ok", false)), "必须能确定性触发路灯熄灭。")
	_assert_true(background.visible and darkening_mask.visible, "触发熄灯后必须立即保留稳定底图并显示局部暗化遮罩。")
	if can_capture_viewport:
		await RenderingServer.frame_post_draw
	_assert_true(background.visible and darkening_mask.visible, "熄灯时不得替换或隐藏稳定底图。")
	if can_capture_viewport:
		var off_image: Image = root.get_texture().get_image()
		_assert_true(_save_image(off_image, "door_lamp_off_1920x1080.png"), "无法写出路灯熄灭验收图。")
		var difference: Image = _create_difference_image(lit_image, off_image)
		_assert_true(_save_image(difference, "door_lamp_difference_1920x1080.png"), "无法写出路灯差分验收图。")
		_assert_difference_is_local(lit_image, off_image)

	var reduce_motion_result: Variant = closeup.call(&"set_motion_enabled", false)
	_assert_true(reduce_motion_result is Dictionary and bool((reduce_motion_result as Dictionary).get("ok", false)), "必须能开启减少闪烁。")
	var snapshot: Dictionary = switch.call(&"get_effect_snapshot") as Dictionary
	_assert_true(
		not bool(snapshot.get("schedule_timer_is_running", true))
		and not bool(snapshot.get("off_timer_is_running", true))
		and not bool(snapshot.get("on_gap_timer_is_running", true))
		and background.visible and not darkening_mask.visible,
		"减少闪烁时必须停止所有路灯动态并恢复稳定底图。"
	)
	closeup.queue_free()
	await process_frame
	_finish()


func _create_difference_image(lit_image: Image, off_image: Image) -> Image:
	var output: Image = Image.create(1920, 1080, false, Image.FORMAT_RGBA8)
	for y: int in 1080:
		for x: int in 1920:
			var lit: Color = lit_image.get_pixel(x, y)
			var off: Color = off_image.get_pixel(x, y)
			var magnitude: float = maxf(absf(lit.r - off.r), maxf(absf(lit.g - off.g), absf(lit.b - off.b)))
			output.set_pixel(x, y, Color(magnitude, magnitude, magnitude, 1.0))
	return output


func _assert_difference_is_local(lit_image: Image, off_image: Image) -> void:
	var allowed_bounds: Rect2i = MASK_SCREEN_BOUNDS.grow(SCREEN_BOUNDS_PADDING)
	var changed_bounds: Rect2i = Rect2i()
	var changed_pixel_count: int = 0
	var first_outside_pixel: Vector2i = Vector2i(-1, -1)
	for y: int in 1080:
		for x: int in 1920:
			var lit: Color = lit_image.get_pixel(x, y)
			var off: Color = off_image.get_pixel(x, y)
			var magnitude: float = maxf(absf(lit.r - off.r), maxf(absf(lit.g - off.g), absf(lit.b - off.b)))
			if magnitude <= 0.015:
				continue
			changed_pixel_count += 1
			if changed_bounds.size == Vector2i.ZERO:
				changed_bounds = Rect2i(x, y, 1, 1)
			else:
				changed_bounds = changed_bounds.expand(Vector2i(x, y))
			if first_outside_pixel == Vector2i(-1, -1) and not allowed_bounds.has_point(Vector2i(x, y)):
				first_outside_pixel = Vector2i(x, y)
	_assert_true(changed_pixel_count > 500, "熄灯必须实际改变路灯和其局部照明，而非空切换。")
	_assert_true(first_outside_pixel == Vector2i(-1, -1), "熄灯差分越出局部遮罩范围：pixel=%s，allowed=%s。" % [first_outside_pixel, allowed_bounds])
	_assert_true(changed_bounds.size != Vector2i.ZERO and allowed_bounds.encloses(changed_bounds), "熄灯差分边界必须完全位于局部遮罩内：changed=%s，allowed=%s。" % [changed_bounds, allowed_bounds])


func _get_alpha_bounds(image: Image) -> Rect2i:
	var minimum_x: int = image.get_width()
	var minimum_y: int = image.get_height()
	var maximum_x: int = -1
	var maximum_y: int = -1
	for y: int in image.get_height():
		for x: int in image.get_width():
			if image.get_pixel(x, y).a <= 0.0:
				continue
			minimum_x = mini(minimum_x, x)
			minimum_y = mini(minimum_y, y)
			maximum_x = maxi(maximum_x, x)
			maximum_y = maxi(maximum_y, y)
	if maximum_x < 0:
		return Rect2i()
	return Rect2i(minimum_x, minimum_y, maximum_x - minimum_x + 1, maximum_y - minimum_y + 1)


func _save_image(image: Image, file_name: String) -> bool:
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	if directory_error != OK:
		push_error("[测试][DoorLampAlignment] 无法创建验收目录：error=%d。" % directory_error)
		return false
	var save_error: Error = image.save_png(ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name]))
	if save_error != OK:
		push_error("[测试][DoorLampAlignment] 无法写出验收图 %s：error=%d。" % [file_name, save_error])
		return false
	return true


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][DoorLampAlignment] %s" % message)


func _finish() -> void:
	if _has_failed:
		print("[测试][DoorLampAlignment] 失败。")
		quit(1)
		return
	print("[测试][DoorLampAlignment] 通过：1920×1080 亮灭共享底图，差分仅位于路灯局部遮罩，减少闪烁会停止动态。")
	quit(0)
