class_name BgmPlayerService
extends Node
## 全局背景音乐播放器。
##
## 音乐页与夜班各有一个受本服务统一管理的播放器，避免页面自行维护音频真相。
## 两个播放器都只路由到既有 Ambience 总线；菜单曲的独立响度只写在菜单播放器，
## 因而不改变用户的环境音量设置，也不影响夜班曲或其他环境声。

const AMBIENCE_BUS_NAME: StringName = &"Ambience"
const MENU_BGM_STREAM_PATH: String = "res://音效/BGM/dream_2_ambience_loop_110s.ogg"
const SHIFT_BGM_STREAM_PATH: String = "res://音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg"
const MENU_LOOP_SECONDS: float = 110.0
const SHIFT_LOOP_SECONDS: float = 180.0
const MENU_BGM_VOLUME_DB: float = -4.0
const SHIFT_BGM_VOLUME_DB: float = 0.0
const SILENT_VOLUME_DB: float = -80.0
const MENU_TO_SHIFT_FADE_SECONDS: float = 2.0
const SHIFT_FADE_IN_SECONDS: float = 0.70
const SHIFT_TO_MENU_FADE_SECONDS: float = 0.55

enum PlaybackMode {
	MENU,
	MENU_TO_SHIFT,
	SHIFT,
}

var _menu_player: AudioStreamPlayer = null
var _shift_player: AudioStreamPlayer = null
var _menu_loop_stream: AudioStream = null
var _shift_loop_stream: AudioStream = null
var _transition_tween: Tween = null
var _playback_mode: PlaybackMode = PlaybackMode.MENU
var _has_reported_missing_bus: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if _is_non_playback_environment():
		print("[音频][bgm_autostart_skipped] 当前为 Headless 或 Dummy 音频环境，不自动启动背景音乐。")
		return
	var start_result: Dictionary = play_menu_bgm()
	if not bool(start_result.get("ok", false)):
		push_error("[音频][bgm_start_failed] %s" % String(start_result.get("message", "未知原因。")))


func _exit_tree() -> void:
	_cancel_transition()
	_release_players()


## 兼容旧调用点：它始终表达“确保菜单音乐可播放”，不再隐含夜班音乐。
func ensure_playing() -> Dictionary:
	return play_menu_bgm()


## 进入主菜单时调用。若夜班曲仍在播放，使用短交叉淡入淡出回到菜单曲。
func play_menu_bgm() -> Dictionary:
	var setup_result: Dictionary = _ensure_players()
	if not bool(setup_result.get("ok", false)):
		return setup_result
	if _playback_mode == PlaybackMode.MENU and _menu_player.playing:
		return {"ok": true, "already_playing": true, "mode": "menu"}
	if _playback_mode == PlaybackMode.MENU_TO_SHIFT:
		_cancel_transition()
		_stop_shift_player()
		_start_menu_player(MENU_BGM_VOLUME_DB)
		_playback_mode = PlaybackMode.MENU
		print("[音频][bgm_transition_cancelled] 加载流程已离开，恢复菜单音乐。")
		return {"ok": true, "mode": "menu", "transition_cancelled": true}
	if _playback_mode != PlaybackMode.SHIFT:
		_start_menu_player(MENU_BGM_VOLUME_DB)
		_playback_mode = PlaybackMode.MENU
		print("[音频][menu_bgm_started] stream=%s loop_seconds=%.3f volume_db=%.1f。" % [MENU_BGM_STREAM_PATH, MENU_LOOP_SECONDS, MENU_BGM_VOLUME_DB])
		return {"ok": true, "mode": "menu"}

	# 从夜班返回菜单也不能骤停；过渡期内两曲只在极短的交叉淡化中同时存在。
	_cancel_transition()
	_start_menu_player(SILENT_VOLUME_DB)
	_transition_tween = create_tween()
	_transition_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_transition_tween.set_parallel(true)
	_transition_tween.tween_property(_shift_player, "volume_db", SILENT_VOLUME_DB, SHIFT_TO_MENU_FADE_SECONDS)
	_transition_tween.tween_property(_menu_player, "volume_db", MENU_BGM_VOLUME_DB, SHIFT_TO_MENU_FADE_SECONDS)
	_transition_tween.set_parallel(false)
	_transition_tween.tween_callback(_finish_shift_to_menu_transition)
	_playback_mode = PlaybackMode.MENU
	print("[音频][bgm_shift_to_menu] 夜班音乐平滑切回菜单音乐。")
	return {"ok": true, "mode": "menu", "crossfading": true}


