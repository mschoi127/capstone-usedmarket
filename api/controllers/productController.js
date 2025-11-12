const Product = require('../models/Product'); // Product 모델 불러오기
const { model_synonyms: MODEL_SYNONYMS_CFG, storage_synonyms: STORAGE_SYNONYMS_CFG } =
  require('../config/modelSynonyms.json');

const NEW_CONDITION_HINTS = [
  '미개봉',
  '새상품',
  '새제품',
  '신품',
  'sealed',
  'seal',
  'unopened',
  'unused',
  '새거',
  '새 것'
];

const RELATIVE_TIME_PATTERNS = [
  { regex: /^(\d+)\s*분\s*전$/i, toDate: (n) => new Date(Date.now() - n * 60 * 1000) },
  { regex: /^(\d+)\s*시간\s*전$/i, toDate: (n) => new Date(Date.now() - n * 60 * 60 * 1000) },
  { regex: /^(\d+)\s*일\s*전$/i, toDate: (n) => new Date(Date.now() - n * 24 * 60 * 60 * 1000) },
  { regex: /^(\d+)\s*주\s*전$/i, toDate: (n) => new Date(Date.now() - n * 7 * 24 * 60 * 60 * 1000) },
  { regex: /^(\d+)\s*(?:개월|달)\s*전$/i, toDate: (n) => new Date(Date.now() - n * 30 * 24 * 60 * 60 * 1000) },
];

const escapeRegex = (str = '') => str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');


const KEYWORD_SYNONYM_PAIRS = [
  ['갤럭시', 'galaxy'],
  ['아이폰', 'iphone'],
  ['울트라', 'ultra'],
  ['플러스', 'plus'],
  ['플립', 'flip'],
  ['폴드', 'fold'],
  ['프로 맥스', 'promax'],
  ['프로맥스', 'promax'],
  ['프로', 'pro'],
  ['맥스', 'max'],
  ['미니', 'mini'],
  ['se', 'se'],
  ['fe', 'fe']
];

const PRICE_TREND_FETCH_LIMIT = 6000;
const RECOMMEND_PRICE_FETCH_LIMIT = 6000;
const RECOMMEND_PRICE_WINDOW_DAYS = 7;

const CONDITION_CANONICALS = [
  '새 상품',
  '사용감 없음',
  '사용감 적음',
  '사용감 많음',
  '고장/파손 상품'
];

const CONDITION_GROUP_MAP = {
  's급': ['새 상품', '사용감 없음'],
  s: ['새 상품', '사용감 없음'],
  'a급': ['사용감 적음'],
  a: ['사용감 적음'],
  'b급': ['사용감 많음'],
  b: ['사용감 많음'],
  'c급': ['고장/파손 상품'],
  c: ['고장/파손 상품']
};

const DEMO_REFERENCE_TIMESTAMP = '2025-11-10T23:59:59+09:00';
const createReferenceEnd = () => {
  const end = new Date(DEMO_REFERENCE_TIMESTAMP);
  end.setHours(23, 59, 59, 999);
  return end;
};
const createReferenceRange = (days) => {
  const end = createReferenceEnd();
  const start = new Date(end);
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - (days - 1));
  return { start, end };
};
const createReferenceAndPreviousRanges = (days) => {
  const { start: recentStart, end: recentEnd } = createReferenceRange(days);
  const previousEnd = new Date(recentStart);
  previousEnd.setDate(recentStart.getDate() - 1);
  previousEnd.setHours(23, 59, 59, 999);
  const previousStart = new Date(previousEnd);
  previousStart.setHours(0, 0, 0, 0);
  previousStart.setDate(previousStart.getDate() - (days - 1));
  return { recentStart, recentEnd, previousStart, previousEnd };
};

const normalizeConditionKey = (value = '') =>
  String(value).toLowerCase().replace(/\s+/g, '');

const expandConditionValues = (value = '') => {
  const normalized = normalizeConditionKey(value);
  if (CONDITION_GROUP_MAP[normalized]) {
    return CONDITION_GROUP_MAP[normalized];
  }
  if (CONDITION_CANONICALS.includes(value)) {
    return [value];
  }
  return [];
};

const trimPriceArray = (values = [], fraction = 0.1) => {
  if (!values.length) return [];
  const sorted = [...values].sort((a, b) => a - b);
  const cut = Math.floor(sorted.length * fraction);
  if (cut * 2 >= sorted.length) return sorted;
  return sorted.slice(cut, sorted.length - cut);
};

const normalizeConditionToken = (value = '') =>
  String(value).toLowerCase().replace(/\s+/g, '');

const CONDITION_SYNONYM_LIST = [];
const registerConditionSynonyms = (canonical, synonyms = []) => {
  const normalizedCanonical = normalizeConditionToken(canonical);
  if (normalizedCanonical) {
    CONDITION_SYNONYM_LIST.push({ token: normalizedCanonical, canonical });
  }
  synonyms.forEach((synonym) => {
    const normalized = normalizeConditionToken(synonym);
    if (normalized) {
      CONDITION_SYNONYM_LIST.push({ token: normalized, canonical });
    }
  });
};

registerConditionSynonyms('새 상품', [
  '새상품',
  '새제품',
  '신품',
  '미개봉',
  '새것',
  '새거'
]);
registerConditionSynonyms('사용감 없음', [
  '사용감없음',
  's급',
  's급',
  'S급',
  '거의새것'
]);
registerConditionSynonyms('사용감 적음', [
  '사용감적음',
  '상태좋음',
  '살짝사용'
]);
registerConditionSynonyms('사용감 많음', [
  '사용감많음',
  '사용감있음',
  '사용감많아요'
]);
registerConditionSynonyms('고장/파손 상품', [
  '고장',
  '파손',
  '고장파손',
  '부품용'
]);

CONDITION_SYNONYM_LIST.sort((a, b) => b.token.length - a.token.length);

const canonicalizeConditionValue = (value = '') => {
  const normalized = normalizeConditionToken(value);
  if (!normalized) return null;
  for (const { token, canonical } of CONDITION_SYNONYM_LIST) {
    if (normalized === token || normalized.includes(token)) {
      return canonical;
    }
  }
  return null;
};

