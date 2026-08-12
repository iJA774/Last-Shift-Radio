class_name ShiftControlBar
extends Control
## 夜班 ESC 菜单只负责表达 UI 意图，不暂停时间或持有剧情状态。

signal settings_requested
signal save_requested
signal exit_requested

const ACTION_DEFAULT_Y: Dictionary[String, float] = {
	"settings": 433.0,
	"save": 583.0,
	"exit": 733.0,
}
const DOT_X: float = 38.0
const DOT_SIZE: float = 28.0
const PRESSED_DOT_X_OFFSET: float = 7.0
const PRESSED_DOT_SCALE: float = 1.18

@onready var _settings_button: Button = %SettingsButton
@onready var _save_button: Button = %SaveButton
@onready var _exit_button: Button = %ExitButton
@onready var _selection_dot: Label = %SelectionDot

var _selected_action_id: String = "settings"
var _pressed_action_id: String = ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_action(_settings_button, "settings", func() -> void: settings_requested.emit())
	_connect_action(_save_button, "save", func() -> void: save_requested.emit())
	_connect_action(_exit_button, "exit", func() -> void: exit_requested.emit())
	_select_action("settings")


func _connect_action(button: Button, action_id: String, callback: Callable) -> void:
	button.pressed.connect(callback)
	button.mouse_entered.connect(func() -> void: _select_action(action_id))
	button.focus_entered.connect(func() -> void: _select_action(action_id))
	button.button_down.connect(func() -> void: _set_pressed_action(action_id))
	button.button_up.connect(_clear_pressed_action)


func set_save_availability(can_save: bool, reason: String) -> Dictionary:
	_save_button.disabled = not can_save
	_save_button.tooltip_text = "打开三槽存档界面；故事时间不会暂停。" if can_save else "存档不可用：%s" % reason
	if not can_save and _selected_action_id == "save":
		_select_action("settings")
	return {"ok": true, "can_save": can_save}


func focus_first_action() -> void:
	_select_action("settings")
	_settings_button.grab_focus()


func get_selected_action_id() -> String:
	return _selected_action_id


func get_visual_contract_snapshot() -> Dictionary:
	return {
		"ok": true,
		"selected_action_id": _selected_action_id,
		"pressed_action_id": _pressed_action_id,
		"has_menu_art": get_node_or_null("Backdrop/MenuArt") is TextureRect,
		"has_single_selection_dot": _selection_dot != null and _selection_dot.text == "●",
	}


func _select_action(action_id: String) -> void:
	if not ACTION_DEFAULT_Y.has(action_id):
		return
	_selected_action_id = action_id
	_update_selection_dot()


func _set_pressed_action(action_id: String) -> void:
	_select_action(action_id)
	_pressed_action_id = action_id
	_update_selection_dot()


func _clear_pressed_action() -> void:
	_pressed_action_id = ""
	_update_selection_dot()


func _update_selection_dot() -> void:
	if _selection_dot == null:
		return
	var y: float = ACTION_DEFAULT_Y.get(_selected_action_id, ACTION_DEFAULT_Y["settings"])
	var is_pressed: bool = _selected_action_id == _pressed_action_id
	_selection_dot.position = Vector2(DOT_X + (PRESSED_DOT_X_OFFSET if is_pressed else 0.0), y)
	_selection_dot.size = Vector2(DOT_SIZE, DOT_SIZE)
	_selection_dot.scale = Vector2.ONE * (PRESSED_DOT_SCALE if is_pressed else 1.0)
