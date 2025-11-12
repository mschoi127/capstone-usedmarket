# 파일 위치: crawler/llm_condition_backfill.py

from pymongo import MongoClient
from llm_condition_classifier import classify_condition_level

# MongoDB Atlas 연결 문자열 수정 필요
client = MongoClient("mongodb+srv://minseok:cbnu1207@cluster0.udipufp.mongodb.net/market_db?retryWrites=true&w=majority&appName=Cluster0")
db = client["market_db"]
collection = db["products"]

# condition이 "알 수 없음"인 항목만 처리
items = collection.find({"condition": "알 수 없음"})

for item in items:
    description = item.get("description", "")
    if not description:
        continue

    level = classify_condition_level(description)

    if level == 4:
        condition = "새상품"
    elif level == 2:
        condition = "중고"
    else:
        condition = "알 수 없음"

    collection.update_one(
        {"_id": item["_id"]},
        {"$set": {
            "condition": condition,
            "condition_level": level
        }}
    )
    print(f"✅ {item['_id']} 업데이트 완료: {condition} ({level})")
