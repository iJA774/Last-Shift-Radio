class_name LowFrequencyLightFx
extends Control
## 老旧电路的局部灯光故障表现。
##
## 组件只控制一对局部状态 TextureRect，不改变背景、剧情或输入状态。
## 每次异常由 3 至 5 次短促断电组成；减少动态时立即回到稳定亮灯状态。

signal light_state_changed(is_lit: bool, flicker_count: int)

@export_node_path("TextureRect") var light_texture_rect_path: NodePath
@export_node_path("TextureRect") var off_texture_rect_path: NodePath
@export var light_texture: Texture2D
@export var off_texture: Texture2D
@export_range(3.0, 90.0, 0.1) var minimum_wait_seconds: float = 4.0
@export_range(3.0, 120.0, 0.1) var maximum_wait_seconds: float = 9.0
@export_range(0.045, 0.16, 0.005) var minimum_off_seconds: float = 0.055
@export_range(0.045, 0.16, 0.005) var maximum_off_seconds: float = 0.11
@export_range(0.045, 0.22, 0.005) var minimum_on_gap_seconds: float = 0.06
@export_range(0.045, 0.22, 0.005) var maximum_on_gap_seconds: float = 0.14
@export_range(3, 6, 1) var minimum_burst_flickers: int = 3
@export_range(3, 6, 1) var maximum_burst_flickers: int = 5
@export var random_seed: int = 1999

var _is_motion_enabled: bool = true
var _schedule_timer: Timer = null
var _off_timer: Timer = null
var _on_gap_timer: Timer = null
var _random: RandomNumberGenerator = RandomNumberGenerator.new()
var _light_texture_rect: TextureRect = null
var _off_texture_rect: TextureRect = null
var _flicker_count: int = 0
var _burst_flicker_count: int = 0
var _remaining_burst_flickers: int = 0
var _last_wait_seconds: float = 0.0
var _last_off_seconds: float = 0.0
var _last_on_gap_seconds: float = 0.0
var _is_lit: bool = true
var _is_configured: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_random.seed = random_seed
	_schedule_timer = _create_one_shot_timer(_on_schedule_timer_timeout)
	_off_timer = _create_one_shot_timer(_on_off_timer_timeout)
	_on_gap_timer = _create_one_shot_timer(_on_on_gap_timer_timeout)
	var target_result: Dictionary = _resolve_exported_texture_rects()
	if not bool(target_result.get("ok", false)):
		push_error("[背景灯光][target_missing] %s" % String(target_result.get("message", "缺少亮灭素材目标。")))
		return
	_apply_injected_textures()
	_is_configured = true
	_apply_lit_state(true)
	_schedule_next_switch()


## 可在场景脚本或测试中直接注入一对 TextureRect；两者必须是不同节点。
func set_texture_rects(light_rect: TextureRect, off_rect: TextureRect) -> Dictionary:
	if light_rect == null or off_rect == null:
		return _make_error("invalid_texture_rect", "亮灯与灭灯 TextureRect 均不能为空。")
	if light_rect == off_rect:
		return _make_error("invalid_texture_rect", "亮灯与灭灯 TextureRect 必须是不同节点。")
	_light_texture_rect = light_rect
	_off_texture_rect = off_rect
	_is_configured = true
	_apply_injected_textures()
	_stop_timers()
	_apply_lit_state(true)
	if is_inside_tree() and _is_motion_enabled:
		_schedule_next_switch()
	return {"ok": true, "target_mode": "texture_rects"}


func set_textures(light_texture_resource: Texture2D, off_texture_resource: Texture2D) -> Dictionary:
	if light_texture_resource == null or off_texture_resource == null:
		return _make_error("invalid_texture", "亮灯与灭灯纹理均不能为空。")
	light_texture = light_texture_resource
	off_texture = off_texture_resource
	_apply_injected_textures()
	return {"ok": true, "target_mode": "textures"}


func configure_texture_rects(light_rect: TextureRect, off_rect: TextureRect) -> Dictionary:
	return set_texture_rects(light_rect, off_rect)


