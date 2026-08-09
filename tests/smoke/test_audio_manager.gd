extends SceneTree

## 音频总线只控制 AudioServer；本专项同时确认静音不会伪造或阻塞 02:00 收束。

const AUDIO_MANAGER_SCRIPT: GDScript = preload("res://scripts/systems/audio_manager.gd")
const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")
const STORY_ENGINE_SCRIPT: GDScript = preload("res://scripts/core/story_engine.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

const MASTER_BUS_NAME: StringName = &"Master"
const AMBIENCE_BUS_NAME: StringName = &"Ambience"
const UI_PHONE_BUS_NAME: StringName = &"UIPhone"

var _has_failed: bool = false
var _bus_apply_counts: Dictionary[StringName, int] = {}


class SmokeSettingsManager extends Node:
	signal setting_changed(setting_id: String, value: Variant)
	signal settings_applied(settings: Dictionary)

	var _settings: Dictionary = {
		"master_volume": 1.0,
		"ambience_volume": 1.0,
		"ui_phone_volume": 1.0,
	}

	func is_settings_loaded() -> bool:
		return true


	func get_master_volume() -> float:
		return float(_settings["master_volume"])


	func get_ambience_volume() -> float:
		return float(_settings["ambience_volume"])


	func get_ui_phone_volume() -> float:
		return float(_settings["ui_phone_volume"])


	func set_master_volume(linear_volume: float) -> void:
		_settings["master_volume"] = linear_volume
		setting_changed.emit("master_volume", linear_volume)
		settings_applied.emit(_settings.duplicate(true))


func _record_bus_volume_applied(bus_name: StringName, _linear_volume: float, _is_muted: bool) -> void:
	_bus_apply_counts[bus_name] = int(_bus_apply_counts.get(bus_name, 0)) + 1


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var smoke_settings_manager := SmokeSettingsManager.new()
	var audio_manager = AUDIO_MANAGER_SCRIPT.new()
	_assert_ok(
		audio_manager.set_settings_manager_for_verification(smoke_settings_manager),
		"AudioManager 专项必须在进入场景树前接入隔离设置源。"
	)
	root.add_child(audio_manager)
	await process_frame
	audio_manager.bus_volume_applied.connect(_record_bus_volume_applied)
	_test_bus_layout()
	_test_volume_and_mute_contract(audio_manager)
	_test_settings_signal_integration(audio_manager, smoke_settings_manager)
	_test_audio_changes_do_not_touch_runtime_state(audio_manager)
	_test_silence_allows_forced_ending(audio_manager)
	if is_instance_valid(audio_manager):
		if audio_manager.get_parent() != null:
			audio_manager.get_parent().remove_child(audio_manager)
		audio_manager.free()
	if is_instance_valid(smoke_settings_manager):
		smoke_settings_manager.free()

	if _has_failed:
		print("[测试][AudioManager] 失败。")
		quit(1)
		return
	print("[测试][AudioManager] 通过：三总线、设置静音、临时静音、状态隔离与静音至 02:00 均符合契约。")
	quit(0)


func _test_bus_layout() -> void:
	_assert_true(AudioServer.get_bus_index(MASTER_BUS_NAME) >= 0, "必须存在 Master Audio Bus。")
	_assert_true(AudioServer.get_bus_index(AMBIENCE_BUS_NAME) >= 0, "必须存在 Ambience Audio Bus。")
	_assert_true(AudioServer.get_bus_index(UI_PHONE_BUS_NAME) >= 0, "必须存在 UIPhone Audio Bus。")
	_assert_equal(_get_bus_send_name(AMBIENCE_BUS_NAME), MASTER_BUS_NAME, "Ambience 必须发送到 Master。")
	_assert_equal(_get_bus_send_name(UI_PHONE_BUS_NAME), MASTER_BUS_NAME, "UIPhone 必须发送到 Master。")


func _test_volume_and_mute_contract(audio_manager) -> void:
	_assert_ok(audio_manager.apply_master_volume(0.5), "Master 必须接受非零线性音量。")
	_assert_equal(audio_manager.get_master_volume(), 0.5, "Master 线性音量记录不正确。")
	_assert_true(not audio_manager.is_master_muted(), "非零 Master 音量必须解除设置静音。")
	_assert_true(
		is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(MASTER_BUS_NAME)), linear_to_db(0.5)),
		"Master 必须使用线性到 dB 的正确换算。"
	)
	_assert_ok(audio_manager.apply_master_volume(0.0), "Master 必须接受 0.0 音量。")
	_assert_true(audio_manager.is_master_muted(), "0.0 Master 音量必须使 Audio Bus 真正静音。")
	_assert_true(AudioServer.is_bus_mute(AudioServer.get_bus_index(MASTER_BUS_NAME)), "Master Bus 必须处于 mute。")
	_assert_ok(audio_manager.apply_master_volume(0.25), "静音后必须能恢复 Master 音量。")
	_assert_true(not audio_manager.is_master_muted(), "恢复非零 Master 音量必须解除设置静音。")
	_assert_true(
		is_equal_approx(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(MASTER_BUS_NAME)), linear_to_db(0.25)),
		"恢复后 Master dB 必须与新线性音量一致。"
	)

	_assert_ok(audio_manager.apply_ambience_volume(0.7), "Ambience 必须接受非零线性音量。")
	_assert_ok(audio_manager.set_ambience_muted(true), "Ambience 必须支持临时静音。")
	_assert_true(audio_manager.is_ambience_muted(), "临时 Ambience 静音必须生效。")
	_assert_ok(audio_manager.apply_ambience_volume(0.4), "临时静音期间仍可更新持久化音量来源。")
	_assert_true(audio_manager.is_ambience_muted(), "临时静音不能被非零设置音量擅自解除。")
	_assert_ok(audio_manager.set_ambience_muted(false), "Ambience 必须能解除临时静音。")
	_assert_true(not audio_manager.is_ambience_muted(), "解除临时静音后 Ambience 应恢复可听状态。")

	_assert_ok(audio_manager.apply_ui_phone_volume(0.0), "UIPhone 必须接受 0.0 音量。")
	_assert_true(audio_manager.is_ui_phone_muted(), "0.0 UIPhone 音量必须静音。")
	_assert_ok(audio_manager.apply_ui_phone_volume(1.0), "UIPhone 必须能从 0.0 恢复。")
	_assert_true(not audio_manager.is_ui_phone_muted(), "恢复 UIPhone 音量必须解除设置静音。")


