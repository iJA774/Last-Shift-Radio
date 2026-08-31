extends SceneTree

## 人物电话配音专项：覆盖信息表、音色映射、文本长度计划与运行时打断边界。

class DialogueStub extends RefCounted:
	signal dialogue_changed(snapshot: Dictionary)
	signal ending_forced(end_tick: int)
	var active_snapshot: Dictionary = {}

	func get_active_dialogue_snapshot() -> Dictionary:
		return active_snapshot.duplicate(true)


const EXPECTED_EVENT_IDS: PackedStringArray = [
	"call_01_warren", "call_02_wrong_number", "call_03_martha", "call_04_dog_walker",
	"call_05_cinema", "call_06_trucker", "call_07_ronnie_1", "call_08_score",
	"call_09_southbound", "call_10_ronnie_2", "call_11_final_amy",
]
const EXPECTED_IDENTITIES: Dictionary = {
	"call_01_warren": {"caller": "沃伦", "speaker": "沃伦"},
	"call_02_wrong_number": {"caller": "错号来电", "speaker": "夜班烘焙工"},
	"call_03_martha": {"caller": "玛莎·克莱恩", "speaker": "玛莎·克莱恩"},
	"call_04_dog_walker": {"caller": "河边遛狗者", "speaker": "河边遛狗者"},
	"call_05_cinema": {"caller": "星光小影院", "speaker": "星光小影院值班员"},
	"call_06_trucker": {"caller": "东侧卡车司机", "speaker": "东侧卡车司机"},
	"call_07_ronnie_1": {"caller": "罗尼·哈特", "speaker": "罗尼·哈特"},
	"call_08_score": {"caller": "西仓门卫", "speaker": "西仓门卫"},
	"call_09_southbound": {"caller": "路过的年轻司机", "speaker": "路过的年轻司机"},
	"call_10_ronnie_2": {"caller": "罗尼·哈特", "speaker": "罗尼·哈特"},
	"call_11_final_amy": {"caller": "艾米", "speaker": "艾米"},
}
const TEST_NIGHT_STORY_PATH: String = "res://data/story/test_night_story.json"

var _has_failed: bool = false


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	await process_frame
	var player: Node = root.get_node_or_null(NodePath("CharacterVoicePlayer")) as Node
	_assert_true(player != null, "项目必须注册持久化 CharacterVoicePlayer 自动加载节点。")
	if player == null:
		_finish()
		return
	_assert_true(player.has_method(&"prepare_manifest") and player.has_method(&"bind_story_engine") and player.has_method(&"unbind_story_engine"), "人物配音服务必须公开加载和运行时绑定接口。")
	player.call(&"stop_and_release_for_verification")
	_assert_ok(player.call(&"prepare_manifest"), "人物信息表、全部事件映射和已导入 MP3 必须一次性通过校验。")
	_test_manifest_mapping(player)
	_test_playback_plan(player)
	_test_runtime_interruptions(player)
	player.call(&"stop_and_release_for_verification")
	_finish()