func configure_textures(light_texture_resource: Texture2D, off_texture_resource: Texture2D) -> Dictionary:
	return set_textures(light_texture_resource, off_texture_resource)


func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	_stop_timers()
	if not _is_configured:
		return _make_error("target_missing", "背景亮灭组件尚未绑定亮灯与灭灯 TextureRect。")
	_apply_lit_state(true)
	if _is_motion_enabled:
		_schedule_next_switch()
	return {"ok": true, "motion_enabled": _is_motion_enabled}


func is_motion_enabled() -> bool:
	return _is_motion_enabled


## 只供确定性视觉/Headless 验收触发一整组老旧电路式连闪。
func trigger_flicker_for_verification() -> Dictionary:
	if not _is_motion_enabled:
		return _make_error("motion_disabled", "减少动态已启用，不能触发背景灯光异常。")
	if not _is_configured:
		return _make_error("target_missing", "背景亮灭组件尚未绑定亮灯与灭灯 TextureRect。")
	if not _is_lit or _remaining_burst_flickers > 0:
		return _make_error("already_flickering", "背景灯光当前已处于异常连闪中。")
	_begin_flicker_burst()
	return {"ok": true, "burst_flicker_count": _burst_flicker_count}


func set_random_seed(new_seed: int) -> Dictionary:
	random_seed = new_seed
	_random.seed = random_seed
	_stop_timers()
	if _is_configured:
		_apply_lit_state(true)
		if _is_motion_enabled:
			_schedule_next_switch()
	return {"ok": true, "random_seed": random_seed}


func get_effect_snapshot() -> Dictionary:
	return {
		"motion_enabled": _is_motion_enabled,
		"minimum_wait_seconds": minimum_wait_seconds,
		"maximum_wait_seconds": maximum_wait_seconds,
		"minimum_off_seconds": minimum_off_seconds,
		"maximum_off_seconds": maximum_off_seconds,
		"minimum_on_gap_seconds": minimum_on_gap_seconds,
		"maximum_on_gap_seconds": maximum_on_gap_seconds,
		"minimum_burst_flickers": minimum_burst_flickers,
		"maximum_burst_flickers": maximum_burst_flickers,
		"last_wait_seconds": _last_wait_seconds,
		"last_off_seconds": _last_off_seconds,
		"last_on_gap_seconds": _last_on_gap_seconds,
		"flicker_count": _flicker_count,
		"burst_flicker_count": _burst_flicker_count,
		"remaining_burst_flickers": _remaining_burst_flickers,
		"is_lit": _is_lit,
		"target_mode": "texture_rects",
		"light_texture_rect_path": light_texture_rect_path,
		"off_texture_rect_path": off_texture_rect_path,
		"is_configured": _is_configured,
		"schedule_timer_is_running": _schedule_timer != null and not _schedule_timer.is_stopped(),
		"off_timer_is_running": _off_timer != null and not _off_timer.is_stopped(),
		"on_gap_timer_is_running": _on_gap_timer != null and not _on_gap_timer.is_stopped(),
	}


func _create_one_shot_timer(timeout_callable: Callable) -> Timer:
	var timer: Timer = Timer.new()
	timer.one_shot = true
	timer.process_callback = Timer.TIMER_PROCESS_IDLE
	add_child(timer)
	timer.timeout.connect(timeout_callable)
	return timer


func _resolve_exported_texture_rects() -> Dictionary:
	if not light_texture_rect_path.is_empty():
		_light_texture_rect = get_node_or_null(light_texture_rect_path) as TextureRect
	if not off_texture_rect_path.is_empty():
		_off_texture_rect = get_node_or_null(off_texture_rect_path) as TextureRect
	if _light_texture_rect == null or _off_texture_rect == null:
		return _make_error("target_missing", "场景必须提供亮灯与灭灯 TextureRect 引用路径。")
	if _light_texture_rect == _off_texture_rect:
		return _make_error("invalid_texture_rect", "亮灯与灭灯 TextureRect 必须是不同节点。")
	return {"ok": true}


