class_name GameScreen
extends Control
## 四个固定工作室视图的唯一导航控制器。
##
## 子视图只发出意图；本类将合法电话意图转交 PhoneSystem，并确保任意时刻
## 只有一个视图可见且接受鼠标输入。它还把权威电话、广播和当前视图合并为
## 派生的工作状态；剧情、时间和记录不在这里保存副本。

signal work_state_changed(previous_state: int, current_state: int, reason_ids: PackedStringArray)
signal save_slot_requested(slot_id: String)
signal save_panel_opened
signal save_panel_closed
signal exit_requested

enum WorkState {
	IDLE,
	ACTIVE,
}

const WORK_REASON_PHONE_RINGING: String = "phone_ringing"
const WORK_REASON_PHONE_CONNECTED: String = "phone_connected"
const WORK_REASON_DIALOGUE_CHOICE: String = "dialogue_choice"
const WORK_REASON_BROADCAST_PENDING: String = "broadcast_pending"
const WORK_REASON_COMPUTER_OPEN: String = "computer_open"
const WORK_REASON_SETTINGS_OPEN: String = "settings_open"

const VIEW_STUDIO: String = "studio"
const VIEW_PHONE: String = "phone"
const VIEW_COMPUTER: String = "computer"
const VIEW_DOOR: String = "door"
const VIEW_IDS: Array[String] = [
	VIEW_STUDIO,
	VIEW_PHONE,
	VIEW_COMPUTER,
	VIEW_DOOR,
]

const TRANSITION_COMPUTER_SECONDS: float = 0.26
const TRANSITION_PHONE_SECONDS: float = 0.20
const TRANSITION_DOOR_SECONDS: float = 0.32
const TRANSITION_RETURN_TO_STUDIO_SECONDS: float = 0.24
## 短通知从请求到完全隐藏的总时长不得超过两秒。
const TRANSIENT_NOTICE_FADE_IN_SECONDS: float = 0.24
const TRANSIENT_NOTICE_HOLD_SECONDS: float = 1.50
const TRANSIENT_NOTICE_FADE_OUT_SECONDS: float = 0.24
const TRANSIENT_NOTICE_MAX_LIFETIME_SECONDS: float = TRANSIENT_NOTICE_FADE_IN_SECONDS + TRANSIENT_NOTICE_HOLD_SECONDS + TRANSIENT_NOTICE_FADE_OUT_SECONDS
const SAVE_SLOT_PANEL_SCENE: PackedScene = preload("res://scenes/ui/save_slot_panel.tscn")
const SETTINGS_PANEL_SCENE: PackedScene = preload("res://scenes/ui/settings_panel.tscn")
const SHIFT_CONTROL_BAR_SCENE: PackedScene = preload("res://scenes/ui/shift_control_bar.tscn")

var _story_engine: RefCounted = null
var _phone_system: RefCounted = null
var _game_clock: Node = null
var _views_by_id: Dictionary[String, Control] = {}
var _current_view_id: String = VIEW_STUDIO
var _is_ending: bool = false
var _are_view_signals_connected: bool = false
var _are_work_state_signals_connected: bool = false
var _work_state: WorkState = WorkState.IDLE
var _work_state_reason_ids: PackedStringArray = PackedStringArray()
var _is_motion_enabled: bool = true
var _is_view_transitioning: bool = false
var _view_transition: Tween = null
var _transition_serial: int = 0
var _save_slot_panel: SaveSlotPanel = null
var _settings_panel: SettingsPanel = null
var _shift_control_bar: Control = null
var _text_speed_multiplier: float = 1.0
var _system_message_tween: Tween = null
var _system_message_serial: int = 0
var _system_message_mode: String = "hidden"

@onready var _studio_overview: Control = $ViewHost/StudioOverview
@onready var _phone_closeup: Control = $ViewHost/PhoneCloseup
@onready var _computer_closeup: Control = $ViewHost/ComputerCloseup
@onready var _door_window_closeup: Control = $ViewHost/DoorWindowCloseup
@onready var _global_status: GlobalStatus = $GlobalStatus
@onready var _system_message: Label = $SystemMessagePanel/SystemMessage
@onready var _system_message_panel: PanelContainer = $SystemMessagePanel


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_views_by_id = {
		VIEW_STUDIO: _studio_overview,
		VIEW_PHONE: _phone_closeup,
		VIEW_COMPUTER: _computer_closeup,
		VIEW_DOOR: _door_window_closeup,
	}
	_hide_system_message_immediately()
	_show_view_internal(VIEW_STUDIO, true)


func _unhandled_input(event: InputEvent) -> void:
	if _is_ending or is_save_panel_open() or is_settings_panel_open():
		return
	if event.is_action_pressed(&"ui_cancel") and not event.is_echo():
		toggle_control_bar()
		get_viewport().set_input_as_handled()


## 由应用壳在内容数据校验通过后注入。这个方法不读取文件，也不启动时钟。
func bind_runtime(story_engine: RefCounted, phone_system: RefCounted, game_clock: Node) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	if phone_system == null:
		return _make_error("PhoneSystem 实例不能为空。")
	if not is_instance_valid(game_clock):
		return _make_error("GameClock 实例不可用。")
	var required_clock_methods: PackedStringArray = [
		"get_current_game_tick",
		"set_time_rate_mode",
		"get_time_rate_mode",
	]
	for method_name: String in required_clock_methods:
		if not game_clock.has_method(method_name):
			return _make_error("GameClock 缺少 %s() 接口。" % method_name)
	var required_phone_methods: PackedStringArray = [
		"answer_call",
		"enter_dialogue_choice",
		"exit_dialogue_choice",
		"hang_up",
		"finish_call",
		"get_last_error",
		"get_state_name",
	]
	for method_name: String in required_phone_methods:
		if not phone_system.has_method(method_name):
			return _make_error("PhoneSystem 缺少 %s() 接口。" % method_name)
	var required_story_methods: PackedStringArray = [
		"begin_active_call_dialogue",
		"select_dialogue_option",
		"send_broadcast_task",
		"get_active_dialogue_snapshot",
		"get_broadcast_tasks",
		"get_computer_entries",
		"get_computer_unread_count",
		"mark_computer_entry_read",
	]
	for method_name: String in required_story_methods:
		if not story_engine.has_method(method_name):
			return _make_error("StoryEngine 缺少 %s() 接口。" % method_name)

	_story_engine = story_engine
	_phone_system = phone_system
	_game_clock = game_clock
	_is_ending = false
	if not _bind_child_runtime(_phone_closeup, &"bind_phone_system", [_phone_system], "绑定电话近景"):
		return {"ok": false, "message": "无法绑定电话近景。"}
	if not _bind_child_runtime(_phone_closeup, &"bind_story_engine", [_story_engine], "绑定电话剧情"):
		return {"ok": false, "message": "无法绑定电话剧情。"}
	if not _bind_child_runtime(_studio_overview, &"bind_story_engine", [_story_engine], "绑定中央麦克风"):
		return {"ok": false, "message": "无法绑定中央麦克风。"}
	if not _bind_child_runtime(_computer_closeup, &"bind_phone_system", [_phone_system], "绑定电脑近景"):
		return {"ok": false, "message": "无法绑定电脑近景。"}
	if not _bind_child_runtime(_computer_closeup, &"bind_story_engine", [_story_engine], "绑定电脑剧情"):
		return {"ok": false, "message": "无法绑定电脑剧情。"}
	if not _bind_child_runtime(_global_status, &"bind_runtime", [_phone_system, _game_clock], "绑定全局状态条"):
		return {"ok": false, "message": "无法绑定全局状态条。"}
	var signal_result: Dictionary = _connect_view_signals()
	if not bool(signal_result.get("ok", false)):
		return signal_result
	var work_state_signal_result: Dictionary = _connect_work_state_signals()
	if not bool(work_state_signal_result.get("ok", false)):
		return work_state_signal_result
	_show_view_internal(VIEW_STUDIO, true)
	var work_state_result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(work_state_result.get("ok", false)):
		return work_state_result
	var settings_result: Dictionary = apply_current_settings()
	if not bool(settings_result.get("ok", false)):
		return settings_result
	return {"ok": true}


