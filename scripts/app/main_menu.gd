class_name MainMenu
extends Control

## 主菜单仅表达应用级意图；存档和设置尚未建立时把原因直接写在页面上。

signal start_shift_requested
signal exit_requested

const LOAD_DISABLED_REASON: String = "存档系统尚未建立"
const SETTINGS_DISABLED_REASON: String = "设置系统尚未建立"

@onready var _start_shift_button: Button = %StartShiftButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _settings_button: Button = %SettingsButton
@onready var _exit_button: Button = %ExitButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason
@onready var _settings_disabled_reason: Label = %SettingsDisabledReason


func _ready() -> void:
	_load_game_button.disabled = true
	_settings_button.disabled = true
	_load_disabled_reason.text = LOAD_DISABLED_REASON
	_settings_disabled_reason.text = SETTINGS_DISABLED_REASON
	_load_game_button.tooltip_text = "不可用：%s" % LOAD_DISABLED_REASON
	_settings_button.tooltip_text = "不可用：%s" % SETTINGS_DISABLED_REASON
	_start_shift_button.pressed.connect(_on_start_shift_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)


func get_disabled_reason(action_id: String) -> String:
	match action_id:
		"load_game":
			return LOAD_DISABLED_REASON
		"settings":
			return SETTINGS_DISABLED_REASON
	return ""


func _on_start_shift_pressed() -> void:
	if not _start_shift_button.disabled:
		start_shift_requested.emit()


func _on_exit_pressed() -> void:
	if not _exit_button.disabled:
		exit_requested.emit()
