class_name ComputerInformationView
extends PanelContainer
## CRT 内的信息终端视图。
##
## 这里不保存内容解锁、已读、人物陈述或事实；所有条目快照与未读数都来自
## StoryEngine。控件只维护当前页签和当前展开条目这类瞬时展示状态，并把“阅读”
## 与“播出”作为意图交给 GameScreen。

signal broadcast_requested(broadcast_id: String)
signal computer_entry_open_requested(category: String, entry_id: String)

const CATEGORY_CHECKLIST: String = "checklist"
const CATEGORY_NEWS: String = "news"
const CATEGORY_MESSAGES: String = "messages"
const CATEGORY_CALL_LOG: String = "call_log"
const CATEGORY_BROADCAST: String = "broadcast"
const INFORMATION_CATEGORIES: Array[String] = [
	CATEGORY_CHECKLIST,
	CATEGORY_NEWS,
	CATEGORY_MESSAGES,
	CATEGORY_CALL_LOG,
]
const PAGE_CATEGORIES: Array[String] = [
	CATEGORY_CHECKLIST,
	CATEGORY_NEWS,
	CATEGORY_MESSAGES,
	CATEGORY_CALL_LOG,
	CATEGORY_BROADCAST,
]
const CATEGORY_TITLES: Dictionary[String, String] = {
	CATEGORY_CHECKLIST: "值班清单",
	CATEGORY_NEWS: "地方新闻",
	CATEGORY_MESSAGES: "短信",
	CATEGORY_CALL_LOG: "来电记录",
	CATEGORY_BROADCAST: "播出工作台",
}
const CATEGORY_TAB_TITLES: Dictionary[String, String] = {
	CATEGORY_CHECKLIST: "清单",
	CATEGORY_NEWS: "新闻",
	CATEGORY_MESSAGES: "短信",
	CATEGORY_CALL_LOG: "来电",
	CATEGORY_BROADCAST: "播出",
}

var _phone_system: RefCounted = null
var _story_engine: RefCounted = null
var _unauthorized_broadcast: Dictionary = {}
var _feedback_text: String = ""
var _active_category: String = CATEGORY_CHECKLIST
var _opened_entry_ids_by_category: Dictionary[String, String] = {}
var _is_ending_locked: bool = false
var _is_phone_connected: bool = false
var _is_story_connected: bool = false

var _summary_label: Label = Label.new()
var _page_title_label: Label = Label.new()
var _notice_label: Label = Label.new()
var _tab_bar: HBoxContainer = HBoxContainer.new()
var _content_box: VBoxContainer = VBoxContainer.new()
var _tab_buttons: Dictionary[String, Button] = {}
var _tab_labels: Dictionary[String, Label] = {}


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


## StoryEngine 是 ComputerSystem 的唯一对外门面；UI 不直接读取其内部状态。
func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	var required_methods: PackedStringArray = [
		"get_computer_entries",
		"get_computer_unread_count",
		"mark_computer_entry_read",
		"get_statement_snapshot",
		"get_available_broadcasts",
		"get_player_broadcast_records",
	]
	for method_name: String in required_methods:
		if not story_engine.has_method(method_name):
			return _make_error("StoryEngine 缺少 %s() 公开接口。" % method_name)
	for signal_name: StringName in [&"computer_entries_changed", &"broadcast_state_changed", &"player_broadcast_sent"]:
		if not story_engine.has_signal(signal_name):
			return _make_error("StoryEngine 缺少 %s 信号。" % String(signal_name))
	_disconnect_story_engine()
	_story_engine = story_engine
	_connect_story_engine_if_possible()
	_refresh()
	return {"ok": true}


## 02:00 的记录已由 StoryEngine 构造；收到它即进入不可返回、不可交互的收束页。
func show_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	var validation: Dictionary = _validate_unauthorized_broadcast(record)
	if not bool(validation["ok"]):
		return validation
	_unauthorized_broadcast = record.duplicate(true)
	_is_ending_locked = true
	_active_category = CATEGORY_BROADCAST
	_refresh()
	return {"ok": true}


