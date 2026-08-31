extends SceneTree

## 固定视图导航与跨视图来电指示验证。

const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")

var _has_failed: bool = false
var _exit_signal_count: int = 0


class ClockDisplayFake extends Node:
	var display_time: String = "13:05"

	func get_current_game_tick() -> int:
		return 0

	func get_display_time() -> String:
		return display_time


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var app: Control = MAIN_SCENE.instantiate()
	root.add_child(app)
	await process_frame
	_assert_equal(app.call(&"get_application_state_name"), "MAIN_MENU", "导航测试启动后必须先进入主菜单。")
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"finish_loading_for_verification")
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
	_assert_true(studio.get_node_or_null("ViewLabel") == null, "工作室总览不得保留左上角“A 号直播室／工作室总览”说明。")
	_assert_true(studio.get_node_or_null("InteractionHint") == null, "工作室总览不得保留左上角“移动鼠标”操作提示。")
	var time_frame: TextureRect = global_status.get_node("TimeFrame") as TextureRect
	var time_title: Label = global_status.get_node("Content/TimeTitle") as Label
	var clock_digits: Control = global_status.get_node("Content/ClockDigits") as Control
	_assert_true(time_frame != null, "游戏内 HUD 必须提供独立时间牌，而非顶部横向状态条。")
	if time_frame != null:
		_assert_true(
			time_frame.position.x >= 0.0 and time_frame.position.x <= 80.0 and time_frame.position.y >= 0.0 and time_frame.size.x <= 560.0,
			"时间牌必须保持为左上角独立仪表，不能退化为横跨屏幕的顶部栏。"
		)
	_assert_true(global_status.get_node_or_null("Content/WorkStateLabel") == null, "HUD 不得再显示工作状态或时间流速文字行。")
	_assert_equal(time_title.text, "1999年12月31日", "时间牌必须在素材自带的“当前时间”右侧显示固定日期。")
	_assert_true(clock_digits != null and clock_digits.visible, "时间牌必须显示由图集拼装的时钟。")
	var clock_snapshot: Dictionary = global_status.get_display_clock_snapshot()
	_assert_true(bool(clock_snapshot.get("ok", false)), "全局状态必须能提供有效的时钟显示快照。")
	_assert_equal(clock_snapshot.get("time_12h"), "01:00", "夜班开始必须显示 12 小时制 01:00。")
	_assert_equal(clock_snapshot.get("meridiem"), "AM", "夜班开始必须显示 AM。")
	for glyph_path: String in [
		"Content/ClockDigits/HourTens", "Content/ClockDigits/HourUnits", "Content/ClockDigits/MinuteTens", "Content/ClockDigits/MinuteUnits", "Content/ClockDigits/Meridiem",
	]:
		var glyph: TextureRect = global_status.get_node(glyph_path) as TextureRect
		_assert_true(glyph != null and glyph.texture is AtlasTexture, "时钟图块 %s 必须使用 AtlasTexture。" % glyph_path)
		if glyph != null and glyph.texture is AtlasTexture:
			var atlas_texture: AtlasTexture = glyph.texture as AtlasTexture
			_assert_true(atlas_texture.atlas != null and atlas_texture.atlas.resource_path == "res://UI美术/时间UI.png", "时钟图块必须来自 时间UI.png。")
	_assert_true(game_screen.get_node_or_null("SaveButton") == null, "夜班内不得保留常驻存档按钮。")
	_assert_true(game_screen.get_node_or_null("SettingsButton") == null, "夜班内不得保留常驻设置按钮。")
	_assert_true(game_screen.get_node_or_null("DutyMenuLabel") == null, "夜班内不得保留常驻值班菜单标题。")
	var game_clock: Node = root.get_node_or_null(NodePath("GameClock")) as Node
	var rate_before_control_bar: Variant = game_clock.call(&"get_time_rate_mode") if game_clock != null else null
	_press_escape(game_screen)
	_assert_true(game_screen.is_control_bar_open(), "打开控制栏后必须有覆盖层。")
	_assert_equal(game_clock.call(&"get_time_rate_mode"), rate_before_control_bar, "单独打开 ESC 控制栏不得改变时钟倍率。")
	var control_bar: Control = game_screen.get_node_or_null("ShiftControlBar") as Control
	_assert_true(control_bar != null, "控制栏必须实例化为覆盖层。")
	if control_bar != null:
		var menu_art: TextureRect = control_bar.get_node_or_null("Backdrop/MenuArt") as TextureRect
		var selection_arrow: TextureRect = control_bar.get_node_or_null("Backdrop/MenuArt/ActionHotspots/SelectionArrow") as TextureRect
		_assert_true(menu_art != null and menu_art.texture != null and menu_art.texture.resource_path == "res://UI美术/菜单UI.png", "控制栏必须完整使用菜单UI美术。")
		_assert_true(selection_arrow != null and selection_arrow.texture is AtlasTexture, "控制栏必须只显示一个裁切后的箭头素材作为选择提示。")
		_assert_true(control_bar.get_node_or_null("Backdrop/Panel") == null, "控制栏不得保留旧选择框底板。")
		_assert_true(control_bar.get_node_or_null("Backdrop/MenuArt/ActionHotspots/SettingsButton") is Button, "控制栏必须包含设置透明热点。")
		_assert_true(control_bar.get_node_or_null("Backdrop/MenuArt/ActionHotspots/SaveButton") is Button, "控制栏必须包含存档透明热点。")
		_assert_true(control_bar.get_node_or_null("Backdrop/MenuArt/ActionHotspots/ExitButton") is Button, "控制栏必须包含退出透明热点。")
		var settings_hotspot: Button = control_bar.get_node("Backdrop/MenuArt/ActionHotspots/SettingsButton") as Button
		var save_hotspot: Button = control_bar.get_node("Backdrop/MenuArt/ActionHotspots/SaveButton") as Button
		_assert_equal(String(control_bar.call(&"get_selected_action_id")), "settings", "打开 ESC 菜单时箭头必须默认指向设置。")
		save_hotspot.emit_signal(&"mouse_entered")
		_assert_equal(String(control_bar.call(&"get_selected_action_id")), "save", "鼠标悬停存档热点时箭头必须同步到存档左侧。")
		save_hotspot.emit_signal(&"button_down")
		var visual_snapshot: Dictionary = control_bar.call(&"get_visual_contract_snapshot") as Dictionary
		_assert_equal(String(visual_snapshot.get("pressed_action_id", "")), "save", "按下透明热点时箭头必须保留按下反馈状态。")
		save_hotspot.emit_signal(&"button_up")
		# Headless 没有窗口焦点所有权；直接派发 Godot 的焦点变化信号验证同一回调。
		settings_hotspot.emit_signal(&"focus_entered")
		_assert_equal(String(control_bar.call(&"get_selected_action_id")), "settings", "键盘焦点回到设置时箭头必须同步。")
		settings_hotspot.emit_signal(&"pressed")
		await process_frame
		_assert_true(not game_screen.is_control_bar_open() and game_screen.is_settings_panel_open(), "设置按钮必须关闭控制栏并打开设置面板。")
		(game_screen.get_node("SettingsPanel") as SettingsPanel).emit_signal(&"closed")
		await process_frame
		_assert_true(bool(game_screen.toggle_control_bar().get("ok", false)), "关闭设置后必须能再次打开 ESC 控制栏。")
		control_bar = game_screen.get_node("ShiftControlBar") as Control
		(control_bar.get_node("Backdrop/MenuArt/ActionHotspots/SaveButton") as Button).emit_signal(&"pressed")
		await process_frame
		_assert_true(not game_screen.is_control_bar_open() and game_screen.is_save_panel_open(), "存档按钮必须关闭控制栏并打开存档面板。")
		game_screen.call(&"_close_save_panel")
		_assert_true(bool(game_screen.toggle_control_bar().get("ok", false)), "关闭存档后必须能再次打开 ESC 控制栏。")
		control_bar = game_screen.get_node("ShiftControlBar") as Control
		var main_exit_callback: Callable = Callable(app, "_on_shift_return_to_menu_requested")
		if game_screen.is_connected(&"exit_requested", main_exit_callback):
			game_screen.disconnect(&"exit_requested", main_exit_callback)
		game_screen.connect(&"exit_requested", Callable(self, "_on_game_exit_requested"))
		(control_bar.get_node("Backdrop/MenuArt/ActionHotspots/ExitButton") as Button).emit_signal(&"pressed")
		_assert_equal(_exit_signal_count, 1, "返回主界面按钮必须先由 GameScreen 发出意图。")
		_assert_equal(String(app.call(&"get_application_state_name")), "SHIFT", "截获返回意图时不应由 GameScreen 自行切换应用页面。")
	_press_escape(game_screen)
	_assert_true(game_screen.is_control_bar_open(), "退出意图后仍必须能用 ESC 打开控制栏。")
	_press_escape(game_screen)
	_assert_true(not game_screen.is_control_bar_open(), "再次 ESC 后控制栏必须关闭。")
	_assert_equal(game_clock.call(&"get_time_rate_mode"), rate_before_control_bar, "单独关闭 ESC 控制栏不得改变时钟倍率。")

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
				var minute_snapshot: Dictionary = global_status.get_display_clock_snapshot()
				_assert_equal(minute_snapshot.get("time_12h"), "01:01", "推进一分钟后图集时钟快照必须更新到 01:01。")

		var clock_display_fake := ClockDisplayFake.new()
		root.add_child(clock_display_fake)
		var fake_bind_result: Dictionary = global_status.bind_runtime(phone_system, clock_display_fake)
		_assert_true(bool(fake_bind_result.get("ok", false)), "图集时钟必须接受符合 GameClock 公开接口的验证时钟。")
		await process_frame
		var pm_snapshot: Dictionary = global_status.get_display_clock_snapshot()
		_assert_equal(pm_snapshot.get("time_12h"), "01:05", "13:05 必须转换为 12 小时制 01:05。")
		_assert_equal(pm_snapshot.get("meridiem"), "PM", "13:05 必须显示 PM 图块。")
		var pm_texture: AtlasTexture = global_status.get_node("Content/ClockDigits/Meridiem").texture as AtlasTexture
		_assert_true(pm_texture != null and pm_texture.region.position.x >= 800.0, "PM 必须切换至 时间UI.png 的 PM 图块。")
		var restore_bind_result: Dictionary = global_status.bind_runtime(phone_system, game_clock)
		_assert_true(bool(restore_bind_result.get("ok", false)), "PM 分支验证后必须恢复真实 GameClock。")
		root.remove_child(clock_display_fake)
		clock_display_fake.free()
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "01:01 首条剧情事件应在导航测试中保持响铃。")
	_assert_true(global_status.is_ringing(), "全局状态条必须从 PhoneSystem 识别响铃。")
	var ringing_icon: TextureRect = global_status.get_node("Content/RingingIndicator/RingingIcon") as TextureRect
	_assert_true(global_status.get_node_or_null("Content/RingingIndicator/RingingText") == null, "红色响铃牌下方不得保留电话状态、人名或号码文字。")
	_assert_true(ringing_icon != null and ringing_icon.visible, "响铃提示必须显示电话图标。")
	_assert_true(global_status.get_node_or_null("Content/RingingIndicator/PhoneButton") == null, "来电提醒不得保留可点击电话按钮。")
	_assert_true(not global_status.has_signal(&"phone_view_requested"), "来电提醒不得再发出电话跳转信号。")
	_assert_equal(global_status.get_node("Content/RingingIndicator").mouse_filter, Control.MOUSE_FILTER_IGNORE, "来电提醒必须鼠标穿透。")
	var blink_before: Dictionary = global_status.get_ringing_blink_snapshot()
	_assert_equal(blink_before.get("interval_seconds"), 1.0, "来电亮灭图必须每秒切换一次。")
	_assert_true(bool(blink_before.get("timer_active", false)), "响铃时必须启用唯一的亮灭计时器。")
	phone_system.emit_signal(&"state_changed", 0, 0, "verification_repeat")
	var repeated_blink: Dictionary = global_status.get_ringing_blink_snapshot()
	_assert_equal(repeated_blink.get("start_count"), blink_before.get("start_count"), "重复电话状态通知不得创建重复来电计时器。")
	_assert_true(bool(global_status.advance_ringing_blink_for_verification(1).get("ok", false)), "亮灭图必须提供确定性验证入口。")
	var blink_after: Dictionary = global_status.get_ringing_blink_snapshot()
	_assert_true(blink_after.get("is_bright") != blink_before.get("is_bright"), "一次闪烁必须切换亮灭素材。")
	_assert_equal(int(blink_after.get("toggle_count")), int(blink_before.get("toggle_count")) + 1, "每次闪烁只能增加一次计数。")
	for view_id: String in ["studio", "phone", "computer", "door"]:
		var show_result: Dictionary = game_screen.show_view(view_id)
		_assert_true(bool(show_result.get("ok", false)), "响铃期间必须能切换到固定视图 %s。" % view_id)
		_assert_true(global_status.visible and global_status.is_ringing(), "视图 %s 下必须持续显示响铃状态。" % view_id)
		_assert_true(ringing_icon.visible, "视图 %s 下红色响铃牌不得消失。" % view_id)
	_assert_equal(String(phone_system.call(&"get_state_name")), "RINGING", "纯提醒闪烁不得自动接听电话。")

	var reduce_motion_result: Dictionary = game_screen.set_motion_enabled(false)
	_assert_true(bool(reduce_motion_result.get("ok", false)), "GameScreen 必须能启用减少动态。")
	_assert_true(not game_screen.is_motion_enabled(), "减少动态状态必须保存在导航控制器。")
	_assert_true(not global_status.is_motion_enabled(), "减少动态必须传播到全局状态条。")
	_assert_child_motion_state(game_screen, false)
	_assert_true(not bool(global_status.get_ringing_blink_snapshot().get("timer_active", true)), "减少动态时必须停止来电亮灭切换。")
	_assert_true(bool(global_status.get_ringing_blink_snapshot().get("is_bright", false)), "减少动态时必须稳定显示亮图。")
	var immediate_result: Dictionary = game_screen.show_view("computer")
	_assert_true(bool(immediate_result.get("ok", false)), "减少动态时仍必须允许正常导航。")
	_assert_true(not game_screen.is_view_transitioning(), "减少动态时视图切换必须立即完成。")
	_assert_exactly_one_active_view(game_screen, "computer")
	_assert_all_view_visuals_rest(game_screen)
	var restore_motion_result: Dictionary = game_screen.set_motion_enabled(true)
	_assert_true(bool(restore_motion_result.get("ok", false)), "GameScreen 必须能恢复动态。")
	_assert_child_motion_state(game_screen, true)
	_assert_true(bool(global_status.get_ringing_blink_snapshot().get("timer_active", false)), "恢复动态且仍在响铃时必须恢复来电亮灭切换。")
	var door_transition_result: Dictionary = game_screen.show_view("door")
	_assert_true(bool(door_transition_result.get("ok", false)) and game_screen.is_view_transitioning(), "恢复动态后必须重新使用异步视图过渡。")

	if game_clock != null:
		_assert_true(bool(game_screen.toggle_control_bar().get("ok", false)), "02:00 前必须能打开 ESC 控制栏。")
		_assert_true(game_screen.is_control_bar_open(), "02:00 前控制栏必须确实打开。")
		var remaining_ticks: Variant = game_clock.call(&"get_remaining_game_ticks")
		_assert_true(bool(game_clock.call(&"advance_ticks_for_verification", int(remaining_ticks))), "导航测试必须能推进到 02:00。")
		await process_frame
		_assert_equal(game_screen.get_current_view_id(), "computer", "02:00 必须覆盖任意当前视图并切到电脑。")
		_assert_true(not game_screen.is_control_bar_open(), "02:00 必须立即关闭 ESC 控制栏。")
		_assert_true(not game_screen.is_view_transitioning(), "02:00 必须立即抢占并终止正在进行的视图过渡。")
		_assert_all_view_visuals_rest(game_screen)
		_assert_true(not bool(global_status.get_ringing_blink_snapshot().get("timer_active", true)), "02:00 中断来电后不得保留来电亮灭计时器。")
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


func _press_escape(game_screen: GameScreen) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	game_screen.call(&"_unhandled_input", event)


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


func _on_game_exit_requested() -> void:
	_exit_signal_count += 1


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][NavigationAndCallIndicator] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
