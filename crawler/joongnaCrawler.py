from shared import BaseCrawler, parse_relative_time, wait_for_element, get_soup
from db_utils import save_to_mongodb_upsert
import os
import json
import re
import time
import logging
from selenium.webdriver.common.by import By
from selenium.common.exceptions import TimeoutException, WebDriverException

class JoongnaCrawler(BaseCrawler):
    EMPTY_PAGE_RETRIES = 2
    MAX_SCROLL_ATTEMPTS = 12
    SCROLL_PAUSE = 0.4

    def __init__(self):
        base_urls = {
            "스마트폰": "https://web.joongna.com/search?category=139&saleYn=SALE_Y&sort=RECENT_SORT",
            "태블릿PC": "https://web.joongna.com/search?category=140&saleYn=SALE_Y&sort=RECENT_SORT",
        }
        super().__init__("중고나라", base_urls)

    def get_links(self, url, max_attempts=3):
        last_error = None
        for attempt in range(1, max_attempts + 1):
            try:
                self.driver.get(url)
                wait_for_element(self.driver, By.CSS_SELECTOR, "a[href^='/product/']")
                links = self._collect_links()
                return links, 0
            except TimeoutException as exc:
                last_error = exc
                logging.warning(f"[{self.name}] Page load timeout ({attempt}/{max_attempts}) for {url}")
                try:
                    self.driver.execute_script("window.stop();")
                except Exception:
                    pass
                self.restart_driver()
            except WebDriverException as exc:
                last_error = exc
                logging.warning(f"[{self.name}] Page load failed ({attempt}/{max_attempts}) for {url}: {exc}")
                self.restart_driver()
        if last_error:
            raise last_error
        return [], 0

    def _collect_links(self):
        collected = set()
        stagnant_rounds = 0
        last_count = 0

        for _ in range(self.MAX_SCROLL_ATTEMPTS):
            anchors = self.driver.find_elements(By.CSS_SELECTOR, "a[href^='/product/']")
            for a in anchors:
                href = a.get_attribute("href") or ""
                if not href:
                    continue
                if href.startswith("/product/"):
                    href = "https://web.joongna.com" + href
                if "/product/" not in href:
                    continue
                collected.add(href.split("?")[0])

            if len(collected) == last_count:
                stagnant_rounds += 1
            else:
                last_count = len(collected)
                stagnant_rounds = 0

            if stagnant_rounds >= 2:
                break

            try:
                self.driver.execute_script("window.scrollTo(0, document.body.scrollHeight);")
            except Exception:
                break
            time.sleep(self.SCROLL_PAUSE)

        return list(collected)

    def parse_detail(self, url):
        try:
            self.driver.get(url)
        except Exception as e:
            logging.warning(f"상세 페이지 로딩 실패: {url} — {e}")
            return None
        
        wait_for_element(self.driver, By.CSS_SELECTOR, "h1")
        soup = get_soup(self.driver)

        #post_content = soup.select_one("div.flex.flex-col.h-auto")
        #if post_content and "매입" in post_content.get_text():
        #    return None

        #title = soup.select_one("div.flex.items-center.justify-between.mb-1 h1")
        #title_text = title.get_text(strip=True) if title else "제목없음"
        
        # 상세 제목: h1이 뜨면 바로 사용, 실패 시 og:title 백업
        title_text = "제목없음"
        try:
            h1 = self.driver.find_element(By.TAG_NAME, "h1")
            candidate = (h1.text or h1.get_attribute("innerText") or "").strip()
            if candidate:
                title_text = candidate
        except Exception:
            pass
        if title_text == "제목없음":
            try:
                og = self.driver.find_element(By.CSS_SELECTOR, "meta[property='og:title']")
                candidate = (og.get_attribute("content") or "").strip()
                if candidate:
                    title_text = candidate
            except Exception:
                pass

        if re.search(r"(매입|삽니다)", title_text):
            self.filtered_count += 1
            return None

        price_div = soup.select_one('div[class*="font-bold"][class*="text-heading"]')
        price_text = price_div.get_text(strip=True) if price_div else "가격 정보 없음"

        time_info = soup.select_one("div.flex.items-center.justify-between.mb-4.text-xs.font-normal span")
        upload_time = "시간 정보 없음"
        if time_info:
            time_text = time_info.get_text(strip=True)
            time_match = re.match(r"\d+(초|분|시간|일) 전", time_text)
            if time_match:
                upload_time = parse_relative_time(time_match.group())

        #condition = "제품 상태 정보 없음"
        #condition_li = soup.select_one("ul.box-border.flex.text-center.border.border-gray-300.rounded.items-center.py-6.mb-6 li:nth-child(1) button")
        #if condition_li:
        #    condition = condition_li.get_text(strip=True)
        
        # dt가 '상품 상태'인 행의 dd 값을 가져옴 → '중고' 등
        condition = "제품 상태 정보 없음"
        condition_xpaths = [
            "//*[@id='__next']//span[normalize-space()='상품 상태']/following-sibling::*[1]//p[1]",
            "//*[@id='__next']//span[normalize-space()='상품 상태']/following-sibling::*[1]//*[self::p or self::button or self::span][1]",
            "//*[@id='__next']//main//dl//dd[1]//*[self::p or self::button][1]",
        ]

        for xpath in condition_xpaths:
            try:
                elems = self.driver.find_elements(By.XPATH, xpath)
                if not elems:
                    continue
                text_candidate = (elems[0].text or elems[0].get_attribute("innerText") or "").strip()
                if text_candidate:
                    condition = text_candidate
                    break
            except Exception:
                continue

        if condition == "제품 상태 정보 없음":
            # 최후 백업: BeautifulSoup로 형제 요소 텍스트 추출
            label = soup.find("span", string=lambda s: s and "상품 상태" in s)
            if label:
                next_elem = label.find_next(["p", "button", "span"])
                if next_elem:
                    text_candidate = next_elem.get_text(strip=True)
                    if text_candidate:
                        condition = text_candidate

        #region = "거래 지역 정보 없음"
        #region_block = soup.select_one("div.pb-5")
        #if region_block:
        #    region_span = region_block.select_one("button span")
        #    if region_span:
        #        region = region_span.get_text(strip=True)
        
        region = "거래 지역 정보 없음"
        region_xpaths = [
            "//*[@id='__next']/div/main/div[1]/div[1]/div[2]/div[4]/div[2]/dl/div/dd/button/p",
            "//*[@id='__next']//main//dl//dd//button/p",
        ]
        for xpath in region_xpaths:
            try:
                elems = self.driver.find_elements(By.XPATH, xpath)
                if not elems:
                    continue
                text_candidate = (elems[0].text or elems[0].get_attribute("innerText") or "").strip()
                if text_candidate:
                    region = text_candidate
                    break
            except Exception:
                continue
        if region == "거래 지역 정보 없음":
            label = soup.find("span", string=lambda s: s and ("거래 지역" in s or "거래지역" in s))
            if label:
                next_elem = label.find_next(["p", "button", "span"])
                if next_elem:
                    text_candidate = next_elem.get_text(strip=True)
                    if text_candidate:
                        region = text_candidate

        #delivery_fee = "배송비 정보 없음"
        #delivery_fee_li = soup.select_one("ul.box-border.flex.text-center.border.border-gray-300.rounded.items-center.py-6.mb-6 li:nth-child(3) button")
        #if delivery_fee_li:
        #    delivery_fee = delivery_fee_li.get_text(strip=True)

        img_tag = soup.find("img", src=lambda x: x and x.startswith("https://img2.joongna.com/media/original/"))

        return {
            "title": title_text,
            "price": price_text,
            "condition": condition,
            "upload_time": upload_time,
            "region": region,
            "url": url,
            "image_url": img_tag["src"] if img_tag else "",
            "status": "판매중"
        }

    # 페이지 단위 저장: 각 페이지 완료 시 DB에 upsert 저장
    def crawl(self, start_page, end_page):
        from pymongo import MongoClient
        client = MongoClient("mongodb://localhost:27017/")
        collection = client["market2"]["products"]

        ad_total_skipped = 0
        duplicate_skipped = 0

        for category, base_url in self.base_urls.items():
            logging.info(f"[{self.name}] 카테고리 시작: {category} ({start_page}~{end_page} 페이지)")
            for page in range(start_page, end_page + 1):
                page_url = self.build_page_url(base_url, page)
                links = []
                ad_skipped = 0
                page_failed = False

                remaining_empty_retries = self.EMPTY_PAGE_RETRIES
                while True:
                    try:
                        result = self.get_links(page_url)
                    except (TimeoutException, WebDriverException) as exc:
                        logging.warning(f"[{self.name}] 페이지 로딩 실패: {category} {page}페이지 — {exc}")
                        page_failed = True
                        break

                    if isinstance(result, tuple):
                        links, ad_skipped = result
                    else:
                        links = result
                        ad_skipped = 0

                    if links:
                        ad_total_skipped += ad_skipped
                        break

                    if remaining_empty_retries == 0:
                        logging.warning(
                            f"[{self.name}] 링크를 찾지 못해 페이지 건너뜀: {category} {page}페이지"
                        )
                        break

                    logging.warning(
                        f"[{self.name}] 링크 없음 → 재시도 ({category} {page}페이지, 남은 재시도 {remaining_empty_retries})"
                    )
                    if remaining_empty_retries == 1:
                        self.restart_driver()
                    else:
                        try:
                            self.driver.refresh()
                        except Exception:
                            pass
                    time.sleep(0.4)
                    remaining_empty_retries -= 1

                if page_failed:
                    self.restart_driver()
                    continue

                if not links:
                    continue

                page_results = []
                for link in links:
                    # 이미 DB에 있으면 스킵
                    if collection.find_one({"url": link}):
                        duplicate_skipped += 1
                        continue

                    data = self.parse_detail(link)
                    if data:
                        data["category"] = category
                        data["platform"] = self.name
                        self.results.append(data)
                        page_results.append(data)

                if page_results:
                    try:
                        save_to_mongodb_upsert(page_results, self.name)
                        logging.info(f"[{self.name}] 페이지 저장 완료: {len(page_results)}건 (카테고리: {category}, 페이지: {page})")
                    except Exception as e:
                        logging.warning(f"[{self.name}] 페이지 저장 실패 (카테고리: {category}, 페이지: {page}): {e}")

        logging.info(f"광고 필터 스킵: {ad_total_skipped}건")
        logging.info(f"매입/의니어 필터: {self.filtered_count}건")
        logging.info(f"중복 스킵: {duplicate_skipped}건")
        client.close()
        self.driver.quit()

    # 최종 저장은 JSON 파일만 기록 (DB는 페이지 단위로 이미 저장됨)
    def save(self):
        from datetime import datetime
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        os.makedirs("./output", exist_ok=True)
        path = f"./output/{self.name}_result_{timestamp}.json"
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.results, f, ensure_ascii=False, indent=4)
        print(f"{self.name} 크롤링 완료 → {path} (총 {len(self.results)}개)")

if __name__ == "__main__":
    crawler = JoongnaCrawler()
    crawler.crawl(start_page=1, end_page=500)
    crawler.save()
