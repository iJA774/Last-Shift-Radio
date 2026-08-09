extends SceneTree

## 固定视图导航与跨视图来电指示验证。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var app: Control = MAIN_SCENE.instantiate()
	root.add_child(app)
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "导航测试启动后必须先进入主菜单。")
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"confirm_content_notice")
	await process_frame

	var game_screen: GameScreen = app.get("_game_screen") as GameScreen
	var phone_system: RefCounted = app.get("_phone_system") as RefCounted
	_assert_true(game_screen != null, "测试需要已注入运行时的 GameScreen。")
	_assert_true(phone_system != null, "测试需要 Main 创建的 PhoneSystem。")
	if game_screen == null or phone_system == null:
		_finish()
		return

	var studio: Control = game_screen.get_node("ViewHost/StudioOverview") as Control
	var phone: Control = game_screen.get_node("ViewHost/PhoneCloseup") as Control
	var computer: Control = game_screen.get_node("ViewHost/ComputerCloseup") as Control
	var door: Control = game_screen.get_node("ViewHost/DoorWindowCloseup") as Control
	var global_status: GlobalStatus = game_screen.get_node("GlobalStatus") as GlobalStatus
	_assert_true(studio != null and phone != null and computer != null and door != null, "GameScreen 必须实例化四个固定视图。")
	_assert_true(global_status != null, "GameScreen 必须实例化始终可见的 GlobalStatus。")
	if studio == null or phone == null or computer == null or door == null or global_status == null:
		_finish()
		return
	var time_label: Label = global_status.get_node("Content/TimeLabel") as Label
	_assert_equal(time_label.text, "1999 年 12 月 31 日 / 01:00", "左上角必须从 1999 年 12 月 31 日凌晨一点开始。")

	_assert_equal(game_screen.get_current_view_id(), "studio", "启动后必须停留在工作室总览。")
	_assert_exactly_one_active_view(game_screen, "studio")
	_press(studio.get_node("PhoneHotspot") as Button, "总览电话热点必须可点击。")
	_assert_equal(game_screen.get_current_view_id(), "phone", "点击总览电话热点必须进入电话近景。")
	_assert_true(game_screen.is_view_transitioning(), "总览进入电话近景必须启动异步过渡。")
	_assert_exactly_one_active_view(game_screen, "phone")
	# 在电话过渡尚未结束时返回，验证新请求会抢占旧 Tween 而不留下半状态。
	_press(phone.get_node("BackButton") as Button, "电话近景必须提供返回总览控件。")
	_assert_equal(game_screen.get_current_view_id(), "studio", "电话近景只能通过返回控件回到工作室总览。")
	_assert_true(game_screen.is_view_transitioning(), "近景返回总览必须启动反向缩回过渡。")
	_assert_exactly_one_active_view(game_screen, "studio")
	await _wait_for_seconds(0.30)
	_assert_true(not game_screen.is_view_transitioning(), "电话返回总览的过渡必须在规定时间内结束。")
	_assert_all_view_visuals_rest(game_screen)

	_press(studio.get_node("ComputerHotspot") as Button, "总览电脑热点必须可点击。")
	_assert_equal(game_screen.get_current_view_id(), "computer", "点击总览电脑热点必须进入电脑近景。")
	_assert_true(game_screen.is_view_transitioning(), "总览进入电脑近景必须启动异步淡入过渡。")
	await _wait_for_seconds(0.32)
	_assert_true(not game_screen.is_view_transitioning(), "电脑过渡必须在 0.26 秒后完整结束。")
	_press(computer.get_node("BackButton") as Button, "电脑近景必须提供返回总览控件。")
	_assert_equal(game_screen.get_current_view_id(), "studio", "电脑近景返回必须回到工作室总览。")
	await _wait_for_seconds(0.30)

	_press(studio.get_node("DoorHotspot") as Button, "总览门窗热点必须可点击。")
	_assert_equal(game_screen.get_current_view_id(), "door", "点击总览门窗热点必须进入门与观察窗近景。")
	_assert_true(game_screen.is_view_transitioning(), "总览进入门窗近景必须启动较慢过渡。")
	await _wait_for_seconds(0.38)
	_assert_true(not game_screen.is_view_transitioning(), "门窗过渡必须在 0.32 秒后完整结束。")
	_press(door.get_node("BackButton") as Button, "门窗近景必须提供返回总览控件。")
	_assert_equal(game_screen.get_current_view_id(), "studio", "门窗近景返回必须回到工作室总览。")
	await _wait_for_seconds(0.30)

	# 统一控制器必须能合并快速连续请求，最终不能保留多个可见或可输入视图。
	game_screen.show_view("phone")
	await process_frame
	game_screen.show_view("computer")
	await process_frame
	game_screen.show_view("door")
	_assert_equal(game_screen.get_current_view_id(), "door", "快速连续导航后必须采用最后一个合法请求。")
	_assert_true(game_screen.is_view_transitioning(), "快速连续导航后的最后一个请求必须保留自己的过渡。")
	_assert_exactly_one_active_view(game_screen, "door")
	await _wait_for_seconds(0.38)
	_assert_true(not game_screen.is_view_transitioning(), "快速连续导航不能遗留进行中的 Tween。")
	_assert_all_view_visuals_rest(game_screen)

	# 测试剧情的首通电话窗口是 01:01；导航测试不能再假设 01:00 绑定运行时后
	# 自动响铃。先通过确定性验证入口精确推到窗口，再验证响铃跨越四个视图。
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	_assert_true(game_clock != null, "导航测试必须能取得 GameClock。")
	if game_clock != null:
		var current_tick_value: Variant = game_clock.call(&"get_current_game_tick")
		_assert_true(typeof(current_tick_value) == TYPE_INT, "导航测试的 GameClock 必须返回整数 tick。")
		if typeof(current_tick_value) == TYPE_INT:
			var first_call_tick: int = GameClockService.GAME_TICKS_PER_MINUTE
			var ticks_until_first_call: int = first_call_tick - int(current_tick_value)
			if ticks_until_first_call > 0:
				_assert_true(
					bool(game_clock.call(&"advance_ticks_for_verification", ticks_until_first_call)),
					"导航测试必须能精确推进到 01:01 首通来电窗口。"
				)
				await process_frame
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "01:01 首条剧情事件应在导航测试中保持响铃。")
	_assert_true(global_status.is_ringing(), "全局状态条必须从 PhoneSystem 识别响铃。")
	var ringing_text: Label = global_status.get_node("Content/RingingIndicator/RingingText") as Label
	var ringing_icon: TextureRect = global_status.get_node("Content/RingingIndicator/RingingIcon") as TextureRect
	var ringing_button: Button = global_status.get_node("Content/RingingIndicator/PhoneButton") as Button
	_assert_true(ringing_text != null and ringing_text.text.contains("电话正在响铃"), "响铃提示必须有明确中文文字。")
	_assert_true(ringing_icon != null and ringing_icon.visible, "响铃提示必须显示电话图标。")
	_assert_true(ringing_button != null, "响铃提示必须提供仅导航到电话的点击控件。")
	await process_frame
	_assert_true(global_status.is_phone_pulse_active(), "响铃时全局提示必须启动克制的视觉脉冲。")
	if ringing_button != null:
		ringing_button.emit_signal(&"mouse_entered")
		await _wait_for_seconds(0.12)
		_assert_true(ringing_button.scale.x > 1.0, "响铃导航按钮悬停时必须有轻微视觉反馈。")
		ringing_button.emit_signal(&"button_down")
		await _wait_for_seconds(0.08)
		_assert_true(ringing_button.scale.x < 1.0, "响铃导航按钮按下时必须有轻微视觉反馈。")
		ringing_button.emit_signal(&"button_up")
		ringing_button.emit_signal(&"mouse_exited")
		await _wait_for_seconds(0.12)
		_assert_equal(ringing_button.scale, Vector2.ONE, "按钮反馈结束后必须回到原始尺寸。")
	for view_id: String in ["studio", "phone", "computer", "door"]:
		var show_result: Dictionary = game_screen.show_view(view_id)
		_assert_true(bool(show_result.get("ok", false)), "响铃期间必须能切换到固定视图 %s。" % view_id)
		_assert_true(global_status.visible and global_status.is_ringing(), "视图 %s 下必须持续显示响铃状态。" % view_id)
		_assert_true(ringing_text.text.contains("电话正在响铃"), "视图 %s 下响铃文字不得消失。" % view_id)
	if ringing_button != null:
		ringing_button.emit_signal(&"pressed")
		_assert_equal(game_screen.get_current_view_id(), "phone", "点击全局响铃提示必须只前往电话近景。")
		_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "点击全局响铃提示不得自动接听电话。")

	var reduce_motion_result: Dictionary = game_screen.set_motion_enabled(false)
	_assert_true(bool(reduce_motion_result.get("ok", false)), "GameScreen 必须能启用减少动态。")
	_assert_true(not game_screen.is_motion_enabled(), "减少动态状态必须保存在导航控制器。")
	_assert_true(not global_status.is_motion_enabled(), "减少动态必须传播到全局状态条。")
	_assert_child_motion_state(game_screen, false)
	_assert_true(not global_status.is_phone_pulse_active(), "减少动态时不得保留响铃脉冲。")
	var immediate_result: Dictionary = game_screen.show_view("computer")
	_assert_true(bool(immediate_result.get("ok", false)), "减少动态时仍必须允许正常导航。")
	_assert_true(not game_screen.is_view_transitioning(), "减少动态时视图切换必须立即完成。")
	_assert_exactly_one_active_view(game_screen, "computer")
	_assert_all_view_visuals_rest(game_screen)
	var restore_motion_result: Dictionary = game_screen.set_motion_enabled(true)
	_assert_true(bool(restore_motion_result.get("ok", false)), "GameScreen 必须能恢复动态。")
	_assert_child_motion_state(game_screen, true)
	_assert_true(global_status.is_phone_pulse_active(), "恢复动态且仍在响铃时必须恢复提示脉冲。")
	var door_transition_result: Dictionary = game_screen.show_view("door")
	_assert_true(bool(door_transition_result.get("ok", false)) and game_screen.is_view_transitioning(), "恢复动态后必须重新使用异步视图过渡。")

	if game_clock != null:
		var remaining_ticks: Variant = game_clock.call(&"get_remaining_game_ticks")
		_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", int(remaining_ticks))), "导航测试必须能推进到 02:00。")
		await process_frame
		_assert_equal(game_screen.get_current_view_id(), "computer", "02:00 必须覆盖任意当前视图并切到电脑。")
		_assert_true(not game_screen.is_view_transitioning(), "02:00 必须立即抢占并终止正在进行的视图过渡。")
		_assert_all_view_visuals_rest(game_screen)
		_assert_true(not global_status.is_phone_pulse_active(), "02:00 中断来电后不得保留全局响铃脉冲。")
		var rejected_result: Dictionary = game_screen.show_view("door")
		_assert_true(not bool(rejected_result.get("ok", false)), "02:00 后不得导航到门窗近景。")
		_assert_equal(game_screen.get_current_view_id(), "computer", "被拒绝的收束后导航不得离开电脑。")
		var computer_back_button: Button = computer.get_node("BackButton") as Button
		_assert_true(computer_back_button != null and computer_back_button.disabled, "02:00 收束页的返回总览按钮必须明确禁用。")
		if computer_back_button != null:
			_assert_true(computer_back_button.text.contains("不可用"), "禁用的收束页返回按钮必须显示中文不可用原因。")
		_assert_exactly_one_active_view(game_screen, "computer")
	_finish()


