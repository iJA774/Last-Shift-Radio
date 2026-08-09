extends SceneTree

const PhoneSystemScript := preload("res://scripts/systems/phone_system.gd")

var _failures: int = 0


func _init() -> void:
	_test_legal_and_illegal_transitions()
	_test_answered_record()
	_test_missed_record()
	_test_hung_up_record()
	_test_record_uniqueness()
	_test_rejects_malformed_event_data()
	_test_expired_call_preserves_active_line()
	_test_forced_end_from_ringing()
	_test_forced_end_from_connected()
	_test_forced_end_from_dialogue_choice()
	if _failures == 0:
		print("[测试][PhoneSystem] 全部通过。")
		quit(0)
	else:
		push_error("[测试][PhoneSystem] 失败数量=%d。" % _failures)
		quit(1)


func _test_legal_and_illegal_transitions() -> void:
	var phone = PhoneSystemScript.new()
	_expect(not phone.answer_call(10), "空闲状态不能接听。")
	_expect(phone.begin_incoming_call(_call("call_legal"), 10, 5), "空闲状态可以开始来电。")
	_expect(phone.get_state_name() == "RINGING", "开始来电后必须处于 Ringing。")
	var snapshot: Dictionary = phone.get_active_call_snapshot()
	_expect(snapshot.get("event_id") == "call_legal", "来显快照必须返回活动事件 ID。")
	_expect(snapshot.get("ringing_deadline_tick") == 15, "来显快照必须返回响铃截止 tick。")
	snapshot["caller_name"] = "界面错误修改"
	_expect(phone.get_active_call_snapshot().get("caller_name") == "测试来电者", "来显快照不能反向修改权威线路状态。")
	_expect(not phone.enter_dialogue_choice(), "Ringing 不能直接进入 DialogueChoice。")
	_expect(phone.answer_call(12), "Ringing 可以接听。")
	_expect(phone.enter_dialogue_choice(), "Connected 可以进入 DialogueChoice。")
	_expect(phone.exit_dialogue_choice(), "DialogueChoice 可以返回 Connected。")
	_expect(phone.finish_call(15), "Connected 可以正常结束。")
	_expect(phone.get_state_name() == "IDLE", "终态记录后必须回到 Idle。")


func _test_answered_record() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_answered"), 100, 8), "answered 测试应能响铃。")
	_expect(phone.answer_call(103), "answered 测试应能接听。")
	_expect(phone.finish_call(111), "answered 测试应能正常结束。")
	var records: Array[Dictionary] = phone.get_call_records()
	_expect(records.size() == 1, "正常结束必须只产生一条记录。")
	_expect(_record_has(records[0], "call_answered", 100, "answered", 8), "answered 记录字段或时长不正确。")


func _test_missed_record() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_missed"), 200, 5), "missed 测试应能响铃。")
	_expect(not phone.advance_to_tick(204), "超时前不应结束来电。")
	_expect(phone.advance_to_tick(205), "到达响铃超时必须记为漏接。")
	var records: Array[Dictionary] = phone.get_call_records()
	_expect(records.size() == 1, "漏接必须只产生一条记录。")
	_expect(_record_has(records[0], "call_missed", 200, "missed", 5), "missed 记录字段或时长不正确。")


func _test_hung_up_record() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_hung_up"), 300, 5), "hung_up 测试应能响铃。")
	_expect(phone.answer_call(302), "hung_up 测试应能接听。")
	_expect(phone.hang_up(307), "Connected 状态应能主动挂断。")
	var records: Array[Dictionary] = phone.get_call_records()
	_expect(records.size() == 1, "主动挂断必须只产生一条记录。")
	_expect(_record_has(records[0], "call_hung_up", 300, "hung_up", 5), "hung_up 记录字段或时长不正确。")


func _test_record_uniqueness() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_unique"), 400, 2), "唯一性测试应能响铃。")
	_expect(phone.advance_to_tick(402), "唯一性测试应能超时。")
	_expect(not phone.advance_to_tick(403), "已结束来电不能再次超时并生成记录。")
	_expect(not phone.begin_incoming_call(_call("call_unique"), 404, 2), "已处理 event_id 不能重复触发。")
	_expect(phone.get_call_records().size() == 1, "相同 event_id 始终只能有一条记录。")


