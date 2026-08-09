class_name ComputerCallLogView
extends PanelContainer
## 电脑终端的来电记录与播出工作台。
##
## 此控件只读取 PhoneSystem / StoryEngine 的公开快照，按钮仅发出 broadcast_id
## 意图。它不写入条件、播出记录、未读状态或电话记录。

signal broadcast_requested(broadcast_id: String)

var _phone_system: RefCounted = null
var _story_engine: RefCounted = null
var _unauthorized_broadcast: Dictionary = {}
var _feedback_text: String = ""
var _summary_label: Label = Label.new()
var _message_box: VBoxContainer = VBoxContainer.new()
var _broadcast_drafts_box: VBoxContainer = VBoxContainer.new()
var _broadcast_history_box: VBoxContainer = VBoxContainer.new()
var _records_box: VBoxContainer = VBoxContainer.new()
var _is_phone_connected: bool = false
var _is_story_connected: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_interface()
	_connect_phone_system_if_possible()
	_connect_story_engine_if_possible()
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


## 故事运行时必须提供只读稿件、玩家播出记录和已解锁短信；三个信号只用于刷新。
func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	var required_methods: PackedStringArray = [
		"get_available_broadcasts",
		"get_player_broadcast_records",
		"get_unlocked_messages",
	]
	for method_name: String in required_methods:
		if not story_engine.has_method(method_name):
			return _make_error("StoryEngine 缺少 %s() 公开接口。" % method_name)
	for signal_name: StringName in [&"broadcast_state_changed", &"player_broadcast_sent", &"message_unlocked"]:
		if not story_engine.has_signal(signal_name):
			return _make_error("StoryEngine 缺少 %s 信号。" % String(signal_name))
	_disconnect_story_engine()
	_story_engine = story_engine
	_connect_story_engine_if_possible()
	_refresh()
	return {"ok": true}


func show_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	var validation: Dictionary = _validate_unauthorized_broadcast(record)
	if not bool(validation["ok"]):
		return validation
	# 仅保留展示快照；异常记录的权威来源仍是 StoryEngine。
	_unauthorized_broadcast = record.duplicate(true)
	_refresh()
	return {"ok": true}


## GameScreen 在 StoryEngine 返回发送结果后调用，避免 UI 自行解释权威状态。
func show_broadcast_feedback(result: Dictionary) -> Dictionary:
	if not result.has("ok") or typeof(result["ok"]) != TYPE_BOOL:
		return _make_error("播出反馈缺少 bool 类型 ok 字段。")
	if bool(result["ok"]):
		var record_value: Variant = result.get("record", {})
		if record_value is Dictionary and (record_value as Dictionary).has("broadcast_id"):
			_feedback_text = "播出已发送：%s" % String((record_value as Dictionary)["broadcast_id"])
		else:
			_feedback_text = "播出已发送。"
	else:
		_feedback_text = "播出未发送：%s" % String(result.get("message", "未知原因。"))
	_refresh()
	return {"ok": true}


func _exit_tree() -> void:
	_disconnect_phone_system()
	_disconnect_story_engine()


