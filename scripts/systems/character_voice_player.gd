class_name CharacterVoicePlayerService
extends Node
## 电话人物配音只读取 StoryEngine 发出的当前对白快照。
##
## 角色与音色的绑定完全由独立人物信息表提供，避免按 UI 名称或中文对白猜测人物。
## 每次快照替换都会停止旧音；当素材短于本句的显示节奏时，手动插入静音而非启用
## AudioStream 自带循环，以保证循环之间固定留出 0.5 秒线路空白。

const UI_PHONE_BUS_NAME: StringName = &"UIPhone"
const DEFAULT_MANIFEST_PATH: String = "res://data/characters/character_voice_manifest.json"
const MANIFEST_KIND: String = "character_voice_manifest"
const MANIFEST_VERSION: int = 1
const DIALOGUE_CHARACTERS_PER_SECOND: float = 34.0
const LOOP_SILENCE_SECONDS: float = 0.5
const END_MARKER: String = "[ 对话结束 ]"
const REQUIRED_EVENT_IDS: PackedStringArray = [
	"call_01_warren", "call_02_wrong_number", "call_03_martha", "call_04_dog_walker",
	"call_05_cinema", "call_06_trucker", "call_07_ronnie_1", "call_08_score",
	"call_09_southbound", "call_10_ronnie_2", "call_11_final_amy",
]

var _manifest_path: String = DEFAULT_MANIFEST_PATH
var _character_by_id: Dictionary = {}
var _character_by_event_id: Dictionary = {}
var _stream_by_path: Dictionary = {}
var _bound_story_engine: RefCounted = null
var _voice_player: AudioStreamPlayer = null
var _active_event_id: String = ""
var _active_character_id: String = ""
var _active_plan: Array[Dictionary] = []
var _segment_index: int = -1
var _segment_elapsed_seconds: float = 0.0
var _voice_start_count: int = 0
var _voice_stop_count: int = 0
var _has_reported_missing_bus: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _exit_tree() -> void:
	unbind_story_engine()
	_release_player()


func _process(delta: float) -> void:
	if _segment_index < 0 or _segment_index >= _active_plan.size():
		return
	_segment_elapsed_seconds += maxf(delta, 0.0)
	var segment: Dictionary = _active_plan[_segment_index]
	var duration: float = float(segment["duration_seconds"])
	if _segment_elapsed_seconds + 0.0001 < duration:
		return
	_advance_segment()


## Main 在开始/读取提交前调用。表、事件覆盖与素材都必须一次性通过，不能让未知
## 角色静默降级为任意声音。
func prepare_manifest(manifest_path: String = DEFAULT_MANIFEST_PATH) -> Dictionary:
	var normalized_path: String = manifest_path.strip_edges()
	if normalized_path.is_empty():
		return _make_error("invalid_manifest_path", "人物配音信息表路径不能为空。")
	var load_result: Dictionary = _load_json(normalized_path)
	if not bool(load_result.get("ok", false)):
		return load_result
	var validation: Dictionary = _validate_manifest(load_result["data"], normalized_path)
	if not bool(validation.get("ok", false)):
		return validation
	_stop_playback()
	_manifest_path = normalized_path
	_character_by_id = validation["character_by_id"] as Dictionary
	_character_by_event_id = validation["character_by_event_id"] as Dictionary
	_stream_by_path = validation["stream_by_path"] as Dictionary
	return {"ok": true, "character_count": _character_by_id.size(), "event_count": _character_by_event_id.size()}