const parseConditionParam = (input) => {
  if (input == null) return [];
  const values = Array.isArray(input) ? input : String(input).split(',');
  const collected = new Set();
  values.forEach((value) => {
    const normalized = normalizeConditionToken(value);
    if (!normalized) return;
    if (CONDITION_GROUP_MAP[normalized]) {
      CONDITION_GROUP_MAP[normalized].forEach((canonical) => collected.add(canonical));
      return;
    }
    const canonical = canonicalizeConditionValue(value);
    if (canonical) collected.add(canonical);
  });
  return [...collected];
};

const parsePlatformParam = (input) => {
  if (input == null) return [];
  const values = Array.isArray(input) ? input : String(input).split(',');
  return [...new Set(
    values
      .map((value) => String(value).trim())
      .filter(Boolean)
  )];
};

const formatDateKey = (date) => {
  const yyyy = String(date.getFullYear());
  const mm = String(date.getMonth() + 1).padStart(2, '0');
  const dd = String(date.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
};

const MODEL_SYNONYM_LIST = [];
Object.entries(MODEL_SYNONYMS_CFG || {}).forEach(([canonical, synonyms]) => {
  if (!Array.isArray(synonyms)) return;
  synonyms
    .filter((v) => typeof v === 'string' && v.trim().length)
    .forEach((synonym) =>
      MODEL_SYNONYM_LIST.push({ synonym: synonym.trim(), canonical })
    );
});
MODEL_SYNONYM_LIST.sort((a, b) => b.synonym.length - a.synonym.length);

const STORAGE_SYNONYM_LIST = [];
Object.entries(STORAGE_SYNONYMS_CFG || {}).forEach(([canonical, synonyms]) => {
  if (!Array.isArray(synonyms)) return;
  synonyms
    .filter((v) => typeof v === 'string' && v.trim().length)
    .forEach((synonym) =>
      STORAGE_SYNONYM_LIST.push({ synonym: synonym.trim(), canonical })
    );
});
STORAGE_SYNONYM_LIST.sort((a, b) => b.synonym.length - a.synonym.length);

const applyKeywordPairs = (value = '', pairs = []) =>
  pairs.reduce(
    (acc, [needle, replacement]) =>
      acc.replace(new RegExp(escapeRegex(needle), 'gi'), replacement),
    value
  );

const expandKeywordVariants = (keyword = '') => {
  const variants = new Set();
  const push = (input) => {
    if (typeof input !== 'string') return;
    const refined = input.trim();
    if (refined) variants.add(refined);
  };

  push(keyword);
  push(applyKeywordPairs(keyword, KEYWORD_SYNONYM_PAIRS));
  push(applyKeywordPairs(keyword, KEYWORD_SYNONYM_PAIRS.map(([ko, en]) => [en, ko])));

  [...variants].forEach((value) => {
    push(value.replace(/\s+/g, ' '));
    push(value.replace(/\s+/g, ''));
  });

  return [...variants].filter(Boolean);
};

const buildKeywordPatterns = (keyword = '') => {
  const variants = expandKeywordVariants(keyword);
  const patterns = new Set();

  variants.forEach((variant) => {
    const tokens = variant.trim().split(/\s+/).filter(Boolean);
    if (!tokens.length) return;
    const loose = tokens.map((token) => escapeRegex(token)).join('\\s*');
    if (loose) patterns.add(loose);
  });

  return [...patterns];
};

const normalizeForKeywordMatch = (value = '') => {
  if (!value) return '';
  const lowered = value.toLowerCase();
  const pairs = [
    ...KEYWORD_SYNONYM_PAIRS,
    ...KEYWORD_SYNONYM_PAIRS.map(([ko, en]) => [en, en])
  ];

  let normalized = lowered;
  pairs.forEach(([needle, replacement]) => {
    normalized = normalized.replace(new RegExp(escapeRegex(needle), 'gi'), replacement);
  });

  return normalized.replace(/[^0-9a-z]/g, '');
};

const normalizeKeywordForSearch = (value = '') =>
  value
    .toLowerCase()
    .replace(/\+/g, '플러스')
    .replace(/[^0-9a-z가-힣]/g, '');

const findCanonicalModel = (normalized = '') => {
  if (!normalized) return null;
  for (const { synonym, canonical } of MODEL_SYNONYM_LIST) {
    if (normalized.includes(synonym)) return canonical;
  }
  return null;
};

const findCanonicalStorage = (normalized = '') => {
  if (!normalized) return null;
  for (const { synonym, canonical } of STORAGE_SYNONYM_LIST) {
    if (normalized.includes(synonym)) return canonical;
  }
  return null;
};

const deriveQueryContext = (keywordRaw = '') => {
  const normalized = normalizeKeywordForSearch(keywordRaw);
  return {
    normalized,
    model: findCanonicalModel(normalized),
    storage: findCanonicalStorage(normalized),
  };
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

const isNewConditionEntry = (item) => {
  const text = ['condition', 'title', 'description']
    .map((key) => (typeof item[key] === 'string' ? item[key].toLowerCase() : ''))
    .join(' ');
  return NEW_CONDITION_HINTS.some((hint) => text.includes(hint));
};

const parseUploadDate = (value) => {
  if (!value) return null;
  if (value instanceof Date) return value;
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed) return null;

  const direct = new Date(trimmed.replace('Z', '+00:00'));
  if (!Number.isNaN(direct.getTime())) return direct;

  const formats = [
    /(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2})(?::(\d{1,2}))?/, // 2025-09-23 12:34:56
    /(\d{4})-(\d{1,2})-(\d{1,2})/,                                       // 2025-09-23
    /(\d{4})\.(\d{1,2})\.(\d{1,2})/,                                    // 2025.09.23
  ];

  for (const regex of formats) {
    const match = trimmed.match(regex);
    if (match) {
      const [ , y, m, d, hh = '0', mm = '0', ss = '0'] = match;
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

  const lower = trimmed.toLowerCase();
  if (['방금 전', '방금전', '지금'].includes(lower)) {
    return new Date();
  }
  if (['오늘'].includes(lower)) {
    return new Date();
  }
  if (['어제'].includes(lower)) {
    const d = new Date();
    d.setDate(d.getDate() - 1);
    return d;
  }

  for (const { regex, toDate } of RELATIVE_TIME_PATTERNS) {
    const match = trimmed.match(regex);
    if (match) {
      const n = parseInt(match[1], 10);
      if (!Number.isNaN(n)) return toDate(n);
    }
  }

  return null;
};

const trimAndAverage = (values = []) => {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length >= 5) {
    const lower = Math.floor(sorted.length * 0.1);
    const upper = Math.ceil(sorted.length * 0.9);
    const sliced = sorted.slice(lower, upper);
    if (sliced.length) {
      const sum = sliced.reduce((acc, cur) => acc + cur, 0);
      return { avg: Math.round(sum / sliced.length), count: sliced.length };
    }
  }
  const sum = sorted.reduce((acc, cur) => acc + cur, 0);
  return { avg: Math.round(sum / sorted.length), count: sorted.length };
};

// ✅ 전체 제품 조회 또는 검색 + 필터 + 정렬 + 페이지네이션
const getAllProducts = async (req, res) => {
  try {
    const {
      keyword = '',
      sort,
      minPrice,
      maxPrice,
      page = 1,
      limit = 100
    } = req.query;

    const toInt = (value) => {
      const parsed = parseInt(value, 10);
      return Number.isNaN(parsed) ? null : parsed;
    };

    const pageNumber = toInt(page) || 1;
    const limitNumber = toInt(limit) || 100;
    const skip = (pageNumber - 1) * limitNumber;
    const limited = limitNumber;
    const minPriceInt = toInt(minPrice);
    const maxPriceInt = toInt(maxPrice);

    const filter = {};
    let canonicalModel = null;
    let canonicalStorage = null;
    let normalizedKeyword = '';
    const explicitModel =
      typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const explicitStorage =
      typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const conditionValues = parseConditionParam(req.query.condition);
    const platformValues = parsePlatformParam(req.query.platform);

    if (keyword) {
      const ctx = deriveQueryContext(keyword);
      normalizedKeyword = ctx.normalized;
      canonicalModel = ctx.model;
      canonicalStorage = ctx.storage;
    }

    const resolvedModel = explicitModel || canonicalModel || '';
    const resolvedStorage = explicitStorage || canonicalStorage || '';
    const normalizedTitleKeyword =
      normalizedKeyword && normalizedKeyword.length ? normalizedKeyword : '';
    let keywordApplied = false;

    if (conditionValues.length === 1) {
      filter.condition = conditionValues[0];
    } else if (conditionValues.length > 1) {
      filter.condition = { $in: conditionValues };
    }

    if (resolvedModel) {
      filter.model_name = resolvedModel;
      keywordApplied = true;
    }
    if (resolvedStorage) {
      filter.storage = resolvedStorage;
    }

    if (!keywordApplied && normalizedTitleKeyword) {
      filter.title_normalization = {
        $regex: escapeRegex(normalizedTitleKeyword)
      };
      keywordApplied = true;
    }

    if (!keywordApplied && keyword) {
      const keywordNoSpace = keyword.replace(/\s/g, '');
      filter.$or = [
        { title: { $regex: keyword, $options: 'i' } },
        { title: { $regex: keywordNoSpace, $options: 'i' } }
      ];
      const lowerKeyword = keyword.toLowerCase();
      if (
        lowerKeyword.includes('아이폰') &&
        !/미니|프로|플러스|맥스/i.test(lowerKeyword)
      ) {
        filter.title = { $not: /미니|프로|플러스|맥스/i };
      }
    }

    // 플랫폼 필터링
    if (platformValues.length === 1) {
      filter.platform = platformValues[0];
    } else if (platformValues.length > 1) {
      filter.platform = { $in: platformValues };
    }

    const sortKey = typeof sort === 'string' ? sort.toLowerCase() : '';
    const isLatestSort = sortKey === 'latest' || sortKey === 'newest';
    const isLowSort =
      sortKey === 'low' || sortKey === 'price_asc' || sortKey === 'asc';
    const isHighSort =
      sortKey === 'high' || sortKey === 'price_desc' || sortKey === 'desc';

    const needsNumericPrice =
      minPriceInt !== null || maxPriceInt !== null || isLowSort || isHighSort;

    const pipeline = [{ $match: filter }];

    if (needsNumericPrice) {
      pipeline.push({
        $addFields: {
          price_numeric: {
            $convert: {
              input: {
                $replaceAll: {
                  input: {
                    $replaceAll: {
                      input: {
                        $replaceAll: {
                          input: '$price',
                          find: ',',
                          replacement: ''
                        }
                      },
                      find: '원',
                      replacement: ''
                    }
                  },
                  find: '₩',
                  replacement: ''
                }
              },
              to: 'int',
              onError: null,
              onNull: null
            }
          }
        }
      });
    }

    if (minPriceInt !== null || maxPriceInt !== null) {
      const priceMatch = { $and: [] };
      if (minPriceInt !== null) {
        priceMatch.$and.push({ price_numeric: { $gte: minPriceInt } });
      }
      if (maxPriceInt !== null) {
        priceMatch.$and.push({ price_numeric: { $lte: maxPriceInt } });
      }
      priceMatch.$and.push({ price_numeric: { $ne: null } });
      pipeline.push({ $match: priceMatch });
    } else if (needsNumericPrice && (isLowSort || isHighSort)) {
      pipeline.push({ $match: { price_numeric: { $ne: null } } });
    }

    if (isLatestSort) {
      pipeline.push({
        $addFields: {
          upload_date_parsed: {
            $let: {
              vars: {
                trimmed: {
                  $trim: { input: { $ifNull: ['$upload_time', ''] } }
                },
              },
              in: {
                $let: {
                  vars: {
                    isoFull: {
                      $dateFromString: {
                        dateString: {
                          $cond: [
                            {
                              $regexMatch: {
                                input: '$$trimmed',
                                regex:
                                  '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9:]+)?$',
                              },
                            },
                            {
                              $replaceOne: {
                                input: '$$trimmed',
                                find: ' ',
                                replacement: 'T',
                              },
                            },
                            '$$trimmed',
                          ],
                        },
                        onError: null,
                        onNull: null,
                      },
                    },
                    isoDateOnly: {
                      $dateFromString: {
                        dateString: {
                          $cond: [
                            {
                              $regexMatch: {
                                input: '$$trimmed',
                                regex: '^[0-9]{4}-[0-9]{2}-[0-9]{2}$',
                              },
                            },
                            { $concat: ['$$trimmed', 'T00:00:00'] },
                            null,
                          ],
                        },
                        onError: null,
                        onNull: null,
                      },
                    },
                    dotDate: {
                      $dateFromString: {
                        dateString: {
                          $cond: [
                            {
                              $regexMatch: {
                                input: '$$trimmed',
                                regex: '^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}$',
                              },
                            },
                            {
                              $replaceAll: {
                                input: { $concat: ['$$trimmed', ' 00:00:00'] },
                                find: '.',
                                replacement: '-',
                              },
                            },
                            null,
                          ],
                        },
                        onError: null,
                        onNull: null,
                      },
                    },
                  },
                  in: {
                    $ifNull: [
                      '$$isoFull',
                      {
                        $ifNull: [
                          '$$isoDateOnly',
                          { $ifNull: ['$$dotDate', { $toDate: '$_id' }] },
                        ],
                      },
                    ],
                  },
                },
              },
            },
          },
        },
      });
      pipeline.push({ $sort: { upload_date_parsed: -1, _id: -1 } });
    } else if (isLowSort && needsNumericPrice) {
      pipeline.push({ $sort: { price_numeric: 1 } });
    } else if (isHighSort && needsNumericPrice) {
      pipeline.push({ $sort: { price_numeric: -1 } });
    } else {
      pipeline.push({ $sort: { _id: -1 } });
    }

    if (skip > 0) {
      pipeline.push({ $skip: skip });
    }
    pipeline.push({ $limit: limited });

    const projection = {};
    if (needsNumericPrice) {
      projection.price_numeric = 0;
    }
    if (isLatestSort) {
      projection.upload_date_parsed = 0;
    }
    if (Object.keys(projection).length > 0) {
      pipeline.push({ $project: projection });
    }

    let products = await Product.aggregate(pipeline).exec();

    // 문자열 가격 → 숫자 가격 필터링
    products = products.filter((p) => {
      const numericPrice = parseInt(p.price.replace(/[^0-9]/g, ''));
      if (isNaN(numericPrice)) return false;
      if (minPriceInt !== null && numericPrice < minPriceInt) return false;
      if (maxPriceInt !== null && numericPrice > maxPriceInt) return false;
      return true;
    });

    // 가격 정렬 (문자열이므로 JS에서 처리)
    if (isLowSort) {
      products.sort((a, b) =>
        parseInt(a.price.replace(/[^0-9]/g, '')) - parseInt(b.price.replace(/[^0-9]/g, ''))
      );
    } else if (isHighSort) {
      products.sort((a, b) =>
        parseInt(b.price.replace(/[^0-9]/g, '')) - parseInt(a.price.replace(/[^0-9]/g, ''))
      );
    } else if (isLatestSort) {
      products.sort((a, b) => {
        const da = parseUploadDate(a.upload_time) || new Date(0);
        const db = parseUploadDate(b.upload_time) || new Date(0);
        return db - da;
      });
    }

    res.json(products);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: '서버 에러' });
  }
};

