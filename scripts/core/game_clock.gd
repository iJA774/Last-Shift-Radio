class_name GameClockService
extends Node
## 夜班游戏时钟的唯一时间来源。
##
## 剧情判断只读取整数 game_tick：一个游戏内分钟有 60 个 tick，01:00 至
## 02:00 共 3,600 tick。现实耗时仅用于换算新增 tick，绝不直接参与关键时间比较。
##
## 游戏界面根据派生的 Idle / Active 工作状态选择倍率；本时钟只接受已经
## 决定好的倍率，不读取 UI、电话或广播状态，避免产生第二个剧情权威来源。

signal shift_started(start_tick: int)
signal game_time_advanced(previous_tick: int, current_tick: int)
signal game_minute_changed(previous_elapsed_minute: int, current_elapsed_minute: int)
signal ending_time_reached(end_tick: int)
signal time_rate_changed(previous_rate: int, current_rate: int)

const SHIFT_START_HOUR: int = 1
const SHIFT_END_HOUR: int = 2
const GAME_TICKS_PER_MINUTE: int = 60
const SHIFT_DURATION_MINUTES: int = 60
const SHIFT_DURATION_TICKS: int = SHIFT_DURATION_MINUTES * GAME_TICKS_PER_MINUTE

## Idle 下 2 现实秒对应 1 游戏分钟；Active 下时间与现实一致，60 现实秒对应
## 1 游戏分钟。SLOW 是相对快进倍率的内部名称；UI 只能通过公开方法修改倍率。
enum TimeRate {
	FAST,
	SLOW,
}

const FAST_REAL_USEC_PER_GAME_MINUTE: int = 2 * 1_000_000
const SLOW_REAL_USEC_PER_GAME_MINUTE: int = 60 * 1_000_000

## 两种分钟倍率的公倍母。分数 tick 以此为单位保存，因此切换倍率时可以保留
## 已经换算但尚不足一个完整 tick 的游戏进度，不把旧倍率的真实微秒错误地带入
## 新倍率。
const TICK_PROGRESS_UNITS_PER_TICK: int = SLOW_REAL_USEC_PER_GAME_MINUTE

var _current_game_tick: int = 0
var _pending_tick_progress_units: int = 0
var _last_wall_clock_usec: int = 0
var _is_running: bool = false
var _is_ending_emitted: bool = false
var _time_rate: TimeRate = TimeRate.FAST


func _ready() -> void:
	# 即使其他应用层界面暂停 SceneTree，本节点仍继续处理真实时间。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_wall_clock_usec = Time.get_ticks_usec()
	set_process(true)


func _process(_delta: float) -> void:
	_consume_wall_clock_elapsed()


## 为下一局准备 01:00 起点，但不启动时钟也不发送 shift_started。
## 仅允许在已停止的局间状态调用，防止应用壳覆盖仍在进行的夜班。
func prepare_new_shift() -> Dictionary:
	if _is_running:
		var message: String = "时钟仍在运行，不能为新夜班重置起点。"
		push_error("[时钟][prepare_new_shift_while_running] %s" % message)
		return {"ok": false, "error_code": "clock_running", "message": message}
	_current_game_tick = 0
	_pending_tick_progress_units = 0
	_is_ending_emitted = false
	_set_time_rate_mode_internal(TimeRate.FAST, false)
	_last_wall_clock_usec = Time.get_ticks_usec()
	print("[01:00][时钟] 已为新夜班准备起点，尚未启动。")
	return {"ok": true, "game_tick": _current_game_tick}


func start_shift() -> void:
	_current_game_tick = 0
	_pending_tick_progress_units = 0
	_is_ending_emitted = false
	_is_running = true
	_last_wall_clock_usec = Time.get_ticks_usec()
	print("[01:00][时钟] 夜班计时已启动，game_tick=0。")
	shift_started.emit(_current_game_tick)


func get_current_game_tick() -> int:
	return _current_game_tick


func get_elapsed_game_minutes() -> int:
	return _current_game_tick / GAME_TICKS_PER_MINUTE


func get_current_hour() -> int:
	var absolute_minutes: int = SHIFT_START_HOUR * 60 + get_elapsed_game_minutes()
	return absolute_minutes / 60


func get_current_minute() -> int:
	var absolute_minutes: int = SHIFT_START_HOUR * 60 + get_elapsed_game_minutes()
	return absolute_minutes % 60


func get_display_time() -> String:
	return "%02d:%02d" % [get_current_hour(), get_current_minute()]


func get_remaining_game_ticks() -> int:
	return SHIFT_DURATION_TICKS - _current_game_tick


func get_shift_duration_ticks() -> int:
	return SHIFT_DURATION_TICKS


func is_running() -> bool:
	return _is_running


func is_shift_ended() -> bool:
	return _is_ending_emitted


## 为运行中的时钟切换公开倍率。先结算切换前已经过去的真实时间，再保留不足
## 一个 tick 的游戏进度，防止 UI 切换视图或电话状态时重复、遗漏时间。
func set_time_rate_mode(time_rate: TimeRate) -> Dictionary:
	return _set_time_rate_mode_internal(time_rate, true)


func get_time_rate_mode() -> TimeRate:
	return _time_rate


func get_time_rate_name() -> String:
	return TimeRate.keys()[_time_rate]


func get_real_usec_per_game_minute() -> int:
	return _get_real_usec_per_game_minute(_time_rate)