## GameScreen 转交 StoryEngine 的发送结果，避免 UI 对权威播出状态作出推断。
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


## 被 GameScreen 在成功提交阅读意图后调用；不写入任何剧情状态。
func show_entry_content(category: String, entry_id: String) -> Dictionary:
	if not INFORMATION_CATEGORIES.has(category):
		return _make_error("无法显示未知电脑分类：%s。" % category)
	if entry_id.strip_edges().is_empty():
		return _make_error("无法显示空条目 ID。")
	if not _contains_entry(category, entry_id):
		return _make_error("分类 %s 中不存在条目 %s。" % [category, entry_id])
	_opened_entry_ids_by_category[category] = entry_id
	_active_category = category
	_refresh()
	return {"ok": true}


func select_category(category: String) -> Dictionary:
	if not PAGE_CATEGORIES.has(category):
		return _make_error("未知电脑页签：%s。" % category)
	if _is_ending_locked and category != CATEGORY_BROADCAST:
		return {"ok": false, "message": "02:00 强制收束中，只能查看播出记录。"}
	_active_category = category
	_refresh()
	return {"ok": true, "category": _active_category}


func get_active_category() -> String:
	return _active_category


func is_ending_locked() -> bool:
	return _is_ending_locked


## 供 Headless 场景测试读取，不向游戏逻辑公开或缓存任何权威剧情状态。
func get_ui_snapshot() -> Dictionary:
	var unread_by_category: Dictionary[String, int] = {}
	for category: String in INFORMATION_CATEGORIES:
		unread_by_category[category] = _get_unread_count(category)
	var snapshot: Dictionary = {
		"active_category": _active_category,
		"is_ending_locked": _is_ending_locked,
		"unread_by_category": unread_by_category,
		"visible_entry_ids": _get_visible_entry_ids(),
	}
	snapshot.make_read_only()
	return snapshot


func _exit_tree() -> void:
	_disconnect_phone_system()
	_disconnect_story_engine()


func _build_interface() -> void:
	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	layout.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layout.offset_left = 20.0
	layout.offset_top = 16.0
	layout.offset_right = -20.0
	layout.offset_bottom = -16.0
	add_child(layout)

	var title: Label = Label.new()
	title.text = "WMLH 终端 / 信息核实与播出"
	title.add_theme_font_size_override("font_size", 27)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(title)

	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary_label.add_theme_font_size_override("font_size", 16)
	layout.add_child(_summary_label)

	_tab_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_bar.add_theme_constant_override("separation", 5)
	layout.add_child(_tab_bar)
	for category: String in PAGE_CATEGORIES:
		var button: Button = Button.new()
		button.name = "%sTab" % category.capitalize()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(130.0, 58.0)
		# 主题按钮的横向内边距服务于底图九宫格，会压窄 Button 自身的文字区域。
		# 因此文字由鼠标穿透的子标签承载，按钮仍是唯一的点击、悬停与禁用控件。
		button.text = ""
		button.pressed.connect(_on_tab_pressed.bind(category))
		_tab_buttons[category] = button
		_tab_bar.add_child(button)
		var tab_label: Label = Label.new()
		tab_label.name = "%sTabLabel" % category.capitalize()
		tab_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tab_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tab_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tab_label.autowrap_mode = TextServer.AUTOWRAP_OFF
		tab_label.add_theme_font_size_override("font_size", 18)
		button.add_child(tab_label)
		_tab_labels[category] = tab_label

	_page_title_label.add_theme_font_size_override("font_size", 22)
	_page_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_page_title_label)

	_notice_label.add_theme_font_size_override("font_size", 16)
	_notice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_notice_label)

	var scroll: ScrollContainer = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_content_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_content_box)


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
		{"signal": &"computer_entries_changed", "callback": Callable(self, "_on_computer_entries_changed")},
		{"signal": &"broadcast_state_changed", "callback": Callable(self, "_on_story_content_changed")},
		{"signal": &"player_broadcast_sent", "callback": Callable(self, "_on_player_broadcast_sent")},
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
		{"signal": &"computer_entries_changed", "callback": Callable(self, "_on_computer_entries_changed")},
		{"signal": &"broadcast_state_changed", "callback": Callable(self, "_on_story_content_changed")},
		{"signal": &"player_broadcast_sent", "callback": Callable(self, "_on_player_broadcast_sent")},
	]
	for contract: Dictionary in contracts:
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		if _story_engine.is_connected(signal_name, callback):
			_story_engine.disconnect(signal_name, callback)
	_is_story_connected = false


