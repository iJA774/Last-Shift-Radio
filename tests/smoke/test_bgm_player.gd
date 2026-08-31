extends SceneTree

## 菜单与夜班 BGM 必须由同一个 Autoload 协调，菜单曲精确截取到 1:50，且不改写 Ambience 总线。

const MENU_BGM_PATH: String = "res://音效/BGM/dream_2_ambience_loop_110s.ogg"
const SHIFT_BGM_PATH: String = "res://音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg"
const MENU_VOLUME_DB: float = -4.0
const SILENT_VOLUME_DB: float = -80.0
const WALL_WATCHDOG_SECONDS: float = 10.0

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var bgm_player: Node = root.get_node_or_null(NodePath("BgmPlayer")) as Node
	_assert_true(bgm_player != null, "项目必须注册 BgmPlayer 自动加载节点。")
	if bgm_player == null:
		_finish()
		return
	for method_name: StringName in [&"play_menu_bgm", &"transition_to_shift_bgm", &"get_playback_snapshot", &"stop_and_release_for_verification"]:
		_assert_true(bgm_player.has_method(method_name), "BgmPlayer 必须公开 %s()。" % String(method_name))
	if not bgm_player.has_method(&"get_playback_snapshot"):
		_finish()
		return

	var ambience_bus_index: int = AudioServer.get_bus_index(&"Ambience")
	_assert_true(ambience_bus_index >= 0, "BGM 必须使用既有 Ambience 总线。")
	var ambience_before_db: float = AudioServer.get_bus_volume_db(ambience_bus_index) if ambience_bus_index >= 0 else 0.0
	_assert_ok(bgm_player.call(&"play_menu_bgm"), "主菜单 BGM 必须可完成播放准备。")
	var menu_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(bool(menu_snapshot.get("ok", false)), "BGM 播放器必须成功初始化。")
	_assert_equal(String(menu_snapshot.get("mode", "")), "MENU", "初始页面必须是菜单音乐状态。")
	_assert_equal(String(menu_snapshot.get("menu_stream_path", "")), MENU_BGM_PATH, "主菜单必须使用 Dream 2 的精确 1:50 裁切副本。")
	_assert_equal(String(menu_snapshot.get("shift_stream_path", "")), SHIFT_BGM_PATH, "夜班必须保留既有三分钟 BGM 音源。")
	_assert_equal(String(menu_snapshot.get("bus_name", "")), "Ambience", "两首 BGM 必须路由到 Ambience。")
	_assert_equal(int(menu_snapshot.get("player_count", 0)), 2, "单一 BgmPlayer 服务必须拥有恰好两个受控播放器。")
	_assert_true(bool(menu_snapshot.get("menu_loop_enabled", false)), "菜单 BGM 必须在资源层启用循环。")
	_assert_true(is_equal_approx(float(menu_snapshot.get("menu_loop_offset_seconds", -1.0)), 0.0), "菜单 BGM 循环必须从 0 秒重新开始。")
	_assert_true(is_equal_approx(float(menu_snapshot.get("menu_length_seconds", -1.0)), 110.0), "菜单 BGM 运行时素材必须精确为 110 秒，不能仅靠 loop_offset 截断。")
	_assert_true(is_equal_approx(float(menu_snapshot.get("menu_volume_db", 0.0)), MENU_VOLUME_DB), "菜单 BGM 必须只在播放器自身降低 4dB。")
	_assert_true(bool(menu_snapshot.get("shift_loop_enabled", false)), "夜班 BGM 必须保留资源层循环。")
	_assert_true(is_equal_approx(float(menu_snapshot.get("shift_length_seconds", -1.0)), 180.0), "夜班 BGM 必须保留 180 秒长度。")
	if ambience_bus_index >= 0:
		_assert_true(is_equal_approx(AudioServer.get_bus_volume_db(ambience_bus_index), ambience_before_db), "菜单独立响度不得改写 Ambience 总线响度。")

	_assert_ok(bgm_player.call(&"transition_to_shift_bgm"), "加载页开始时必须能够启动菜单到夜班的过渡。")
	_assert_true(bool((bgm_player.call(&"transition_to_shift_bgm") as Dictionary).get("already_transitioning", false)), "重复开始请求不得重置两秒淡出。")
	_assert_true(await _wait_engine_seconds(bgm_player, 0.35), "菜单淡出阶段必须在墙钟看门狗内推进。")
	var fading_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(fading_snapshot.get("mode", "")), "MENU_TO_SHIFT", "前两秒必须仍处于菜单淡出阶段。")
	_assert_true(float(fading_snapshot.get("menu_volume_db", MENU_VOLUME_DB)) < MENU_VOLUME_DB, "菜单曲必须从加载开始平滑降低。")
	if ambience_bus_index >= 0:
		_assert_true(is_equal_approx(AudioServer.get_bus_volume_db(ambience_bus_index), ambience_before_db), "淡出期间不得修改 Ambience 总线。")

	_assert_true(await _wait_engine_seconds(bgm_player, 1.85), "菜单两秒淡出必须在墙钟看门狗内完成。")
	var shift_fade_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(shift_fade_snapshot.get("mode", "")), "SHIFT", "菜单曲两秒静音后必须进入夜班曲淡入。")
	_assert_true(float(shift_fade_snapshot.get("menu_volume_db", 0.0)) <= SILENT_VOLUME_DB + 0.1, "菜单曲达到最低响度后必须停止。")
	_assert_true(await _wait_engine_seconds(bgm_player, 0.85), "夜班音乐淡入必须在墙钟看门狗内完成。")
	var shift_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(shift_snapshot.get("mode", "")), "SHIFT", "夜班曲淡入后必须保持夜班状态。")
	_assert_true(is_equal_approx(float(shift_snapshot.get("shift_volume_db", SILENT_VOLUME_DB)), 0.0), "夜班 BGM 必须平滑恢复自身标准响度。")
	if ambience_bus_index >= 0:
		_assert_true(is_equal_approx(AudioServer.get_bus_volume_db(ambience_bus_index), ambience_before_db), "夜班曲淡入也不得修改 Ambience 总线。")

	_assert_ok(bgm_player.call(&"play_menu_bgm"), "返回主菜单必须能启动反向平滑切换。")
	_assert_true(await _wait_engine_seconds(bgm_player, 0.70), "返回菜单交叉淡化必须在墙钟看门狗内完成。")
	var returned_menu_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(returned_menu_snapshot.get("mode", "")), "MENU", "返回主菜单后必须恢复菜单音乐状态。")
	_assert_true(is_equal_approx(float(returned_menu_snapshot.get("menu_volume_db", SILENT_VOLUME_DB)), MENU_VOLUME_DB), "反向切换后菜单曲必须恢复独立降低后的响度。")
	_assert_true(float(returned_menu_snapshot.get("shift_volume_db", 0.0)) <= SILENT_VOLUME_DB + 0.1, "反向切换后不得残留夜班曲响度。")
	if ambience_bus_index >= 0:
		_assert_true(is_equal_approx(AudioServer.get_bus_volume_db(ambience_bus_index), ambience_before_db), "反向切换不得修改 Ambience 总线。")

	bgm_player.call(&"stop_and_release_for_verification")
	await process_frame
	await process_frame
	var released_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(released_snapshot.get("player_count", -1)), 0, "专项清理后不得保留 BGM 播放器。")
	_finish()


func _wait_engine_seconds(node: Node, duration_seconds: float) -> bool:
	var elapsed_seconds: float = 0.0
	var wall_started_at_msec: int = Time.get_ticks_msec()
	while elapsed_seconds < duration_seconds:
		await process_frame
		elapsed_seconds += node.get_process_delta_time()
		if float(Time.get_ticks_msec() - wall_started_at_msec) / 1000.0 > WALL_WATCHDOG_SECONDS:
			return false
	return true


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][BgmPlayer] %s" % message)


func _finish() -> void:
	if _has_failed:
		print("[测试][BgmPlayer] 失败。")
		quit(1)
		return
	print("[测试][BgmPlayer] 通过：菜单 1:50 循环、独立响度、双向平滑切换及总线隔离均符合合同。")
	quit(0)
