class_name SaveSlotPanel
extends Control
## 复用的三槽覆盖层；自身不暂停 SceneTree 或 GameClock。
##
## 保存/读取、文件写入及运行时恢复都由 Main 完成。本控件只展示槽位摘要、
## 明确禁用原因并发出玩家选择意图。

signal slot_save_requested(slot_id: String)
signal slot_load_requested(slot_id: String)
signal return_requested

enum Mode {
	SAVE,
	LOAD,
}

const SLOT_IDS: Array[String] = ["slot_1", "slot_2", "slot_3"]

var _mode: Mode = Mode.SAVE
var _can_save: bool = true
var _save_block_reason: String = ""
var _slot_summaries: Dictionary[String, Dictionary] = {}

@onready var _title_label: Label = %TitleLabel
@onready var _hint_label: Label = %HintLabel
@onready var _message_label: Label = %MessageLabel
@onready var _slot_buttons: Dictionary[String, Button] = {
	"slot_1": %Slot1Button,
	"slot_2": %Slot2Button,
	"slot_3": %Slot3Button,
}
@onready var _slot_labels: Dictionary[String, Label] = {
	"slot_1": %Slot1Label,
	"slot_2": %Slot2Label,
	"slot_3": %Slot3Label,
}


func _ready() -> void:
	for slot_id: String in SLOT_IDS:
		var button: Button = _slot_buttons[slot_id]
		button.pressed.connect(_on_slot_pressed.bind(slot_id))
	%BackButton.pressed.connect(_on_back_pressed)
	_refresh()


func set_mode(mode: Mode) -> Dictionary:
	if mode != Mode.SAVE and mode != Mode.LOAD:
		return _make_error("未知存档界面模式。")
	_mode = mode
	_refresh_if_ready()
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
	_message_label.text = message
	_message_label.modulate = Color(1.0, 0.70, 0.64, 1.0) if is_error else Color(0.65, 0.92, 0.80, 1.0)
	_message_label.visible = not message.strip_edges().is_empty()


func _on_slot_pressed(slot_id: String) -> void:
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
	slot_load_requested.emit(slot_id)


func _on_back_pressed() -> void:
	return_requested.emit()


func _refresh_if_ready() -> void:
	if is_node_ready():
		_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	_title_label.text = "保存班次" if _mode == Mode.SAVE else "读取存档"
	_hint_label.text = _get_hint_text()
	for slot_id: String in SLOT_IDS:
		var summary: Dictionary = _slot_summaries.get(slot_id, _make_empty_summary(slot_id)) as Dictionary
		var button: Button = _slot_buttons[slot_id]
		var label: Label = _slot_labels[slot_id]
		label.text = _format_summary(slot_id, summary)
		if _mode == Mode.SAVE:
			button.disabled = not _can_save
			button.tooltip_text = "不可保存：%s" % _save_block_reason if not _can_save else "保存到%s。" % _slot_title(slot_id)
		else:
			button.disabled = not bool(summary.get("is_valid", false))
			button.tooltip_text = "不可读取：%s" % String(summary.get("message", "空槽位。")) if button.disabled else "读取%s。" % _slot_title(slot_id)
	if _mode == Mode.SAVE and not _can_save:
		show_message("当前不能保存：%s" % _save_block_reason)


func _get_hint_text() -> String:
	if _mode == Mode.SAVE:
		if _can_save:
			return "保存不会暂停故事时间。电话响铃时可以保存；通话或对话选择期间不能保存。"
		return "保存不会暂停故事时间。当前不可保存：%s" % _save_block_reason
	return "只读取已通过完整校验的本地 JSON 存档。损坏或不兼容的槽位会被拒绝。"


func _format_summary(slot_id: String, summary: Dictionary) -> String:
	if not bool(summary.get("exists", false)):
		return "%s\n空槽位" % _slot_title(slot_id)
	if not bool(summary.get("is_valid", false)):
		return "%s\n损坏或不兼容\n%s" % [_slot_title(slot_id), String(summary.get("message", "无法读取。"))]
	return "%s\n保存于 %s\n游戏时刻 %s" % [
		_slot_title(slot_id),
		String(summary.get("saved_at_utc", "未知时间")),
		String(summary.get("display_time", "时刻未知")),
	]


func _make_empty_summary(slot_id: String) -> Dictionary:
	return {"slot_id": slot_id, "exists": false, "is_valid": false, "message": "空槽位"}


func _slot_title(slot_id: String) -> String:
	return "槽位 %d" % (SLOT_IDS.find(slot_id) + 1)


func _make_error(message: String) -> Dictionary:
	push_error("[存档界面][save_slot_panel_error] %s" % message)
	return {"ok": false, "message": message}