## 公开导航入口。正常玩家导航仍只从总览热点或近景返回信号触发。
func show_view(view_id: String) -> Dictionary:
	if not _views_by_id.has(view_id):
		return _make_error("未知视图 ID：%s。" % view_id)
	if _is_ending and view_id != VIEW_COMPUTER:
		return {"ok": false, "message": "02:00 强制收束中，只能停留在电脑夜班结束记录。"}
	_show_view_internal(view_id, false)
	var work_state_result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(work_state_result.get("ok", false)):
		return work_state_result
	return {"ok": true, "view_id": view_id}


## 减少动态时，视图切换和全局互动反馈均立即完成；不会改变导航或剧情状态。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	if not _is_motion_enabled:
		_cancel_view_transition()
	var motion_targets: Array[Object] = [
		_studio_overview,
		_phone_closeup,
		_computer_closeup,
		_door_window_closeup,
		_global_status,
	]
	for target: Object in motion_targets:
		if target == null or not target.has_method(&"set_motion_enabled"):
			return _make_error("视图缺少 set_motion_enabled() 接口。")
		var result: Variant = target.call(&"set_motion_enabled", is_enabled)
		if not _is_ok_result(result):
			return _make_error("设置减少动态失败：%s" % str(result))
	return {"ok": true, "motion_enabled": _is_motion_enabled}


## 读取全局设置后由 Main 或场景初始化调用。该入口不写入设置、不接触
## StoryEngine / GameClock / PhoneSystem，仅将公开快照映射为当前 UI 表现。
func apply_current_settings() -> Dictionary:
	var settings_manager: Node = get_tree().root.get_node_or_null(NodePath("SettingsManager")) as Node
	if settings_manager == null or not settings_manager.has_method(&"get_settings_snapshot") or not settings_manager.has_method(&"is_settings_loaded"):
		return _make_error("SettingsManager 不可用，无法应用当前设置。")
	if not bool(settings_manager.call(&"is_settings_loaded")):
		return _make_error("SettingsManager 未成功加载，不能把默认内存设置应用到夜班。")
	var snapshot_value: Variant = settings_manager.call(&"get_settings_snapshot")
	if not snapshot_value is Dictionary:
		return _make_error("SettingsManager 未返回有效设置快照。")
	return apply_settings_snapshot(snapshot_value as Dictionary)


func apply_settings_snapshot(snapshot: Dictionary) -> Dictionary:
	var validation: Dictionary = _validate_settings_snapshot(snapshot)
	if not bool(validation.get("ok", false)):
		return validation
	var motion_result: Dictionary = set_motion_enabled(not bool(snapshot["reduce_flashing"]))
	if not bool(motion_result.get("ok", false)):
		return motion_result
	if _computer_closeup == null or not _computer_closeup.has_method(&"set_crt_enabled"):
		return _make_error("电脑近景缺少 set_crt_enabled() 接口。")
	var crt_result: Variant = _computer_closeup.call(&"set_crt_enabled", bool(snapshot["crt_enabled"]))
	if not _is_ok_result(crt_result):
		return _make_error("应用 CRT 设置失败：%s" % str(crt_result))
	if _phone_closeup == null or not _phone_closeup.has_method(&"set_text_speed_multiplier"):
		return _make_error("电话近景缺少 set_text_speed_multiplier() 接口。")
	var text_speed: float = float(snapshot["text_speed"])
	var text_result: Variant = _phone_closeup.call(&"set_text_speed_multiplier", text_speed)
	if not _is_ok_result(text_result):
		return _make_error("应用逐字文字速度失败：%s" % str(text_result))
	_text_speed_multiplier = text_speed
	return {"ok": true}


func get_text_speed_multiplier() -> float:
	return _text_speed_multiplier


func _validate_settings_snapshot(snapshot: Dictionary) -> Dictionary:
	for field_name: String in ["text_speed", "reduce_flashing", "crt_enabled"]:
		if not snapshot.has(field_name):
			return _make_error("设置快照缺少字段：%s。" % field_name)
	if (typeof(snapshot["text_speed"]) != TYPE_FLOAT and typeof(snapshot["text_speed"]) != TYPE_INT) \
		or typeof(snapshot["reduce_flashing"]) != TYPE_BOOL \
		or typeof(snapshot["crt_enabled"]) != TYPE_BOOL:
		return _make_error("设置快照字段类型无效。")
	var text_speed: float = float(snapshot["text_speed"])
	if is_nan(text_speed) or is_inf(text_speed) or text_speed < 0.25 or text_speed > 4.0:
		return _make_error("设置快照 text_speed 超出 0.25 到 4.0。")
	return {"ok": true}


## 02:00 由 Main 传入 StoryEngine 已验证的权威播出记录。
func show_ending(record: Dictionary) -> Dictionary:
	if record.is_empty():
		return _make_error("02:00 收束缺少权威未授权播出记录。")
	_is_ending = true
	_close_save_panel()
	_close_settings_panel(false)
	_close_control_bar()
	if _phone_closeup.has_method(&"stop_text_presentation"):
		_phone_closeup.call(&"stop_text_presentation")
	# 02:00 具有最高优先级：先终止任何进行中的 Tween，再立即锁到电脑视图。
	_cancel_view_transition()
	var computer_result: Variant = _computer_closeup.call(&"show_unauthorized_broadcast", record)
	if not _is_ok_result(computer_result):
		show_system_error("无法显示 02:00 未授权播出记录：%s" % str(computer_result))
		_show_view_internal(VIEW_COMPUTER, true)
		return {"ok": false, "message": "电脑收束记录显示失败。"}
	if _phone_closeup.has_method(&"set_actions_enabled"):
		var phone_lock_result: Variant = _phone_closeup.call(
			&"set_actions_enabled",
			false,
			"02:00 强制收束中，电话操作已终止。"
		)
		if not _is_ok_result(phone_lock_result):
			push_error("[游戏界面][phone_lock_error] %s" % str(phone_lock_result))
	var computer_return_lock_result: Variant = _computer_closeup.call(
		&"set_return_enabled",
		false,
		"02:00 强制收束中，已锁定在电脑夜班结束记录。"
	)
	if not _is_ok_result(computer_return_lock_result):
		push_error("[游戏界面][computer_return_lock_error] %s" % str(computer_return_lock_result))
	var microphone_lock_result: Variant = _studio_overview.call(
		&"set_microphone_enabled",
		false,
		"夜班已经结束，中央麦克风已关闭。"
	)
	if not _is_ok_result(microphone_lock_result):
		push_error("[游戏界面][microphone_lock_error] %s" % str(microphone_lock_result))
	_set_overview_hotspots_enabled(false, "02:00 强制收束中，已切换到电脑夜班结束记录。")
	_show_persistent_system_message("夜班已经结束，线路安静了下来。")
	_show_view_internal(VIEW_COMPUTER, true)
	var work_state_result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(work_state_result.get("ok", false)):
		return work_state_result
	return {"ok": true}


