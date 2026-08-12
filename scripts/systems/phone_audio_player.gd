class_name PhoneAudioPlayerService
extends Node
## 电话音效只订阅 PhoneSystem 的权威状态转移。
##
## 它不读取 UI，也不维护第二套线路状态。每局运行时由 Main 明确绑定一次；
## 读取响铃存档时，Main 在运行时提交后重新绑定，因此可从 PhoneSystem 的真实
## RINGING 状态恢复铃声，而不会让 staging 读取过程提前发声。

const UI_PHONE_BUS_NAME: StringName = &"UIPhone"
const PICKUP_STREAM: AudioStreamWAV = preload("res://音效/电话/164034__drni__fetap-pickup_trimmed.wav")
const HANGUP_STREAM: AudioStreamWAV = preload("res://音效/电话/164035__drni__fetap-hangup_trimmed.wav")
const RING_STREAM: AudioStreamWAV = preload("res://音效/电话/164036__drni__fetap-ring_trimmed.wav")
const PHONE_STATE_IDLE: int = 0
const PHONE_STATE_RINGING: int = 1
const PHONE_STATE_CONNECTED: int = 2
const PHONE_STATE_DIALOGUE_CHOICE: int = 3
const PHONE_STATE_ENDED: int = 4
const PHONE_STATE_MISSED: int = 5

var _bound_phone_system: RefCounted = null
var _ring_player: AudioStreamPlayer = null
var _pickup_player: AudioStreamPlayer = null
var _hangup_player: AudioStreamPlayer = null
var _ring_stream: AudioStreamWAV = null
var _is_ring_requested: bool = false
var _ring_start_count: int = 0
var _pickup_play_count: int = 0
var _hangup_play_count: int = 0
var _stop_all_count: int = 0
var _has_reported_missing_bus: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	unbind_phone_system()
	_release_players()


## Main 是唯一生产绑定方。切换到新一局、读取新存档或销毁运行时均会先停铃并断开旧实例。
func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	var validation: Dictionary = _validate_phone_system(phone_system)
	if not bool(validation.get("ok", false)):
		return validation
	if _bound_phone_system == phone_system:
		_sync_from_bound_phone()
		return {"ok": true, "already_bound": true}
	unbind_phone_system()
	_bound_phone_system = phone_system
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	var connect_result: Error = _bound_phone_system.connect(&"state_changed", callback)
	if connect_result != OK:
		_bound_phone_system = null
		return _make_error("phone_state_connect_failed", "无法监听 PhoneSystem.state_changed，错误码=%d。" % connect_result)
	_sync_from_bound_phone()
	return {"ok": true, "already_bound": false}


## 销毁本局或放弃读取 staging 时调用。它只处理声音订阅，不改写电话状态。
func unbind_phone_system() -> void:
	_stop_all_players()
	if _bound_phone_system == null:
		return
	var callback: Callable = Callable(self, "_on_phone_state_changed")
	if _bound_phone_system.is_connected(&"state_changed", callback):
		_bound_phone_system.disconnect(&"state_changed", callback)
	_bound_phone_system = null


