## 来电内容文件的最小读取入口。
##
## 此类只负责 UTF-8 文本读取和标准 JSON 解析；内容结构与业务字段必须交由
## ContentValidator 校验，避免读取层擅自补齐或改变内容语义。
extends RefCounted
class_name ContentLoader


func load_json(source_path: String) -> Dictionary:
	if source_path.strip_edges().is_empty():
		return _make_error(source_path, "", "$", "invalid_source_path", "内容文件路径不能为空。")
	if not FileAccess.file_exists(source_path):
		return _make_error(source_path, "", "$", "file_not_found", "找不到内容文件。")

	var file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		return _make_error(
			source_path,
			"",
			"$",
			"file_open_failed",
			"无法以只读方式打开内容文件，错误码=%d。" % int(FileAccess.get_open_error())
		)
	var source_text: String = file.get_as_text()
	file.close()

	var parser: JSON = JSON.new()
	var parse_error: Error = parser.parse(source_text)
	if parse_error != OK:
		return _make_error(
			source_path,
			"",
			"$",
			"json_syntax_error",
			"JSON 解析失败（第 %d 行）：%s。" % [parser.get_error_line(), parser.get_error_message()]
		)

	return {
		"ok": true,
		"source_path": source_path,
		"data": parser.data,
	}


func _make_error(
	source_path: String,
	event_id: String,
	field_name: String,
	error_code: String,
	message: String
) -> Dictionary:
	return {
		"ok": false,
		"source_path": source_path,
		"event_id": event_id,
		"field": field_name,
		"error_code": error_code,
		"message": message,
	}
