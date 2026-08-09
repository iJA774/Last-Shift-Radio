class_name ComputerCallLogView
extends PanelContainer
## 电脑中的来电记录页。
##
## 本控件只读取 PhoneSystem 已生成的记录，并读取 StoryEngine 提供的收束播出记录。
## 它不创建、修改或推断任何剧情状态。

var _phone_system: RefCounted = null
var _unauthorized_broadcast: Dictionary = {}
var _summary_label: Label = Label.new()
var _broadcast_label: Label = Label.new()
var _records_box: VBoxContainer = VBoxContainer.new()
var _is_phone_connected: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()
	_connect_phone_system_if_possible()
	_refresh()


func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("电话系统实例不能为空。")
	if not phone_system.has_signal(&"call_record_created") or not phone_system.has_method(&"get_call_records"):
		return _make_error("电话系统缺少来电记录展示所需的公开接口。")
	_disconnect_phone_system()
	_phone_system = phone_system
	_connect_phone_system_if_possible()
	_refresh()
	return {"ok": true}


func show_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	var validation: Dictionary = _validate_broadcast_record(record)
	if not bool(validation["ok"]):
		return validation
	# 仅保留展示快照；权威记录仍由 StoryEngine 持有。
	_unauthorized_broadcast = record.duplicate(true)
	_refresh()
	return {"ok": true}


func _exit_tree() -> void:
	_disconnect_phone_system()


func _build_interface() -> void:
	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.offset_left = 24.0
	layout.offset_top = 24.0
	layout.offset_right = -24.0
	layout.offset_bottom = -24.0
	add_child(layout)

	var title: Label = Label.new()
	title.text = "电脑终端 / 来电记录"
	title.add_theme_font_size_override("font_size", 30)
	layout.add_child(title)

	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_font_size_override("font_size", 18)
	layout.add_child(_summary_label)

	var broadcast_panel: PanelContainer = PanelContainer.new()
	broadcast_panel.custom_minimum_size = Vector2(0.0, 104.0)
	layout.add_child(broadcast_panel)
	_broadcast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_broadcast_label.add_theme_font_size_override("font_size", 20)
	_broadcast_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_broadcast_label.offset_left = 16.0
	_broadcast_label.offset_top = 12.0
	_broadcast_label.offset_right = -16.0
	_broadcast_label.offset_bottom = -12.0
	broadcast_panel.add_child(_broadcast_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	_records_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_records_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_records_box)


func _connect_phone_system_if_possible() -> void:
	if _phone_system == null or not is_node_ready() or _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_call_record_created")
	var result: Error = _phone_system.connect(&"call_record_created", callback)
	if result != OK:
		push_error("[电脑][call_record_connect_failed] 无法连接 PhoneSystem.call_record_created，错误码=%d。" % result)
		return
	_is_phone_connected = true


func _disconnect_phone_system() -> void:
	if _phone_system == null or not _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_call_record_created")
	if _phone_system.is_connected(&"call_record_created", callback):
		_phone_system.disconnect(&"call_record_created", callback)
	_is_phone_connected = false


func _on_call_record_created(_record: Dictionary) -> void:
	# PhoneSystem 已在其内部写入权威记录；此处只请求刷新。
	_refresh()


func _refresh() -> void:
	if not is_node_ready():
		return
	_refresh_broadcast()
	_refresh_call_records()


func _refresh_broadcast() -> void:
	if _unauthorized_broadcast.is_empty():
		_broadcast_label.text = "播出记录：本阶段尚未出现未授权播出。"
		return
	var time_text: String = _format_game_time(int(_unauthorized_broadcast["time_tick"]))
	_broadcast_label.text = "未授权播出记录\n时间：%s　来源：%s\n%s\n事实 ID：%s" % [
		time_text,
		String(_unauthorized_broadcast["source"]),
		String(_unauthorized_broadcast["body"]),
		String(_unauthorized_broadcast["fact_id"]),
	]


func _refresh_call_records() -> void:
	for child: Node in _records_box.get_children():
		child.queue_free()

	if _phone_system == null:
		_summary_label.text = "来电记录：电话系统尚未连接。"
		return
	var result: Variant = _phone_system.call(&"get_call_records")
	if typeof(result) != TYPE_ARRAY:
		_summary_label.text = "来电记录：电话系统返回的数据类型无效。"
		push_error("[电脑][invalid_call_records] PhoneSystem.get_call_records() 必须返回 Array。")
		return
	var records: Array = result as Array
	_summary_label.text = "来电记录：共 %d 条。所有条目均由电话状态机实际转移生成。" % records.size()
	if records.is_empty():
		var empty_label: Label = Label.new()
		empty_label.text = "暂无记录。接听、主动挂断、漏接或 02:00 中断后会自动写入此处。"
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_records_box.add_child(empty_label)
		return

	for raw_record: Variant in records:
		if not raw_record is Dictionary:
			push_error("[电脑][invalid_call_record] PhoneSystem 返回了非 Dictionary 的来电记录。")
			continue
		_records_box.add_child(_make_record_row(raw_record as Dictionary))


func _make_record_row(record: Dictionary) -> PanelContainer:
	var row: PanelContainer = PanelContainer.new()
	row.custom_minimum_size = Vector2(0.0, 76.0)
	var label: Label = Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	label.offset_left = 12.0
	label.offset_top = 8.0
	label.offset_right = -12.0
	label.offset_bottom = -8.0
	row.add_child(label)

	if not _is_valid_call_record(record):
		label.text = "记录损坏：缺少必要字段，无法展示。"
		return row
	label.text = "%s  %s  %s\n状态：%s　时长：%d tick（游戏内 %d 秒）　事件：%s" % [
		_format_game_time(int(record["time"])),
		String(record["caller_name"]),
		String(record["caller_number"]),
		_format_outcome(String(record["outcome"])),
		int(record["duration_ticks"]),
		int(record["duration_ticks"]),
		String(record["event_id"]),
	]
	return row


func _is_valid_call_record(record: Dictionary) -> bool:
	var required_fields: PackedStringArray = [
		"event_id", "time", "caller_name", "caller_number", "outcome", "duration_ticks",
	]
	for field_name: String in required_fields:
		if not record.has(field_name):
			return false
	return typeof(record["time"]) == TYPE_INT and typeof(record["duration_ticks"]) == TYPE_INT


func _validate_broadcast_record(record: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = ["fact_id", "time_tick", "source", "body"]
	for field_name: String in required_fields:
		if not record.has(field_name):
			return _make_error("未授权播出记录缺少字段：%s。" % field_name)
	if typeof(record["time_tick"]) != TYPE_INT:
		return _make_error("未授权播出记录的 time_tick 必须是整数。")
	for field_name: String in ["fact_id", "source", "body"]:
		if typeof(record[field_name]) != TYPE_STRING or String(record[field_name]).is_empty():
			return _make_error("未授权播出记录的 %s 必须是非空字符串。" % field_name)
	return {"ok": true}


func _format_game_time(game_tick: int) -> String:
	var elapsed_minutes: int = game_tick / 60
	var absolute_minutes: int = 60 + elapsed_minutes
	return "%02d:%02d" % [absolute_minutes / 60, absolute_minutes % 60]


func _format_outcome(outcome: String) -> String:
	match outcome:
		"answered":
			return "已接听"
		"missed":
			return "漏接"
		"hung_up":
			return "主动挂断"
		"forced_end":
			return "02:00 中断"
	return "未知（%s）" % outcome


func _make_error(message: String) -> Dictionary:
	push_error("[电脑][call_log_error] %s" % message)
	return {"ok": false, "message": message}