## 只读专项观测接口；不向 UI 暴露播放器节点或电话控制权。
func get_playback_snapshot() -> Dictionary:
	var is_ring_player_valid: bool = _ring_player != null and is_instance_valid(_ring_player)
	return {
		"ok": true,
		"bus_name": String(UI_PHONE_BUS_NAME),
		"bound": _bound_phone_system != null,
		"bound_state": _get_bound_state_name(),
		"player_count": _get_player_count(),
		"is_ring_requested": _is_ring_requested,
		"is_ring_playing": _ring_player.playing if is_ring_player_valid else false,
		"ring_player_bus": String(_ring_player.bus) if is_ring_player_valid else "",
		"ring_playback_position_seconds": _ring_player.get_playback_position() if is_ring_player_valid else 0.0,
		"ring_loop_enabled": _ring_stream.loop_mode == AudioStreamWAV.LOOP_FORWARD if _ring_stream != null else false,
		"ring_length_seconds": _ring_stream.get_length() if _ring_stream != null else 0.0,
		"ring_loop_begin": _ring_stream.loop_begin if _ring_stream != null else -1,
		"ring_loop_end": _ring_stream.loop_end if _ring_stream != null else -1,
		"ring_start_count": _ring_start_count,
		"pickup_play_count": _pickup_play_count,
		"hangup_play_count": _hangup_play_count,
		"stop_all_count": _stop_all_count,
		"is_pickup_playing": _pickup_player.playing if _pickup_player != null and is_instance_valid(_pickup_player) else false,
		"is_hangup_playing": _hangup_player.playing if _hangup_player != null and is_instance_valid(_hangup_player) else false,
		"pickup_stream_path": PICKUP_STREAM.resource_path,
		"hangup_stream_path": HANGUP_STREAM.resource_path,
		"ring_stream_path": RING_STREAM.resource_path,
	}


## 仅供专项在同一进程内验证释放；生产流程只通过 unbind_phone_system() 停止本局声音。
func stop_and_release_for_verification() -> void:
	unbind_phone_system()
	_release_players()
	_ring_start_count = 0
	_pickup_play_count = 0
	_hangup_play_count = 0
	_stop_all_count = 0


func _on_phone_state_changed(previous_state: int, current_state: int, _event_id: String) -> void:
	var previous_name: String = _state_name_from_value(previous_state)
	var current_name: String = _state_name_from_value(current_state)
	if current_name == "RINGING":
		_start_ring()
		return
	if previous_name == "RINGING":
		_stop_ring()
	if current_name == "ENDED" and (previous_name == "CONNECTED" or previous_name == "DIALOGUE_CHOICE"):
		_play_hangup()
		return
	if previous_name == "RINGING" and current_name == "CONNECTED":
		_play_pickup()


func _sync_from_bound_phone() -> void:
	if _get_bound_state_name() == "RINGING":
		_start_ring()
	else:
		_stop_ring()


func _start_ring() -> void:
	if _is_ring_requested:
		return
	var player_result: Dictionary = _ensure_players()
	if not bool(player_result.get("ok", false)):
		push_error("[音频][phone_ring_start_failed] %s" % String(player_result.get("message", "未知原因。")))
		return
	_is_ring_requested = true
	_ring_start_count += 1
	if _is_non_playback_environment():
		return
	_ring_player.play()
	print("[音频][phone_ring_started] bus=%s loop=true。" % String(UI_PHONE_BUS_NAME))


func _stop_ring() -> void:
	_is_ring_requested = false
	if _ring_player != null and is_instance_valid(_ring_player):
		_ring_player.stop()


## 解绑代表本局电话运行时已切换或被销毁；不能让摘机/挂机尾音越过页面、存档或新局边界。
## 保留节点以避免同一进程内的后续班次重复分配，生产退出才由 _release_players() 真正释放。
func _stop_all_players() -> void:
	_stop_ring()
	for player: AudioStreamPlayer in [_pickup_player, _hangup_player]:
		if player != null and is_instance_valid(player):
			player.stop()
	_stop_all_count += 1


func _play_pickup() -> void:
	var player_result: Dictionary = _ensure_players()
	if not bool(player_result.get("ok", false)):
		push_error("[音频][phone_pickup_failed] %s" % String(player_result.get("message", "未知原因。")))
		return
	_pickup_play_count += 1
	if not _is_non_playback_environment():
		_pickup_player.play()


func _play_hangup() -> void:
	var player_result: Dictionary = _ensure_players()
	if not bool(player_result.get("ok", false)):
		push_error("[音频][phone_hangup_failed] %s" % String(player_result.get("message", "未知原因。")))
		return
	_hangup_play_count += 1
	if not _is_non_playback_environment():
		_hangup_player.play()


