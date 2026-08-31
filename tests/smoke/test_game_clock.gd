extends SceneTree

const GAME_CLOCK_SCRIPT: GDScript = preload("res://scripts/core/game_clock.gd")

var _ending_signal_count: int = 0
var _minute_signal_count: int = 0
var _signal_order: Array[String] = []
var _has_failed: bool = false
var _shift_duration_ticks: int = 0
var _shift_started_count: int = 0
var _rate_ending_signal_count: int = 0


func _init() -> void:
	var test_clock = GAME_CLOCK_SCRIPT.new()
	root.add_child(test_clock)
	test_clock.ending_time_reached.connect(_on_ending_time_reached)
	test_clock.game_time_advanced.connect(_on_game_time_advanced)
	test_clock.game_minute_changed.connect(_on_game_minute_changed)
	test_clock.shift_started.connect(_on_shift_started)
	_shift_duration_ticks = test_clock.get_shift_duration_ticks()

	var initial_prepare: Dictionary = test_clock.prepare_new_shift()
	_assert_true(bool(initial_prepare.get("ok", false)), "停止的时钟必须允许 prepare_new_shift。")
	_assert_equal(test_clock.get_current_game_tick(), 0, "预备新夜班后必须停在 01:00。")
	_assert_true(not test_clock.is_running(), "prepare_new_shift 不得启动时钟。")
	_assert_equal(_shift_started_count, 0, "prepare_new_shift 不得发送 shift_started。")
	test_clock.start_shift()
	_assert_equal(test_clock.get_current_game_tick(), 0, "启动时应处于 01:00。")
	_assert_equal(test_clock.get_display_time(), "01:00", "启动显示时间应为 01:00。")
	_assert_equal(_shift_duration_ticks, 3_600, "夜班应从 01:00 精确持续至 02:00（3,600 tick）。")
	_assert_equal(_shift_started_count, 1, "start_shift 必须只发送一次正式启动信号。")
	_test_real_time_rate_contract()
	var running_prepare: Dictionary = test_clock.prepare_new_shift()
	_assert_true(not bool(running_prepare.get("ok", false)), "运行中的时钟必须拒绝 prepare_new_shift。")
	_assert_equal(String(running_prepare.get("error_code", "")), "clock_running", "运行中预备失败必须给出稳定错误码。")
	_assert_equal(test_clock.get_current_game_tick(), 0, "被拒绝的预备不得改变运行中时钟。")

	_assert_true(test_clock.advance_ticks_for_verification(59), "验证接口应接受正整数推进。")
	_assert_equal(test_clock.get_current_game_tick(), 59, "59 tick 后不应跨过第一个游戏分钟。")
	_assert_equal(_minute_signal_count, 0, "未跨分钟时不得发送分钟信号。")

	_assert_true(test_clock.advance_ticks_for_verification(1), "第 60 个 tick 应可推进。")
	_assert_equal(test_clock.get_display_time(), "01:01", "60 tick 后应显示 01:01。")
	_assert_equal(_minute_signal_count, 1, "跨过一个分钟边界时应发送一次信号。")

	_signal_order.clear()
	_assert_true(
		test_clock.advance_ticks_for_verification(_shift_duration_ticks - 60),
		"应能确定性推进至 02:00。"
	)
	_assert_equal(test_clock.get_current_game_tick(), _shift_duration_ticks, "收束 tick 必须精确为 3600。")
	_assert_equal(test_clock.get_display_time(), "02:00", "收束显示时间应为 02:00。")
	_assert_true(test_clock.is_shift_ended(), "02:00 后必须标记为已收束。")
	_assert_equal(_ending_signal_count, 1, "ending_time_reached 必须只发一次。")
	_assert_equal(_signal_order, ["ending", "time"], "收束必须先于普通时间推进通知。")
	_assert_true(not test_clock.is_running(), "收束后计时器必须停止，避免重复推进或重复发送收束信号。")
	var post_ending_prepare: Dictionary = test_clock.prepare_new_shift()
	_assert_true(bool(post_ending_prepare.get("ok", false)), "02:00 后停止的时钟必须允许为下一局预备。")
	_assert_equal(test_clock.get_current_game_tick(), 0, "局间预备必须归零 tick。")
	_assert_true(not test_clock.is_shift_ended(), "局间预备必须清除上局 ending 标记。")
	_assert_true(not test_clock.is_running(), "局间预备仍不得启动时钟。")
	_assert_equal(_shift_started_count, 1, "局间预备不得额外发送 shift_started。")

	if _has_failed:
		print("[测试][GameClock] 失败。")
		quit(1)
		return

	print("[测试][GameClock] 通过：整数 tick、动态倍率、分钟边界与 02:00 强制收束均符合契约。")
	quit(0)


