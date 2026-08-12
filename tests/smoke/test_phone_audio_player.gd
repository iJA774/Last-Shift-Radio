extends SceneTree

## 电话音效专项：只允许 PhoneSystem 状态机驱动，不允许界面或存档页面推测电话状态。

const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const CALL_EVENT: Dictionary = {
	"id": "phone_audio_call",
	"caller_display_name": "音频验证来电",
	"caller_number": "010-0000-0000",
}
const PICKUP_STREAM_PATH: String = "res://音效/电话/164034__drni__fetap-pickup_trimmed.wav"
const HANGUP_STREAM_PATH: String = "res://音效/电话/164035__drni__fetap-hangup_trimmed.wav"
const RING_STREAM_PATH: String = "res://音效/电话/164036__drni__fetap-ring_trimmed.wav"
const PICKUP_TRIMMED_DURATION_SECONDS: float = 4.460583
const HANGUP_TRIMMED_DURATION_SECONDS: float = 2.309938
const RING_TRIMMED_DURATION_SECONDS: float = 18.320313

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var player: Node = root.get_node_or_null(NodePath("PhoneAudioPlayer")) as Node
	_assert_true(player != null, "项目必须注册持久化 PhoneAudioPlayer 自动加载节点。")
	if player == null:
		_finish()
		return
	_assert_true(player.has_method(&"bind_phone_system") and player.has_method(&"unbind_phone_system"), "PhoneAudioPlayer 必须公开本局绑定与解绑接口。")
	_assert_true(player.has_method(&"get_playback_snapshot"), "PhoneAudioPlayer 必须公开只读验证快照。")
	if not player.has_method(&"get_playback_snapshot"):
		_finish()
		return

	player.call(&"stop_and_release_for_verification")
	_test_trimmed_stream_assets()
	_test_answer_and_hangup(player)
	_test_missed_and_forced_end_stop_ring(player)
	_test_staged_restore_does_not_ring_before_commit(player)
	player.call(&"stop_and_release_for_verification")
	await process_frame
	await process_frame
	var released: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(released.get("player_count", -1)), 0, "专项释放后不得遗留电话播放器。")
	_assert_true(not bool(released.get("is_ring_requested", true)), "专项释放后不得保留响铃请求。")
	_finish()


func _test_answer_and_hangup(player: Node) -> void:
	var phone: RefCounted = PHONE_SYSTEM_SCRIPT.new() as RefCounted
	_assert_true(bool(phone.call(&"begin_incoming_call", CALL_EVENT, 0, 30)), "电话音效专项必须能进入响铃状态。")
	_assert_ok(player.call(&"bind_phone_system", phone), "正常来电必须能绑定电话音效服务。")
	var ringing: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(ringing.get("bus_name", "")), "UIPhone", "所有电话音效必须路由到 UIPhone。")
	_assert_equal(String(ringing.get("ring_stream_path", "")), RING_STREAM_PATH, "响铃必须使用裁切后的电话素材。")
	_assert_equal(String(ringing.get("pickup_stream_path", "")), PICKUP_STREAM_PATH, "接听必须使用裁切后的电话素材。")
	_assert_equal(String(ringing.get("hangup_stream_path", "")), HANGUP_STREAM_PATH, "挂机必须使用裁切后的电话素材。")
	_assert_equal(int(ringing.get("player_count", 0)), 3, "电话音效必须只创建一个铃声、一个摘机和一个挂机播放器。")
	_assert_true(bool(ringing.get("is_ring_requested", false)), "PhoneSystem 进入 RINGING 后必须请求播放铃声。")
	_assert_true(bool(ringing.get("ring_loop_enabled", false)), "铃声资源必须开启前向循环，未接听时不得自然停止。")
	_assert_equal(int(ringing.get("ring_start_count", 0)), 1, "首次绑定已响铃电话只能启动一个循环。")
	_assert_true(bool(phone.call(&"answer_call", 1)), "响铃电话必须能接听。")
	var answered: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(not bool(answered.get("is_ring_requested", true)), "接听后必须立即停止铃声。")
	_assert_equal(int(answered.get("pickup_play_count", 0)), 1, "RINGING→CONNECTED 必须只播放一次摘机声。")
	var stop_count_before_pickup_dispose: int = int(answered.get("stop_all_count", 0))
	player.call(&"unbind_phone_system")
	var pickup_disposed: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(pickup_disposed.get("player_count", 0)), 3, "解绑后应复用已创建电话播放器，而不是遗留或额外分配。")
	_assert_equal(int(pickup_disposed.get("stop_all_count", 0)), stop_count_before_pickup_dispose + 1, "接听后立刻离开夜班必须停止摘机尾音。")
	_assert_true(not bool(pickup_disposed.get("is_pickup_playing", true)), "解绑后不得保留活跃摘机声。")
	_assert_ok(player.call(&"bind_phone_system", phone), "接听后重新绑定同一电话必须安全。")
	_assert_true(bool(phone.call(&"hang_up", 2)), "接通电话必须能主动挂机。")
	var hung_up: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(hung_up.get("hangup_play_count", 0)), 1, "CONNECTED→ENDED 必须只播放一次挂机声。")
	var stop_count_before_hangup_dispose: int = int(hung_up.get("stop_all_count", 0))
	player.call(&"unbind_phone_system")
	var hangup_disposed: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(hangup_disposed.get("stop_all_count", 0)), stop_count_before_hangup_dispose + 1, "挂机后立刻离开夜班必须停止挂机尾音。")
	_assert_true(not bool(hangup_disposed.get("is_hangup_playing", true)), "解绑后不得保留活跃挂机声。")


