class_name GameScreen
extends Control
## 四个固定工作室视图的唯一导航控制器。
##
## 子视图只发出意图；本类将合法电话意图转交 PhoneSystem，并确保任意时刻
## 只有一个视图可见且接受鼠标输入。它还把权威电话、广播和当前视图合并为
## 派生的工作状态；剧情、时间和记录不在这里保存副本。

signal work_state_changed(previous_state: int, current_state: int, reason_ids: PackedStringArray)

enum WorkState {
	IDLE,
	ACTIVE,
}

const WORK_REASON_PHONE_RINGING: String = "phone_ringing"
const WORK_REASON_PHONE_CONNECTED: String = "phone_connected"
const WORK_REASON_DIALOGUE_CHOICE: String = "dialogue_choice"
const WORK_REASON_BROADCAST_PENDING: String = "broadcast_pending"
const WORK_REASON_COMPUTER_OPEN: String = "computer_open"

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
	_system_message_panel.visible = false
	_show_view_internal(VIEW_STUDIO, true)


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
		"send_player_broadcast",
		"get_active_dialogue_snapshot",
		"get_available_broadcasts",
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
	return {"ok": true}


## 公开导航入口。正常玩家导航仍只从总览热点或近景返回信号触发。
func show_view(view_id: String) -> Dictionary:
	if not _views_by_id.has(view_id):
		return _make_error("未知视图 ID：%s。" % view_id)
	if _is_ending and view_id != VIEW_COMPUTER:
		return {"ok": false, "message": "02:00 强制收束中，只能停留在电脑播出记录。"}
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


## 02:00 由 Main 传入 StoryEngine 已验证的权威播出记录。
func show_ending(record: Dictionary) -> Dictionary:
	if record.is_empty():
		return _make_error("02:00 收束缺少权威未授权播出记录。")
	_is_ending = true
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
		"02:00 强制收束中，已锁定在电脑播出记录。"
	)
	if not _is_ok_result(computer_return_lock_result):
		push_error("[游戏界面][computer_return_lock_error] %s" % str(computer_return_lock_result))
	_set_overview_hotspots_enabled(false, "02:00 强制收束中，已切换到电脑播出记录。")
	_system_message.text = "02:00 强制收束：线路与待触发事件已由 StoryEngine 终止。"
	_system_message_panel.visible = true
	_show_view_internal(VIEW_COMPUTER, true)
	var work_state_result: Dictionary = _sync_work_state_and_time_rate()
	if not bool(work_state_result.get("ok", false)):
		return work_state_result
	return {"ok": true}


func show_system_error(message: String) -> void:
	_system_message.text = "系统错误：%s" % message
	_system_message_panel.visible = true


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