func _build_interface() -> void:
	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.offset_left = 20.0
	layout.offset_top = 18.0
	layout.offset_right = -20.0
	layout.offset_bottom = -18.0
	add_child(layout)

	var title: Label = Label.new()
	title.text = "电脑终端 / 信息、播出与来电记录"
	title.add_theme_font_size_override("font_size", 28)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(title)

	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_font_size_override("font_size", 17)
	layout.add_child(_summary_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	var content: VBoxContainer = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	content.add_child(_make_section_title("值班短信"))
	_message_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message_box.add_theme_constant_override("separation", 6)
	content.add_child(_message_box)

	content.add_child(_make_section_title("播出工作台"))
	_broadcast_drafts_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_broadcast_drafts_box.add_theme_constant_override("separation", 8)
	content.add_child(_broadcast_drafts_box)

	content.add_child(_make_section_title("真实播出记录"))
	_broadcast_history_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_broadcast_history_box.add_theme_constant_override("separation", 6)
	content.add_child(_broadcast_history_box)

	content.add_child(_make_section_title("来电记录"))
	_records_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_records_box.add_theme_constant_override("separation", 8)
	content.add_child(_records_box)


func _make_section_title(text_value: String) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", 21)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _connect_phone_system_if_possible() -> void:
	if _phone_system == null or not is_node_ready() or _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_call_record_created")
	var result: Error = _phone_system.connect(&"call_record_created", callback)
	if result != OK:
		push_error("[电脑][call_record_connect_failed] 无法连接 PhoneSystem.call_record_created，错误码=%d。" % result)
		return
	_is_phone_connected = true


func _connect_story_engine_if_possible() -> void:
	if _story_engine == null or not is_node_ready() or _is_story_connected:
		return
	var contracts: Array[Dictionary] = [
		{"signal": &"broadcast_state_changed", "callback": Callable(self, "_on_story_content_changed")},
		{"signal": &"player_broadcast_sent", "callback": Callable(self, "_on_player_broadcast_sent")},
		{"signal": &"message_unlocked", "callback": Callable(self, "_on_message_unlocked")},
	]
	for contract: Dictionary in contracts:
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		var result: Error = _story_engine.connect(signal_name, callback)
		if result != OK:
			_disconnect_story_engine()
			push_error("[电脑][story_connect_failed] 无法连接 StoryEngine.%s，错误码=%d。" % [String(signal_name), result])
			return
	_is_story_connected = true


func _disconnect_phone_system() -> void:
	if _phone_system == null or not _is_phone_connected:
		return
	var callback: Callable = Callable(self, "_on_call_record_created")
	if _phone_system.is_connected(&"call_record_created", callback):
		_phone_system.disconnect(&"call_record_created", callback)
	_is_phone_connected = false


func _disconnect_story_engine() -> void:
	if _story_engine == null or not _is_story_connected:
		return
	var contracts: Array[Dictionary] = [
		{"signal": &"broadcast_state_changed", "callback": Callable(self, "_on_story_content_changed")},
		{"signal": &"player_broadcast_sent", "callback": Callable(self, "_on_player_broadcast_sent")},
		{"signal": &"message_unlocked", "callback": Callable(self, "_on_message_unlocked")},
	]
	for contract: Dictionary in contracts:
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		if _story_engine.is_connected(signal_name, callback):
			_story_engine.disconnect(signal_name, callback)
	_is_story_connected = false


func _on_call_record_created(_record: Dictionary) -> void:
	_refresh()


func _on_story_content_changed() -> void:
	_refresh()


func _on_player_broadcast_sent(_record: Dictionary) -> void:
	_refresh()


func _on_message_unlocked(_message: Dictionary) -> void:
	_refresh()


func _on_broadcast_button_pressed(broadcast_id: String) -> void:
	broadcast_requested.emit(broadcast_id)


func _refresh() -> void:
	if not is_node_ready():
		return
	_refresh_summary()
	_refresh_messages()
	_refresh_broadcast_drafts()
	_refresh_broadcast_history()
	_refresh_call_records()


func _refresh_summary() -> void:
	var call_count: int = 0
	if _phone_system != null:
		var records_result: Variant = _phone_system.call(&"get_call_records")
		if records_result is Array:
			call_count = (records_result as Array).size()
	var feedback_suffix: String = ""
	if not _feedback_text.is_empty():
		feedback_suffix = "　%s" % _feedback_text
	_summary_label.text = "来电记录：%d 条。播出与短信均由 StoryEngine 提供；本页只提交预制稿件 ID。%s" % [call_count, feedback_suffix]


func _refresh_messages() -> void:
	_clear_children(_message_box)
	var messages: Array = _read_story_array(&"get_unlocked_messages", "已解锁短信")
	if messages.is_empty():
		_message_box.add_child(_make_wrapped_label("暂无已解锁短信。"))
		return
	for raw_message: Variant in messages:
		if not raw_message is Dictionary:
			_message_box.add_child(_make_wrapped_label("短信记录损坏，无法展示。"))
			continue
		var message: Dictionary = raw_message as Dictionary
		if not _has_nonempty_strings(message, ["id", "sender", "body"]) or typeof(message.get("unlock_minute")) != TYPE_INT:
			_message_box.add_child(_make_wrapped_label("短信记录缺少必要字段，无法展示。"))
			continue
		_message_box.add_child(_make_text_card("[%s] %s\n%s" % [
			_format_game_time(int(message["unlock_minute"]) * 60),
			String(message["sender"]),
			String(message["body"]),
		]))


func _refresh_broadcast_drafts() -> void:
	_clear_children(_broadcast_drafts_box)
	var drafts: Array = _read_story_array(&"get_available_broadcasts", "可用广播稿")
	if drafts.is_empty():
		_broadcast_drafts_box.add_child(_make_wrapped_label("暂无已解锁稿件。官方短信或已接通的相关来电会提供可选口径。"))
		return
	for raw_draft: Variant in drafts:
		if not raw_draft is Dictionary:
			_broadcast_drafts_box.add_child(_make_wrapped_label("广播稿数据损坏，无法展示。"))
			continue
		_broadcast_drafts_box.add_child(_make_broadcast_draft_card(raw_draft as Dictionary))


func _refresh_broadcast_history() -> void:
	_clear_children(_broadcast_history_box)
	var has_records: bool = false
	var player_records: Array = _read_story_array(&"get_player_broadcast_records", "玩家播出记录")
	for raw_record: Variant in player_records:
		if not raw_record is Dictionary:
			_broadcast_history_box.add_child(_make_wrapped_label("玩家播出记录损坏，无法展示。"))
			continue
		_broadcast_history_box.add_child(_make_broadcast_record_card(raw_record as Dictionary, false))
		has_records = true
	if not _unauthorized_broadcast.is_empty():
		_broadcast_history_box.add_child(_make_broadcast_record_card(_unauthorized_broadcast, true))
		has_records = true
	if not has_records:
		_broadcast_history_box.add_child(_make_wrapped_label("本局尚无真实播出记录。"))


func _refresh_call_records() -> void:
	_clear_children(_records_box)
	if _phone_system == null:
		_records_box.add_child(_make_wrapped_label("电话系统尚未连接。"))
		return
	var result: Variant = _phone_system.call(&"get_call_records")
	if not result is Array:
		_records_box.add_child(_make_wrapped_label("电话系统返回的数据类型无效。"))
		push_error("[电脑][invalid_call_records] PhoneSystem.get_call_records() 必须返回 Array。")
		return
	var records: Array = result as Array
	if records.is_empty():
		_records_box.add_child(_make_wrapped_label("暂无记录。接听、主动挂断、漏接或 02:00 中断后会自动写入此处。"))
		return
	for raw_record: Variant in records:
		if not raw_record is Dictionary:
			_records_box.add_child(_make_wrapped_label("记录损坏：条目不是对象。"))
			continue
		_records_box.add_child(_make_call_record_card(raw_record as Dictionary))


func _make_broadcast_draft_card(draft: Dictionary) -> Control:
	if not _has_nonempty_strings(draft, ["id", "source", "body"]) or typeof(draft.get("is_available_to_send")) != TYPE_BOOL:
		return _make_text_card("广播稿数据损坏：缺少必要字段。")
	var card: VBoxContainer = VBoxContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_constant_override("separation", 5)
	card.add_child(_make_wrapped_label("来源：%s\n%s" % [String(draft["source"]), String(draft["body"])]))
	var button: Button = Button.new()
	button.text = "发送预制稿件\n%s" % String(draft["id"])
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.custom_minimum_size = Vector2(0.0, 58.0)
	button.disabled = not bool(draft["is_available_to_send"])
	var disabled_reason: String = String(draft.get("disabled_reason", ""))
	button.tooltip_text = "不可用：%s" % disabled_reason if button.disabled else "向外播出这条预制稿件。"
	button.pressed.connect(_on_broadcast_button_pressed.bind(String(draft["id"])))
	card.add_child(button)
	if button.disabled:
		# 禁用原因必须常驻可见，不能只藏在鼠标悬停提示中。
		var reason_label: Label = _make_wrapped_label("不可发送：%s" % disabled_reason)
		reason_label.add_theme_font_size_override("font_size", 16)
		card.add_child(reason_label)
	return _wrap_control_in_card(card)


func _make_broadcast_record_card(record: Dictionary, is_unauthorized: bool) -> Control:
	var required_fields: PackedStringArray = ["broadcast_id", "source", "body", "is_unauthorized"]
	if not _has_nonempty_strings(record, ["broadcast_id", "source", "body"]) or not record.has("is_unauthorized"):
		return _make_text_card("播出记录损坏：缺少必要字段。")
	var tick_value: Variant = record.get("sent_at_tick", record.get("time_tick", -1))
	if typeof(tick_value) != TYPE_INT:
		return _make_text_card("播出记录损坏：发送时间不是整数 tick。")
	var heading: String = "未授权播出记录" if is_unauthorized else "玩家播出记录"
	var extra: String = ""
	if is_unauthorized and record.has("fact_id"):
		extra = "\n事实 ID：%s" % String(record["fact_id"])
	return _make_text_card("%s\n时间：%s　来源：%s\n%s\n记录 ID：%s%s" % [
		heading,
		_format_game_time(int(tick_value)),
		String(record["source"]),
		String(record["body"]),
		String(record["broadcast_id"]),
		extra,
	])


func _make_call_record_card(record: Dictionary) -> Control:
	if not _is_valid_call_record(record):
		return _make_text_card("来电记录损坏：缺少必要字段，无法展示。")
	return _make_text_card("%s　%s　%s\n状态：%s　时长：%d tick（游戏内 %d 秒）\n事件：%s" % [
		_format_game_time(int(record["time"])),
		String(record["caller_name"]),
		String(record["caller_number"]),
		_format_outcome(String(record["outcome"])),
		int(record["duration_ticks"]),
		int(record["duration_ticks"]),
		String(record["event_id"]),
	])


func _make_text_card(text_value: String) -> Control:
	return _wrap_control_in_card(_make_wrapped_label(text_value))


func _wrap_control_in_card(content: Control) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_child(margin)
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(content)
	return card


func _make_wrapped_label(text_value: String) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 18)
	return label


