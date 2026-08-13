extends SceneTree
## 结束图仅保留素材内返回热点与严格的成功/失败素材映射。

const ENDING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/ending_screen.tscn")

var _failures: int = 0
var _return_count: int = 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	var ending: EndingScreen = ENDING_SCREEN_SCENE.instantiate() as EndingScreen
	var sound_player: Node = root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	_assert_true(ending != null, "结束页必须可实例化。")
	if ending == null:
		_finish()
		return
	root.add_child(ending)
	await process_frame
	if sound_player != null:
		sound_player.call(&"reset_button_click_count_for_verification")
	ending.return_to_menu_requested.connect(func() -> void: _return_count += 1)
	_assert_true(ending.get_node_or_null(NodePath("ActionsPanel")) == null, "结束页不得保留底部额外操作面板。")
	_assert_true(ending.get_node_or_null(NodePath("RestartButton")) == null and ending.get_node_or_null(NodePath("LoadGameButton")) == null, "结束页不得提供重新开始或读取存档入口。")
	var hotspot: Button = ending.get_node_or_null(NodePath("ReturnToMenuHotspot")) as Button
	var art: TextureRect = ending.get_node_or_null(NodePath("EndingArt")) as TextureRect
	_assert_true(hotspot != null and art != null, "结束页必须提供素材内返回热点与结束图。")
	if hotspot != null and art != null:
		_assert_true(art.get_global_rect().encloses(hotspot.get_global_rect()), "返回热点必须覆盖在结束图内已有的返回图形上。")
		hotspot.emit_signal(&"pressed")
	_assert_true(_return_count == 1, "素材内返回热点必须只发出一次返回主菜单意图。")
	if sound_player != null:
		var audio_snapshot: Dictionary = sound_player.call(&"get_button_click_snapshot") as Dictionary
		_assert_true(int(audio_snapshot.get("play_count", 0)) == 1, "有效返回热点必须只播放一次按钮声。")
	_assert_art(ending, EndingScreen.EndResult.SUCCESS, "res://UI美术/值夜成功.png")
	_assert_art(ending, EndingScreen.EndResult.FAILURE, "res://UI美术/值夜失败.png")
	var unknown_result: Dictionary = ending.set_result(99)
	_assert_true(not bool(unknown_result.get("ok", true)) and String(unknown_result.get("error_code", "")) == "unknown_end_result", "结束页必须拒绝未知结果值。")
	ending.queue_free()
	await process_frame
	_finish()


func _assert_art(ending: EndingScreen, result: EndingScreen.EndResult, expected_path: String) -> void:
	var result_set: Dictionary = ending.set_result(result)
	_assert_true(bool(result_set.get("ok", false)), "结束页必须接受已声明结果。")
	var snapshot: Dictionary = ending.get_ending_art_snapshot()
	_assert_true(String(snapshot.get("resource_path", "")) == expected_path, "结束图必须使用对应素材。")


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[测试][EndingScreenUI] %s" % message)


func _finish() -> void:
	if _failures > 0:
		quit(1)
		return
	print("[测试][EndingScreenUI] 通过：两张结束图均只保留素材内返回热点。")
	quit(0)
