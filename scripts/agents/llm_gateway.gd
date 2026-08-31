class_name LlmGateway
extends Node

## 只负责 OpenAI Chat Completions 兼容协议的网络传输与响应解析。
## 它不读取 SettingsManager，也不拥有任何剧情或 Actor 状态，更不能直接提交世界变化。


func request_json(endpoint: Dictionary, system_prompt: String, payload: Dictionary) -> Dictionary:
	var request_node: HTTPRequest = HTTPRequest.new()
	request_node.use_threads = true
	request_node.timeout = float(endpoint["timeout_seconds"])
	add_child(request_node)

	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	var api_key: String = String(endpoint["api_key"])
	if not api_key.is_empty():
		headers.append("Authorization: Bearer %s" % api_key)
	var extra_headers: Dictionary = endpoint["extra_headers"] as Dictionary
	for raw_key: Variant in extra_headers.keys():
		var key: String = String(raw_key)
		headers.append("%s: %s" % [key, String(extra_headers[raw_key])])

	var request_body: Dictionary = {
		"model": String(endpoint["model"]),
		"temperature": float(endpoint["temperature"]),
		"max_tokens": int(endpoint["max_tokens"]),
		"messages": [
			{"role": "system", "content": system_prompt},
			{"role": "user", "content": JSON.stringify(payload)},
		],
	}
	var extra_body: Dictionary = endpoint["extra_body"] as Dictionary
	for raw_key: Variant in extra_body.keys():
		request_body[raw_key] = extra_body[raw_key]

	var request_error: Error = request_node.request(
		String(endpoint["url"]),
		headers,
		HTTPClient.METHOD_POST,
		JSON.stringify(request_body)
	)
	if request_error != OK:
		request_node.queue_free()
		return _error("request_start_failed", "模型请求无法启动，错误码=%d。" % request_error)

	var completed: Array = await request_node.request_completed
	request_node.queue_free()
	if completed.size() != 4:
		return _error("request_result_invalid", "模型请求完成信号结构无效。")
	var result_code: int = int(completed[0])
	var response_code: int = int(completed[1])
	var response_headers: PackedStringArray = completed[2] as PackedStringArray
	var body: PackedByteArray = completed[3] as PackedByteArray
	if result_code != HTTPRequest.RESULT_SUCCESS:
		return _error("request_transport_failed", "模型请求传输失败，HTTPRequest result=%d。" % result_code)
	if response_code < 200 or response_code >= 300:
		return {
			"ok": false,
			"error_code": "request_http_failed",
			"message": "模型服务返回 HTTP %d。" % response_code,
			"response_code": response_code,
			"response_headers": response_headers,
			"response_body": body.get_string_from_utf8().left(2000),
		}
	return _parse_chat_completion(body)


func _parse_chat_completion(body: PackedByteArray) -> Dictionary:
	var text: String = body.get_string_from_utf8()
	var json: JSON = JSON.new()
	var parse_error: Error = json.parse(text)
	if parse_error != OK or not json.data is Dictionary:
		return _error("response_json_invalid", "模型服务返回的响应不是有效 JSON。")
	var document: Dictionary = json.data as Dictionary
	if not document.has("choices") or not document["choices"] is Array:
		return _error("response_shape_invalid", "模型响应缺少 choices 数组。")
	var choices: Array = document["choices"] as Array
	if choices.is_empty() or not choices[0] is Dictionary:
		return _error("response_shape_invalid", "模型响应 choices[0] 无效。")
	var choice: Dictionary = choices[0] as Dictionary
	if not choice.has("message") or not choice["message"] is Dictionary:
		return _error("response_shape_invalid", "模型响应缺少 choices[0].message。")
	var message: Dictionary = choice["message"] as Dictionary
	if not message.has("content") or not message["content"] is String:
		return _error("response_shape_invalid", "模型响应缺少字符串 choices[0].message.content。")
	var content: String = String(message["content"]).strip_edges()
	var content_json: JSON = JSON.new()
	var content_parse_error: Error = content_json.parse(content)
	if content_parse_error != OK or not content_json.data is Dictionary:
		return {
			"ok": false,
			"error_code": "model_output_json_invalid",
			"message": "模型没有返回严格 JSON 对象。",
			"raw_content": content.left(4000),
		}
	return {
		"ok": true,
		"data": (content_json.data as Dictionary).duplicate(true),
		"usage": document.get("usage", {}),
		"model": String(document.get("model", "")),
	}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
