class ProductSummary {
  final String title;
  final String price;
  final String? imageUrl;
  final String url;
  final String platform;

  const ProductSummary({
    required this.title,
    required this.price,
    required this.url,
    required this.platform,
    this.imageUrl,
  });
}