const getPriceStats = async (req, res) => {
  try {
    const keywordRaw = (req.query.keyword || '').trim();
    const { normalized: normalizedKeyword, model: canonicalModel, storage: canonicalStorage } =
      deriveQueryContext(keywordRaw);
    const modelParam = typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const storageParam =
      typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const range = parseInt(req.query.range, 10) || 7;
    const region = req.query.region;
    const platform = req.query.platform;

    const endDate = createReferenceEnd();
    const startDate = new Date(endDate);
    startDate.setHours(0, 0, 0, 0);
    startDate.setDate(startDate.getDate() - range);

    const filter = {};

    if (keywordRaw) {
      const keywordNoSpace = keywordRaw.replace(/\s/g, '');
      const orClauses = [
        { title: { $regex: keywordRaw, $options: 'i' } },
        { title: { $regex: keywordNoSpace, $options: 'i' } }
      ];
      if (normalizedKeyword) {
        orClauses.push({
          title_normalization: { $regex: escapeRegex(normalizedKeyword) }
        });
      }
      filter.$and = [
        { $or: orClauses },
        { title: { $not: /케이스|교환|구합니다/i } }
      ];
      const lowerKeyword = keywordRaw.toLowerCase();
      if (
        lowerKeyword.includes('아이폰') &&
        !/미니|프로|플러스|맥스/i.test(lowerKeyword)
      ) {
        filter.$and.push({
          title: { $not: /미니|프로|플러스|맥스/i }
        });
      }
    }

    if (modelParam) filter.model_name = modelParam;
    else if (canonicalModel) filter.model_name = canonicalModel;
    if (storageParam) filter.storage = storageParam;
    else if (canonicalStorage) filter.storage = canonicalStorage;
    if (region) filter.region = region;
    if (platform) filter.platform = platform;

    const products = await Product.find(filter)
      .select({ price: 1, upload_time: 1 });

    const filtered = products.filter((p) => {
      const uploadTime = new Date(p.upload_time);
      return !Number.isNaN(uploadTime) && uploadTime >= startDate && uploadTime <= endDate;
    });

    const prices = filtered
      .map((p) => parseInt(String(p.price).replace(/[^0-9]/g, ''), 10))
      .filter((p) => Number.isFinite(p));

    if (prices.length === 0) {
      return res.json({ message: '분석 가능한 데이터가 없습니다.' });
    }

    const stats = {
      average: Math.round(prices.reduce((a, b) => a + b, 0) / prices.length),
      min: Math.min(...prices),
      max: Math.max(...prices),
      count: prices.length
    };

    res.json(stats);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: '서버 에러' });
  }
};
const getPriceTrend = async (req, res) => {
  try {
    const keywordRaw = (req.query.keyword || '').trim();
    const {
      normalized: normalizedKeyword,
      model: canonicalModel,
      storage: canonicalStorage
    } = deriveQueryContext(keywordRaw);
    const explicitModel =
      typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const explicitStorage =
      typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const resolvedModel = explicitModel || canonicalModel || '';
    const resolvedStorage = explicitStorage || canonicalStorage || '';
    const conditionValues = parseConditionParam(req.query.condition);
    const conditionSet = new Set(conditionValues);
    const platformValues = parsePlatformParam(req.query.platform);
    const platformSet = new Set(platformValues);
    const daysRaw = parseInt(req.query.days, 10);
    const windowDays =
      Number.isFinite(daysRaw) && daysRaw > 0 ? Math.min(daysRaw, 90) : 7;

    const { start: windowStart, end: windowEnd } = createReferenceRange(windowDays);

    const filter = {};
    const normalizedTitleKeyword =
      normalizedKeyword && normalizedKeyword.length ? normalizedKeyword : '';
    const appliedTitleNormalizationFilter =
      !resolvedModel && Boolean(normalizedTitleKeyword);

    if (resolvedModel) {
      filter.model_name = resolvedModel;
    } else if (normalizedTitleKeyword) {
      filter.title_normalization = {
        $regex: escapeRegex(normalizedTitleKeyword)
      };
    } else if (keywordRaw) {
      const patterns = buildKeywordPatterns(keywordRaw);
      if (patterns.length) {
        const orClauses = [];
        const seen = new Set();
        patterns.forEach((pattern) => {
          ['title', 'description', 'model', 'model_name'].forEach((field) => {
            const key = `${field}:${pattern}`;
            if (seen.has(key)) return;
            seen.add(key);
            orClauses.push({ [field]: { $regex: pattern, $options: 'i' } });
          });
        });
        if (orClauses.length) {
          filter.$or = orClauses;
        }
      }
    }

    if (resolvedStorage) {
      filter.storage = resolvedStorage;
    }
    if (keywordRaw) {
      filter.title = filter.title || { $not: /케이스|교환|구합니다/i };

      const lowerKeyword = keywordRaw.toLowerCase();
      const iphoneLike = /아이폰|iphone/.test(lowerKeyword);
      if (iphoneLike && !/(미니|mini|프로|pro|프로맥스|promax)/.test(lowerKeyword)) {
        filter.$and = (filter.$and || []).concat({
          title: { $not: /미니|mini|프로|pro|프로맥스|promax/i }
        });
      }
    }
    if (conditionValues.length === 1) {
      filter.condition = conditionValues[0];
    } else if (conditionValues.length > 1) {
      filter.condition = { $in: conditionValues };
    }
    if (platformValues.length === 1) {
      filter.platform = platformValues[0];
    } else if (platformValues.length > 1) {
      filter.platform = { $in: platformValues };
    }

    const docs = await Product.find(filter)
      .sort({ _id: -1 })
      .limit(PRICE_TREND_FETCH_LIMIT)
      .lean();

    const effectiveNormalized =
      normalizedKeyword && normalizedKeyword.length >= 2
        ? normalizedKeyword
        : normalizeForKeywordMatch(keywordRaw);
    const shouldApplyKeywordNarrowing =
      !resolvedModel &&
      !appliedTitleNormalizationFilter &&
      effectiveNormalized &&
      effectiveNormalized.length >= 2;
    const narrowedDocs =
      shouldApplyKeywordNarrowing
        ? docs.filter((item) => {
            const fields = [
              item.title_normalization,
              item.title,
              item.description,
              item.model_name,
              item.model
            ].filter((value) => typeof value === 'string' && value.trim().length);
            if (!fields.length) return false;
            return fields.some((value) =>
              normalizeKeywordForSearch(value).includes(effectiveNormalized)
            );
          })
        : docs;
    const sourceDocs = narrowedDocs.length ? narrowedDocs : docs;

    const dailyBuckets = new Map();
    const platformBuckets = new Map();

    for (const item of sourceDocs) {
      const condition = canonicalizeConditionValue(item.condition);
      if (conditionSet.size && (!condition || !conditionSet.has(condition))) {
        continue;
      }

      const itemPlatform =
        typeof item.platform === 'string' ? item.platform.trim() : '';
      if (platformSet.size && (!itemPlatform || !platformSet.has(itemPlatform))) {
        continue;
      }

      const uploadedAt = parseUploadDate(item.upload_time || item.uploaded_at);
      if (!uploadedAt) continue;
      if (uploadedAt < windowStart || uploadedAt > windowEnd) continue;

      const price = parsePriceValue(item.price);
      if (!price || price <= 0) continue;

      const dayKey = formatDateKey(uploadedAt);
      const bucket = dailyBuckets.get(dayKey) || { sum: 0, count: 0 };
      bucket.sum += price;
      bucket.count += 1;
      dailyBuckets.set(dayKey, bucket);

      const platformKey = itemPlatform || '기타';
      const platformBucket =
        platformBuckets.get(platformKey) || { sum: 0, count: 0 };
      platformBucket.sum += price;
      platformBucket.count += 1;
      platformBuckets.set(platformKey, platformBucket);
    }

    const timeline = {};
    for (let offset = 0; offset < windowDays; offset += 1) {
      const day = new Date(windowStart);
      day.setDate(windowStart.getDate() + offset);
      const key = formatDateKey(day);
      const bucket = dailyBuckets.get(key);
      if (bucket && bucket.count > 0) {
        timeline[key] = {
          average: Math.round(bucket.sum / bucket.count),
          count: bucket.count
        };
      } else {
        timeline[key] = { average: null, count: 0 };
      }
    }

    const platformAverages = {};
    for (const [platformKey, bucket] of platformBuckets.entries()) {
      if (!bucket.count) continue;
      platformAverages[platformKey] = {
        average: Math.round(bucket.sum / bucket.count),
        count: bucket.count
      };
    }

    res.json({
      condition: conditionValues.length === 1 ? conditionValues[0] : null,
      days: windowDays,
      timeline,
      platformAverages
    });
  } catch (err) {
    console.error('Error in getPriceTrend:', err);
    res.status(500).json({ error: '서버 오류' });
  }
};

