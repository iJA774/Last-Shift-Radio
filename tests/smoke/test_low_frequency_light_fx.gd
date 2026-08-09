extends SceneTree

const LIGHT_FX_SCENE: PackedScene = preload("res://scenes/ui/fx/low_frequency_light_fx.tscn")

var _has_failed: bool = false
var _state_transitions: Array[bool] = []


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture: Dictionary = _create_switch_fixture("Primary")
	var light_fx: Control = fixture["switch"] as Control
	var light_rect: TextureRect = fixture["light_rect"] as TextureRect
	var off_rect: TextureRect = fixture["off_rect"] as TextureRect
	light_fx.connect(&"light_state_changed", _on_light_state_changed)
	await process_frame

	_assert_true(not (light_fx is ColorRect), "背景灯光组件不得使用全屏 ColorRect 光晕层。")
	var initial: Dictionary = _snapshot(light_fx)
	_assert_true(bool(initial["is_configured"]), "背景灯光组件必须绑定一对 TextureRect。")
	_assert_true(float(initial["minimum_wait_seconds"]) >= 3.0, "自动异常最短间隔不得低于 3 秒。")
	_assert_true(float(initial["maximum_wait_seconds"]) >= float(initial["minimum_wait_seconds"]), "最大等待时间不得短于最小等待时间。")
	_assert_true(int(initial["minimum_burst_flickers"]) >= 3, "每次老旧电路异常至少包含三次快速断电。")
	_assert_true(bool(initial["schedule_timer_is_running"]), "启用动态后必须等待下一次灯光异常。")
	_assert_true(bool(initial["is_lit"]) and light_rect.visible and not off_rect.visible, "初始状态必须稳定显示亮灯素材。")

	var light_texture: GradientTexture2D = GradientTexture2D.new()
	var off_texture: GradientTexture2D = GradientTexture2D.new()
	var texture_result: Dictionary = light_fx.call(&"set_textures", light_texture, off_texture) as Dictionary
	_assert_true(bool(texture_result.get("ok", false)), "组件必须接受亮/灭纹理注入。")
	_assert_true(light_rect.texture == light_texture and off_rect.texture == off_texture, "注入纹理必须写入对应 TextureRect。")

	_state_transitions.clear()
	var trigger_result: Dictionary = light_fx.call(&"trigger_flicker_for_verification") as Dictionary
	_assert_true(bool(trigger_result.get("ok", false)), "验证接口必须能确定性触发一组快速连闪。")
	await process_frame
	var during: Dictionary = _snapshot(light_fx)
	_assert_true(int(during["flicker_count"]) == 1, "一组异常只能计为一次触发。")
	_assert_true(int(during["burst_flicker_count"]) >= 3, "一次异常必须包含多次快速断电。")
	_assert_true(not bool(during["is_lit"]) and not light_rect.visible and off_rect.visible, "连闪开始必须切换到局部灭灯素材。")
	_assert_true(bool(during["off_timer_is_running"]), "每次断电必须由短时 Timer 控制。")
	await create_timer(1.6).timeout
	var after: Dictionary = _snapshot(light_fx)
	_assert_true(bool(after["is_lit"]) and light_rect.visible and not off_rect.visible, "连闪完成后必须恢复稳定亮灯素材。")
	_assert_true(int(after["remaining_burst_flickers"]) == 0, "连闪完成后不得遗留未执行断电次数。")
	_assert_true(_state_transitions.count(false) >= int(during["burst_flicker_count"]), "状态信号必须记录每一次快速灭灯。")
	_assert_true(_state_transitions.count(true) >= int(during["burst_flicker_count"]), "状态信号必须记录每一次快速恢复亮灯。")
	_assert_true(bool(after["schedule_timer_is_running"]) and not bool(after["off_timer_is_running"]) and not bool(after["on_gap_timer_is_running"]), "连闪完成后必须重新等待下一次异常。")

	var disable_result: Dictionary = light_fx.call(&"set_motion_enabled", false) as Dictionary
	_assert_true(bool(disable_result.get("ok", false)), "必须能关闭灯光异常动态。")
	var disabled: Dictionary = _snapshot(light_fx)
	_assert_true(not bool(disabled["schedule_timer_is_running"]) and not bool(disabled["off_timer_is_running"]) and not bool(disabled["on_gap_timer_is_running"]), "减少动态后不得保留任何灯光 Timer。")
	_assert_true(bool(disabled["is_lit"]) and light_rect.visible and not off_rect.visible, "减少动态后必须稳定回亮灯素材。")
	var rejected: Dictionary = light_fx.call(&"trigger_flicker_for_verification") as Dictionary
	_assert_true(not bool(rejected.get("ok", false)), "减少动态时必须拒绝灯光异常触发。")

	var enable_result: Dictionary = light_fx.call(&"set_motion_enabled", true) as Dictionary
	_assert_true(bool(enable_result.get("ok", false)), "必须能恢复背景灯光异常动态。")
	_assert_true(bool(_snapshot(light_fx)["schedule_timer_is_running"]), "恢复动态后必须重新等待下一次异常。")
	_test_seed_is_reproducible()

	_cleanup(fixture)
	await process_frame
	if _has_failed:
		print("[测试][LowFrequencyLightFx] 失败。")
		quit(1)
		return
	print("[测试][LowFrequencyLightFx] 通过：快速连闪、频率、纹理注入、固定 seed 与减少动态契约成立。")
	quit(0)


