extends SceneTree

## 任务通知图形验收：等待完整滑入后保存独立 1920×1080 帧，避免覆盖已导入旧截图。
const GAME_SCREEN_SCENE: PackedScene = preload("res://scenes/studio/game_screen.tscn")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase10"
const OUTPUT_PATH: String = OUTPUT_DIRECTORY + "/task_notification_1920x1080.png"


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	var screen: GameScreen = GAME_SCREEN_SCENE.instantiate() as GameScreen
	if screen == null:
		_fail("无法实例化 GameScreen。")
		return
	root.add_child(screen)
	await process_frame
	screen.call(&"_on_broadcast_decision_required", {"id": "task_capture", "name": "北桥封锁广播"})
	# 滑入为 0.35 秒；0.45 秒保证截图时纸条已位于完整可读位置。
	await create_timer(0.45).timeout
	var panel: Control = screen.find_child("TaskDecisionNotification", true, false) as Control
	if panel == null or not panel.visible or panel.position != Vector2(24.0, 200.0):
		_fail("任务通知未在滑入完成后进入预期位置。")
		return
	var directory_error: Error = DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	if directory_error != OK:
		_fail("无法创建通知截图目录，错误码=%d。" % directory_error)
		return
	var image: Image = root.get_texture().get_image()
	var save_error: Error = image.save_png(ProjectSettings.globalize_path(OUTPUT_PATH))
	if save_error != OK:
		_fail("无法保存任务通知截图，错误码=%d。" % save_error)
		return
	print("[测试][TaskNotificationCapture] 已保存 1920×1080 任务通知验收帧：%s。" % OUTPUT_PATH)
	quit(0)


func _fail(message: String) -> void:
	push_error("[测试][TaskNotificationCapture] %s" % message)
	quit(1)
