class_name EndingScreen
extends Control

## 结束页只负责重新开始或返回主菜单，不持有本局剧情、电话或时钟状态。

signal restart_requested
signal return_to_menu_requested

const LOAD_DISABLED_REASON: String = "存档系统尚未建立"

@onready var _restart_button: Button = %RestartButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _return_to_menu_button: Button = %ReturnToMenuButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason


func _ready() -> void:
	_load_game_button.disabled = true
	_load_disabled_reason.text = LOAD_DISABLED_REASON
	_load_game_button.tooltip_text = "不可用：%s" % LOAD_DISABLED_REASON
	_restart_button.pressed.connect(_on_restart_pressed)
	_return_to_menu_button.pressed.connect(_on_return_to_menu_pressed)


func get_disabled_reason(action_id: String) -> String:
	if action_id == "load_game":
		return LOAD_DISABLED_REASON
	return ""


func _on_restart_pressed() -> void:
	if not _restart_button.disabled:
		restart_requested.emit()


func _on_return_to_menu_pressed() -> void:
	if not _return_to_menu_button.disabled:
		return_to_menu_requested.emit()
