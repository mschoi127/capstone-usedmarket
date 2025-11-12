import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/model_storage_resolver.dart';
import '../utils/model_formatters.dart';

class MainSearchPage extends StatefulWidget {
  const MainSearchPage({super.key});
  @override
  State<MainSearchPage> createState() => _MainSearchPageState();
}

class _MainSearchPageState extends State<MainSearchPage> {
  final _q = TextEditingController(),
      _min = TextEditingController(),
      _max = TextEditingController();

  final _platforms = {'번개장터', '당근마켓', '중고나라'};
  final _picked = <String>{'번개장터', '당근마켓', '중고나라'};
  final _sorts = ['최신순', '가격 낮은순', '가격 높은순'];
  String _sort = '최신순';

  // 웹: localhost, 에뮬레이터: 10.0.2.2, 실기기: PC LAN IP
  static const baseUrl = 'http://localhost:3001';
  static const int _limit = 20;

  int _page = 1;
  int _lastCount = 0;
  String? _resolvedModel;
  String? _resolvedStorage;
  Future<List<Product>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch(_page); // 첫 로드시 자동 조회
  }

  // === 서버 스키마 매핑 ===
  String _sortToServer(String ui) {
    switch (ui) {
      case '최신순':
        return 'latest';
      case '가격 낮은순':
        return 'low'; // 서버 규약에 맞춤
      case '가격 높은순':
        return 'high'; // 서버 규약에 맞춤
      default:
        return 'latest';
    }
  }

  String? _platformToServer(String ui) {
    switch (ui) {
      case '번개장터':
        return '번개장터';
      case '당근마켓':
        return '당근마켓';
      case '중고나라':
        return '중고나라';
      default:
        return null;
    }
  }

  Future<List<Product>> _fetch(int page,
      {String? model, String? storage}) async {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json'},
      ),
    );

    final queryKeyword = _q.text.trim();
    String? resolvedModel = model;
    String? resolvedStorage = storage;
    resolvedModel ??= await ModelStorageResolver.matchModel(queryKeyword);
    resolvedStorage ??= await ModelStorageResolver.matchStorage(queryKeyword);

    dio.interceptors.add(
      LogInterceptor(
        requestBody: true,
        responseBody: false,
        requestHeader: false,
        responseHeader: false,
      ),
    );

    final platformCodes =
        _picked.map(_platformToServer).whereType<String>().toList();
    final allSelected = _picked.length == _platforms.length;
    final sortKey = _sortToServer(_sort);

    final qp = <String, dynamic>{
      'keyword': _q.text.trim(),
      if (!allSelected && platformCodes.isNotEmpty)
        'platform': platformCodes.join(','), // 선택된 플랫폼만 보기
      'sort': sortKey,
      if (_min.text.trim().isNotEmpty)
        'minPrice': int.tryParse(_min.text.trim()),
      if (_max.text.trim().isNotEmpty)
        'maxPrice': int.tryParse(_max.text.trim()),
      'page': page,
      'limit': _limit,
    };
    if (resolvedModel != null && resolvedModel.isNotEmpty) {
      qp['model'] = resolvedModel;
    }
    if (resolvedStorage != null && resolvedStorage.isNotEmpty) {
      qp['storage'] = resolvedStorage;
    }

    final resp = await dio.get('/products', queryParameters: qp);
    if (resp.statusCode != 200) {
      throw Exception(
        'HTTP ${resp.statusCode} ${resp.statusMessage}  ${resp.requestOptions.uri}',
      );
    }

    final body = resp.data;
    final List raw = switch (body) {
      List l => l,
      Map m =>
        (m['items'] ?? m['data'] ?? m['products'] ?? m['result'] ?? []) as List,
      _ => const [],
    };

    final items =
        raw.map((e) => Product.fromJson(e as Map<String, dynamic>)).toList();
    debugPrint('Fetched ${items.length} items (page $page)');
    return items;
  }

  Future<void> _search([int page = 1]) async {
    final kw = _q.text.trim();
    final model = await ModelStorageResolver.matchModel(kw);
    final storage = await ModelStorageResolver.matchStorage(kw);
    setState(() {
      _page = page;
      _resolvedModel = model;
      _resolvedStorage = storage;
      _future = _fetch(_page, model: model, storage: storage); // setState는 void만 반환
    });
  }

  void _reset() {
    _q.clear();
    _min.clear();
    _max.clear();
    _picked
      ..clear()
      ..addAll(_platforms);
    _sort = '최신순';
    _page = 1;
    _lastCount = 0;
    _resolvedModel = null;
    _resolvedStorage = null;
    setState(() {
      _future = _fetch(_page);
    });
  }

  @override
  void dispose() {
    _q.dispose();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  // 외부 브라우저로 링크 열기
  Future<void> _openUrl(String? url) async {
    if (url == null || url.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('이동할 링크가 없습니다.')));
      return;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('잘못된 링크 형식입니다.')));
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('링크를 열 수 없습니다.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final modelLabel = formatModelLabel(_resolvedModel);
    final storageLabel = formatStorageLabel(_resolvedStorage);

    Widget searchBar() => TextField(
          controller: _q,
          onSubmitted: (_) => _search(1),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '모델명, 키워드 검색',
            prefixIcon: const Icon(Icons.search),
            contentPadding: const EdgeInsets.symmetric(
              vertical: 16,
              horizontal: 16,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(28)),
            filled: true,
            fillColor: cs.surfaceContainerHighest.withOpacity(.6),
          ),
        );

    Widget platformChips() => Wrap(
          spacing: 8,
          runSpacing: -4,
          children: [
            for (final p in _platforms)
              FilterChip(
                label: Text(p),
                selected: _picked.contains(p),
                onSelected: (_) => setState(
                  () =>
                      _picked.contains(p) ? _picked.remove(p) : _picked.add(p),
                ),
                showCheckmark: false,
                shape:
                    StadiumBorder(side: BorderSide(color: cs.outlineVariant)),
              ),
          ],
        );

    Widget numberField(String label, TextEditingController c) => TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: label,
            prefixText: '₩ ',
            contentPadding: const EdgeInsets.symmetric(
              vertical: 14,
              horizontal: 14,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
        );

    Widget sortSelector() => InkWell(
          onTap: () async {
            final pick = await showModalBottomSheet<String>(
              context: context,
              showDragHandle: true,
              builder: (_) => ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  for (final s in _sorts)
                    ListTile(
                      leading: Icon(
                        s == _sort
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      title: Text(s),
                      onTap: () => Navigator.pop(context, s),
                    ),
                ],
              ),
            );
            if (pick != null) {
              setState(() => _sort = pick);
              _search(1); // 정렬 바꾸면 즉시 재요청
            }
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.tune),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        '정렬: ',
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Flexible(
                        child: Text(
                          _sort,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyLarge?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.keyboard_arrow_down_rounded),
              ],
            ),
          ),
        );

    Widget productTile(Product it) {
      Color pColor() {
        switch (it.platform) {
          case '번개장터':
            return Colors.redAccent;
          case '당근마켓':
            return Colors.deepOrangeAccent;
          case '중고나라':
            return Colors.blueAccent;
          default:
            return cs.primary;
        }
      }

      final modelLabel = formatModelLabel(it.modelName);
      final storageLabel = formatStorageLabel(it.storage);
      final metaWidgets = <Widget>[];
      if (modelLabel != null) {
        metaWidgets.add(_metaChip(modelLabel));
      }
      if (storageLabel != null) {
        metaWidgets.add(_metaChip(storageLabel));
      }

      return ListTile(
        onTap: () => _openUrl(it.url), // 카드 탭 시 링크 열기
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: 56,
            child: (it.imageUrl ?? '').isNotEmpty
                ? Image.network(it.imageUrl!, fit: BoxFit.cover)
                : Container(
                    color: cs.surfaceContainerHigh,
                    child: const Icon(Icons.image_outlined),
                  ),
          ),
        ),
        title: Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: pColor().withOpacity(.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    it.platform,
                    style:
                        TextStyle(color: pColor(), fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    it.time ?? '',
                    style: TextStyle(color: cs.outline),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (metaWidgets.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: metaWidgets,
              ),
            ],
          ],
        ),
        trailing: Text(
          (it.price == null || it.price == 0) ? '-' : '₩ ${_comma(it.price!)}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      );
    }

    Widget resultArea() => FutureBuilder<List<Product>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return Card(
                color: cs.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline, color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Text(
                            '데이터 요청 실패',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: cs.onErrorContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${snap.error}',
                        style: TextStyle(color: cs.onErrorContainer),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonal(
                        onPressed: () => _search(_page),
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              );
            }
            final items = snap.data ?? const [];
            _lastCount = items.length;

            if (items.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Column(
                  children: [
                    Icon(Icons.search_off, size: 48, color: cs.outline),
                    const SizedBox(height: 8),
                    Text(
                      '검색 결과가 없습니다.',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Text(
                      '키워드나 필터를 조정해 보세요.',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: cs.outline),
                    ),
                  ],
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '결과: ${items.length}건 (페이지 $_page)',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                for (final it in items) productTile(it),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _page > 1 ? () => _search(_page - 1) : null,
                      icon: const Icon(Icons.chevron_left),
                      label: const Text('이전'),
                    ),
                    Text('페이지 $_page'),
                    FilledButton.icon(
                      onPressed: _lastCount == _limit
                          ? () => _search(_page + 1)
                          : null,
                      icon: const Icon(Icons.chevron_right),
                      label: const Text('다음'),
                    ),
                  ],
                ),
              ],
            );
          },
        );

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          children: [
            searchBar(),
            const SizedBox(height: 12),
            platformChips(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: numberField('최소 가격', _min)),
                const SizedBox(width: 10),
                Expanded(child: numberField('최대 가격', _max)),
              ],
            ),
            const SizedBox(height: 12),
            sortSelector(),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _search(1),
                    icon: const Icon(Icons.search),
                    label: const Text('검색'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _reset,
                  icon: const Icon(Icons.refresh),
                  label: const Text('초기화'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (modelLabel != null || storageLabel != null) ...[
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (modelLabel != null)
                    _metaChip('모델 $modelLabel'),
                  if (storageLabel != null)
                    _metaChip('용량 $storageLabel'),
                ],
              ),
              const SizedBox(height: 16),
            ],
            resultArea(),
          ],
        ),
      ),
    );
  }

  String _comma(num n) {
    final s = n.toStringAsFixed(0);
    return s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  }

  Widget _metaChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.55),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: const TextStyle(fontSize: 12)),
      );
}

