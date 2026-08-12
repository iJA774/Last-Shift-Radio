class_name MainMenu
extends Control

## 主菜单仅表达应用级意图；存档页面由 Main 统一创建和校验。

signal start_shift_requested
signal load_game_requested
signal settings_requested
signal exit_requested

## bong_001.wav 的实测时长约为 0.132 秒；仅真正退出程序时留出极短听觉反馈。
const EXIT_CLICK_AUDIBLE_DELAY_SECONDS: float = 0.15

@onready var _start_shift_button: Button = %StartShiftButton
@onready var _load_game_button: Button = %LoadGameButton
@onready var _settings_button: Button = %SettingsButton
@onready var _exit_button: Button = %ExitButton
@onready var _load_disabled_reason: Label = %LoadDisabledReason
@onready var _settings_disabled_reason: Label = %SettingsDisabledReason
@onready var _selection_frame: TextureRect = %SelectionFrame

var _menu_buttons: Array[Button] = []
var _sound_started_by_button: Dictionary[int, bool] = {}
var _is_exit_pending: bool = false


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
		# 鼠标按下先起声，随后场景替换也不会截断；pressed 仍为键盘激活的回退点。
		button.button_down.connect(_on_menu_button_down.bind(button))
		button.button_up.connect(_clear_sound_started_after_release.bind(button))
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
		_play_button_click_if_needed(_start_shift_button)
		start_shift_requested.emit()


func _on_load_game_pressed() -> void:
	if not _load_game_button.disabled:
		_play_button_click_if_needed(_load_game_button)
		load_game_requested.emit()


func _on_settings_pressed() -> void:
	if not _settings_button.disabled:
		_play_button_click_if_needed(_settings_button)
		settings_requested.emit()


func _on_exit_pressed() -> void:
	if _exit_button.disabled or _is_exit_pending:
		return
	_play_button_click_if_needed(_exit_button)
	_is_exit_pending = true
	_exit_button.disabled = true
	# 主菜单退出会立即调用 SceneTree.quit()；短暂延后仅为了让已开始的 68ms 点击声实际可听。
	await get_tree().create_timer(EXIT_CLICK_AUDIBLE_DELAY_SECONDS).timeout
	if is_instance_valid(self):
		exit_requested.emit()


func _on_menu_button_down(button: Button) -> void:
	var button_id: int = button.get_instance_id()
	_sound_started_by_button[button_id] = true
	_play_button_click()


func _clear_sound_started_after_release(button: Button) -> void:
	# pressed 可能与 button_up 同帧发射；延后清理才能避免一次鼠标激活重复起声。
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
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，主菜单点击音未播放。")
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] 主菜单点击音播放失败：%s" % str(result))
