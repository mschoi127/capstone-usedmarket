# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import re
from typing import Dict, List, Sequence, Tuple

from pymongo import MongoClient, UpdateOne

from model_storage_synonyms import MODEL_SYNONYMS, STORAGE_SYNONYMS, sorted_model_keys_desc

STORAGE_FALLBACK_PATTERNS = [
    (re.compile(r"(?<!\d)512(?!\d)"), "512g"),
    (re.compile(r"(?<!\d)256(?!\d)"), "256g"),
    (re.compile(r"(?<!\d)128(?!\d)"), "128g"),
    (re.compile(r"(?<!\d)64(?!\d)"), "64g"),
    (re.compile(r"(?<!\d)32(?!\d)"), "32g"),
    (re.compile(r"(?<!\d)1\s*(tb|테라)"), "1tb"),
]


def build_matchers() -> Tuple[List[Tuple[str, str]], List[Tuple[str, str]]]:
    model_pairs: List[Tuple[str, str]] = []
    for key in sorted_model_keys_desc():
        synonyms = MODEL_SYNONYMS.get(key, [])
        for synonym in sorted(set(synonyms), key=len, reverse=True):
            model_pairs.append((synonym, key))

    storage_pairs: List[Tuple[str, str]] = []
    for key, synonyms in STORAGE_SYNONYMS.items():
        for synonym in sorted(set(synonyms), key=len, reverse=True):
            storage_pairs.append((synonym, key))

    storage_pairs.sort(key=lambda x: len(x[0]), reverse=True)
    return model_pairs, storage_pairs


def parse_fields(
    normalized: str,
    model_pairs: List[Tuple[str, str]],
    storage_pairs: List[Tuple[str, str]],
    raw_texts: Sequence[str] | None = None,
) -> Tuple[str | None, str | None]:
    model_name = None
    storage_name = None

    if normalized:
        is_tab_context = "탭" in normalized or "tab" in normalized

        for synonym, canonical in model_pairs:
            if is_tab_context and canonical.startswith("galaxy_s"):
                continue
            if synonym and synonym in normalized:
                model_name = canonical
                break

        for synonym, canonical in storage_pairs:
            if synonym and synonym in normalized:
                storage_name = canonical
                break

        if not storage_name and model_name and raw_texts:
            storage_name = infer_storage_from_raw(raw_texts)

    return model_name, storage_name


def infer_storage_from_raw(raw_texts: Sequence[str]) -> str | None:
    """Search non-normalized title/description text for plain-number capacities."""
    for raw in raw_texts:
        if not raw:
            continue
        lowered = raw.lower()
        for pattern, canonical in STORAGE_FALLBACK_PATTERNS:
            if pattern.search(lowered):
                return canonical
    return None


def process(
    mongo_uri: str,
    database: str,
    collection_name: str,
    batch_size: int = 1000,
) -> Dict[str, int]:
    client = MongoClient(mongo_uri)
    collection = client[database][collection_name]

    model_pairs, storage_pairs = build_matchers()
    stats = {"processed": 0, "updated": 0}

    cursor = collection.find(
        {},
        {"_id": 1, "title_normalization": 1, "title": 1, "description": 1},
        no_cursor_timeout=True,
    ).batch_size(batch_size)

    operations: List[UpdateOne] = []

    try:
        for doc in cursor:
            stats["processed"] += 1
            normalized = doc.get("title_normalization", "")
            model_name, storage_name = parse_fields(
                normalized or "",
                model_pairs,
                storage_pairs,
                (doc.get("title", ""), doc.get("description", "")),
            )

            update = {
                "$set": {
                    "model_name": model_name,
                    "storage": storage_name,
                }
            }
            operations.append(UpdateOne({"_id": doc["_id"]}, update))

            if len(operations) >= batch_size:
                result = collection.bulk_write(operations, ordered=False)
                stats["updated"] += result.modified_count
                operations.clear()
    finally:
        cursor.close()

    if operations:
        result = collection.bulk_write(operations, ordered=False)
        stats["updated"] += result.modified_count

    return stats


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Parse model/storage from title_normalization field."
    )
    parser.add_argument(
        "--mongodb-uri",
        default="mongodb://localhost:27017",
        help="MongoDB connection string",
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
    args = parser.parse_args()

    stats = process(
        mongo_uri=args.mongodb_uri,
        database=args.database,
        collection_name=args.collection,
        batch_size=args.batch_size,
    )
    print(f"Processed {stats['processed']} documents, updated {stats['updated']}.")


if __name__ == "__main__":
    main()
