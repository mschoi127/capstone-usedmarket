import os
import time
import json
import subprocess
from pymongo import MongoClient
from multiprocessing import Process

# 🔑 키-프로젝트 매핑 (index는 인자로 사용)
KEY_PROJECT_MAP = [
    {"key": "crawler/capstone-459103-e45c686b12c9.json", "project": "capstone-459103"},
    {"key": "crawler/capstone2-459202-e090fd0bb954.json", "project": "capstone2-459202"},
    {"key": "crawler/capstone3-459202-0ba8d6a9942b.json", "project": "capstone3-459202"},
]

# 🔧 MongoDB 연결
client = MongoClient("mongodb+srv://minseok:cbnu1207@cluster0.udipufp.mongodb.net/market_db?retryWrites=true&w=majority&appName=Cluster0")
db = client["market_db"]
collection = db["products"]

# 🔍 상태 매핑 함수
def map_condition_text_to_level(text: str) -> int:
    text = text.strip()
    if "새상품" in text:
        return 4
    elif "중고" in text:
        return 2
    return -1

# 🔁 서브프로세스에서 실행될 함수 (REST 방식으로 Vertex 호출)
def process_worker(index: int, item_ids: list):
    from google.oauth2 import service_account
    from vertexai import init
    from vertexai.generative_models import GenerativeModel

    entry = KEY_PROJECT_MAP[index]
    credentials = service_account.Credentials.from_service_account_file(entry["key"])
    init(project=entry["project"], location="global", credentials=credentials)
    model = GenerativeModel("gemini-2.5-pro-exp-03-25")

    for _id in item_ids:
        item = collection.find_one({"_id": _id})
        if not item or not item.get("description"):
            continue

        prompt = f"""
다음 중고 거래 글을 읽고 물건 상태를 '새상품' 또는 '중고' 중 하나로 분류해 주세요.

조건:
- 사용 흔적이 있거나 포장이 개봉되었으면 '중고'
- 미사용, 미개봉이면 '새상품'

글 내용:
{item['description']}

출력: 물건 상태 한 단어로만 응답해 주세요.
"""
        try:
            response = model.generate_content(prompt, generation_config={
                "temperature": 0.2,
                "max_output_tokens": 2048
            })
            result = response.candidates[0].content.parts[-1].text.strip()
            level = map_condition_text_to_level(result)
            condition = "새상품" if level == 4 else "중고" if level == 2 else "알 수 없음"

            collection.update_one({"_id": _id}, {"$set": {
                "condition": condition,
                # "condition_level": level
            }})
            print(f"✅ {str(_id)} → {condition} ({level})")

        except Exception as e:
            print(f"❌ {_id} 처리 실패: {e}")
            collection.update_one({"_id": _id}, {"$set": {"condition_level": -1}})

# 📦 작업 분배 및 병렬 실행
if __name__ == "__main__":
    from bson import ObjectId
    from math import ceil

    items = list(collection.find({"condition": "알 수 없음"}, {"_id": 1}))
    chunks = [[] for _ in range(len(KEY_PROJECT_MAP))]

    for idx, item in enumerate(items):
        chunks[idx % len(KEY_PROJECT_MAP)].append(item["_id"])

    processes = []
    for i, chunk in enumerate(chunks):
        p = Process(target=process_worker, args=(i, chunk))
        p.start()
        processes.append(p)

    for p in processes:
        p.join()