## Main 在开始值班且加载页出现的同一时刻调用。重复调用不会重置两秒倒计时。
func transition_to_shift_bgm() -> Dictionary:
	var setup_result: Dictionary = _ensure_players()
	if not bool(setup_result.get("ok", false)):
		return setup_result
	if _playback_mode == PlaybackMode.MENU_TO_SHIFT:
		return {"ok": true, "already_transitioning": true, "mode": "menu_to_shift"}
	if _playback_mode == PlaybackMode.SHIFT:
		return {"ok": true, "already_in_shift": true, "mode": "shift"}
	_cancel_transition()
	_start_menu_player(MENU_BGM_VOLUME_DB)
	_stop_shift_player()
	_transition_tween = create_tween()
	_transition_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_transition_tween.tween_property(_menu_player, "volume_db", SILENT_VOLUME_DB, MENU_TO_SHIFT_FADE_SECONDS)
	_transition_tween.tween_callback(_finish_menu_to_shift_fade)
	_playback_mode = PlaybackMode.MENU_TO_SHIFT
	print("[音频][bgm_menu_fade_started] 加载页开始，菜单音乐将在 %.1f 秒后停止。" % MENU_TO_SHIFT_FADE_SECONDS)
	return {"ok": true, "mode": "menu_to_shift", "fade_seconds": MENU_TO_SHIFT_FADE_SECONDS}


## 只读观测接口供专项验证；页面不得读取内部播放器节点或直接改写其音量。
func get_playback_snapshot() -> Dictionary:
	return {
		"ok": _menu_player != null and is_instance_valid(_menu_player) and _shift_player != null and is_instance_valid(_shift_player),
		"mode": PlaybackMode.keys()[_playback_mode],
		"bus_name": String(AMBIENCE_BUS_NAME),
		"player_count": _get_valid_player_count(),
		"menu_stream_path": MENU_BGM_STREAM_PATH,
		"menu_loop_seconds": MENU_LOOP_SECONDS,
		"menu_length_seconds": _menu_loop_stream.get_length() if _menu_loop_stream != null else -1.0,
		"menu_loop_enabled": _is_loop_enabled(_menu_loop_stream),
		"menu_loop_offset_seconds": _get_loop_offset_seconds(_menu_loop_stream),
		"menu_volume_db": _menu_player.volume_db if _menu_player != null and is_instance_valid(_menu_player) else SILENT_VOLUME_DB,
		"is_menu_playing": _menu_player.playing if _menu_player != null and is_instance_valid(_menu_player) else false,
		"shift_stream_path": SHIFT_BGM_STREAM_PATH,
		"shift_loop_seconds": SHIFT_LOOP_SECONDS,
		"shift_length_seconds": _shift_loop_stream.get_length() if _shift_loop_stream != null else -1.0,
		"shift_loop_enabled": _is_loop_enabled(_shift_loop_stream),
		"shift_loop_offset_seconds": _get_loop_offset_seconds(_shift_loop_stream),
		"shift_volume_db": _shift_player.volume_db if _shift_player != null and is_instance_valid(_shift_player) else SILENT_VOLUME_DB,
		"is_shift_playing": _shift_player.playing if _shift_player != null and is_instance_valid(_shift_player) else false,
		"is_transition_running": _transition_tween != null and _transition_tween.is_valid() and _transition_tween.is_running(),
	}


## 仅供 Headless 专项在退出前释放显式启动的解码资源；生产页面不得调用。
func stop_and_release_for_verification() -> void:
	_cancel_transition()
	_release_players()


func _ensure_players() -> Dictionary:
	if AudioServer.get_bus_index(AMBIENCE_BUS_NAME) < 0:
		if not _has_reported_missing_bus:
			_has_reported_missing_bus = true
			push_error("[音频][bgm_missing_bus] 缺少 Ambience Audio Bus，无法播放背景音乐。")
		return {"ok": false, "error_code": "missing_ambience_bus", "message": "缺少 Ambience Audio Bus。"}
	if _menu_player != null and is_instance_valid(_menu_player) and _shift_player != null and is_instance_valid(_shift_player):
		return {"ok": true}
	_release_players()
	var menu_source: AudioStream = load(MENU_BGM_STREAM_PATH) as AudioStream
	if menu_source == null:
		return {"ok": false, "error_code": "missing_menu_bgm_stream", "message": "无法加载主菜单背景音乐。"}
	var menu_stream_result: Dictionary = _make_loop_stream(menu_source, MENU_LOOP_SECONDS)
	if not bool(menu_stream_result.get("ok", false)):
		return menu_stream_result
	var shift_source: AudioStream = load(SHIFT_BGM_STREAM_PATH) as AudioStream
	if shift_source == null:
		return {"ok": false, "error_code": "missing_shift_bgm_stream", "message": "无法加载夜班背景音乐。"}
	var shift_stream_result: Dictionary = _make_loop_stream(shift_source, SHIFT_LOOP_SECONDS)
	if not bool(shift_stream_result.get("ok", false)):
		return shift_stream_result
	_menu_loop_stream = menu_stream_result["stream"] as AudioStream
	_shift_loop_stream = shift_stream_result["stream"] as AudioStream
	_menu_player = _create_player("MenuBgmPlayer", _menu_loop_stream)
	_shift_player = _create_player("ShiftBgmPlayer", _shift_loop_stream)
	return {"ok": true}