const getMarketSummary = async (req, res) => {
  try {
    const keywordRaw = (req.query.keyword || '').trim();
    const {
      normalized: normalizedKeyword,
      model: canonicalModel,
      storage: canonicalStorage
    } = deriveQueryContext(keywordRaw);
    const explicitModel =
      typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const explicitStorage =
      typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const resolvedModel = explicitModel || canonicalModel || '';
    const resolvedStorage = explicitStorage || canonicalStorage || '';
    const conditionValues = parseConditionParam(req.query.condition);
    const conditionSet = new Set(conditionValues);
    const platformValues = parsePlatformParam(req.query.platform);
    const platformSet = new Set(platformValues);
    const daysRaw = parseInt(req.query.days, 10);
    const windowDays =
      Number.isFinite(daysRaw) && daysRaw > 0 ? Math.min(daysRaw, 30) : 7;

    const {
      recentStart,
      recentEnd,
      previousStart,
      previousEnd
    } = createReferenceAndPreviousRanges(windowDays);

    const filter = {};
    const normalizedTitleKeyword =
      normalizedKeyword && normalizedKeyword.length ? normalizedKeyword : '';
    const appliedTitleNormalizationFilter =
      !resolvedModel && Boolean(normalizedTitleKeyword);

    if (resolvedModel) {
      filter.model_name = resolvedModel;
    } else if (normalizedTitleKeyword) {
      filter.title_normalization = {
        $regex: escapeRegex(normalizedTitleKeyword)
      };
    } else if (keywordRaw) {
      const patterns = buildKeywordPatterns(keywordRaw);
      if (patterns.length) {
        const orClauses = [];
        const seen = new Set();
        patterns.forEach((pattern) => {
          ['title', 'description', 'model', 'model_name'].forEach((field) => {
            const key = `${field}:${pattern}`;
            if (seen.has(key)) return;
            seen.add(key);
            orClauses.push({ [field]: { $regex: pattern, $options: 'i' } });
          });
        });
        if (orClauses.length) {
          filter.$or = orClauses;
        }
      }
    }

    if (resolvedStorage) {
      filter.storage = resolvedStorage;
    }
    if (keywordRaw) {
      filter.title = filter.title || { $not: /케이스|교환|구합니다/i };

      const lowerKeyword = keywordRaw.toLowerCase();
      const iphoneLike = /아이폰|iphone/.test(lowerKeyword);
      if (iphoneLike && !/(미니|mini|프로|pro|프로맥스|promax)/.test(lowerKeyword)) {
        filter.$and = (filter.$and || []).concat({
          title: { $not: /미니|mini|프로|pro|프로맥스|promax/i }
        });
      }
    }
    if (conditionValues.length === 1) {
      filter.condition = conditionValues[0];
    } else if (conditionValues.length > 1) {
      filter.condition = { $in: conditionValues };
    }
    if (platformValues.length === 1) {
      filter.platform = platformValues[0];
    } else if (platformValues.length > 1) {
      filter.platform = { $in: platformValues };
    }

    const docs = await Product.find(filter)
      .sort({ _id: -1 })
      .limit(RECOMMEND_PRICE_FETCH_LIMIT)
      .lean();

    const effectiveNormalized =
      normalizedKeyword && normalizedKeyword.length >= 2
        ? normalizedKeyword
        : normalizeForKeywordMatch(keywordRaw);
    const shouldApplyKeywordNarrowing =
      !resolvedModel &&
      !appliedTitleNormalizationFilter &&
      effectiveNormalized &&
      effectiveNormalized.length >= 2;
    const narrowedDocs =
      shouldApplyKeywordNarrowing
        ? docs.filter((item) => {
            const fields = [
              item.title_normalization,
              item.title,
              item.description,
              item.model_name,
              item.model
            ].filter((value) => typeof value === 'string' && value.trim().length);
            if (!fields.length) return false;
            return fields.some((value) =>
              normalizeKeywordForSearch(value).includes(effectiveNormalized)
            );
          })
        : docs;
    const sourceDocs = narrowedDocs.length ? narrowedDocs : docs;

    const recentPrices = [];
    const previousPrices = [];

    const matchesCondition = (value) => {
      if (!conditionSet.size) return true;
      const canonical = canonicalizeConditionValue(value);
      return canonical ? conditionSet.has(canonical) : false;
    };

    const matchesPlatform = (value) => {
      if (!platformSet.size) return true;
      const trimmed = typeof value === 'string' ? value.trim() : '';
      return trimmed && platformSet.has(trimmed);
    };

    for (const item of sourceDocs) {
      if (!matchesCondition(item.condition)) continue;
      if (!matchesPlatform(item.platform)) continue;

      const uploadedAt = parseUploadDate(item.upload_time || item.uploaded_at);
      if (!uploadedAt) continue;

      const price = parsePriceValue(item.price);
      if (!price || price <= 0) continue;

      if (uploadedAt >= recentStart && uploadedAt <= recentEnd) {
        recentPrices.push(price);
      } else if (uploadedAt >= previousStart && uploadedAt <= previousEnd) {
        previousPrices.push(price);
      }
    }

    const computeStats = (values) => {
      if (!values.length) {
        return {
          average: null,
          low: null,
          high: null,
          count: 0
        };
      }
      const sorted = [...values].sort((a, b) => a - b);
      const count = sorted.length;

      const trimForRange = Math.floor(count * 0.25);
      const low = sorted[Math.min(trimForRange, count - 1)];
      const high = sorted[Math.max(0, count - 1 - trimForRange)];

      const trimForAverage = Math.floor(count * 0.10);
      let avgStart = trimForAverage;
      let avgEnd = count - trimForAverage;
      if (avgEnd <= avgStart) {
        avgStart = 0;
        avgEnd = count;
      }
      const trimmedSlice = sorted.slice(avgStart, avgEnd);
      const avgSum = trimmedSlice.reduce((acc, cur) => acc + cur, 0);

      return {
        average: Math.round(avgSum / trimmedSlice.length),
        low,
        high,
        count
      };
    };

    const recentStats = computeStats(recentPrices);
    const previousStats = computeStats(previousPrices);

    const calcChangePct = (currentValue, previousValue) => {
      if (
        currentValue == null ||
        previousValue == null ||
        previousValue === 0
      ) {
        return null;
      }
      return Number((((currentValue - previousValue) / previousValue) * 100).toFixed(1));
    };

    res.json({
      windowDays,
      condition: conditionValues.length === 1 ? conditionValues[0] : null,
      averagePrice: recentStats.average,
      minPrice: recentStats.low,
      maxPrice: recentStats.high,
      priceChangePct: calcChangePct(recentStats.average, previousStats.average),
      listingCount: recentStats.count,
      listingChangePct: calcChangePct(recentStats.count, previousStats.count),
      previous: {
        averagePrice: previousStats.average,
        listingCount: previousStats.count
      },
      period: {
        recent: {
          start: formatDateKey(recentStart),
          end: formatDateKey(recentEnd)
        },
        previous: {
          start: formatDateKey(previousStart),
          end: formatDateKey(previousEnd)
        }
      }
    });
  } catch (err) {
    console.error('Error in getMarketSummary:', err);
    res.status(500).json({ error: '서버 오류' });
  }
};

