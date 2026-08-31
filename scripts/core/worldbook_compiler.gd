class_name WorldBookCompiler
extends RefCounted

## 把已经通过 WorldBookValidator 的作者数据编译成当前确定性 Runtime 可消费的定义。
## Compiler 不执行 WorldBook 文本，不加载脚本/场景，也不授予模型任何世界写权限。

const COMPILED_FORMAT_VERSION: int = 1
const RUNTIME_CONTENT_FORMAT_VERSION: int = 2
const RUNTIME_CONTENT_KIND: String = "test_night_story"


func compile(validation_result: Dictionary) -> Dictionary:
	if not bool(validation_result.get("ok", false)):
		return _error("worldbook_not_validated", "WorldBookCompiler 只接受 WorldBookValidator 成功结果。")
	if not validation_result.has("manifest") or not validation_result["manifest"] is Dictionary:
		return _error("worldbook_manifest_missing", "WorldBookValidator 成功结果缺少 manifest。")
	if not validation_result.has("worldbook") or not validation_result["worldbook"] is Dictionary:
		return _error("worldbook_data_missing", "WorldBookValidator 成功结果缺少 worldbook。")
	var manifest: Dictionary = validation_result["manifest"] as Dictionary
	var worldbook: Dictionary = validation_result["worldbook"] as Dictionary
	var worldbook_id: String = String(validation_result.get("worldbook_id", ""))
	if worldbook_id.is_empty() or String(manifest.get("worldbook_id", "")) != worldbook_id or String(worldbook.get("worldbook_id", "")) != worldbook_id:
		return _error("worldbook_id_mismatch", "编译前 worldbook_id 必须在 Validator 结果、manifest 与 worldbook 中一致。")
	var worldbook_version_value: Variant = manifest.get("worldbook_version")
	if typeof(worldbook_version_value) != TYPE_INT or int(worldbook_version_value) < 1:
		return _error("worldbook_version_invalid", "编译前 manifest.worldbook_version 必须是 Validator 规范化后的正整数。")
	var worldbook_version: int = int(worldbook_version_value)

	# 保持 StoryEngine Agent Dialogue v2 的已验证输入合同。WorldBook 特有的 lore、
	# hidden truths、goals、relationships、opportunities 不进入 StoryEngine 世界事实表。
	var runtime_story: Dictionary = {
		"content_format_version": RUNTIME_CONTENT_FORMAT_VERSION,
		"content_kind": RUNTIME_CONTENT_KIND,
		"conditions": (worldbook["conditions"] as Array).duplicate(true),
		"events": (worldbook["events"] as Array).duplicate(true),
		"checklist_entries": (worldbook["checklist_entries"] as Array).duplicate(true),
		"news_entries": (worldbook["news_entries"] as Array).duplicate(true),
		"messages": (worldbook["messages"] as Array).duplicate(true),
		"broadcast_tasks": (worldbook["broadcast_tasks"] as Array).duplicate(true),
		"actors": (worldbook["actors"] as Array).duplicate(true),
		"statements": (worldbook["statements"] as Array).duplicate(true),
		"facts": (worldbook["facts"] as Array).duplicate(true),
	}
	var director_lore: Dictionary = {
		"worldbook_id": worldbook_id,
		"lore": (worldbook["lore"] as Dictionary).duplicate(true),
		"hidden_truths": (worldbook["hidden_truths"] as Array).duplicate(true),
		"relationships": (worldbook["relationships"] as Array).duplicate(true),
		"goals": (worldbook["goals"] as Array).duplicate(true),
		"narrative_constraints": (worldbook["narrative_constraints"] as Dictionary).duplicate(true),
	}
	var compiled: Dictionary = {
		"compiled_format_version": COMPILED_FORMAT_VERSION,
		"worldbook_id": worldbook_id,
		"worldbook_version": worldbook_version,
		"manifest": manifest.duplicate(true),
		"runtime_story": runtime_story,
		"actors": (worldbook["actors"] as Array).duplicate(true),
		"statements": (worldbook["statements"] as Array).duplicate(true),
		"facts": (worldbook["facts"] as Array).duplicate(true),
		"conditions": (worldbook["conditions"] as Array).duplicate(true),
		"events": (worldbook["events"] as Array).duplicate(true),
		"tasks": (worldbook["broadcast_tasks"] as Array).duplicate(true),
		"opportunities": (worldbook["opportunities"] as Array).duplicate(true),
		"director_lore": director_lore,
	}
	var executable_result: Dictionary = _reject_executable_fields(compiled, "compiled")
	if not bool(executable_result.get("ok", false)):
		return executable_result
	return {"ok": true, "compiled": compiled}


func _reject_executable_fields(value: Variant, path: String) -> Dictionary:
	if value is Dictionary:
		var dictionary_value: Dictionary = value as Dictionary
		for raw_key: Variant in dictionary_value.keys():
			var key: String = String(raw_key)
			if ["script", "script_path", "scene", "scene_path", "code", "plugin", "executable"].has(key):
				return _error("executable_worldbook_field_forbidden", "CompiledWorldDefinition 不允许可执行字段：%s.%s。" % [path, key])
			var child_result: Dictionary = _reject_executable_fields(dictionary_value[raw_key], "%s.%s" % [path, key])
			if not bool(child_result.get("ok", false)):
				return child_result
	elif value is Array:
		var array_value: Array = value as Array
		for index: int in range(array_value.size()):
			var child_result: Dictionary = _reject_executable_fields(array_value[index], "%s[%d]" % [path, index])
			if not bool(child_result.get("ok", false)):
				return child_result
	return {"ok": true}


func _error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}
