extends SceneTree
## 使用真实 Tween 时序验证加载页，而不是只读取配置常量。

const LOADING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/loading_screen.tscn")

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
	var started_at_msec: int = Time.get_ticks_msec()
	root.add_child(loading)

	await create_timer(0.65, true, false, true).timeout
	_assert_true(loading.modulate.a >= 0.98, "0.5 秒渐入后加载页必须完整可见。")
	_assert_true(not _has_finished, "渐入完成后不能提前结束加载页。")

	await create_timer(1.70, true, false, true).timeout
	_assert_true(loading.modulate.a >= 0.98, "完整可见的 2 秒停留结束前不得开始渐出。")
	_assert_true(not _has_finished, "2 秒完整停留结束前不得发出完成信号。")

	await create_timer(0.85, true, false, true).timeout
	var elapsed_seconds: float = float(Time.get_ticks_msec() - started_at_msec) / 1000.0
	_assert_true(_has_finished, "0.5 秒渐出结束后必须发出完成信号。")
	_assert_true(elapsed_seconds >= 2.9 and elapsed_seconds <= 3.6, "真实加载过渡总时长应约为 3 秒，实际 %.3f 秒。" % elapsed_seconds)
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
