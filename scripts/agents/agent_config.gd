class_name AgentConfig
extends RefCounted

const SCHEMA_VERSION: int = 1
const SUPPORTED_PROTOCOL: String = "openai_chat_completions"


func load_from_path(path: String) -> Dictionary:
	if path.strip_edges().is_empty():
		return _error("config_path_empty", "Agent 配置路径不能为空。")
	if not FileAccess.file_exists(path):
		return _error("config_missing", "找不到 Agent 配置文件：%s" % path)
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("config_open_failed", "无法读取 Agent 配置文件：%s，错误码=%d。" % [path, FileAccess.get_open_error()])
	var text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(text)
	if parse_error != OK:
		return _error(
			"config_json_invalid",
			"Agent 配置 JSON 无效：%s:%d：%s" % [path, json.get_error_line(), json.get_error_message()]
		)
	if not json.data is Dictionary:
		return _error("config_root_invalid", "Agent 配置顶层必须是 JSON 对象：%s" % path)
	var validation: Dictionary = validate_document(json.data as Dictionary)
	if not bool(validation.get("ok", false)):
		validation["path"] = path
		return validation
	return {
		"ok": true,
		"path": path,
		"config": (json.data as Dictionary).duplicate(true),
	}


func validate_document(document: Dictionary) -> Dictionary:
	for required_key: String in ["schema_version", "enabled", "director", "actor", "runtime"]:
		if not document.has(required_key):
			return _error("config_field_missing", "Agent 配置缺少必填字段：%s。" % required_key)
	var version_result: Dictionary = _read_exact_int(document["schema_version"], "schema_version")
	if not bool(version_result.get("ok", false)):
		return version_result
	if int(version_result["value"]) != SCHEMA_VERSION:
		return _error(
			"config_version_unsupported",
			"不支持的 Agent 配置版本：%d，当前仅支持 %d。" % [int(version_result["value"]), SCHEMA_VERSION]
		)
	if not document["enabled"] is bool:
		return _error("config_field_type_invalid", "Agent 配置 enabled 必须是布尔值。")
	for role: String in ["director", "actor"]:
		if not document[role] is Dictionary:
			return _error("config_field_type_invalid", "Agent 配置 %s 必须是对象。" % role)
		var endpoint_result: Dictionary = _validate_endpoint(role, document[role] as Dictionary)
		if not bool(endpoint_result.get("ok", false)):
			return endpoint_result
	if not document["runtime"] is Dictionary:
		return _error("config_field_type_invalid", "Agent 配置 runtime 必须是对象。")
	return _validate_runtime(document["runtime"] as Dictionary)


