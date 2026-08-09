extends SceneTree

## 第六阶段 ComputerSystem 专项烟测。
## 验证静态来源解锁/已读分离、读取幂等、电话记录权威同步以及输入快照隔离。

const COMPUTER_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/computer_system.gd")
const PHONE_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/phone_system.gd")

var _failures: int = 0
var _unlocked_signals: Array[Dictionary] = []
var _read_signals: Array[Dictionary] = []
var _changed_categories: Array[String] = []


func _init() -> void:
	_test_static_content_unlock_and_read_state()
	_test_rejections()
	_test_phone_call_log_sync()
	if _failures == 0:
		print("[测试][ComputerSystem] 全部通过。")
		quit(0)
	else:
		push_error("[测试][ComputerSystem] 失败数量=%d。" % _failures)
		quit(1)


func _test_static_content_unlock_and_read_state() -> void:
	var computer: ComputerSystem = COMPUTER_SYSTEM_SCRIPT.new()
	computer.source_unlocked.connect(_on_source_unlocked)
	computer.source_read.connect(_on_source_read)
	computer.entries_changed.connect(_on_entries_changed)

	var checklist_entries: Array = [
		{
			"id": "check_shift_open",
			"title": "值班开始",
			"body": "确认北桥封闭公告。",
			"unlock_minute": 0,
			"statement_ids": ["statement_bridge_closed"],
			"fact_ids": ["fact_bridge_closed"],
			"metadata": {"note": "原始内容必须隔离"},
		},
		{
			"id": "check_late_review",
			"title": "后续核对",
			"body": "比较目击说法。",
			"unlock_minute": 10,
			"statement_ids": [],
			"fact_ids": [],
		},
	]
	var news_entries: Array = [
		{
			"id": "news_bridge_closure",
			"title": "北桥封闭",
			"body": "市政部门称北桥因结构风险封闭。",
			"unlock_minute": 0,
			"statement_ids": ["statement_official_closure"],
			"fact_ids": ["fact_bridge_closed"],
		},
		{
			"id": "news_riverbank_report",
			"title": "河堤目击",
			"body": "一则待核实的河堤报告。",
			"unlock_minute": 8,
			"statement_ids": ["statement_riverbank_report"],
			"fact_ids": [],
		},
	]
	var messages: Array = [
		{
			"id": "message_handoff",
			"sender": "夜班交接",
			"body": "值班清单已更新。",
			"unlock_minute": 0,
			"statement_ids": [],
			"fact_ids": [],
		},
		{
			"id": "message_police",
			"sender": "警员米勒",
			"body": "北桥维持封闭。",
			"unlock_minute": 5,
			"statement_ids": ["statement_official_closure"],
			"fact_ids": ["fact_bridge_closed"],
		},
	]

	_assert_ok(computer.configure_content(checklist_entries, news_entries, messages), "有效电脑内容必须可配置。")
	# 输入在配置后发生的任何修改都不能进入内部状态。
	(checklist_entries[0] as Dictionary)["body"] = "被外部篡改"
	((checklist_entries[0] as Dictionary)["metadata"] as Dictionary)["note"] = "被外部篡改"
	(news_entries[0] as Dictionary)["statement_ids"] = ["statement_tampered"]

	_assert_ok(computer.advance_to_minute(0), "第 0 分钟必须能解锁初始来源。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_CHECKLIST).size(), 1, "第 0 分钟必须显示初始值班清单。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_NEWS).size(), 1, "第 0 分钟必须显示基础新闻。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_MESSAGES).size(), 1, "第 0 分钟必须显示交接短信。")
	_assert_equal(_unlocked_signals.size(), 3, "三个初始来源必须分别发出解锁信号。")

	var checklist: Array[Dictionary] = computer.get_entries(ComputerSystem.CATEGORY_CHECKLIST)
	var initial_checklist: Dictionary = checklist[0]
	_assert_true(initial_checklist.is_read_only(), "公开条目必须是只读快照。")
	_assert_equal(String(initial_checklist["body"]), "确认北桥封闭公告。", "外部修改不得污染内部正文。")
	_assert_equal(String((initial_checklist["metadata"] as Dictionary)["note"]), "原始内容必须隔离", "深层外部修改不得污染内部数据。")
	_assert_true(not bool(initial_checklist["read"]), "解锁来源不得自动标记已读。")
	_assert_true(computer.is_source_unlocked(ComputerSystem.CATEGORY_CHECKLIST, "check_shift_open"), "初始清单必须已解锁。")
	_assert_true(not computer.is_source_read(ComputerSystem.CATEGORY_CHECKLIST, "check_shift_open"), "初始清单尚未阅读。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_CHECKLIST), 1, "初始清单未读数必须为一。")

	var first_read: Dictionary = computer.mark_entry_read(ComputerSystem.CATEGORY_CHECKLIST, "check_shift_open")
	_assert_ok(first_read, "已解锁来源必须能标为已读。")
	_assert_true(bool(first_read["newly_read"]), "首次阅读必须标记 newly_read。")
	_assert_equal((first_read["statement_ids"] as Array).size(), 1, "阅读结果必须返回稳定陈述 ID。")
	_assert_equal(String(((first_read["entry"] as Dictionary)["fact_ids"] as Array)[0]), "fact_bridge_closed", "阅读结果条目必须保留事实引用，不确认事实。")
	_assert_true(computer.is_source_read(ComputerSystem.CATEGORY_CHECKLIST, "check_shift_open"), "首次阅读后必须记住已读状态。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_CHECKLIST), 0, "阅读后未读数必须减少。")
	_assert_equal(_read_signals.size(), 1, "首次阅读必须发出一次阅读信号。")
	_assert_equal(String((_read_signals[0]["statement_ids"] as Array)[0]), "statement_bridge_closed", "阅读信号必须携带陈述 ID。")

	var repeated_read: Dictionary = computer.mark_entry_read(ComputerSystem.CATEGORY_CHECKLIST, "check_shift_open")
	_assert_ok(repeated_read, "重复打开同一来源应为成功幂等操作。")
	_assert_true(not bool(repeated_read["newly_read"]), "重复打开不得再次标记 newly_read。")
	_assert_equal(_read_signals.size(), 1, "重复打开不得重复发出阅读信号。")

	_assert_ok(computer.advance_to_minute(5), "后续分钟推进必须成功。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_MESSAGES).size(), 2, "第 5 分钟必须解锁后续短信。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_MESSAGES), 2, "收到短信只能解锁，不能自动已读。")
	_assert_ok(computer.advance_to_minute(10), "跨越多个解锁分钟必须成功。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_NEWS).size(), 2, "跨越第 8 分钟必须解锁新闻。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_CHECKLIST).size(), 2, "第 10 分钟必须解锁后续清单。")
	_assert_equal(String((computer.get_entries(ComputerSystem.CATEGORY_NEWS)[0] as Dictionary)["statement_ids"][0]), "statement_official_closure", "原始 statement_ids 必须使用隔离副本。")