func _test_seed_is_reproducible() -> void:
	var first_fixture: Dictionary = _create_switch_fixture("SeedFirst")
	var second_fixture: Dictionary = _create_switch_fixture("SeedSecond")
	var first_switch: Control = first_fixture["switch"] as Control
	var second_switch: Control = second_fixture["switch"] as Control
	var first_result: Dictionary = first_switch.call(&"set_random_seed", 31415) as Dictionary
	var second_result: Dictionary = second_switch.call(&"set_random_seed", 31415) as Dictionary
	_assert_true(bool(first_result.get("ok", false)) and bool(second_result.get("ok", false)), "组件必须接受可复现的随机 seed。")
	var first_snapshot: Dictionary = _snapshot(first_switch)
	var second_snapshot: Dictionary = _snapshot(second_switch)
	_assert_true(is_equal_approx(float(first_snapshot["last_wait_seconds"]), float(second_snapshot["last_wait_seconds"])), "相同 seed 必须安排相同的下一次异常等待时间。")
	_cleanup(first_fixture)
	_cleanup(second_fixture)


func _create_switch_fixture(prefix: String) -> Dictionary:
	var host: Control = Control.new()
	host.name = "%sHost" % prefix
	root.add_child(host)
	var light_rect: TextureRect = TextureRect.new()
	light_rect.name = "LightTexture"
	var off_rect: TextureRect = TextureRect.new()
	off_rect.name = "OffTexture"
	host.add_child(light_rect)
	host.add_child(off_rect)
	var light_fx: Control = LIGHT_FX_SCENE.instantiate() as Control
	light_fx.set("light_texture_rect_path", NodePath("../LightTexture"))
	light_fx.set("off_texture_rect_path", NodePath("../OffTexture"))
	host.add_child(light_fx)
	return {"host": host, "switch": light_fx, "light_rect": light_rect, "off_rect": off_rect}


func _snapshot(light_fx: Control) -> Dictionary:
	var snapshot: Variant = light_fx.call(&"get_effect_snapshot")
	if snapshot is Dictionary:
		return snapshot as Dictionary
	_has_failed = true
	push_error("[测试][LowFrequencyLightFx] get_effect_snapshot() 未返回 Dictionary。")
	return {}


func _on_light_state_changed(is_lit: bool, _flicker_count: int) -> void:
	_state_transitions.append(is_lit)


func _cleanup(fixture: Dictionary) -> void:
	var host: Control = fixture.get("host") as Control
	if is_instance_valid(host):
		host.queue_free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][LowFrequencyLightFx] %s" % message)
