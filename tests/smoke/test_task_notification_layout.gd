extends SceneTree

## 任务通知使用原图有效区域，不能把 1536×1024 的编辑画布整体压进小卡片。
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	root.add_child(screen)
	await process_frame
	var panel: Control = screen.find_child("TaskDecisionNotification", true, false) as Control
	var label: Label = screen.find_child("TaskDecisionNotificationLabel", true, false) as Label
	_assert_true(panel != null and label != null, "GameScreen 必须构建任务通知及其文本控件。")
	if panel != null:
		_assert_equal(panel.size, Vector2(736.0, 186.0), "1920×1080 任务通知必须保持纸条正确比例。")
		var background: TextureRect = panel.get_child(0) as TextureRect
		_assert_true(background != null and background.texture is AtlasTexture, "任务通知背景必须使用 AtlasTexture 裁剪有效美术区域。")
		if background != null and background.texture is AtlasTexture:
			var atlas: AtlasTexture = background.texture as AtlasTexture
			_assert_equal(atlas.region, Rect2(32.0, 307.0, 1472.0, 372.0), "任务通知必须精确裁剪任务框有效边界。")
			_assert_true(atlas.atlas != null and atlas.atlas.resource_path == "res://UI美术/任务框.png", "AtlasTexture 必须仍引用任务框原始资源。")
	screen.call(&"_on_broadcast_decision_required", {"id": "task_abandon_a", "name": "北桥封锁广播"})
	screen.call(&"_on_broadcast_decision_required", {"id": "task_keep_b", "name": "寻车目击征集"})
	# 放弃 A 只能移除 A 的当前通知；B 必须马上成为待展示通知，不能被一并清空。
	screen.call(&"_remove_task_notifications", "task_abandon_a")
	await create_timer(0.45).timeout
	_assert_true(panel != null and panel.visible, "任务通知进场后必须可见。")
	if panel != null:
		_assert_equal(panel.position, Vector2(24.0, 200.0), "任务通知滑入位置必须避开左上时间牌安全区。")
	_assert_equal(String(screen.get("_current_task_notification_id")), "task_keep_b", "放弃 A 后只应移除 A 的当前通知。")
	_assert_true(label != null and label.text.contains("新信息可通过麦克风发送") and label.text.contains("寻车目击征集"), "通知必须完整显示固定提示和未放弃任务名。")
	# 滑入 0.35 秒之后的停留精确为 5 秒；4.8 秒后仍应处于可读停留阶段。
	await create_timer(4.70).timeout
	_assert_true(panel != null and panel.visible, "任务通知必须在 5 秒停留期间保持显示。")
	await create_timer(0.70).timeout
	_assert_true(panel != null and not panel.visible, "任务通知在离场完成后必须隐藏。")
	root.remove_child(screen)
	screen.queue_free()
	_finish()


func _finish() -> void:
	if _has_failed:
		print("[测试][TaskNotificationLayout] 失败。")
		quit(1)
		return
	print("[测试][TaskNotificationLayout] 通过：图集裁剪、文本安全区与五秒停留合同成立。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][TaskNotificationLayout] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
