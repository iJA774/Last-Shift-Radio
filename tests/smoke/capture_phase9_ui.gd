extends SceneTree
## 1920×1080 视觉验收：通话发言、回应区、终止后与成功/失败结束图。

const ENDING_SCREEN_SCENE: PackedScene = preload("res://scenes/app/ending_screen.tscn")
const PHONE_CLOSEUP_SCENE: PackedScene = preload("res://scenes/studio/phone_closeup.tscn")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")
const OUTPUT_DIRECTORY: String = "res://tests/artifacts/phase9"

var _failures: int = 0


class DialogueStub extends RefCounted:
	signal dialogue_changed(snapshot: Dictionary)
	var snapshot: Dictionary = {
		"speaker": "来电者",
		"text": "雨没有停。北桥的灯还亮着，可我刚才明明看见那辆车又从桥头开过去一次。",
		"is_terminal": false,
		"options": [
			{"id": "opt_confirm", "text": "请确认你看见车辆的准确时间。"},
			{"id": "opt_direction", "text": "请回忆那辆车当时朝向哪一侧。"},
			{"id": "opt_reassure", "text": "慢一点说，只登记你亲眼看见的情况。"},
		],
	}

	func get_active_dialogue_snapshot() -> Dictionary:
		return snapshot.duplicate(true)


func _init() -> void:
	call_deferred("_capture")


func _capture() -> void:
	root.size = Vector2i(1920, 1080)
	await _capture_ending(EndingScreen.EndResult.SUCCESS, "ending_success_1920x1080.png")
	await _capture_ending(EndingScreen.EndResult.FAILURE, "ending_failure_1920x1080.png")
	await _capture_phone_states()
	if _failures > 0:
		quit(1)
		return
	print("[测试][Phase9Capture] 已生成结束图及通话发言、回应、终止后的 1920×1080 截图。")
	quit(0)


func _capture_ending(result: EndingScreen.EndResult, file_name: String) -> void:
	var ending: EndingScreen = ENDING_SCREEN_SCENE.instantiate() as EndingScreen
	if ending == null:
		_fail("无法实例化结束页。")
		return
	root.add_child(ending)
	ending.set_result(result)
	await _wait_frames(4)
	await _save_viewport(file_name)
	ending.queue_free()
	await process_frame


func _capture_phone_states() -> void:
	var phone: PhoneCloseup = PHONE_CLOSEUP_SCENE.instantiate() as PhoneCloseup
	var phone_system: RefCounted = PHONE_SYSTEM_SCRIPT.new()
	var dialogue_stub: DialogueStub = DialogueStub.new()
	if phone == null:
		_fail("无法实例化电话近景。")
		return
	root.add_child(phone)
	await _wait_frames(3)
	var event_data: Dictionary = {"id": "phase9_call", "caller_display_name": "北桥来电", "caller_number": "555-0199"}
	if not bool(phone_system.call(&"begin_incoming_call", event_data, 0, 60)) or not bool(phone.bind_phone_system(phone_system).get("ok", false)):
		_fail("无法准备电话来电状态。")
		return
	phone_system.call(&"answer_call", 1)
	phone_system.call(&"enter_dialogue_choice")
	phone.bind_story_engine(dialogue_stub)
	phone.stop_text_presentation()
	await _wait_frames(3)
	await _save_viewport("phone_speech_1920x1080.png")
	var reveal_result: Dictionary = phone.reveal_dialogue_options()
	if not bool(reveal_result.get("ok", false)):
		_fail("无法显示回应选项。")
		return
	await _wait_frames(3)
	await _save_viewport("phone_speech_with_choices_1920x1080.png")
	dialogue_stub.snapshot = {
		"speaker": "来电者",
		"text": "……那就到这里吧。",
		"is_terminal": true,
		"options": [],
	}
	dialogue_stub.dialogue_changed.emit(dialogue_stub.snapshot)
	phone_system.call(&"exit_dialogue_choice")
	phone.stop_text_presentation()
	await _wait_frames(3)
	await _save_viewport("phone_terminal_1920x1080.png")
	phone.queue_free()
	await process_frame


func _save_viewport(file_name: String) -> void:
	await RenderingServer.frame_post_draw
	var directory: String = ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var make_result: Error = DirAccess.make_dir_recursive_absolute(directory)
	if make_result != OK:
		_fail("无法创建截图目录，错误码=%d。" % make_result)
		return
	var image: Image = root.get_texture().get_image()
	if image == null or image.is_empty():
		_fail("当前运行模式未生成可保存画面。")
		return
	var save_result: Error = image.save_png("%s/%s" % [directory, file_name])
	if save_result != OK:
		_fail("无法保存截图 %s，错误码=%d。" % [file_name, save_result])


func _wait_frames(count: int) -> void:
	for _index: int in count:
		await process_frame


func _fail(message: String) -> void:
	_failures += 1
	push_error("[测试][Phase9Capture] %s" % message)
