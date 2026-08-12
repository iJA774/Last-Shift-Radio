extends SceneTree

## 主菜单与夜班 ESC 三项必须共用同一持久化点击音播放器。

const MAIN_MENU_SCENE: PackedScene = preload("res://scenes/app/main_menu.tscn")
const MAIN_SCENE: PackedScene = preload("res://scenes/app/main.tscn")
const SHIFT_CONTROL_BAR_SCENE: PackedScene = preload("res://scenes/ui/shift_control_bar.tscn")
const BUTTON_PATHS: Array[NodePath] = [
	NodePath("Content/MenuPanel/Margin/Layout/StartShiftButton"),
	NodePath("Content/MenuPanel/Margin/Layout/LoadGameButton"),
	NodePath("Content/MenuPanel/Margin/Layout/SettingsButton"),
	NodePath("Content/MenuPanel/Margin/Layout/ExitButton"),
]
const ESC_BUTTON_PATHS: Array[NodePath] = [
	NodePath("Backdrop/MenuArt/ActionHotspots/SettingsButton"),
	NodePath("Backdrop/MenuArt/ActionHotspots/SaveButton"),
	NodePath("Backdrop/MenuArt/ActionHotspots/ExitButton"),
]

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var sound_player: Node = root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	_assert_true(sound_player != null, "项目必须注册持久化 UiSoundPlayer 自动加载节点。")
	if sound_player == null:
		_finish()
		return
	_assert_true(sound_player.has_method(&"play_button_click"), "UiSoundPlayer 必须公开 play_button_click()。")
	_assert_true(sound_player.has_method(&"get_button_click_snapshot"), "UiSoundPlayer 必须公开只读验证快照。")
	if not sound_player.has_method(&"get_button_click_snapshot"):
		_finish()
		return
	var initial_snapshot: Dictionary = sound_player.call(&"get_button_click_snapshot") as Dictionary
	_assert_equal(String(initial_snapshot.get("stream_path", "")), "res://音效/按钮/bong_001.wav", "菜单点击音必须使用指定 bong_001.wav。")
	_assert_equal(String(initial_snapshot.get("bus_name", "")), "UIPhone", "菜单点击音必须路由到 UIPhone 总线。")
	_assert_true(int(initial_snapshot.get("player_count", 0)) >= 2, "切换场景后要听完点击音，播放器至少需要两个持久化声道。")

	sound_player.call(&"reset_button_click_count_for_verification")
	var main_menu: Control = MAIN_MENU_SCENE.instantiate() as Control
	root.add_child(main_menu)
	await process_frame
	for path: NodePath in BUTTON_PATHS:
		var button: Button = main_menu.get_node_or_null(path) as Button
		_assert_true(button != null, "主菜单按钮 %s 必须存在。" % String(path))
		if button != null:
			button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), BUTTON_PATHS.size(), "主菜单每个已启用按钮都必须播放一次点击音。")
	# 鼠标按下应先于 pressed 播放，随后同一次激活不得叠播第二声。
	sound_player.call(&"reset_button_click_count_for_verification")
	var start_button: Button = main_menu.get_node(BUTTON_PATHS[0]) as Button
	start_button.emit_signal(&"button_down")
	start_button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), 1, "鼠标按下与 pressed 属于同一次主菜单激活，只能播放一声。")
	# 鼠标按下后拖出热点释放不会产生 pressed，必须清理标记，后续键盘激活仍能播放。
	sound_player.call(&"reset_button_click_count_for_verification")
	start_button.emit_signal(&"button_down")
	start_button.emit_signal(&"button_up")
	await process_frame
	start_button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), 2, "主菜单拖出释放后，后续键盘激活必须仍播放点击音。")
	root.remove_child(main_menu)
	main_menu.queue_free()

	sound_player.call(&"reset_button_click_count_for_verification")
	var control_bar: Control = SHIFT_CONTROL_BAR_SCENE.instantiate() as Control
	root.add_child(control_bar)
	await process_frame
	for path: NodePath in ESC_BUTTON_PATHS:
		var button: Button = control_bar.get_node_or_null(path) as Button
		_assert_true(button != null, "ESC 菜单按钮 %s 必须存在。" % String(path))
		if button != null:
			button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), ESC_BUTTON_PATHS.size(), "ESC 菜单的设置、存档、退出均必须播放点击音。")
	sound_player.call(&"reset_button_click_count_for_verification")
	var esc_settings_button: Button = control_bar.get_node(ESC_BUTTON_PATHS[0]) as Button
	esc_settings_button.emit_signal(&"button_down")
	esc_settings_button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), 1, "鼠标按下与 pressed 属于同一次 ESC 激活，只能播放一声。")
	sound_player.call(&"reset_button_click_count_for_verification")
	esc_settings_button.emit_signal(&"button_down")
	esc_settings_button.emit_signal(&"button_up")
	await process_frame
	esc_settings_button.emit_signal(&"pressed")
	_assert_equal(_get_play_count(sound_player), 2, "ESC 菜单拖出释放后，后续键盘激活必须仍播放点击音。")

	# ESC 本身也属于可听见的界面操作：打开和关闭控制栏各播放一声。
	root.remove_child(control_bar)
	control_bar.queue_free()
	await process_frame
	_test_escape_and_settings_return_sounds(sound_player)

	# 极快连点不可停止已开始的声道；上限内并发，超过上限只丢弃新声而不截断旧声。
	sound_player.call(&"reset_button_click_count_for_verification")
	for _index: int in 32:
		sound_player.call(&"play_button_click")
	var rapid_snapshot: Dictionary = sound_player.call(&"get_button_click_snapshot") as Dictionary
	_assert_true(
		int(rapid_snapshot.get("active_player_count", 0)) <= int(rapid_snapshot.get("player_count", 0)),
		"快速点击时活跃点击音不得超过预分配声道，也不得靠重启声道截断旧音。"
	)
	_assert_true(int(rapid_snapshot.get("play_count", 0)) <= int(rapid_snapshot.get("player_count", 0)), "所有声道忙碌时必须拒绝新点击而非截断先前音效。")
	# 退出专项测试前停止仍在播放的短音效，并让 queue_free 真正完成；否则会把测试退出时的对象残留误报成产品泄漏。
	sound_player.call(&"reset_button_click_count_for_verification")
	await process_frame
	await process_frame
	_finish()


