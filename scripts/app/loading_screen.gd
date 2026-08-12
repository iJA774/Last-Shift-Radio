class_name LoadingScreen
extends Control
## 新夜班的纯视觉过渡。运行时与 GameClock 只能在它完整渐出后由 Main 创建。

signal transition_finished

const FADE_IN_SECONDS: float = 0.5
const HOLD_SECONDS: float = 2.0
const FADE_OUT_SECONDS: float = 0.5

var _transition_tween: Tween = null
var _is_transition_running: bool = false
var _is_finished: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	modulate.a = 0.0
	_start_transition()


func _exit_tree() -> void:
	_cancel_transition()


func get_timing_snapshot() -> Dictionary:
	return {
		"ok": true,
		"fade_in_seconds": FADE_IN_SECONDS,
		"hold_seconds": HOLD_SECONDS,
		"fade_out_seconds": FADE_OUT_SECONDS,
		"is_running": _is_transition_running,
		"is_finished": _is_finished,
	}


## 仅用于确定性测试；真实流程始终经过上述 0.5 / 2.0 / 0.5 秒序列。
func finish_for_verification() -> Dictionary:
	if _is_finished:
		return {"ok": true, "already_finished": true}
	_cancel_transition()
	modulate.a = 0.0
	_finish_transition()
	return {"ok": true, "verification_finished": true}


func _start_transition() -> void:
	_cancel_transition()
	_is_transition_running = true
	_transition_tween = create_tween()
	_transition_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_transition_tween.tween_property(self, "modulate:a", 1.0, FADE_IN_SECONDS)
	_transition_tween.tween_interval(HOLD_SECONDS)
	_transition_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT_SECONDS)
	_transition_tween.tween_callback(_finish_transition)


func _cancel_transition() -> void:
	if _transition_tween != null and _transition_tween.is_valid():
		_transition_tween.kill()
	_transition_tween = null
	_is_transition_running = false


func _finish_transition() -> void:
	if _is_finished:
		return
	_transition_tween = null
	_is_transition_running = false
	_is_finished = true
	transition_finished.emit()
