const Product = require('../models/Product'); // Product 모델 불러오기

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

const INVALID_UPLOAD_TIME_VALUES = [
  '시간 형식 오류',
  '시간 정보 없음',
  '등록 시간 정보 없음'
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
      platform,
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

    const normalizedSort = typeof sort === 'string' ? sort.toLowerCase() : '';
    const isNewestSort = ['latest', 'newest', 'lastest'].includes(normalizedSort);

    const filter = {};

    if (keyword) {
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
    if (platform) {
      const platforms = platform.split(',');
      filter.platform = { $in: platforms };
    }

    const needsNumericPrice =
      minPriceInt !== null ||
      maxPriceInt !== null ||
      normalizedSort === 'low' ||
      normalizedSort === 'high';

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
    } else if (needsNumericPrice && (normalizedSort === 'low' || normalizedSort === 'high')) {
      pipeline.push({ $match: { price_numeric: { $ne: null } } });
    }

    if (isNewestSort) {
      pipeline.push({
        $match: {
          upload_time: { $nin: INVALID_UPLOAD_TIME_VALUES }
        }
      });
      pipeline.push({ $sort: { upload_time: -1, _id: -1 } });
    } else if (normalizedSort === 'low' && needsNumericPrice) {
      pipeline.push({ $sort: { price_numeric: 1 } });
    } else if (normalizedSort === 'high' && needsNumericPrice) {
      pipeline.push({ $sort: { price_numeric: -1 } });
    } else {
      pipeline.push({ $sort: { _id: -1 } });
    }

    if (skip > 0) {
      pipeline.push({ $skip: skip });
    }
    pipeline.push({ $limit: limited });

    if (needsNumericPrice) {
      pipeline.push({ $project: { price_numeric: 0 } });
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
    if (normalizedSort === 'low') {
      products.sort((a, b) =>
        parseInt(a.price.replace(/[^0-9]/g, '')) - parseInt(b.price.replace(/[^0-9]/g, ''))
      );
    } else if (normalizedSort === 'high') {
      products.sort((a, b) =>
        parseInt(b.price.replace(/[^0-9]/g, '')) - parseInt(a.price.replace(/[^0-9]/g, ''))
      );
    }

    res.json(products);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: '서버 에러' });
  }
};

