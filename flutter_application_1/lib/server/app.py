# app.py
import os, re, json, logging, httpx
from datetime import datetime, timedelta
from typing import Any, Dict, List, Literal, Optional
from dotenv import load_dotenv
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import google.generativeai as genai

# =========================
# 환경설정
# =========================
load_dotenv()
GOOGLE_API_KEY = os.getenv("GOOGLE_API_KEY", "")
GENIMI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.0-flash-lite")

PRODUCT_BASE = os.getenv("BACKEND_BASE_URL", "http://localhost:3001").rstrip("/")
PRODUCT_API = f"{PRODUCT_BASE}/products"
PRICE_TREND_API = f"{PRODUCT_BASE}/products/price-trend"
RECOMMEND_PRICE_API = f"{PRODUCT_BASE}/products/recommend-price"

if not GOOGLE_API_KEY:
    raise RuntimeError("GOOGLE_API_KEY가 설정되지 않음")
genai.configure(api_key=GOOGLE_API_KEY)
llm = genai.GenerativeModel(model_name=GENIMI_MODEL)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
log = logging.getLogger("gateway")

# =========================
# FastAPI & CORS
# =========================
app = FastAPI(title="LLM Gateway (Flutter용)")
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",")],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =========================
# 모델 (Flutter와 동일 포맷)
# =========================
class ClientCtx(BaseModel):
    keyword: Optional[str] = None
    platforms: List[str] = Field(default_factory=lambda: ["번개장터", "당근마켓", "중고나라"])
    sort: Literal["latest", "price_asc", "price_desc"] = "latest"
    minPrice: Optional[int] = None
    maxPrice: Optional[int] = None
    page: int = 1
    limit: int = 5

class ChatRequest(BaseModel):
    message: str
    context: Dict[str, Any] | None = None   # 레거시
    client_ctx: ClientCtx | None = None     # 권장
    conversation_id: Optional[str] = None

class Card(BaseModel):
    title: str
    price: str
    url: Optional[str] = None
    image_url: Optional[str] = None
    platform: Optional[str] = None
    uploaded_at: Optional[str] = None

class ChatResponse(BaseModel):
    text: str
    cards: List[Card] = Field(default_factory=list)
    memory: Dict[str, Any] = Field(default_factory=dict)
    trend: Dict[str, Any] | None = None

# =========================
# 유틸
# =========================
PRICE_INTENT_HINTS = ("시세", "가격 추세", "평균가", "그래프", "차트", "trend", "트렌드")

def _force_price_intent(user_q: str) -> bool:
    q = (user_q or "").lower()
    return any(h in q for h in PRICE_INTENT_HINTS)

def _extract_json(s: str) -> Dict[str, Any]:
    m = re.search(r"\{[\s\S]*\}|\[[\s\S]*\]", s or "")
    if not m: return {}
    try: return json.loads(m.group(0))
    except Exception: return {}

async def _parse_intent_and_params(user_q: str, last: Dict[str, Any] | None) -> Dict[str, Any]:
    sys = (
        "아래 JSON 스키마로만 대답:\n"
        '{"intent":"제품_추천|시세_분석|일반_대화|가격_추천|기타",'
        '"followup":true|false,'
        '"model":"","min_price":null,"max_price":null,"condition":"","sort":""}'
    )
    prompt = (
        f"사용자의 이전 조건: {json.dumps(last or {}, ensure_ascii=False)}\n"
        f"새 질문: \"{user_q}\"\n{sys}"
    )
    try:
        out = await llm.generate_content_async(
            prompt, generation_config={"temperature":0.0, "max_output_tokens":256}
        )
        data = _extract_json(out.text or "")
        if not isinstance(data, dict):
            data = {}
    except Exception as e:
        log.warning("intent LLM 실패: %s", e)
        data = {}

    # 강제 보정: '시세/차트'류 키워드면 무조건 시세_분석
    if _force_price_intent(user_q):
        data["intent"] = "시세_분석"

    # 기본값 보정
    data.setdefault("intent", "기타")
    data.setdefault("followup", False)
    for k in ("model","min_price","max_price","condition","sort"):
        data.setdefault(k, None)
    return data

def _norm_sort(v: Optional[str]) -> str:
    if v in ("low","가격낮은순","price_asc"): return "price_asc"
    if v in ("high","가격높은순","price_desc"): return "price_desc"
    return "latest"

# =========================
# 외부 API 호출
# =========================
async def _call_products(params: Dict[str, Any]) -> List[Dict[str, Any]]:
    try:
        async with httpx.AsyncClient(timeout=12) as c:
            r = await c.get(PRODUCT_API, params=params)
            r.raise_for_status()
            return r.json()
    except Exception as e:
        log.warning("products 호출 실패: %s", e)
        return []

async def _call_price_trend(keyword: str) -> Dict[str, Any]:
    if not keyword: return {}
    try:
        async with httpx.AsyncClient(timeout=12) as c:
            r = await c.get(PRICE_TREND_API, params={"keyword": keyword})
            r.raise_for_status()
            return r.json()
    except Exception as e:
        log.warning("price-trend 호출 실패: %s", e)
        return {}

async def _call_recommend_price(keyword: str) -> Dict[str, Any]:
    if not keyword: return {}
    try:
        async with httpx.AsyncClient(timeout=12) as c:
            r = await c.get(RECOMMEND_PRICE_API, params={"keyword": keyword})
            r.raise_for_status()
            return r.json()
    except Exception as e:
        log.warning("recommend-price 호출 실패: %s", e)
        return {}