func bind_story_engine(story_engine: RefCounted, sync_initial_dialogue: bool = true) -> Dictionary:
	if _character_by_event_id.is_empty():
		var manifest_result: Dictionary = prepare_manifest(_manifest_path)
		if not bool(manifest_result.get("ok", false)):
			return manifest_result
	if story_engine == null or not story_engine.has_signal(&"dialogue_changed") or not story_engine.has_signal(&"ending_forced") or not story_engine.has_method(&"get_active_dialogue_snapshot"):
		return _make_error("invalid_story_engine_contract", "剧情运行时缺少电话对白配音所需的公开状态。")
	if _bound_story_engine == story_engine:
		if sync_initial_dialogue:
			var existing_sync_result: Dictionary = _sync_from_bound_story()
			if not bool(existing_sync_result.get("ok", false)):
				return existing_sync_result
		return {"ok": true, "already_bound": true}
	unbind_story_engine()
	_bound_story_engine = story_engine
	var dialogue_callback: Callable = Callable(self, "_on_dialogue_changed")
	var dialogue_result: Error = _bound_story_engine.connect(&"dialogue_changed", dialogue_callback)
	if dialogue_result != OK:
		_bound_story_engine = null
		return _make_error("dialogue_connect_failed", "无法监听电话对白，错误码=%d。" % dialogue_result)
	var ending_callback: Callable = Callable(self, "_on_ending_forced")
	var ending_result: Error = _bound_story_engine.connect(&"ending_forced", ending_callback)
	if ending_result != OK:
		_bound_story_engine.disconnect(&"dialogue_changed", dialogue_callback)
		_bound_story_engine = null
		return _make_error("ending_connect_failed", "无法监听夜班收束，错误码=%d。" % ending_result)
	if sync_initial_dialogue:
		var sync_result: Dictionary = _sync_from_bound_story()
		if not bool(sync_result.get("ok", false)):
			unbind_story_engine()
			return sync_result
	return {"ok": true, "already_bound": false}


func unbind_story_engine() -> void:
	_stop_playback()
	if _bound_story_engine == null:
		return
	var dialogue_callback: Callable = Callable(self, "_on_dialogue_changed")
	if _bound_story_engine.is_connected(&"dialogue_changed", dialogue_callback):
		_bound_story_engine.disconnect(&"dialogue_changed", dialogue_callback)
	var ending_callback: Callable = Callable(self, "_on_ending_forced")
	if _bound_story_engine.is_connected(&"ending_forced", ending_callback):
		_bound_story_engine.disconnect(&"ending_forced", ending_callback)
	_bound_story_engine = null


## Headless 和专项均通过此只读快照检验节奏，而不依赖声卡是否真的输出。
func get_playback_snapshot() -> Dictionary:
	return {
		"ok": true,
		"manifest_path": _manifest_path,
		"manifest_loaded": not _character_by_event_id.is_empty(),
		"bound": _bound_story_engine != null,
		"bus_name": String(UI_PHONE_BUS_NAME),
		"active_event_id": _active_event_id,
		"active_character_id": _active_character_id,
		"is_playing": _voice_player.playing if _voice_player != null and is_instance_valid(_voice_player) else false,
		"voice_start_count": _voice_start_count,
		"voice_stop_count": _voice_stop_count,
		"segment_index": _segment_index,
		"plan": _active_plan.duplicate(true),
		"character_by_event_id": _character_by_event_id.duplicate(true),
	}


func get_character_snapshot_for_event(event_id: String) -> Dictionary:
	if not _character_by_event_id.has(event_id):
		return {}
	var character: Dictionary = _character_by_event_id[event_id] as Dictionary
	var copy: Dictionary = character.duplicate(true)
	copy.make_read_only()
	return copy


