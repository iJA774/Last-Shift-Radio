extends SceneTree

const DELIVERY_SYSTEM_SCRIPT: GDScript = preload("res://scripts/systems/delivery_system.gd")

var _has_failed: bool = false
var _restore_committed_count: int = 0
var _restore_queued_count: int = 0


class FakePhone:
	extends RefCounted
	var busy: bool = false
	var forced: bool = false
	var begin_calls: Array[Dictionary] = []

	func begin_incoming_call(call_data: Dictionary, current_tick: int, ring_timeout_ticks: int) -> bool:
		if forced or busy:
			return false
		busy = true
		begin_calls.append({
			"call_data": call_data.duplicate(true),
			"current_tick": current_tick,
			"ring_timeout_ticks": ring_timeout_ticks,
		})
		return true

	func is_busy() -> bool:
		return busy

	func is_forced_ended() -> bool:
		return forced


class FakeComputer:
	extends RefCounted
	var commits: Array[Dictionary] = []
	var by_id: Dictionary = {}

	func commit_dynamic_message(message: Dictionary, current_tick: int) -> Dictionary:
		var source_id: String = String(message.get("id", ""))
		var normalized: Dictionary = {
			"message": message.duplicate(true),
			"current_tick": current_tick,
		}
		if by_id.has(source_id):
			if (by_id[source_id] as Dictionary) != normalized:
				return {"ok": false, "error_code": "fake_message_conflict"}
			return {"ok": true, "duplicate": true}
		by_id[source_id] = normalized
		commits.append(normalized)
		return {"ok": true, "duplicate": false}


func _init() -> void:
	_test_validate_request_intent_is_read_only()
	_test_commit_queue_dedupe_and_serials()
	_test_queued_restore_without_replay()
	if _has_failed:
		print("[测试][DeliverySystem] 失败。")
		quit(1)
		return
	print("[测试][DeliverySystem] 通过：只读预检、稳定 ID、call queue、send_message 与 restore-no-replay 合同成立。")
	quit(0)


func _test_validate_request_intent_is_read_only() -> void:
	var system: DeliverySystem = DELIVERY_SYSTEM_SCRIPT.new() as DeliverySystem
	var phone: FakePhone = FakePhone.new()
	var computer: FakeComputer = FakeComputer.new()
	_assert_ok(system.configure(_actors(), _events()), "只读预检测试必须配置正式 Actor 与 authored call identity。")
	_assert_ok(system.set_phone_system(phone), "只读预检测试必须绑定 Phone authority。")
	_assert_ok(system.set_computer_system(computer), "只读预检测试必须绑定 Computer authority。")
	var before: Dictionary = system.get_state_summary().duplicate(true)

	_assert_ok(system.validate_request_intent(
		"martha",
		"call_station",
		{},
		"opportunity_preflight_call",
		"director_plan_preflight"
	), "call_station 只读预检必须接受当前允许的结构化 intent。")
	_assert_ok(system.validate_request_intent(
		"martha",
		"send_message",
		{"body": "Preflight only."},
		"opportunity_preflight_message",
		"director_plan_preflight"
	), "send_message 只读预检必须接受当前允许的结构化 intent。")

	_assert_equal(system.get_state_summary(), before, "validate_request_intent 不得修改 requests、queue 或 next_serial。")
	_assert_equal(phone.begin_calls.size(), 0, "validate_request_intent 不得调用 Phone authority。")
	_assert_equal(computer.commits.size(), 0, "validate_request_intent 不得调用 Computer authority。")
	var submit_result: Dictionary = system.submit_delivery_request(
		"martha",
		"call_station",
		{},
		50,
		"opportunity_after_preflight"
	)
	_assert_ok(submit_result, "只读预检后正式 submit 仍必须成功。")
	_assert_equal(String((submit_result.get("record", {}) as Dictionary).get("delivery_id", "")), "delivery_call_martha_1", "只读预检不得消耗 delivery serial。")


