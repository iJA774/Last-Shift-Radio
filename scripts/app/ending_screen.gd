class_name EndingScreen
extends Control

## 结束页只负责素材内的返回主界面热点，不持有本局剧情、电话或时钟状态。

signal return_to_menu_requested

enum EndResult {
	SUCCESS,
	FAILURE,
}

const SUCCESS_ART: Texture2D = preload("res://UI美术/值夜成功.png")
const FAILURE_ART: Texture2D = preload("res://UI美术/值夜失败.png")

@onready var _return_to_menu_hotspot: Button = %ReturnToMenuHotspot
@onready var _ending_art: TextureRect = %EndingArt

var _result: EndResult = EndResult.SUCCESS


func _ready() -> void:
	_apply_result_art()
	_return_to_menu_hotspot.pressed.connect(_on_return_to_menu_pressed)


## 结果呈现只接受稳定枚举。它不判断剧情，也不创建失败条件；
## 当前 Main 仅把已确认的 02:00 固定收束映射为 SUCCESS。
func set_result(result: EndResult) -> Dictionary:
	if result != EndResult.SUCCESS and result != EndResult.FAILURE:
		return {"ok": false, "error_code": "unknown_end_result", "message": "未知结束结果，拒绝切换结束页素材。"}
	_result = result
	if is_node_ready():
		_apply_result_art()
	return {"ok": true, "result_id": get_result_id()}


func get_result_id() -> String:
	return "success" if _result == EndResult.SUCCESS else "failure"


func get_ending_art_snapshot() -> Dictionary:
	return {
		"ok": _ending_art != null and _ending_art.texture != null,
		"outcome": get_result_id(),
		"resource_path": _ending_art.texture.resource_path if _ending_art != null and _ending_art.texture != null else "",
	}


func _apply_result_art() -> void:
	if _ending_art == null:
		push_error("[结束页][ending_art_missing] 结束页缺少 EndingArt 节点。")
		return
	_ending_art.texture = SUCCESS_ART if _result == EndResult.SUCCESS else FAILURE_ART


func _on_return_to_menu_pressed() -> void:
	if not _return_to_menu_hotspot.disabled:
		_play_button_click("return_to_menu")
		return_to_menu_requested.emit()


## 只有素材内热点会切换应用级界面；只在热点已启用且意图已确认时调用。
## UiSoundPlayer 是持久化自动加载，结束页被替换后点击音仍能自然播放完。
func _play_button_click(action_id: String) -> void:
	var player: Node = get_tree().root.get_node_or_null(NodePath("UiSoundPlayer")) as Node
	if player == null or not player.has_method(&"play_button_click"):
		push_error("[音频][ui_sound_player_missing] 未找到 UiSoundPlayer，结束页 %s 点击音未播放。" % action_id)
		return
	var result: Variant = player.call(&"play_button_click")
	if not result is Dictionary or not bool((result as Dictionary).get("ok", false)):
		push_warning("[音频][ui_button_click_failed] 结束页 %s 点击音播放失败：%s" % [action_id, str(result)])
