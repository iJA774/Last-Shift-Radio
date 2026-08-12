extends SceneTree

## 三分钟 BGM 必须只有一个跨页面持续的 Ambience 播放器，并在资源层启用循环。

const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/app/main_menu.tscn")
const LOADING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/loading_screen.tscn")
const BGM_PATH: String = "res://音效/BGM/post_apocalyptic_wastelands_loop_180s.ogg"

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
	_assert_true(bgm_player.has_method(&"ensure_playing"), "BgmPlayer 必须公开 ensure_playing()。")
	_assert_true(bgm_player.has_method(&"get_playback_snapshot"), "BgmPlayer 必须公开只读播放快照。")
	_assert_true(bgm_player.has_method(&"stop_and_release_for_verification"), "BgmPlayer 必须提供专项解码资源清理接口。")
	if not bgm_player.has_method(&"get_playback_snapshot"):
		_finish()
		return
	_assert_ok(bgm_player.call(&"ensure_playing"), "BGM 必须可完成播放准备。")
	var initial_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(bool(initial_snapshot.get("ok", false)), "BGM 播放器必须成功初始化。")
	_assert_equal(String(initial_snapshot.get("stream_path", "")), BGM_PATH, "BGM 必须使用三分钟裁剪素材。")
	_assert_equal(String(initial_snapshot.get("bus_name", "")), "Ambience", "BGM 必须路由到 Ambience 总线。")
	_assert_equal(int(initial_snapshot.get("player_count", 0)), 1, "BGM 必须始终只有一个播放器。")
	_assert_true(bool(initial_snapshot.get("is_loop_enabled", false)), "三分钟 BGM 必须在资源层启用循环。")
	_assert_true(is_equal_approx(float(initial_snapshot.get("loop_offset_seconds", -1.0)), 0.0), "BGM 循环必须从 0 秒重新开始。")
	_assert_true(is_equal_approx(float(initial_snapshot.get("length_seconds", -1.0)), 180.0), "Godot 导入后的 BGM 时长必须精确为 180 秒。")
	await process_frame
	var after_prepare_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	if DisplayServer.get_name().to_lower() == "headless" or AudioServer.get_driver_name().to_lower() == "dummy":
		_assert_true(not bool(after_prepare_snapshot.get("is_playing", true)), "Headless/Dummy 环境不得实际启动无意义的 BGM 播放。")
	else:
		_assert_true(bool(after_prepare_snapshot.get("is_playing", false)), "图形音频环境中 BGM 准备后必须处于播放状态。")

	var instance_id: int = bgm_player.get_instance_id()
	var main_menu: Control = MAIN_MENU_SCENE.instantiate() as Control
	root.add_child(main_menu)
	await process_frame
	root.remove_child(main_menu)
	main_menu.queue_free()
	await process_frame
	var loading_screen: Control = LOADING_SCREEN_SCENE.instantiate() as Control
	root.add_child(loading_screen)
	await process_frame
	root.remove_child(loading_screen)
	loading_screen.queue_free()
	await process_frame
	var later_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(bgm_player.get_instance_id(), instance_id, "页面切换不得重建 BGM 自动加载节点。")
	_assert_equal(int(later_snapshot.get("player_count", 0)), 1, "页面切换不得叠加第二个 BGM 播放器。")
	if DisplayServer.get_name().to_lower() != "headless" and AudioServer.get_driver_name().to_lower() != "dummy":
		_assert_true(bool(later_snapshot.get("is_playing", false)), "图形环境中页面切换后 BGM 必须持续播放。")
	bgm_player.call(&"stop_and_release_for_verification")
	await process_frame
	await process_frame
	var released_snapshot: Dictionary = bgm_player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(int(released_snapshot.get("player_count", -1)), 0, "专项清理后不得保留 BGM 播放器。")
	_assert_true(not bool(released_snapshot.get("is_playing", true)), "专项清理后 BGM 必须停止。")
	_finish()


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
	print("[测试][BgmPlayer] 通过：三分钟素材、Ambience 路由、唯一循环播放器与跨页面连续播放均符合合同。")
	quit(0)
