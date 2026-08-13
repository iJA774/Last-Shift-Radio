extends Control
## 应用级生命周期权威。
##
## Main 只管理页面状态、本局运行时的创建/销毁与 02:00 的短暂收束余韵。
## StoryEngine 仍是剧情真相的唯一来源；菜单、加载页和结束页均不保存剧情副本。

const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const CONTENT_LOADER_SCRIPT: GDScript = preload("res://scripts/core/content_loader.gd")
const CONTENT_VALIDATOR_SCRIPT: GDScript = preload("res://scripts/core/content_validator.gd")
const SAVE_MANAGER_SCRIPT: GDScript = preload("res://scripts/systems/save_manager.gd")
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/app/main_menu.tscn")
const SAVE_SLOT_PANEL_SCENE: PackedScene = preload("res://scenes/ui/save_slot_panel.tscn")
const SETTINGS_PANEL_SCENE: PackedScene = preload("res://scenes/ui/settings_panel.tscn")
const LOADING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/loading_screen.tscn")
const ENDING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/ending_screen.tscn")
const TEST_NIGHT_STORY_PATH: String = "res://data/story/test_night_story.json"
const DEFAULT_ENDING_TRANSITION_DELAY_SECONDS: float = 0.85

enum AppState {
	BOOT,
	MAIN_MENU,
	LOAD_SLOTS,
	LOADING,
	SHIFT,
	ENDING,
}

## 同一张加载页面服务于两个已确认目的；完成时不得一律启动新夜班。
enum LoadingTarget {
	START_SHIFT,
	MAIN_MENU,
}

@export_file("*.json") var content_source_path: String = TEST_NIGHT_STORY_PATH
@export_range(0.05, 3.0, 0.05) var ending_transition_delay_seconds: float = DEFAULT_ENDING_TRANSITION_DELAY_SECONDS

var _app_state: AppState = AppState.BOOT
var _story_engine: RefCounted = null
var _phone_system: RefCounted = null
var _game_clock: Node = null
var _game_screen: GameScreen = null
var _current_screen: Control = null
var _content_validation_result: Dictionary = {}
var _save_manager: SaveManager = null
var _load_slot_panel: SaveSlotPanel = null
var _settings_manager: Node = null
var _settings_panel: SettingsPanel = null
var _loading_screen: Control = null
var _loading_target: LoadingTarget = LoadingTarget.START_SHIFT
var _is_settings_signal_connected: bool = false
var _has_settings_load_error: bool = false
var _is_shift_started: bool = false
var _is_creating_shift: bool = false
var _ending_delay_serial: int = 0

@onready var _screen_host: Control = $ScreenHost
@onready var _overlay_host: Control = $OverlayHost
@onready var _shell_error_panel: PanelContainer = $ShellErrorPanel
@onready var _shell_error_label: Label = $ShellErrorPanel/ErrorLabel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_shell_error_panel.visible = false
	_save_manager = SAVE_MANAGER_SCRIPT.new() as SaveManager
	if _save_manager == null:
		_show_shell_error("无法创建 SaveManager，读取和保存功能不可用。")
	_game_clock = get_tree().root.get_node_or_null(NodePath("GameClock")) as Node
	var settings_result: Dictionary = _bind_settings_manager()
	if not bool(settings_result.get("ok", false)):
		_has_settings_load_error = true
		_show_shell_error("设置系统不可用：%s" % String(settings_result.get("message", "未知原因。")))
	elif bool(settings_result.get("needs_recovery", false)):
		_has_settings_load_error = true
		_show_shell_error("设置文件读取失败：%s 可在“设置”中点击“恢复默认设置”修复。" % String(settings_result.get("message", "未知原因。")))
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