func _validate_endpoint(role: String, endpoint: Dictionary) -> Dictionary:
	for required_key: String in [
		"protocol",
		"url",
		"model",
		"api_key",
		"temperature",
		"max_tokens",
		"timeout_seconds",
		"extra_headers",
		"extra_body",
	]:
		if not endpoint.has(required_key):
			return _error("config_field_missing", "Agent 配置 %s 缺少必填字段：%s。" % [role, required_key])
	for string_key: String in ["protocol", "url", "model", "api_key"]:
		if not endpoint[string_key] is String:
			return _error("config_field_type_invalid", "Agent 配置 %s.%s 必须是字符串。" % [role, string_key])
	if String(endpoint["protocol"]) != SUPPORTED_PROTOCOL:
		return _error(
			"config_protocol_unsupported",
			"Agent 配置 %s.protocol=%s 不受支持，当前仅支持 %s。" % [role, String(endpoint["protocol"]), SUPPORTED_PROTOCOL]
		)
	if String(endpoint["url"]).strip_edges().is_empty():
		return _error("config_endpoint_invalid", "Agent 配置 %s.url 不能为空。" % role)
	if String(endpoint["model"]).strip_edges().is_empty():
		return _error("config_endpoint_invalid", "Agent 配置 %s.model 不能为空。" % role)
	if not endpoint["temperature"] is float and not endpoint["temperature"] is int:
		return _error("config_field_type_invalid", "Agent 配置 %s.temperature 必须是数字。" % role)
	var temperature: float = float(endpoint["temperature"])
	if temperature < 0.0 or temperature > 2.0:
		return _error("config_value_invalid", "Agent 配置 %s.temperature 必须位于 0～2。" % role)
	var max_tokens_result: Dictionary = _read_exact_int(endpoint["max_tokens"], "%s.max_tokens" % role)
	if not bool(max_tokens_result.get("ok", false)):
		return max_tokens_result
	if int(max_tokens_result["value"]) <= 0:
		return _error("config_value_invalid", "Agent 配置 %s.max_tokens 必须大于 0。" % role)
	var timeout_result: Dictionary = _read_exact_int(endpoint["timeout_seconds"], "%s.timeout_seconds" % role)
	if not bool(timeout_result.get("ok", false)):
		return timeout_result
	if int(timeout_result["value"]) <= 0:
		return _error("config_value_invalid", "Agent 配置 %s.timeout_seconds 必须大于 0。" % role)
	if not endpoint["extra_headers"] is Dictionary:
		return _error("config_field_type_invalid", "Agent 配置 %s.extra_headers 必须是对象。" % role)
	if not endpoint["extra_body"] is Dictionary:
		return _error("config_field_type_invalid", "Agent 配置 %s.extra_body 必须是对象。" % role)
	for raw_header_key: Variant in (endpoint["extra_headers"] as Dictionary).keys():
		if not raw_header_key is String:
			return _error("config_field_type_invalid", "Agent 配置 %s.extra_headers 的键必须是字符串。" % role)
		var raw_header_value: Variant = (endpoint["extra_headers"] as Dictionary)[raw_header_key]
		if not raw_header_value is String:
			return _error("config_field_type_invalid", "Agent 配置 %s.extra_headers.%s 必须是字符串。" % [role, String(raw_header_key)])
	return {"ok": true}


func _validate_runtime(runtime: Dictionary) -> Dictionary:
	for required_key: String in [
		"actor_retry_limit",
		"director_guidance_enabled",
		"director_force_action_enabled",
		"deterministic_fallback_policy",
		"max_rejection_history",
	]:
		if not runtime.has(required_key):
			return _error("config_field_missing", "Agent 配置 runtime 缺少必填字段：%s。" % required_key)
	var retry_result: Dictionary = _read_exact_int(runtime["actor_retry_limit"], "runtime.actor_retry_limit")
	if not bool(retry_result.get("ok", false)):
		return retry_result
	var retry_limit: int = int(retry_result["value"])
	if retry_limit < 1 or retry_limit > 5:
		return _error("config_value_invalid", "runtime.actor_retry_limit 必须位于 1～5。")
	for bool_key: String in ["director_guidance_enabled", "director_force_action_enabled"]:
		if not runtime[bool_key] is bool:
			return _error("config_field_type_invalid", "Agent 配置 runtime.%s 必须是布尔值。" % bool_key)
	if not runtime["deterministic_fallback_policy"] is String:
		return _error("config_field_type_invalid", "runtime.deterministic_fallback_policy 必须是字符串。")
	if String(runtime["deterministic_fallback_policy"]) != "lowest_fallback_priority":
		return _error(
			"config_value_invalid",
			"runtime.deterministic_fallback_policy 当前仅支持 lowest_fallback_priority。"
		)
	var history_result: Dictionary = _read_exact_int(runtime["max_rejection_history"], "runtime.max_rejection_history")
	if not bool(history_result.get("ok", false)):
		return history_result
	var history_limit: int = int(history_result["value"])
	if history_limit < 1 or history_limit > 20:
		return _error("config_value_invalid", "runtime.max_rejection_history 必须位于 1～20。")
	return {"ok": true}


func _read_exact_int(value: Variant, field_name: String) -> Dictionary:
	if typeof(value) == TYPE_INT:
		return {"ok": true, "value": int(value)}
	# Godot 的 JSON 解析器会把 JSON number 读成 float。只接受精确整数值，
	# 既兼容磁盘 JSON，也继续拒绝 1.5、NaN 和无穷大等伪整数。
	if typeof(value) == TYPE_FLOAT:
		var float_value: float = float(value)
		if not is_nan(float_value) and not is_inf(float_value) and is_equal_approx(float_value, floor(float_value)):
			return {"ok": true, "value": int(float_value)}
	return _error("config_field_type_invalid", "Agent 配置 %s 必须是整数。" % field_name)


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