func set_time_rate_mode_for_verification(time_rate: TimeRate) -> Dictionary:
	## 仅供项目内自动验证使用。测试通过 advance_real_usec_for_verification()
	## 注入确定性真实耗时，因此不能混入主机时钟的微秒差。
	return _set_time_rate_mode_internal(time_rate, false)


func advance_ticks_for_verification(ticks_to_advance: int) -> bool:
	## 仅供项目内自动验证使用的确定性推进入口；玩家 UI 不得调用此方法。
	if ticks_to_advance <= 0:
		push_error("[时钟] 验证推进必须传入正整数 tick。")
		return false
	if not _is_running:
		push_error("[时钟] 验证推进失败：夜班尚未启动或已经结束。")
		return false

	_advance_by_ticks(ticks_to_advance)
	return true


func advance_real_usec_for_verification(elapsed_usec: int) -> bool:
	## 仅供项目内自动验证使用的确定性真实时间入口；玩家 UI 不得调用此方法。
	if elapsed_usec <= 0:
		push_error("[时钟] 验证真实时间推进必须传入正整数微秒。")
		return false
	if not _is_running:
		push_error("[时钟] 验证真实时间推进失败：夜班尚未启动或已经结束。")
		return false
	_accumulate_real_usec(elapsed_usec)
	return true


func _set_time_rate_mode_internal(time_rate: TimeRate, synchronize_wall_clock: bool) -> Dictionary:
	if not _is_valid_time_rate(time_rate):
		var message: String = "未知时间倍率：%d。" % int(time_rate)
		push_error("[时钟][invalid_time_rate] %s" % message)
		return {"ok": false, "error_code": "invalid_time_rate", "message": message}
	if synchronize_wall_clock:
		_consume_wall_clock_elapsed()
	var previous_rate: TimeRate = _time_rate
	_time_rate = time_rate
	if previous_rate != _time_rate:
		print("[%s][时钟] 时间倍率 %s -> %s。" % [get_display_time(), TimeRate.keys()[previous_rate], TimeRate.keys()[_time_rate]])
		time_rate_changed.emit(previous_rate, _time_rate)
	return {
		"ok": true,
		"previous_rate": previous_rate,
		"time_rate": _time_rate,
		"real_usec_per_game_minute": get_real_usec_per_game_minute(),
	}


func _consume_wall_clock_elapsed() -> void:
	var now_usec: int = Time.get_ticks_usec()
	if _last_wall_clock_usec == 0:
		_last_wall_clock_usec = now_usec
		return

	var elapsed_usec: int = now_usec - _last_wall_clock_usec
	_last_wall_clock_usec = now_usec
	if elapsed_usec < 0:
		push_error("[时钟] 单调时钟倒退，已忽略本帧的负增量。")
		return
	if not _is_running or elapsed_usec == 0:
		return
	_accumulate_real_usec(elapsed_usec)


func _accumulate_real_usec(elapsed_usec: int) -> void:
	if elapsed_usec <= 0 or not _is_running:
		return
	var real_usec_per_game_minute: int = _get_real_usec_per_game_minute(_time_rate)
	var multiplier: int = SLOW_REAL_USEC_PER_GAME_MINUTE / real_usec_per_game_minute
	_pending_tick_progress_units += elapsed_usec * GAME_TICKS_PER_MINUTE * multiplier
	var ticks_to_advance: int = _pending_tick_progress_units / TICK_PROGRESS_UNITS_PER_TICK
	if ticks_to_advance <= 0:
		return
	_pending_tick_progress_units -= ticks_to_advance * TICK_PROGRESS_UNITS_PER_TICK
	_advance_by_ticks(ticks_to_advance)
	if _is_ending_emitted:
		_pending_tick_progress_units = 0


func _get_real_usec_per_game_minute(time_rate: TimeRate) -> int:
	match time_rate:
		TimeRate.FAST:
			return FAST_REAL_USEC_PER_GAME_MINUTE
		TimeRate.SLOW:
			return SLOW_REAL_USEC_PER_GAME_MINUTE
	push_error("[时钟][invalid_time_rate_internal] 未知时间倍率：%d。" % int(time_rate))
	return 0


func _is_valid_time_rate(time_rate: int) -> bool:
	return time_rate == TimeRate.FAST or time_rate == TimeRate.SLOW


func _advance_by_ticks(ticks_to_advance: int) -> void:
	if ticks_to_advance <= 0 or not _is_running:
		return

	var previous_tick: int = _current_game_tick
	var target_tick: int = mini(previous_tick + ticks_to_advance, SHIFT_DURATION_TICKS)
	_current_game_tick = target_tick

	# 收束信号必须先于普通时间推进通知，确保订阅者先清空电话和事件队列。
	if target_tick >= SHIFT_DURATION_TICKS and not _is_ending_emitted:
		_is_ending_emitted = true
		_is_running = false
		print("[02:00][时钟] 已到达收束时间，发送 ending_time_reached。")
		ending_time_reached.emit(SHIFT_DURATION_TICKS)

	game_time_advanced.emit(previous_tick, target_tick)
	_emit_crossed_minutes(previous_tick, target_tick)


func _emit_crossed_minutes(previous_tick: int, current_tick: int) -> void:
	var previous_elapsed_minute: int = previous_tick / GAME_TICKS_PER_MINUTE
	var current_elapsed_minute: int = current_tick / GAME_TICKS_PER_MINUTE
	for elapsed_minute: int in range(previous_elapsed_minute + 1, current_elapsed_minute + 1):
		game_minute_changed.emit(elapsed_minute - 1, elapsed_minute)
