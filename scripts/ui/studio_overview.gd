class_name StudioOverview
extends Control
## 工作室总览只负责把三个明确的设备导航意图交给上层。
## 热点不持有电话或剧情状态，避免界面成为第二个剧情权威来源。

signal view_requested(view_id: String)

const VIEW_PHONE: String = "phone"
const VIEW_COMPUTER: String = "computer"
const VIEW_DOOR: String = "door"

const HOTSPOT_DEFAULT_TEXT: Dictionary[String, String] = {
	VIEW_PHONE: "查看电话",
	VIEW_COMPUTER: "使用电脑终端",
	VIEW_DOOR: "查看门与观察窗",
}

const HOTSPOT_DISABLED_TEXT: String = "不可用\n当前界面已锁定"

@onready var _phone_hotspot: Button = %PhoneHotspot
@onready var _computer_hotspot: Button = %ComputerHotspot
@onready var _door_hotspot: Button = %DoorHotspot
@onready var _phone_hint: PanelContainer = %PhoneHint
@onready var _computer_hint: PanelContainer = %ComputerHint
@onready var _door_hint: PanelContainer = %DoorHint
@onready var _phone_hint_label: Label = %PhoneHintLabel
@onready var _computer_hint_label: Label = %ComputerHintLabel
@onready var _door_hint_label: Label = %DoorHintLabel
@onready var _room_ambient_fx: Control = $AmbientFx
@onready var _window_rain_fx: Control = $WindowRainClip/WindowRainFx
@onready var _table_lamp_material_switch: Control = $TableLampMaterialSwitch

var _is_motion_enabled: bool = true


func _ready() -> void:
	_set_hotspot_state(VIEW_PHONE, true, "")
	_set_hotspot_state(VIEW_COMPUTER, true, "")
	_set_hotspot_state(VIEW_DOOR, true, "")
	_configure_ambient_fx()


## 由设置层传播“减少动态”状态，只影响视觉反馈，不改变导航或剧情真相。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	var motion_targets: Array[Control] = [
		_room_ambient_fx,
		_window_rain_fx,
		_table_lamp_material_switch,
	]
	for target: Control in motion_targets:
		if target == null or not target.has_method(&"set_motion_enabled"):
			return _make_error("工作室动态组件缺少 set_motion_enabled() 接口。")
		var result: Variant = target.call(&"set_motion_enabled", is_enabled)
		if not (result is Dictionary and bool((result as Dictionary).get("ok", false))):
			return _make_error("工作室动态组件拒绝切换动态状态：%s。" % str(result))
	return {"ok": true}


## 只读返回室内环境与台灯背景素材切换状态，供验证层确认画面契约。
func get_atmosphere_snapshot() -> Dictionary:
	if _room_ambient_fx == null or _window_rain_fx == null or _table_lamp_material_switch == null:
		return _make_error("工作室氛围组件尚未就绪。")
	return {
		"ok": true,
		"room_ambient": _room_ambient_fx.call(&"get_effect_snapshot"),
		"window_rain": _window_rain_fx.call(&"get_effect_snapshot"),
		"table_lamp": _table_lamp_material_switch.call(&"get_effect_snapshot"),
	}


## 返回固定的稳定目标，供上层和 Headless 验证使用。
func get_hotspot_targets() -> PackedStringArray:
	return PackedStringArray([VIEW_PHONE, VIEW_COMPUTER, VIEW_DOOR])