func _test_manifest_mapping(player: Node) -> void:
	var snapshot: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(bool(snapshot.get("manifest_loaded", false)), "人物配音表必须在专项中处于已加载状态。")
	_assert_equal(String(snapshot.get("bus_name", "")), "UIPhone", "人物对白必须路由至 UIPhone。")
	var mapping: Dictionary = snapshot.get("character_by_event_id", {}) as Dictionary
	var story_identities: Dictionary = _load_story_identities()
	_assert_equal(mapping.size(), EXPECTED_EVENT_IDS.size(), "人物配音表必须精确覆盖 11 通电话。")
	for event_id: String in EXPECTED_EVENT_IDS:
		_assert_true(mapping.has(event_id), "人物配音表缺少事件映射：%s。" % event_id)
		if not mapping.has(event_id):
			continue
		var character: Dictionary = mapping[event_id] as Dictionary
		var expected_identity: Dictionary = EXPECTED_IDENTITIES[event_id] as Dictionary
		var story_identity: Dictionary = story_identities.get(event_id, {}) as Dictionary
		_assert_equal(String(story_identity.get("caller", "")), String(expected_identity["caller"]), "测试剧情的来电登记名不得与人物审计基线偏离。")
		_assert_equal(String(story_identity.get("speaker", "")), String(expected_identity["speaker"]), "测试剧情的对白说话人不得与人物审计基线偏离。")
		var display_name: String = String(character.get("display_name", ""))
		_assert_true(display_name == String(story_identity.get("caller", "")) or display_name == String(story_identity.get("speaker", "")), "事件 %s 的人物表显示名必须与实际来电登记名或对白说话人一致，防止串音。" % event_id)
		_assert_equal(String(character.get("character_id", "")), String(story_identity.get("voice_profile_id", "")), "事件 %s 必须绑定 Actor 定义声明的 voice_profile_id。" % event_id)
		var stream_path: String = String(character.get("voice_stream_path", ""))
		var stream: AudioStream = load(stream_path) as AudioStream
		_assert_true(stream != null and stream.get_length() > 0.0, "事件 %s 绑定的配音必须已导入且有正时长。" % event_id)
	var ronnie_one: Dictionary = mapping.get("call_07_ronnie_1", {}) as Dictionary
	var ronnie_two: Dictionary = mapping.get("call_10_ronnie_2", {}) as Dictionary
	_assert_equal(String(ronnie_one.get("character_id", "")), "ronnie_hart", "罗尼首通必须绑定罗尼人物档案。")
	_assert_equal(String(ronnie_one.get("voice_stream_path", "")), String(ronnie_two.get("voice_stream_path", "")), "罗尼两通电话必须严格使用同一配音。")


func _test_playback_plan(player: Node) -> void:
	var short_plan: Dictionary = player.call(&"build_playback_plan", "call_01_warren", "简短一句") as Dictionary
	_assert_ok(short_plan, "短对白必须能生成播放计划。")
	var short_segments: Array = short_plan.get("segments", []) as Array
	_assert_equal(short_segments.size(), 1, "短对白不应插入循环静音。")
	if not short_segments.is_empty():
		_assert_equal(String((short_segments[0] as Dictionary).get("kind", "")), "audio", "短对白计划必须从音频段开始。")
		_assert_true(absf(float((short_segments[0] as Dictionary).get("duration_seconds", -1.0)) - float(short_plan.get("target_duration_seconds", 0.0))) < 0.001, "短对白应在目标时长处截停。")
	var long_text: String = ""
	for index: int in 700:
		long_text += "长"
	var long_plan: Dictionary = player.call(&"build_playback_plan", "call_01_warren", long_text) as Dictionary
	_assert_ok(long_plan, "长对白必须能生成循环播放计划。")
	var long_segments: Array = long_plan.get("segments", []) as Array
	var audio_count: int = 0
	var silence_count: int = 0
	var planned_total_seconds: float = 0.0
	for segment_value: Variant in long_segments:
		var segment: Dictionary = segment_value as Dictionary
		planned_total_seconds += float(segment.get("duration_seconds", 0.0))
		if String(segment.get("kind", "")) == "audio":
			audio_count += 1
		elif String(segment.get("kind", "")) == "silence":
			silence_count += 1
			_assert_true(absf(float(segment.get("duration_seconds", 0.0)) - 0.5) < 0.001, "每次循环间必须插入 0.5 秒静音。")
	_assert_true(audio_count >= 2 and silence_count == audio_count - 1, "长对白必须按音频、静音、音频的顺序循环，末尾不得多留静音。")
	_assert_true(absf(planned_total_seconds - float(long_plan.get("target_duration_seconds", 0.0))) < 0.001, "音频与静音总时长必须严格匹配按 34 字/秒计算的当前对白时长。")