func _ensure_players() -> Dictionary:
	if AudioServer.get_bus_index(UI_PHONE_BUS_NAME) < 0:
		if not _has_reported_missing_bus:
			_has_reported_missing_bus = true
			push_error("[音频][phone_missing_bus] 缺少 UIPhone Audio Bus，无法播放电话音效。")
		return _make_error("missing_ui_phone_bus", "缺少 UIPhone Audio Bus。")
	if _ring_player != null and is_instance_valid(_ring_player):
		return {"ok": true}
	_ring_stream = RING_STREAM.duplicate() as AudioStreamWAV
	if _ring_stream == null:
		return _make_error("invalid_ring_stream", "电话铃声不是可循环 WAV 资源。")
	# Godot 的 WAV 导入在未在 Import 面板预设循环时会保留 loop_end=0。
	# 仅设置 LOOP_FORWARD 会把 0 当作立即到达的循环边界，播放器在首个混音块
	# 就结束。这里用完整 PCM 帧数明确指定边界，电话状态仍是唯一的停铃权威。
	var ring_frame_count: int = roundi(_ring_stream.get_length() * float(_ring_stream.mix_rate))
	if ring_frame_count <= 0:
		return _make_error("invalid_ring_length", "电话铃声 WAV 的长度或采样率无效。")
	_ring_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_ring_stream.loop_begin = 0
	_ring_stream.loop_end = ring_frame_count
	_ring_player = _create_player("PhoneRingPlayer", _ring_stream)
	_pickup_player = _create_player("PhonePickupPlayer", PICKUP_STREAM)
	_hangup_player = _create_player("PhoneHangupPlayer", HANGUP_STREAM)
	return {"ok": true}


func _create_player(player_name: String, stream: AudioStream) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.stream = stream
	player.bus = UI_PHONE_BUS_NAME
	add_child(player)
	return player


func _release_players() -> void:
	for player: AudioStreamPlayer in [_ring_player, _pickup_player, _hangup_player]:
		if player == null or not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	_ring_player = null
	_pickup_player = null
	_hangup_player = null
	_ring_stream = null
	_is_ring_requested = false


func _validate_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("missing_phone_system", "PhoneSystem 不能为空。")
	if not phone_system.has_signal(&"state_changed") or not phone_system.has_method(&"get_state_name"):
		return _make_error("invalid_phone_contract", "PhoneSystem 缺少 state_changed 或 get_state_name() 契约。")
	return {"ok": true}


func _get_bound_state_name() -> String:
	if _bound_phone_system == null or not _bound_phone_system.has_method(&"get_state_name"):
		return ""
	var state_value: Variant = _bound_phone_system.call(&"get_state_name")
	return String(state_value) if typeof(state_value) == TYPE_STRING else ""


func _state_name_from_value(state_value: int) -> String:
	if _bound_phone_system == null or not _bound_phone_system.has_method(&"get_state_name"):
		return ""
	# PhoneSystem 的枚举数字是稳定内部契约；仅在音频边界做显式映射，避免 UI 文案参与判断。
	match state_value:
		PHONE_STATE_IDLE:
			return "IDLE"
		PHONE_STATE_RINGING:
			return "RINGING"
		PHONE_STATE_CONNECTED:
			return "CONNECTED"
		PHONE_STATE_DIALOGUE_CHOICE:
			return "DIALOGUE_CHOICE"
		PHONE_STATE_ENDED:
			return "ENDED"
		PHONE_STATE_MISSED:
			return "MISSED"
	return ""


func _get_player_count() -> int:
	var count: int = 0
	for player: AudioStreamPlayer in [_ring_player, _pickup_player, _hangup_player]:
		if player != null and is_instance_valid(player):
			count += 1
	return count


func _is_non_playback_environment() -> bool:
	return DisplayServer.get_name().to_lower() == "headless" or AudioServer.get_driver_name().to_lower() == "dummy"


func _make_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