const getProductByUrl = async (req, res) => {
  const rawUrl = typeof req.query.url === 'string' ? req.query.url.trim() : '';
  if (!rawUrl) {
    return res.status(400).json({ error: 'url 파라미터가 필요합니다.' });
  }

  try {
    const doc = await Product.findOne({ url: rawUrl })
      .select({
        title: 1,
        price: 1,
        image_url: 1,
        platform: 1,
        url: 1,
        condition: 1,
        storage: 1,
      })
      .lean();

    if (!doc) {
      return res.status(404).json({ error: '매물을 찾지 못했습니다.' });
    }

    res.json({
      title: String(doc.title || ''),
      price: String(doc.price || ''),
      image_url: String(doc.image_url || ''),
      platform: String(doc.platform || ''),
      url: String(doc.url || rawUrl),
      condition: String(doc.condition || ''),
      storage: String(doc.storage || ''),
    });
  } catch (err) {
    console.error('Error in getProductByUrl:', err);
    res.status(500).json({ error: '서버 오류' });
  }
};

const recommendPrice = async (req, res) => {
  try {
    const keywordRaw = (req.query.keyword || '').trim();
    const {
      normalized: normalizedKeyword,
      model: canonicalModel,
      storage: canonicalStorage
    } = deriveQueryContext(keywordRaw);
    const explicitModel = typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const explicitStorage = typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const effectiveWindow = Math.max(RECOMMEND_PRICE_WINDOW_DAYS, 1);

    const { start: startDate, end: endDate } = createReferenceRange(effectiveWindow);

    const filter = {};

    if (keywordRaw) {
      const patterns = buildKeywordPatterns(keywordRaw);
      if (patterns.length) {
        const orClauses = [];
        const seen = new Set();
        patterns.forEach((pattern) => {
          ['title', 'description', 'model', 'model_name'].forEach((field) => {
            const key = `${field}:${pattern}`;
            if (seen.has(key)) return;
            seen.add(key);
            orClauses.push({ [field]: { $regex: pattern, $options: 'i' } });
          });
        });
        if (normalizedKeyword) {
          orClauses.push({
            title_normalization: { $regex: escapeRegex(normalizedKeyword) }
          });
        }
        if (orClauses.length) {
          filter.$or = orClauses;
        }
      } else if (normalizedKeyword) {
        filter.$or = [{
          title_normalization: { $regex: escapeRegex(normalizedKeyword) }
        }];
      }

      filter.title = filter.title || { $not: /케이스|교환|구합니다/i };

      const lowerKeyword = keywordRaw.toLowerCase();
      const iphoneLike = /아이폰|iphone/.test(lowerKeyword);
      if (iphoneLike && !/(미니|mini|프로|pro|프로맥스|promax)/.test(lowerKeyword)) {
        filter.$and = (filter.$and || []).concat({
          title: { $not: /미니|mini|프로|pro|프로맥스|promax/i }
        });
      }
    }

    if (explicitModel) {
      filter.model_name = explicitModel;
    } else if (canonicalModel) {
      filter.model_name = canonicalModel;
    }
    if (explicitStorage) {
      filter.storage = explicitStorage;
    } else if (canonicalStorage) {
      filter.storage = canonicalStorage;
    }

    const docs = await Product.find(filter)
      .sort({ _id: -1 })
      .limit(RECOMMEND_PRICE_FETCH_LIMIT)
      .lean();

    const effectiveNormalized =
      normalizedKeyword && normalizedKeyword.length >= 2
        ? normalizedKeyword
        : normalizeForKeywordMatch(keywordRaw);
    const narrowedDocs =
      effectiveNormalized && effectiveNormalized.length >= 2
        ? docs.filter((item) => {
            const fields = [
              item.title_normalization,
              item.title,
              item.description,
              item.model_name,
              item.model
            ].filter((value) => typeof value === 'string' && value.trim().length);
            if (!fields.length) return false;
            return fields.some((value) =>
              normalizeKeywordForSearch(value).includes(effectiveNormalized)
            );
          })
        : docs;

    const newPrices = [];
    const usedPrices = [];

    for (const item of narrowedDocs.length ? narrowedDocs : docs) {
      const uploadedAt = parseUploadDate(item.upload_time || item.uploaded_at);
      if (!uploadedAt || uploadedAt < startDate || uploadedAt > endDate) continue;

      const price = parsePriceValue(item.price);
      if (!price || price <= 0) continue;

      if (isNewConditionEntry(item)) {
        newPrices.push(price);
      } else {
        usedPrices.push(price);
      }
    }

    const analyze = (priceArray) => {
      if (priceArray.length < 5) return null;

      const sorted = [...priceArray].sort((a, b) => a - b);
      const lowerIndex = Math.floor(sorted.length * 0.10);
      const upperIndex = Math.ceil(sorted.length * 0.90);
      const filtered = sorted.slice(lowerIndex, upperIndex);

      if (filtered.length === 0) return null;

      const sum = filtered.reduce((a, b) => a + b, 0);
      return {
        recommended: Math.round(sum / filtered.length),
        range: [Math.min(...filtered), Math.max(...filtered)],
        sampleCount: filtered.length
      };
    };

    const newResult = analyze(newPrices);
    const usedResult = analyze(usedPrices);

    if (!newResult && !usedResult) {
      return res.json({
        message: '분석 가능한 데이터가 부족합니다.',
        new: newResult,
        used: usedResult
      });
    }

    res.json({
      ...(newResult && { new: newResult }),
      ...(usedResult && { used: usedResult })
    });
  } catch (err) {
    console.error('Error in recommendPrice:', err);
    res.status(500).json({ error: '서버 에러' });
  }
};
const getUploadTrends = async (req, res) => {
  try {
    const start = new Date(req.query.start); // ISO 형식 문자열
    const end = new Date(req.query.end);

    const result = await Product.aggregate([
      {
        $match: {
          $expr: {
            $and: [
              { $gte: [{ $toDate: "$upload_time" }, start] },
              { $lte: [{ $toDate: "$upload_time" }, end] }
            ]
          }
        }
      },
      {
        $group: {
          _id: {
            date: {
              $dateToString: {
                format: "%Y-%m-%d",
                date: { $toDate: "$upload_time" }
              }
            }
          },
          totalCount: { $sum: 1 }
        }
      },
      { $sort: { "_id.date": 1 } },
      {
        $setWindowFields: {
          sortBy: { "_id.date": 1 },
          output: {
            cumulativeCount: {
              $sum: "$totalCount",
              window: { documents: ["unbounded", "current"] }
            }
          }
        }
      },
      {
        $project: {
          _id: 0,
          date: "$_id.date",
          totalCount: 1,
          cumulativeCount: 1
        }
      }
    ]);

    res.json(result);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: "서버 에러" });
  }
};

