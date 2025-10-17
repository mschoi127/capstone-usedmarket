class Product {
  final String? id;
  final String? title;
  final int? price;
  final String? platform;
  final String? url;
  final String? imageUrl;
  final String? uploadTime;

  Product({
    this.id,
    this.title,
    this.price,
    this.platform,
    this.url,
    this.imageUrl,
    this.uploadTime,
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    return Product(
      id: (j['_id'] ?? j['id'])?.toString(),
      title: j['title']?.toString(),
      price: j['price'] is num ? (j['price'] as num).toInt() : int.tryParse('${j['price']}'),
      platform: j['platform']?.toString(),
      url: j['url']?.toString(),
      imageUrl: j['image_url']?.toString() ?? j['imageUrl']?.toString(),
      uploadTime: j['upload_time']?.toString() ?? j['uploadTime']?.toString(),
    );
  }
}
