class_name DoorWindowCloseup
extends Control
## 门与观察窗近景没有剧情实体或独立交互，只允许请求返回总览。

signal return_requested()

var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true

@onready var _return_button: Button = %BackButton
@onready var _street_lamp_material_switch: Control = $StreetLampMaterialSwitch


func _ready() -> void:
	_refresh_return_button()
	var motion_result: Dictionary = set_motion_enabled(_is_motion_enabled)
	if not bool(motion_result.get("ok", false)):
		push_error("[门窗][lamp_switch_motion] %s" % String(motion_result.get("message", "背景素材切换初始化失败。")))


## 导航锁定由上层控制，门窗近景没有独立剧情或环境状态可供修改。
func set_return_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用返回工作室总览时必须提供中文原因。")
	_is_return_enabled = is_enabled
	_refresh_return_button(disabled_reason)
	return {"ok": true}


## 门窗只把减少动态状态交给背景素材切换，不由此引入任何剧情实体。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	if _street_lamp_material_switch == null or not _street_lamp_material_switch.has_method(&"set_motion_enabled"):
		return _make_error("门外路灯背景素材切换组件缺少 set_motion_enabled() 接口。")
	var lamp_result: Variant = _street_lamp_material_switch.call(&"set_motion_enabled", is_enabled)
	if not _is_ok_result(lamp_result):
		return _make_error("门窗背景素材切换组件拒绝切换动态状态：lamp=%s。" % str(lamp_result))
	return {"ok": true}


func get_atmosphere_snapshot() -> Dictionary:
	if _street_lamp_material_switch == null:
		return _make_error("门窗氛围组件尚未就绪。")
	return {
		"ok": true,
		"street_lamp": _street_lamp_material_switch.call(&"get_effect_snapshot"),
	}


func _refresh_return_button(disabled_reason: String = "") -> void:
	_return_button.disabled = not _is_return_enabled
	if _is_return_enabled:
		_return_button.text = "返回工作室总览"
		_return_button.tooltip_text = "返回工作室总览。"
		return
	# 保持按钮两行短文案，避免完整原因在窄按钮中截断。
	_return_button.text = "返回不可用\n当前界面已锁定"
	_return_button.tooltip_text = "不可用：%s" % disabled_reason


func _on_back_button_pressed() -> void:
	if _is_return_enabled and not _return_button.disabled:
		return_requested.emit()


func _make_error(message: String) -> Dictionary:
	push_error("[门窗][closeup_error] %s" % message)
	return {"ok": false, "message": message}


func _is_ok_result(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))
