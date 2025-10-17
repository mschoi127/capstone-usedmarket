const mongoose = require('mongoose');

// 제품 스키마 정의 (MongoDB에 저장될 데이터 형식과 일치)
const productSchema = new mongoose.Schema({
  title: String,            // 제품 제목
  price: String,            // 가격 문자열
  condition: String,        // 제품 상태
  upload_time: String,      // 게시 시간
  region: String,           // 거래 지역
  url: String,              // 상세 페이지 링크
  image_url: String,        // 이미지 URL
  status: String,           // 판매 상태
  category: String,         // 카테고리
  description: String,      // 제품 설명
  platform: String          // 수집한 플랫폼 이름
}, {
  collection: 'temp'        // 컬렉션 이름 명시적으로 지정
});

// Product 모델 생성 및 export
module.exports = mongoose.model('Product', productSchema);
