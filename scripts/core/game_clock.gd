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

## Idle 下 3 现实秒对应 1 游戏分钟；Active 下时间与现实一致，60 现实秒对应
## 1 游戏分钟。SLOW 是相对快进倍率的内部名称；UI 只能通过公开方法修改倍率。
enum TimeRate {
	FAST,
	SLOW,
	PAUSED,
}

const FAST_REAL_USEC_PER_GAME_MINUTE: int = 3 * 1_000_000
const SLOW_REAL_USEC_PER_GAME_MINUTE: int = 60 * 1_000_000

## 两种分钟倍率的公倍母。分数 tick 以此为单位保存，因此切换倍率时可以保留
## 已经换算但尚不足一个完整 tick 的游戏进度，不把旧倍率的真实微秒错误地带入
## 新倍率。
const TICK_PROGRESS_UNITS_PER_TICK: int = SLOW_REAL_USEC_PER_GAME_MINUTE
const SNAPSHOT_VERSION: int = 1
const SNAPSHOT_SYSTEM_ID: String = "game_clock"

var _current_game_tick: int = 0
var _pending_tick_progress_units: int = 0
var _last_wall_clock_usec: int = 0
var _is_running: bool = false
var _is_ending_emitted: bool = false
var _time_rate: TimeRate = TimeRate.FAST
## 延后恢复仅用于让 Main 先完成 StoryEngine 等运行时绑定；不能让加载耗时
## 计入游戏时间，也绝不能再次发送 shift_started。
var _restored_running_pending: bool = false


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
	_restored_running_pending = false
	_set_time_rate_mode_internal(TimeRate.FAST, false)
	_last_wall_clock_usec = Time.get_ticks_usec()
	print("[01:00][时钟] 已为新夜班准备起点，尚未启动。")
	return {"ok": true, "game_tick": _current_game_tick}


func start_shift() -> void:
	_current_game_tick = 0
	_pending_tick_progress_units = 0
	_is_ending_emitted = false
	_is_running = true
	_restored_running_pending = false
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


## 应用壳销毁一局运行时时调用：只停止真实时间累计并重置 wall-clock 基准，
## 不重置任何可存档状态，也不发送剧情、时间或收束信号。读取存档前 Main 必须
## 先让旧局停止，避免旧运行时在槽位界面或重建期间继续推进。
func stop_for_runtime_disposal() -> Dictionary:
	_is_running = false
	_restored_running_pending = false
	_last_wall_clock_usec = Time.get_ticks_usec()
	return {"ok": true, "stopped_game_tick": _current_game_tick}


## 返回仅包含 JSON 标准类型的时钟运行时快照。
func create_snapshot() -> Dictionary:
	return {
		"snapshot_version": SNAPSHOT_VERSION,
		"system_id": SNAPSHOT_SYSTEM_ID,
		"current_game_tick": _current_game_tick,
		"pending_tick_progress_units": _pending_tick_progress_units,
		"is_running": _is_running,
		"ending_emitted": _is_ending_emitted,
		"time_rate": int(_time_rate),
	}


## 严格校验时钟快照。JSON 读取器可把整数解析为无小数 float，因此只接受
## 数学上精确的整数数值；其他字段必须保持精确 JSON 类型。
func validate_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	if not _has_exact_snapshot_fields(
		snapshot,
		PackedStringArray([
			"snapshot_version",
			"system_id",
			"current_game_tick",
			"pending_tick_progress_units",
			"is_running",
			"ending_emitted",
			"time_rate",
		])
	):
		return _make_snapshot_error("invalid_fields", "时钟快照字段缺失或包含未知字段。")
	var version_result: Dictionary = _read_snapshot_integer(snapshot, "snapshot_version", SNAPSHOT_VERSION, SNAPSHOT_VERSION)
	if not bool(version_result["ok"]):
		return version_result
	if typeof(snapshot["system_id"]) != TYPE_STRING or String(snapshot["system_id"]) != SNAPSHOT_SYSTEM_ID:
		return _make_snapshot_error("invalid_system_id", "时钟快照 system_id 必须为 game_clock。")
	var tick_result: Dictionary = _read_snapshot_integer(snapshot, "current_game_tick", 0, SHIFT_DURATION_TICKS)
	if not bool(tick_result["ok"]):
		return tick_result
	var pending_result: Dictionary = _read_snapshot_integer(
		snapshot,
		"pending_tick_progress_units",
		0,
		TICK_PROGRESS_UNITS_PER_TICK - 1
	)
	if not bool(pending_result["ok"]):
		return pending_result
	var rate_result: Dictionary = _read_snapshot_integer(snapshot, "time_rate", int(TimeRate.FAST), int(TimeRate.PAUSED))
	if not bool(rate_result["ok"]):
		return rate_result
	if typeof(snapshot["is_running"]) != TYPE_BOOL:
		return _make_snapshot_error("invalid_is_running", "时钟快照 is_running 必须是布尔值。")
	if typeof(snapshot["ending_emitted"]) != TYPE_BOOL:
		return _make_snapshot_error("invalid_ending_emitted", "时钟快照 ending_emitted 必须是布尔值。")
	if not _validate_restore_context(context):
		return _make_snapshot_error("invalid_context", "时钟恢复上下文 defer_running 必须是布尔值。")

	var current_tick: int = int(tick_result["value"])
	var pending_units: int = int(pending_result["value"])
	var is_running_snapshot: bool = bool(snapshot["is_running"])
	var ending_emitted: bool = bool(snapshot["ending_emitted"])
	if ending_emitted:
		if current_tick != SHIFT_DURATION_TICKS or is_running_snapshot or pending_units != 0:
			return _make_snapshot_error("invalid_ending_state", "02:00 时钟快照必须停止、位于 3600 tick 且没有未满 tick 进度。")
	elif current_tick >= SHIFT_DURATION_TICKS:
		return _make_snapshot_error("invalid_end_tick_state", "到达 02:00 的时钟快照必须标记 ending_emitted。")
	elif not is_running_snapshot and (current_tick != 0 or pending_units != 0):
		return _make_snapshot_error("invalid_stopped_state", "未收束的停止时钟只能是 01:00 的新班次预备状态。")

	return {
		"ok": true,
		"normalized_snapshot": {
			"snapshot_version": SNAPSHOT_VERSION,
			"system_id": SNAPSHOT_SYSTEM_ID,
			"current_game_tick": current_tick,
			"pending_tick_progress_units": pending_units,
			"is_running": is_running_snapshot,
			"ending_emitted": ending_emitted,
			"time_rate": int(rate_result["value"]),
		},
	}