## 由应用壳在替换本局 GameScreen 前调用。视图节点随后会被销毁；此处只清理
## 本控制器持有的运行时引用和自身回调，不能重置 StoryEngine 或 PhoneSystem。
func release_runtime() -> Dictionary:
	_cancel_view_transition()
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
		{"source": _phone_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _phone_closeup, "signal": &"answer_requested", "callback": Callable(self, "_on_answer_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_choice_requested", "callback": Callable(self, "_on_dialogue_choice_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_option_requested", "callback": Callable(self, "_on_dialogue_option_requested")},
		{"source": _phone_closeup, "signal": &"hang_up_requested", "callback": Callable(self, "_on_hang_up_requested")},
		{"source": _phone_closeup, "signal": &"finish_call_requested", "callback": Callable(self, "_on_finish_call_requested")},
		{"source": _computer_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _computer_closeup, "signal": &"broadcast_requested", "callback": Callable(self, "_on_broadcast_requested")},
		{"source": _door_window_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _global_status, "signal": &"phone_view_requested", "callback": Callable(self, "_on_phone_view_requested")},
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
		{"source": _phone_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _phone_closeup, "signal": &"answer_requested", "callback": Callable(self, "_on_answer_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_choice_requested", "callback": Callable(self, "_on_dialogue_choice_requested")},
		{"source": _phone_closeup, "signal": &"dialogue_option_requested", "callback": Callable(self, "_on_dialogue_option_requested")},
		{"source": _phone_closeup, "signal": &"hang_up_requested", "callback": Callable(self, "_on_hang_up_requested")},
		{"source": _phone_closeup, "signal": &"finish_call_requested", "callback": Callable(self, "_on_finish_call_requested")},
		{"source": _computer_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _computer_closeup, "signal": &"broadcast_requested", "callback": Callable(self, "_on_broadcast_requested")},
		{"source": _door_window_closeup, "signal": &"return_requested", "callback": Callable(self, "_on_closeup_return_requested")},
		{"source": _global_status, "signal": &"phone_view_requested", "callback": Callable(self, "_on_phone_view_requested")},
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
	var drafts_value: Variant = _story_engine.call(&"get_available_broadcasts")
	if not drafts_value is Array:
		return _make_error("StoryEngine.get_available_broadcasts() 必须返回 Array。")
	for raw_draft: Variant in drafts_value as Array:
		if not raw_draft is Dictionary:
			return _make_error("StoryEngine 返回了非 Dictionary 的广播稿。")
		var draft: Dictionary = raw_draft as Dictionary
		if not draft.has("is_available_to_send") or typeof(draft["is_available_to_send"]) != TYPE_BOOL:
			return _make_error("广播稿缺少布尔字段 is_available_to_send。")
		if bool(draft["is_available_to_send"]):
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


func _on_phone_view_requested() -> void:
	# 来电指示只导航，PhoneSystem 的 Ringing 状态保持不变。
	_handle_view_request(VIEW_PHONE)


func _handle_view_request(view_id: String) -> void:
	var result: Dictionary = show_view(view_id)
	if not bool(result.get("ok", false)):
		show_system_error(String(result.get("message", "视图切换失败。")))


func _on_answer_requested() -> void:
	_call_phone_action(&"answer_call", "接听", true)


func _on_dialogue_choice_requested() -> void:
	if _is_ending:
		show_system_error("对话选择失败：02:00 强制收束已执行。")
		return
	if _phone_system == null:
		show_system_error("电话操作失败：PhoneSystem 不可用。")
		return
	if _story_engine == null:
		show_system_error("电话操作失败：StoryEngine 不可用。")
		return
	var state_result: Variant = _phone_system.call(&"get_state_name")
	if typeof(state_result) != TYPE_STRING:
		show_system_error("电话操作失败：PhoneSystem 未返回有效状态。")
		return
	var state_name: String = String(state_result)
	if state_name == "CONNECTED":
		if _is_active_dialogue_terminal():
			show_system_error("本通电话的预制对话已经结束，请直接结束通话。")
			return
		if not _call_phone_action(&"enter_dialogue_choice", "进入对话选择", false):
			return
		var dialogue_result: Variant = _story_engine.call(&"begin_active_call_dialogue")
		if _is_ok_result(dialogue_result):
			_system_message.text = "预制对话已由 StoryEngine 开始。"
			_system_message_panel.visible = true
			return
		var restore_result: Variant = _phone_system.call(&"exit_dialogue_choice")
		var failure_reason: String = _describe_operation_failure(dialogue_result, "StoryEngine 未能开始预制对话。")
		if typeof(restore_result) != TYPE_BOOL or not bool(restore_result):
			failure_reason += "；同时无法将电话恢复为已接通状态。"
		show_system_error("进入对话选择失败：%s" % failure_reason)
	elif state_name == "DIALOGUE_CHOICE":
		show_system_error("当前正在等待预制回应，请点击上方的对话选项。")
	else:
		show_system_error("对话选择失败：当前电话状态 %s 不允许此操作。" % state_name)


func _on_dialogue_option_requested(option_id: String) -> void:
	if _is_ending:
		show_system_error("提交对话回应失败：02:00 强制收束已执行。")
		return
	if option_id.strip_edges().is_empty():
		show_system_error("提交对话回应失败：选项 ID 不能为空。")
		return
	if _story_engine == null or _phone_system == null:
		show_system_error("提交对话回应失败：StoryEngine 或 PhoneSystem 不可用。")
		return
	var selection_result: Variant = _story_engine.call(&"select_dialogue_option", option_id)
	if not _is_ok_result(selection_result):
		show_system_error("提交对话回应失败：%s" % _describe_operation_failure(selection_result, "StoryEngine 拒绝了该选项。"))
		return
	var selection: Dictionary = selection_result as Dictionary
	if not bool(selection.get("reached_terminal", false)):
		return
	var exit_result: Variant = _phone_system.call(&"exit_dialogue_choice")
	if typeof(exit_result) != TYPE_BOOL or not bool(exit_result):
		var reason: String = "PhoneSystem 拒绝将终止台词后的线路恢复为已接通。"
		if _phone_system.has_method(&"get_last_error"):
			reason = String(_phone_system.call(&"get_last_error"))
		show_system_error("提交对话回应失败：%s" % reason)
		return
	_system_message.text = "本轮预制对话结束，可结束通话。"
	_system_message_panel.visible = true


func _is_active_dialogue_terminal() -> bool:
	if _story_engine == null:
		return false
	var snapshot_value: Variant = _story_engine.call(&"get_active_dialogue_snapshot")
	if not snapshot_value is Dictionary:
		return false
	var snapshot: Dictionary = snapshot_value as Dictionary
	return not snapshot.is_empty() and bool(snapshot.get("is_terminal", false))


func _on_broadcast_requested(broadcast_id: String) -> void:
	var broadcast_result: Dictionary = {}
	if _is_ending:
		broadcast_result = {"ok": false, "message": "02:00 强制收束已发生，不能发送玩家广播。"}
	elif broadcast_id.strip_edges().is_empty():
		broadcast_result = {"ok": false, "message": "广播稿 ID 不能为空。"}
	elif _story_engine == null:
		broadcast_result = {"ok": false, "message": "StoryEngine 不可用，不能发送玩家广播。"}
	else:
		var result_value: Variant = _story_engine.call(&"send_player_broadcast", broadcast_id)
		if result_value is Dictionary:
			broadcast_result = result_value as Dictionary
		else:
			broadcast_result = {"ok": false, "message": "StoryEngine.send_player_broadcast() 未返回 Dictionary。"}
	var feedback_result: Variant = _computer_closeup.call(&"show_broadcast_feedback", broadcast_result)
	if not _is_ok_result(feedback_result):
		show_system_error("无法显示广播反馈：%s" % _describe_operation_failure(feedback_result, "电脑播出工作台不可用。"))
		return
	if not bool(broadcast_result.get("ok", false)):
		show_system_error("发送广播失败：%s" % String(broadcast_result.get("message", "未知原因。")))


func _on_hang_up_requested() -> void:
	_call_phone_action(&"hang_up", "主动挂断", true)


func _on_finish_call_requested() -> void:
	_call_phone_action(&"finish_call", "结束通话", true)


func _call_phone_action(method_name: StringName, action_name: String, needs_game_tick: bool) -> bool:
	if _is_ending:
		show_system_error("%s失败：02:00 强制收束已执行。" % action_name)
		return false
	if _phone_system == null:
		show_system_error("%s失败：PhoneSystem 不可用。" % action_name)
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
		_system_message.text = "%s意图已提交给 PhoneSystem。" % action_name
		_system_message_panel.visible = true
		return true
	var reason: String = "PhoneSystem 拒绝了该操作。"
	if _phone_system.has_method(&"get_last_error"):
		reason = String(_phone_system.call(&"get_last_error"))
	show_system_error("%s失败：%s" % [action_name, reason])
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