func _on_call_record_created(_record: Dictionary) -> void:
	# PhoneSystem 仍是记录的权威来源；StoryEngine 的装饰条目随后会发刷新信号。
	_refresh()


func _on_computer_entries_changed(_category: String = "") -> void:
	_refresh()


func _on_story_content_changed() -> void:
	_refresh()


func _on_player_broadcast_sent(_record: Dictionary) -> void:
	_refresh()


func _on_tab_pressed(category: String) -> void:
	var result: Dictionary = select_category(category)
	if not bool(result.get("ok", false)):
		_notice_label.text = "不可用：%s" % String(result.get("message", "当前无法切换页面。"))


func _on_entry_open_pressed(category: String, entry_id: String) -> void:
	if _is_ending_locked:
		_notice_label.text = "不可用：02:00 强制收束中，信息终端已锁定为播出记录。"
		return
	if entry_id.strip_edges().is_empty():
		push_error("[电脑][entry_open_empty_id] 电脑条目打开意图使用了空 ID。")
		return
	computer_entry_open_requested.emit(category, entry_id)


func _on_broadcast_button_pressed(broadcast_id: String) -> void:
	if _is_ending_locked:
		_notice_label.text = "不可用：02:00 强制收束中，不能发送玩家广播。"
		return
	broadcast_requested.emit(broadcast_id)


func _refresh() -> void:
	if not is_node_ready():
		return
	_refresh_tab_labels()
	_refresh_summary()
	_page_title_label.text = String(CATEGORY_TITLES.get(_active_category, "电脑终端"))
	_refresh_notice()
	_clear_children(_content_box)
	if _active_category == CATEGORY_BROADCAST:
		_refresh_broadcast_page()
	else:
		_refresh_information_page(_active_category)
	_apply_current_font_size()


## 页签与信息卡片在运行时创建。每次重建后用当前全局档位处理新增控件，
## 避免 125% 下新出现的新闻、短信、记录或播出卡片退回默认字号。
func _apply_current_font_size() -> void:
	var settings_manager: Node = get_tree().root.get_node_or_null(NodePath("SettingsManager")) as Node
	if settings_manager == null or not settings_manager.has_method(&"get_settings_snapshot"):
		return
	var snapshot_value: Variant = settings_manager.call(&"get_settings_snapshot")
	if not snapshot_value is Dictionary:
		return
	var font_size_value: Variant = (snapshot_value as Dictionary).get("font_size", 100)
	if typeof(font_size_value) != TYPE_INT:
		return
	var font_size_percent: int = int(font_size_value)
	if font_size_percent != 100 and font_size_percent != 125:
		return
	var inherited_percent: int = int(get_meta(SettingsUiScale.META_APPLIED_PERCENT, font_size_percent))
	var result: Dictionary = SettingsUiScale.apply_font_size(self, font_size_percent, inherited_percent)
	if not bool(result.get("ok", false)):
		push_error("[电脑][dynamic_font_apply_failed] %s" % String(result.get("message", "未知原因。")))


func _refresh_tab_labels() -> void:
	for category: String in PAGE_CATEGORIES:
		var button: Button = _tab_buttons.get(category) as Button
		var tab_label: Label = _tab_labels.get(category) as Label
		if button == null or tab_label == null:
			continue
		var title: String = String(CATEGORY_TAB_TITLES.get(category, category))
		if INFORMATION_CATEGORIES.has(category):
			tab_label.text = "%s\n未读 %d" % [title, _get_unread_count(category)]
		else:
			tab_label.text = title
		button.disabled = _is_ending_locked and category != CATEGORY_BROADCAST
		tab_label.modulate = Color(0.58, 0.56, 0.49, 0.92) if button.disabled else Color.WHITE
		if button.disabled:
			button.tooltip_text = "不可用：02:00 强制收束中，只能查看播出记录。"
		else:
			button.tooltip_text = "打开%s。" % title


