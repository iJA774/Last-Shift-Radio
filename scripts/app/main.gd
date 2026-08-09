extends Control
## 应用级生命周期权威。
##
## Main 只管理页面状态、本局运行时的创建/销毁与 02:00 的短暂收束余韵。
## StoryEngine 仍是剧情真相的唯一来源；菜单、内容提示和结束页均不保存剧情副本。

const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/app/main_menu.tscn")
const CONTENT_NOTICE_SCENE: PackedScene = preload("res://scenes/app/content_notice.tscn")
const ENDING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/ending_screen.tscn")
const FOUNDATION_EVENTS_PATH: String = "res://data/story/foundation_events.json"
const DEFAULT_ENDING_TRANSITION_DELAY_SECONDS: float = 0.85

enum AppState {
	BOOT,
	MAIN_MENU,
	CONTENT_NOTICE,
	SHIFT,
	ENDING,
}

@export_file("*.json") var content_source_path: String = FOUNDATION_EVENTS_PATH
@export_range(0.05, 3.0, 0.05) var ending_transition_delay_seconds: float = DEFAULT_ENDING_TRANSITION_DELAY_SECONDS

var _app_state: AppState = AppState.BOOT
var _story_engine: RefCounted = null
var _phone_system: RefCounted = null
var _game_clock: Node = null
var _game_screen: GameScreen = null
var _current_screen: Control = null
var _content_validation_result: Dictionary = {}
var _is_shift_started: bool = false
var _is_creating_shift: bool = false
var _ending_delay_serial: int = 0

@onready var _screen_host: Control = $ScreenHost
@onready var _shell_error_panel: PanelContainer = $ShellErrorPanel
@onready var _shell_error_label: Label = $ShellErrorPanel/ErrorLabel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_shell_error_panel.visible = false
	_game_clock = get_tree().root.get_node_or_null(NodePath("GameClock")) as Node
	_show_main_menu()
	if _game_clock == null:
		_show_shell_error("找不到 GameClock 自动加载节点。无法开始值班，但可返回主菜单。")
	print("[应用][lifecycle_ready] 应用已启动，当前状态=MAIN_MENU；本局运行时尚未创建。")


## 稳定只读状态接口，供 Headless 验证和后续 UI 审计使用。
func get_application_state() -> AppState:
	return _app_state


func get_application_state_name() -> String:
	return AppState.keys()[_app_state]


func has_active_runtime() -> bool:
	return _story_engine != null or _phone_system != null or _game_screen != null


func get_current_game_screen() -> GameScreen:
	return _game_screen


func request_start_shift() -> void:
	if _app_state != AppState.MAIN_MENU:
		return
	_show_content_notice()


func confirm_content_notice() -> void:
	if _app_state != AppState.CONTENT_NOTICE:
		return
	_start_new_shift()


func return_to_main_menu() -> void:
	if _app_state != AppState.CONTENT_NOTICE and _app_state != AppState.ENDING:
		return
	_show_main_menu()


func restart_shift() -> void:
	if _app_state != AppState.ENDING:
		return
	_start_new_shift()


func _show_main_menu() -> void:
	_cancel_pending_ending_transition()
	_dispose_runtime()
	var menu: Control = MAIN_MENU_SCENE.instantiate() as Control
	menu.connect(&"start_shift_requested", Callable(self, "request_start_shift"))
	menu.connect(&"exit_requested", Callable(self, "_on_exit_requested"))
	_replace_screen(menu)
	_app_state = AppState.MAIN_MENU
	_is_shift_started = false
	print("[应用][state] 已进入 MAIN_MENU；GameClock 不运行且本局运行时已清理。")


func _show_content_notice(error_message: String = "") -> void:
	_cancel_pending_ending_transition()
	_dispose_runtime()
	var notice: Control = CONTENT_NOTICE_SCENE.instantiate() as Control
	notice.connect(&"shift_confirmed", Callable(self, "confirm_content_notice"))
	notice.connect(&"return_to_menu_requested", Callable(self, "return_to_main_menu"))
	_replace_screen(notice)
	_app_state = AppState.CONTENT_NOTICE
	if not error_message.is_empty():
		notice.call(&"show_error", error_message)
	print("[应用][state] 已进入 CONTENT_NOTICE；本局运行时尚未创建。")