func build_playback_plan(event_id: String, dialogue_text: String) -> Dictionary:
	if not _character_by_event_id.has(event_id):
		return _make_error("unknown_voice_event", "人物配音表未覆盖来电事件：%s。" % event_id)
	var character: Dictionary = _character_by_event_id[event_id] as Dictionary
	var voice_path: String = String(character["voice_stream_path"])
	if not _stream_by_path.has(voice_path):
		return _make_error("voice_stream_not_loaded", "人物配音素材未加载：%s。" % voice_path)
	var stream: AudioStream = _stream_by_path[voice_path] as AudioStream
	var stream_length: float = stream.get_length()
	if stream_length <= 0.0:
		return _make_error("voice_stream_invalid_length", "人物配音素材时长无效：%s。" % voice_path)
	var character_count: int = _count_dialogue_characters(dialogue_text)
	var target_seconds: float = float(character_count) / DIALOGUE_CHARACTERS_PER_SECOND
	var segments: Array[Dictionary] = []
	var remaining: float = target_seconds
	while remaining > 0.0001:
		var audio_duration: float = minf(stream_length, remaining)
		segments.append({"kind": "audio", "duration_seconds": audio_duration, "stream_path": voice_path})
		remaining -= audio_duration
		if remaining > 0.0001:
			# 静音属于这句对白的总时长：若它不计入，长句会比 34 字/秒的
			# 文字呈现越拖越长。只在仍有剩余时插入，最后一段绝不额外留白。
			var silence_duration: float = minf(LOOP_SILENCE_SECONDS, remaining)
			segments.append({"kind": "silence", "duration_seconds": silence_duration})
			remaining -= silence_duration
	return {
		"ok": true,
		"event_id": event_id,
		"character_id": String(character["character_id"]),
		"voice_stream_path": voice_path,
		"character_count": character_count,
		"target_duration_seconds": target_seconds,
		"stream_length_seconds": stream_length,
		"segments": segments,
	}


func stop_and_release_for_verification() -> void:
	unbind_story_engine()
	_release_player()
	_voice_start_count = 0
	_voice_stop_count = 0


## 读取存档的 staging 先完成无声绑定和预检；页面正式提交后才显式同步旧对白，
## 避免隐藏读取过程留下听觉副作用。返回失败让 Main 拒绝提交运行时。
func sync_from_bound_story() -> Dictionary:
	return _sync_from_bound_story()


## 此检查不启动播放器，供读取存档的隐藏 staging 在提交前确认当前对白、人物映射
## 与 UIPhone 总线都可用。不能把运行时故障留到玩家已经离开读取槽位页之后。
func validate_bound_story_dialogue() -> Dictionary:
	if _bound_story_engine == null:
		return _make_error("story_engine_not_bound", "人物配音尚未绑定剧情运行时。")
	var snapshot_value: Variant = _bound_story_engine.call(&"get_active_dialogue_snapshot")
	if not snapshot_value is Dictionary:
		return _make_error("invalid_dialogue_snapshot", "剧情运行时未返回有效电话对白快照。")
	var snapshot: Dictionary = snapshot_value as Dictionary
	if snapshot.is_empty():
		return {"ok": true, "has_active_dialogue": false}
	if typeof(snapshot.get("event_id")) != TYPE_STRING or typeof(snapshot.get("text")) != TYPE_STRING:
		return _make_error("invalid_dialogue_snapshot", "电话对白快照缺少 event_id 或 text。")
	var plan_result: Dictionary = build_playback_plan(String(snapshot["event_id"]), String(snapshot["text"]))
	if not bool(plan_result.get("ok", false)):
		return plan_result
	var player_result: Dictionary = _ensure_player()
	if not bool(player_result.get("ok", false)):
		return player_result
	return {"ok": true, "has_active_dialogue": true}


func _on_dialogue_changed(snapshot: Dictionary) -> Dictionary:
	_stop_playback()
	if snapshot.is_empty():
		return {"ok": true, "has_active_dialogue": false}
	if typeof(snapshot.get("event_id")) != TYPE_STRING or typeof(snapshot.get("text")) != TYPE_STRING:
		push_error("[音频][character_voice_invalid_dialogue] 对白快照缺少 event_id 或 text。")
		return _make_error("invalid_dialogue_snapshot", "电话对白快照缺少 event_id 或 text。")
	var plan_result: Dictionary = build_playback_plan(String(snapshot["event_id"]), String(snapshot["text"]))
	if not bool(plan_result.get("ok", false)):
		push_error("[音频][character_voice_plan_failed] %s" % String(plan_result.get("message", "未知原因。")))
		return plan_result
	return _start_plan(plan_result)