func _bind_settings_manager() -> Dictionary:
	var settings_manager: Node = get_tree().root.get_node_or_null(NodePath("SettingsManager")) as Node
	if settings_manager == null:
		return {"ok": false, "message": "找不到 SettingsManager 自动加载节点。"}
	for method_name: String in ["get_settings_snapshot", "get_font_size", "is_settings_loaded", "get_last_load_result"]:
		if not settings_manager.has_method(method_name):
			return {"ok": false, "message": "SettingsManager 缺少 %s() 接口。" % method_name}
	if not settings_manager.has_signal(&"settings_applied"):
		return {"ok": false, "message": "SettingsManager 缺少 settings_applied 信号。"}
	_settings_manager = settings_manager
	var callback: Callable = Callable(self, "_on_settings_applied")
	if not _settings_manager.is_connected(&"settings_applied", callback):
		var connect_result: Error = _settings_manager.connect(&"settings_applied", callback)
		if connect_result != OK:
			_settings_manager = null
			return {"ok": false, "message": "无法监听 SettingsManager.settings_applied，错误码=%d。" % connect_result}
	_is_settings_signal_connected = true
	if not bool(_settings_manager.call(&"is_settings_loaded")):
		var load_result: Variant = _settings_manager.call(&"get_last_load_result")
		var recovery_message: String = String((load_result as Dictionary).get("message", "设置文件损坏或不可读取。")) if load_result is Dictionary else "设置文件损坏或不可读取。"
		# 未成功加载时不能把内存中的默认值当作用户设置正式应用；主菜单保持
		# 场景安全基线，设置页仅开放“恢复默认设置”这一显式修复操作。
		return {"ok": true, "needs_recovery": true, "message": recovery_message}
	var snapshot_value: Variant = _settings_manager.call(&"get_settings_snapshot")
	if not snapshot_value is Dictionary:
		return {"ok": false, "message": "SettingsManager 未返回有效设置快照。"}
	var apply_result: Dictionary = _apply_settings_to_ui(snapshot_value as Dictionary)
	if not bool(apply_result.get("ok", false)):
		return apply_result
	return {"ok": true}


func _on_settings_applied(snapshot: Dictionary) -> void:
	var apply_result: Dictionary = _apply_settings_to_ui(snapshot)
	if not bool(apply_result.get("ok", false)):
		_show_shell_error("应用设置失败：%s" % String(apply_result.get("message", "未知原因。")))
		return
	if _has_settings_load_error and _settings_manager != null and bool(_settings_manager.call(&"is_settings_loaded")):
		_has_settings_load_error = false
		_shell_error_panel.visible = false


## 字体先从 Main 整个可见树统一重排，再让 GameScreen 应用视觉/逐字参数。
## 这使菜单、五个电脑页签、存档、设置与结束页在同一档位下同步更新。
func _apply_settings_to_ui(snapshot: Dictionary) -> Dictionary:
	if not snapshot.has("font_size") or typeof(snapshot["font_size"]) != TYPE_INT:
		return {"ok": false, "message": "设置快照缺少整数 font_size。"}
	if not snapshot.has("window_mode") or typeof(snapshot["window_mode"]) != TYPE_STRING:
		return {"ok": false, "message": "设置快照缺少字符串 window_mode。"}
	var font_size_percent: int = int(snapshot["font_size"])
	if font_size_percent != 100 and font_size_percent != 125:
		return {"ok": false, "message": "设置快照包含不支持的字体大小档位。"}
	var window_result: Dictionary = _apply_window_mode(String(snapshot["window_mode"]))
	if not bool(window_result.get("ok", false)):
		return window_result
	var previous_percent: int = int(get_meta(SettingsUiScale.META_APPLIED_PERCENT, 100))
	var font_result: Dictionary = SettingsUiScale.apply_font_size(self, font_size_percent, previous_percent)
	if not bool(font_result.get("ok", false)):
		return font_result
	if _game_screen != null and is_instance_valid(_game_screen):
		var screen_result: Dictionary = _game_screen.apply_settings_snapshot(snapshot)
		if not bool(screen_result.get("ok", false)):
			return screen_result
	return {"ok": true}


## 窗口模式只从 SettingsManager 快照派生并直接交给 DisplayServer；不在 Main
## 复制或持久化该状态。Headless 验收保留可观测结果，但不会请求不存在的窗口。
func _apply_window_mode(window_mode: String) -> Dictionary:
	if window_mode != "windowed" and window_mode != "fullscreen":
		return {"ok": false, "message": "设置快照包含未知窗口模式：%s。" % window_mode}
	if DisplayServer.get_name().to_lower() == "headless":
		return {"ok": true, "window_mode": window_mode, "headless_skipped": true}
	var display_mode: DisplayServer.WindowMode = DisplayServer.WINDOW_MODE_FULLSCREEN if window_mode == "fullscreen" else DisplayServer.WINDOW_MODE_WINDOWED
	DisplayServer.window_set_mode(display_mode)
	return {"ok": true, "window_mode": window_mode, "headless_skipped": false}