func show_system_error(message: String) -> void:
	_show_persistent_system_message("提示：%s" % _player_safe_message(message))


## 用于接听、挂断等低信息量反馈。单一 Panel 不会叠出多个框，每次均从透明渐入。
func show_transient_notice(message: String) -> void:
	if message.strip_edges().is_empty():
		return
	_cancel_system_message_tween()
	_system_message_serial += 1
	var serial: int = _system_message_serial
	_system_message_mode = "transient"
	_system_message.text = message
	_system_message_panel.visible = true
	# 每条短通知独立从透明开始；不能继承常驻错误或上一条通知的满不透明状态。
	_set_system_message_alpha(0.0)
	_system_message_tween = create_tween()
	_system_message_tween.set_process_mode(Tween.TWEEN_PROCESS_IDLE)
	_system_message_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	# 使用方法 Tween 而非属性子路径，确保 CanvasItem 的 alpha 在所有渲染后端均逐帧插值。
	_system_message_tween.tween_method(_set_system_message_alpha, 0.0, 1.0, TRANSIENT_NOTICE_FADE_IN_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_system_message_tween.tween_interval(TRANSIENT_NOTICE_HOLD_SECONDS)
	_system_message_tween.tween_method(_set_system_message_alpha, 1.0, 0.0, TRANSIENT_NOTICE_FADE_OUT_SECONDS).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_system_message_tween.tween_callback(_finish_transient_notice.bind(serial))


## 供自动化验证读取；不承载剧情状态，也不允许调用方修改通知流程。
func get_transient_notice_timing_snapshot() -> Dictionary:
	var snapshot: Dictionary = {
		"mode": _system_message_mode,
		"is_visible": _system_message_panel.visible,
		"alpha": _get_system_message_alpha(),
		"fade_in_seconds": TRANSIENT_NOTICE_FADE_IN_SECONDS,
		"hold_seconds": TRANSIENT_NOTICE_HOLD_SECONDS,
		"fade_out_seconds": TRANSIENT_NOTICE_FADE_OUT_SECONDS,
		"max_lifetime_seconds": TRANSIENT_NOTICE_MAX_LIFETIME_SECONDS,
	}
	snapshot.make_read_only()
	return snapshot


func _show_persistent_system_message(message: String) -> void:
	_cancel_system_message_tween()
	_system_message_serial += 1
	_system_message_mode = "persistent"
	_system_message.text = message
	_system_message_panel.visible = true
	_set_system_message_alpha(1.0)


func _hide_system_message_immediately() -> void:
	_cancel_system_message_tween()
	_system_message_serial += 1
	_system_message_mode = "hidden"
	_system_message_panel.visible = false
	_set_system_message_alpha(0.0)


func _cancel_system_message_tween() -> void:
	if _system_message_tween != null and _system_message_tween.is_valid():
		_system_message_tween.kill()
	_system_message_tween = null


func _finish_transient_notice(serial: int) -> void:
	if serial != _system_message_serial or _system_message_mode != "transient":
		return
	_system_message_tween = null
	_system_message_mode = "hidden"
	_system_message_panel.visible = false
	_set_system_message_alpha(0.0)


func _get_system_message_alpha() -> float:
	return clampf(_system_message_panel.modulate.a, 0.0, 1.0)


func _set_system_message_alpha(alpha: float) -> void:
	var color: Color = _system_message_panel.modulate
	color.a = clampf(alpha, 0.0, 1.0)
	_system_message_panel.modulate = color


## 底层契约错误会包含实现名、数据类型和内部 ID；它们只进入日志，不能进入玩家提示。
func _player_safe_message(message: String) -> String:
	var forbidden_terms: PackedStringArray = ["预制对话", "StoryEngine", "PhoneSystem", "System", "system", "Dictionary", "option_id", "稳定 ID", "电话状态", "工作状态", "SettingsManager", "SaveManager", "GameClock", " JSON", " ID", "接口", "快照", "错误码"]
	for term: String in forbidden_terms:
		if message.contains(term):
			print("[游戏界面][player_message_filtered] %s" % message)
			return "暂时无法完成此操作，请稍后再试。"
	return message


func get_current_view_id() -> String:
	return _current_view_id


func get_work_state() -> WorkState:
	return _work_state


func get_work_state_name() -> String:
	return WorkState.keys()[_work_state]


func get_work_state_snapshot() -> Dictionary:
	var snapshot: Dictionary = {
		"state": _work_state,
		"state_name": get_work_state_name(),
		"reason_ids": _work_state_reason_ids.duplicate(),
		"uses_realtime_rate": _work_state == WorkState.ACTIVE,
	}
	snapshot.make_read_only()
	return snapshot


func is_ending() -> bool:
	return _is_ending


func is_motion_enabled() -> bool:
	return _is_motion_enabled


func is_view_transitioning() -> bool:
	return _is_view_transitioning


## 存档只保存界面展示位置，不承载 StoryEngine / PhoneSystem 的任何权威剧情状态。
func create_snapshot() -> Dictionary:
	if _is_ending:
		return {"ok": false, "error_code": "ending_active", "message": "02:00 强制收束中不能保存界面状态。"}
	var active_category: String = _read_active_computer_category()
	if active_category.is_empty():
		return {"ok": false, "error_code": "invalid_computer_category", "message": "电脑当前页签无效，不能保存。"}
	return {
		"ok": true,
		"snapshot": {
			"system_id": "game_screen",
			"snapshot_version": 1,
			"current_view_id": _current_view_id,
			"computer_active_category": active_category,
		},
	}


func validate_snapshot(snapshot: Dictionary, _context: Dictionary = {}) -> Dictionary:
	for field_name: String in ["system_id", "snapshot_version", "current_view_id", "computer_active_category"]:
		if not snapshot.has(field_name):
			return {"ok": false, "error_code": "missing_field", "message": "GameScreen 存档缺少字段：%s。" % field_name}
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != "game_screen":
		return {"ok": false, "error_code": "invalid_system_id", "message": "GameScreen 存档 system_id 无效。"}
	var version_result: Dictionary = _read_exact_integer(snapshot["snapshot_version"])
	if not bool(version_result.get("ok", false)) or int(version_result["value"]) != 1:
		return {"ok": false, "error_code": "unsupported_snapshot_version", "message": "GameScreen 存档版本不受支持。"}
	if typeof(snapshot["current_view_id"]) != TYPE_STRING or not VIEW_IDS.has(String(snapshot["current_view_id"])):
		return {"ok": false, "error_code": "invalid_view_id", "message": "GameScreen 存档包含未知固定视图。"}
	if typeof(snapshot["computer_active_category"]) != TYPE_STRING or not ComputerCloseup.PAGE_CATEGORIES.has(String(snapshot["computer_active_category"])):
		return {"ok": false, "error_code": "invalid_computer_category", "message": "GameScreen 存档包含未知电脑页签。"}
	return {"ok": true}


func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation.get("ok", false)):
		return validation
	if _is_ending:
		return {"ok": false, "error_code": "ending_active", "message": "02:00 收束中的界面不能恢复普通班次存档。"}
	var category_result: Variant = _computer_closeup.call(&"select_category", String(snapshot["computer_active_category"]))
	if not _is_ok_result(category_result):
		return {"ok": false, "error_code": "computer_restore_failed", "message": "恢复电脑页签失败：%s" % _describe_operation_failure(category_result, "未知原因。")}
	_show_view_internal(String(snapshot["current_view_id"]), true)
	var sync_result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(sync_result.get("ok", false)):
		return sync_result
	return {"ok": true}