func _read_story_array(method_name: StringName, context_name: String) -> Array:
	if _story_engine == null:
		return []
	var result: Variant = _story_engine.call(method_name)
	if result is Array:
		return result as Array
	push_error("[电脑][invalid_story_result] StoryEngine.%s() 必须返回 Array，当前用于%s。" % [String(method_name), context_name])
	return []


func _clear_children(container: Container) -> void:
	for child: Node in container.get_children():
		child.queue_free()


func _has_nonempty_strings(data: Dictionary, fields: Array[String]) -> bool:
	for field_name: String in fields:
		if not data.has(field_name) or typeof(data[field_name]) != TYPE_STRING or String(data[field_name]).strip_edges().is_empty():
			return false
	return true


func _is_valid_call_record(record: Dictionary) -> bool:
	var required_fields: PackedStringArray = [
		"event_id", "time", "caller_name", "caller_number", "outcome", "duration_ticks",
	]
	for field_name: String in required_fields:
		if not record.has(field_name):
			return false
	return typeof(record["time"]) == TYPE_INT and typeof(record["duration_ticks"]) == TYPE_INT


func _validate_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	var required_fields: PackedStringArray = ["fact_id", "broadcast_id", "source", "body", "is_unauthorized"]
	for field_name: String in required_fields:
		if not record.has(field_name):
			return _make_error("未授权播出记录缺少字段：%s。" % field_name)
	if not record.has("sent_at_tick") and not record.has("time_tick"):
		return _make_error("未授权播出记录缺少 sent_at_tick。")
	var tick_value: Variant = record.get("sent_at_tick", record.get("time_tick", -1))
	if typeof(tick_value) != TYPE_INT:
		return _make_error("未授权播出记录的 sent_at_tick 必须是整数。")
	for field_name: String in ["fact_id", "broadcast_id", "source", "body"]:
		if typeof(record[field_name]) != TYPE_STRING or String(record[field_name]).strip_edges().is_empty():
			return _make_error("未授权播出记录的 %s 必须是非空字符串。" % field_name)
	if typeof(record["is_unauthorized"]) != TYPE_BOOL or not bool(record["is_unauthorized"]):
		return _make_error("未授权播出记录必须明确标记 is_unauthorized=true。")
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