func _test_escape_and_settings_return_sounds(sound_player: Node) -> void:
	# 通过应用壳创建已绑定运行时的 GameScreen，避免裸场景缺少 GameClock 时把正常测试
	# 行为记录为产品错误。
	var app: Control = MAIN_SCENE.instantiate() as Control
	root.add_child(app)
	await process_frame
	app.call(&"request_start_shift")
	await process_frame
	app.call(&"finish_loading_for_verification")
	await process_frame
	var game_screen: GameScreen = app.get("_game_screen") as GameScreen
	_assert_true(game_screen != null, "ESC 与设置返回音效专项必须由应用壳创建 GameScreen。")
	if game_screen == null:
		root.remove_child(app)
		app.queue_free()
		return

	sound_player.call(&"reset_button_click_count_for_verification")
	_press_escape(game_screen)
	_assert_true(game_screen.is_control_bar_open(), "按 ESC 必须打开夜班控制栏。")
	_assert_equal(_get_play_count(sound_player), 1, "单次按 ESC 打开控制栏必须只播放一声。")
	_press_escape(game_screen)
	_assert_true(not game_screen.is_control_bar_open(), "再次按 ESC 必须关闭夜班控制栏。")
	_assert_equal(_get_play_count(sound_player), 2, "关闭控制栏的 ESC 必须额外播放且只播放一声。")

	# 通过控制栏进入真实设置覆盖层；其后的返回必须由设置页消费，不能重新打开底层控制栏。
	_press_escape(game_screen)
	var control_bar: Control = game_screen.get_node_or_null(NodePath("ShiftControlBar")) as Control
	var settings_button: Button = control_bar.get_node_or_null(NodePath("Backdrop/MenuArt/ActionHotspots/SettingsButton")) as Button if control_bar != null else null
	_assert_true(settings_button != null, "设置返回音效专项需要 ESC 菜单中的设置按钮。")
	if settings_button == null:
		root.remove_child(app)
		app.queue_free()
		return
	settings_button.emit_signal(&"pressed")
	await process_frame
	var settings_panel: SettingsPanel = game_screen.get_node_or_null(NodePath("SettingsPanel")) as SettingsPanel
	_assert_true(settings_panel != null and not game_screen.is_control_bar_open(), "打开设置覆盖层时必须关闭底层控制栏。")
	if settings_panel == null:
		root.remove_child(app)
		app.queue_free()
		return

	var close_button: Button = settings_panel.get_node_or_null(NodePath("Controls/CloseButton")) as Button
	_assert_true(close_button != null, "设置页必须提供返回按钮。")
	if close_button != null:
		sound_player.call(&"reset_button_click_count_for_verification")
		close_button.emit_signal(&"button_down")
		close_button.emit_signal(&"pressed")
		_assert_equal(_get_play_count(sound_player), 1, "设置返回按钮的鼠标按下与 pressed 属于同一次输入，只能播放一声。")
		settings_panel.call(&"finish_fade_for_verification")
		await process_frame

	# 重新打开设置页，验证 ESC 关闭同样起声，并且绝不落到底层 GameScreen 打开控制栏。
	_press_escape(game_screen)
	control_bar = game_screen.get_node_or_null(NodePath("ShiftControlBar")) as Control
	settings_button = control_bar.get_node_or_null(NodePath("Backdrop/MenuArt/ActionHotspots/SettingsButton")) as Button if control_bar != null else null
	if settings_button != null:
		settings_button.emit_signal(&"pressed")
	await process_frame
	settings_panel = game_screen.get_node_or_null(NodePath("SettingsPanel")) as SettingsPanel
	_assert_true(settings_panel != null, "设置返回音效专项必须能再次打开设置覆盖层。")
	if settings_panel != null:
		sound_player.call(&"reset_button_click_count_for_verification")
		_press_escape(settings_panel)
		# 模拟未处理输入继续向上冒泡时，GameScreen 必须因覆盖层存在而拒绝创建控制栏。
		_press_escape(game_screen)
		_assert_equal(_get_play_count(sound_player), 1, "设置覆盖层中的单次 ESC 返回必须只播放一声。")
		_assert_true(not game_screen.is_control_bar_open(), "设置覆盖层消费 ESC 时不得触发底层控制栏。")
		settings_panel.call(&"finish_fade_for_verification")
		await process_frame

	# 读取/保存覆盖层同样是现有 ui_cancel 路径；其 Esc 必须独立消费且只发一声。
	_press_escape(game_screen)
	control_bar = game_screen.get_node_or_null(NodePath("ShiftControlBar")) as Control
	var save_button: Button = control_bar.get_node_or_null(NodePath("Backdrop/MenuArt/ActionHotspots/SaveButton")) as Button if control_bar != null else null
	_assert_true(save_button != null, "存档返回音效专项需要 ESC 菜单中的存档按钮。")
	if save_button != null:
		save_button.emit_signal(&"pressed")
	await process_frame
	var save_panel: SaveSlotPanel = game_screen.get_node_or_null(NodePath("SaveSlotPanel")) as SaveSlotPanel
	_assert_true(save_panel != null and not game_screen.is_control_bar_open(), "打开存档覆盖层时必须关闭底层控制栏。")
	if save_panel != null:
		sound_player.call(&"reset_button_click_count_for_verification")
		_press_escape(save_panel)
		_press_escape(game_screen)
		_assert_equal(_get_play_count(sound_player), 1, "存档覆盖层中的单次 ESC 返回必须只播放一声。")
		_assert_true(not game_screen.is_control_bar_open(), "存档覆盖层消费 ESC 时不得触发底层控制栏。")
		save_panel.call(&"finish_fade_for_verification")
		await process_frame

	root.remove_child(app)
	app.queue_free()
	await process_frame


func _press_escape(target: Control) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.pressed = true
	target.call(&"_unhandled_input", event)


func _get_play_count(sound_player: Node) -> int:
	var snapshot: Variant = sound_player.call(&"get_button_click_snapshot")
	return int((snapshot as Dictionary).get("play_count", -1)) if snapshot is Dictionary else -1


func _finish() -> void:
	if _has_failed:
		print("[测试][MenuButtonSound] 失败。")
		quit(1)
		return
	print("[测试][MenuButtonSound] 通过：指定素材、UIPhone 路由、主菜单、ESC 菜单、持久化与快速点击合同均成立。")
	quit(0)


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][MenuButtonSound] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])