func _test_runtime_interruptions(player: Node) -> void:
	var story := DialogueStub.new()
	_assert_ok(player.call(&"bind_story_engine", story), "人物配音必须能绑定权威对白信号。")
	story.dialogue_changed.emit({"event_id": "call_07_ronnie_1", "text": "罗尼的第一句。"})
	var first: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(first.get("active_event_id", "")), "call_07_ronnie_1", "新对白必须开始对应人物的声音。")
	story.dialogue_changed.emit({"event_id": "call_10_ronnie_2", "text": "罗尼的第二句。"})
	var replaced: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(replaced.get("active_event_id", "")), "call_10_ronnie_2", "新对白必须立即替换上一句，不能串音。")
	_assert_equal(String(replaced.get("active_character_id", "")), "ronnie_hart", "罗尼续电仍必须使用同一人物档案。")
	story.dialogue_changed.emit({})
	var cleared: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(cleared.get("active_event_id", "")), "", "对白清空（挂机）必须立刻停止人物配音。")
	story.dialogue_changed.emit({"event_id": "call_11_final_amy", "text": "艾米仍在线上。"})
	story.ending_forced.emit(3600)
	var ended: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_equal(String(ended.get("active_event_id", "")), "", "02:00 收束必须立刻停止人物配音。")
	story.dialogue_changed.emit({"event_id": "call_03_martha", "text": "这句将在解绑时停止。"})
	player.call(&"unbind_story_engine")
	var unbound: Dictionary = player.call(&"get_playback_snapshot") as Dictionary
	_assert_true(not bool(unbound.get("bound", true)), "运行时解绑后不得保留 StoryEngine 订阅。")
	_assert_equal(String(unbound.get("active_event_id", "")), "", "运行时解绑必须停止当前人物配音。")


func _load_story_identities() -> Dictionary:
	var file: FileAccess = FileAccess.open(TEST_NIGHT_STORY_PATH, FileAccess.READ)
	_assert_true(file != null, "人物映射专项必须能读取测试剧情。")
	if file == null:
		return {}
	var parser := JSON.new()
	var parse_result: Error = parser.parse(file.get_as_text())
	file.close()
	_assert_true(parse_result == OK and parser.data is Dictionary, "测试剧情必须是可解析 JSON。")
	if parse_result != OK or not parser.data is Dictionary:
		return {}
	var root_data: Dictionary = parser.data as Dictionary
	var actors_by_id: Dictionary = {}
	for raw_actor: Variant in root_data.get("actors", []) as Array:
		if raw_actor is Dictionary:
			var actor: Dictionary = raw_actor as Dictionary
			actors_by_id[String(actor.get("id", ""))] = actor
	var identities: Dictionary = {}
	for raw_event: Variant in root_data.get("events", []) as Array:
		if raw_event is Dictionary:
			var event: Dictionary = raw_event as Dictionary
			var event_id: String = String(event.get("id", ""))
			var actor: Dictionary = actors_by_id.get(String(event.get("actor_id", "")), {}) as Dictionary
			identities[event_id] = {
				"caller": String(event.get("caller_display_name", "")),
				"speaker": String(actor.get("display_name", "")),
				"voice_profile_id": String(actor.get("voice_profile_id", "")),
			}
	return identities


func _assert_ok(result: Variant, message: String) -> void:
	_assert_true(result is Dictionary and bool((result as Dictionary).get("ok", false)), message)


func _assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	_assert_true(actual == expected, "%s 实际=%s，期望=%s。" % [message, str(actual), str(expected)])


func _assert_true(condition: bool, message: String) -> void:
	if condition:
		return
	_has_failed = true
	push_error("[测试][CharacterVoicePlayer] %s" % message)


func _finish() -> void:
	if _has_failed:
		print("[测试][CharacterVoicePlayer] 失败。")
		quit(1)
		return
	print("[测试][CharacterVoicePlayer] 通过：人物映射、素材、文本节奏循环与打断边界均符合合同。")
	quit(0)