## 校验成功后一次性替换时钟状态。恢复过程不发出 shift_started、时间推进或
## 收束信号；恢复完成时重置 wall-clock 基准，加载耗时不会被折算进夜班时间。
## context.defer_running=true 时调用方必须在全部运行时恢复并绑定完成后调用
## resume_restored_clock()。
func restore_snapshot(snapshot: Dictionary, context: Dictionary = {}) -> Dictionary:
	var validation: Dictionary = validate_snapshot(snapshot, context)
	if not bool(validation["ok"]):
		return validation
	var normalized: Dictionary = validation["normalized_snapshot"] as Dictionary
	var snapshot_running: bool = bool(normalized["is_running"])
	var defer_running: bool = bool(context.get("defer_running", false))
	_current_game_tick = int(normalized["current_game_tick"])
	_pending_tick_progress_units = int(normalized["pending_tick_progress_units"])
	_time_rate = int(normalized["time_rate"])
	_is_ending_emitted = bool(normalized["ending_emitted"])
	_restored_running_pending = snapshot_running and defer_running
	_is_running = snapshot_running and not defer_running
	_last_wall_clock_usec = Time.get_ticks_usec()
	return {
		"ok": true,
		"restored_game_tick": _current_game_tick,
		"resume_required": _restored_running_pending,
	}


## 只用于 defer_running 恢复路径。它不是新夜班开始，因此不发送任何剧情信号。
func resume_restored_clock() -> Dictionary:
	if not _restored_running_pending:
		return _make_snapshot_error("resume_not_required", "当前时钟没有等待恢复的运行状态。")
	if _is_ending_emitted or _current_game_tick >= SHIFT_DURATION_TICKS:
		return _make_snapshot_error("resume_after_ending", "02:00 后不能恢复运行时钟。")
	_is_running = true
	_restored_running_pending = false
	_last_wall_clock_usec = Time.get_ticks_usec()
	return {"ok": true, "resumed": true}


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
	if _time_rate == TimeRate.PAUSED:
		_last_wall_clock_usec = Time.get_ticks_usec()
		return
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
	if elapsed_usec <= 0 or not _is_running or _time_rate == TimeRate.PAUSED:
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
		TimeRate.PAUSED:
			return 0
	push_error("[时钟][invalid_time_rate_internal] 未知时间倍率：%d。" % int(time_rate))
	return 0


func _is_valid_time_rate(time_rate: int) -> bool:
	return time_rate == TimeRate.FAST or time_rate == TimeRate.SLOW or time_rate == TimeRate.PAUSED


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


func _has_exact_snapshot_fields(snapshot: Dictionary, required_fields: PackedStringArray) -> bool:
	if snapshot.size() != required_fields.size():
		return false
	for field_name: String in required_fields:
		if not snapshot.has(field_name):
			return false
	return true


func _read_snapshot_integer(snapshot: Dictionary, field_name: String, minimum: int, maximum: int) -> Dictionary:
	if not snapshot.has(field_name):
		return _make_snapshot_error("missing_%s" % field_name, "时钟快照缺少字段 %s。" % field_name)
	var raw_value: Variant = snapshot[field_name]
	if typeof(raw_value) != TYPE_INT and typeof(raw_value) != TYPE_FLOAT:
		return _make_snapshot_error("invalid_%s" % field_name, "时钟快照字段 %s 必须是整数。" % field_name)
	var numeric_value: float = float(raw_value)
	if not is_finite(numeric_value) or floor(numeric_value) != numeric_value:
		return _make_snapshot_error("invalid_%s" % field_name, "时钟快照字段 %s 必须是有限整数。" % field_name)
	var integer_value: int = int(numeric_value)
	if integer_value < minimum or integer_value > maximum:
		return _make_snapshot_error(
			"out_of_range_%s" % field_name,
			"时钟快照字段 %s 必须在 %d 到 %d 之间。" % [field_name, minimum, maximum]
		)
	return {"ok": true, "value": integer_value}


func _validate_restore_context(context: Dictionary) -> bool:
	if context.has("defer_running") and typeof(context["defer_running"]) != TYPE_BOOL:
		return false
	return true


func _make_snapshot_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
