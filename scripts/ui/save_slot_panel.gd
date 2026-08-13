class_name SaveSlotPanel
extends Control
## 三槽 UI 只展示摘要并提交意图；读取模式使用“读取记忆”美术，绝不暂停时钟。

signal slot_save_requested(slot_id: String)
signal slot_load_requested(slot_id: String)
## 写入已获确认后才会在渐出完成时发出，避免成功界面提前消失。
signal save_succeeded
signal return_requested

enum Mode { SAVE, LOAD }

const SLOT_IDS: Array[String] = ["slot_1", "slot_2", "slot_3"]
const FADE_SECONDS: float = 0.25

var _mode: Mode = Mode.SAVE
var _can_save: bool = true
var _save_block_reason: String = ""
var _slot_summaries: Dictionary[String, Dictionary] = {}
var _fade_tween: Tween = null
var _is_fading_out: bool = false
var _has_emitted_terminal_intent: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_current_controls()
	_refresh()
	_start_fade_in()


func _exit_tree() -> void:
	_cancel_fade()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and not event.is_echo():
		_on_back_pressed()
		get_viewport().set_input_as_handled()


func set_mode(mode: Mode) -> Dictionary:
	if mode != Mode.SAVE and mode != Mode.LOAD:
		return _make_error("未知存档界面模式。")
	if _mode == mode:
		return {"ok": true}
	_mode = mode
	if is_node_ready():
		_connect_current_controls()
		_refresh()
	return {"ok": true}


func get_mode() -> Mode:
	return _mode


func set_slot_summaries(summaries: Array[Dictionary]) -> Dictionary:
	var next_summaries: Dictionary[String, Dictionary] = {}
	for summary: Dictionary in summaries:
		var slot_id: String = String(summary.get("slot_id", ""))
		if not SLOT_IDS.has(slot_id):
			return _make_error("槽位摘要包含未知槽位：%s。" % slot_id)
		next_summaries[slot_id] = summary.duplicate(true)
	_slot_summaries = next_summaries
	_refresh_if_ready()
	return {"ok": true}


func set_save_availability(can_save: bool, reason: String = "") -> Dictionary:
	if not can_save and reason.strip_edges().is_empty():
		return _make_error("禁用保存时必须提供中文原因。")
	_can_save = can_save
	_save_block_reason = reason
	_refresh_if_ready()
	return {"ok": true}


func show_message(message: String, is_error: bool = true) -> void:
	if not is_node_ready():
		return
	var label: Label = _message_label()
	label.text = message
	label.modulate = Color(1.0, 0.70, 0.64, 1.0) if is_error else Color(0.65, 0.92, 0.80, 1.0)
	label.visible = not message.strip_edges().is_empty()


## Main 完成真实落盘后调用。失败留在当前页面显示错误；成功才开始渐出。
func handle_save_result(result: Dictionary) -> Dictionary:
	if _mode != Mode.SAVE:
		return _make_error("读取模式不能接收保存结果。")
	if not bool(result.get("ok", false)):
		show_message("保存失败：%s" % String(result.get("message", "未知原因。")))
		return {"ok": false, "panel_remains_open": true}
	show_message("保存完成，正在返回控制栏。", false)
	# 只有真实落盘成功才关闭页面并起声，避免失败点击伪造成功反馈。
	_play_button_click()
	_begin_fade_out("save_success", "")
	return {"ok": true, "is_fading_out": true}


func get_fade_snapshot() -> Dictionary:
	return {"ok": true, "fade_seconds": FADE_SECONDS, "is_fading_out": _is_fading_out, "mode": _mode}


func finish_fade_for_verification() -> Dictionary:
	if not _is_fading_out:
		return {"ok": true, "already_idle": true}
	_cancel_fade()
	_complete_terminal_intent()
	return {"ok": true}


func _connect_current_controls() -> void:
	for slot_id: String in SLOT_IDS:
		var button: Button = _slot_button(slot_id)
		var callback: Callable = _on_slot_pressed.bind(slot_id)
		if not button.is_connected(&"pressed", callback):
			button.pressed.connect(callback)
	var back_callback: Callable = _on_back_pressed
	var back: Button = _back_button()
	if not back.is_connected(&"pressed", back_callback):
		back.pressed.connect(back_callback)


func _on_slot_pressed(slot_id: String) -> void:
	if _is_fading_out or _has_emitted_terminal_intent:
		return
	if _mode == Mode.SAVE:
		if not _can_save:
			show_message("当前不能保存：%s" % _save_block_reason)
			return
		slot_save_requested.emit(slot_id)
		return
	var summary: Dictionary = _slot_summaries.get(slot_id, {}) as Dictionary
	if not bool(summary.get("is_valid", false)):
		show_message("该槽位不可读取：%s" % String(summary.get("message", "空槽位或存档损坏。")))
		return
	# 读取有效槽位会在渐出后替换界面；无效槽位保持当前页面且不发声。
	_play_button_click()
	_begin_fade_out("load", slot_id)


func _on_back_pressed() -> void:
	if _is_fading_out or _has_emitted_terminal_intent:
		return
	# 保存模式的写槽不关闭页面，但两个模式的正常返回都必须完成相同的渐出。
	_play_button_click()
	_begin_fade_out("return", "")


