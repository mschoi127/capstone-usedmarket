const { GoogleGenerativeAI } = require('@google/generative-ai');
const Product = require('../models/Product');
const {
  model_synonyms: MODEL_SYNONYMS_CFG,
  storage_synonyms: STORAGE_SYNONYMS_CFG
} = require('../config/modelSynonyms.json');

const {
  createReferenceRange,
  createReferenceAndPreviousRanges,
  calculateListingRecommendation
} = require('./productController');

const DEFAULT_STATE = {
  stage: 'awaiting_model',
  model: null,
  storage: null,
  condition: null,
};

const CONDITION_TIERS = {
  s: 'S급',
  a: 'A급',
  b: 'B급',
  c: 'C급',
};

const CONDITION_GROUP_MAP = {
  's급': ['새 상품', '사용감 없음'],
  s: ['새 상품', '사용감 없음'],
  'a급': ['사용감 적음'],
  a: ['사용감 적음'],
  'b급': ['사용감 많음'],
  b: ['사용감 많음'],
  'c급': ['고장/파손 상품'],
  c: ['고장/파손 상품'],
};

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) {
  throw new Error('GEMINI_API_KEY 환경 변수가 설정되어 있지 않습니다.');
}
const gemini = new GoogleGenerativeAI(apiKey);
const LLM_MODEL = process.env.GEMINI_MODEL || 'gemini-2.5-flash';

const llmClient = gemini.getGenerativeModel({
  model: LLM_MODEL,
  generationConfig: { responseMimeType: 'application/json' },
});

const normalizeText = (value = '') =>
  value.toLowerCase().replace(/[^0-9a-z가-힣]/g, '');

const normalizeConditionKey = (value = '') =>
  value.toLowerCase().replace(/\s+/g, '');

const formatStorageLabel = (value = '') => {
  if (!value) return '';
  const lowered = value.toLowerCase();
  if (lowered === '1tb') return '1TB';
  const digits = value.replace(/[^0-9]/g, '');
  return digits ? `${digits}GB` : value.toUpperCase();
};

function buildSynonymList(source = {}) {
  const list = [];
  Object.entries(source).forEach(([canonical, synonyms]) => {
    if (!Array.isArray(synonyms)) return;
    synonyms
      .filter((v) => typeof v === 'string' && v.trim().length)
      .forEach((synonym) =>
        list.push({ synonym: normalizeText(synonym), canonical })
      );
  });
  list.sort((a, b) => b.synonym.length - a.synonym.length);
  return list;
}

const MODEL_SYNONYM_LIST = buildSynonymList(MODEL_SYNONYMS_CFG);
const STORAGE_SYNONYM_LIST = buildSynonymList(STORAGE_SYNONYMS_CFG);

const parseStorageFromMessage = (input = '') => {
  const lowered = input.toLowerCase();
  const direct = lowered.match(/(\d{2,4})\s*(g|gb|기가|기|giga)/i);
  if (direct) {
    const raw = direct[1];
    return `${raw}${raw.length === 4 ? '' : ''}g`.replace('gg', 'g');
  }

  const normalized = normalizeText(input);
  for (const { synonym, canonical } of STORAGE_SYNONYM_LIST) {
    if (normalized.includes(synonym)) return canonical;
  }
  return null;
};

const canonicalizeModel = (value = '') => {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  for (const { synonym, canonical } of MODEL_SYNONYM_LIST) {
    if (normalized.includes(synonym)) return canonical;
  }
  return null;
};

const stageOrder = {
  awaiting_model: 'awaiting_model',
  awaiting_storage: 'awaiting_storage',
  awaiting_condition: 'awaiting_condition',
  ready: 'ready',
};

const parsePriceValue = (value) => {
  if (value == null) return null;
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const digits = value.replace(/[^0-9]/g, '');
    if (!digits) return null;
    return parseInt(digits, 10);
  }
  return null;
};