func _on_ending_forced(_end_tick: int) -> void:
	_stop_playback()


func _sync_from_bound_story() -> Dictionary:
	_stop_playback()
	if _bound_story_engine == null:
		return _make_error("story_engine_not_bound", "人物配音尚未绑定剧情运行时。")
	var snapshot_value: Variant = _bound_story_engine.call(&"get_active_dialogue_snapshot")
	if not snapshot_value is Dictionary:
		return _make_error("invalid_dialogue_snapshot", "剧情运行时未返回有效电话对白快照。")
	return _on_dialogue_changed(snapshot_value as Dictionary)


func _start_plan(plan_result: Dictionary) -> Dictionary:
	_active_event_id = String(plan_result["event_id"])
	_active_character_id = String(plan_result["character_id"])
	_active_plan = plan_result["segments"] as Array[Dictionary]
	if _active_plan.is_empty():
		return _make_error("empty_playback_plan", "人物配音播放计划为空。")
	_segment_index = 0
	_segment_elapsed_seconds = 0.0
	return _start_current_segment()


func _advance_segment() -> void:
	if _voice_player != null and is_instance_valid(_voice_player):
		_voice_player.stop()
	_segment_index += 1
	_segment_elapsed_seconds = 0.0
	if _segment_index >= _active_plan.size():
		_active_plan.clear()
		_segment_index = -1
		_active_event_id = ""
		_active_character_id = ""
		return
	var start_result: Dictionary = _start_current_segment()
	if not bool(start_result.get("ok", false)):
		push_error("[音频][character_voice_segment_advance_failed] %s" % String(start_result.get("message", "未知原因。")))


func _start_current_segment() -> Dictionary:
	var segment: Dictionary = _active_plan[_segment_index]
	if String(segment["kind"]) != "audio":
		return {"ok": true, "is_silence": true}
	var player_result: Dictionary = _ensure_player()
	if not bool(player_result.get("ok", false)):
		push_error("[音频][character_voice_start_failed] %s" % String(player_result.get("message", "未知原因。")))
		_stop_playback()
		return player_result
	var stream_path: String = String(segment["stream_path"])
	var stream: AudioStream = _stream_by_path[stream_path] as AudioStream
	_voice_player.stream = stream
	_voice_start_count += 1
	if not _is_non_playback_environment():
		_voice_player.play()
	return {"ok": true, "is_silence": false}


func _stop_playback() -> void:
	var had_active_plan: bool = not _active_plan.is_empty() or not _active_event_id.is_empty()
	if _voice_player != null and is_instance_valid(_voice_player):
		_voice_player.stop()
	_active_event_id = ""
	_active_character_id = ""
	_active_plan.clear()
	_segment_index = -1
	_segment_elapsed_seconds = 0.0
	if had_active_plan:
		_voice_stop_count += 1


func _ensure_player() -> Dictionary:
	if AudioServer.get_bus_index(UI_PHONE_BUS_NAME) < 0:
		if not _has_reported_missing_bus:
			_has_reported_missing_bus = true
			push_error("[音频][character_voice_missing_bus] 缺少 UIPhone Audio Bus，无法播放人物配音。")
		return _make_error("missing_ui_phone_bus", "缺少 UIPhone Audio Bus。")
	if _voice_player != null and is_instance_valid(_voice_player):
		return {"ok": true}
	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "CharacterVoicePlayer"
	_voice_player.bus = UI_PHONE_BUS_NAME
	add_child(_voice_player)
	return {"ok": true}


func _release_player() -> void:
	if _voice_player == null or not is_instance_valid(_voice_player):
		_voice_player = null
		return
	_voice_player.stop()
	_voice_player.stream = null
	if _voice_player.get_parent() == self:
		remove_child(_voice_player)
	_voice_player.free()
	_voice_player = null