func _test_rejects_malformed_event_data() -> void:
	var phone = PhoneSystemScript.new()
	_expect(not phone.begin_incoming_call({}, 450, 2), "缺少 id 的外部事件必须被拒绝。")
	_expect(
		not phone.begin_incoming_call({"id": "Bad-Id", "caller_display_name": "甲", "caller_number": "1"}, 450, 2),
		"非 snake_case 稳定 ID 必须被拒绝。"
	)
	_expect(
		not phone.begin_incoming_call({"id": "call_bad_name", "caller_display_name": 3, "caller_number": "1"}, 450, 2),
		"非字符串 caller_display_name 必须被拒绝。"
	)
	_expect(phone.get_call_records().is_empty(), "损坏事件不得产生来电记录。")


func _test_expired_call_preserves_active_line() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_active"), 460, 8), "占线过期测试应能开始活动线路。")
	_expect(phone.answer_call(462), "占线过期测试应能接听活动线路。")
	_expect(phone.record_expired_call(_call("call_expired"), 465), "占线期间过期普通来电必须生成漏接记录。")
	_expect(phone.get_state_name() == "CONNECTED", "记录旁路过期来电不能改变活动线路状态。")
	_expect(phone.get_active_event_id() == "call_active", "记录旁路过期来电不能替换活动线路。")
	var records: Array[Dictionary] = phone.get_call_records()
	_expect(records.size() == 1, "旁路过期来电必须只生成一条记录。")
	_expect(_record_has(records[0], "call_expired", 465, "missed", 0), "旁路过期来电记录字段不正确。")
	_expect(not phone.record_expired_call(_call("call_expired"), 466), "过期来电记录必须按 event_id 去重。")
	_expect(phone.finish_call(470), "旁路记录后活动线路仍必须能正常结束。")


func _test_forced_end_from_ringing() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_force_ringing"), 500, 8), "强制结束响铃测试应能开始。")
	_expect(phone.force_end_at_0200(510), "02:00 必须中断 Ringing。")
	_expect(phone.force_end_at_0200(510), "02:00 重复调用必须幂等。")
	_expect(_has_forced_end_record(phone, "call_force_ringing", 10), "Ringing 强制结束记录不正确。")


func _test_forced_end_from_connected() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_force_connected"), 600, 8), "强制结束接通测试应能开始。")
	_expect(phone.answer_call(603), "强制结束接通测试应能接听。")
	_expect(phone.force_end_at_0200(611), "02:00 必须中断 Connected。")
	_expect(_has_forced_end_record(phone, "call_force_connected", 8), "Connected 强制结束记录不正确。")


func _test_forced_end_from_dialogue_choice() -> void:
	var phone = PhoneSystemScript.new()
	_expect(phone.begin_incoming_call(_call("call_force_choice"), 700, 8), "强制结束选择测试应能开始。")
	_expect(phone.answer_call(702), "强制结束选择测试应能接听。")
	_expect(phone.enter_dialogue_choice(), "强制结束选择测试应能进入选择。")
	_expect(phone.force_end_at_0200(709), "02:00 必须中断 DialogueChoice。")
	_expect(_has_forced_end_record(phone, "call_force_choice", 7), "DialogueChoice 强制结束记录不正确。")


func _call(event_id: String) -> Dictionary:
	return {
		"id": event_id,
		"caller_display_name": "测试来电者",
		"caller_number": "555-0199",
	}


func _record_has(record: Dictionary, event_id: String, time: int, outcome: String, duration_ticks: int) -> bool:
	return (
		record.get("event_id") == event_id
		and record.get("time") == time
		and record.get("caller_name") == "测试来电者"
		and record.get("caller_number") == "555-0199"
		and record.get("outcome") == outcome
		and record.get("duration_ticks") == duration_ticks
	)


func _has_forced_end_record(phone: Variant, event_id: String, duration_ticks: int) -> bool:
	var records: Array[Dictionary] = phone.get_call_records()
	return records.size() == 1 and _record_has(records[0], event_id, records[0].get("time"), "forced_end", duration_ticks)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error("[测试][PhoneSystem] %s" % message)
