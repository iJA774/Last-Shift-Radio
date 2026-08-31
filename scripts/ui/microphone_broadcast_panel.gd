class_name MicrophoneBroadcastPanel
extends PanelContainer
## 中央麦克风的发布任务控制面板。
##
## 面板只读取 StoryEngine 派生的任务快照，并提交稳定 task_id + information_item_ids；
## 不缓存任务资格、对话完成状态、陈述揭示状态或播出记录，StoryEngine 仍是唯一权威来源。

signal broadcast_requested(task_id: String, information_item_ids: Array[String])
signal broadcast_abandon_requested(task_id: String)
signal broadcast_defer_requested(task_id: String)
signal close_requested()

const COLOR_TEXT: Color = Color("d8d2b4")
const COLOR_MUTED: Color = Color("918b74")
const COLOR_ACCENT: Color = Color("d6b75e")

var _story_engine: RefCounted = null
var _is_story_connected: bool = false
var _is_ending_locked: bool = false
var _feedback: String = ""
var _title_label: Label = Label.new()
var _notice_label: Label = Label.new()
var _task_list: VBoxContainer = VBoxContainer.new()
var _checkboxes_by_task_id: Dictionary = {}


func _ready() -> void:
	_build_interface()
	_connect_story_engine_if_possible()
	_refresh()


func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	if not story_engine.has_method(&"get_broadcast_tasks") or not story_engine.has_signal(&"broadcast_state_changed"):
		return _make_error("剧情引擎缺少发布任务面板所需的公开接口。")
	_disconnect_story_engine()
	_story_engine = story_engine
	_connect_story_engine_if_possible()
	_refresh()
	return {"ok": true}


func set_ending_locked(is_locked: bool, disabled_reason: String = "") -> Dictionary:
	if is_locked and disabled_reason.strip_edges().is_empty():
		return _make_error("锁定麦克风时必须提供中文原因。")
	_is_ending_locked = is_locked
	_feedback = disabled_reason if is_locked else ""
	_refresh()
	return {"ok": true}


func show_feedback(result: Dictionary) -> Dictionary:
	if not result.has("ok") or typeof(result["ok"]) != TYPE_BOOL:
		return _make_error("发布结果缺少 bool 类型 ok 字段。")
	if bool(result["ok"]):
		_feedback = "信息已通过中央麦克风发送。"
	else:
		_feedback = String(result.get("message", "任务信息未能播出，请稍后再试。"))
	_refresh()
	return {"ok": true}


func is_open() -> bool:
	return visible


func open_panel() -> Dictionary:
	if _is_ending_locked:
		return {"ok": false, "message": "夜班已经结束。"}
	visible = true
	_refresh()
	return {"ok": true}


func close_panel() -> void:
	visible = false


func _exit_tree() -> void:
	_disconnect_story_engine()


func _build_interface() -> void:
	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.offset_left = 26.0
	layout.offset_top = 22.0
	layout.offset_right = -26.0
	layout.offset_bottom = -22.0
	add_child(layout)
	_title_label.text = "中央麦克风"
	_title_label.add_theme_font_size_override("font_size", 24)
	_title_label.add_theme_color_override("font_color", COLOR_ACCENT)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(_title_label)
	var subtitle: Label = _make_label("完成任务要求的必要通话后，可从已收集信息中选择本次要向外发布的内容。也可以暂不播出，继续等待相关来电。", 16, COLOR_TEXT)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(subtitle)
	_notice_label.add_theme_font_size_override("font_size", 15)
	_notice_label.name = "FeedbackLabel"
	_notice_label.add_theme_color_override("font_color", COLOR_MUTED)
	_notice_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_notice_label)
	var rule: HSeparator = HSeparator.new()
	layout.add_child(rule)
	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.name = "TaskScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_task_list.add_theme_constant_override("separation", 10)
	_task_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_task_list)
	var close_button: Button = _make_button("放下麦克风")
	close_button.tooltip_text = "返回工作室总览；未发布任务会保留，可以继续等待后续信息。"
	close_button.pressed.connect(_on_close_pressed)
	layout.add_child(close_button)


func _connect_story_engine_if_possible() -> void:
	if _story_engine == null or not is_node_ready() or _is_story_connected:
		return
	var callback: Callable = Callable(self, "_on_broadcast_state_changed")
	var result: Error = _story_engine.connect(&"broadcast_state_changed", callback)
	if result != OK:
		push_error("[麦克风][broadcast_state_connect_failed] 无法连接 StoryEngine.broadcast_state_changed，错误码=%d。" % result)
		return
	_is_story_connected = true