const getDailyPriceDistribution = async (req, res) => {
  try {
    const start = req.query.startDate;
    const end = req.query.endDate;

    if (!start || !end) {
      return res.status(400).json({ error: 'startDate와 endDate를 지정해야 합니다.' });
    }

    const startDate = new Date(start);
    const endDate = new Date(end);

    const pipeline = [
      {
        $match: {
          upload_time: { $type: 'string' },
          price: { $regex: '\\d' }
        }
      },
      {
        $addFields: {
          upload_parsed: {
            $dateFromString: {
              dateString: '$upload_time',
              onError: null,
              onNull: null
            }
          },
          price_parsed: {
            $convert: {
              input: {
                $convert: {
                  input: {
                    $replaceAll: {
                      input: {
                        $replaceAll: {
                          input: '$price',
                          find: '원',
                          replacement: ''
                        }
                      },
                      find: ',',
                      replacement: ''
                    }
                  },
                  to: 'double',
                  onError: null,
                  onNull: null
                }
              },
              to: 'int',
              onError: null,
              onNull: null
            }
          }
        }
      },
      {
        $match: {
          upload_parsed: {
            $gte: startDate,
            $lte: endDate
          },
          price_parsed: {
            $ne: null,
            $lte: 1500000,
            $gte: 10000
          }
        }
      },
      {
        $project: {
          upload_date: {
            $dateToString: {
              format: '%Y-%m-%d',
              date: '$upload_parsed'
            }
          },
          price_bin: {
            $multiply: [
              { $floor: { $divide: ['$price_parsed', 100000] } },
              100000
            ]
          }
        }
      },
      {
        $group: {
          _id: {
            upload_date: '$upload_date',
            price_bin: '$price_bin'
          },
          count: { $sum: 1 }
        }
      },
      {
        $project: {
          _id: 0,
          upload_date: '$_id.upload_date',
          price_bin: '$_id.price_bin',
          count: 1
        }
      },
      {
        $sort: {
          upload_date: 1,
          price_bin: 1
        }
      }
    ];

    const result = await Product.aggregate(pipeline).allowDiskUse(true).exec();
    res.json(result);
  } catch (err) {
    console.error('Error in getDailyPriceDistribution:', err);
    res.status(500).json({ error: '서버 에러' });
  }
};

