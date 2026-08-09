class_name MainMenu
extends Control

## 主菜单仅表达应用级意图；存档页面由 Main 统一创建和校验。

signal start_shift_requested
signal load_game_requested
signal exit_requested

const SETTINGS_DISABLED_REASON: String = "设置系统尚未建立"

@onready var _start_shift_button: Button = %StartShiftButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _settings_button: Button = %SettingsButton
@onready var _exit_button: Button = %ExitButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason
@onready var _settings_disabled_reason: Label = %SettingsDisabledReason


func _ready() -> void:
	_load_game_button.disabled = false
	_settings_button.disabled = true
	_load_disabled_reason.text = "读取本地三槽存档"
	_settings_disabled_reason.text = SETTINGS_DISABLED_REASON
	_load_game_button.tooltip_text = "打开三槽读取页。"
	_settings_button.tooltip_text = "不可用：%s" % SETTINGS_DISABLED_REASON
	_start_shift_button.pressed.connect(_on_start_shift_pressed)
	_load_game_button.pressed.connect(_on_load_game_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)


func get_disabled_reason(action_id: String) -> String:
	match action_id:
		"settings":
			return SETTINGS_DISABLED_REASON
	return ""


func _on_start_shift_pressed() -> void:
	if not _start_shift_button.disabled:
		start_shift_requested.emit()


func _on_load_game_pressed() -> void:
	if not _load_game_button.disabled:
		load_game_requested.emit()


func _on_exit_pressed() -> void:
	if not _exit_button.disabled:
		exit_requested.emit()
