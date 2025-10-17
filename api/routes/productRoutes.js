const express = require('express');
const router = express.Router(); // 라우터 객체 생성
const {
  getAllProducts,
  getPriceStats,
  getPriceTrend,
  recommendPrice,
  getUploadTrends,
  getDailyPriceDistribution
} = require('../controllers/productController'); // 컨트롤러 함수 불러오기

// 전체 상품 조회 또는 키워드 검색
router.get('/', getAllProducts);

// 시세 분석 API
// 예: GET /products/price-stats?keyword=아이폰&range=7&region=개신동
router.get('/price-stats', getPriceStats);

router.get('/price-trend', getPriceTrend);

router.get('/recommend-price', recommendPrice);

router.get('/upload-trends', getUploadTrends);

router.get('/daily-price-distribution', getDailyPriceDistribution);

module.exports = router; // 라우터 내보내기