func _test_rejections() -> void:
	var computer: ComputerSystem = COMPUTER_SYSTEM_SCRIPT.new()
	_assert_error(computer.advance_to_minute(0), "content_not_configured", "未配置时不得推进静态来源。")
	_assert_error(
		computer.configure_content([
			{"id": "duplicate_id", "unlock_minute": 0},
		], [
			{"id": "duplicate_id", "unlock_minute": 0},
		], []),
		"duplicate_source_id",
		"跨电脑分类重复的来源 ID 必须拒绝。"
	)
	_assert_error(
		computer.configure_content([
			{"id": "bad_minute", "unlock_minute": 1.5},
		], [], []),
		"invalid_unlock_minute",
		"非整数 unlock_minute 必须拒绝。"
	)
	_assert_error(
		computer.configure_content([
			{"id": "bad_statements", "unlock_minute": 0, "statement_ids": ["not stable"]},
		], [], []),
		"invalid_statement_ids",
		"错误类型或格式的 statement_ids 必须拒绝。"
	)
	_assert_ok(computer.configure_content([
		{"id": "locked_source", "unlock_minute": 2},
	], [], []), "后续错误测试必须能配置有效内容。")
	_assert_ok(computer.advance_to_minute(0), "错误测试初始推进必须成功。")
	_assert_error(
		computer.mark_entry_read(ComputerSystem.CATEGORY_CHECKLIST, "locked_source"),
		"source_not_unlocked",
		"未解锁来源不得标记为已读。"
	)
	_assert_error(
		computer.mark_entry_read("unknown_category", "locked_source"),
		"unknown_category",
		"未知分类必须拒绝。"
	)
	_assert_error(computer.advance_to_minute(-1), "invalid_minute", "负分钟必须拒绝。")
	_assert_error(computer.advance_to_minute(0), "", "同一时间重复推进应成功而非报错。", true)
	_assert_error(computer.advance_to_minute(3), "", "正向推进应成功而非报错。", true)
	_assert_error(computer.advance_to_minute(2), "time_reversal", "时间倒退必须拒绝。")
	_assert_error(
		computer.mark_entry_read(ComputerSystem.CATEGORY_CHECKLIST, "unknown_source"),
		"unknown_source_id",
		"未知来源必须拒绝。"
	)