func _validate_manifest(document: Variant, source_path: String) -> Dictionary:
	if not document is Dictionary:
		return _manifest_error(source_path, "", "$", "invalid_top_level_type", "人物配音信息表顶层必须是对象。")
	var root: Dictionary = document as Dictionary
	var required_fields: PackedStringArray = ["format_version", "kind", "characters"]
	if root.size() != required_fields.size():
		return _manifest_error(source_path, "", "$", "invalid_top_level_fields", "人物配音信息表字段缺失或包含未知字段。")
	for field_name: String in required_fields:
		if not root.has(field_name):
			return _manifest_error(source_path, "", field_name, "missing_field", "人物配音信息表缺少字段：%s。" % field_name)
	if not _is_exact_integer(root["format_version"]) or int(root["format_version"]) != MANIFEST_VERSION:
		return _manifest_error(source_path, "", "format_version", "invalid_version", "format_version 必须精确为整数 1。")
	if typeof(root["kind"]) != TYPE_STRING or String(root["kind"]) != MANIFEST_KIND:
		return _manifest_error(source_path, "", "kind", "invalid_kind", "kind 必须精确为 character_voice_manifest。")
	if not root["characters"] is Array:
		return _manifest_error(source_path, "", "characters", "invalid_characters", "characters 必须是数组。")
	var character_by_id: Dictionary = {}
	var character_by_event_id: Dictionary = {}
	var stream_by_path: Dictionary = {}
	for raw_character: Variant in root["characters"] as Array:
		if not raw_character is Dictionary:
			return _manifest_error(source_path, "", "characters", "invalid_character", "characters 中每项必须是对象。")
		var character: Dictionary = raw_character as Dictionary
		var fields: PackedStringArray = ["character_id", "display_name", "profile", "event_ids", "voice_stream_path"]
		if character.size() != fields.size():
			return _manifest_error(source_path, "", "characters", "invalid_character_fields", "人物记录字段缺失或包含未知字段。")
		for field_name: String in fields:
			if not character.has(field_name):
				return _manifest_error(source_path, "", "characters.%s" % field_name, "missing_character_field", "人物记录缺少字段：%s。" % field_name)
		if typeof(character["character_id"]) != TYPE_STRING or not _is_stable_id(String(character["character_id"])):
			return _manifest_error(source_path, "", "characters.character_id", "invalid_character_id", "人物 character_id 必须是英文 snake_case。")
		var character_id: String = String(character["character_id"])
		if character_by_id.has(character_id):
			return _manifest_error(source_path, character_id, "characters.character_id", "duplicate_character_id", "人物 character_id 重复。")
		if typeof(character["display_name"]) != TYPE_STRING or String(character["display_name"]).strip_edges().is_empty() or typeof(character["profile"]) != TYPE_STRING or String(character["profile"]).strip_edges().is_empty():
			return _manifest_error(source_path, character_id, "characters.profile", "invalid_character_information", "人物名称和个人信息必须是非空文本。")
		if not character["event_ids"] is Array or (character["event_ids"] as Array).is_empty():
			return _manifest_error(source_path, character_id, "characters.event_ids", "invalid_event_ids", "人物必须绑定至少一通电话。")
		if typeof(character["voice_stream_path"]) != TYPE_STRING or not String(character["voice_stream_path"]).begins_with("res://"):
			return _manifest_error(source_path, character_id, "characters.voice_stream_path", "invalid_voice_path", "配音路径必须是 res:// 资源路径。")
		var voice_path: String = String(character["voice_stream_path"])
		var stream: AudioStream = ResourceLoader.load(voice_path) as AudioStream
		if stream == null or stream.get_length() <= 0.0:
			return _manifest_error(source_path, character_id, "characters.voice_stream_path", "voice_stream_unavailable", "人物配音素材不存在、未导入或时长无效：%s。" % voice_path)
		stream_by_path[voice_path] = stream
		var normalized_character: Dictionary = character.duplicate(true)
		character_by_id[character_id] = normalized_character
		for raw_event_id: Variant in character["event_ids"] as Array:
			if typeof(raw_event_id) != TYPE_STRING or not REQUIRED_EVENT_IDS.has(String(raw_event_id)):
				return _manifest_error(source_path, character_id, "characters.event_ids", "unknown_event_id", "人物绑定了未知电话事件：%s。" % String(raw_event_id))
			var event_id: String = String(raw_event_id)
			if character_by_event_id.has(event_id):
				return _manifest_error(source_path, character_id, "characters.event_ids", "duplicate_event_binding", "电话事件不能绑定多个角色：%s。" % event_id)
			character_by_event_id[event_id] = normalized_character
	if character_by_event_id.size() != REQUIRED_EVENT_IDS.size():
		return _manifest_error(source_path, "", "characters.event_ids", "incomplete_event_coverage", "人物配音表必须精确覆盖全部 11 通电话。")
	for required_event_id: String in REQUIRED_EVENT_IDS:
		if not character_by_event_id.has(required_event_id):
			return _manifest_error(source_path, "", "characters.event_ids", "missing_event_binding", "人物配音表缺少电话事件：%s。" % required_event_id)
	var ronnie_first: Dictionary = character_by_event_id["call_07_ronnie_1"] as Dictionary
	var ronnie_second: Dictionary = character_by_event_id["call_10_ronnie_2"] as Dictionary
	if String(ronnie_first["character_id"]) != "ronnie_hart" or String(ronnie_first["voice_stream_path"]) != String(ronnie_second["voice_stream_path"]):
		return _manifest_error(source_path, "ronnie_hart", "characters.event_ids", "ronnie_voice_mismatch", "罗尼的两通电话必须绑定同一人物与同一配音。")
	return {"ok": true, "character_by_id": character_by_id, "character_by_event_id": character_by_event_id, "stream_by_path": stream_by_path}