## 只读读取 DisplayServer 当前窗口模式，供集成/Headless 测试确认设置立即派生。
func get_window_mode_observation() -> String:
	if DisplayServer.get_name().to_lower() == "headless":
		return "headless"
	return "fullscreen" if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else "windowed"


func _open_settings_panel() -> void:
	if _settings_panel != null and is_instance_valid(_settings_panel):
		return
	if _settings_manager == null or not is_instance_valid(_settings_manager):
		_show_shell_error("SettingsManager 不可用，不能打开设置。")
		return
	var panel: SettingsPanel = SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	if panel == null:
		_show_shell_error("无法实例化设置界面。")
		return
	var bind_result: Dictionary = panel.bind_settings_manager(_settings_manager)
	if not bool(bind_result.get("ok", false)):
		panel.queue_free()
		_show_shell_error("无法绑定设置界面：%s" % String(bind_result.get("message", "未知原因。")))
		return
	panel.z_index = 50
	panel.closed.connect(_on_application_settings_closed)
	_overlay_host.add_child(panel)
	_settings_panel = panel
	var snapshot_value: Variant = _settings_manager.call(&"get_settings_snapshot")
	if bool(_settings_manager.call(&"is_settings_loaded")) and snapshot_value is Dictionary:
		var apply_result: Dictionary = _apply_settings_to_ui(snapshot_value as Dictionary)
		if not bool(apply_result.get("ok", false)):
			_show_shell_error("打开设置后无法应用当前设置：%s" % String(apply_result.get("message", "未知原因。")))


func _on_application_settings_closed() -> void:
	_close_settings_panel()


func _close_settings_panel() -> void:
	if _settings_panel == null or not is_instance_valid(_settings_panel):
		_settings_panel = null
		return
	_settings_panel.queue_free()
	_settings_panel = null


func request_start_shift() -> void:
	if _app_state != AppState.MAIN_MENU:
		return
	_show_loading_screen(LoadingTarget.START_SHIFT)


## 仅供自动化测试跳过视觉等待；玩家流程不会暴露确认按钮。
func finish_loading_for_verification() -> void:
	if _app_state != AppState.LOADING or _loading_screen == null or not is_instance_valid(_loading_screen):
		return
	_loading_screen.call(&"finish_for_verification")


func return_to_main_menu() -> void:
	if _app_state == AppState.SHIFT:
		_show_loading_screen(LoadingTarget.MAIN_MENU)
		return
	if _app_state == AppState.LOADING or _app_state == AppState.ENDING or _app_state == AppState.LOAD_SLOTS:
		_show_main_menu()


func restart_shift() -> void:
	if _app_state != AppState.ENDING:
		return
	_start_new_shift()


func _show_main_menu() -> void:
	_cancel_pending_ending_transition()
	_close_settings_panel()
	_loading_screen = null
	_dispose_runtime()
	_load_slot_panel = null
	var menu: Control = MAIN_MENU_SCENE.instantiate() as Control
	menu.connect(&"start_shift_requested", Callable(self, "request_start_shift"))
	menu.connect(&"load_game_requested", Callable(self, "request_load_game"))
	menu.connect(&"settings_requested", Callable(self, "request_open_settings"))
	menu.connect(&"exit_requested", Callable(self, "_on_exit_requested"))
	_replace_screen(menu)
	_app_state = AppState.MAIN_MENU
	_is_shift_started = false
	print("[应用][state] 已进入 MAIN_MENU；GameClock 不运行且本局运行时已清理。")


func _show_loading_screen(target: LoadingTarget) -> void:
	_cancel_pending_ending_transition()
	_close_settings_panel()
	_dispose_runtime()
	var loading: Control = LOADING_SCREEN_SCENE.instantiate() as Control
	if loading == null:
		_show_shell_error("无法实例化加载页面，夜班未启动。")
		return
	loading.transition_finished.connect(_on_loading_transition_finished)
	_loading_screen = loading
	_loading_target = target
	_replace_screen(loading)
	_app_state = AppState.LOADING
	print("[应用][state] 已进入 LOADING；target=%s，本局运行时已清理且 GameClock 已停止。" % LoadingTarget.keys()[target])


func _on_loading_transition_finished() -> void:
	if _app_state != AppState.LOADING:
		return
	var target: LoadingTarget = _loading_target
	_loading_screen = null
	if target == LoadingTarget.MAIN_MENU:
		_show_main_menu()
		return
	_start_new_shift()


