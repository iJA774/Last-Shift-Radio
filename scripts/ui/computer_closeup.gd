class_name ComputerCloseup
extends Control
## 电脑近景只包装信息、来电记录与夜班结束记录显示组件。
## 玩家公告通过工作室总览的中央麦克风发送，不在电脑上重复提供入口。

signal return_requested()
signal computer_entry_open_requested(category: String, entry_id: String)

## 电脑页面是 UI 展示状态，不是 StoryEngine / ComputerSystem 的内容状态。
## 这个白名单同时是未来存读档前可查询的稳定 UI 契约，不能接受任意字符串。
const PAGE_CATEGORIES: Array[String] = [
	"checklist",
	"news",
	"messages",
	"call_log",
]

var _is_return_enabled: bool = true
var _is_motion_enabled: bool = true
var _is_crt_enabled: bool = true
var _cursor_tween: Tween = null
var _glow_tween: Tween = null

@onready var _information_view: Control = %InformationView
@onready var _return_button: Button = %BackButton
@onready var _screen_glow: ColorRect = %ScreenGlow
@onready var _screen_cursor: Label = %ScreenCursor


func bind_phone_system(phone_system: RefCounted) -> Dictionary:
	if phone_system == null:
		return _make_error("电话系统实例不能为空。")
	if _information_view == null or not _information_view.has_method(&"bind_phone_system"):
		return _make_error("电脑来电记录组件缺少 bind_phone_system() 接口。")
	var result: Variant = _information_view.call(&"bind_phone_system", phone_system)
	return _validate_component_result(result, "绑定电话系统")


## 电脑只读取信息条目；玩家公告由中央麦克风读取独立稿件接口。
func bind_story_engine(story_engine: RefCounted) -> Dictionary:
	if story_engine == null:
		return _make_error("StoryEngine 实例不能为空。")
	if _information_view == null or not _information_view.has_method(&"bind_story_engine"):
		return _make_error("电脑记录组件缺少 bind_story_engine() 接口。")
	var result: Variant = _information_view.call(&"bind_story_engine", story_engine)
	return _validate_component_result(result, "绑定剧情引擎")


## 仅维护当前可见页签；切页不会读取条目、写入 ComputerSystem 或推导剧情事实。
func select_category(category: String) -> Dictionary:
	if not PAGE_CATEGORIES.has(category):
		# UI 边界上的无效点击/脚本请求是可恢复的拒绝，不把预期校验写成引擎错误。
		print("[电脑][invalid_page_category] 拒绝未知电脑页签：%s。" % category)
		return {"ok": false, "message": "未知电脑页签：%s。" % category}
	if _information_view == null or not _information_view.has_method(&"select_category"):
		return _make_error("电脑信息组件缺少 select_category() 接口。")
	var result: Variant = _information_view.call(&"select_category", category)
	return _validate_component_result(result, "切换电脑页签")


func get_active_category() -> String:
	if _information_view == null or not _information_view.has_method(&"get_active_category"):
		push_error("[电脑][active_category_missing] 电脑信息组件缺少 get_active_category() 接口。")
		return ""
	var category_value: Variant = _information_view.call(&"get_active_category")
	if typeof(category_value) != TYPE_STRING or not PAGE_CATEGORIES.has(String(category_value)):
		push_error("[电脑][invalid_active_category] 电脑信息组件返回了无效页签：%s。" % str(category_value))
		return ""
	return String(category_value)


func show_unauthorized_broadcast(record: Dictionary) -> Dictionary:
	if _information_view == null or not _information_view.has_method(&"show_unauthorized_broadcast"):
		return _make_error("电脑来电记录组件缺少 show_unauthorized_broadcast() 接口。")
	var result: Variant = _information_view.call(&"show_unauthorized_broadcast", record)
	return _validate_component_result(result, "显示未授权播出记录")


## 阅读状态已由 GameScreen 转交 StoryEngine 写入；这里只把确认后的条目展开给玩家看。
func show_entry_content(category: String, entry_id: String) -> Dictionary:
	if _information_view == null or not _information_view.has_method(&"show_entry_content"):
		return _make_error("电脑信息组件缺少 show_entry_content() 接口。")
	var result: Variant = _information_view.call(&"show_entry_content", category, entry_id)
	return _validate_component_result(result, "显示电脑条目")


## 收束期间由 GameScreen 锁定导航；电脑近景不自行决定收束时间或剧情状态。
func set_return_enabled(is_enabled: bool, disabled_reason: String = "") -> Dictionary:
	if not is_enabled and disabled_reason.strip_edges().is_empty():
		return _make_error("禁用返回工作室总览时必须提供中文原因。")
	_is_return_enabled = is_enabled
	_refresh_return_button(disabled_reason)
	return {"ok": true}


## 减少动态只停止 CRT 光标闪烁与环境效果，不影响记录内容或收束状态。
func set_motion_enabled(is_enabled: bool) -> Dictionary:
	_is_motion_enabled = is_enabled
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null or not ambient_fx.has_method(&"set_motion_enabled"):
		return _make_error("环境效果组件缺少 set_motion_enabled() 接口。")
	ambient_fx.call(&"set_motion_enabled", is_enabled and _is_crt_enabled)
	_refresh_screen_motion()
	return {"ok": true}


