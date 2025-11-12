# -*- coding: utf-8 -*-
"""
Populate the `title_normalization` field for products that do not have it yet.

Rules:
    * remove all whitespace characters
    * lowercase ASCII letters
    * strip special characters (keep only 0-9, a-z, Korean syllables)

Usage:
    python normalize_titles.py --mongodb-uri mongodb://localhost:27017 \
        --database market2 --collection products
"""

from __future__ import annotations

import argparse
import re
from typing import Dict

from pymongo import MongoClient, UpdateOne

ALLOWED_PATTERN = re.compile(r"[^0-9a-z가-힣]")
WHITESPACE_PATTERN = re.compile(r"\s+")


def normalize_title(value: str | None) -> str:
    """Apply project-wide normalization rules to a raw title string."""
    if not value:
        return ""

    lowered = value.lower()
    no_space = WHITESPACE_PATTERN.sub("", lowered)
    cleaned = ALLOWED_PATTERN.sub("", no_space)
    return cleaned


def process(
    mongo_uri: str,
    database: str,
    collection_name: str,
    batch_size: int = 1000,
    log_interval: int = 5000,
) -> Dict[str, int]:
    client = MongoClient(mongo_uri)
    collection = client[database][collection_name]

    filter_query = {"title_normalization": {"$exists": False}}
    total = collection.count_documents(filter_query)

    cursor = collection.find(
        filter_query,
        {"_id": 1, "title": 1},
        no_cursor_timeout=True,
    ).batch_size(batch_size)

    stats = {"total": total, "processed": 0, "updated": 0}
    operations: list[UpdateOne] = []

    try:
        for doc in cursor:
            stats["processed"] += 1
            normalized = normalize_title(doc.get("title", ""))

            operations.append(
                UpdateOne(
                    {"_id": doc["_id"]},
                    {"$set": {"title_normalization": normalized}},
                )
            )

            if len(operations) >= batch_size:
                result = collection.bulk_write(operations, ordered=False)
                stats["updated"] += result.modified_count
                operations.clear()

            if log_interval and stats["processed"] % log_interval == 0:
                print(
                    f"[normalize_titles] Processed {stats['processed']}/{stats['total']} "
                    f"({stats['processed'] / max(stats['total'], 1):.1%})"
                )
    finally:
        cursor.close()

    if operations:
        result = collection.bulk_write(operations, ordered=False)
        stats["updated"] += result.modified_count

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Populate title_normalization for missing documents."
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
        help="Bulk update batch size (default: 1000)",
    )
    parser.add_argument(
        "--log-interval",
        type=int,
        default=5000,
        help="How many processed documents between progress logs (default: 5000)",
    )
    args = parser.parse_args()

    stats = process(
        mongo_uri=args.mongodb_uri,
        database=args.database,
        collection_name=args.collection,
        batch_size=args.batch_size,
        log_interval=args.log_interval,
    )

    print(
        "Normalization complete. "
        f"Total: {stats['total']}, processed: {stats['processed']}, "
        f"updated: {stats['updated']}."
    )


if __name__ == "__main__":
    main()