func request_load_game() -> void:
	if _app_state != AppState.MAIN_MENU and _app_state != AppState.ENDING:
		return
	if _save_manager == null:
		_show_shell_error("SaveManager 不可用，不能读取存档。")
		return
	_show_load_slots()


func request_open_settings() -> void:
	if _app_state != AppState.MAIN_MENU:
		return
	_open_settings_panel()


func _show_load_slots() -> void:
	_cancel_pending_ending_transition()
	_close_settings_panel()
	_loading_screen = null
	_dispose_runtime()
	var panel: SaveSlotPanel = SAVE_SLOT_PANEL_SCENE.instantiate() as SaveSlotPanel
	if panel == null:
		_show_shell_error("无法实例化读取存档界面。")
		_show_main_menu()
		return
	panel.set_mode(SaveSlotPanel.Mode.LOAD)
	panel.slot_load_requested.connect(_on_load_slot_requested)
	panel.return_requested.connect(_on_load_slots_return_requested)
	_replace_screen(panel)
	_load_slot_panel = panel
	_refresh_load_slot_summaries()
	_app_state = AppState.LOAD_SLOTS
	print("[应用][state] 已进入 LOAD_SLOTS；故事时间不会因槽位界面而暂停。")


func _on_load_slots_return_requested() -> void:
	if _app_state == AppState.LOAD_SLOTS:
		_show_main_menu()


func _refresh_load_slot_summaries() -> void:
	if _save_manager == null or _load_slot_panel == null or not is_instance_valid(_load_slot_panel):
		return
	var summaries: Array[Dictionary] = _save_manager.get_slot_summaries("test_night_story", 1)
	var result: Dictionary = _load_slot_panel.set_slot_summaries(summaries)
	if not bool(result.get("ok", false)):
		push_error("[应用][load_slot_summary_error] %s" % String(result.get("message", "未知错误。")))


func _on_load_slot_requested(slot_id: String) -> void:
	if _app_state != AppState.LOAD_SLOTS or _save_manager == null:
		return
	var load_result: Dictionary = _save_manager.load_slot(slot_id, "test_night_story", 1)
	if not bool(load_result.get("ok", false)):
		_show_load_slot_message("读取失败：%s" % String(load_result.get("message", "未知原因。")))
		_refresh_load_slot_summaries()
		return
	var restore_result: Dictionary = _restore_loaded_shift(load_result["document"] as Dictionary)
	if not bool(restore_result.get("ok", false)):
		_show_load_slot_message("读取失败：%s" % String(restore_result.get("message", "无法恢复存档。")))
		_refresh_load_slot_summaries()


func _show_load_slot_message(message: String) -> void:
	if _load_slot_panel != null and is_instance_valid(_load_slot_panel):
		_load_slot_panel.show_message(message)


