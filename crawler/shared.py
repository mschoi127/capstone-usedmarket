import time
import re
import os
import json
import logging
from datetime import datetime, timedelta
from abc import ABC, abstractmethod
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.common.by import By
from bs4 import BeautifulSoup
from pymongo import MongoClient

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def parse_relative_time(text):
    now = datetime.now()
    m = re.match(r"(\d+)(초|분|시간|일) 전", text)
    if not m:
        return "시간 형식 오류"
    value, unit = m.groups()
    delta = {"초": timedelta(seconds=int(value)),
             "분": timedelta(minutes=int(value)),
             "시간": timedelta(hours=int(value)),
             "일": timedelta(days=int(value))}[unit]
    return (now - delta).strftime("%Y-%m-%d %H:%M:%S")

def init_browser():
    opts = Options()
    opts.add_argument("--headless")
    opts.add_argument("--no-sandbox")
    opts.add_argument("--disable-dev-shm-usage")
    driver = webdriver.Chrome(options=opts)
    driver.set_page_load_timeout(30)
    driver.implicitly_wait(3)
    return driver

def get_soup(driver):
    return BeautifulSoup(driver.page_source, "html.parser")

def wait_for_element(driver, by, value, timeout=5):
    try:
        WebDriverWait(driver, timeout).until(EC.visibility_of_element_located((by, value)))
    except:
        logging.warning(f"[경고] 요소 로딩 실패: {value} → fallback sleep 1초 적용")
        time.sleep(0.5)
        
# 당근마켓 전용
def wait_for_presence(driver, by, value, timeout=5):
    try:
        WebDriverWait(driver, timeout).until(EC.presence_of_element_located((by, value)))
    except:
        logging.warning(f"[경고] 요소 존재 감지 실패: {value} → fallback sleep 1초 적용")
        time.sleep(0.5)

def save_to_mongodb(data, platform):
    from pymongo import MongoClient
    client = MongoClient("mongodb://localhost:27017/")
    db = client["market2"]
    collection = db["products"]

    inserted = 0
    for item in data:
        item["platform"] = platform
        collection.insert_one(item)
        inserted += 1
    
    logging.info(f"MongoDB에 {inserted}개 저장 완료 ({platform})")
    client.close()

class BaseCrawler(ABC):
    def __init__(self, name, base_urls):
        self.name = name
        self.base_urls = base_urls
        self.driver = init_browser()
        self.results = []
        self.filtered_count = 0  # 매입/삽니다 필터 개수 누적용

    @abstractmethod
    def get_links(self, url):
        pass

    @abstractmethod
    def parse_detail(self, url):
        pass

    def crawl(self, start_page, end_page):
        from pymongo import MongoClient  # 중복 확인용 DB 연결 추가
        client = MongoClient("mongodb://localhost:27017/")
        collection = client["market2"]["products"]
        
        ad_total_skipped = 0  # 광고 건너뛴 총 개수 카운트
        duplicate_skipped = 0  # 중복 카운트

        for category, base_url in self.base_urls.items():
            logging.info(f"▶ {self.name} 크롤링 시작 — {category} ({start_page}~{end_page} 페이지)")
            for page in range(start_page, end_page + 1):
                page_url = self.build_page_url(base_url, page)
                result = self.get_links(page_url)

                # get_links() 결과 처리
                if isinstance(result, tuple):
                    links, ad_skipped = result
                    ad_total_skipped += ad_skipped
                else:
                    links = result

                if not links:
                    break
                
                for link in links:
                    # 상세 페이지 진입 전 중복 검사
                    if collection.find_one({"url": link}):
                        duplicate_skipped += 1
                        continue
                    
                    data = self.parse_detail(link)
                    if data:
                        data["category"] = category
                        data["platform"] = self.name
                        self.results.append(data)

        logging.info(f"광고 필터링: {ad_total_skipped}개")
        logging.info(f"매입/삽니다 필터링: {self.filtered_count}개")
        logging.info(f"중복 필터링: {duplicate_skipped}개")
        client.close()
        self.driver.quit()

    def save(self):
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        os.makedirs("./output", exist_ok=True)
        path = f"./output/{self.name}_result_{timestamp}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.results, f, ensure_ascii=False, indent=4)
        print(f"{self.name} 크롤링 완료 → {path} (총 {len(self.results)}개)")
        save_to_mongodb(self.results, self.name)

    def restart_driver(self):
        try:
            self.driver.quit()
        except Exception:
            pass
        self.driver = init_browser()

    def build_page_url(self, base_url, page):
        return f"{base_url}&page={page}"