func _test_trimmed_stream_assets() -> void:
	_assert_trimmed_stream(PICKUP_STREAM_PATH, PICKUP_TRIMMED_DURATION_SECONDS, "摘机")
	_assert_trimmed_stream(HANGUP_STREAM_PATH, HANGUP_TRIMMED_DURATION_SECONDS, "挂机")
	_assert_trimmed_stream(RING_STREAM_PATH, RING_TRIMMED_DURATION_SECONDS, "响铃")


func _assert_trimmed_stream(stream_path: String, expected_duration: float, display_name: String) -> void:
	var stream: AudioStreamWAV = load(stream_path) as AudioStreamWAV
	_assert_true(stream != null, "%s裁切 WAV 必须能由 Godot 导入。" % display_name)
	if stream == null:
		return
	_assert_true(not stream.stereo, "%s裁切 WAV 必须保持单声道。" % display_name)
	_assert_equal(int(stream.mix_rate), 48000, "%s裁切 WAV 必须保持 48kHz。" % display_name)
	_assert_true(absf(stream.get_length() - expected_duration) < 0.002, "%s裁切 WAV 时长不符合素材处理记录。" % display_name)


func _test_missed_and_forced_end_stop_ring(player: Node) -> void:
	var missed_phone: RefCounted = PHONE_SYSTEM_SCRIPT.new() as RefCounted
	_assert_ok(player.call(&"bind_phone_system", missed_phone), "漏接验证必须能绑定电话。")
	_assert_true(bool(missed_phone.call(&"begin_incoming_call", CALL_EVENT, 0, 2)), "漏接验证必须能进入响铃。")
	_assert_true(bool((player.call(&"get_playback_snapshot") as Dictionary).get("is_ring_requested", false)), "漏接前铃声必须处于循环请求状态。")
	_assert_true(bool(missed_phone.call(&"advance_to_tick", 2)), "响铃超时必须由 PhoneSystem 记为漏接。")
	var missed: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(not bool(missed.get("is_ring_requested", true)), "响铃超时变为 MISSED 时必须立即停止铃声。")
	_assert_equal(int(missed.get("hangup_play_count", 0)), 1, "RINGING→MISSED 不得伪播挂机声。")
	player.call(&"unbind_phone_system")

	var forced_phone: RefCounted = PHONE_SYSTEM_SCRIPT.new() as RefCounted
	_assert_ok(player.call(&"bind_phone_system", forced_phone), "02:00 验证必须能绑定电话。")
	_assert_true(bool(forced_phone.call(&"begin_incoming_call", CALL_EVENT, 0, 60)), "02:00 验证必须能进入响铃。")
	_assert_true(bool(forced_phone.call(&"force_end_at_0200", 3600)), "02:00 必须能强制终止响铃线路。")
	var forced: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(not bool(forced.get("is_ring_requested", true)), "02:00 强制收束必须立即停止铃声。")
	_assert_equal(int(forced.get("hangup_play_count", 0)), 1, "RINGING→ENDED 的 02:00 收束不得播放挂机声。")
	player.call(&"unbind_phone_system")


func _test_staged_restore_does_not_ring_before_commit(player: Node) -> void:
	var source_phone: RefCounted = PHONE_SYSTEM_SCRIPT.new() as RefCounted
	_assert_true(bool(source_phone.call(&"begin_incoming_call", CALL_EVENT, 10, 30)), "读取验证源电话必须进入响铃。")
	var snapshot: Dictionary = source_phone.call(&"create_snapshot") as Dictionary
	var restored_phone: RefCounted = PHONE_SYSTEM_SCRIPT.new() as RefCounted
	var context: Dictionary = {"current_game_tick": 10, "event_by_id": {"phone_audio_call": CALL_EVENT}}
	_assert_ok(restored_phone.call(&"restore_snapshot", snapshot, context), "响铃存档必须能恢复到 staging PhoneSystem。")
	var staging_snapshot: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(not bool(staging_snapshot.get("is_ring_requested", true)), "隐藏 staging 恢复未正式提交前绝不能播放铃声。")
	_assert_ok(player.call(&"bind_phone_system", restored_phone), "读取正式提交后必须能绑定已恢复电话。")
	var committed: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(bool(committed.get("is_ring_requested", false)), "响铃存档正式提交后必须恢复循环铃声。")
	var start_count: int = int(committed.get("ring_start_count", 0))
	_assert_ok(player.call(&"bind_phone_system", restored_phone), "同一已恢复电话的重复绑定必须安全。")
	var rebound: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(rebound.get("ring_start_count", 0)), start_count, "重复绑定同一响铃存档不得叠加或重启铃声。")
	player.call(&"unbind_phone_system")


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][PhoneAudioPlayer] %s" % message)


func _finish() -> void:
	if _has_failed:
		print("[测试][PhoneAudioPlayer] 失败。")
		quit(1)
		return
	print("[测试][PhoneAudioPlayer] 通过：权威状态驱动、未接听循环、终止停止、读取提交与生命周期清理均符合合同。")
	quit(0)