func _begin_fade_out(intent: String, slot_id: String) -> void:
	_is_fading_out = true
	set_meta("terminal_intent", intent)
	set_meta("terminal_slot_id", slot_id)
	_cancel_fade()
	_is_fading_out = true
	_fade_tween = create_tween()
	_fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(self, "modulate:a", 0.0, FADE_SECONDS)
	_fade_tween.tween_callback(_complete_terminal_intent)


func _start_fade_in() -> void:
	modulate.a = 0.0
	_fade_tween = create_tween()
	_fade_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	_fade_tween.tween_property(self, "modulate:a", 1.0, FADE_SECONDS)


func _cancel_fade() -> void:
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null


func _complete_terminal_intent() -> void:
	if _has_emitted_terminal_intent:
		return
	_has_emitted_terminal_intent = true
	_is_fading_out = false
	var intent: String = String(get_meta("terminal_intent", ""))
	if intent == "load":
		slot_load_requested.emit(String(get_meta("terminal_slot_id", "")))
	elif intent == "save_success":
		save_succeeded.emit()
	elif intent == "return":
		return_requested.emit()


func _refresh_if_ready() -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	var is_load: bool = _mode == Mode.LOAD
	$LoadMemory/ModeTitleLabel.visible = not is_load
	$LoadMemory/ModeHintLabel.visible = not is_load
	$LoadMemory/BackButton.visible = not is_load
	$LoadMemory/ModeTitleLabel.text = "保存班次"
	$LoadMemory/ModeHintLabel.text = _get_hint_text()
	$LoadMemory/BackButton/BackLabel.text = "返回值班\nEsc"
	_back_button().tooltip_text = "返回班次控制栏"
	for slot_id: String in SLOT_IDS:
		var summary: Dictionary = _slot_summaries.get(slot_id, _make_empty_summary(slot_id)) as Dictionary
		var button: Button = _slot_button(slot_id)
		var label: Label = _slot_label(slot_id)
		label.text = _format_summary(slot_id, summary, is_load)
		if _mode == Mode.SAVE:
			button.disabled = not _can_save
			button.tooltip_text = "不可保存：%s" % _save_block_reason if not _can_save else "保存至%s；已有记录将覆盖。" % _slot_title(slot_id)
		else:
			button.disabled = not bool(summary.get("is_valid", false))
			button.tooltip_text = "不可读取：%s" % String(summary.get("message", "空槽位。")) if button.disabled else "读取%s。" % _slot_title(slot_id)
	if _mode == Mode.SAVE and not _can_save:
		show_message("当前不能保存：%s" % _save_block_reason)


func _slot_button(slot_id: String) -> Button:
	return get_node("LoadMemory/%sButton" % _slot_node_name(slot_id)) as Button


func _slot_label(slot_id: String) -> Label:
	return get_node("LoadMemory/%sButton/%sLabel" % [_slot_node_name(slot_id), _slot_node_name(slot_id)]) as Label


func _back_button() -> Button:
	return $LoadMemory/BackButton


func _message_label() -> Label:
	return $LoadMemory/MessageLabel


## 保存页返回按钮和读取页 Esc 均使用持久化 UI 声道，避免渐出/换页截断音效。
func _play_button_click() -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	if player == null or not player.has_method(&"play_button_click"):
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，存档返回点击音未播放。")
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] 存档返回点击音播放失败：%s" % str(result))


func _slot_node_name(slot_id: String) -> String:
	return "Slot%d" % (SLOT_IDS.find(slot_id) + 1)


func _get_hint_text() -> String:
	return "保存不会暂停故事时间。当前不可保存：%s" % _save_block_reason if not _can_save else "保存不会暂停故事时间。电话响铃时可以保存；通话或对话选择期间不能保存。"


func _format_summary(slot_id: String, summary: Dictionary, is_load: bool) -> String:
	if not bool(summary.get("exists", false)):
		return "%s\n%s" % [_slot_title(slot_id), "空槽位（不可读取）" if is_load else "保存至槽位（新记录）"]
	if not bool(summary.get("is_valid", false)):
		return "%s\n损坏或不兼容\n%s" % [_slot_title(slot_id), String(summary.get("message", "无法读取。"))] if is_load else "%s\n覆盖槽位\n旧存档损坏，仍可写入。" % _slot_title(slot_id)
	var action: String = "读取" if is_load else "覆盖槽位"
	return "%s\n%s：%s\n游戏时刻 %s" % [_slot_title(slot_id), action, String(summary.get("saved_at_utc", "未知时间")), String(summary.get("display_time", "时刻未知"))]


func _make_empty_summary(slot_id: String) -> Dictionary:
	return {"slot_id": slot_id, "exists": false, "is_valid": false, "message": "空槽位"}


func _slot_title(slot_id: String) -> String:
	return "槽位 %d" % (SLOT_IDS.find(slot_id) + 1)


func _make_error(message: String) -> Dictionary:
	push_error("[存档界面][save_slot_panel_error] %s" % message)
	return {"ok": false, "message": message}