func set_save_slot_summaries(summaries: Array[Dictionary]) -> Dictionary:
	if _save_slot_panel == null or not is_instance_valid(_save_slot_panel):
		return {"ok": false, "error_code": "save_panel_closed", "message": "存档界面未打开。"}
	return _save_slot_panel.set_slot_summaries(summaries)


func show_save_result(result: Dictionary) -> void:
	if _save_slot_panel == null or not is_instance_valid(_save_slot_panel):
		return
	var panel_result: Dictionary = _save_slot_panel.handle_save_result(result)
	if not bool(panel_result.get("ok", false)) and bool(result.get("ok", false)):
		show_system_error("保存完成后无法关闭存档界面：%s" % String(panel_result.get("message", "未知原因。")))


func is_save_panel_open() -> bool:
	return _save_slot_panel != null and is_instance_valid(_save_slot_panel)


func is_settings_panel_open() -> bool:
	return _settings_panel != null and is_instance_valid(_settings_panel)


func is_control_bar_open() -> bool:
	return _shift_control_bar != null and is_instance_valid(_shift_control_bar)


## ESC 调用的公开入口。控制栏本身不改变工作状态或游戏时间倍率。
func toggle_control_bar() -> Dictionary:
	if _is_ending:
		return {"ok": false, "message": "02:00 强制收束中不能打开控制栏。"}
	if is_control_bar_open():
		_close_control_bar()
		_play_button_click()
		return {"ok": true, "is_open": false}
	_shift_control_bar = SHIFT_CONTROL_BAR_SCENE.instantiate() as Control
	if _shift_control_bar == null:
		return _make_error("无法实例化 ESC 控制栏。")
	_shift_control_bar.z_index = 40
	_shift_control_bar.connect(&"settings_requested", Callable(self, "_on_control_bar_settings_requested"))
	_shift_control_bar.connect(&"save_requested", Callable(self, "_on_control_bar_save_requested"))
	_shift_control_bar.connect(&"exit_requested", Callable(self, "_on_control_bar_exit_requested"))
	add_child(_shift_control_bar)
	_refresh_control_bar_availability()
	_shift_control_bar.call(&"focus_first_action")
	_play_button_click()
	return {"ok": true, "is_open": true}


## 由应用壳在替换本局 GameScreen 前调用。视图节点随后会被销毁；此处只清理
## 本控制器持有的运行时引用和自身回调，不能重置 StoryEngine 或 PhoneSystem。
func release_runtime() -> Dictionary:
	_cancel_view_transition()
	_hide_system_message_immediately()
	_close_save_panel()
	_close_settings_panel(false)
	_close_control_bar()
	if _phone_closeup != null and _phone_closeup.has_method(&"stop_text_presentation"):
		_phone_closeup.call(&"stop_text_presentation")
	_disconnect_view_signals()
	_disconnect_work_state_signals()
	_story_engine = null
	_phone_system = null
	_game_clock = null
	_work_state = WorkState.IDLE
	_work_state_reason_ids = PackedStringArray()
	return {"ok": true}