## CRT 开关与“减少闪烁”独立：关闭时隐藏终端光感、光标与设备噪声层，
## 不改终端面板、文字、热点或任何运行时剧情状态。
func set_crt_enabled(is_enabled: bool) -> Dictionary:
	_is_crt_enabled = is_enabled
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null or not ambient_fx.has_method(&"set_motion_enabled"):
		return _make_error("环境效果组件缺少 set_motion_enabled() 接口。")
	ambient_fx.call(&"set_motion_enabled", _is_motion_enabled and _is_crt_enabled)
	_refresh_screen_motion()
	return {"ok": true, "crt_enabled": _is_crt_enabled}


func is_crt_enabled() -> bool:
	return _is_crt_enabled


func _ready() -> void:
	_connect_information_view_signals()
	_refresh_return_button()
	_configure_ambient_fx()
	_refresh_screen_motion()


func _refresh_return_button(disabled_reason: String = "") -> void:
	_return_button.disabled = not _is_return_enabled
	if _is_return_enabled:
		_return_button.text = "返回工作室总览"
		_return_button.tooltip_text = "返回工作室总览。"
		return
	# 02:00 收束页必须在不依赖悬停的情况下说明导航已锁定。
	_return_button.text = "返回不可用\n02:00 已锁定"
	_return_button.tooltip_text = "不可用：%s" % disabled_reason


func _on_back_button_pressed() -> void:
	if _is_return_enabled and not _return_button.disabled:
		return_requested.emit()


func _connect_information_view_signals() -> void:
	if _information_view == null:
		push_error("[电脑][computer_view_missing] 电脑信息组件不存在。")
		return
	var contracts: Array[Dictionary] = [
		{"signal": &"computer_entry_open_requested", "callback": Callable(self, "_on_information_entry_open_requested")},
	]
	for contract: Dictionary in contracts:
		var signal_name: StringName = contract["signal"] as StringName
		var callback: Callable = contract["callback"] as Callable
		if not _information_view.has_signal(signal_name):
			push_error("[电脑][computer_view_signal_missing] 电脑信息组件缺少 %s 信号。" % String(signal_name))
			continue
		if _information_view.is_connected(signal_name, callback):
			continue
		var result: Error = _information_view.connect(signal_name, callback)
		if result != OK:
			push_error("[电脑][computer_view_signal_connect_failed] 无法连接 %s，错误码=%d。" % [String(signal_name), result])


func _on_information_entry_open_requested(category: String, entry_id: String) -> void:
	if category.strip_edges().is_empty() or entry_id.strip_edges().is_empty():
		push_error("[电脑][invalid_entry_open_intent] 电脑信息组件发出了空分类或空条目 ID。")
		return
	computer_entry_open_requested.emit(category, entry_id)


func _configure_ambient_fx() -> void:
	var ambient_fx: Control = get_node_or_null(NodePath("AmbientFx")) as Control
	if ambient_fx == null:
		push_error("[电脑][ambient_fx_missing] 缺少 AmbientFx 环境效果组件。")
		return
	if not ambient_fx.has_method(&"set_profile") or not ambient_fx.has_method(&"set_random_seed"):
		push_error("[电脑][ambient_fx_contract] AmbientFx 缺少 set_profile() 或 set_random_seed() 接口。")
		return
	ambient_fx.call(&"set_profile", "equipment")
	ambient_fx.call(&"set_random_seed", 199903)
	var result: Dictionary = set_motion_enabled(_is_motion_enabled)
	if not bool(result.get("ok", false)):
		push_error("[电脑][ambient_fx_motion] %s" % String(result.get("message", "环境效果初始化失败。")))


func _refresh_screen_motion() -> void:
	_screen_glow.visible = _is_crt_enabled
	_screen_glow.modulate = Color(1.0, 1.0, 1.0, 0.72)
	_screen_cursor.visible = _is_crt_enabled
	_screen_cursor.modulate = Color(1.0, 1.0, 1.0, 0.76)
	_stop_cursor_tween()
	_stop_glow_tween()
	if not _is_motion_enabled or not _is_crt_enabled:
		return
	# 极低频、低幅度的屏幕呼吸光，仅营造 CRT 通电感，不制造闪烁惊吓。
	_glow_tween = create_tween().set_loops()
	_glow_tween.tween_property(_screen_glow, "modulate", Color(1.0, 1.0, 1.0, 0.46), 1.65)
	_glow_tween.tween_property(_screen_glow, "modulate", Color(1.0, 1.0, 1.0, 0.78), 1.65)
	_cursor_tween = create_tween().set_loops()
	_cursor_tween.tween_property(_screen_cursor, "modulate", Color(1.0, 1.0, 1.0, 0.15), 0.58)
	_cursor_tween.tween_property(_screen_cursor, "modulate", Color(1.0, 1.0, 1.0, 0.82), 0.58)


func _stop_cursor_tween() -> void:
	if _cursor_tween != null and _cursor_tween.is_valid():
		_cursor_tween.kill()
	_cursor_tween = null


func _stop_glow_tween() -> void:
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	_glow_tween = null


func _validate_component_result(result: Variant, action_name: String) -> Dictionary:
	if result is Dictionary and (result as Dictionary).has("ok"):
		return result as Dictionary
	return _make_error("%s失败：来电记录组件未返回带 ok 字段的结果。" % action_name)


func _make_error(message: String) -> Dictionary:
	push_error("[电脑][closeup_error] %s" % message)
	return {"ok": false, "message": message}