func _restore_loaded_shift(document: Dictionary) -> Dictionary:
	if _is_creating_shift:
		return {"ok": false, "message": "运行时仍在创建中，请稍后再试。"}
	_is_creating_shift = true
	var structural_result: Dictionary = _save_manager.validate_document(document, "test_night_story", 1)
	if not bool(structural_result.get("ok", false)):
		_is_creating_shift = false
		return structural_result
	_game_clock = get_tree().root.get_node_or_null(NodePath("GameClock")) as Node
	if _game_clock == null:
		_is_creating_shift = false
		return {"ok": false, "message": "找不到 GameClock 自动加载节点。"}
	if bool(_game_clock.call(&"is_running")):
		_is_creating_shift = false
		return {"ok": false, "message": "GameClock 仍在运行，拒绝用读取存档覆盖当前班次。"}
	var story_content_result: Dictionary = _load_validated_test_story()
	if not bool(story_content_result.get("ok", false)):
		_is_creating_shift = false
		return story_content_result
	_content_validation_result = story_content_result
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var story: RefCounted = STORY_ENGINE_SCRIPT.new()
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	if phone == null or story == null or screen == null:
		if screen != null:
			screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "无法创建存档恢复所需的运行时对象。"}
	# GameScreen 的 @onready 子视图只能在 SceneTree 中绑定。先隐藏地挂进 ScreenHost
	# 作为 staging，读取失败时槽位页仍是 _current_screen，不会出现半恢复班次。
	screen.visible = false
	_screen_host.add_child(screen)
	var configure_result: Variant = story.call(&"configure_test_night_story", story_content_result)
	if not _is_ok_result(configure_result):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "配置读取的剧情内容失败：%s" % _describe_result(configure_result)}
	var clock_snapshot: Dictionary = document["game_clock_state"] as Dictionary
	var scheduler: RefCounted = story.call(&"get_scheduler") as RefCounted
	if scheduler == null or not scheduler.has_method(&"get_configured_events_by_id"):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "EventScheduler 缺少恢复电话所需的公开事件映射接口。"}
	var event_by_id_value: Variant = scheduler.call(&"get_configured_events_by_id")
	var current_tick_value: Variant = clock_snapshot.get("current_game_tick")
	var current_tick_result: Dictionary = _read_exact_integer(current_tick_value)
	if not event_by_id_value is Dictionary or not bool(current_tick_result.get("ok", false)):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "存档事件映射或时钟 tick 无效，拒绝读取。"}
	var phone_context: Dictionary = {"current_game_tick": int(current_tick_result["value"]), "event_by_id": event_by_id_value as Dictionary}
	# StoryEngine 的嵌套 ComputerSystem 必须交叉核验真实电话记录，因此先对无依赖
	# 的 Clock/Phone/Screen 进行校验并在隔离对象上恢复电话，再校验 StoryEngine。
	for contract: Dictionary in [
		{"name": "GameClock", "object": _game_clock, "snapshot": document["game_clock_state"], "context": {}},
		{"name": "PhoneSystem", "object": phone, "snapshot": document["phone_state"], "context": phone_context},
		{"name": "GameScreen", "object": screen, "snapshot": document["game_screen_state"], "context": {}},
	]:
		var validation: Dictionary = _save_manager.validate_component_snapshot(
			String(contract["name"]),
			contract["object"] as Object,
			contract["snapshot"] as Dictionary,
			contract["context"] as Dictionary
		)
		if not bool(validation.get("ok", false)):
			screen.queue_free()
			_is_creating_shift = false
			return validation
	var phone_restore: Variant = phone.callv(&"restore_snapshot", [document["phone_state"], phone_context])
	if not _is_ok_result(phone_restore):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "恢复电话状态失败：%s" % _describe_result(phone_restore)}
	var phone_bind: Variant = story.call(&"set_phone_system", phone)
	if not _is_ok_result(phone_bind):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "恢复后连接 PhoneSystem 失败：%s" % _describe_result(phone_bind)}
	var records_value: Variant = phone.call(&"get_call_records")
	if not records_value is Array:
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "恢复后的电话没有返回真实来电记录，拒绝继续。"}
	var record_event_ids: PackedStringArray = PackedStringArray()
	for raw_record: Variant in records_value as Array:
		if raw_record is Dictionary:
			record_event_ids.append(String((raw_record as Dictionary).get("event_id", "")))
	var story_context: Dictionary = {
		"phone_system": phone,
		"call_record_event_ids": record_event_ids,
		"current_game_tick": int(current_tick_result["value"]),
	}
	var story_validation: Dictionary = _save_manager.validate_component_snapshot("StoryEngine", story, document["story_state"] as Dictionary, story_context)
	if not bool(story_validation.get("ok", false)):
		screen.queue_free()
		_is_creating_shift = false
		return story_validation
	var story_restore: Variant = story.callv(&"restore_snapshot", [document["story_state"], story_context])
	if not _is_ok_result(story_restore):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "恢复剧情状态失败：%s" % _describe_result(story_restore)}
	var clock_restore: Variant = _game_clock.callv(&"restore_snapshot", [document["game_clock_state"], {"defer_running": true}])
	if not _is_ok_result(clock_restore):
		screen.queue_free()
		_is_creating_shift = false
		return {"ok": false, "message": "恢复游戏时钟失败：%s" % _describe_result(clock_restore)}
	var bind_result: Dictionary = screen.bind_runtime(story, phone, _game_clock)
	if not bool(bind_result.get("ok", false)):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "绑定已恢复 GameScreen 失败：%s" % String(bind_result.get("message", "未知原因。"))}
	var screen_restore: Variant = screen.call(&"restore_snapshot", document["game_screen_state"])
	if not _is_ok_result(screen_restore):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "恢复保存视图失败：%s" % _describe_result(screen_restore)}
	var game_clock_connect: Variant = story.call(&"connect_game_clock", _game_clock)
	if not _is_ok_result(game_clock_connect):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "连接恢复后的 GameClock 失败：%s" % _describe_result(game_clock_connect)}
	_story_engine = story
	_phone_system = phone
	_game_screen = screen
	if not _connect_ending_signal():
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "无法监听恢复后的 02:00 收束。"}
	_connect_game_screen_save_signals()
	# 剧情槽不携带设置副本；在 hidden staging 中先完整应用当前全局设置。
	# 任何设置映射失败都不能提交半恢复的 SHIFT 或替换读取槽位页面。
	if _settings_manager == null or not is_instance_valid(_settings_manager) or not _settings_manager.has_method(&"is_settings_loaded"):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "SettingsManager 不可用，不能完成读取后的设置应用。"}
	if not bool(_settings_manager.call(&"is_settings_loaded")):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "SettingsManager 未成功加载，拒绝用内存默认设置提交读取班次。"}
	var settings_snapshot_value: Variant = _settings_manager.call(&"get_settings_snapshot")
	if not settings_snapshot_value is Dictionary:
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "SettingsManager 未返回读取后设置快照。"}
	var settings_apply_result: Dictionary = _apply_settings_to_ui(settings_snapshot_value as Dictionary)
	if not bool(settings_apply_result.get("ok", false)):
		_discard_staged_loaded_runtime(screen, story)
		_is_creating_shift = false
		return {"ok": false, "message": "读取后应用当前全局设置失败：%s" % String(settings_apply_result.get("message", "未知原因。"))}
	# 直到此处 staging 中的运行时与全局设置均已成功。状态转换紧贴提交前发生，
	# 使此前任一失败都仍保持 LOAD_SLOTS 及未启动的时钟基线。
	_app_state = AppState.SHIFT
	_is_shift_started = true
	_commit_staged_game_screen()
	_bind_phone_audio(phone)
	var resume_result: Variant = _game_clock.call(&"resume_restored_clock")
	if not _is_ok_result(resume_result):
		_is_creating_shift = false
		return {"ok": false, "message": "恢复游戏时钟运行失败：%s" % _describe_result(resume_result)}
	_is_creating_shift = false
	print("[存档][load_ok] 已恢复本地槽位，当前游戏时刻=%s。" % String(_game_clock.call(&"get_display_time")))
	return {"ok": true}