const roundToStep = (value, step = 5000) =>
  value == null ? null : Math.round(value / step) * step;

const calculateListingRecommendation = async ({
  model,
  storage,
  condition,
} = {}) => {
  if (!model || !storage) return null;

  const { start, end } = createReferenceRange(7);
  const filter = {
    model_name: model,
    storage,
  };

  const conditionValues = expandConditionValues(condition);
  if (conditionValues.length === 1) {
    filter.condition = conditionValues[0];
  } else if (conditionValues.length > 1) {
    filter.condition = { $in: conditionValues };
  }

  const docs = await Product.find(filter)
    .select({ price: 1, upload_time: 1 })
    .lean();

  const prices = [];
  docs.forEach((doc) => {
    const price = parsePriceValue(doc.price);
    if (!price) return;
    const uploaded = parseUploadDate(doc.upload_time || doc.uploaded_at);
    if (!uploaded || uploaded < start || uploaded > end) return;
    prices.push(price);
  });

  if (!prices.length) return null;
  prices.sort((a, b) => a - b);

  const trimmed = trimPriceArray(prices, 0.1);
  const base = trimmed.length ? trimmed : prices;
  const avg = Math.round(
    base.reduce((acc, cur) => acc + cur, 0) / base.length
  );

  const quartile = Math.max(1, Math.floor(prices.length * 0.1));
  const lowPrice = prices[Math.min(quartile, prices.length - 1)];
  const highPrice =
    prices[Math.max(prices.length - quartile - 1, prices.length - 1)];

  const recommendedPrice = roundToStep(avg);
  const recommendedMin = roundToStep(
    trimmed.length > 0
      ? trimmed[0]
      : Math.max(lowPrice || avg, Math.round(avg * 0.97))
  );
  const recommendedMax = roundToStep(
    trimmed.length > 0
      ? trimmed[trimmed.length - 1]
      : Math.min(highPrice || avg, Math.round(avg * 1.03))
  );
  const fastQuantile = prices.length ? Math.floor(prices.length * 0.18) : 0;
  const fastCandidate = prices[Math.max(0, Math.min(fastQuantile, prices.length - 1))];
  const fastFallback = Math.max(recommendedMin || avg, Math.round(recommendedPrice * 0.98));
  const fastSalePrice = roundToStep(fastCandidate || fastFallback);

  return {
    averagePrice: avg,
    lowPrice,
    highPrice,
    recommendedPrice,
    recommendedMin,
    recommendedMax,
    fastSalePrice,
    sampleCount: prices.length,
  };
};

const getListingRecommendation = async (req, res) => {
  try {
    const model = typeof req.query.model === 'string' ? req.query.model.trim() : '';
    const storage =
      typeof req.query.storage === 'string' ? req.query.storage.trim() : '';
    const condition =
      typeof req.query.condition === 'string' ? req.query.condition.trim() : '';

    if (!model || !storage || !condition) {
      return res
        .status(400)
        .json({ error: 'model, storage, condition 파라미터가 필요합니다.' });
    }

    const recommendation = await calculateListingRecommendation({
      model,
      storage,
      condition,
    });

    if (!recommendation) {
      return res
        .status(404)
        .json({ error: '권장가를 계산할 데이터가 부족합니다.' });
    }

    res.json(recommendation);
  } catch (err) {
    console.error('Error in getListingRecommendation:', err);
    res.status(500).json({ error: '서버 에러' });
  }
};

module.exports = {
  getAllProducts,
  getPriceStats,
  getPriceTrend,
  getMarketSummary,
  getProductByUrl,
  getListingRecommendation,
  calculateListingRecommendation,
  recommendPrice,
  getUploadTrends,
  getDailyPriceDistribution,
  createReferenceRange,
  createReferenceAndPreviousRanges
};