func _disconnect_story_engine() -> void:
	if _story_engine == null or not _is_story_connected:
		return
	var callback: Callable = Callable(self, "_on_broadcast_state_changed")
	if _story_engine.is_connected(&"broadcast_state_changed", callback):
		_story_engine.disconnect(&"broadcast_state_changed", callback)
	_is_story_connected = false


func _on_broadcast_state_changed() -> void:
	_refresh()


func _on_close_pressed() -> void:
	close_requested.emit()


func _on_task_publish_pressed(task_id: String) -> void:
	if _is_ending_locked:
		_notice_label.text = "不可用：夜班已经结束。"
		return
	if task_id.strip_edges().is_empty():
		push_error("[麦克风][empty_task_id] 发布按钮缺少稳定任务 ID。")
		return
	if not _checkboxes_by_task_id.has(task_id):
		push_error("[麦克风][missing_task_selection] 找不到任务 %s 的信息选择控件。" % task_id)
		return
	var selected_ids: Array[String] = []
	for raw_entry: Variant in _checkboxes_by_task_id[task_id] as Array:
		if not raw_entry is Dictionary:
			continue
		var entry: Dictionary = raw_entry as Dictionary
		var checkbox: CheckBox = entry.get("checkbox") as CheckBox
		if checkbox != null and checkbox.button_pressed:
			selected_ids.append(String(entry.get("information_item_id", "")))
	if selected_ids.is_empty():
		_notice_label.text = "至少勾选一条已经收集的信息。"
		return
	broadcast_requested.emit(task_id, selected_ids)


func _on_task_abandon_pressed(task_id: String) -> void:
	broadcast_abandon_requested.emit(task_id)


func _on_task_defer_pressed(task_id: String) -> void:
	broadcast_defer_requested.emit(task_id)


func _refresh() -> void:
	if not is_node_ready():
		return
	for child: Node in _task_list.get_children():
		child.queue_free()
	_checkboxes_by_task_id.clear()
	_notice_label.text = _feedback if not _feedback.is_empty() else ""
	if _is_ending_locked:
		_task_list.add_child(_make_card("夜班已经结束，麦克风已关闭。"))
		return
	var tasks: Array = _read_tasks()
	if tasks.is_empty():
		_task_list.add_child(_make_card("当前没有配置麦克风发布任务。"))
		return
	var visible_count: int = 0
	for raw_task: Variant in tasks:
		if not raw_task is Dictionary:
			_task_list.add_child(_make_card("发布任务数据损坏，无法使用。"))
			continue
		var task: Dictionary = raw_task as Dictionary
		if task.has("is_publishable") and not bool(task["is_publishable"]):
			continue
		_task_list.add_child(_make_task_card(task))
		visible_count += 1
	if visible_count == 0:
		_task_list.add_child(_make_card("当前没有可处理的发布任务。"))


func _read_tasks() -> Array:
	if _story_engine == null:
		return []
	var value: Variant = _story_engine.call(&"get_broadcast_tasks")
	if value is Array:
		return value as Array
	push_error("[麦克风][invalid_tasks] StoryEngine.get_broadcast_tasks() 必须返回 Array。")
	return []