func _commit_staged_game_screen() -> void:
	if _game_screen == null or not is_instance_valid(_game_screen):
		return
	if _current_screen != null and is_instance_valid(_current_screen) and _current_screen != _game_screen:
		if _current_screen.get_parent() == _screen_host:
			_screen_host.remove_child(_current_screen)
		_current_screen.queue_free()
	_current_screen = _game_screen
	_game_screen.visible = true


## 读取恢复尚未提交到 ScreenHost 前的回滚路径。调用者仍停在 LOAD_SLOTS，
## 因此不得调用 _show_main_menu() 或替换 _current_screen。
func _discard_staged_loaded_runtime(screen: GameScreen, story: RefCounted) -> void:
	if screen != null and is_instance_valid(screen):
		if screen.has_method(&"release_runtime"):
			screen.call(&"release_runtime")
		if screen.get_parent() == _screen_host:
			_screen_host.remove_child(screen)
		screen.queue_free()
	if story != null and story.has_method(&"release_runtime"):
		story.call(&"release_runtime")
	_story_engine = null
	_phone_system = null
	_game_screen = null
	_is_shift_started = false
	_app_state = AppState.LOAD_SLOTS
	# deferred restore 会保留“待恢复运行”标记；读取提交前若放弃 staging，必须
	# 一并清掉它，避免槽位页期间或下一次操作时意外恢复旧班次的时钟。
	if _game_clock != null and is_instance_valid(_game_clock) and _game_clock.has_method(&"stop_for_runtime_disposal"):
		var stop_result: Variant = _game_clock.call(&"stop_for_runtime_disposal")
		if not _is_ok_result(stop_result):
			push_error("[存档][discard_staged_clock_stop_failed] %s" % _describe_result(stop_result))