const parseUploadDate = (value) => {
  if (!value) return null;
  const trimmed = value.trim();
  if (!trimmed) return null;
  const direct = new Date(trimmed.replace('Z', '+00:00'));
  if (!Number.isNaN(direct.getTime())) return direct;
  const formats = [
    /(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?/,
    /(\d{4})-(\d{1,2})-(\d{1,2})/,
    /(\d{4})\.(\d{1,2})\.(\d{1,2})/,
  ];
  for (const regex of formats) {
    const match = trimmed.match(regex);
    if (match) {
      const [, y, m, d, hh = '0', mm = '0', ss = '0'] = match;
      return new Date(
        parseInt(y, 10),
        parseInt(m, 10) - 1,
        parseInt(d, 10),
        parseInt(hh, 10),
        parseInt(mm, 10),
        parseInt(ss, 10)
      );
    }
  }
  return null;
};

const trimOutliers = (values = [], lowerFrac = 0.1) => {
  if (!values.length) return [];
  const sorted = [...values].sort((a, b) => a - b);
  const cut = Math.floor(sorted.length * lowerFrac);
  if (cut * 2 >= sorted.length) return sorted;
  return sorted.slice(cut, sorted.length - cut);
};

const safeJsonParse = (text, key) => {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch (err) {
    const match = text.match(/\{[\s\S]*\}/);
    if (match) {
      try {
        return JSON.parse(match[0]);
      } catch (_) {
        return null;
      }
    }
  }
  return null;
};

const runGemini = async (instruction) => {
  try {
    const result = await llmClient.generateContent(instruction);
    return result.response?.text();
  } catch (error) {
    console.error('Gemini API error:', error);
    return null;
  }
};

const extractModelText = async (input) => {
  const prompt = `당신은 사용자가 언급한 스마트폰 모델명을 추출하는 도우미입니다.
가능한 경우 정확한 모델 문자열만 반환하세요. 예시: "갤럭시 S24 울트라", "아이폰 15 프로".
입력: """${input}"""
응답 형식(JSON): {"model_text": "<모델명 또는 빈 문자열>"}.
`;
  const text = await runGemini(prompt);
  const parsed = safeJsonParse(text, 'model_text');
  const value = parsed?.model_text || '';
  return value.trim();
};

const heuristicTier = (input = '') => {
  const lowered = input.toLowerCase();
  if (
    /새\s*상품|미개봉|새것|s급|s\-?grade|sealed|unused/.test(lowered)
  ) {
    return 's';
  }
  if (
    /거의\s*새것|사용감\s*없음|미세\s*사용|깨끗|a급/.test(lowered)
  ) {
    return 'a';
  }
  if (
    /흠집|스크래치|찍힘|잔상|약간의\s*사용감|배터리\s*8\d|b급/.test(lowered)
  ) {
    return 'b';
  }
  if (
    /고장|파손|수리필요|배터리\s*7\d|불량|c급|문제/.test(lowered)
  ) {
    return 'c';
  }
  return null;
};

const classifyConditionTier = async (input) => {
  const prompt = `사용자가 설명한 스마트폰 상태를 아래 등급 중 하나로 분류하세요.
- S: 새 상품/사용감 없음
- A: 사용감 적음(미세 사용감)
- B: 사용감 있음(눈에 띄는 흠집/배터리 열화 등)
- C: 고장/파손 또는 기능 이상
입력: """${input}"""
응답 JSON: {"tier": "S" | "A" | "B" | "C"}
`;
  const text = await runGemini(prompt);
  const parsed = safeJsonParse(text, 'tier');
  let tier = (parsed?.tier || '').toLowerCase();
  if (['s', 'a', 'b', 'c'].includes(tier)) return tier;
  tier = heuristicTier(input);
  return tier;
};

const detectIntent = async (input) => {
  const prompt = `사용자 메시지를 보고 의도를 분류하세요.
- "price" : 시세, 평균가, 가격 추세를 알고 싶은 경우
- "recommendation" : 매물 추천, 매물 목록, 어디서 사야 할지 질문
- "sell_price" : 기기를 판매하려고 할 때 얼마에 올려야 할지 묻는 경우
- "reset" : 다른 모델을 다시 확인하거나 모델 선택을 처음부터 다시 하고 싶다는 의사 표현
- "platform_compare" : 플랫폼별 가격/비교, 어디에 올리면 잘 팔릴지 등의 질문
- "other" : 위 항목에 해당하지 않음
입력: """${input}"""
응답 JSON: {"intent": "price"|"recommendation"|"sell_price"|"reset"|"platform_compare"|"other"}
`;
  const text = await runGemini(prompt);
  const parsed = safeJsonParse(text, 'intent');
  const intent = (parsed?.intent || '').toLowerCase();
  if (
    intent === 'price' ||
    intent === 'recommendation' ||
    intent === 'sell_price' ||
    intent === 'reset' ||
    intent === 'platform_compare'
  ) {
    return intent;
  }
  return 'other';
};

const formatCurrency = (value) =>
  value == null ? '-' : `${value.toLocaleString('ko-KR')}원`;

const expandTier = (tier) => {
  if (!tier) return null;
  const normalized = normalizeConditionKey(tier);
  if (CONDITION_GROUP_MAP[normalized]) {
    return CONDITION_GROUP_MAP[normalized];
  }
  return CONDITION_GROUP_MAP[tier] || [tier];
};

const summarizePrices = (values) => {
  if (!values.length) return null;
  const trimmed = trimOutliers(values, 0.1);
  const sum = trimmed.reduce((acc, cur) => acc + cur, 0);
  const average = Math.round(sum / trimmed.length);
  const range = trimOutliers(values, 0.1);
  return {
    average,
    low: range.length ? range[0] : null,
    high: range.length ? range[range.length - 1] : null,
    count: values.length,
  };
};

const roundToStepValue = (value, step = 5000) => {
  if (value == null) return null;
  return Math.round(value / step) * step;
};

const fetchMarketSummary = async ({ model, storage, condition }) => {
  const { start, end } = createReferenceRange(7);
  const { previousStart, previousEnd } = createReferenceAndPreviousRanges(7);
  const filter = {
    model_name: model,
    storage,
  };
  const groups = expandTier(condition);
  if (groups) {
    filter.condition = { $in: groups };
  }

  const docs = await Product.find(filter)
    .select({ price: 1, upload_time: 1 })
    .limit(6000)
    .lean();

  const current = [];
  const previous = [];
  const allowedPlatforms = ['당근마켓', '중고나라', '번개장터'];
  const platformBuckets = {};
  docs.forEach((doc) => {
    const price = parsePriceValue(doc.price);
    if (!price) return;
    const uploaded = parseUploadDate(doc.upload_time);
    if (!uploaded) return;
    if (uploaded >= start && uploaded <= end) {
      current.push(price);
      const platform = allowedPlatforms.includes(doc.platform)
        ? doc.platform
        : null;
      if (platform) {
        if (!platformBuckets[platform]) platformBuckets[platform] = [];
        platformBuckets[platform].push(price);
      }
    } else if (uploaded >= previousStart && uploaded <= previousEnd)
      previous.push(price);
  });

  const currentStats = summarizePrices(current);
  if (!currentStats) return null;
  const prevStats = summarizePrices(previous);

  const platformStats = Object.entries(platformBuckets)
    .map(([platform, arr]) => {
      const trimmed = trimOutliers(arr, 0.1);
      if (!trimmed.length) return null;
      const avg = Math.round(trimmed.reduce((acc, cur) => acc + cur, 0) / trimmed.length);
      return {
        platform,
        averagePrice: avg,
      };
    })
    .filter(Boolean)
    .sort((a, b) => a.averagePrice - b.averagePrice);

  const priceChange =
    currentStats.average && prevStats?.average
      ? Number(
          (
            ((currentStats.average - prevStats.average) / prevStats.average) *
            100
          ).toFixed(1)
        )
      : null;

  return {
    averagePrice: currentStats.average,
    lowPrice: currentStats.low,
    highPrice: currentStats.high,
    listingCount: currentStats.count,
    listingChange:
      prevStats?.count && prevStats.count > 0
        ? Number(
            (
              ((currentStats.count - prevStats.count) / prevStats.count) * 100
            ).toFixed(1)
          )
        : null,
    priceChange,
    platformStats,
  };
};

const fetchRecommendations = async ({ model, storage, condition }, summary) => {
  const { start: since, end } = createReferenceRange(7);

  const filter = {
    model_name: model,
    storage,
    url: { $exists: true, $ne: '' },
  };
  const groups = expandTier(condition);
  if (groups) {
    filter.condition = { $in: groups };
  }

  const docs = await Product.find(filter)
    .select({
      title: 1,
      price: 1,
      platform: 1,
      image_url: 1,
      url: 1,
      upload_time: 1,
    })
    .lean();

  const low = summary?.lowPrice || null;
  const high = summary?.highPrice || null;
  const shaped = [];
  docs.forEach((doc) => {
    const price = parsePriceValue(doc.price);
    if (!price) return;
    if (low && price < low) return;
    if (high && price > high) return;
    const uploaded = parseUploadDate(doc.upload_time || doc.uploaded_at);
    if (!uploaded || uploaded < since || uploaded > end) return;
    shaped.push({
      title: doc.title || '제목 없음',
      subtitle: doc.platform || '',
      url: doc.url,
      price,
      image_url: doc.image_url || '',
    });
  });

  shaped.sort((a, b) => a.price - b.price);
  return shaped.slice(0, 3).map((item) => ({
    title: item.title,
    subtitle: item.subtitle,
    price: formatCurrency(item.price),
    url: item.url,
    image_url: item.image_url,
  }));
};

const chatbotController = async (req, res) => {
  const message = (req.body?.message || '').trim();
  if (!message) {
    return res.status(400).json({ error: 'message는 필수입니다.' });
  }
  const incomingState = req.body?.state || {};
  const state = {
    ...DEFAULT_STATE,
    ...incomingState,
  };

  try {
    let reply;
    if (!state.model) {
      reply = await handleModelStep(message, state);
    } else if (!state.storage) {
      reply = await handleStorageStep(message, state);
    } else if (!state.condition) {
      reply = await handleConditionStep(message, state);
    } else {
      reply = await handleIntentStep(message, state);
    }

    return res.json({
      state,
      reply,
    });
  } catch (error) {
    console.error('Chatbot error:', error);
    return res
      .status(500)
      .json({ error: '챗봇 처리 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.' });
  }
};

const handleModelStep = async (message, state) => {
  const guess = await extractModelText(message);
  let canonical = canonicalizeModel(guess);
  if (!canonical) {
    canonical = canonicalizeModel(message);
  }
  if (!canonical) {
    return {
      text:
        '모델명을 정확히 인식하지 못했어요. 예: "갤럭시 S24 울트라", "아이폰 15 프로"처럼 알려주세요.',
    };
  }

  const detectedStorage = parseStorageFromMessage(message);
  state.model = canonical;
  state.condition = null;
  if (detectedStorage) {
    state.storage = detectedStorage;
    state.stage = stageOrder.awaiting_condition;
    const storageLabel = formatStorageLabel(detectedStorage);
    return {
      text: `좋아요! ${humanizeModel(canonical)} ${storageLabel} 모델로 진행할게요. 이제 기기의 상태를 알려주세요.\n예: "거의 새것", "모서리에 흠집 있고 배터리 85%" 등으로 설명해 주세요.`,
    };
  }

  state.storage = null;
  state.stage = stageOrder.awaiting_storage;
  return {
    text: `좋아요! ${humanizeModel(canonical)} 모델을 기준으로 진행할게요. 저장 공간(예: 256GB)을 알려주세요.`,
  };
};

const handleStorageStep = async (message, state) => {
  const storage = parseStorageFromMessage(message);
  if (!storage) {
    return {
      text: '용량 정보를 찾지 못했어요. "256GB", "512기가"처럼 입력해 주세요.',
    };
  }

  state.storage = storage;
  state.stage = stageOrder.awaiting_condition;
  return {
    text:
      '감사합니다. 이제 기기의 상태를 알려주세요.\n예: "거의 새것", "모서리에 흠집 있고 배터리 85%" 등으로 설명해 주세요.',
  };
};

const handleConditionStep = async (message, state) => {
  const tier = await classifyConditionTier(message);
  if (!tier) {
    return {
      text:
        '상태를 명확히 이해하지 못했어요. 흠집, 잔상, 배터리, 기능 이상 여부 등을 조금 더 자세히 알려주세요.',
    };
  }

  state.condition = tier;
  state.stage = stageOrder.ready;
  return {
    text: `${CONDITION_TIERS[tier]} 상태로 기록했어요. 이제 "시세 조회", "매물 추천", "판매가 추천" 등 필요한 작업을 말씀해 주세요.`,
  };
};

const handleIntentStep = async (message, state) => {
  const intent = await detectIntent(message);
  if (intent === 'reset') {
    state.model = null;
    state.storage = null;
    state.condition = null;
    state.stage = stageOrder.awaiting_model;
    return {
      text: '다른 모델로 다시 시작해 볼게요. 새롭게 확인하고 싶은 모델명을 알려주세요.',
    };
  }

  if (intent === 'price') {
    const summary = await fetchMarketSummary(state);
    if (!summary) {
      return {
        text: '해당 조건으로 분석 가능한 시세 데이터를 찾지 못했습니다.',
      };
    }
    const platformStats = summary.platformStats || [];
    let text = '최근 7일 시세 요약입니다.';
    if (platformStats.length > 0) {
      const cheapest = platformStats[0];
      const pricey = platformStats[platformStats.length - 1];
      text += `\n\n플랫폼 비교:\n- ${cheapest.platform}: ${formatCurrency(
        cheapest.averagePrice
      )}`;
      if (platformStats.length > 1) {
        text += `\n- ${pricey.platform}: ${formatCurrency(pricey.averagePrice)}`;
        text += `\n\n가격이 낮은 ${cheapest.platform}에 올리면 더 빨리 거래될 가능성이 높고, 높은 금액을 노린다면 ${pricey.platform}도 고려해 보세요.`;
      }
    }
    return {
      text,
      infoEntries: [
        { label: '평균 시세', value: formatCurrency(summary.averagePrice) },
        {
          label: '가격 범위',
          value: `${formatCurrency(summary.lowPrice)} ~ ${formatCurrency(
            summary.highPrice
          )}`,
        },
        {
          label: '가격 변화',
          value:
            summary.priceChange == null
              ? '-'
              : `${summary.priceChange > 0 ? '+' : ''}${summary.priceChange}%`,
        },
      ],
    };
  }

  if (intent === 'platform_compare') {
    const summary = await fetchMarketSummary(state);
    if (!summary || !summary.platformStats?.length) {
      return {
        text: '플랫폼별 평균가를 비교할 수 있는 데이터가 부족합니다.',
      };
    }
    const stats = summary.platformStats;
    const cheapest = stats[0];
    const highest = stats[stats.length - 1];
    let text = '플랫폼별 최근 평균 시세입니다:\n';
    text += stats
      .map((item) => `- ${item.platform}: ${formatCurrency(item.averagePrice)}`)
      .join('\n');
    text += `\n\n높은 금액을 원하면 ${highest.platform}에, 빠르게 팔고 싶다면 ${cheapest.platform}처럼 평균가가 낮은 플랫폼에 올려 보세요.`;
    return { text };
  }

  if (intent === 'recommendation') {
    const summary = await fetchMarketSummary(state);
    const products = await fetchRecommendations(state, summary);
    if (!products.length) {
      return {
        text:
          '최근 3일 이내 조건에 맞는 매물을 찾지 못했어요. 범위를 넓혀 다시 시도해 주세요.',
      };
    }
    const rangeText =
      summary?.lowPrice && summary?.highPrice
        ? `가격 범위 ${formatCurrency(summary.lowPrice)} ~ ${formatCurrency(
            summary.highPrice
          )} 안에서 찾았어요. `
        : '';
    const text = `${rangeText}조건에 맞는 최신 매물을 추천드릴게요. 링크는 판매 완료되었을 수도 있어요.`;
    return {
      text,
      products,
    };
  }

  if (intent === 'sell_price') {
    const recommendation = await calculateListingRecommendation(state);
    if (!recommendation) {
      return {
        text:
          '권장 등록가를 계산할 데이터를 찾지 못했습니다. 모델, 용량, 상태를 다시 한번 확인해 주세요.',
      };
    }
    const mainPrice = roundToStepValue(recommendation.recommendedPrice);
    const fastPrice =
      roundToStepValue(recommendation.fastSalePrice) ||
      roundToStepValue(Math.max(recommendation.recommendedMin || 0, (recommendation.recommendedPrice || 0) * 0.98));
    let text =
      '최근 7일 데이터를 토대로 권장 등록가를 계산했습니다. 상황에 따라 소폭 조정해 주세요.';
    text += `\n- 기본 권장가: ${formatCurrency(mainPrice)}`;
    text += `\n- 빠른 판매용 권장가: ${formatCurrency(fastPrice)}`;
    return { text };
  }

  return {
    text: '시세 조회, 매물 추천, 판매가 추천 중 필요한 기능을 말씀해 주세요.',
  };
};

const humanizeModel = (canonical) =>
  canonical
    .split('_')
    .map((token) => token.charAt(0).toUpperCase() + token.slice(1))
    .join(' ');

module.exports = chatbotController;