func _test_phone_call_log_sync() -> void:
	var computer: ComputerSystem = COMPUTER_SYSTEM_SCRIPT.new()
	var phone: PhoneSystem = PHONE_SYSTEM_SCRIPT.new()
	_assert_ok(computer.set_phone_system(phone), "ComputerSystem 必须能够绑定真实 PhoneSystem。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_CALL_LOG).size(), 0, "电话尚未生成记录时，来电页不得伪造事件。")

	_assert_true(phone.begin_incoming_call(_call("call_computer_answered"), 20, 4), "电话记录同步测试必须能开始来电。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_CALL_LOG).size(), 0, "正在响铃的电话尚未生成记录，来电页不能预先显示。")
	_assert_true(phone.answer_call(21), "电话记录同步测试必须能接听。")
	_assert_true(phone.finish_call(25), "电话记录同步测试必须能结束。")
	var entries_after_answered: Array[Dictionary] = computer.get_entries(ComputerSystem.CATEGORY_CALL_LOG)
	_assert_equal(entries_after_answered.size(), 1, "PhoneSystem 生成记录后，来电页必须同步一条记录。")
	var answered_entry: Dictionary = entries_after_answered[0]
	_assert_equal(String(answered_entry["id"]), "call_computer_answered", "来电装饰条目的 id 必须稳定等于真实 event_id。")
	_assert_equal(String(answered_entry["source_id"]), "call_computer_answered", "来电来源键必须稳定等于真实 event_id。")
	_assert_equal(String(answered_entry["event_id"]), "call_computer_answered", "来电快照必须保留真实 event_id。")
	_assert_equal(String(answered_entry["outcome"]), "answered", "来电快照不得改写电话结果。")
	_assert_equal(int(answered_entry["time"]), 20, "来电快照必须保留真实开始时间。")
	_assert_true(not answered_entry.has("body"), "ComputerSystem 不得为来电记录添加剧情正文。")
	_assert_true(not bool(answered_entry["read"]), "新来电记录不能自动标为已读。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_CALL_LOG), 1, "新来电记录必须计入未读。")
	_assert_ok(computer.mark_entry_read(ComputerSystem.CATEGORY_CALL_LOG, "call_computer_answered"), "真实来电记录必须可单独标为已读。")
	var phone_records: Array[Dictionary] = phone.get_call_records()
	_assert_equal(String(phone_records[0]["outcome"]), "answered", "阅读来电记录绝不能写回或改写 PhoneSystem。")

	_assert_true(phone.begin_incoming_call(_call("call_computer_missed"), 30, 3), "漏接记录同步测试必须能开始来电。")
	_assert_true(phone.advance_to_tick(33), "响铃超时必须由 PhoneSystem 生成漏接记录。")
	var entries_after_missed: Array[Dictionary] = computer.get_entries(ComputerSystem.CATEGORY_CALL_LOG)
	_assert_equal(entries_after_missed.size(), 2, "PhoneSystem 漏接记录必须同步到来电页。")
	var missed_entry: Dictionary = entries_after_missed[1]
	_assert_equal(String(missed_entry["event_id"]), "call_computer_missed", "漏接记录必须保留真实 event_id。")
	_assert_equal(String(missed_entry["outcome"]), "missed", "漏接记录不能被伪装成已接通。")
	_assert_equal(computer.get_unread_count(ComputerSystem.CATEGORY_CALL_LOG), 1, "只读取第一条后，漏接记录应保持唯一未读。")

	var release_result: Dictionary = computer.release_runtime()
	_assert_ok(release_result, "运行时释放必须成功。")
	_assert_true(bool(release_result["released_phone_system"]), "首次释放必须报告已解除电话系统。")
	_assert_true(phone.begin_incoming_call(_call("call_after_release"), 40, 2), "释放后的原电话仍可独立生成真实记录。")
	_assert_true(phone.advance_to_tick(42), "释放后的原电话必须能生成漏接记录。")
	_assert_equal(phone.get_call_records().size(), 3, "原电话必须真实保留释放后生成的记录。")
	_assert_equal(computer.get_entries(ComputerSystem.CATEGORY_CALL_LOG).size(), 2, "释放后生成的电话记录不得再同步到电脑。")
	var repeated_release: Dictionary = computer.release_runtime()
	_assert_ok(repeated_release, "重复释放必须是成功幂等操作。")
	_assert_true(not bool(repeated_release["released_phone_system"]), "重复释放必须报告当前没有电话系统。")


func _call(event_id: String) -> Dictionary:
	return {
		"id": event_id,
		"caller_display_name": "电脑系统测试来电者",
		"caller_number": "555-0199",
	}


func _on_source_unlocked(category: String, entry: Dictionary) -> void:
	_unlocked_signals.append({"category": category, "entry": entry})


func _on_source_read(category: String, source_id: String, statement_ids: Array[String]) -> void:
	_read_signals.append({
		"category": category,
		"source_id": source_id,
		"statement_ids": statement_ids.duplicate(),
	})


func _on_entries_changed(category: String) -> void:
	_changed_categories.append(category)


func _assert_ok(result: Dictionary, message: String) -> void:
	_expect(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])


func _assert_error(result: Dictionary, error_code: String, message: String, expect_success: bool = false) -> void:
	if expect_success:
		_expect(bool(result.get("ok", false)), "%s 结果=%s。" % [message, str(result)])
		return
	_expect(not bool(result.get("ok", false)), message)
	_expect(String(result.get("error_code", "")) == error_code, "%s error_code 实际=%s。" % [message, String(result.get("error_code", ""))])


func _assert_true(condition: bool, message: String) -> void:
	_expect(condition, message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_expect(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[测试][ComputerSystem] %s" % message)
