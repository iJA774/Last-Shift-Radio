class_name EndingScreen
extends Control

## 结束页只负责重新开始或返回主菜单，不持有本局剧情、电话或时钟状态。

signal restart_requested
signal load_game_requested
signal return_to_menu_requested

@onready var _restart_button: Button = %RestartButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _return_to_menu_button: Button = %ReturnToMenuButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason


func _ready() -> void:
	_load_game_button.disabled = true
	_load_disabled_reason.visible = false
	_load_game_button.disabled = false
	_load_game_button.tooltip_text = "打开三槽读取页。"
	_restart_button.pressed.connect(_on_restart_pressed)
	_load_game_button.pressed.connect(_on_load_game_pressed)
	_return_to_menu_button.pressed.connect(_on_return_to_menu_pressed)


func get_disabled_reason(action_id: String) -> String:
	if action_id == "load_game" and _load_game_button.disabled:
		return "读取功能当前不可用。"
	return ""


func _on_restart_pressed() -> void:
	if not _restart_button.disabled:
		restart_requested.emit()


func _on_load_game_pressed() -> void:
	if not _load_game_button.disabled:
		load_game_requested.emit()


func _on_return_to_menu_pressed() -> void:
	if not _return_to_menu_button.disabled:
		return_to_menu_requested.emit()
