import logging
from typing import Iterable, Mapping


def save_to_mongodb_upsert(
    data: Iterable[Mapping],
    platform: str,
    mongo_uri: str = "mongodb://localhost:27017/",
    db_name: str = "market2",
    collection_name: str = "products",
):
    try:
        from pymongo import MongoClient
    except Exception as e:
        logging.error(f"pymongo import 실패: {e}")
        raise

    client = MongoClient(mongo_uri)
    collection = client[db_name][collection_name]

    inserted = 0
    updated = 0
    for item in data:
        try:
            doc = dict(item)
            doc["platform"] = platform
            url = doc.get("url")
            if url:
                res = collection.update_one({"url": url}, {"$set": doc}, upsert=True)
                if res.matched_count == 0 and res.upserted_id is not None:
                    inserted += 1
                else:
                    updated += 1
            else:
                collection.insert_one(doc)
                inserted += 1
        except Exception as e:
            logging.warning(f"MongoDB upsert 실패: {e}")

    logging.info(f"MongoDB에 {inserted}개 insert, {updated}개 update ({platform})")
    client.close()
