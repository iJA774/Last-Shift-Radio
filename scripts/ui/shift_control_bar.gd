class_name ShiftControlBar
extends Control
## 夜班 ESC 菜单只负责表达 UI 意图，不暂停时间或持有剧情状态。

signal settings_requested
signal save_requested
signal exit_requested

const ACTION_DEFAULT_Y: Dictionary[String, float] = {
	"settings": 392.0,
	"save": 542.0,
	"exit": 685.0,
}
const ARROW_X: float = 75.0
const ARROW_SIZE: Vector2 = Vector2(50.0, 80.0)
const PRESSED_ARROW_X_OFFSET: float = 6.0
const PRESSED_ARROW_SCALE: float = 1.12

@onready var _settings_button: Button = %SettingsButton
@onready var _save_button: Button = %SaveButton
@onready var _exit_button: Button = %ExitButton
@onready var _selection_arrow: TextureRect = %SelectionArrow

var _selected_action_id: String = "settings"
var _pressed_action_id: String = ""
var _sound_started_by_button: Dictionary[int, bool] = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_action(_settings_button, "settings")
	_connect_action(_save_button, "save")
	_connect_action(_exit_button, "exit")
	_select_action("settings")


func _connect_action(button: Button, action_id: String) -> void:
	button.pressed.connect(_on_action_pressed.bind(button, action_id))
	button.mouse_entered.connect(func() -> void: _select_action(action_id))
	button.focus_entered.connect(func() -> void: _select_action(action_id))
	button.button_down.connect(func() -> void:
		_set_pressed_action(action_id)
		_on_action_button_down(button)
	)
	button.button_up.connect(_clear_pressed_action)
	button.button_up.connect(_clear_sound_started_after_release.bind(button))


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
		"has_single_selection_arrow": _selection_arrow != null and _selection_arrow.texture is AtlasTexture,
	}


func _select_action(action_id: String) -> void:
	if not ACTION_DEFAULT_Y.has(action_id):
		return
	_selected_action_id = action_id
	_update_selection_arrow()


func _set_pressed_action(action_id: String) -> void:
	_select_action(action_id)
	_pressed_action_id = action_id
	_update_selection_arrow()


func _clear_pressed_action() -> void:
	_pressed_action_id = ""
	_update_selection_arrow()


func _update_selection_arrow() -> void:
	if _selection_arrow == null:
		return
	var y: float = ACTION_DEFAULT_Y.get(_selected_action_id, ACTION_DEFAULT_Y["settings"])
	var is_pressed: bool = _selected_action_id == _pressed_action_id
	_selection_arrow.position = Vector2(ARROW_X + (PRESSED_ARROW_X_OFFSET if is_pressed else 0.0), y)
	_selection_arrow.size = ARROW_SIZE
	_selection_arrow.scale = Vector2.ONE * (PRESSED_ARROW_SCALE if is_pressed else 1.0)


func _on_action_pressed(button: Button, action_id: String) -> void:
	_play_button_click_if_needed(button)
	match action_id:
		"settings": settings_requested.emit()
		"save": save_requested.emit()
		"exit": exit_requested.emit()
		_:
			push_error("[UI][shift_control_unknown_action] 未知夜班菜单动作：%s。" % action_id)


func _on_action_button_down(button: Button) -> void:
	var button_id: int = button.get_instance_id()
	_sound_started_by_button[button_id] = true
	_play_button_click()


func _clear_sound_started_after_release(button: Button) -> void:
	# pressed 与 button_up 的同帧次序依平台而异，延后清理保证正常点击只发一声。
	call_deferred("_clear_sound_started_by_id", button.get_instance_id())


func _clear_sound_started_by_id(button_id: int) -> void:
	_sound_started_by_button.erase(button_id)


func _play_button_click_if_needed(button: Button) -> void:
	var button_id: int = button.get_instance_id()
	if bool(_sound_started_by_button.get(button_id, false)):
		_sound_started_by_button.erase(button_id)
		return
	_play_button_click()


func _play_button_click() -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	if player == null or not player.has_method(&"play_button_click"):
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，夜班菜单点击音未播放。")
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] 夜班菜单点击音播放失败：%s" % str(result))