func _test_settings_signal_integration(audio_manager, settings_manager: SmokeSettingsManager) -> void:
	_assert_true(
		not settings_manager.is_connected(&"setting_changed", Callable(audio_manager, "_on_setting_changed")),
		"AudioManager 不得订阅 setting_changed，避免每次 setter 重复应用总线。"
	)
	_bus_apply_counts.clear()
	settings_manager.setting_changed.emit("master_volume", 0.35)
	_assert_equal(audio_manager.get_master_volume(), 0.25, "单项 setting_changed 不得单独触发 AudioServer 写入。")
	_assert_equal(_get_total_bus_apply_count(), 0, "单项 setting_changed 不得产生总线应用事件。")

	settings_manager.set_master_volume(0.35)
	_assert_equal(audio_manager.get_master_volume(), 0.35, "settings_applied 必须更新 Master 音量。")
	_assert_equal(_get_total_bus_apply_count(), 3, "每次 setter 的完整快照只能应用三条总线各一次。")
	_assert_equal(int(_bus_apply_counts.get(MASTER_BUS_NAME, 0)), 1, "Master 只能应用一次。")
	_assert_equal(int(_bus_apply_counts.get(AMBIENCE_BUS_NAME, 0)), 1, "Ambience 只能应用一次。")
	_assert_equal(int(_bus_apply_counts.get(UI_PHONE_BUS_NAME, 0)), 1, "UIPhone 只能应用一次。")


func _get_total_bus_apply_count() -> int:
	var total: int = 0
	for count: int in _bus_apply_counts.values():
		total += count
	return total