func _apply_injected_textures() -> void:
	if _light_texture_rect == null or _off_texture_rect == null:
		return
	if light_texture != null:
		_light_texture_rect.texture = light_texture
	if off_texture != null:
		_off_texture_rect.texture = off_texture


func _on_schedule_timer_timeout() -> void:
	if _is_motion_enabled and _is_configured:
		_begin_flicker_burst()


func _begin_flicker_burst() -> void:
	_stop_timers()
	_burst_flicker_count = _random.randi_range(minimum_burst_flickers, maximum_burst_flickers)
	_remaining_burst_flickers = _burst_flicker_count
	_flicker_count += 1
	_begin_off_phase()


func _begin_off_phase() -> void:
	if not _is_motion_enabled or _remaining_burst_flickers <= 0:
		_finish_burst()
		return
	_last_off_seconds = _random.randf_range(minimum_off_seconds, maximum_off_seconds)
	_apply_lit_state(false)
	_off_timer.start(_last_off_seconds)


func _on_off_timer_timeout() -> void:
	if not _is_motion_enabled or not _is_configured:
		return
	_apply_lit_state(true)
	_remaining_burst_flickers -= 1
	if _remaining_burst_flickers <= 0:
		_finish_burst()
		return
	_last_on_gap_seconds = _random.randf_range(minimum_on_gap_seconds, maximum_on_gap_seconds)
	_on_gap_timer.start(_last_on_gap_seconds)


func _on_on_gap_timer_timeout() -> void:
	if _is_motion_enabled and _is_configured:
		_begin_off_phase()


func _finish_burst() -> void:
	_remaining_burst_flickers = 0
	_apply_lit_state(true)
	if _is_motion_enabled and _is_configured:
		_schedule_next_switch()


func _schedule_next_switch() -> void:
	if not _is_motion_enabled or not _is_configured or _schedule_timer == null:
		return
	var validation_result: Dictionary = _validate_intervals()
	if not bool(validation_result.get("ok", false)):
		push_error("[背景灯光][invalid_interval] %s" % String(validation_result.get("message", "无效亮灭间隔。")))
		return
	_last_wait_seconds = _random.randf_range(minimum_wait_seconds, maximum_wait_seconds)
	_schedule_timer.start(_last_wait_seconds)


func _validate_intervals() -> Dictionary:
	if minimum_wait_seconds < 3.0 or maximum_wait_seconds < minimum_wait_seconds:
		return _make_error("invalid_interval", "自动异常间隔必须满足 3 <= minimum <= maximum。")
	if minimum_off_seconds < 0.045 or maximum_off_seconds > 0.16 or maximum_off_seconds < minimum_off_seconds:
		return _make_error("invalid_off_duration", "每次断电时长必须满足 0.045 <= minimum <= maximum <= 0.16 秒。")
	if minimum_on_gap_seconds < 0.045 or maximum_on_gap_seconds > 0.22 or maximum_on_gap_seconds < minimum_on_gap_seconds:
		return _make_error("invalid_on_gap", "连闪间隔必须满足 0.045 <= minimum <= maximum <= 0.22 秒。")
	if minimum_burst_flickers < 3 or maximum_burst_flickers < minimum_burst_flickers:
		return _make_error("invalid_burst_count", "连闪次数必须满足 3 <= minimum <= maximum。")
	return {"ok": true}


func _stop_timers() -> void:
	if _schedule_timer != null:
		_schedule_timer.stop()
	if _off_timer != null:
		_off_timer.stop()
	if _on_gap_timer != null:
		_on_gap_timer.stop()
	_remaining_burst_flickers = 0


func _apply_lit_state(is_lit: bool) -> void:
	_is_lit = is_lit
	if _light_texture_rect != null:
		_light_texture_rect.visible = is_lit
	if _off_texture_rect != null:
		_off_texture_rect.visible = not is_lit
	light_state_changed.emit(_is_lit, _flicker_count)


func _make_error(error_code: String, message: String) -> Dictionary:
	printerr("[背景灯光][%s] %s" % [error_code, message])
	return {"ok": false, "error_code": error_code, "message": message}