func _start_new_shift() -> void:
	if _is_creating_shift:
		return
	_is_creating_shift = true
	_dispose_runtime()
	_game_clock = get_tree().root.get_node_or_null(NodePath("GameClock")) as Node
	if _game_clock == null:
		_is_creating_shift = false
		_show_content_notice("找不到 GameClock 自动加载节点，夜班未启动。")
		return
	if _game_clock.has_method(&"is_running") and bool(_game_clock.call(&"is_running")):
		_is_creating_shift = false
		_show_content_notice("GameClock 仍在运行，拒绝覆盖当前夜班。")
		return
	if not _game_clock.has_method(&"prepare_new_shift"):
		_is_creating_shift = false
		_show_content_notice("GameClock 缺少 prepare_new_shift() 新局预备接口。")
		return
	var prepare_result: Variant = _game_clock.call(&"prepare_new_shift")
	if not _is_ok_result(prepare_result):
		_is_creating_shift = false
		_show_content_notice("准备新夜班时钟失败：%s" % _describe_result(prepare_result))
		return

	var events_result: Dictionary = _load_validated_events()
	if not bool(events_result.get("ok", false)):
		_is_creating_shift = false
		_show_content_notice(String(events_result.get("message", "基础系统事件数据加载失败。")))
		return

	_content_validation_result = events_result
	_phone_system = PHONE_SYSTEM_SCRIPT.new()
	_story_engine = STORY_ENGINE_SCRIPT.new()
	if not _check_runtime_result(_story_engine.call(&"set_phone_system", _phone_system), "连接 PhoneSystem"):
		return
	var events: Array = events_result["events"] as Array
	if not _check_runtime_result(_story_engine.call(&"schedule_events", events), "登记已校验来电事件"):
		return

	_game_screen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	if _game_screen == null:
		_fail_shift_creation("无法实例化 GameScreen。")
		return
	_replace_screen(_game_screen)
	if not _check_runtime_result(_game_screen.bind_runtime(_story_engine, _phone_system, _game_clock), "注入 GameScreen 运行时"):
		return
	if not _check_runtime_result(_story_engine.call(&"connect_game_clock", _game_clock), "连接 GameClock"):
		return
	if not _connect_ending_signal():
		return
	# 现在 StoryEngine、PhoneSystem、GameScreen 与 02:00 回调均完整绑定，
	# 所有成功路径才在此处发送一次正式 shift_started。
	_app_state = AppState.SHIFT
	_is_shift_started = true
	_game_clock.call(&"start_shift")
	_is_creating_shift = false
	print("[应用][shift_started] 已加载并校验 %d 条基础系统来电事件，当前状态=SHIFT。" % events.size())


func _load_validated_events() -> Dictionary:
	var loader = CONTENT_LOADER_SCRIPT.new()
	var load_result: Variant = loader.load_json(content_source_path)
	if not _is_ok_result(load_result):
		return _startup_error("读取基础系统事件数据失败：%s" % _describe_result(load_result))
	var loaded: Dictionary = load_result as Dictionary
	if not loaded.has("data"):
		return _startup_error("读取基础系统事件数据失败：ContentLoader 成功结果缺少 data 字段。")

	var validator = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_result: Variant = validator.validate_incoming_call_events(loaded["data"], content_source_path)
	if not _is_ok_result(validation_result):
		return _startup_error("基础系统事件数据校验失败：%s" % _describe_result(validation_result))
	var validated: Dictionary = validation_result as Dictionary
	var events_value: Variant = validated.get("events")
	if not events_value is Array:
		return _startup_error("基础系统事件数据校验失败：成功结果缺少 events 数组。")
	return {"ok": true, "events": (events_value as Array).duplicate(true)}


func _connect_ending_signal() -> bool:
	var callback: Callable = Callable(self, "_on_ending_forced")
	if _story_engine.is_connected(&"ending_forced", callback):
		return true
	var connect_result: Error = _story_engine.connect(&"ending_forced", callback)
	if connect_result != OK:
		_fail_shift_creation("无法监听 StoryEngine.ending_forced，错误码=%d。" % connect_result)
		return false
	return true