func _press(button: Button, message: String) -> void:
	_assert_true(button != null, message)
	if button != null:
		button.emit_signal(&"pressed")


func _wait_for_seconds(seconds: float) -> void:
	await create_timer(seconds).timeout


func _assert_exactly_one_active_view(game_screen: GameScreen, expected_view_id: String) -> void:
	var view_paths: Dictionary[String, String] = {
		"studio": "ViewHost/StudioOverview",
		"phone": "ViewHost/PhoneCloseup",
		"computer": "ViewHost/ComputerCloseup",
		"door": "ViewHost/DoorWindowCloseup",
	}
	var visible_count: int = 0
	for view_id: String in view_paths:
		var view: Control = game_screen.get_node(view_paths[view_id]) as Control
		if view.visible:
			visible_count += 1
		var should_be_active: bool = view_id == expected_view_id
		_assert_true(view.visible == should_be_active, "视图 %s 的可见性必须与当前视图一致。" % view_id)
		var expected_filter: Control.MouseFilter = Control.MOUSE_FILTER_STOP if should_be_active else Control.MOUSE_FILTER_IGNORE
		_assert_equal(view.mouse_filter, expected_filter, "视图 %s 的鼠标输入状态不正确。" % view_id)
	_assert_equal(visible_count, 1, "任意时刻只能有一个固定视图可见。")