func _count_dialogue_characters(dialogue_text: String) -> int:
	var cleaned: String = dialogue_text.replace(END_MARKER, "")
	var count: int = 0
	for character: String in cleaned:
		if not character.strip_edges().is_empty():
			count += 1
	return count


func _load_json(source_path: String) -> Dictionary:
	if not FileAccess.file_exists(source_path):
		return _manifest_error(source_path, "", "$", "file_not_found", "找不到人物配音信息表。")
	var file: FileAccess = FileAccess.open(source_path, FileAccess.READ)
	if file == null:
		return _manifest_error(source_path, "", "$", "file_open_failed", "无法读取人物配音信息表，错误码=%d。" % int(FileAccess.get_open_error()))
	var source_text: String = file.get_as_text()
	file.close()
	var parser := JSON.new()
	var parse_result: Error = parser.parse(source_text)
	if parse_result != OK:
		return _manifest_error(source_path, "", "$", "json_syntax_error", "人物配音信息表 JSON 解析失败（第 %d 行）：%s。" % [parser.get_error_line(), parser.get_error_message()])
	return {"ok": true, "data": parser.data}


func _is_stable_id(value: String) -> bool:
	return value.length() >= 3 and value.is_valid_identifier() and value == value.to_lower() and not value.begins_with("_")


func _is_exact_integer(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or (typeof(value) == TYPE_FLOAT and is_equal_approx(float(value), floorf(float(value))))


func _is_non_playback_environment() -> bool:
	return DisplayServer.get_name().to_lower() == "headless" or AudioServer.get_driver_name().to_lower() == "dummy"


func _make_error(error_code: String, message: String) -> Dictionary:
	return {"ok": false, "error_code": error_code, "message": message}


func _manifest_error(source_path: String, character_id: String, field_name: String, error_code: String, message: String) -> Dictionary:
	return {"ok": false, "source_path": source_path, "character_id": character_id, "field": field_name, "error_code": error_code, "message": message}
