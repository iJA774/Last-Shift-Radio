## 固定室内视图可复用的克制环境效果层。
##
## 本组件只绘制室内浮尘与设备指示灯脉冲，不读取剧情、时间或电话状态，
## 也不会接收鼠标输入。窗外程序化雨线和水滴已经移除；需要的亮灭变化
## 由独立的背景素材切换组件负责。随机元素由可注入 seed 一次性生成，
## 以便验证和复现画面，而不是在每帧引入不可追踪的随机变化。
class_name AmbientFx
extends Control

signal motion_enabled_changed(is_enabled: bool)
signal profile_changed(profile_id: String)

const PROFILE_STUDIO: String = "studio"
const PROFILE_EQUIPMENT: String = "equipment"

const DEFAULT_RANDOM_SEED: int = 1999

const STUDIO_DUST_COUNT: int = 18
const EQUIPMENT_DUST_COUNT: int = 8
const STUDIO_INDICATOR_COUNT: int = 2
const EQUIPMENT_INDICATOR_COUNT: int = 4

const SUPPORTED_PROFILES: PackedStringArray = [
	PROFILE_STUDIO,
	PROFILE_EQUIPMENT,
]

@export_enum("studio", "equipment") var profile_id: String = PROFILE_STUDIO
@export var random_seed: int = DEFAULT_RANDOM_SEED
@export var motion_enabled: bool = true

var _elapsed_seconds: float = 0.0
var _dust_marks: Array[Dictionary] = []
var _indicator_marks: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild_marks()
	_apply_motion_state()


func _process(delta: float) -> void:
	_elapsed_seconds = fmod(_elapsed_seconds + maxf(delta, 0.0), 3_600.0)
	queue_redraw()


## 关闭后会隐藏本层并停止 _process；Control 的尺寸、锚点和鼠标穿透属性不变。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	motion_enabled = is_enabled
	_apply_motion_state()
	motion_enabled_changed.emit(motion_enabled)
	return {"ok": true, "motion_enabled": motion_enabled}


func is_motion_enabled() -> bool:
	return motion_enabled


## 切换仅限两种室内低成本效果组合，拒绝已移除的雨天配置以避免静默复活雨层。
func set_profile(new_profile_id: String) -> Dictionary:
	if not SUPPORTED_PROFILES.has(new_profile_id):
		return _make_error("invalid_profile", "未知或已移除的环境效果配置：%s。" % new_profile_id)
	profile_id = new_profile_id
	_elapsed_seconds = 0.0
	_rebuild_marks()
	queue_redraw()
	profile_changed.emit(profile_id)
	return {"ok": true, "profile_id": profile_id}


func get_profile() -> String:
	return profile_id


## 相同 seed 与 profile 必须重建出相同位置和相位，供 Headless 冒烟测试复现。
func set_random_seed(new_seed: int) -> Dictionary:
	random_seed = new_seed
	_elapsed_seconds = 0.0
	_rebuild_marks()
	queue_redraw()
	return {"ok": true, "random_seed": random_seed}


## 仅返回深拷贝的只读观测数据；上层不应把它当作剧情或输入状态。
func get_effect_snapshot() -> Dictionary:
	return {
		"profile_id": profile_id,
		"random_seed": random_seed,
		"motion_enabled": motion_enabled,
		"is_processing": is_processing(),
		"is_visible": visible,
		"dust_marks": _dust_marks.duplicate(true),
		"indicator_marks": _indicator_marks.duplicate(true),
	}


func _draw() -> void:
	if not motion_enabled:
		return
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_draw_indoor_atmosphere()


func _apply_motion_state() -> void:
	visible = motion_enabled
	set_process(motion_enabled)
	queue_redraw()


func _rebuild_marks() -> void:
	_dust_marks.clear()
	_indicator_marks.clear()

	var random: RandomNumberGenerator = RandomNumberGenerator.new()
	random.seed = random_seed
	match profile_id:
		PROFILE_STUDIO:
			_create_dust_marks(random, STUDIO_DUST_COUNT)
			_create_indicator_marks(random, STUDIO_INDICATOR_COUNT)
		PROFILE_EQUIPMENT:
			_create_dust_marks(random, EQUIPMENT_DUST_COUNT)
			_create_indicator_marks(random, EQUIPMENT_INDICATOR_COUNT)
		_:
			# 导出属性或错误场景文件可能绕过 set_profile，仍需清楚降级为无效果。
			push_error("[环境效果][invalid_profile] 未知或已移除的环境效果配置：%s。" % profile_id)


func _create_dust_marks(random: RandomNumberGenerator, count: int) -> void:
	for index: int in count:
		_dust_marks.append({
			"x_ratio": random.randf_range(0.05, 0.95),
			"y_ratio": random.randf_range(0.09, 0.91),
			"speed": random.randf_range(0.004, 0.012),
			"drift": random.randf_range(0.006, 0.018),
			"radius": random.randf_range(0.65, 1.35),
			"alpha": random.randf_range(0.025, 0.065),
			"phase": float(index) * 0.113,
		})


func _create_indicator_marks(random: RandomNumberGenerator, count: int) -> void:
	for _index: int in count:
		_indicator_marks.append({
			"x_ratio": random.randf_range(0.12, 0.88),
			"y_ratio": random.randf_range(0.16, 0.84),
			"period_seconds": random.randf_range(5.5, 10.0),
			"phase": random.randf_range(0.0, TAU),
			"radius": random.randf_range(1.1, 2.2),
		})


func _draw_indoor_atmosphere() -> void:
	for mark: Dictionary in _dust_marks:
		var drift_x: float = sin(_elapsed_seconds * float(mark["speed"]) * TAU + float(mark["phase"])) * float(mark["drift"])
		var drift_y: float = cos(_elapsed_seconds * float(mark["speed"]) * TAU + float(mark["phase"])) * float(mark["drift"]) * 0.35
		var center := Vector2(
			fposmod(float(mark["x_ratio"]) + drift_x, 1.0) * size.x,
			fposmod(float(mark["y_ratio"]) + drift_y, 1.0) * size.y
		)
		draw_circle(center, float(mark["radius"]), Color(0.84, 0.78, 0.58, float(mark["alpha"])), true, -1.0, true)

	for mark: Dictionary in _indicator_marks:
		var pulse: float = 0.5 + 0.5 * sin((_elapsed_seconds / float(mark["period_seconds"])) * TAU + float(mark["phase"]))
		var alpha: float = 0.035 + pulse * 0.065
		var center := Vector2(float(mark["x_ratio"]) * size.x, float(mark["y_ratio"]) * size.y)
		draw_circle(center, float(mark["radius"]), Color(0.75, 0.89, 0.56, alpha), true, -1.0, true)


func _make_error(error_code: String, message: String) -> Dictionary:
	printerr("[环境效果][%s] %s" % [error_code, message])
	return {"ok": false, "error_code": error_code, "message": message}