## 上层可在不可导航时提供明确的中文原因；总览不自行决定可用性。
func set_hotspot_enabled(view_id: String, is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not HOTSPOT_DEFAULT_TEXT.has(view_id):
		return _make_error("未知工作室热点目标：%s。" % view_id)
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用热点 %s 时必须提供中文原因。" % view_id)
	_set_hotspot_state(view_id, is_enabled, disabled_reason)
	return {"ok": true}


func _set_hotspot_state(view_id: String, is_enabled: bool, disabled_reason: String) -> void:
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot == null:
		push_error("[工作室][unknown_hotspot] 无法设置未知热点 %s。" % view_id)
		return
	hotspot.disabled = not is_enabled
	if is_enabled:
		hotspot.text = ""
		# 启用态已有紧邻设备的行动提示，避免再叠加 Godot 默认 tooltip 遮住画面。
		hotspot.tooltip_text = ""
		_set_hint(view_id, HOTSPOT_DEFAULT_TEXT[view_id], false)
		return
	hotspot.text = ""
	hotspot.tooltip_text = "不可用：%s" % disabled_reason
	_set_hint(view_id, HOTSPOT_DISABLED_TEXT, true)


func _get_hotspot(view_id: String) -> Button:
	match view_id:
		VIEW_PHONE:
			return _phone_hotspot
		VIEW_COMPUTER:
			return _computer_hotspot
		VIEW_DOOR:
			return _door_hotspot
	return null


func _on_phone_hotspot_pressed() -> void:
	_request_view(VIEW_PHONE)


func _on_computer_hotspot_pressed() -> void:
	_request_view(VIEW_COMPUTER)


func _on_door_hotspot_pressed() -> void:
	_request_view(VIEW_DOOR)


func _request_view(view_id: String) -> void:
	if not HOTSPOT_DEFAULT_TEXT.has(view_id):
		push_error("[工作室][invalid_view_request] 拒绝未知视图目标 %s。" % view_id)
		return
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot == null or hotspot.disabled:
		return
	view_requested.emit(view_id)


func _configure_ambient_fx() -> void:
	if _room_ambient_fx == null:
		push_error("[工作室][ambient_fx_missing] 缺少室内环境效果组件。")
		return
	if _window_rain_fx == null:
		push_error("[工作室][window_rain_missing] 缺少窗外雨幕组件。")
		return
	if not _room_ambient_fx.has_method(&"set_profile") or not _room_ambient_fx.has_method(&"set_random_seed"):
		push_error("[工作室][ambient_fx_contract] AmbientFx 缺少 set_profile() 或 set_random_seed() 接口。")
		return
	if not _window_rain_fx.has_method(&"set_motion_enabled") or not _window_rain_fx.has_method(&"set_random_seed"):
		push_error("[工作室][window_rain_contract] 窗外雨幕组件缺少动态或随机种子接口。")
		return
	if _table_lamp_material_switch == null or not _table_lamp_material_switch.has_method(&"set_motion_enabled"):
		push_error("[工作室][lamp_switch_contract] 台灯背景素材切换组件缺少 set_motion_enabled() 接口。")
		return
	_room_ambient_fx.call(&"set_profile", "studio")
	_room_ambient_fx.call(&"set_random_seed", 199901)
	_window_rain_fx.call(&"set_random_seed", 199904)
	var result: Dictionary = set_motion_enabled(_is_motion_enabled)
	if not bool(result.get("ok", false)):
		push_error("[工作室][ambient_fx_motion] %s" % String(result.get("message", "环境效果初始化失败。")))


func _set_hint(view_id: String, text: String, is_visible: bool) -> void:
	var hint: PanelContainer = _get_hint(view_id)
	var hint_label: Label = _get_hint_label(view_id)
	if hint == null or hint_label == null:
		push_error("[工作室][hotspot_hint_missing] 热点 %s 缺少行动提示控件。" % view_id)
		return
	hint_label.text = text
	hint.visible = is_visible


func _get_hint(view_id: String) -> PanelContainer:
	match view_id:
		VIEW_PHONE:
			return _phone_hint
		VIEW_COMPUTER:
			return _computer_hint
		VIEW_DOOR:
			return _door_hint
	return null


func _get_hint_label(view_id: String) -> Label:
	match view_id:
		VIEW_PHONE:
			return _phone_hint_label
		VIEW_COMPUTER:
			return _computer_hint_label
		VIEW_DOOR:
			return _door_hint_label
	return null


func _on_hotspot_mouse_entered(view_id: String) -> void:
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot != null and not hotspot.disabled:
		_set_hint(view_id, HOTSPOT_DEFAULT_TEXT[view_id], true)


func _on_hotspot_mouse_exited(view_id: String) -> void:
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot != null and not hotspot.disabled:
		_set_hint(view_id, HOTSPOT_DEFAULT_TEXT[view_id], false)


func _on_hotspot_button_down(view_id: String) -> void:
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot == null or hotspot.disabled:
		return
	hotspot.pivot_offset = hotspot.size * 0.5
	hotspot.scale = Vector2(0.98, 0.98)


func _on_hotspot_button_up(view_id: String) -> void:
	var hotspot: Button = _get_hotspot(view_id)
	if hotspot != null:
		hotspot.scale = Vector2.ONE


func _make_error(message: String) -> Dictionary:
	push_error("[工作室][overview_error] %s" % message)
	return {"ok": false, "message": message}
