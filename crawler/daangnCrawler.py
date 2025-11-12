from shared import init_browser, wait_for_presence
# Override DB saver with upsert-based implementation to avoid duplicates
from db_utils import save_to_mongodb_upsert as save_to_mongodb
import os
import re
import json
import time
import logging
from datetime import datetime
from bs4 import BeautifulSoup
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from urllib.parse import quote
from concurrent.futures import ThreadPoolExecutor, as_completed
from selenium.common.exceptions import TimeoutException
from selenium.common.exceptions import (TimeoutException, StaleElementReferenceException)

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
MAX_WORKERS = int(os.environ.get("DAANGN_MAX_WORKERS", "6"))


def scrape_daangn(region_url):
    driver = init_browser()
    driver.get(region_url)
    results = []
    
    # while True:
    #     try:
    #         # 텍스트가 '더보기'인 버튼을 찾고 스크롤 후 클릭
    #         more_button = WebDriverWait(driver, 3).until(
    #             EC.presence_of_element_located((By.XPATH, "//button[normalize-space(text())='더보기']"))
    #         )
    #         driver.execute_script("arguments[0].scrollIntoView(true);", more_button)
    #         time.sleep(0.5)
    #         driver.execute_script("arguments[0].click();", more_button)
    #         logging.info("✅ 더보기 버튼 클릭됨")
    #         time.sleep(1)  # 로딩 대기
    #     except:
    #         logging.info("▶ 더보기 버튼이 더 이상 존재하지 않음 — 전체 상품 로드 완료")
    #         break

    SHOW_MORE_CSS = 'div[data-gtm="search_show_more_articles"] > button'

    while True:
        try:
            # 1) 화면 맨 아래까지 한 번 스크롤 – 새 버튼을 렌더링시키기
            driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
            WebDriverWait(driver, 5).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, SHOW_MORE_CSS)))

            # 2) 버튼 **다시** 찾기 → stale 방지
            more_btn = driver.find_element(By.CSS_SELECTOR, SHOW_MORE_CSS)

            # 3) 중앙에 오도록 스크롤 후 JS 클릭
            driver.execute_script(
                "arguments[0].scrollIntoView({block:'center'});", more_btn)
            driver.execute_script("arguments[0].click();", more_btn)

            logging.info("✅  더보기 버튼 클릭됨")
            time.sleep(1)                          # Ajax 로딩 대기

        except StaleElementReferenceException:
            logging.debug("↻  버튼이 재-렌더링됨, 다시 시도")
            continue                               # while True 처음으로

        except TimeoutException:
            logging.info("▶  더보기 버튼이 더 이상 없음 — 전체 상품 로드 완료")
            break
    
    soup = BeautifulSoup(driver.page_source, "html.parser")
    items = soup.select("a[data-gtm='search_article']")

    for item in items:
        try:
            link = "https://www.daangn.com" + item.get("href")
            spans = item.select("span")
            #img_tag = item.select_one("img")

            status = "판매중"
            title = "제목 정보 없음"
            price = "가격 정보 없음"
            region = "지역 정보 없음"

            text_spans = [s.text.strip() for s in spans if s.text.strip()]
            if text_spans:
                if text_spans[0] in ["예약중", "판매완료"]:
                    status = text_spans[0]
                    if len(text_spans) > 1:
                        title = text_spans[1]
                    if len(text_spans) > 2:
                        price = text_spans[2]
                    if len(text_spans) > 3:
                        region = text_spans[3].split("·")[0].strip()
                else:
                    if len(text_spans) > 0:
                        title = text_spans[0]
                    if len(text_spans) > 1:
                        price = text_spans[1]
                    if len(text_spans) > 2:
                        region = text_spans[2].split("·")[0].strip()

            #img_url = img_tag["src"] if img_tag else None

            driver.get(link)
            #detail_soup = BeautifulSoup(driver.page_source, "html.parser")

            #desc_tag = detail_soup.select_one("p.jy3q4ic")
            #time_tag = detail_soup.select_one("time")

            #description = desc_tag.text.strip() if desc_tag else "상세 설명 없음"
            #post_time = time_tag["datetime"] if time_tag and time_tag.has_attr("datetime") else "등록 시간 정보 없음"
            
            img_url = None
            try:
                og = WebDriverWait(driver, 2, poll_frequency=0.1).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, "meta[property='og:image']"))
                )
                img_url = og.get_attribute("content")
            except TimeoutException:
                # 백업: 페이지 내 첫번째 상품 이미지 시도
                try:
                    first_img = driver.find_element(By.CSS_SELECTOR, "article img")
                    img_url = (
                        first_img.get_attribute("src")
                        or first_img.get_attribute("data-src")
                        or (first_img.get_attribute("srcset") or "").split(" ")[0]
                    )
                except Exception:
                    img_url = None
            
            # 본문
            try:
                desc_elt = WebDriverWait(driver, 6).until(
                    EC.visibility_of_element_located(
                        (By.XPATH, "//*[@id='main-content']/article/div[1]/div[2]/section[2]/p")
                    )
                )
                description = desc_elt.text.strip()
                if not description:  # <br> 줄바꿈 보존
                    html = desc_elt.get_attribute("innerHTML") or ""
                    description = (html.replace("<br>", "\n")
                                    .replace("<br/>", "\n")
                                    .replace("<br />", "\n")
                                    .strip())
            except TimeoutException:
                description = "상세 설명 없음"

            # 등록 시간
            try:
                time_elt = WebDriverWait(driver, 3).until(
                    EC.presence_of_element_located((By.TAG_NAME, "time"))
                )
                post_time = time_elt.get_attribute("datetime") or "등록 시간 정보 없음"
            except TimeoutException:
                post_time = "등록 시간 정보 없음"

            results.append({
                "title": title,
                "price": price,
                "condition": "알 수 없음",
                "upload_time": post_time,
                "region": region,
                "url": link,
                "image_url": img_url,
                "status": status,
                "description": description,
                "platform": "당근마켓"
            })

        except Exception as e:
            logging.warning(f"❌ 항목 처리 중 오류 발생: {e}")
            continue

    # Persist per search_url to reduce data loss
    if results:
        try:
            save_to_mongodb(results, "당근마켓")
            logging.info(f"검색 배치 저장: {len(results)}건 ({region_url})")
        except Exception as e:
            logging.warning(f"검색 배치 저장 실패 ({region_url}): {e}")

    driver.quit()
    return results