func _test_real_time_rate_contract() -> void:
	var rate_clock = GAME_CLOCK_SCRIPT.new()
	root.add_child(rate_clock)
	rate_clock.start_shift()
	_assert_equal(
		rate_clock.get_time_rate_mode(),
		GameClockService.TimeRate.FAST,
		"夜班默认必须使用常态 FAST 倍率。"
	)
	_assert_equal(
		rate_clock.get_real_usec_per_game_minute(),
		GameClockService.FAST_REAL_USEC_PER_GAME_MINUTE,
		"常态倍率必须为 3 现实秒对应 1 游戏分钟。"
	)
	_assert_true(
		rate_clock.advance_real_usec_for_verification(GameClockService.FAST_REAL_USEC_PER_GAME_MINUTE),
		"常态倍率必须接受确定性真实时间推进。"
	)
	_assert_equal(rate_clock.get_current_game_tick(), 60, "3 现实秒在常态倍率下必须精确推进 1 游戏分钟。")
	var slow_result: Dictionary = rate_clock.set_time_rate_mode_for_verification(GameClockService.TimeRate.SLOW)
	_assert_true(bool(slow_result.get("ok", false)), "时钟必须允许切换到 SLOW 倍率。")
	_assert_equal(
		rate_clock.get_real_usec_per_game_minute(),
		GameClockService.SLOW_REAL_USEC_PER_GAME_MINUTE,
		"SLOW 倍率必须为 60 现实秒对应 1 游戏分钟。"
	)
	_assert_true(
		rate_clock.advance_real_usec_for_verification(GameClockService.SLOW_REAL_USEC_PER_GAME_MINUTE),
		"SLOW 倍率必须接受确定性真实时间推进。"
	)
	_assert_equal(rate_clock.get_current_game_tick(), 120, "60 现实秒在 SLOW 倍率下必须只推进 1 游戏分钟。")
	_cleanup_clock(rate_clock)

	var boundary_clock = GAME_CLOCK_SCRIPT.new()
	root.add_child(boundary_clock)
	boundary_clock.start_shift()
	_assert_true(
		boundary_clock.advance_real_usec_for_verification(49_999),
		"倍率切换边界前必须能注入不足一个 tick 的常态真实时间。"
	)
	_assert_equal(boundary_clock.get_current_game_tick(), 0, "49,999 微秒常态时间不足一个完整 tick。")
	var boundary_rate_result: Dictionary = boundary_clock.set_time_rate_mode_for_verification(GameClockService.TimeRate.SLOW)
	_assert_true(bool(boundary_rate_result.get("ok", false)), "边界处必须允许切换到 SLOW 倍率。")
	_assert_true(boundary_clock.advance_real_usec_for_verification(19), "切换后的部分真实时间必须可累计。")
	_assert_equal(boundary_clock.get_current_game_tick(), 0, "切换后 19 微秒仍不足以补齐原有分数 tick。")
	_assert_true(boundary_clock.advance_real_usec_for_verification(1), "切换后必须能补齐原有分数 tick。")
	_assert_equal(
		boundary_clock.get_current_game_tick(),
		1,
		"倍率切换必须保留分数游戏进度，不能丢失或重复 tick。"
	)
	_cleanup_clock(boundary_clock)

	var ending_clock = GAME_CLOCK_SCRIPT.new()
	root.add_child(ending_clock)
	_rate_ending_signal_count = 0
	ending_clock.ending_time_reached.connect(_on_rate_ending_time_reached)
	ending_clock.start_shift()
	_assert_true(
		bool(ending_clock.set_time_rate_mode_for_verification(GameClockService.TimeRate.SLOW).get("ok", false)),
		"02:00 边界测试必须能进入 SLOW 倍率。"
	)
	_assert_true(
		ending_clock.advance_real_usec_for_verification(
			GameClockService.SLOW_REAL_USEC_PER_GAME_MINUTE * (GameClockService.SHIFT_DURATION_MINUTES - 1)
		),
		"SLOW 倍率下必须能确定性推进至 01:59。"
	)
	_assert_equal(ending_clock.get_current_game_tick(), 3_540, "01:59 前的慢速推进 tick 必须精确。")
	_assert_true(
		bool(ending_clock.set_time_rate_mode_for_verification(GameClockService.TimeRate.FAST).get("ok", false)),
		"02:00 前必须能从 SLOW 切回 FAST 倍率。"
	)
	_assert_true(
		ending_clock.advance_real_usec_for_verification(GameClockService.FAST_REAL_USEC_PER_GAME_MINUTE),
		"切回 FAST 后必须能完成最后一个游戏分钟。"
	)
	_assert_equal(ending_clock.get_current_game_tick(), GameClockService.SHIFT_DURATION_TICKS, "动态倍率下 02:00 tick 必须精确。")
	_assert_equal(_rate_ending_signal_count, 1, "动态倍率下 ending_time_reached 仍必须只发送一次。")
	_assert_true(not ending_clock.is_running(), "动态倍率下到达 02:00 后时钟仍必须停止。")
	_cleanup_clock(ending_clock)


func _on_ending_time_reached(_end_tick: int) -> void:
	_ending_signal_count += 1
	_signal_order.append("ending")


func _on_rate_ending_time_reached(_end_tick: int) -> void:
	_rate_ending_signal_count += 1


func _on_game_time_advanced(_previous_tick: int, current_tick: int) -> void:
	if current_tick == _shift_duration_ticks:
		_signal_order.append("time")


func _on_game_minute_changed(_previous_elapsed_minute: int, _current_elapsed_minute: int) -> void:
	_minute_signal_count += 1


func _on_shift_started(_start_tick: int) -> void:
	_shift_started_count += 1


func _cleanup_clock(clock: Node) -> void:
	if is_instance_valid(clock) and clock.get_parent() != null:
		clock.get_parent().remove_child(clock)
		clock.free()


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][GameClock] %s" % message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])