func _make_task_card(task: Dictionary) -> Control:
	var task_id: String = String(task.get("id", ""))
	var task_name: String = String(task.get("name", ""))
	if task_id.is_empty() or task_name.is_empty():
		return _make_card("发布任务数据不完整，无法使用。")
	for required_field: String in ["available_information_items", "is_sent", "is_publishable"]:
		if not task.has(required_field):
			return _make_card("发布任务 %s 缺少状态字段 %s。" % [task_name, required_field])
	var content: VBoxContainer = VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	var name_label: Label = _make_label(task_name, 19, COLOR_ACCENT)
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(name_label)
	var completed_count: int = int(task.get("completed_required_dialogue_count", 0))
	var required_count: int = int(task.get("required_dialogue_count", 0))
	var progress_text: String = "必要通话：%d/%d" % [completed_count, required_count]
	if bool(task.get("prerequisites_met", true)):
		progress_text += "  ·  已满足发布前提"
	content.add_child(_make_label(progress_text, 15, COLOR_MUTED))
	var available_items: Array = task["available_information_items"] as Array
	var count_label: Label = _make_label("已收集可选信息：%d/%d" % [available_items.size(), int(task.get("total_information_item_count", available_items.size()))], 15, COLOR_MUTED)
	content.add_child(count_label)
	var selections: Array[Dictionary] = []
	var selection_mode: String = String(task.get("selection_mode", "multiple"))
	var single_group: ButtonGroup = ButtonGroup.new() if selection_mode == "single" else null
	if available_items.is_empty():
		var empty_label: Label = _make_label("目前还没有真正揭示、可用于本任务的信息。继续阅读相关消息或完成相关通话。", 16, COLOR_TEXT)
		empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(empty_label)
	else:
		for raw_item: Variant in available_items:
			if not raw_item is Dictionary:
				continue
			var item: Dictionary = raw_item as Dictionary
			var information_item_id: String = String(item.get("id", ""))
			var source_label: String = String(item.get("source_label", ""))
			var body: String = String(item.get("body", ""))
			if information_item_id.is_empty() or source_label.is_empty() or body.is_empty():
				continue
			var checkbox: CheckBox = CheckBox.new()
			checkbox.name = "InformationOption_%s" % information_item_id
			checkbox.button_group = single_group
			checkbox.button_pressed = selection_mode != "single"
			checkbox.disabled = not bool(task.get("prerequisites_met", true)) or bool(task["is_sent"])
			checkbox.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			checkbox.add_theme_font_size_override("font_size", 16)
			checkbox.add_theme_color_override("font_color", COLOR_TEXT)
			checkbox.add_theme_color_override("font_disabled_color", COLOR_MUTED)
			# 原生 CheckBox 的勾选图标是非纯颜色的明确状态反馈。正文在构建后
			# 不随单选切换改写，避免多行重排、滚动跳动或视觉闪烁。
			checkbox.text = "%s\n%s" % [source_label, body]
			content.add_child(checkbox)
			selections.append({"information_item_id": information_item_id, "checkbox": checkbox})
	if selection_mode == "single" and not selections.is_empty():
		var first_checkbox: CheckBox = (selections[0] as Dictionary).get("checkbox") as CheckBox
		if first_checkbox != null:
			first_checkbox.button_pressed = true
	_checkboxes_by_task_id[task_id] = selections
	var button: Button = _make_button("通过麦克风发布所选信息")
	button.name = "PublishTask_%s" % task_id
	button.disabled = not bool(task["is_publishable"])
	if bool(task["is_publishable"]):
		button.tooltip_text = "任务最低通话前提已满足；本次发布后该任务即完成，不能重复发布。"
	else:
		button.tooltip_text = String(task.get("disabled_reason", "当前任务不可发布。"))
	button.pressed.connect(_on_task_publish_pressed.bind(task_id))
	content.add_child(button)
	var decision_status: String = String(task.get("decision_status", ""))
	if decision_status == "pending":
		var defer_button: Button = _make_button("推迟广播")
		defer_button.name = "DeferTask_%s" % task_id
		defer_button.tooltip_text = "保留任务并恢复值守；有新的相关信息时会再次提醒。"
		defer_button.pressed.connect(_on_task_defer_pressed.bind(task_id))
		content.add_child(defer_button)
	if decision_status == "pending" or decision_status == "deferred":
		var abandon_button: Button = _make_button("放弃广播")
		abandon_button.name = "AbandonTask_%s" % task_id
		abandon_button.tooltip_text = "永久放弃本局任务；它不会再次出现或触发。"
		abandon_button.pressed.connect(_on_task_abandon_pressed.bind(task_id))
		content.add_child(abandon_button)
	if not String(task.get("disabled_reason", "")).is_empty():
		var reason_label: Label = _make_label(String(task["disabled_reason"]), 14, COLOR_MUTED)
		reason_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		content.add_child(reason_label)
	return _wrap_card(content)


func _make_card(text_value: String) -> Control:
	var label: Label = _make_label(text_value, 17, COLOR_TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return _wrap_card(label)


func _wrap_card(content: Control) -> PanelContainer:
	var card: PanelContainer = PanelContainer.new()
	card.add_theme_stylebox_override("panel", _make_style(Color(0.015, 0.018, 0.016, 0.96), Color(0.48, 0.42, 0.25, 0.92), 1))
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	card.add_child(margin)
	margin.add_child(content)
	return card


func _make_label(text_value: String, font_size: int, color: Color) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	return label


func _make_button(text_value: String) -> Button:
	var button: Button = Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(0.0, 44.0)
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", COLOR_TEXT)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color(0.5, 0.48, 0.40, 1))
	button.add_theme_stylebox_override("normal", _make_style(Color(0.03, 0.035, 0.03, 0.98), Color(0.56, 0.49, 0.28, 0.8), 1))
	button.add_theme_stylebox_override("hover", _make_style(Color(0.13, 0.11, 0.06, 0.98), COLOR_ACCENT, 1))
	button.add_theme_stylebox_override("pressed", _make_style(Color(0.2, 0.16, 0.07, 0.98), Color(1, 0.84, 0.43, 1), 2))
	button.add_theme_stylebox_override("disabled", _make_style(Color(0.025, 0.025, 0.023, 0.92), Color(0.3, 0.3, 0.27, 0.8), 1))
	return button


func _make_style(background: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style


func _make_error(message: String) -> Dictionary:
	push_error("[麦克风][broadcast_panel_error] %s" % message)
	return {"ok": false, "message": message}
