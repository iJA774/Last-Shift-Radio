import json
from pathlib import Path

path = Path("data/story/test_night_story.json")
data = json.loads(path.read_text(encoding="utf-8"))

for event in data["events"]:
    event.pop("unlocks_broadcast_ids", None)
for message in data["messages"]:
    message.pop("unlocks_broadcast_ids", None)

old_broadcasts = {item["id"]: item for item in data.pop("broadcasts", [])}

statements = data["statements"]
if not any(item.get("id") == "statement_trucker_bridge_queue" for item in statements):
    insert_at = next((index for index, item in enumerate(statements) if item.get("id") == "statement_southbound_bridge_claim"), len(statements))
    statements.insert(insert_at, {
        "id": "statement_trucker_bridge_queue",
        "source_id": "call_06_trucker",
        "body": "东侧卡车司机称北桥东边严重拥堵，车辆在封闭区域前等待，现场有人下车查看道路。",
    })

for node in data["dialogue_nodes"]:
    if node.get("id") in {"dlg_trucker_car_end", "dlg_trucker_closure_end"}:
        reveal_ids = list(node.get("reveals_statement_ids", []))
        if "statement_trucker_bridge_queue" not in reveal_ids:
            reveal_ids.append("statement_trucker_bridge_queue")
        node["reveals_statement_ids"] = reveal_ids

closure_body = old_broadcasts.get("broadcast_bridge_structural_closure", {}).get(
    "body",
    "官方路况：北桥因结构受损封闭，桥面存在塌陷风险。请勿前往，并按现场指示绕行。",
)
tanker_body = old_broadcasts.get("broadcast_bridge_tanker_fire", {}).get(
    "body",
    "未核实路况：有听众称北桥附近一辆油罐车起火或冒烟。请避开该区域，等待官方更新。",
)
wagon_body = old_broadcasts.get("broadcast_wagon_witness_request", {}).get(
    "body",
    "代家属征集信息：如您今晚在北桥周边见过一辆深色旧旅行车，请在安全地点联系 WMLH 新闻室；请勿自行追车。",
)

data["broadcast_tasks"] = [
    {
        "id": "task_broadcast_bridge_closure",
        "name": "通过麦克风发布北桥封锁信息",
        "channel": "microphone",
        "source": "Studio A",
        "related_dialogue_event_ids": ["call_01_warren", "call_06_trucker", "call_09_southbound"],
        "required_dialogue_event_ids": ["call_01_warren", "call_06_trucker"],
        "sets_condition_id": "",
        "information_items": [
            {
                "id": "info_bridge_tanker_fire",
                "source_label": "沃伦",
                "body": tanker_body,
                "statement_ids": ["statement_warren_tanker_fire_claim"],
                "fact_ids": [],
            },
            {
                "id": "info_bridge_east_queue",
                "source_label": "东侧卡车司机",
                "body": "现场路况：北桥东侧入口严重拥堵，有车辆在封闭区域前等待。请避开该区域并等待现场指引。",
                "statement_ids": ["statement_trucker_bridge_queue"],
                "fact_ids": [],
            },
            {
                "id": "info_bridge_official_closure",
                "source_label": "警员 K. 米勒 #451",
                "body": closure_body,
                "statement_ids": ["statement_miller_bridge_closure"],
                "fact_ids": ["fact_bridge_closed"],
            },
            {
                "id": "info_bridge_southbound_crossing",
                "source_label": "路过的年轻司机",
                "body": "未核实补充：有司机称封桥消息后仍按临时路牌经过北桥。请不要据此前往，继续按官方封闭通知绕行。",
                "statement_ids": ["statement_southbound_bridge_claim"],
                "fact_ids": ["fact_bridge_traffic_after_closure"],
            },
        ],
    },
    {
        "id": "task_broadcast_wagon_witness_request",
        "name": "通过麦克风征集旧旅行车目击信息",
        "channel": "microphone",
        "source": "Studio A",
        "related_dialogue_event_ids": ["call_03_martha"],
        "required_dialogue_event_ids": ["call_03_martha"],
        "sets_condition_id": "condition_wagon_witness_request_sent",
        "information_items": [
            {
                "id": "info_wagon_martha_route",
                "source_label": "玛莎·克莱恩",
                "body": wagon_body,
                "statement_ids": ["statement_martha_wagon_route"],
                "fact_ids": ["fact_same_wagon_recurs", "fact_wagon_positions_conflict"],
            }
        ],
    },
]

ordered = {}
for key, value in data.items():
    if key == "dialogue_nodes":
        ordered["broadcast_tasks"] = data["broadcast_tasks"]
    if key != "broadcast_tasks":
        ordered[key] = value

path.write_text(json.dumps(ordered, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
