class_name MainMenu
extends Control

## 主菜单仅表达应用级意图；存档页面由 Main 统一创建和校验。

signal start_shift_requested
signal load_game_requested
signal settings_requested
signal exit_requested

@onready var _start_shift_button: Button = %StartShiftButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _settings_button: Button = %SettingsButton
@onready var _exit_button: Button = %ExitButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason
@onready var _settings_disabled_reason: Label = %SettingsDisabledReason
@onready var _selection_frame: TextureRect = %SelectionFrame

var _menu_buttons: Array[Button] = []


func _ready() -> void:
	_load_game_button.disabled = false
	_settings_button.disabled = false
	_load_disabled_reason.text = "读取本地三槽存档"
	# 保留旧的可访问性/测试契约，但由透明 Godot 文本承载，不覆盖参考图中的排版。
	_load_disabled_reason.visible = true
	_settings_disabled_reason.visible = false
	_load_game_button.tooltip_text = "打开三槽读取页。"
	_settings_button.tooltip_text = "打开设置；设置会立即保存。"
	_start_shift_button.pressed.connect(_on_start_shift_pressed)
	_load_game_button.pressed.connect(_on_load_game_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_exit_button.pressed.connect(_on_exit_pressed)
	_menu_buttons = [_start_shift_button, _load_game_button, _settings_button, _exit_button]
	for button: Button in _menu_buttons:
		button.mouse_entered.connect(_on_menu_button_highlighted.bind(button))
		button.focus_entered.connect(_on_menu_button_highlighted.bind(button))
	_start_shift_button.grab_focus()
	call_deferred("_move_selection_frame", _start_shift_button)


func get_disabled_reason(action_id: String) -> String:
	return ""


func _on_menu_button_highlighted(button: Button) -> void:
	_move_selection_frame(button)


func _move_selection_frame(button: Button) -> void:
	if button == null or _selection_frame == null:
		return
	_selection_frame.position = Vector2(-20.0, button.position.y - 8.0)
	_selection_frame.size = Vector2(713.0, 89.0)


func _on_start_shift_pressed() -> void:
	if not _start_shift_button.disabled:
		start_shift_requested.emit()


func _on_load_game_pressed() -> void:
	if not _load_game_button.disabled:
		load_game_requested.emit()


func _on_settings_pressed() -> void:
	if not _settings_button.disabled:
		settings_requested.emit()


func _on_exit_pressed() -> void:
	if not _exit_button.disabled:
		exit_requested.emit()
