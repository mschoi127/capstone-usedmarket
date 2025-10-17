const express = require('express'); // Express 불러오기
const mongoose = require('mongoose'); // MongoDB 연결을 위한 Mongoose 불러오기
const productRoutes = require('./routes/productRoutes'); // 제품 관련 라우터 불러오기
const cors = require('cors'); // CORS 문제 해결을 위한 미들웨어

const app = express(); // Express 앱 생성

app.use(express.json()); // 요청 본문에서 JSON 파싱
app.use(cors()); // 모든 출처에서의 요청 허용
app.use('/products', productRoutes); // /products로 시작하는 요청은 productRoutes로 위임
// MongoDB에 연결
mongoose.connect('mongodb://localhost:27017/market2')
  .then(() => console.log('MongoDB Atlas connected'))
  .catch(err => console.log(err));

// 서버 실행 (포트 3001번)
app.listen(3001, () => {
  console.log('Server running');
});
