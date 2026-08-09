extends SceneTree

## 环境效果只验证室内组件契约与确定性，不依赖四视图或 StoryEngine。
## 窗外程序化雨层已移除，不允许再接受 door_window 配置。

const AMBIENT_FX_SCENE: PackedScene = preload("res://scenes/ui/fx/ambient_fx.tscn")
const PROFILE_STUDIO: String = "studio"
const PROFILE_EQUIPMENT: String = "equipment"
const STUDIO_DUST_COUNT: int = 18
const EQUIPMENT_DUST_COUNT: int = 8
const STUDIO_INDICATOR_COUNT: int = 2
const EQUIPMENT_INDICATOR_COUNT: int = 4

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	_test_default_scene_contract()
	_test_profiles_have_bounded_effect_sets()
	_test_seed_is_deterministic()
	_test_motion_toggle_stops_and_clears()
	_test_removed_and_invalid_profiles_are_rejected()

	if _has_failed:
		print("[测试][AmbientFx] 失败。")
		quit(1)
		return
	print("[测试][AmbientFx] 通过：固定 seed、两种室内效果配置、减少动态与雨层移除契约成立。")
	quit(0)


func _test_default_scene_contract() -> void:
	var ambient_fx: Control = _create_fx()
	_assert_equal(ambient_fx.mouse_filter, Control.MOUSE_FILTER_IGNORE, "环境效果层必须鼠标穿透。")
	_assert_equal(ambient_fx.size, Vector2(1920.0, 1080.0), "环境效果层必须随宿主填满 1920×1080 视图。")
	_assert_equal(String(ambient_fx.call(&"get_profile")), PROFILE_STUDIO, "默认场景必须使用 studio 配置。")
	_assert_true(bool(ambient_fx.call(&"is_motion_enabled")), "默认场景必须启用动态效果。")
	_assert_true(ambient_fx.is_processing(), "启用动态效果时必须处理动画。")
	_cleanup(ambient_fx)


func _test_profiles_have_bounded_effect_sets() -> void:
	var ambient_fx: Control = _create_fx()
	_assert_ok(_set_profile(ambient_fx, PROFILE_STUDIO), "工作室配置必须可设置。")
	var studio_snapshot: Dictionary = _snapshot(ambient_fx)
	_assert_true(not studio_snapshot.has("rain_marks") and not studio_snapshot.has("drip_marks"), "室内 AmbientFx 快照不得保留雨线或水滴字段。")
	_assert_equal((studio_snapshot["dust_marks"] as Array).size(), STUDIO_DUST_COUNT, "工作室浮尘数量必须受限。")
	_assert_equal((studio_snapshot["indicator_marks"] as Array).size(), STUDIO_INDICATOR_COUNT, "工作室指示灯数量必须受限。")

	_assert_ok(_set_profile(ambient_fx, PROFILE_EQUIPMENT), "设备配置必须可设置。")
	var equipment_snapshot: Dictionary = _snapshot(ambient_fx)
	_assert_equal((equipment_snapshot["dust_marks"] as Array).size(), EQUIPMENT_DUST_COUNT, "设备配置浮尘数量必须受限。")
	_assert_equal((equipment_snapshot["indicator_marks"] as Array).size(), EQUIPMENT_INDICATOR_COUNT, "设备配置灯光数量必须受限。")
	_cleanup(ambient_fx)


func _test_seed_is_deterministic() -> void:
	var first_fx: Control = _create_fx()
	var second_fx: Control = _create_fx()
	_assert_ok(_set_profile(first_fx, PROFILE_STUDIO), "第一个实例必须可设置工作室配置。")
	_assert_ok(_set_profile(second_fx, PROFILE_STUDIO), "第二个实例必须可设置工作室配置。")
	_assert_ok(_set_seed(first_fx, 31415), "第一个实例必须接受测试 seed。")
	_assert_ok(_set_seed(second_fx, 31415), "第二个实例必须接受测试 seed。")
	var first_snapshot: Dictionary = _snapshot(first_fx)
	var second_snapshot: Dictionary = _snapshot(second_fx)
	_assert_equal(first_snapshot["dust_marks"], second_snapshot["dust_marks"], "相同 seed 必须生成相同室内浮尘。")
	_assert_equal(first_snapshot["indicator_marks"], second_snapshot["indicator_marks"], "相同 seed 必须生成相同指示灯。")
	_assert_ok(_set_seed(second_fx, 27182), "实例必须允许切换测试 seed。")
	var changed_snapshot: Dictionary = _snapshot(second_fx)
	_assert_true(first_snapshot["dust_marks"] != changed_snapshot["dust_marks"], "不同 seed 不应复用相同室内浮尘。")
	_cleanup(first_fx)
	_cleanup(second_fx)