const getPriceStats = async (req, res) => {
  try {
    const keyword = req.query.keyword || '';
    const range = parseInt(req.query.range) || 7;
    const region = req.query.region;
    const platform = req.query.platform;

    const endDate = new Date();
    const startDate = new Date();
    startDate.setDate(endDate.getDate() - range);

    const filter = {};

    if (keyword) {
      const keywordNoSpace = keyword.replace(/\s/g, '');
      filter.$and = [
        {
          $or: [
            { title: { $regex: keyword, $options: 'i' } },
            { title: { $regex: keywordNoSpace, $options: 'i' } }
          ]
        },
        {
          title: { $not: /케이스|교환|구합니다/i }
        }
      ];
      const lowerKeyword = keyword.toLowerCase();
      if (
        lowerKeyword.includes('아이폰') &&
        !/미니|프로|플러스|맥스/i.test(lowerKeyword)
      ) {
        filter.$and.push({
          title: { $not: /미니|프로|플러스|맥스/i }
        });
      }
    }

    if (region) filter.region = region;
    if (platform) filter.platform = platform;

    const products = await Product.find(filter);

    const filtered = products.filter(p => {
      const uploadTime = new Date(p.upload_time);
      return !isNaN(uploadTime) && uploadTime >= startDate && uploadTime <= endDate;
    });

    const prices = filtered.map(p => parseInt(p.price.replace(/[^0-9]/g, ''))).filter(p => !isNaN(p));

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
    const now = new Date();
    const since = new Date(now.getTime() - 6 * 24 * 60 * 60 * 1000);

    const filter = {};
    if (keywordRaw) {
      const patterns = buildKeywordPatterns(keywordRaw);
      if (patterns.length) {
        const orClauses = [];
        const seen = new Set();
        patterns.forEach((pattern) => {
          ['title', 'description', 'model'].forEach((field) => {
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

      filter.title = filter.title || { $not: /케이스|교환|구합니다/i };

      const lowerKeyword = keywordRaw.toLowerCase();
      const iphoneLike = /아이폰|iphone/.test(lowerKeyword);
      if (iphoneLike && !/(미니|mini|프로|pro|프로맥스|promax)/.test(lowerKeyword)) {
        filter.$and = (filter.$and || []).concat({
          title: { $not: /미니|mini|프로|pro|프로맥스|promax/i }
        });
      }
    }

    const docs = await Product.find(filter).lean().limit(2500);
    const normalizedKeyword = normalizeForKeywordMatch(keywordRaw);
    const narrowedDocs = normalizedKeyword
      ? docs.filter((item) => {
          const parts = [item.title, item.description, item.model]
            .filter((value) => typeof value === 'string' && value.trim().length)
            .join(' ');
          if (!parts) return false;
          return normalizeForKeywordMatch(parts).includes(normalizedKeyword);
        })
      : docs;
    const sourceDocs = narrowedDocs.length ? narrowedDocs : docs;

    const grouped = {};

    for (const item of sourceDocs) {
      const price = parsePriceValue(item.price);
      if (!price || price <= 0) continue;

      const uploadedAt = parseUploadDate(item.upload_time || item.uploaded_at);
      if (!uploadedAt || uploadedAt < since) continue;

      const dayKey = uploadedAt.toISOString().slice(0, 10);
      const platform = item.platform || '기타';
      const status = isNewConditionEntry(item) ? 'new' : 'used';

      if (!grouped[platform]) grouped[platform] = {};
      if (!grouped[platform][dayKey]) grouped[platform][dayKey] = { new: [], used: [] };
      grouped[platform][dayKey][status].push(price);
    }

    const result = {};
    for (const [platform, dates] of Object.entries(grouped)) {
      const out = {};
      for (const [dateKey, buckets] of Object.entries(dates)) {
        const day = {};
        for (const [status, values] of Object.entries(buckets)) {
          const stats = trimAndAverage(values);
          if (stats) day[status] = stats;
        }
        if (Object.keys(day).length) {
          out[dateKey] = day;
        }
      }
      if (Object.keys(out).length) {
        result[platform] = Object.fromEntries(
          Object.entries(out).sort(([a], [b]) => a.localeCompare(b))
        );
      }
    }

    res.json(result);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: '서버 오류' });
  }
};

const recommendPrice = async (req, res) => {
  try {
    const keyword = req.query.keyword || '';

    const endDate   = new Date();
    endDate.setHours(23, 59, 59, 999);

    const startDate = new Date(endDate);
    startDate.setDate(endDate.getDate() - 6);
    startDate.setHours(0, 0, 0, 0);

    const matchStage = {
      $expr: {
        $and: [
          { $gte: [{ $toDate: '$upload_time' }, startDate] },
          { $lte: [{ $toDate: '$upload_time' }, endDate] }
        ]
      }
    };

    if (keyword.trim()) {
      const keywordNoSpace = keyword.replace(/\s/g, '');
      matchStage.$and = [
        {
          $or: [
            { title: { $regex: keyword, $options: 'i' } },
            { title: { $regex: keywordNoSpace, $options: 'i' } }
          ]
        },
        {
          title: { $not: /케이스|교환|구합니다/i }
        }
      ];
      const lowerKeyword = keyword.toLowerCase();
      if (
        lowerKeyword.includes('아이폰') &&
        !/미니|프로|플러스|맥스/i.test(lowerKeyword)
      ) {
        matchStage.$and.push({
          title: { $not: /미니|프로|플러스|맥스/i }
        });
      }
    }

    const products = await Product.find(matchStage);

    // 새상품과 중고 분리
    const newPrices = [];
    const usedPrices = [];

    for (const item of products) {
      const price = parseInt(item.price?.replace(/[^0-9]/g, ''));
      if (isNaN(price)) continue;

      const cond = item.condition;
      if (typeof cond === 'string' && (cond.includes('새 상품') || cond.includes('새상품'))) {
        newPrices.push(price);
      } else {
        usedPrices.push(price);
      }
    }

    const analyze = (priceArray) => {
      if (priceArray.length < 5) return null;

      const sorted = priceArray.sort((a, b) => a - b);
      const lowerIndex = Math.floor(sorted.length * 0.10);
      const upperIndex = Math.ceil(sorted.length * 0.90);
      const filtered = sorted.slice(lowerIndex, upperIndex);

      if (filtered.length === 0) return null;

      return {
        recommended: Math.round(filtered.reduce((a, b) => a + b, 0) / filtered.length),
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
    console.error(err);
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

module.exports = {
  getAllProducts,
  getPriceStats,
  getPriceTrend,
  recommendPrice,
  getUploadTrends,
  getDailyPriceDistribution
};
