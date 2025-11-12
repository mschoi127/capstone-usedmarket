# -*- coding: utf-8 -*-
"""
Remove duplicated spam listings that share the same core fields.

Criteria:
    - Only consider documents that already contain a `description` field.
    - Group by (title, description, price, platform, region).
    - Keep only the document with the latest `upload_time` (fallback to _id order).
    - Delete every other document in the group.

Usage:
    python remove_duplicate_spam.py \
        --mongodb-uri mongodb://localhost:27017 \
        --database market2 \
        --collection products
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Tuple

from bson import ObjectId
from pymongo import MongoClient

KST = timezone(timedelta(hours=9))


def parse_upload_time(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text:
        return None
    candidates = [text, text.replace("Z", "+00:00")]
    for candidate in candidates:
        try:
            parsed = datetime.fromisoformat(candidate)
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=KST)
            else:
                parsed = parsed.astimezone(KST)
            return parsed
        except ValueError:
            continue
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(text, fmt).replace(tzinfo=KST)
            return parsed
        except ValueError:
            continue
    return None


def object_id_time(value: Any) -> datetime | None:
    if isinstance(value, ObjectId):
        return value.generation_time
    return None


def is_newer(
    candidate_time: datetime | None,
    candidate_id: Any,
    current_time: datetime | None,
    current_id: Any,
) -> bool:
    if candidate_time and current_time:
        return candidate_time > current_time
    if candidate_time and not current_time:
        return True
    if current_time and not candidate_time:
        return False

    cand_id_time = object_id_time(candidate_id)
    curr_id_time = object_id_time(current_id)
    if cand_id_time and curr_id_time:
        return cand_id_time > curr_id_time

    return str(candidate_id) > str(current_id)


def normalize_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    return str(value)


def process_duplicates(
    mongo_uri: str,
    database: str,
    collection_name: str,
    batch_size: int = 1000,
    log_interval: int = 10000,
) -> Dict[str, int]:
    client = MongoClient(mongo_uri)
    collection = client[database][collection_name]

    cursor = collection.find(
        {"description": {"$exists": True}},
        {
            "_id": 1,
            "title": 1,
            "description": 1,
            "price": 1,
            "platform": 1,
            "region": 1,
            "upload_time": 1,
        },
        no_cursor_timeout=True,
    ).batch_size(batch_size)

    best_map: Dict[Tuple[str, str, str, str, str], Dict[str, Any]] = {}
    delete_ids: list[Any] = []
    stats = {"scanned": 0, "groups": 0, "marked_for_delete": 0}

    try:
        for doc in cursor:
            stats["scanned"] += 1
            key = (
                normalize_value(doc.get("title")),
                normalize_value(doc.get("description")),
                normalize_value(doc.get("price")),
                normalize_value(doc.get("platform")),
                normalize_value(doc.get("region")),
            )

            record = best_map.get(key)
            upload_dt = parse_upload_time(doc.get("upload_time"))

            if not record:
                best_map[key] = {
                    "id": doc["_id"],
                    "time": upload_dt,
                }
                stats["groups"] += 1
                continue

            if is_newer(upload_dt, doc["_id"], record["time"], record["id"]):
                delete_ids.append(record["id"])
                best_map[key] = {"id": doc["_id"], "time": upload_dt}
            else:
                delete_ids.append(doc["_id"])

            stats["marked_for_delete"] += 1

            if log_interval and stats["scanned"] % log_interval == 0:
                print(
                    f"[scan] {stats['scanned']} docs processed, "
                    f"{stats['marked_for_delete']} marked so far."
                )
    finally:
        cursor.close()

    deleted = 0
    if delete_ids:
        for i in range(0, len(delete_ids), batch_size):
            chunk = delete_ids[i : i + batch_size]
            result = collection.delete_many({"_id": {"$in": chunk}})
            deleted += result.deleted_count
            if log_interval and deleted % log_interval == 0:
                print(f"[delete] {deleted} documents removed...")

    stats["deleted"] = deleted
    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Remove duplicate spam listings keeping the latest upload_time."
    )
    parser.add_argument(
        "--mongodb-uri",
        default="mongodb://localhost:27017",
        help="MongoDB connection string (default: mongodb://localhost:27017)",
    )
    parser.add_argument(
        "--database",
        default="market2",
        help="Database name (default: market2)",
    )
    parser.add_argument(
        "--collection",
        default="products",
        help="Collection name (default: products)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=1000,
        help="Batch size for scanning/deleting (default: 1000)",
    )
    parser.add_argument(
        "--log-interval",
        type=int,
        default=10000,
        help="Progress log interval (default: 10000 docs)",
    )
    args = parser.parse_args()

    stats = process_duplicates(
        mongo_uri=args.mongodb_uri,
        database=args.database,
        collection_name=args.collection,
        batch_size=args.batch_size,
        log_interval=args.log_interval,
    )

    print(
        "Duplicate cleanup finished. "
        f"Scanned: {stats['scanned']}, groups: {stats['groups']}, "
        f"marked: {stats['marked_for_delete']}, deleted: {stats['deleted']}."
    )


if __name__ == "__main__":
    main()