func _test_motion_toggle_stops_and_clears() -> void:
	var ambient_fx: Control = _create_fx()
	_assert_ok(_set_motion_enabled(ambient_fx, false), "关闭动态效果必须成功。")
	var disabled_snapshot: Dictionary = _snapshot(ambient_fx)
	_assert_true(not bool(disabled_snapshot["motion_enabled"]), "关闭后状态必须为 false。")
	_assert_true(not bool(disabled_snapshot["is_processing"]), "关闭后必须停止 _process。")
	_assert_true(not bool(disabled_snapshot["is_visible"]), "关闭后必须清空可见效果层。")
	_assert_equal(ambient_fx.mouse_filter, Control.MOUSE_FILTER_IGNORE, "关闭效果不得改变鼠标穿透。")

	_assert_ok(_set_motion_enabled(ambient_fx, true), "重新开启动态效果必须成功。")
	var enabled_snapshot: Dictionary = _snapshot(ambient_fx)
	_assert_true(bool(enabled_snapshot["is_processing"]), "重新开启后必须恢复 _process。")
	_assert_true(bool(enabled_snapshot["is_visible"]), "重新开启后必须恢复效果层可见性。")
	_cleanup(ambient_fx)


func _test_removed_and_invalid_profiles_are_rejected() -> void:
	var ambient_fx: Control = _create_fx()
	var removed_result: Dictionary = _set_profile(ambient_fx, "door_window")
	_assert_true(not bool(removed_result.get("ok", false)), "已移除的门窗雨层配置必须明确拒绝。")
	_assert_equal(String(removed_result.get("error_code", "")), "invalid_profile", "已移除的雨层配置必须返回稳定错误码。")
	var invalid_result: Dictionary = _set_profile(ambient_fx, "unknown_profile")
	_assert_true(not bool(invalid_result.get("ok", false)), "未知配置必须明确拒绝。")
	_assert_equal(String(invalid_result.get("error_code", "")), "invalid_profile", "未知配置必须返回稳定错误码。")
	_cleanup(ambient_fx)


func _create_fx() -> Control:
	var host: Control = Control.new()
	host.size = Vector2(1920.0, 1080.0)
	root.add_child(host)
	var ambient_fx: Control = AMBIENT_FX_SCENE.instantiate() as Control
	host.add_child(ambient_fx)
	return ambient_fx


func _snapshot(ambient_fx: Control) -> Dictionary:
	var snapshot: Variant = ambient_fx.call(&"get_effect_snapshot")
	if snapshot is Dictionary:
		return snapshot as Dictionary
	push_error("[测试][AmbientFx] get_effect_snapshot() 未返回 Dictionary。")
	_has_failed = true
	return {}


func _set_profile(ambient_fx: Control, profile_id: String) -> Dictionary:
	return ambient_fx.call(&"set_profile", profile_id) as Dictionary


func _set_seed(ambient_fx: Control, seed: int) -> Dictionary:
	return ambient_fx.call(&"set_random_seed", seed) as Dictionary


func _set_motion_enabled(ambient_fx: Control, is_enabled: bool) -> Dictionary:
	return ambient_fx.call(&"set_motion_enabled", is_enabled) as Dictionary


func _cleanup(ambient_fx: Control) -> void:
	if not is_instance_valid(ambient_fx):
		return
	var host: Node = ambient_fx.get_parent()
	if is_instance_valid(host):
		host.queue_free()


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][AmbientFx] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
