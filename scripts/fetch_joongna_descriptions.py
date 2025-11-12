# -*- coding: utf-8 -*-
from __future__ import annotations

import argparse
import re
from typing import Any, Dict, List
from urllib.parse import urlparse

import requests
from requests import RequestException
from pymongo import MongoClient
from pymongo.collection import Collection

BUILD_ID_PATTERN = re.compile(r"/main-web/_next/static/([^/]+)/_buildManifest\.js")
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/129.0.0.0 Safari/537.36"
)
BASE_URL = "https://web.joongna.com"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fetch product descriptions for Joongna items."
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum documents to process (0 for no limit).",
    )
    parser.add_argument(
        "--mongodb-uri",
        default="mongodb://localhost:27017",
        help="MongoDB connection string.",
    )
    parser.add_argument(
        "--database",
        default="market2",
        help="MongoDB database name (default: market2).",
    )
    parser.add_argument(
        "--source",
        default="products",
        help="MongoDB collection name to read/update (default: products).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Process documents even if description already exists.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print a line for every processed document.",
    )
    return parser.parse_args()


def extract_product_id(url: str | None) -> str | None:
    if not url or not isinstance(url, str):
        return None
    parsed = urlparse(url)
    path_parts = [part for part in parsed.path.split("/") if part]
    if len(path_parts) >= 2 and path_parts[0].lower() == "product":
        candidate = path_parts[-1]
        return candidate if candidate.isdigit() else None
    return None


def search_description(payload: Any) -> str | None:
    if isinstance(payload, dict):
        if (
            "productDescription" in payload
            and isinstance(payload["productDescription"], str)
        ):
            return payload["productDescription"]
        for value in payload.values():
            found = search_description(value)
            if found:
                return found
    elif isinstance(payload, list):
        for item in payload:
            found = search_description(item)
            if found:
                return found
    return None


class DescriptionFetcher:
    def __init__(self) -> None:
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": USER_AGENT})
        self._build_id_cache: Dict[str, str] = {}

    def _get(self, url: str, *, timeout: int = 10):
        try:
            response = self.session.get(url, timeout=timeout)
        except RequestException as exc:
            return None, f"request failed ({exc.__class__.__name__})"
        return response, None

    def _refresh_build_id(self, product_id: str) -> tuple[str | None, str | None]:
        page_url = f"{BASE_URL}/product/{product_id}"
        response, error = self._get(page_url)
        if error:
            return None, error
        if response.status_code != 200:
            return None, f"page status {response.status_code}"
        match = BUILD_ID_PATTERN.search(response.text)
        if not match:
            return None, "build id not found in page"
        build_id = match.group(1)
        self._build_id_cache[BASE_URL] = build_id
        return build_id, None

    def _ensure_build_id(self, product_id: str) -> tuple[str | None, str | None]:
        cached = self._build_id_cache.get(BASE_URL)
        if cached:
            return cached, None
        return self._refresh_build_id(product_id)

    def fetch(self, product_id: str) -> tuple[str | None, str | None]:
        build_id, error = self._ensure_build_id(product_id)
        if error or not build_id:
            return None, error or "build id not found"

        data_url = (
            f"{BASE_URL}/main-web/_next/data/{build_id}/product/{product_id}.json"
        )
        response, error = self._get(data_url)
        if error:
            return None, error
        if response.status_code == 404:
            build_id, error = self._refresh_build_id(product_id)
            if error or not build_id:
                return None, error or "build id refresh failed"
            data_url = (
                f"{BASE_URL}/main-web/_next/data/{build_id}/product/{product_id}.json"
            )
            response, error = self._get(data_url)
            if error:
                return None, error

        if response.status_code != 200:
            return None, f"data fetch failed ({response.status_code})"

        try:
            payload = response.json()
        except ValueError:
            return None, "invalid json response"

        description = search_description(payload)
        if not description:
            return None, "description not found in payload"
        return description.strip(), None


def connect_collection(uri: str, database: str, collection: str) -> Collection:
    client = MongoClient(uri)
    return client[database][collection]


def main() -> None:
    args = parse_args()

    collection = connect_collection(args.mongodb_uri, args.database, args.source)
    query: Dict[str, Any] = {"platform": "중고나라"}
    if not args.force:
        query["$or"] = [
            {"description": {"$exists": False}},
            {"description": ""},
        ]

    total_candidates = collection.count_documents(query)
    print(f"Query candidates: {total_candidates}")

    cursor = collection.find(query, {"url": 1}, no_cursor_timeout=True).batch_size(100)
    if args.limit and args.limit > 0:
        cursor = cursor.limit(args.limit)

    fetcher = DescriptionFetcher()

    processed = 0
    updated = 0
    failure_count = 0
    failure_samples: List[str] = []
    failure_sample_limit = 20

    try:
        for doc in cursor:
            processed += 1
            product_id = extract_product_id(doc.get("url"))
            if not product_id:
                failure_count += 1
                if len(failure_samples) < failure_sample_limit:
                    failure_samples.append(f"{doc.get('_id')} : invalid product url")
                continue

            description, error = fetcher.fetch(product_id)
            if error or not description:
                failure_count += 1
                if len(failure_samples) < failure_sample_limit:
                    failure_samples.append(f"{doc.get('_id')} : {error}")
                continue

            result = collection.update_one(
                {"_id": doc["_id"]}, {"$set": {"description": description}}
            )
            if result.modified_count:
                updated += 1

            if args.verbose:
                print(
                    f"Updated {_id_repr(doc.get('_id'))} "
                    f"({product_id}) - description length {len(description)}"
                )
            elif processed % 100 == 0:
                print(
                    f"Progress: processed {processed}, "
                    f"updated {updated}, failures {failure_count}"
                )
    finally:
        cursor.close()

    print(f"Processed: {processed}")
    print(f"Updated: {updated}")
    print(f"Failures: {failure_count}")
    if failure_samples:
        print("Failure samples:")
        for entry in failure_samples:
            print(f"  - {entry}")
        if failure_count > len(failure_samples):
            print(f"  ... and {failure_count - len(failure_samples)} more")


def _id_repr(value: Any) -> str:
    return str(value)


if __name__ == "__main__":
    main()
