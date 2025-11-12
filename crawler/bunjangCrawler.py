from shared import BaseCrawler, parse_relative_time, wait_for_element, get_soup, save_to_mongodb
import re
import logging
from selenium.webdriver.common.by import By

class BunjangCrawler(BaseCrawler):
    def __init__(self):
        base_urls = {
            "스마트폰": "https://m.bunjang.co.kr/categories/600700001?&order=date",
            "태블릿": "https://m.bunjang.co.kr/categories/600710100?&order=date",
            #"웨어러블": "https://m.bunjang.co.kr/categories/600720?order=date",
            #"오디오/영상": "https://m.bunjang.co.kr/categories/600500?order=date",
            #"PC/노트북": "https://m.bunjang.co.kr/categories/600100?order=date",
            #"PC부품/저장장치": "https://m.bunjang.co.kr/categories/600200?order=date",
        }
        super().__init__("번개장터", base_urls) 

    def get_links(self, url):
        self.driver.get(url)
        wait_for_element(self.driver, By.CSS_SELECTOR, "a[href^='/products/']")
        soup = get_soup(self.driver)
        links = set()
        ad_skipped = 0
        for a in soup.select("a[href^='/products/']"):
            if any(text == "AD" for text in a.stripped_strings):
                ad_skipped += 1
                continue
            href = a["href"].split("?")[0]
            links.add("https://m.bunjang.co.kr" + href)
        return list(links), ad_skipped

    def parse_detail(self, url):
        try:
            self.driver.get(url)
        except Exception as e:
            logging.warning(f"상세 페이지 로딩 실패: {url} — {e}")
            return None
        
        wait_for_element(self.driver, By.CSS_SELECTOR, "div.ProductSummarystyle__Name-sc-oxz0oy-3")
        soup = get_soup(self.driver)

        #desc = soup.select_one("div.ProductInfostyle__DescriptionContent-sc-ql55c8-3.eJCiaL")
        #if desc and "매입" in desc.get_text():
        #    return None

        title = soup.select_one("div.ProductSummarystyle__Name-sc-oxz0oy-3")
        title_text = title.get_text(strip=True) if title else "제목없음"
        if re.search(r"(매입|삽니다)", title_text):
            self.filtered_count += 1
            return None

        price = soup.select_one("div.ProductSummarystyle__Price-sc-oxz0oy-5")
        price_text = price.get_text(strip=True) if price else "가격 정보 없음"

        raw_time = "0초 전"
        for div in soup.select("div.ProductSummarystyle__Status-sc-oxz0oy-11"):
            txt = div.get_text(strip=True)
            if re.match(r"\d+(초|분|시간|일) 전", txt):
                if div.img:
                    div.img.decompose()
                raw_time = txt
                break
        upload_time = parse_relative_time(raw_time)

        label_value_map = {}
        labels = soup.select("div.ProductSummarystyle__Label-sc-oxz0oy-20")
        values = soup.select("div.ProductSummarystyle__Value-sc-oxz0oy-21")
        for label, value in zip(labels, values):
            key = label.get_text(strip=True).replace(" ", "")  # 공백 제거
            val = value.get_text(strip=True)
            label_value_map[key] = val

        condition = label_value_map.get("•상품상태", "제품 상태 정보 없음")
        #delivery_fee = label_value_map.get("•배송비", "배송비 정보 없음")
        direct_location = label_value_map.get("•직거래지역", "직거래 지역 정보 없음")

        img = soup.find("img", src=lambda x: x and x.startswith("https://media.bunjang.co.kr/product/"))
        status_img = soup.select_one("div.Productsstyle__ProductStatus-sc-13cvfvh-39 img")
        status = status_img["alt"].strip() if status_img else "판매중"

        return {
            "title": title_text,
            "price": price_text,
            "condition": condition,
            "upload_time": upload_time,
            "region": direct_location,
            "url": url,
            "image_url": img["src"] if img else "",
            "status": status
        }

if __name__ == "__main__":
    crawler = BunjangCrawler()
    crawler.crawl(start_page=1, end_page=100)
    crawler.save()