class Product {
  final String id, title, platform;
  final num? price;
  final String? imageUrl, time;
  final String? url; // 링크 필드
  final String? modelName;
  final String? storage;

  Product({
    required this.id,
    required this.title,
    required this.platform,
    required this.price,
    this.imageUrl,
    this.time,
    this.url,
    this.modelName,
    this.storage,
  });

  factory Product.fromJson(Map<String, dynamic> j) {
    num? toNum(dynamic v) {
      if (v == null) return null;
      if (v is num) return v;
      final s = v.toString().replaceAll(RegExp(r'[^0-9.]'), '');
      return num.tryParse(s);
    }

    return Product(
      id: (j['_id'] ?? j['id'] ?? '').toString(),
      title: (j['title'] ?? j['name'] ?? '').toString(),
      price: toNum(j['price']),
      platform: (j['platform'] ?? j['site'] ?? '').toString(),
      imageUrl:
          (j['image'] ?? j['imageUrl'] ?? j['thumbnail'] ?? j['image_url'])
              ?.toString(),
      time: (j['upload_time'] ?? j['createdAt'] ?? j['time'])?.toString(),
      url: (j['url'] ?? j['link'])?.toString(),
      modelName: j['model_name']?.toString(),
      storage: j['storage']?.toString(),
    );
  }
}