func _test_commit_queue_dedupe_and_serials() -> void:
	var system: DeliverySystem = DELIVERY_SYSTEM_SCRIPT.new() as DeliverySystem
	var phone: FakePhone = FakePhone.new()
	var computer: FakeComputer = FakeComputer.new()
	_assert_ok(system.configure(_actors(), _events()), "DeliverySystem 必须接受正式 Actor 与 authored call identity。")
	_assert_ok(system.set_phone_system(phone), "DeliverySystem 必须绑定 Phone authority。")
	_assert_ok(system.set_computer_system(computer), "DeliverySystem 必须绑定 Computer authority。")

	var first_call: Dictionary = system.submit_delivery_request(
		"martha",
		"call_station",
		{},
		100,
		"opportunity_test_call_martha"
	)
	_assert_ok(first_call, "空闲线路上的 call_station 必须提交。")
	var first_record: Dictionary = first_call.get("record", {}) as Dictionary
	_assert_equal(String(first_record.get("delivery_id", "")), "delivery_call_martha_1", "首条 call delivery ID 必须使用确定性 serial。")
	_assert_equal(String(first_record.get("status", "")), "committed", "成功进入 PhoneSystem 后必须标记 committed。")
	_assert_equal(phone.begin_calls.size(), 1, "成功来电只能调用一次 Phone authority。")
	if phone.begin_calls.size() == 1:
		var call_data: Dictionary = (phone.begin_calls[0]["call_data"] as Dictionary)
		_assert_equal(String(call_data.get("caller_display_name", "")), "Martha", "动态来电来显必须来自 authored identity。")
		_assert_equal(String(call_data.get("caller_number", "")), "555-0101", "动态来电号码必须来自 authored identity。")

	var duplicate_call: Dictionary = system.submit_delivery_request(
		"martha",
		"call_station",
		{},
		101,
		"opportunity_test_call_martha"
	)
	_assert_ok(duplicate_call, "同一 opportunity 重复提交必须幂等。")
	_assert_true(bool(duplicate_call.get("duplicate", false)), "幂等重复必须显式标记 duplicate。")
	_assert_equal(phone.begin_calls.size(), 1, "重复 opportunity 不得再次调用 PhoneSystem。")

	var queued_call: Dictionary = system.submit_delivery_request(
		"ronnie",
		"call_station",
		{"topic": "player_broadcast"},
		102,
		"opportunity_test_call_ronnie"
	)
	_assert_ok(queued_call, "线路 busy 时 call_station 必须进入确定性队列。")
	var queued_record: Dictionary = queued_call.get("record", {}) as Dictionary
	_assert_equal(String(queued_record.get("delivery_id", "")), "delivery_call_ronnie_2", "第二条 request 必须使用下一个 serial。")
	_assert_equal(String(queued_record.get("status", "")), "queued", "busy policy 第一版必须是 queued。")
	_assert_equal((system.get_state_summary()["queued_call_ids"] as Array), ["delivery_call_ronnie_2"], "call queue 必须保持 FIFO stable ID。")

	phone.busy = false
	_assert_ok(system.retry_queued_calls(110), "Phone idle 后必须可继续 FIFO 队头。")
	_assert_equal(String(system.get_request("delivery_call_ronnie_2").get("status", "")), "committed", "队头成功进入 Phone 后必须转为 committed。")
	_assert_equal(phone.begin_calls.size(), 2, "队列重试只能新增一次 Phone authority 调用。")

	var message_result: Dictionary = system.submit_delivery_request(
		"martha",
		"send_message",
		{"body": "I heard the broadcast."},
		111,
		"opportunity_test_message_martha",
		"director_plan_test_one"
	)
	_assert_ok(message_result, "send_message 必须通过 Computer authority 提交。")
	var message_record: Dictionary = message_result.get("record", {}) as Dictionary
	_assert_equal(String(message_record.get("delivery_id", "")), "delivery_message_martha_3", "message delivery 必须共享同一确定性 serial authority。")
	_assert_equal(String(message_record.get("status", "")), "committed", "Computer 提交成功后 Delivery 必须 committed。")
	_assert_equal(computer.commits.size(), 1, "send_message 只能提交一次 Computer authority。")
	if computer.commits.size() == 1:
		var message: Dictionary = (computer.commits[0]["message"] as Dictionary)
		_assert_equal(String(message.get("sender", "")), "Martha", "动态消息 sender 必须来自正式 Actor display_name。")
		_assert_equal(String(message.get("id", "")), "delivery_message_martha_3", "Computer 动态消息 ID 必须与 Delivery ID 相同。")

	var snapshot: Dictionary = system.create_snapshot().duplicate(true)
	_assert_ok(system.validate_snapshot(snapshot, {"current_game_tick": 111}), "Delivery snapshot 必须通过严格自校验。")
	_assert_equal(int(snapshot.get("next_serial", 0)), 4, "next_serial 必须持久化并精确接续已有 requests。")
	var tampered: Dictionary = snapshot.duplicate(true)
	(tampered["call_queue"] as Array).append("delivery_call_martha_1")
	_assert_error_code(system.validate_snapshot(tampered, {"current_game_tick": 111}), "delivery_snapshot_queue_mismatch", "存档不得把 committed call 偷塞回 queue。")


