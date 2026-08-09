class_name GameClockService
extends Node
## 夜班游戏时钟的唯一时间来源。
##
## 剧情判断只读取整数 game_tick：一个游戏内分钟有 60 个 tick，01:00 至
## 02:00 共 3,600 tick。现实耗时仅用于换算新增 tick，绝不直接参与关键时间比较。

signal shift_started(start_tick: int)
signal game_time_advanced(previous_tick: int, current_tick: int)
signal game_minute_changed(previous_elapsed_minute: int, current_elapsed_minute: int)
signal ending_time_reached(end_tick: int)

const SHIFT_START_HOUR: int = 1
const SHIFT_END_HOUR: int = 2
const GAME_TICKS_PER_MINUTE: int = 60
const SHIFT_DURATION_MINUTES: int = 60
const SHIFT_DURATION_TICKS: int = SHIFT_DURATION_MINUTES * GAME_TICKS_PER_MINUTE
const REAL_USEC_PER_GAME_MINUTE: int = 30 * 1_000_000
const REAL_USEC_PER_GAME_TICK: int = REAL_USEC_PER_GAME_MINUTE / GAME_TICKS_PER_MINUTE

var _current_game_tick: int = 0
var _pending_real_usec: int = 0
var _last_wall_clock_usec: int = 0
var _is_running: bool = false
var _is_ending_emitted: bool = false


func _ready() -> void:
	# 即使其他应用层界面暂停 SceneTree，本节点仍继续处理真实时间。
	process_mode = Node.PROCESS_MODE_ALWAYS
	_last_wall_clock_usec = Time.get_ticks_usec()
	set_process(true)


func _process(_delta: float) -> void:
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

	_pending_real_usec += elapsed_usec
	var ticks_to_advance: int = _pending_real_usec / REAL_USEC_PER_GAME_TICK
	if ticks_to_advance <= 0:
		return

	_pending_real_usec -= ticks_to_advance * REAL_USEC_PER_GAME_TICK
	_advance_by_ticks(ticks_to_advance)


## 为下一局准备 01:00 起点，但不启动时钟也不发送 shift_started。
## 仅允许在已停止的局间状态调用，防止应用壳覆盖仍在进行的夜班。
func prepare_new_shift() -> Dictionary:
	if _is_running:
		var message: String = "时钟仍在运行，不能为新夜班重置起点。"
		push_error("[时钟][prepare_new_shift_while_running] %s" % message)
		return {"ok": false, "error_code": "clock_running", "message": message}
	_current_game_tick = 0
	_pending_real_usec = 0
	_is_ending_emitted = false
	_last_wall_clock_usec = Time.get_ticks_usec()
	print("[01:00][时钟] 已为新夜班准备起点，尚未启动。")
	return {"ok": true, "game_tick": _current_game_tick}


func start_shift() -> void:
	_current_game_tick = 0
	_pending_real_usec = 0
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
