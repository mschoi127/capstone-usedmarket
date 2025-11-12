# -*- coding: utf-8 -*-
"""
Condition updater for market2.products.

Workflow
0. Delete 당근마켓 rows whose title contains 워치/버즈/핏/북.
1. Select documents whose condition is missing or not one of
   ["새 상품", "사용감 없음", "사용감 적음", "사용감 많음", "고장/파손 상품"].
2. Rule-based updates:
   - platform == 중고나라 and existing condition contains "새상품" => "새 상품"
   - title contains any of ["미개봉","새 상품","새상품","새 제품","새제품"] => "새 상품"
3. Remaining docs are classified via Gemini 2.5 Flash using title+description.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from typing import Any, Dict, Iterable

import requests
from pymongo import MongoClient
from pymongo.collection import Collection

TITLE_KEYWORDS = ("미개봉", "새 상품", "새상품", "새 제품", "새제품")
CARROT_SKIP_KEYWORDS = ("워치", "버즈", "핏", "북")
CONDITIONS = ["새 상품", "사용감 없음", "사용감 적음", "사용감 많음", "고장/파손 상품"]
LLM_MODEL = "gemini-2.5-flash"
LLM_ENDPOINT = (
    f"https://generativelanguage.googleapis.com/v1beta/models/{LLM_MODEL}:generateContent"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update product condition fields via LLM.")
    parser.add_argument("--mongodb-uri", default="mongodb://localhost:27017")
    parser.add_argument("--database", default="market2")
    parser.add_argument("--collection", default="products")
    parser.add_argument("--api-key", required=True, help="Gemini API key")
    parser.add_argument("--log-interval", type=int, default=20)
    parser.add_argument(
        "--worker-count",
        type=int,
        default=1,
        help="Total number of parallel workers (default: 1)",
    )
    parser.add_argument(
        "--worker-index",
        type=int,
        default=0,
        help="Zero-based index of this worker (default: 0)",
    )
    return parser.parse_args()


def connect_collection(uri: str, database: str, collection: str) -> Collection:
    client = MongoClient(uri)
    return client[database][collection]


def remove_carrot_watch(collection: Collection) -> int:
    regex = "|".join(map(re.escape, CARROT_SKIP_KEYWORDS))
    result = collection.delete_many(
        {"platform": "당근마켓", "title": {"$regex": regex, "$options": "i"}}
    )
    return result.deleted_count


def find_target_docs(collection: Collection) -> Iterable[Dict[str, Any]]:
    query = {
        "$or": [
            {"condition": {"$exists": False}},
            {"condition": {"$nin": CONDITIONS}},
        ]
    }
    cursor = collection.find(query, no_cursor_timeout=True).batch_size(500)
    try:
        for doc in cursor:
            yield doc
    finally:
        cursor.close()


def condition_has_new(value: Any) -> bool:
    return isinstance(value, str) and "새상품" in value


def title_has_new_keyword(title: Any) -> bool:
    return isinstance(title, str) and any(keyword in title for keyword in TITLE_KEYWORDS)


def llm_prompt(title: str, description: str) -> str:
    return f"""당신은 중고 스마트폰 매물의 상태를 분류하는 전문가입니다.
아래 정보를 읽고 상태를 다음 다섯 가지 중 하나로 판단하세요.
- 새 상품
- 사용감 없음
- 사용감 적음
- 사용감 많음
- 고장/파손 상품

JSON 만 출력하세요. 예: {{"condition": "사용감 적음"}}

제목: {title or "(정보 없음)"}
설명: {description or "(설명 없음)"}"""


def call_gemini(api_key: str, prompt: str) -> str | None:
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"},
    }
    params = {"key": api_key}
    try:
        resp = requests.post(
            LLM_ENDPOINT,
            params=params,
            json=payload,
            timeout=40,
        )
        resp.raise_for_status()
        data = resp.json()
        text = data["candidates"][0]["content"]["parts"][0]["text"]
        return text
    except (requests.RequestException, KeyError, IndexError) as exc:
        print(f"[LLM] error: {exc}")
        return None


def classify_condition(api_key: str, title: str, description: str) -> str | None:
    prompt = llm_prompt(title, description)
    text = call_gemini(api_key, prompt)
    if not text:
        return None
    try:
        parsed = json.loads(text)
        value = extract_condition(parsed)
        if value:
            return value
    except json.JSONDecodeError:
        pass
    for condition in CONDITIONS:
        if condition in text:
            return condition
    return None


def extract_condition(data: Any) -> str | None:
    if isinstance(data, dict):
        value = data.get("condition")
        if isinstance(value, str) and value in CONDITIONS:
            return value
        for nested in data.values():
            found = extract_condition(nested)
            if found:
                return found
    elif isinstance(data, list):
        for item in data:
            found = extract_condition(item)
            if found:
                return found
    return None


def update_condition(collection: Collection, doc_id, new_condition: str) -> None:
    collection.update_one({"_id": doc_id}, {"$set": {"condition": new_condition}})


def main() -> None:
    args = parse_args()
    if args.worker_count <= 0:
        raise ValueError("worker_count must be >= 1")
    if not (0 <= args.worker_index < args.worker_count):
        raise ValueError("worker_index must satisfy 0 <= index < worker_count")
    collection = connect_collection(args.mongodb_uri, args.database, args.collection)

    removed = remove_carrot_watch(collection)
    print(f"[INFO] Removed {removed} 당근마켓 워치/버즈/핏/북 entries.")

    docs = list(find_target_docs(collection))
    total = len(docs)
    print(f"[INFO] Target docs (condition missing or outside allowed set): {total}")

    rule_jn = rule_title = llm_updates = skipped = 0

    def belongs_to_worker(doc_id: Any) -> bool:
        digest = hashlib.sha1(str(doc_id).encode("utf-8")).digest()
        value = int.from_bytes(digest[:8], "big", signed=False)
        return (value % args.worker_count) == args.worker_index

    assigned = 0
    for idx, doc in enumerate(docs, start=1):
        doc_id = doc.get("_id")
        if not belongs_to_worker(doc_id):
            continue
        assigned += 1
        platform = doc.get("platform")
        condition = doc.get("condition")
        title = doc.get("title") if isinstance(doc.get("title"), str) else ""
        description = doc.get("description") if isinstance(doc.get("description"), str) else ""

        if platform == "중고나라" and condition_has_new(condition):
            update_condition(collection, doc_id, "새 상품")
            rule_jn += 1
        elif title_has_new_keyword(title):
            update_condition(collection, doc_id, "새 상품")
            rule_title += 1
        else:
            classified = classify_condition(args.api_key, title, description)
            if classified:
                update_condition(collection, doc_id, classified)
                llm_updates += 1
            else:
                skipped += 1

        if assigned % args.log_interval == 0:
            print(
                f"[PROGRESS worker {args.worker_index}/{args.worker_count}] "
                f"processed {assigned} "
                f"(rule_jn={rule_jn}, rule_title={rule_title}, llm={llm_updates}, skipped={skipped})"
            )

    print("=== Summary ===")
    print(
        f"Worker {args.worker_index}/{args.worker_count} processed {assigned} "
        f"out of {total} targets."
    )
    print(f"Rule updates (중고나라+condition): {rule_jn}")
    print(f"Rule updates (title keywords):   {rule_title}")
    print(f"LLM updates:                     {llm_updates}")
    print(f"LLM skipped/failed:              {skipped}")


if __name__ == "__main__":
    main()