func _test_audio_changes_do_not_touch_runtime_state(audio_manager) -> void:
	var clock: GameClockService = GAME_CLOCK_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	root.add_child(clock)
	var start_result: Dictionary = clock.prepare_new_shift()
	_assert_ok(start_result, "隔离测试必须能预备夜班时钟。")
	var tick_before: int = clock.get_current_game_tick()
	var phone_state_before: String = phone.get_state_name()
	_assert_ok(audio_manager.apply_master_volume(0.6), "音频设置隔离测试必须可应用 Master 音量。")
	_assert_ok(audio_manager.apply_ambience_volume(0.0), "音频设置隔离测试必须可静音 Ambience。")
	_assert_ok(audio_manager.apply_ui_phone_volume(0.2), "音频设置隔离测试必须可应用 UIPhone 音量。")
	_assert_equal(clock.get_current_game_tick(), tick_before, "音量改变不得推进或重置游戏时钟。")
	_assert_equal(phone.get_state_name(), phone_state_before, "音量改变不得改变电话状态。")
	_cleanup_clock(clock)


func _test_silence_allows_forced_ending(audio_manager) -> void:
	_assert_ok(audio_manager.apply_master_volume(0.0), "静音收束专项必须静音 Master。")
	_assert_ok(audio_manager.apply_ambience_volume(0.0), "静音收束专项必须静音 Ambience。")
	_assert_ok(audio_manager.apply_ui_phone_volume(0.0), "静音收束专项必须静音 UIPhone。")
	_assert_true(audio_manager.is_master_muted(), "静音收束专项中 Master 必须为 mute。")
	_assert_true(audio_manager.is_ambience_muted(), "静音收束专项中 Ambience 必须为 mute。")
	_assert_true(audio_manager.is_ui_phone_muted(), "静音收束专项中 UIPhone 必须为 mute。")

	var clock: GameClockService = GAME_CLOCK_SCRIPT.new()
	var engine: StoryEngine = STORY_ENGINE_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	root.add_child(clock)
	_assert_ok(engine.set_phone_system(phone), "静音收束专项必须连接 PhoneSystem。")
	_assert_ok(engine.connect_game_clock(clock), "静音收束专项必须连接 GameClock。")
	_assert_ok(engine.schedule_event(_make_call_event("call_audio_silence_end", 1, 8)), "静音收束专项必须注册活动来电。")
	clock.start_shift()
	_assert_true(clock.advance_ticks_for_verification(60), "静音状态下必须仍能触发真实来电。")
	_assert_equal(phone.get_state_name(), "RINGING", "静音状态不得跳过电话响铃状态。")
	_assert_true(
		clock.advance_ticks_for_verification(GameClockService.SHIFT_DURATION_TICKS - clock.get_current_game_tick()),
		"静音状态下时钟必须仍可推进至 02:00。"
	)
	_assert_true(clock.is_shift_ended(), "静音状态下 02:00 必须结束时钟。")
	_assert_true(engine.is_ending_forced(), "静音状态下 StoryEngine 必须强制收束。")
	_assert_true(phone.is_forced_ended(), "静音状态下 PhoneSystem 必须强制结束。")
	_assert_equal(phone.get_state_name(), "IDLE", "静音状态下强制收束必须清空活动线路。")
	var broadcast_record: Dictionary = engine.get_unauthorized_broadcast_record()
	_assert_equal(String(broadcast_record.get("fact_id", "")), "fact_unauthorized_broadcast", "静音状态下仍必须生成未授权播出记录。")
	_cleanup_clock(clock)


func _make_call_event(event_id: String, start_minute: int, end_minute: int) -> Dictionary:
	return {
		"id": event_id,
		"kind": "incoming_call",
		"priority": "main",
		"window_start_minute": start_minute,
		"window_end_minute": end_minute,
		"when_busy": "queue",
		"on_expire": "mark_missed",
		"condition_ids": [],
		"caller_display_name": "静音专项来电者",
		"caller_number": "555-0199",
	}


func _get_bus_send_name(bus_name: StringName) -> StringName:
	var bus_index: int = AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return &""
	return AudioServer.get_bus_send(bus_index)


func _cleanup_clock(clock: Node) -> void:
	if is_instance_valid(clock) and clock.get_parent() != null:
		clock.get_parent().remove_child(clock)
		clock.free()


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][AudioManager] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