def run_search_tasks(region_urls, keywords):
    tasks = []
    for region_url in region_urls:
        for keyword in keywords:
            search_url = region_url + "&search=" + quote(keyword)
            tasks.append((region_url, keyword, search_url))

    if not tasks:
        logging.warning("[daangn] No region/keyword combinations to crawl.")
        return []

    max_workers = min(MAX_WORKERS, len(tasks)) or 1
    all_results = []
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_meta = {
            executor.submit(scrape_daangn, search_url): (region_url, keyword)
            for region_url, keyword, search_url in tasks
        }
        for future in as_completed(future_to_meta):
            region_url, keyword = future_to_meta[future]
            try:
                result = future.result()
            except Exception as exc:
                logging.error(f"[daangn] Search failed for region={region_url} keyword={keyword}: {exc}")
                continue
            if result:
                all_results.extend(result)
    return all_results


if __name__ == "__main__":
    with open("region_list.txt", "r", encoding="utf-8") as f:
        region_urls = [line.strip() for line in f if line.strip()]

    keywords = ["아이폰", "갤럭시", "아이패드"]

    all_results = run_search_tasks(region_urls, keywords)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    os.makedirs("./output", exist_ok=True)
    path = f"./output/당근마켓_result_{timestamp}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=4)

    print(f"당근마켓 크롤링 완료 → {path} (총 {len(all_results)}개)")
    #save_to_mongodb(all_results, "당근마켓")