# =========================
# 상태
# =========================
# 간단히 메모리 저장(세션 대용): 최근 질문 조건 1개
_last_condition: Dict[str, Any] = {}
_last_intent: str = ""

# =========================
# 엔드포인트
# =========================
@app.get("/health")
async def health():
    return {"ok": True, "backend": PRODUCT_BASE}

@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest):
    global _last_condition, _last_intent

    user_q = (req.message or "").strip()

    # 프런트에서 넘어온 컨텍스트 우선
    ctx = req.client_ctx or (ClientCtx(**req.context) if isinstance(req.context, dict) else ClientCtx())

    # 1) 의도/파라미터 파싱
    parsed = await _parse_intent_and_params(user_q, _last_condition or {})
    intent = parsed["intent"]
    followup = bool(parsed.get("followup"))
    model = (parsed.get("model") or "").strip()
    min_price = parsed.get("min_price")
    max_price = parsed.get("max_price")
    sort = _norm_sort(parsed.get("sort"))

    # 후속이면 이전 조건 병합
    if followup and _last_condition:
        base = _last_condition.copy()
        if model: base["model"] = model
        if min_price is not None: base["min_price"] = min_price
        if max_price is not None: base["max_price"] = max_price
        if sort: base["sort"] = sort
        merged = base
    else:
        merged = {"model": model, "min_price": min_price, "max_price": max_price, "sort": sort}

    # 메모리 업데이트
    _last_condition = merged.copy()
    _last_intent = intent

    # 2) 분기 처리
    cards: List[Card] = []
    trend: Dict[str, Any] | None = None
    text: str = ""

    # ---- 시세_분석: 차트 전용(카드 금지) ----
    if intent == "시세_분석":
        key = merged.get("model") or ctx.keyword or ""
        trend = await _call_price_trend(key)
        # 요약 텍스트(선택)
        if trend:
            # 간단 평균 요약
            vals = []
            for p, days in trend.items():
                for d, stat in (days or {}).items():
                    used = (stat or {}).get("used", {})
                    if isinstance(used.get("avg"), (int, float)):
                        vals.append(float(used["avg"]))
            if vals:
                avg = sum(vals) / len(vals)
                text = f"최근 7일 {key} 중고 평균가 약 {int(round(avg)):,}원."
        # 카드 비움
        cards = []

    # ---- 가격_추천: 권장가 텍스트 + (선택) 카드 간단 노출 ----
    elif intent == "가격_추천":
        key = merged.get("model") or ctx.keyword or ""
        rec = await _call_recommend_price(key)
        parts = []
        if isinstance(rec.get("new"), dict):
            parts.append(f"새상품 권장가 {rec['new'].get('recommended', 0):,}원")
        if isinstance(rec.get("used"), dict):
            parts.append(f"중고 권장가 {rec['used'].get('recommended', 0):,}원")
        text = " / ".join(parts) if parts else "권장가 산출에 필요한 데이터가 부족합니다."

        # 보조 카드(상위 5개)
        params = {
            "keyword": key,
            "platform": ",".join(ctx.platforms),
            "sort": {"latest": "newest", "price_asc": "low", "price_desc": "high"}[ctx.sort],
            "minPrice": ctx.minPrice, "maxPrice": ctx.maxPrice, "page": 1, "limit": 5,
        }
        items = await _call_products({k: v for k, v in params.items() if v not in (None, "", [])})
        for p in items[:5]:
            cards.append(Card(
                title=str(p.get("title","")), price=str(p.get("price","")),
                url=p.get("url") or p.get("link"),
                image_url=p.get("image_url") or p.get("imageUrl") or p.get("image") or p.get("thumbnail"),
                platform=p.get("platform"), uploaded_at=p.get("upload_time") or p.get("uploaded_at"),
            ))

    # ---- 제품_추천: 카드 중심 ----
    elif intent == "제품_추천":
        key = merged.get("model") or ctx.keyword or ""
        params = {
            "keyword": key,
            "platform": ",".join(ctx.platforms),
            "sort": {"latest": "newest", "price_asc": "low", "price_desc": "high"}[ctx.sort],
            "minPrice": ctx.minPrice, "maxPrice": ctx.maxPrice, "page": ctx.page, "limit": ctx.limit,
        }
        items = await _call_products({k: v for k, v in params.items() if v not in (None, "", [])})
        for p in items[:5]:
            cards.append(Card(
                title=str(p.get("title","")), price=str(p.get("price","")),
                url=p.get("url") or p.get("link"),
                image_url=p.get("image_url") or p.get("imageUrl") or p.get("image") or p.get("thumbnail"),
                platform=p.get("platform"), uploaded_at=p.get("upload_time") or p.get("uploaded_at"),
            ))
        text = ""  # 카드만

    # ---- 일반/기타: 안내만 ----
    else:
        text = "원하시는 기능을 선택하세요: 제품_추천 / 시세_분석 / 가격_추천"

    # 3) 메모리(프론트가 재사용)
    memory = {"last_ctx": {
        "keyword": merged.get("model") or ctx.keyword,
        "platforms": ctx.platforms, "sort": ctx.sort,
        "minPrice": ctx.minPrice, "maxPrice": ctx.maxPrice, "page": ctx.page, "limit": ctx.limit,
    }, "last_intent": intent}

    return ChatResponse(text=text, cards=cards, memory=memory, trend=trend)