func _refresh_summary() -> void:
	var unread_total: int = 0
	for category: String in INFORMATION_CATEGORIES:
		unread_total += _get_unread_count(category)
	if _is_ending_locked:
		_summary_label.text = "02:00 已锁定：未授权播出记录正在保留，返回与其他终端操作不可用。"
		return
	_summary_label.text = "信息终端：共 %d 条未读。新信息只更新计数，不会自动切换页面。" % unread_total


func _refresh_notice() -> void:
	if _is_ending_locked:
		_notice_label.text = "02:00 强制收束：已切换到播出页，所有其他页签和发送操作均已锁定。"
		return
	if not _feedback_text.is_empty() and _active_category == CATEGORY_BROADCAST:
		_notice_label.text = _feedback_text
		return
	_notice_label.text = "打开条目后才会标记为已读；未读数以文字显示。"


func _refresh_information_page(category: String) -> void:
	if not INFORMATION_CATEGORIES.has(category):
		_content_box.add_child(_make_text_card("电脑分类无效，无法显示。"))
		return
	var entries: Array = _read_story_entries(category)
	if entries.is_empty():
		_content_box.add_child(_make_text_card("暂无已解锁%s。" % String(CATEGORY_TITLES[category])))
		return
	var opened_entry_id: String = _opened_entry_ids_by_category.get(category, "")
	for raw_entry: Variant in entries:
		if not raw_entry is Dictionary:
			_content_box.add_child(_make_text_card("条目数据损坏，无法展示。"))
			continue
		var entry: Dictionary = raw_entry as Dictionary
		_content_box.add_child(_make_information_entry_card(category, entry, opened_entry_id == String(entry.get("id", ""))))


func _refresh_broadcast_page() -> void:
	var drafts_title: Label = _make_section_title("已解锁预制稿件")
	_content_box.add_child(drafts_title)
	_refresh_broadcast_drafts()
	_content_box.add_child(_make_section_title("真实播出记录"))
	_refresh_broadcast_history()


func _refresh_broadcast_drafts() -> void:
	var drafts: Array = _read_story_array(&"get_available_broadcasts", "可用广播稿")
	if drafts.is_empty():
		_content_box.add_child(_make_text_card("暂无已解锁稿件。官方短信或已接通的相关来电会提供可选口径。"))
		return
	for raw_draft: Variant in drafts:
		if not raw_draft is Dictionary:
			_content_box.add_child(_make_text_card("广播稿数据损坏，无法展示。"))
			continue
		_content_box.add_child(_make_broadcast_draft_card(raw_draft as Dictionary))


func _refresh_broadcast_history() -> void:
	var has_records: bool = false
	var player_records: Array = _read_story_array(&"get_player_broadcast_records", "玩家播出记录")
	for raw_record: Variant in player_records:
		if not raw_record is Dictionary:
			_content_box.add_child(_make_text_card("玩家播出记录损坏，无法展示。"))
			continue
		_content_box.add_child(_make_broadcast_record_card(raw_record as Dictionary, false))
		has_records = true
	if not _unauthorized_broadcast.is_empty():
		_content_box.add_child(_make_broadcast_record_card(_unauthorized_broadcast, true))
		has_records = true
	if not has_records:
		_content_box.add_child(_make_text_card("本局尚无真实播出记录。"))


