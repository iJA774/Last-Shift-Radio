class_name UiSoundPlayerService
extends Node
## 持久化的 UI 点击音播放器。
##
## 菜单会在点击后立即替换场景，因此播放器作为 Autoload 存活在场景外。
## 每次播放优先使用空闲声道；所有声道忙碌时拒绝本次额外点击而不截断已经开始的音效。

signal button_click_played(play_count: int)

const UI_PHONE_BUS_NAME: StringName = &"UIPhone"
const MAX_CONCURRENT_BUTTON_SOUNDS: int = 12
const BUTTON_CLICK_STREAM: AudioStream = preload("res://音效/按钮/bong_001.wav")

var _button_players: Array[AudioStreamPlayer] = []
var _button_click_play_count: int = 0
var _has_reported_pool_exhaustion: bool = false
var _headless_active_count: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if AudioServer.get_bus_index(UI_PHONE_BUS_NAME) < 0:
		push_error("[音频][ui_sound_missing_bus] 缺少 UIPhone Audio Bus，无法播放菜单点击音。")
		return
	for index: int in MAX_CONCURRENT_BUTTON_SOUNDS:
		var player := AudioStreamPlayer.new()
		player.name = "ButtonClickPlayer%d" % (index + 1)
		player.stream = BUTTON_CLICK_STREAM
		player.bus = UI_PHONE_BUS_NAME
		add_child(player)
		_button_players.append(player)


func _exit_tree() -> void:
	# 显式断开播放后端再释放播放器，避免 Headless/测试进程退出时遗留 WAV playback 实例。
	for player: AudioStreamPlayer in _button_players:
		if not is_instance_valid(player):
			continue
		player.stop()
		player.stream = null
		if player.get_parent() == self:
			remove_child(player)
		player.free()
	_button_players.clear()


## 所有主菜单与夜班 ESC 选项共享此入口；返回数据便于日志与自动验证。
func play_button_click() -> Dictionary:
	# Dummy 音频后端会在进程退出时遗留 playback 对象；Headless 只验证路由与并发合同，图形运行才真正发声。
	if DisplayServer.get_name() == "headless":
		if _headless_active_count >= MAX_CONCURRENT_BUTTON_SOUNDS:
			return _report_pool_exhaustion()
		_headless_active_count += 1
		_button_click_play_count += 1
		button_click_played.emit(_button_click_play_count)
		return {"ok": true, "play_count": _button_click_play_count}
	for player: AudioStreamPlayer in _button_players:
		if player.playing:
			continue
		player.play()
		_button_click_play_count += 1
		button_click_played.emit(_button_click_play_count)
		return {"ok": true, "play_count": _button_click_play_count}
	return _report_pool_exhaustion()


func _report_pool_exhaustion() -> Dictionary:
	if not _has_reported_pool_exhaustion:
		push_warning("[音频][ui_button_click_dropped] 菜单点击声道已满，本次点击不播放以避免截断已开始的音效。")
		_has_reported_pool_exhaustion = true
	return {"ok": false, "error_code": "all_button_players_busy", "message": "菜单点击声道繁忙。"}


## 只读快照用于专项测试；不暴露播放器以免 UI 改写音频状态。
func get_button_click_snapshot() -> Dictionary:
	var active_player_count: int = _headless_active_count if DisplayServer.get_name() == "headless" else 0
	if DisplayServer.get_name() != "headless":
		for player: AudioStreamPlayer in _button_players:
			if player.playing:
				active_player_count += 1
	return {
		"ok": true,
		"stream_path": BUTTON_CLICK_STREAM.resource_path,
		"bus_name": String(UI_PHONE_BUS_NAME),
		"player_count": _button_players.size(),
		"active_player_count": active_player_count,
		"play_count": _button_click_play_count,
	}


## 仅供独立冒烟测试重置观测计数，生产 UI 不调用此方法。
func reset_button_click_count_for_verification() -> void:
	for player: AudioStreamPlayer in _button_players:
		player.stop()
	_button_click_play_count = 0
	_headless_active_count = 0
	_has_reported_pool_exhaustion = false
