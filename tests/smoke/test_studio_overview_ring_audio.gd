extends SceneTree

## 图形音频回归：从工作室总览的真实 Main 生命周期推进到 01:01，
## 不能用 Headless 的“请求播放”计数代替实际 AudioStreamPlayer 播放状态。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const UI_PHONE_BUS_NAME: StringName = &"UIPhone"
const MASTER_BUS_NAME: StringName = &"Master"

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	_assert_true(DisplayServer.get_name().to_lower() != "headless", "本专项必须在带渲染的显示环境运行。")
	_assert_true(AudioServer.get_driver_name().to_lower() != "dummy", "本专项必须使用真实音频驱动，而非 Dummy。")
	var app: Control = MAIN_SCENE.instantiate() as Control
	_assert_true(app != null, "必须能实例化 Main。")
	if app == null:
		_finish()
		return
	root.add_child(app)
	await process_frame
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"finish_loading_for_verification")
	await process_frame
	var game_screen: GameScreen = app.call(&"get_current_game_screen") as GameScreen
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	var phone_system: RefCounted = app.get("_phone_system") as RefCounted
	var phone_audio: Node = root.get_node_or_null(NodePath("PhoneAudioPlayer")) as Node
	_assert_true(game_screen != null and game_screen.get_current_view_id() == GameScreen.VIEW_STUDIO, "新班次必须停在工作室总览。")
	_assert_true(game_clock != null and phone_system != null and phone_audio != null, "总览响铃验证所需运行时必须完整创建。")
	if game_clock == null or phone_system == null or phone_audio == null:
		_cleanup(app)
		_finish()
		return
	_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", 60)), "必须能推进到 01:01。")
	await process_frame
	await create_timer(1.20).timeout
	var playback: Dictionary = phone_audio.call(&"get_playback_snapshot") as Dictionary
	var bgm_audio: Node = root.get_node_or_null(NodePath("BgmPlayer")) as Node
	var bgm_playback: Dictionary = bgm_audio.call(&"get_playback_snapshot") as Dictionary if bgm_audio != null else {}
	var ui_phone_bus_index: int = AudioServer.get_bus_index(UI_PHONE_BUS_NAME)
	var master_bus_index: int = AudioServer.get_bus_index(MASTER_BUS_NAME)
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "01:01 时首通来电必须仍处于 RINGING。")
	_assert_equal(game_screen.get_current_view_id(), GameScreen.VIEW_STUDIO, "响铃时不得离开工作室总览。")
	_assert_true(bool(playback.get("bound", false)), "PhoneAudioPlayer 必须已绑定当前班次的 PhoneSystem。")
	_assert_equal(String(playback.get("bound_state", "")), "RINGING", "PhoneAudioPlayer 绑定状态必须与权威电话状态一致。")
	_assert_equal(int(playback.get("player_count", 0)), 3, "电话音效只能保留三个单一用途播放器。")
	_assert_true(bool(playback.get("is_ring_requested", false)), "RINGING 必须请求铃声播放。")
	_assert_true(bool(playback.get("is_ring_playing", false)), "图形音频环境下工作室总览响铃必须实际处于播放状态。")
	_assert_equal(String(playback.get("ring_player_bus", "")), "UIPhone", "铃声播放器必须路由到 UIPhone。")
	_assert_true(float(playback.get("ring_playback_position_seconds", 0.0)) > 0.05, "等待混音后铃声播放位置必须推进，不能只停在播放请求。")
	_assert_true(ui_phone_bus_index >= 0 and master_bus_index >= 0, "UIPhone 与 Master 总线必须存在。")
	if ui_phone_bus_index >= 0:
		_assert_true(not AudioServer.is_bus_mute(ui_phone_bus_index), "默认 UIPhone 总线不得静音。")
		_assert_true(AudioServer.get_bus_volume_db(ui_phone_bus_index) > -70.0, "默认 UIPhone 音量不得接近静音。")
	if master_bus_index >= 0:
		_assert_true(not AudioServer.is_bus_mute(master_bus_index), "默认 Master 总线不得静音。")
		_assert_true(AudioServer.get_bus_volume_db(master_bus_index) > -70.0, "默认 Master 音量不得接近静音。")
	# 直接跳到铃声尾部附近，验证真实播放器能越过显式 loop_end 回到开头。
	# 这比只检查 loop_mode 更能防止 loop_end=0 导致首个混音块即停播的回归。
	var ring_player: AudioStreamPlayer = phone_audio.get_node_or_null(NodePath("PhoneRingPlayer")) as AudioStreamPlayer
	_assert_true(ring_player != null, "必须创建唯一的 PhoneRingPlayer。")
	if ring_player != null:
		var ring_length_seconds: float = float(playback.get("ring_length_seconds", 0.0))
		_assert_true(ring_length_seconds > 1.0, "铃声音频必须具有有效长度。")
		ring_player.seek(maxf(ring_length_seconds - 0.15, 0.0))
		await create_timer(0.45).timeout
		var looped_playback: Dictionary = phone_audio.call(&"get_playback_snapshot") as Dictionary
		_assert_true(bool(looped_playback.get("is_ring_playing", false)), "越过铃声结尾后仍应继续循环播放。")
		_assert_true(float(looped_playback.get("ring_playback_position_seconds", ring_length_seconds)) < 1.0, "越过铃声结尾后播放位置应回到开头。")
	print("[测试][StudioOverviewRingAudio] driver=%s display=%s ring=%s bgm=%s ui_phone_db=%.2f。" % [AudioServer.get_driver_name(), DisplayServer.get_name(), str(playback), str(bgm_playback), AudioServer.get_bus_volume_db(ui_phone_bus_index) if ui_phone_bus_index >= 0 else -200.0])
	_cleanup(app)
	_finish()


func _cleanup(app: Control) -> void:
	if app.get_parent() == root:
		root.remove_child(app)
	app.queue_free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][StudioOverviewRingAudio] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _finish() -> void:
	if _has_failed:
		print("[测试][StudioOverviewRingAudio] 失败。")
		quit(1)
		return
	print("[测试][StudioOverviewRingAudio] 通过：工作室总览 01:01 的单一铃声正在真实音频环境播放。")
	quit(0)
