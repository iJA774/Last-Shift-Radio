extends SceneTree
## 使用真实 Tween 时序验证加载页，而不是只读取配置常量。

const LOADING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/loading_screen.tscn")
const WALL_WATCHDOG_SECONDS: float = 10.0

var _failure_count: int = 0
var _has_finished: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	var loading: Control = LOADING_SCREEN_SCENE.instantiate() as Control
	_assert_true(loading != null, "加载页必须能够实例化。")
	if loading == null:
		_finish()
		return
	loading.transition_finished.connect(func() -> void: _has_finished = true)
	root.add_child(loading)
	var wall_started_at_msec: int = Time.get_ticks_msec()
	var engine_elapsed_seconds: float = 0.0
	var fully_visible_at_seconds: float = -1.0
	var fade_out_started_at_seconds: float = -1.0
	while not _has_finished:
		await process_frame
		engine_elapsed_seconds += loading.get_process_delta_time()
		var alpha: float = loading.modulate.a
		if fully_visible_at_seconds < 0.0 and alpha >= 0.98:
			fully_visible_at_seconds = engine_elapsed_seconds
		elif fully_visible_at_seconds >= 0.0 and fade_out_started_at_seconds < 0.0 and alpha < 0.98:
			fade_out_started_at_seconds = engine_elapsed_seconds
		if float(Time.get_ticks_msec() - wall_started_at_msec) / 1000.0 > WALL_WATCHDOG_SECONDS:
			_assert_true(false, "真实加载 Tween 在 10 秒墙钟看门狗内未结束。")
			break

	# Headless 无 VSync 时引擎 delta 与墙钟并不等速；Tween 与 create_timer 却共同消费
	# 引擎 delta。因此这里按实际驱动 Tween 的 delta 验证三个阶段，墙钟只负责防死锁。
	_assert_true(fully_visible_at_seconds >= 0.4 and fully_visible_at_seconds <= 0.8, "渐入必须约 0.5 秒后完整可见，实际 %.3f 引擎秒。" % fully_visible_at_seconds)
	_assert_true(fade_out_started_at_seconds >= 2.35 and fade_out_started_at_seconds <= 2.8, "完整可见阶段必须保持约 2 秒，渐出始于 %.3f 引擎秒。" % fade_out_started_at_seconds)
	_assert_true(fade_out_started_at_seconds - fully_visible_at_seconds >= 1.85, "加载页完整可见停留不得短于约 2 秒。")
	_assert_true(_has_finished, "0.5 秒渐出结束后必须发出完成信号。")
	_assert_true(
		engine_elapsed_seconds >= 2.8 and engine_elapsed_seconds <= 3.3,
		"真实加载过渡总时长应约为 3 秒，实际 %.3f 引擎秒。" % engine_elapsed_seconds
	)
	_assert_true(loading.modulate.a <= 0.02, "过渡完成时加载页必须完全渐出。")
	loading.queue_free()
	_finish()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failure_count += 1
	push_error("[测试][LoadingScreenTransition] %s" % message)


func _finish() -> void:
	if _failure_count == 0:
		print("[测试][LoadingScreenTransition] 通过：0.5 秒渐入、2 秒完整停留与 0.5 秒渐出使用真实 Tween 时序。")
		quit(0)
		return
	push_error("[测试][LoadingScreenTransition] 失败：共 %d 项。" % _failure_count)
	quit(1)