func _connect_view_signals() -> Dictionary:
	if _are_view_signals_connected:
		return {"ok": true}
	var contracts: Array[Dictionary] = [
		{"source": _studio_overview, "signal": &"view_requested", "callback": Callable(self, "_on_overview_view_requested")},
		{"source": _studio_overview, "signal": &"broadcast_requested", "callback": Callable(self, "_on_broadcast_requested")},
		{"source": _studio_overview, "signal": &"microphone_panel_opened", "callback": Callable(self, "_on_microphone_panel_opened")},
		{"source": _studio_overview, "signal": &"microphone_panel_closed", "callback": Callable(self, "_on_microphone_panel_closed")},
		{"source": _phone_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _phone_closeup, "signal": &"answer_requested", "callback": Callable(self, "_on_answer_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_choice_requested", "callback": Callable(self, "_on_dialogue_choice_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_option_requested", "callback": Callable(self, "_on_dialogue_option_requested")},
		{"source": _phone_closeup, "signal": &"hang_up_requested", "callback": Callable(self, "_on_hang_up_requested")},
		{"source": _phone_closeup, "signal": &"finish_call_requested", "callback": Callable(self, "_on_finish_call_requested")},
		{"source": _computer_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _computer_closeup, "signal": &"computer_entry_open_requested", "callback": Callable(self, "_on_computer_entry_open_requested")},
		{"source": _door_window_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
	]
	for contract: Dictionary in contracts:
		var source: Object = contract["source"] as Object
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		if source == null or not source.has_signal(signal_name):
			return _make_error("视图缺少信号 %s。" % signal_name)
		if source.is_connected(signal_name, callback):
			continue
		var connect_result: Error = source.connect(signal_name, callback)
		if connect_result != OK:
			return _make_error("无法连接视图信号 %s，错误码=%d。" % [signal_name, connect_result])
	_are_view_signals_connected = true
	return {"ok": true}


func _disconnect_view_signals() -> void:
	if not _are_view_signals_connected:
		return
	var contracts: Array[Dictionary] = [
		{"source": _studio_overview, "signal": &"view_requested", "callback": Callable(self, "_on_overview_view_requested")},
		{"source": _studio_overview, "signal": &"broadcast_requested", "callback": Callable(self, "_on_broadcast_requested")},
		{"source": _studio_overview, "signal": &"microphone_panel_opened", "callback": Callable(self, "_on_microphone_panel_opened")},
		{"source": _studio_overview, "signal": &"microphone_panel_closed", "callback": Callable(self, "_on_microphone_panel_closed")},
		{"source": _phone_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _phone_closeup, "signal": &"answer_requested", "callback": Callable(self, "_on_answer_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_choice_requested", "callback": Callable(self, "_on_dialogue_choice_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_option_requested", "callback": Callable(self, "_on_dialogue_option_requested")},
		{"source": _phone_closeup, "signal": &"hang_up_requested", "callback": Callable(self, "_on_hang_up_requested")},
		{"source": _phone_closeup, "signal": &"finish_call_requested", "callback": Callable(self, "_on_finish_call_requested")},
		{"source": _computer_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _computer_closeup, "signal": &"computer_entry_open_requested", "callback": Callable(self, "_on_computer_entry_open_requested")},
		{"source": _door_window_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
	]
	for contract: Dictionary in contracts:
		var source: Object = contract["source"] as Object
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		if source != null and source.is_connected(signal_name, callback):
			source.disconnect(signal_name, callback)
	_are_view_signals_connected = false


## 工作状态是电话、待播稿件和当前视图的派生结果，不取代这些系统各自的
## 权威状态。任何来源改变时都在同一处重算，并让 GameClock 与可见状态同步。
func _connect_work_state_signals() -> Dictionary:
	if _are_work_state_signals_connected:
		return {"ok": true}
	if _phone_system == null or not _phone_system.has_signal(&"state_changed"):
		return _make_error("PhoneSystem 缺少 state_changed 信号，无法同步工作状态。")
	if _story_engine == null or not _story_engine.has_signal(&"broadcast_state_changed"):
		return _make_error("StoryEngine 缺少 broadcast_state_changed 信号，无法同步工作状态。")
	var phone_callback: Callable = Callable(self, "_on_phone_state_changed")
	if not _phone_system.is_connected(&"state_changed", phone_callback):
		var connect_result: Error = _phone_system.connect(&"state_changed", phone_callback)
		if connect_result != OK:
			return _make_error("无法连接 PhoneSystem.state_changed，错误码=%d。" % connect_result)
	var broadcast_callback: Callable = Callable(self, "_on_broadcast_state_changed")
	if not _story_engine.is_connected(&"broadcast_state_changed", broadcast_callback):
		var broadcast_connect_result: Error = _story_engine.connect(&"broadcast_state_changed", broadcast_callback)
		if broadcast_connect_result != OK:
			if _phone_system.is_connected(&"state_changed", phone_callback):
				_phone_system.disconnect(&"state_changed", phone_callback)
			return _make_error("无法连接 StoryEngine.broadcast_state_changed，错误码=%d。" % broadcast_connect_result)
	_are_work_state_signals_connected = true
	return {"ok": true}


func _disconnect_work_state_signals() -> void:
	if not _are_work_state_signals_connected:
		return
	if _phone_system != null:
		var phone_callback: Callable = Callable(self, "_on_phone_state_changed")
		if _phone_system.is_connected(&"state_changed", phone_callback):
			_phone_system.disconnect(&"state_changed", phone_callback)
	if _story_engine != null:
		var broadcast_callback: Callable = Callable(self, "_on_broadcast_state_changed")
		if _story_engine.is_connected(&"broadcast_state_changed", broadcast_callback):
			_story_engine.disconnect(&"broadcast_state_changed", broadcast_callback)
	_are_work_state_signals_connected = false


func _on_phone_state_changed(_previous_state: int, _current_state: int, _event_id: String) -> void:
	_refresh_save_panel_availability()
	_refresh_control_bar_availability()
	_sync_work_state_or_show_error()


func _on_broadcast_state_changed() -> void:
	_sync_work_state_or_show_error()


func _sync_work_state_or_show_error() -> void:
	var result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(result.get("ok", false)):
		show_system_error(String(result.get("message", "无法同步工作状态与时间倍率。")))


func _sync_work_state_and_time_rate() -> Dictionary:
	if _game_clock == null or not is_instance_valid(_game_clock):
		return _make_error("GameClock 不可用，无法同步工作状态与时间倍率。")
	if _phone_system == null:
		return _make_error("PhoneSystem 不可用，无法同步工作状态。")
	if _story_engine == null:
		return _make_error("StoryEngine 不可用，无法同步待播广播状态。")
	var state_result: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_result) != TYPE_STRING:
		return _make_error("PhoneSystem 未返回有效状态，无法同步工作状态。")
	var phone_state_name: String = String(state_result)
	var next_reason_ids: PackedStringArray = PackedStringArray()
	match phone_state_name:
		"RINGING":
			next_reason_ids.append(WORK_REASON_PHONE_RINGING)
		"CONNECTED":
			next_reason_ids.append(WORK_REASON_PHONE_CONNECTED)
		"DIALOGUE_CHOICE":
			next_reason_ids.append(WORK_REASON_DIALOGUE_CHOICE)
		"IDLE", "ENDED", "MISSED":
			pass
		_:
			return _make_error("PhoneSystem 返回未知状态：%s。" % phone_state_name)
	if _current_view_id == VIEW_COMPUTER:
		next_reason_ids.append(WORK_REASON_COMPUTER_OPEN)
	if is_settings_panel_open():
		next_reason_ids.append(WORK_REASON_SETTINGS_OPEN)
	var pending_result: Dictionary = _has_pending_player_broadcast()
	if not bool(pending_result.get("ok", false)):
		return pending_result
	if bool(pending_result["has_pending_broadcast"]):
		next_reason_ids.append(WORK_REASON_BROADCAST_PENDING)

	var next_work_state: WorkState = WorkState.ACTIVE if not next_reason_ids.is_empty() else WorkState.IDLE
	var target_rate: GameClockService.TimeRate = GameClockService.TimeRate.SLOW if next_work_state == WorkState.ACTIVE else GameClockService.TimeRate.FAST
	var rate_result: Variant = _game_clock.call(&"set_time_rate_mode", target_rate)
	if not _is_ok_result(rate_result):
		return _make_error("GameClock 拒绝同步时间倍率：%s" % str(rate_result))

	var previous_work_state: WorkState = _work_state
	_work_state = next_work_state
	_work_state_reason_ids = next_reason_ids
	if not _global_status.has_method(&"show_work_state"):
		return _make_error("全局状态条缺少 show_work_state()，无法显示实际时间流速。")
	var display_result: Variant = _global_status.call(&"show_work_state", get_work_state_snapshot())
	if not _is_ok_result(display_result):
		return _make_error("全局状态条拒绝显示工作状态：%s" % str(display_result))
	if previous_work_state != _work_state:
		print("[%s][工作状态] %s -> %s，原因=%s。" % [
			String(_game_clock.call(&"get_display_time")),
			WorkState.keys()[previous_work_state],
			get_work_state_name(),
			str(_work_state_reason_ids),
		])
		work_state_changed.emit(previous_work_state, _work_state, _work_state_reason_ids.duplicate())
	return {
		"ok": true,
		"work_state": _work_state,
		"work_state_name": get_work_state_name(),
		"reason_ids": _work_state_reason_ids.duplicate(),
		"time_rate": target_rate,
	}


func _has_pending_player_broadcast() -> Dictionary:
	var tasks_value: Variant = _story_engine.call(&"get_broadcast_tasks")
	if not tasks_value is Array:
		return _make_error("StoryEngine.get_broadcast_tasks() 必须返回 Array。")
	for raw_task: Variant in tasks_value as Array:
		if not raw_task is Dictionary:
			return _make_error("StoryEngine 返回了非 Dictionary 的发布任务。")
		var task: Dictionary = raw_task as Dictionary
		if not task.has("is_publishable") or typeof(task["is_publishable"]) != TYPE_BOOL:
			return _make_error("发布任务缺少布尔字段 is_publishable。")
		if bool(task["is_publishable"]):
			return {"ok": true, "has_pending_broadcast": true}
	return {"ok": true, "has_pending_broadcast": false}


func _bind_child_runtime(view: Object, method_name: StringName, arguments: Array, context: String) -> bool:
	if view == null or not view.has_method(method_name):
		show_system_error("%s失败：视图缺少 %s() 接口。" % [context, method_name])
		return false
	var result: Variant = view.callv(method_name, arguments)
	if _is_ok_result(result):
		return true
	show_system_error("%s失败：%s" % [context, str(result)])
	return false


func _on_overview_view_requested(view_id: String) -> void:
	if view_id != VIEW_PHONE and view_id != VIEW_COMPUTER and view_id != VIEW_DOOR:
		show_system_error("工作室总览请求了不允许的视图：%s。" % view_id)
		return
	_handle_view_request(view_id)


func _on_closeup_return_requested() -> void:
	_handle_view_request(VIEW_STUDIO)


func _on_microphone_panel_opened() -> void:
	_play_button_click("microphone_open")


func _on_microphone_panel_closed() -> void:
	_play_button_click("microphone_close")


func _handle_view_request(view_id: String) -> void:
	var previous_view_id: String = _current_view_id
	var result: Dictionary = show_view(view_id)
	if not bool(result.get("ok", false)):
		show_system_error(String(result.get("message", "视图切换失败。")))
		return
	# 只在点击确实打开或关闭一个固定视图后播放；拒绝和原地请求不响。
	if previous_view_id != _current_view_id:
		_play_button_click("fixed_view_switch")


func _on_answer_requested() -> void:
	if not _call_phone_action(&"answer_call", "接听", true):
		return
	_play_button_click("answer_call")
	# 接听成功后立即进入首段权威对白；此时只展示对方发言，不展示回应选项。
	if _is_ending or _phone_system == null or _story_engine == null:
		show_system_error("这通电话暂时无法继续。")
		return
	if not _call_phone_action(&"enter_dialogue_choice", "继续通话", false):
		return
	var dialogue_result: Variant = _story_engine.call(&"begin_active_call_dialogue")
	if _is_ok_result(dialogue_result):
		_hide_system_message_immediately()
		return
	var restore_result: Variant = _phone_system.call(&"exit_dialogue_choice")
	if typeof(restore_result) != TYPE_BOOL or not bool(restore_result):
		push_error("[通话][answer_dialogue_restore_failed] 接听后无法恢复线路状态。")
	show_system_error("线路暂时无法继续，请稍后再试。")


func _on_dialogue_choice_requested() -> void:
	if _is_ending:
		show_system_error("夜班已经结束。")
		return
	if _phone_system == null:
		show_system_error("线路暂时不可用。")
		return
	if _story_engine == null:
		show_system_error("这通电话暂时无法继续。")
		return
	var state_result: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_result) != TYPE_STRING:
		show_system_error("线路暂时无法确认。")
		return
	var state_name: String = String(state_result)
	if state_name == "DIALOGUE_CHOICE":
		var reveal_result: Variant = _phone_closeup.call(&"reveal_dialogue_options") if _phone_closeup.has_method(&"reveal_dialogue_options") else {"ok": false}
		if _is_ok_result(reveal_result):
			_play_button_click("dialogue_choice_reveal")
		else:
			show_system_error("现在还没有可回应的内容。")
	else:
		show_system_error("现在还不能继续对话。")


func _on_dialogue_option_requested(option_id: String) -> void:
	if _is_ending:
		show_system_error("夜班已经结束。")
		return
	if option_id.strip_edges().is_empty():
		show_system_error("这句回应暂时不可用。")
		return
	if _story_engine == null or _phone_system == null:
		show_system_error("线路暂时无法回应，请稍后再试。")
		return
	var selection_result: Variant = _story_engine.call(&"select_dialogue_option", option_id)
	if not _is_ok_result(selection_result):
		show_system_error("这句回应没有送出，请再试一次。")
		return
	var selection: Dictionary = selection_result as Dictionary
	# 只在 StoryEngine 接受稳定 option_id 后播放；02:00 等拒绝路径不产生假反馈。
	_play_button_click("dialogue_option")
	if not bool(selection.get("reached_terminal", false)):
		return
	var exit_result: Variant = _phone_system.call(&"exit_dialogue_choice")
	if typeof(exit_result) != TYPE_BOOL or not bool(exit_result):
		show_system_error("线路暂时无法继续，请稍后再试。")
		return
	_hide_system_message_immediately()


func _is_active_dialogue_terminal() -> bool:
	if _story_engine == null:
		return false
	var snapshot_value: Variant = _story_engine.call(&"get_active_dialogue_snapshot")
	if not snapshot_value is Dictionary:
		return false
	var snapshot: Dictionary = snapshot_value as Dictionary
	return not snapshot.is_empty() and bool(snapshot.get("is_terminal", false))


func _on_broadcast_requested(task_id: String, information_item_ids: Array[String]) -> void:
	var broadcast_result: Dictionary = {}
	if _is_ending:
		broadcast_result = {"ok": false, "message": "夜班已经结束，无法播出。"}
	elif task_id.strip_edges().is_empty():
		broadcast_result = {"ok": false, "message": "这项发布任务暂时无法执行。"}
	elif information_item_ids.is_empty():
		broadcast_result = {"ok": false, "message": "至少选择一条已经收集的信息。"}
	elif _story_engine == null:
		broadcast_result = {"ok": false, "message": "播出暂时不可用。"}
	else:
		var result_value: Variant = _story_engine.call(&"send_broadcast_task", task_id, information_item_ids)
		if result_value is Dictionary:
			broadcast_result = result_value as Dictionary
		else:
			broadcast_result = {"ok": false, "message": "播出暂时不可用。"}
	# 只有 StoryEngine 真正接受任务与所选信息后才播放操作音；拒绝路径不得伪造成功反馈。
	if bool(broadcast_result.get("ok", false)):
		_play_button_click("microphone_broadcast")
	var feedback_result: Variant = _studio_overview.call(&"show_microphone_feedback", broadcast_result)
	if not _is_ok_result(feedback_result):
		push_error("[播出][feedback_display_failed] %s" % _describe_operation_failure(feedback_result, "中央麦克风不可用。"))
		show_system_error("播出结果暂时无法显示。")
		return
	if not bool(broadcast_result.get("ok", false)):
		show_system_error(String(broadcast_result.get("message", "播出没有成功，请稍后再试。")))


## 电脑只报告“玩家打开了哪一条”；StoryEngine 才能将其标记已读并推进陈述/事实。
func _on_computer_entry_open_requested(category: String, entry_id: String) -> void:
	if _is_ending:
		show_system_error("打开电脑条目失败：02:00 强制收束已执行。")
		return
	if category.strip_edges().is_empty() or entry_id.strip_edges().is_empty():
		show_system_error("这条记录暂时无法打开。")
		return
	if _story_engine == null:
		show_system_error("这条记录暂时无法打开。")
		return
	var mark_result_value: Variant = _story_engine.call(&"mark_computer_entry_read", category, entry_id)
	if not _is_ok_result(mark_result_value):
		push_error("[电脑][entry_read_failed] %s" % _describe_operation_failure(mark_result_value, "阅读操作被拒绝。"))
		show_system_error("这条记录暂时无法打开。")
		return
	if _computer_closeup == null or not _computer_closeup.has_method(&"show_entry_content"):
		show_system_error("这条记录暂时无法显示。")
		return
	var display_result: Variant = _computer_closeup.call(&"show_entry_content", category, entry_id)
	if not _is_ok_result(display_result):
		push_error("[电脑][entry_display_failed] %s" % _describe_operation_failure(display_result, "电脑近景不可用。"))
		show_system_error("这条记录暂时无法显示。")


func _on_hang_up_requested() -> void:
	if _call_phone_action(&"hang_up", "主动挂断", true):
		_play_button_click("hang_up")


func _on_finish_call_requested() -> void:
	if _call_phone_action(&"finish_call", "结束通话", true):
		_play_button_click("finish_call")


func _on_control_bar_save_requested() -> void:
	_close_control_bar()
	_open_save_panel()


func _on_control_bar_settings_requested() -> void:
	_close_control_bar()
	_open_settings_panel()


func _on_control_bar_exit_requested() -> void:
	_close_control_bar()
	exit_requested.emit()


func _open_save_panel() -> void:
	if _is_ending:
		show_system_error("02:00 强制收束中不能保存。")
		return
	if is_save_panel_open():
		_close_save_panel()
		return
	_save_slot_panel = SAVE_SLOT_PANEL_SCENE.instantiate() as SaveSlotPanel
	if _save_slot_panel == null:
		show_system_error("无法实例化存档界面。")
		return
	_save_slot_panel.z_index = 50
	_save_slot_panel.set_mode(SaveSlotPanel.Mode.SAVE)
	_save_slot_panel.slot_save_requested.connect(_on_save_slot_requested)
	_save_slot_panel.save_succeeded.connect(_on_save_panel_return_requested)
	_save_slot_panel.return_requested.connect(_on_save_panel_return_requested)
	add_child(_save_slot_panel)
	_refresh_save_panel_availability()
	save_panel_opened.emit()


func _open_settings_panel() -> void:
	if _is_ending:
		show_system_error("02:00 强制收束中不能打开设置。")
		return
	if is_settings_panel_open():
		_close_settings_panel()
		return
	var settings_manager: Node = get_tree().root.get_node_or_null(NodePath("SettingsManager")) as Node
	if settings_manager == null:
		show_system_error("设置暂时不可用。")
		return
	_settings_panel = SETTINGS_PANEL_SCENE.instantiate() as SettingsPanel
	if _settings_panel == null:
		show_system_error("无法实例化设置界面。")
		return
	var bind_result: Dictionary = _settings_panel.bind_settings_manager(settings_manager)
	if not bool(bind_result.get("ok", false)):
		_settings_panel.queue_free()
		_settings_panel = null
		push_error("[设置][panel_bind_failed] %s" % String(bind_result.get("message", "未知原因。")))
		show_system_error("设置暂时无法打开。")
		return
	_settings_panel.z_index = 60
	_settings_panel.closed.connect(_on_settings_panel_closed)
	add_child(_settings_panel)
	_sync_work_state_or_show_error()


func _on_settings_panel_closed() -> void:
	_close_settings_panel()


func _close_settings_panel(sync_work_state: bool = true) -> void:
	if _settings_panel == null or not is_instance_valid(_settings_panel):
		_settings_panel = null
		return
	_settings_panel.queue_free()
	_settings_panel = null
	if sync_work_state and _game_clock != null and is_instance_valid(_game_clock) and not _is_ending:
		_sync_work_state_or_show_error()


func _on_save_slot_requested(slot_id: String) -> void:
	if slot_id.strip_edges().is_empty():
		show_save_result({"ok": false, "message": "存档槽位不能为空。"})
		return
	if not _can_current_phone_save():
		show_save_result({"ok": false, "message": _get_current_save_block_reason()})
		_refresh_save_panel_availability()
		return
	save_slot_requested.emit(slot_id)


func _on_save_panel_return_requested() -> void:
	_close_save_panel()


func _close_save_panel() -> void:
	if _save_slot_panel == null or not is_instance_valid(_save_slot_panel):
		_save_slot_panel = null
		return
	_save_slot_panel.queue_free()
	_save_slot_panel = null
	save_panel_closed.emit()


func _close_control_bar() -> void:
	if _shift_control_bar == null or not is_instance_valid(_shift_control_bar):
		_shift_control_bar = null
		return
	_shift_control_bar.queue_free()
	_shift_control_bar = null


## 所有已确认的打开/关闭入口共用持久化 UI 声道；失败或无状态变化的点击不调用此方法。
func _play_button_click(context: String = "game_screen") -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	if player == null or not player.has_method(&"play_button_click"):
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，%s 点击音未播放。" % context)
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] %s 点击音播放失败：%s" % [context, str(result)])


func _refresh_control_bar_availability() -> void:
	if _shift_control_bar == null or not is_instance_valid(_shift_control_bar):
		return
	var can_save: bool = _can_current_phone_save() and not _is_ending
	var reason: String = _get_current_save_block_reason()
	if _is_ending:
		reason = "02:00 强制收束中不能保存。"
	var result_value: Variant = _shift_control_bar.call(&"set_save_availability", can_save, reason)
	if not result_value is Dictionary:
		push_error("[游戏界面][control_bar_refresh_error] ESC 控制栏未返回 Dictionary。")
		return
	var result: Dictionary = result_value as Dictionary
	if not bool(result.get("ok", false)):
		push_error("[游戏界面][control_bar_refresh_error] %s" % String(result.get("message", "未知错误。")))


func _refresh_save_panel_availability() -> void:
	if _save_slot_panel == null or not is_instance_valid(_save_slot_panel):
		return
	var can_save: bool = _can_current_phone_save() and not _is_ending
	var reason: String = _get_current_save_block_reason()
	if _is_ending:
		reason = "02:00 强制收束中不能保存。"
	var result: Dictionary = _save_slot_panel.set_save_availability(can_save, reason)
	if not bool(result.get("ok", false)):
		push_error("[游戏界面][save_panel_refresh_error] %s" % String(result.get("message", "未知错误。")))


func _can_current_phone_save() -> bool:
	return _phone_system != null and _phone_system.has_method(&"can_save") and bool(_phone_system.call(&"can_save"))


func _get_current_save_block_reason() -> String:
	if _phone_system == null or not _phone_system.has_method(&"get_save_block_reason"):
		return "电话系统未提供存档状态。"
	var reason: Variant = _phone_system.call(&"get_save_block_reason")
	return String(reason) if typeof(reason) == TYPE_STRING else "电话系统未返回存档限制原因。"


func _read_active_computer_category() -> String:
	if _computer_closeup == null or not _computer_closeup.has_method(&"get_active_category"):
		return ""
	var category: Variant = _computer_closeup.call(&"get_active_category")
	return String(category) if typeof(category) == TYPE_STRING else ""


func _read_exact_integer(value: Variant) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	if typeof(value) != TYPE_FLOAT:
		return {"ok": false}
	var number: float = float(value)
	if is_nan(number) or is_inf(number) or number != floor(number):
		return {"ok": false}
	return {"ok": true, "value": int(number)}


func _call_phone_action(method_name: StringName, action_name: String, needs_game_tick: bool) -> bool:
	if _is_ending:
		show_system_error("夜班已经结束。")
		return false
	if _phone_system == null:
		show_system_error("线路暂时不可用。")
		return false
	var arguments: Array = []
	if needs_game_tick:
		var tick_result: Dictionary = _get_current_game_tick()
		if not bool(tick_result.get("ok", false)):
			show_system_error("%s失败：%s" % [action_name, String(tick_result.get("message", "时钟不可用。"))])
			return false
		arguments.append(int(tick_result["game_tick"]))
	var result: Variant = _phone_system.callv(method_name, arguments)
	if typeof(result) == TYPE_BOOL and bool(result):
		show_transient_notice("%s成功。" % action_name)
		return true
	var reason: String = "线路暂时无法响应。"
	if _phone_system.has_method(&"get_last_error"):
		var raw_reason: String = String(_phone_system.call(&"get_last_error"))
		if not raw_reason.strip_edges().is_empty():
			push_error("[通话][phone_action_rejected] action=%s reason=%s" % [action_name, raw_reason])
	show_system_error("%s没有成功，请稍后再试。" % action_name)
	return false


func _describe_operation_failure(result: Variant, fallback_message: String) -> String:
	if result is Dictionary:
		var payload: Dictionary = result as Dictionary
		var message: String = String(payload.get("message", ""))
		if not message.strip_edges().is_empty():
			return message
	return fallback_message


func _get_current_game_tick() -> Dictionary:
	if _game_clock == null or not is_instance_valid(_game_clock):
		return {"ok": false, "message": "GameClock 不可用。"}
	var tick_result: Variant = _game_clock.call(&"get_current_game_tick")
	if typeof(tick_result) != TYPE_INT or int(tick_result) < 0:
		return {"ok": false, "message": "GameClock 未返回非负整数 tick。"}
	return {"ok": true, "game_tick": int(tick_result)}


func _show_view_internal(view_id: String, force_immediate: bool) -> void:
	var previous_view_id: String = _current_view_id
	_cancel_view_transition()
	_current_view_id = view_id
	for candidate_id: String in VIEW_IDS:
		var view: Control = _views_by_id[candidate_id]
		var is_active: bool = candidate_id == view_id
		view.visible = is_active
		view.mouse_filter = Control.MOUSE_FILTER_STOP if is_active else Control.MOUSE_FILTER_IGNORE
		_reset_view_visual_state(view)

	if force_immediate or not _is_motion_enabled or previous_view_id == view_id:
		return
	_start_view_transition(previous_view_id, view_id)


func _start_view_transition(previous_view_id: String, next_view_id: String) -> void:
	var target_view: Control = _views_by_id[next_view_id]
	var spec: Dictionary = _get_transition_spec(previous_view_id, next_view_id)
	var duration: float = float(spec["duration"])
	target_view.pivot_offset = target_view.size * 0.5
	target_view.scale = spec["start_scale"] as Vector2
	target_view.position = spec["start_position"] as Vector2
	target_view.self_modulate = Color(1.0, 1.0, 1.0, float(spec["start_alpha"]))

	_transition_serial += 1
	var serial: int = _transition_serial
	_is_view_transitioning = true
	_view_transition = create_tween()
	_view_transition.set_parallel(true)
	_view_transition.tween_property(target_view, "scale", Vector2.ONE, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_view_transition.tween_property(target_view, "position", Vector2.ZERO, duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_view_transition.tween_property(target_view, "self_modulate", Color.WHITE, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_view_transition.finished.connect(_on_view_transition_finished.bind(serial))


func _get_transition_spec(previous_view_id: String, next_view_id: String) -> Dictionary:
	if next_view_id == VIEW_STUDIO and previous_view_id != VIEW_STUDIO:
		return {
			"duration": TRANSITION_RETURN_TO_STUDIO_SECONDS,
			"start_scale": Vector2(1.045, 1.045),
			"start_position": Vector2.ZERO,
			"start_alpha": 0.72,
		}
	match next_view_id:
		VIEW_COMPUTER:
			return {
				"duration": TRANSITION_COMPUTER_SECONDS,
				"start_scale": Vector2(0.965, 0.965),
				"start_position": Vector2.ZERO,
				"start_alpha": 0.18,
			}
		VIEW_PHONE:
			return {
				"duration": TRANSITION_PHONE_SECONDS,
				"start_scale": Vector2(0.94, 0.94),
				"start_position": Vector2(36.0, 0.0),
				"start_alpha": 0.28,
			}
		VIEW_DOOR:
			return {
				"duration": TRANSITION_DOOR_SECONDS,
				"start_scale": Vector2(0.97, 0.97),
				"start_position": Vector2.ZERO,
				"start_alpha": 0.24,
			}
	return {
		"duration": TRANSITION_COMPUTER_SECONDS,
		"start_scale": Vector2.ONE,
		"start_position": Vector2.ZERO,
		"start_alpha": 1.0,
	}


func _on_view_transition_finished(serial: int) -> void:
	if serial != _transition_serial:
		return
	_view_transition = null
	_is_view_transitioning = false
	var active_view: Control = _views_by_id[_current_view_id]
	_reset_view_visual_state(active_view)


func _cancel_view_transition() -> void:
	_transition_serial += 1
	if _view_transition != null and _view_transition.is_valid():
		_view_transition.kill()
	_view_transition = null
	_is_view_transitioning = false
	for candidate_id: String in VIEW_IDS:
		_reset_view_visual_state(_views_by_id[candidate_id])


func _reset_view_visual_state(view: Control) -> void:
	view.scale = Vector2.ONE
	view.position = Vector2.ZERO
	view.self_modulate = Color.WHITE


func _set_overview_hotspots_enabled(is_enabled: bool, reason: String) -> void:
	if not _studio_overview.has_method(&"set_hotspot_enabled"):
		return
	for target_view: String in [VIEW_PHONE, VIEW_COMPUTER, VIEW_DOOR]:
		var result: Variant = _studio_overview.call(&"set_hotspot_enabled", target_view, is_enabled, reason)
		if not _is_ok_result(result):
			push_error("[游戏界面][overview_hotspot_error] %s" % str(result))


func _is_ok_result(result: Variant) -> bool:
	return result is Dictionary and bool((result as Dictionary).get("ok", false))


func _make_error(message: String) -> Dictionary:
	push_error("[游戏界面][game_screen_error] %s" % message)
	return {"ok": false, "message": message}