func _on_ending_forced(_end_tick: int) -> void:
	if _app_state != AppState.SHIFT or _story_engine == null or _game_screen == null:
		return
	var record_result: Variant = _story_engine.call(&"get_unauthorized_broadcast_record")
	if not record_result is Dictionary or (record_result as Dictionary).is_empty():
		_show_shell_error("02:00 收束已触发，但 StoryEngine 未提供权威未授权播出记录。")
		return
	var display_result: Dictionary = _game_screen.show_ending(record_result as Dictionary)
	if not bool(display_result.get("ok", false)):
		_show_shell_error("02:00 收束记录显示失败：%s" % String(display_result.get("message", "未知错误。")))
		return
	_cancel_pending_ending_transition()
	var serial: int = _ending_delay_serial
	_show_ending_after_delay(serial)


func _show_ending_after_delay(serial: int) -> void:
	# SceneTreeTimer 始终处理且不受暂停影响；serial 防止旧回调覆盖新的流程。
	await get_tree().create_timer(ending_transition_delay_seconds, true, false, true).timeout
	if serial != _ending_delay_serial or _app_state != AppState.SHIFT:
		return
	_show_ending_screen()


func _show_ending_screen() -> void:
	_remove_game_screen()
	var ending: Control = ENDING_SCREEN_SCENE.instantiate() as Control
	ending.connect(&"restart_requested", Callable(self, "restart_shift"))
	ending.connect(&"return_to_menu_requested", Callable(self, "return_to_main_menu"))
	_replace_screen(ending)
	_app_state = AppState.ENDING
	print("[应用][state] 已进入 ENDING；运行时保留至重新开始或返回主菜单时统一清理。")


func _replace_screen(next_screen: Control) -> void:
	if _current_screen != null and is_instance_valid(_current_screen):
		if _current_screen == _game_screen:
			_remove_game_screen()
		else:
			_screen_host.remove_child(_current_screen)
			_current_screen.queue_free()
	_current_screen = next_screen
	_screen_host.add_child(next_screen)


func _remove_game_screen() -> void:
	if _game_screen == null or not is_instance_valid(_game_screen):
		_game_screen = null
		return
	if _game_screen.has_method(&"release_runtime"):
		_game_screen.call(&"release_runtime")
	if _game_screen.get_parent() == _screen_host:
		_screen_host.remove_child(_game_screen)
	_game_screen.queue_free()
	if _current_screen == _game_screen:
		_current_screen = null
	_game_screen = null


func _dispose_runtime() -> void:
	_cancel_pending_ending_transition()
	_remove_game_screen()
	if _story_engine != null:
		var ending_callback: Callable = Callable(self, "_on_ending_forced")
		if _story_engine.is_connected(&"ending_forced", ending_callback):
			_story_engine.disconnect(&"ending_forced", ending_callback)
		if _story_engine.has_method(&"release_runtime"):
			_story_engine.call(&"release_runtime")
	_story_engine = null
	_phone_system = null
	_is_shift_started = false


func _cancel_pending_ending_transition() -> void:
	_ending_delay_serial += 1


func _check_runtime_result(result: Variant, context: String) -> bool:
	if _is_ok_result(result):
		return true
	_fail_shift_creation("%s失败：%s" % [context, _describe_result(result)])
	return false


func _fail_shift_creation(message: String) -> void:
	_is_creating_shift = false
	_dispose_runtime()
	_show_content_notice(message)


func _show_shell_error(message: String) -> void:
	_shell_error_label.text = "系统错误：%s" % message
	_shell_error_panel.visible = true
	push_error("[应用][lifecycle_error] %s" % message)


func _on_exit_requested() -> void:
	print("[应用][exit_requested] 玩家从主菜单请求退出。")
	get_tree().quit()


func _is_ok_result(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))


func _describe_result(result: Variant) -> String:
	if result is Dictionary:
		var payload: Dictionary = result as Dictionary
		var message: String = String(payload.get("message", str(payload)))
		var details: PackedStringArray = []
		if payload.has("source_path"):
			details.append("文件：%s" % String(payload["source_path"]))
		if payload.has("event_id") and not String(payload["event_id"]).is_empty():
			details.append("事件：%s" % String(payload["event_id"]))
		if payload.has("field") and not String(payload["field"]).is_empty():
			details.append("字段：%s" % String(payload["field"]))
		if not details.is_empty():
			return "%s（%s）" % [message, "；".join(details)]
		return message
	return str(result)


func _startup_error(message: String) -> Dictionary:
	return {"ok": false, "message": message}