func _start_new_shift() -> void:
	if _is_creating_shift:
		return
	_is_creating_shift = true
	_dispose_runtime()
	_game_clock = get_tree().root.get_node_or_null(NodePath("GameClock")) as Node
	if _game_clock == null:
		_fail_shift_creation("找不到 GameClock 自动加载节点，夜班未启动。")
		return
	if _game_clock.has_method(&"is_running") and bool(_game_clock.call(&"is_running")):
		_fail_shift_creation("GameClock 仍在运行，拒绝覆盖当前夜班。")
		return
	if not _game_clock.has_method(&"prepare_new_shift"):
		_fail_shift_creation("GameClock 缺少 prepare_new_shift() 新局预备接口。")
		return
	var prepare_result: Variant = _game_clock.call(&"prepare_new_shift")
	if not _is_ok_result(prepare_result):
		_fail_shift_creation("准备新夜班时钟失败：%s" % _describe_result(prepare_result))
		return

	var story_content_result: Dictionary = _load_validated_test_story()
	if not bool(story_content_result.get("ok", false)):
		_fail_shift_creation(String(story_content_result.get("message", "测试剧情数据加载失败。")))
		return

	_content_validation_result = story_content_result
	_phone_system = PHONE_SYSTEM_SCRIPT.new()
	_story_engine = STORY_ENGINE_SCRIPT.new()
	if not _check_runtime_result(_story_engine.call(&"set_phone_system", _phone_system), "连接 PhoneSystem"):
		return
	if not _check_runtime_result(_story_engine.call(&"configure_test_night_story", story_content_result), "配置已校验测试剧情"):
		return

	_game_screen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	if _game_screen == null:
		_fail_shift_creation("无法实例化 GameScreen。")
		return
	_replace_screen(_game_screen)
	if not _check_runtime_result(_game_screen.bind_runtime(_story_engine, _phone_system, _game_clock), "注入 GameScreen 运行时"):
		return
	_connect_game_screen_save_signals()
	if not _check_runtime_result(_story_engine.call(&"connect_game_clock", _game_clock), "连接 GameClock"):
		return
	if not _connect_ending_signal():
		return
	_bind_phone_audio(_phone_system)
	# 现在 StoryEngine、PhoneSystem、GameScreen 与 02:00 回调均完整绑定，
	# 所有成功路径才在此处发送一次正式 shift_started。
	_app_state = AppState.SHIFT
	_is_shift_started = true
	_game_clock.call(&"start_shift")
	_is_creating_shift = false
	var event_count: int = (story_content_result["events"] as Array).size()
	print("[应用][shift_started] 已加载并校验 %d 条测试剧情来电事件，当前状态=SHIFT。" % event_count)


func _connect_game_screen_save_signals() -> void:
	if _game_screen == null or not is_instance_valid(_game_screen):
		return
	var save_callback: Callable = Callable(self, "_on_shift_save_slot_requested")
	if not _game_screen.is_connected(&"save_slot_requested", save_callback):
		_game_screen.connect(&"save_slot_requested", save_callback)
	var open_callback: Callable = Callable(self, "_on_shift_save_panel_opened")
	if not _game_screen.is_connected(&"save_panel_opened", open_callback):
		_game_screen.connect(&"save_panel_opened", open_callback)
	var exit_callback: Callable = Callable(self, "_on_shift_return_to_menu_requested")
	if not _game_screen.is_connected(&"exit_requested", exit_callback):
		_game_screen.connect(&"exit_requested", exit_callback)


func _on_shift_save_panel_opened() -> void:
	_refresh_shift_save_slot_summaries()


func _refresh_shift_save_slot_summaries() -> void:
	if _save_manager == null or _game_screen == null or not is_instance_valid(_game_screen):
		return
	var summaries: Array[Dictionary] = _save_manager.get_slot_summaries("test_night_story", 1)
	var result: Dictionary = _game_screen.set_save_slot_summaries(summaries)
	if not bool(result.get("ok", false)):
		push_error("[应用][shift_save_slot_summary_error] %s" % String(result.get("message", "未知错误。")))


func _on_shift_save_slot_requested(slot_id: String) -> void:
	if _app_state != AppState.SHIFT or _save_manager == null or _game_screen == null:
		return
	var save_result: Dictionary = _save_manager.save_slot(
		slot_id,
		_content_validation_result,
		_game_clock,
		_story_engine,
		_phone_system,
		_game_screen
	)
	_game_screen.show_save_result(save_result)
	if bool(save_result.get("ok", false)):
		_refresh_shift_save_slot_summaries()


