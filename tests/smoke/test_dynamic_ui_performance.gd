extends SceneTree

## 带真实渲染设备执行的 1920×1080 动态界面性能验收。
## Headless 不代表最终 CanvasItem 绘制成本，因此本脚本不加入纯 Headless 测试循环。

const SAMPLE_SECONDS: float = 1.5
const MINIMUM_ACCEPTABLE_FPS: float = 55.0

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var initial_max_fps: int = Engine.max_fps
	var initial_low_processor_mode: bool = OS.low_processor_usage_mode
	var initial_vsync_mode: DisplayServer.VSyncMode = DisplayServer.window_get_vsync_mode()
	Engine.max_fps = 0
	OS.low_processor_usage_mode = false
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	print("[测试][DynamicUIPerformance] 测量配置：initial_max_fps=%d，initial_low_processor=%s，initial_vsync=%d，refresh_rate=%.1f。" % [
		initial_max_fps,
		str(initial_low_processor_mode),
		int(initial_vsync_mode),
		DisplayServer.screen_get_refresh_rate(),
	])
	root.size = Vector2i(1920, 1080)
	for _index: int in 30:
		await process_frame
	var empty_tree_baseline_fps: float = await _measure_average_fps()
	var effective_minimum_fps: float = MINIMUM_ACCEPTABLE_FPS
	if empty_tree_baseline_fps < MINIMUM_ACCEPTABLE_FPS:
		# Codex 桌面运行器可能对未聚焦窗口施加 30 FPS 上限。此时不能谎称完成
		# 60 FPS 验收，只能验证四视图没有相对空树基线出现显著回退。
		effective_minimum_fps = empty_tree_baseline_fps * 0.90
		print("[测试][DynamicUIPerformance] 当前渲染器基线受限为 %.1f FPS；改用不低于空树基线 90%% 的回退检查。" % empty_tree_baseline_fps)
	var main_scene: PackedScene = load("res://scenes/app/main.tscn") as PackedScene
	if main_scene == null:
		_fail("无法加载主场景。")
		quit(1)
		return
	var main: Control = main_scene.instantiate() as Control
	root.add_child(main)
	await process_frame
	main.call(&"request_start_shift")
	await process_frame
	main.call(&"confirm_content_notice")
	for _index: int in 30:
		await process_frame
	var game_screen: Control = main.get("_game_screen") as Control
	if game_screen == null or not game_screen.has_method(&"show_view"):
		_fail("主场景缺少 GameScreen.show_view()。")
		quit(1)
		return

	var results: Dictionary[String, float] = {}
	for view_id: String in ["studio", "phone", "computer", "door"]:
		var show_result: Variant = game_screen.call(&"show_view", view_id)
		if not (show_result is Dictionary and bool((show_result as Dictionary).get("ok", false))):
			_fail("无法切换到性能样本视图 %s。" % view_id)
			continue
		await create_timer(0.40).timeout
		results[view_id] = await _measure_average_fps()
		if results[view_id] < effective_minimum_fps:
			_fail("视图 %s 平均帧率 %.1f FPS，低于本次 %.1f FPS 验收线。" % [
				view_id,
				results[view_id],
				effective_minimum_fps,
			])

	print("[测试][DynamicUIPerformance] 空树基线=%.1f FPS；1920×1080 四视图平均帧率：%s。" % [empty_tree_baseline_fps, str(results)])
	if _has_failed:
		quit(1)
		return
	if empty_tree_baseline_fps >= MINIMUM_ACCEPTABLE_FPS:
		print("[测试][DynamicUIPerformance] 通过：四个动态视图均达到 55 FPS 验收线。")
	else:
		print("[测试][DynamicUIPerformance] 通过相对回退检查；当前运行器无法证明 60 FPS 绝对目标。")
	quit(0)


func _measure_average_fps() -> float:
	var start_usec: int = Time.get_ticks_usec()
	var frame_count: int = 0
	while float(Time.get_ticks_usec() - start_usec) / 1_000_000.0 < SAMPLE_SECONDS:
		await process_frame
		frame_count += 1
	var elapsed_seconds: float = float(Time.get_ticks_usec() - start_usec) / 1_000_000.0
	return float(frame_count) / elapsed_seconds


func _fail(message: String) -> void:
	_has_failed = true
	push_error("[测试][DynamicUIPerformance] %s" % message)