func _make_information_entry_card(category: String, entry: Dictionary, is_open: bool) -> Control:
	var entry_id: String = String(entry.get("id", ""))
	if entry_id.strip_edges().is_empty():
		return _make_text_card("条目数据损坏：缺少稳定 ID。")
	var title: String = _get_entry_title(category, entry)
	var header: String = _get_entry_header(category, entry)
	var is_read: bool = bool(entry.get("read", false))
	var state_text: String = "已读" if is_read else "未读（打开后标记）"
	var card: VBoxContainer = VBoxContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_constant_override("separation", 5)
	card.add_child(_make_wrapped_label("%s\n%s\n状态：%s" % [header, title, state_text]))
	if is_open:
		var body: String = _get_entry_body(category, entry)
		card.add_child(_make_wrapped_label(body if not body.is_empty() else "该条目没有可显示正文。"))
	else:
		var open_button: Button = Button.new()
		open_button.text = "打开并标记已读"
		open_button.custom_minimum_size = Vector2(0.0, 48.0)
		open_button.tooltip_text = "打开此条%s；内容将由 StoryEngine 标记为已读。" % String(CATEGORY_TITLES[category])
		open_button.disabled = _is_ending_locked
		if open_button.disabled:
			open_button.tooltip_text = "不可用：02:00 强制收束中。"
		open_button.pressed.connect(_on_entry_open_pressed.bind(category, entry_id))
		card.add_child(open_button)
	return _wrap_control_in_card(card)


func _get_entry_title(category: String, entry: Dictionary) -> String:
	if category == CATEGORY_MESSAGES:
		var sender: String = String(entry.get("sender", "未知发件人"))
		return "来自：%s" % sender
	if category == CATEGORY_CALL_LOG:
		return "%s　%s" % [String(entry.get("caller_name", "未知来电")), String(entry.get("caller_number", "号码未知"))]
	var title: String = String(entry.get("title", ""))
	return title if not title.strip_edges().is_empty() else "未命名条目"


func _get_entry_header(category: String, entry: Dictionary) -> String:
	if category == CATEGORY_CALL_LOG:
		var time_value: Variant = entry.get("time", -1)
		var duration_value: Variant = entry.get("duration_ticks", -1)
		if typeof(time_value) != TYPE_INT or typeof(duration_value) != TYPE_INT:
			return "来电记录时间或时长无效"
		return "%s　%s　时长：%d tick" % [
			_format_game_time(int(time_value)),
			_format_outcome(String(entry.get("outcome", ""))),
			int(duration_value),
		]
	var source: String = String(entry.get("sender", entry.get("source", "终端记录")))
	return "来源：%s" % source


func _get_entry_body(category: String, entry: Dictionary) -> String:
	if category == CATEGORY_CALL_LOG:
		# 来电记录不保存逐字稿。只展示 StoryEngine 已确认揭示、且与本通来源匹配的
		# 陈述正文；即使装饰条目意外携带未知 ID，也不会让 UI 泄露未揭示内容。
		var summary_bodies: PackedStringArray = _get_revealed_call_summary_bodies(entry)
		var header: String = "事件：%s\n状态：%s\n本通已记录摘要：" % [
			String(entry.get("event_id", entry.get("source_id", "未知事件"))),
			_format_outcome(String(entry.get("outcome", ""))),
		]
		if summary_bodies.is_empty():
			return "%s\n未记录可核对线索。\n本记录不包含通话逐字稿。" % header
		var summary_lines: PackedStringArray = PackedStringArray()
		for body: String in summary_bodies:
			summary_lines.append("• %s" % body)
		return "%s\n%s\n本记录不包含通话逐字稿。" % [header, "\n".join(summary_lines)]
	return String(entry.get("body", ""))


