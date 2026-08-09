extends SceneTree

const WINDOW_RAIN_SCENE: PackedScene = preload("res://scenes/ui/fx/window_rain_fx.tscn")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var rain_fx: Control = WINDOW_RAIN_SCENE.instantiate() as Control
	_assert_true(rain_fx != null, "窗外雨幕场景必须可实例化。")
	if rain_fx == null:
		_finish()
		return
	rain_fx.size = Vector2(784.0, 447.0)
	root.add_child(rain_fx)
	await process_frame
	var initial: Dictionary = _snapshot(rain_fx)
	_assert_true(rain_fx.mouse_filter == Control.MOUSE_FILTER_IGNORE, "窗外雨幕不得接收鼠标输入。")
	_assert_true(bool(initial.get("motion_enabled", false)) and bool(initial.get("is_processing", false)), "默认窗外雨幕必须在运行。")
	_assert_true((initial.get("far_rain_marks", []) as Array).size() == 34, "雨幕必须保留受限的远景雨线数量。")
	_assert_true((initial.get("near_rain_marks", []) as Array).size() == 15, "雨幕必须保留受限的近景雨线数量。")
	var seed_result: Dictionary = rain_fx.call(&"set_random_seed", 742) as Dictionary
	_assert_true(bool(seed_result.get("ok", false)), "窗外雨幕必须接受确定性随机种子。")
	var seeded: Dictionary = _snapshot(rain_fx)
	var second_fx: Control = WINDOW_RAIN_SCENE.instantiate() as Control
	second_fx.size = rain_fx.size
	root.add_child(second_fx)
	await process_frame
	second_fx.call(&"set_random_seed", 742)
	var second_seeded: Dictionary = _snapshot(second_fx)
	_assert_true(seeded.get("far_rain_marks", []) == second_seeded.get("far_rain_marks", []), "相同种子必须生成相同远景雨线。")
	_assert_true(seeded.get("near_rain_marks", []) == second_seeded.get("near_rain_marks", []), "相同种子必须生成相同近景雨线。")
	var disabled_result: Dictionary = rain_fx.call(&"set_motion_enabled", false) as Dictionary
	_assert_true(bool(disabled_result.get("ok", false)), "必须能关闭窗外雨幕动态。")
	var disabled: Dictionary = _snapshot(rain_fx)
	_assert_true(not bool(disabled.get("is_visible", true)) and not bool(disabled.get("is_processing", true)), "减少动态后窗外雨幕必须隐藏并停止处理。")
	var enabled_result: Dictionary = rain_fx.call(&"set_motion_enabled", true) as Dictionary
	_assert_true(bool(enabled_result.get("ok", false)), "必须能恢复窗外雨幕动态。")
	var enabled: Dictionary = _snapshot(rain_fx)
	_assert_true(bool(enabled.get("is_visible", false)) and bool(enabled.get("is_processing", false)), "恢复动态后窗外雨幕必须重新显示并处理。")
	rain_fx.queue_free()
	second_fx.queue_free()
	await process_frame
	_finish()


func _snapshot(rain_fx: Control) -> Dictionary:
	var snapshot: Variant = rain_fx.call(&"get_effect_snapshot")
	if snapshot is Dictionary:
		return snapshot as Dictionary
	_has_failed = true
	push_error("[测试][WindowRainFx] get_effect_snapshot() 未返回 Dictionary。")
	return {}


func _finish() -> void:
	if _has_failed:
		print("[测试][WindowRainFx] 失败。")
		quit(1)
		return
	print("[测试][WindowRainFx] 通过：分层雨线、固定 seed 与减少动态契约成立。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][WindowRainFx] %s" % message)