func _make_loop_stream(source: AudioStream, expected_loop_seconds: float) -> Dictionary:
	var duplicate: AudioStream = source.duplicate() as AudioStream
	if duplicate is AudioStreamMP3:
		var mp3: AudioStreamMP3 = duplicate as AudioStreamMP3
		mp3.loop = true
		mp3.loop_offset = 0.0
	elif duplicate is AudioStreamOggVorbis:
		var ogg: AudioStreamOggVorbis = duplicate as AudioStreamOggVorbis
		ogg.loop = true
		ogg.loop_offset = 0.0
	else:
		return {"ok": false, "error_code": "unsupported_bgm_stream", "message": "背景音乐必须是可设置循环点的 MP3 或 Ogg Vorbis 资源。"}
	if duplicate.get_length() + 0.01 < expected_loop_seconds:
		return {"ok": false, "error_code": "bgm_too_short", "message": "背景音乐长度不足 %.1f 秒，不能建立指定循环。" % expected_loop_seconds}
	return {"ok": true, "stream": duplicate}


func _create_player(player_name: String, stream: AudioStream) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.stream = stream
	player.bus = AMBIENCE_BUS_NAME
	player.volume_db = SILENT_VOLUME_DB
	add_child(player)
	return player


func _start_menu_player(volume_db: float) -> void:
	if _menu_player == null or not is_instance_valid(_menu_player):
		return
	_menu_player.volume_db = volume_db
	if not _is_non_playback_environment() and not _menu_player.playing:
		_menu_player.play()


func _start_shift_player(volume_db: float) -> void:
	if _shift_player == null or not is_instance_valid(_shift_player):
		return
	_shift_player.volume_db = volume_db
	if not _is_non_playback_environment() and not _shift_player.playing:
		_shift_player.play()


func _stop_shift_player() -> void:
	if _shift_player == null or not is_instance_valid(_shift_player):
		return
	_shift_player.stop()
	_shift_player.volume_db = SILENT_VOLUME_DB


func _finish_menu_to_shift_fade() -> void:
	_transition_tween = null
	if _playback_mode != PlaybackMode.MENU_TO_SHIFT:
		return
	if _menu_player != null and is_instance_valid(_menu_player):
		_menu_player.stop()
		_menu_player.volume_db = SILENT_VOLUME_DB
	_start_shift_player(SILENT_VOLUME_DB)
	_transition_tween = create_tween()
	_transition_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_transition_tween.tween_property(_shift_player, "volume_db", SHIFT_BGM_VOLUME_DB, SHIFT_FADE_IN_SECONDS)
	_transition_tween.tween_callback(_finish_shift_fade_in)
	_playback_mode = PlaybackMode.SHIFT
	print("[音频][shift_bgm_fade_started] 菜单音乐已停止，开始平滑接入夜班音乐。")


func _finish_shift_fade_in() -> void:
	_transition_tween = null
	if _playback_mode == PlaybackMode.SHIFT:
		print("[音频][shift_bgm_started] stream=%s loop_seconds=%.3f。" % [SHIFT_BGM_STREAM_PATH, SHIFT_LOOP_SECONDS])


func _finish_shift_to_menu_transition() -> void:
	_transition_tween = null
	_stop_shift_player()
	if _playback_mode == PlaybackMode.MENU:
		print("[音频][menu_bgm_started] 已平滑恢复主菜单音乐。")


func _cancel_transition() -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null


func _release_players() -> void:
	for player: AudioStreamPlayer in [_menu_player, _shift_player]:
		if player == null or not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	_menu_player = null
	_shift_player = null
	_menu_loop_stream = null
	_shift_loop_stream = null


func _get_valid_player_count() -> int:
	var count: int = 0
	if _menu_player != null and is_instance_valid(_menu_player):
		count += 1
	if _shift_player != null and is_instance_valid(_shift_player):
		count += 1
	return count


func _is_loop_enabled(stream: AudioStream) -> bool:
	if stream is AudioStreamMP3:
		return (stream as AudioStreamMP3).loop
	if stream is AudioStreamOggVorbis:
		return (stream as AudioStreamOggVorbis).loop
	return false


func _get_loop_offset_seconds(stream: AudioStream) -> float:
	if stream is AudioStreamMP3:
		return (stream as AudioStreamMP3).loop_offset
	if stream is AudioStreamOggVorbis:
		return (stream as AudioStreamOggVorbis).loop_offset
	return -1.0


func _is_non_playback_environment() -> bool:
	return DisplayServer.get_name().to_lower() == "headless" or AudioServer.get_driver_name().to_lower() == "dummy"