func _load_validated_test_story() -> Dictionary:
	var loader = CONTENT_LOADER_SCRIPT.new()
	var load_result: Variant = loader.load_json(content_source_path)
	if not _is_ok_result(load_result):
		return _startup_error("读取测试剧情数据失败：%s" % _describe_result(load_result))
	var loaded: Dictionary = load_result as Dictionary
	if not loaded.has("data"):
		return _startup_error("读取测试剧情数据失败：ContentLoader 成功结果缺少 data 字段。")

	var validator = CONTENT_VALIDATOR_SCRIPT.new()
	var validation_result: Variant = validator.validate_test_night_story(loaded["data"], content_source_path)
	if not _is_ok_result(validation_result):
		return _startup_error("测试剧情数据校验失败：%s" % _describe_result(validation_result))
	var validated: Dictionary = validation_result as Dictionary
	var events_value: Variant = validated.get("events")
	if not events_value is Array:
		return _startup_error("测试剧情数据校验失败：成功结果缺少 events 数组。")
	return validated.duplicate(true)


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
	ending.connect(&"load_game_requested", Callable(self, "request_load_game"))
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
	if _settings_manager != null and is_instance_valid(_settings_manager) and bool(_settings_manager.call(&"is_settings_loaded")):
		var snapshot_value: Variant = _settings_manager.call(&"get_settings_snapshot")
		if snapshot_value is Dictionary:
			var apply_result: Dictionary = _apply_settings_to_ui(snapshot_value as Dictionary)
			if not bool(apply_result.get("ok", false)):
				_show_shell_error("切换界面后无法应用当前设置：%s" % String(apply_result.get("message", "未知原因。")))


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
	_unbind_phone_audio()
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
	# 销毁一局运行时不能让自动加载的时钟脱离 StoryEngine 独自继续；这条公开
	# 生命周期接口不会发出结束或额外剧情事件，专供返回菜单/测试彻底释放使用。
	if _game_clock != null and is_instance_valid(_game_clock) and _game_clock.has_method(&"stop_for_runtime_disposal"):
		if bool(_game_clock.call(&"is_running")):
			var stop_result: Variant = _game_clock.call(&"stop_for_runtime_disposal")
			if not _is_ok_result(stop_result):
				push_error("[应用][clock_dispose_failed] %s" % _describe_result(stop_result))


## 电话音效绑定在本局运行时正式提交后才发生：隐藏的读取 staging 即使恢复为
## RINGING，也绝不能在校验失败或玩家仍停在槽位页时发出声音。
func _bind_phone_audio(phone_system: RefCounted) -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("PhoneAudioPlayer")) as Node
	if player == null or not player.has_method(&"bind_phone_system"):
		push_error("[音频][phone_audio_player_missing] 未找到 PhoneAudioPlayer，电话音效不可用。")
		return
	var result: Variant = player.call(&"bind_phone_system", phone_system)
	if not _is_ok_result(result):
		push_error("[音频][phone_audio_bind_failed] %s" % _describe_result(result))


func _unbind_phone_audio() -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("PhoneAudioPlayer")) as Node
	if player == null or not player.has_method(&"unbind_phone_system"):
		return
	player.call(&"unbind_phone_system")


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
	_show_main_menu()
	_show_shell_error("无法开始值班：%s" % message)


func _show_shell_error(message: String) -> void:
	_shell_error_label.text = "系统错误：%s" % message
	_shell_error_panel.visible = true
	push_error("[应用][lifecycle_error] %s" % message)


func _on_shift_return_to_menu_requested() -> void:
	if _app_state != AppState.SHIFT:
		return
	print("[应用][shift_return_requested] 玩家请求从夜班返回主界面。")
	_show_loading_screen(LoadingTarget.MAIN_MENU)


## 仅主菜单的“退出游戏”调用 SceneTree.quit；夜班菜单不会连接到此路由。
func _on_exit_requested() -> void:
	print("[应用][main_menu_exit_requested] 玩家请求退出程序。")
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


## 磁盘 JSON 会将数字恢复成 float；时钟 tick 仍只接受有限、无小数部分的整数。
func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	if number < -9_223_372_036_854_775_808.0 or number > 9_223_372_036_854_775_807.0:
		return {"ok": false}
	return {"ok": true, "value": int(number)}
