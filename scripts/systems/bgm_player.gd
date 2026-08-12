class_name BgmPlayerService
extends Node
## 全局背景音乐播放器。
##
## 它独立于页面与本局运行时，因此主菜单、加载页和夜班之间只维持一个连续播放实例。
## 音量只服从既有 Ambience 总线，不能自行保存或改写任何设置、剧情或时钟状态。

const AMBIENCE_BUS_NAME: StringName = &"Ambience"
const BGM_STREAM_PATH: String = "res://音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg"

var _player: AudioStreamPlayer = null
var _source_stream: AudioStream = null
var _loop_stream: AudioStreamOggVorbis = null
var _has_reported_missing_bus: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _is_non_playback_environment():
		print("[音频][bgm_autostart_skipped] 当前为 Headless 或 Dummy 音频环境，不自动启动背景音乐。")
		return
	var start_result: Dictionary = ensure_playing()
	if not bool(start_result.get("ok", false)):
		push_error("[音频][bgm_start_failed] %s" % String(start_result.get("message", "未知原因。")))


func _exit_tree() -> void:
	_release_player()


## 在异常停止或测试主动停止后恢复同一个播放器；重复调用绝不叠加新的声音实例。
func ensure_playing() -> Dictionary:
	var player_result: Dictionary = _ensure_player()
	if not bool(player_result.get("ok", false)):
		return player_result
	if _player.playing:
		return {"ok": true, "already_playing": true}
	if _is_non_playback_environment():
		return {"ok": true, "already_playing": false, "playback_skipped": true}
	_player.play()
	print("[音频][bgm_started] stream=%s bus=%s loop_seconds=180.000。" % [BGM_STREAM_PATH, String(AMBIENCE_BUS_NAME)])
	return {"ok": true, "already_playing": false}


## 只读观测接口供 Headless 专项验证；不向页面公开播放器节点。
func get_playback_snapshot() -> Dictionary:
	return {
		"ok": _player != null and is_instance_valid(_player),
		"stream_path": BGM_STREAM_PATH,
		"bus_name": String(AMBIENCE_BUS_NAME),
		"player_count": 1 if _player != null and is_instance_valid(_player) else 0,
		"is_playing": _player.playing if _player != null and is_instance_valid(_player) else false,
		"is_loop_enabled": _loop_stream.loop if _loop_stream != null else false,
		"loop_offset_seconds": _loop_stream.loop_offset if _loop_stream != null else -1.0,
		"length_seconds": _loop_stream.get_length() if _loop_stream != null else -1.0,
	}


## 仅供 Headless 专项在退出前释放显式启动的解码资源；生产页面不得调用。
func stop_and_release_for_verification() -> void:
	_release_player()


func _ensure_player() -> Dictionary:
	if AudioServer.get_bus_index(AMBIENCE_BUS_NAME) < 0:
		if not _has_reported_missing_bus:
			_has_reported_missing_bus = true
			push_error("[音频][bgm_missing_bus] 缺少 Ambience Audio Bus，无法播放背景音乐。")
		return {"ok": false, "error_code": "missing_ambience_bus", "message": "缺少 Ambience Audio Bus。"}
	if _player != null and is_instance_valid(_player):
		return {"ok": true}
	_source_stream = load(BGM_STREAM_PATH) as AudioStream
	if _source_stream == null:
		return {"ok": false, "error_code": "missing_bgm_stream", "message": "无法加载三分钟背景音乐资源。"}
	_loop_stream = _source_stream.duplicate() as AudioStreamOggVorbis
	if _loop_stream == null:
		return {"ok": false, "error_code": "invalid_bgm_stream", "message": "三分钟背景音乐不是可循环的 Ogg Vorbis 资源。"}
	_loop_stream.loop = true
	_loop_stream.loop_offset = 0.0
	_player = AudioStreamPlayer.new()
	_player.name = "LoopingBgmPlayer"
	_player.stream = _loop_stream
	_player.bus = AMBIENCE_BUS_NAME
	_player.finished.connect(_on_player_finished)
	add_child(_player)
	return {"ok": true}


func _release_player() -> void:
	if _player == null or not is_instance_valid(_player):
		_loop_stream = null
		_source_stream = null
		return
	_player.stop()
	var finished_callback: Callable = Callable(self, "_on_player_finished")
	if _player.is_connected(&"finished", finished_callback):
		_player.disconnect(&"finished", finished_callback)
	_player.stream = null
	if _player.get_parent() == self:
		remove_child(_player)
	_player.free()
	_player = null
	_loop_stream = null
	_source_stream = null


func _is_non_playback_environment() -> bool:
	if DisplayServer.get_name().to_lower() == "headless":
		return true
	return AudioServer.get_driver_name().to_lower() == "dummy"


## 正常的 Ogg loop 不会走到这里；保留此分支以防音频后端异常结束时出现永久静音。
func _on_player_finished() -> void:
	if _player == null or not is_instance_valid(_player) or _player.playing:
		return
	_player.play()
	print("[音频][bgm_restarted_after_finish] 已恢复背景音乐播放。")