func _test_queued_restore_without_replay() -> void:
	var source: DeliverySystem = DELIVERY_SYSTEM_SCRIPT.new() as DeliverySystem
	var busy_phone: FakePhone = FakePhone.new()
	busy_phone.busy = true
	var source_computer: FakeComputer = FakeComputer.new()
	_assert_ok(source.configure(_actors(), _events()), "队列 restore source 必须配置同一世界。")
	_assert_ok(source.set_phone_system(busy_phone), "队列 restore source 必须绑定 Phone。")
	_assert_ok(source.set_computer_system(source_computer), "队列 restore source 必须绑定 Computer。")
	_assert_ok(source.submit_delivery_request("martha", "call_station", {}, 200, "opportunity_restore_call"), "busy source 必须产生 queued delivery。")
	var snapshot: Dictionary = source.create_snapshot().duplicate(true)

	var restored: DeliverySystem = DELIVERY_SYSTEM_SCRIPT.new() as DeliverySystem
	var restored_phone: FakePhone = FakePhone.new()
	var restored_computer: FakeComputer = FakeComputer.new()
	_assert_ok(restored.configure(_actors(), _events()), "恢复目标必须先配置同一世界。")
	_assert_ok(restored.set_phone_system(restored_phone), "恢复目标必须绑定 Phone authority。")
	_assert_ok(restored.set_computer_system(restored_computer), "恢复目标必须绑定 Computer authority。")
	_restore_committed_count = 0
	_restore_queued_count = 0
	restored.delivery_committed.connect(_on_restored_committed)
	restored.delivery_queued.connect(_on_restored_queued)
	_assert_ok(restored.restore_snapshot(snapshot, {"current_game_tick": 200}), "queued Delivery 决定必须可恢复。")
	_assert_equal(_restore_committed_count, 0, "restore 不得重发 historical delivery_committed。")
	_assert_equal(_restore_queued_count, 0, "restore 不得重发 historical delivery_queued。")
	_assert_equal(restored_phone.begin_calls.size(), 0, "restore queued delivery 不得立刻重提 PhoneSystem。")
	_assert_ok(restored.retry_queued_calls(201), "恢复后 deterministic queue 应能在明确 idle 时继续。")
	_assert_equal(restored_phone.begin_calls.size(), 1, "恢复后的 queued call 只应提交一次。")
	_assert_equal(String(restored.get_request("delivery_call_martha_1").get("status", "")), "committed", "恢复队列提交后状态必须 committed。")


func _actors() -> Array:
	return [
		{"id": "martha", "display_name": "Martha"},
		{"id": "ronnie", "display_name": "Ronnie"},
	]


func _events() -> Array:
	return [
		{"id": "call_test_martha", "actor_id": "martha", "caller_display_name": "Martha", "caller_number": "555-0101"},
		{"id": "call_test_ronnie", "actor_id": "ronnie", "caller_display_name": "Ronnie", "caller_number": "555-0109"},
	]


func _on_restored_committed(_record: Dictionary) -> void:
	_restore_committed_count += 1


func _on_restored_queued(_record: Dictionary) -> void:
	_restore_queued_count += 1


func _assert_ok(result: Dictionary, message: String) -> void:
	_assert_true(bool(result.get("ok", false)), "%s result=%s" % [message, str(result)])


func _assert_error_code(result: Dictionary, expected_code: String, message: String) -> void:
	_assert_true(not bool(result.get("ok", true)), "%s 不应成功。 result=%s" % [message, str(result)])
	_assert_equal(String(result.get("error_code", "")), expected_code, message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际值=%s，期望值=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][DeliverySystem] %s" % message)
