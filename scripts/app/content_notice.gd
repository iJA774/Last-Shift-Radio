class_name ContentNotice
extends Control

## 内容提示只列出体验强度，不泄露地点、车辆或收束记录等剧情信息。

signal shift_confirmed
signal return_to_menu_requested

@onready var _confirm_button: Button = %ConfirmShiftButton
@onready var _return_button: Button = %ReturnToMenuButton
@onready var _error_panel: PanelContainer = %ErrorPanel
@onready var _error_label: Label = %ErrorLabel


func _ready() -> void:
	_error_panel.visible = false
	_confirm_button.pressed.connect(_on_confirm_pressed)
	_return_button.pressed.connect(_on_return_pressed)


func show_error(message: String) -> void:
	_error_label.text = "无法开始值班：%s" % message
	_error_panel.visible = true


func clear_error() -> void:
	_error_label.text = ""
	_error_panel.visible = false


func get_notice_text() -> String:
	return "《末班电台》包含克制的心理恐怖氛围，以及对交通事故、失踪或死亡的暗示。部分场景含有轻度的突发声音或视觉刺激。"


func _on_confirm_pressed() -> void:
	if not _confirm_button.disabled:
		shift_confirmed.emit()


func _on_return_pressed() -> void:
	if not _return_button.disabled:
		return_to_menu_requested.emit()
