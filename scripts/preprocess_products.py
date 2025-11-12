# -*- coding: utf-8 -*-
"""
Lightweight preprocessing for market2.products.
Steps
1) Deduplicate by url (first-come keeps record)
2) Remove titles containing blocked keywords (e.g. "삽니다", "교환")
3) Remove documents whose price <= 5,000 or >= 5,000,000
All operations happen in-place on the products collection.
"""

from __future__ import annotations

import argparse
import re
from typing import Any, Dict, Set

from pymongo import MongoClient
from pymongo.collection import Collection

KEYWORDS = ("삽니다", "교환")
PRICE_MIN = 5_000
PRICE_MAX = 5_000_000
PRICE_PATTERN = re.compile(r"\d+")
URL_MISSING = object()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Preprocess market2.products collection")
    parser.add_argument(
        "--mongodb-uri", default="mongodb://localhost:27017", help="MongoDB connection string"
    )
    parser.add_argument("--database", default="market2", help="Database name (default: market2)")
    parser.add_argument(
        "--collection", default="products", help="Collection name (default: products)"
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Limit number of documents to inspect (0 = no limit, use for testing)",
    )
    return parser.parse_args()


def connect_collection(uri: str, database: str, collection: str) -> Collection:
    client = MongoClient(uri)
    return client[database][collection]


def normalize_url(value: Any) -> Any:
    if isinstance(value, str):
        trimmed = value.strip()
        return trimmed if trimmed else URL_MISSING
    return URL_MISSING


def parse_price(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    digits = PRICE_PATTERN.findall(value)
    if not digits:
        return None
    return int("".join(digits))


def preprocess(collection: Collection, limit: int = 0) -> Dict[str, int]:
    stats: Dict[str, int] = {
        "scanned": 0,
        "removed_duplicates": 0,
        "removed_title": 0,
        "removed_price": 0,
        "kept": 0,
    }
    seen_urls: Set[Any] = set()

    cursor = collection.find({}, no_cursor_timeout=True).batch_size(1000)
    if limit and limit > 0:
        cursor = cursor.limit(limit)

    def delete_doc(doc_id) -> None:
        collection.delete_one({"_id": doc_id})

    try:
        for doc in cursor:
            stats["scanned"] += 1
            doc_id = doc.get("_id")

            # Step 1: duplicate url removal
            url_key = normalize_url(doc.get("url"))
            if url_key is not URL_MISSING:
                if url_key in seen_urls:
                    delete_doc(doc_id)
                    stats["removed_duplicates"] += 1
                    continue
                seen_urls.add(url_key)

            # Step 2: title keyword filter
            title = doc.get("title") if isinstance(doc.get("title"), str) else ""
            if any(keyword in title for keyword in KEYWORDS):
                delete_doc(doc_id)
                stats["removed_title"] += 1
                continue

            # Step 3: price sanity check
            price_value = parse_price(doc.get("price"))
            if (
                price_value is None
                or price_value <= PRICE_MIN
                or price_value >= PRICE_MAX
            ):
                delete_doc(doc_id)
                stats["removed_price"] += 1
                continue

            stats["kept"] += 1
    finally:
        cursor.close()

    return stats


def main() -> None:
    args = parse_args()
    collection = connect_collection(args.mongodb_uri, args.database, args.collection)
    stats = preprocess(collection, args.limit)

    print("=== Preprocessing Summary ===")
    print(f"Scanned:            {stats['scanned']}")
    print(f"Removed duplicates: {stats['removed_duplicates']}")
    print(f"Removed titles:     {stats['removed_title']}")
    print(f"Removed prices:     {stats['removed_price']}")
    print(f"Kept documents:     {stats['kept']}")


if __name__ == "__main__":
    main()