func _assert_all_view_visuals_rest(game_screen: GameScreen) -> void:
	for view_path: String in [
		"ViewHost/StudioOverview",
		"ViewHost/PhoneCloseup",
		"ViewHost/ComputerCloseup",
		"ViewHost/DoorWindowCloseup",
	]:
		var view: Control = game_screen.get_node(view_path) as Control
		_assert_true(view != null, "过渡检查缺少视图 %s。" % view_path)
		if view == null:
			continue
		_assert_equal(view.scale, Vector2.ONE, "过渡结束后 %s 必须恢复原始缩放。" % view_path)
		_assert_equal(view.position, Vector2.ZERO, "过渡结束后 %s 必须恢复原始位置。" % view_path)
		_assert_equal(view.self_modulate, Color.WHITE, "过渡结束后 %s 不得残留半透明状态。" % view_path)


func _assert_child_motion_state(game_screen: GameScreen, expected: bool) -> void:
	for view_path: String in [
		"ViewHost/StudioOverview",
		"ViewHost/PhoneCloseup",
		"ViewHost/ComputerCloseup",
		"ViewHost/DoorWindowCloseup",
	]:
		var view: Control = game_screen.get_node(view_path) as Control
		_assert_true(view != null, "减少动态传播检查缺少视图 %s。" % view_path)
		if view != null:
			_assert_equal(bool(view.get("_is_motion_enabled")), expected, "减少动态必须传播到 %s。" % view_path)


func _finish() -> void:
	if _has_failed:
		print("[测试][NavigationAndCallIndicator] 失败。")
		quit(1)
		return
	print("[测试][NavigationAndCallIndicator] 通过：四视图导航、跨视图响铃提示与 02:00 锁定均符合契约。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][NavigationAndCallIndicator] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