func _get_revealed_call_summary_bodies(entry: Dictionary) -> PackedStringArray:
	var summary_bodies: PackedStringArray = PackedStringArray()
	if _story_engine == null:
		return summary_bodies
	var raw_statement_ids: Variant = entry.get("revealed_statement_ids", [])
	if not raw_statement_ids is Array:
		push_error("[电脑][invalid_revealed_statement_ids] 来电记录的 revealed_statement_ids 必须为数组。")
		return summary_bodies
	var seen_statement_ids: Dictionary = {}
	for raw_statement_id: Variant in raw_statement_ids as Array:
		if typeof(raw_statement_id) != TYPE_STRING:
			push_error("[电脑][invalid_revealed_statement_id] 来电记录包含非字符串陈述 ID。")
			continue
		var statement_id: String = String(raw_statement_id)
		if statement_id.strip_edges().is_empty() or seen_statement_ids.has(statement_id):
			continue
		seen_statement_ids[statement_id] = true
		var snapshot_value: Variant = _story_engine.call(&"get_statement_snapshot", statement_id)
		if not snapshot_value is Dictionary:
			push_error("[电脑][invalid_statement_snapshot] StoryEngine.get_statement_snapshot(%s) 必须返回 Dictionary。" % statement_id)
			continue
		var snapshot: Dictionary = snapshot_value as Dictionary
		# is_revealed 是最后一道门；绝不因 entry 中出现 ID 就显示其正文。
		if not bool(snapshot.get("is_revealed", false)):
			continue
		var body_value: Variant = snapshot.get("body", "")
		if typeof(body_value) != TYPE_STRING or String(body_value).strip_edges().is_empty():
			push_error("[电脑][invalid_statement_body] 已揭示陈述 %s 缺少可显示摘要正文。" % statement_id)
			continue
		summary_bodies.append(String(body_value))
	return summary_bodies


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
	button.disabled = not bool(draft["is_available_to_send"]) or _is_ending_locked
	var disabled_reason: String = "02:00 强制收束中，不能发送玩家广播。" if _is_ending_locked else String(draft.get("disabled_reason", ""))
	button.tooltip_text = "不可用：%s" % disabled_reason if button.disabled else "向外播出这条预制稿件。"
	button.pressed.connect(_on_broadcast_button_pressed.bind(String(draft["id"])))
	card.add_child(button)
	if button.disabled:
		var reason_label: Label = _make_wrapped_label("不可发送：%s" % disabled_reason)
		reason_label.add_theme_font_size_override("font_size", 16)
		card.add_child(reason_label)
	return _wrap_control_in_card(card)


func _make_broadcast_record_card(record: Dictionary, is_unauthorized: bool) -> Control:
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


func _make_section_title(text_value: String) -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", 20)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


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


func _read_story_entries(category: String) -> Array:
	if _story_engine == null:
		return []
	var result: Variant = _story_engine.call(&"get_computer_entries", category)
	if result is Array:
		return result as Array
	push_error("[电脑][invalid_computer_entries] StoryEngine.get_computer_entries(%s) 必须返回 Array。" % category)
	return []


func _read_story_array(method_name: StringName, context_name: String) -> Array:
	if _story_engine == null:
		return []
	var result: Variant = _story_engine.call(method_name)
	if result is Array:
		return result as Array
	push_error("[电脑][invalid_story_result] StoryEngine.%s() 必须返回 Array，当前用于%s。" % [String(method_name), context_name])
	return []


func _get_unread_count(category: String) -> int:
	if _story_engine == null:
		return 0
	var result: Variant = _story_engine.call(&"get_computer_unread_count", category)
	if typeof(result) != TYPE_INT or int(result) < 0:
		push_error("[电脑][invalid_unread_count] StoryEngine.get_computer_unread_count(%s) 必须返回非负整数。" % category)
		return 0
	return int(result)


func _contains_entry(category: String, entry_id: String) -> bool:
	for raw_entry: Variant in _read_story_entries(category):
		if raw_entry is Dictionary and String((raw_entry as Dictionary).get("id", "")) == entry_id:
			return true
	return false


func _get_visible_entry_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	if not INFORMATION_CATEGORIES.has(_active_category):
		return ids
	for raw_entry: Variant in _read_story_entries(_active_category):
		if raw_entry is Dictionary:
			var entry_id: String = String((raw_entry as Dictionary).get("id", ""))
			if not entry_id.strip_edges().is_empty():
				ids.append(entry_id)
	return ids


func _clear_children(container: Container) -> void:
	for child: Node in container.get_children():
		child.queue_free()


func _has_nonempty_strings(data: Dictionary, fields: Array[String]) -> bool:
	for field_name: String in fields:
		if not data.has(field_name) or typeof(data[field_name]) != TYPE_STRING or String(data[field_name]).strip_edges().is_empty():
			return false
	return true


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
	push_error("[电脑][computer_view_error] %s" % message)
	return {"ok": false, "message": message}
