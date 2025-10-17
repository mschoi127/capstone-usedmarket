import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fl_chart/fl_chart.dart';
import '../data/api_client.dart';

class ChatbotBody extends StatefulWidget {
  const ChatbotBody({super.key});
  @override
  State<ChatbotBody> createState() => _ChatbotBodyState();
}

class _Msg {
  final String role, text;
  final List<dynamic> cards; // LLM 카드(옵션)
  final Map<String, dynamic>? trend; // 시세 추세(옵션)
  _Msg(this.role, this.text, {this.cards = const [], this.trend});
}

/// ---- 대화 컨텍스트(프론트 로컬 메모리) ----
class _QueryCtx {
  String? keyword;
  Set<String> platforms; // 번개장터/당근마켓/중고나라
  String sort; // latest | price_asc | price_desc
  int? minPrice;
  int? maxPrice;
  int page;

  _QueryCtx({
    Set<String>? platforms,
    this.sort = 'latest',
    this.minPrice,
    this.maxPrice,
    this.page = 1,
  }) : platforms = platforms ?? {'번개장터', '당근마켓', '중고나라'};

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'platforms': platforms.toList(),
        'sort': sort,
        'minPrice': minPrice,
        'maxPrice': maxPrice,
        'page': page,
        // 필요 시 서버 기본 5개보다 더 수확하고 싶으면 아래 주석을 풀어라.
        // 'limit': 12,
      };

  void resetPage() => page = 1;
}

class _ChatbotBodyState extends State<ChatbotBody> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  late final ApiClient _api;
  bool _loading = false;

  final _QueryCtx _lastCtx = _QueryCtx();

  @override
  void initState() {
    super.initState();
    _api = ApiClient();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // ====== 키워드 정규화/정본화/우선순위 ======
  static const Map<String, String> _en2ko = {
    'galaxy': '갤럭시',
    'iphone': '아이폰',
    'ultra': '울트라',
    'plus': '플러스',
    'max': '맥스',
    'pro': '프로',
    'fe': 'FE',
  };

  String _cleanupToKorean(String s) {
    var t = s;
    t = t.replaceAll('+', ' 플러스 ');
    t = t.toLowerCase();
    t = t.replaceAll(RegExp(r'[^0-9a-z가-힣 ]'), ' ');
    _en2ko.forEach((en, ko) {
      t = t.replaceAll(RegExp('\\b$en\\b', caseSensitive: false), ko);
    });
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();

    // s25 / s 25 / S25e → S25 / S25 / S25E
    t = t.replaceAllMapped(
      RegExp(r'\b[sS]\s*(\d{1,2})([a-z])?'),
      (m) => 'S${m.group(1)}${(m.group(2) ?? '').toUpperCase()}',
    );
    return t;
  }

  String? _canonModel(String s) {
    final t = _cleanupToKorean(s);

    // Galaxy S 시리즈
    final mg = RegExp(
      r'(?:갤럭시)\s*S?\s*(\d{1,2})(?:\s*(FE))?(?:\s*(울트라|플러스|프로맥스|프로|맥스))?',
      caseSensitive: false,
    ).firstMatch(t);
    if (mg != null) {
      final num = mg.group(1)!;
      final fe = (mg.group(2) ?? '').isNotEmpty ? ' FE' : '';
      final suf = (mg.group(3) ?? '').isNotEmpty ? ' ${mg.group(3)!}' : '';
      return '갤럭시 S$num$fe$suf'.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    // iPhone 시리즈
    final mi = RegExp(
      r'아이폰\s*(\d{1,2})\s*(프로\s*맥스|프로맥스|프로\s*max|프로max|프로|플러스|맥스)?',
      caseSensitive: false,
    ).firstMatch(t);
    if (mi != null) {
      final num = mi.group(1)!;
      final raw = (mi.group(2) ?? '');
      final suf = raw.isEmpty
          ? ''
          : ' ${_cleanupToKorean(raw.replaceAll('max', '맥스'))}';
      return '아이폰 $num$suf'.replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return null;
  }

  bool _hasDigits(String s) => RegExp(r'\d').hasMatch(s);

  int _suffixScore(String s) {
    var score = 0;
    if (RegExp(r'울트라', caseSensitive: false).hasMatch(s)) score += 2;
    if (RegExp(r'프로\s*맥스|프로맥스', caseSensitive: false).hasMatch(s)) score += 2;
    if (RegExp(r'프로', caseSensitive: false).hasMatch(s)) score += 1;
    if (RegExp(r'플러스|맥스', caseSensitive: false).hasMatch(s)) score += 1;
    if (RegExp(r'\bFE\b', caseSensitive: false).hasMatch(s)) score += 1;
    return score;
  }

  String _normalizeKw(String s) => _canonModel(s) ?? _cleanupToKorean(s);

  String _preferKeyword(String? oldKw, String newKw) {
    final n = _normalizeKw(newKw);
    if (n.isEmpty) return oldKw ?? '';
    if (oldKw == null || oldKw.isEmpty) return n;

    final o = _normalizeKw(oldKw);
    final cn = _canonModel(n);
    final co = _canonModel(o);
    if (cn != null && co == null) return n;
    if (co != null && cn == null) return o;

    if (cn != null && co != null) {
      final scoreN =
          (_hasDigits(n) ? 1 : 0) * 10 + _suffixScore(n) * 5 + n.length;
      final scoreO =
          (_hasDigits(o) ? 1 : 0) * 10 + _suffixScore(o) * 5 + o.length;
      return scoreN >= scoreO ? n : o;
    }

    if (_hasDigits(n) && !_hasDigits(o)) return n;
    if (n.length > o.length) return n;
    return o;
  }

  // ---------- 금액 파서(만/천 단위도 처리) ----------
  int? _toWon(String raw) {
    final s = raw.replaceAll(RegExp(r'\s'), '');
    final m = RegExp(r'(?:(\d+)\s*만)?\s*(\d{1,3})?\s*천?').firstMatch(s);
    if (m != null) {
      final man = int.tryParse(m.group(1) ?? '0') ?? 0;
      final chun = int.tryParse(m.group(2) ?? '0') ?? 0;
      if (man > 0 || chun > 0) {
        return man * 10000 + (chun == 0 ? 0 : chun * 1000);
      }
    }
    final d = RegExp(r'(\d{1,9})').firstMatch(s);
    if (d != null) return int.parse(d.group(1)!);
    return null;
  }

  // ---------- 규칙 기반 파서 ----------
  void _applyParsedIntent(String userText) {
    final tight = userText.replaceAll(RegExp(r'\s+'), '');

    // 1) 범위
    final rangeRe = RegExp(r'(\d+)(만)?\s*원?\s*[-~]\s*(\d+)(만)?\s*원?');
    final mr = rangeRe.firstMatch(userText) ?? rangeRe.firstMatch(tight);
    if (mr != null) {
      final a = _toWon('${mr.group(1)!}${mr.group(2) ?? ''}') ?? 0;
      final b = _toWon('${mr.group(3)!}${mr.group(4) ?? ''}') ?? 0;
      if (a > 0 && b > 0) {
        _lastCtx.minPrice = (a < b) ? a : b;
        _lastCtx.maxPrice = (a < b) ? b : a;
      }
    } else {
      // 2) 단일값 + 방향
      final hasLE = RegExp(r'(이하|이내|최대|까지|미만)').hasMatch(userText) ||
          RegExp(r'(이하|이내|최대|까지|미만)').hasMatch(tight);
      final hasGE = RegExp(r'(이상|부터|최소|초과)').hasMatch(userText) ||
          RegExp(r'(이상|부터|최소|초과)').hasMatch(tight);
      final mNum = RegExp(r'(\d+)(만)?\s*원?').firstMatch(userText) ??
          RegExp(r'(\d+)(만)?\s*원?').firstMatch(tight);
      final val = mNum != null
          ? _toWon('${mNum.group(1)!}${mNum.group(2) ?? ''}')
          : null;
      if (val != null) {
        if (hasLE) _lastCtx.maxPrice = val;
        if (hasGE) _lastCtx.minPrice = val;
      }
    }

    // ----- 정렬 -----
    final t = userText.replaceAll(' ', '');
    if (t.contains('최신순')) _lastCtx.sort = 'latest';
    if (t.contains('가격낮은순')) _lastCtx.sort = 'price_asc';
    if (t.contains('가격높은순')) _lastCtx.sort = 'price_desc';

    // ----- 플랫폼 (사용자가 말했을 때만 설정) -----
    final wanted = <String>{};
    if (userText.contains('번개장터')) wanted.add('번개장터');
    if (userText.contains('당근') || userText.contains('당근마켓')) {
      wanted.add('당근마켓');
    }
    if (userText.contains('중고나라')) wanted.add('중고나라');
    if (wanted.isNotEmpty) _lastCtx.platforms = wanted;

    // ----- 페이지 -----
    if (userText.contains('더보') ||
        userText.contains('더봐') ||
        userText.contains('더줘')) {
      _lastCtx.page += 1;
    } else {
      _lastCtx.resetPage();
    }

    // ----- 키워드 -----
    final kwHit = _canonModel(userText);
    if (kwHit != null && kwHit.isNotEmpty) {
      _lastCtx.keyword = _preferKeyword(_lastCtx.keyword, kwHit);
    } else {
      final loose = RegExp(
        r'(갤럭시\s*s?\s*\d{1,2}\w*|아이폰\s*\d{1,2}\w*)',
        caseSensitive: false,
      ).firstMatch(userText);
      if (loose != null) {
        _lastCtx.keyword = _preferKeyword(_lastCtx.keyword, loose.group(0)!);
      }
    }
  }

  // 카드로부터 보정: 플랫폼은 건드리지 않음, 키워드만 수확
  void _harvestFromCards(List<dynamic> cards) {
    final titles = <String>[];
    for (final c in cards) {
      final title = (c['title'] ?? '') as String;
      if (title.isNotEmpty) titles.add(title);
    }

    final counts = <String, int>{};
    for (final t in titles) {
      final c = _canonModel(t);
      if (c != null && c.isNotEmpty) {
        counts[c] = (counts[c] ?? 0) + 1;
      } else {
        for (final hit in RegExp(
          r'(갤럭시\s*s?\s*\d{1,2}\w*|아이폰\s*\d{1,2}\w*)',
          caseSensitive: false,
        ).allMatches(t)) {
          final k = _normalizeKw(hit.group(0)!);
          counts[k] = (counts[k] ?? 0) + 1;
        }
      }
    }
    if (counts.isNotEmpty) {
      final best =
          counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      _lastCtx.keyword = _preferKeyword(_lastCtx.keyword, best);
    }
  }

  void _jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final raw = _ctrl.text.trim();
    if (raw.isEmpty || _loading) return;

    setState(() {
      _msgs.add(_Msg('user', raw));
      _loading = true;
    });
    _jumpToEnd();
    _ctrl.clear();

    _applyParsedIntent(raw);

    // 여전히 키워드 없으면 직전 사용자 발화에서 회수
    if (_lastCtx.keyword == null) {
      final reKw = RegExp(
        r'(갤럭시\s*s?\s*\d{1,2}\w*|아이폰\s*\d{1,2}\w*|아이폰|갤럭시)',
        caseSensitive: false,
      );
      for (var i = _msgs.length - 1; i >= 0; i--) {
        final m = _msgs[i];
        if (m.role != 'user') continue;
        final hit = reKw.firstMatch(m.text);
        if (hit != null) {
          _lastCtx.keyword = _preferKeyword(_lastCtx.keyword, hit.group(0)!);
          break;
        }
      }
    }

    try {
      // ApiClient 구현에 따라 다음 중 하나를 써라.
      // 1) 레거시(이미 동작 중): context 키
      final resp = await _api.sendChat(raw, context: _lastCtx.toJson());

      // 2) 권장: client_ctx 키 (ApiClient쪽도 바꿔야 함)
      // final resp = await _api.sendChat(raw, clientCtx: _lastCtx.toJson());

      final text = (resp['text'] ?? '').toString();
      final cards = (resp['cards'] as List?) ?? const [];
      final trend = resp['trend'] is Map<String, dynamic>
          ? (resp['trend'] as Map<String, dynamic>)
          : null;

      if (cards.isNotEmpty) _harvestFromCards(cards);

      setState(() {
        _msgs.add(_Msg('assistant', text, cards: cards, trend: trend));
      });
    } catch (e) {
      setState(() {
        _msgs.add(_Msg('assistant', '에러: $e'));
      });
    } finally {
      if (mounted) setState(() => _loading = false);
      _jumpToEnd();
    }
  }

  // -------------------- 링크 열기 --------------------
  Future<void> _openExternalLink(String? url) async {
    if (url == null || url.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('이동할 링크가 없습니다.')),
      );
      return;
    }
    final uri = Uri.tryParse(url.trim());
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('잘못된 링크 형식입니다.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('링크를 열 수 없습니다.')),
      );
    }
  }

  // -------------------- 카드 렌더 --------------------
  Widget _buildCards(List<dynamic> cards) {
    if (cards.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: cards.map((c) {
        final title = (c['title'] ?? '').toString();
        final price = (c['price'] ?? '').toString();
        final imageUrl =
            (c['image_url'] ?? c['imageUrl'] ?? c['thumbnail']) as String?;
        final platform = c['platform'] as String?;
        final uploaded = (c['uploaded_at'] ?? c['uploadedAt']) as String?;
        final url = (c['url'] ?? c['link']) as String?;

        Widget thumb() {
          if (imageUrl == null || imageUrl.isEmpty) {
            return Container(
              color: cs.surfaceContainerHigh,
              child: const Icon(Icons.image_outlined),
            );
          }
          return Image.network(
            imageUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              color: cs.surfaceContainerHigh,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image_outlined),
            ),
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return Container(
                color: cs.surfaceContainerHigh,
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            },
          );
        }

        return InkWell(
          onTap: () => _openExternalLink(url),
          borderRadius: BorderRadius.circular(12),
          child: Card(
            margin: const EdgeInsets.only(top: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(width: 64, height: 64, child: thumb()),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(
                              child: Text(price,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.open_in_new,
                                size: 16, color: Colors.grey),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if ((platform ?? '').isNotEmpty ||
                            (uploaded ?? '').isNotEmpty)
                          Text(
                            [platform, uploaded]
                                .where((e) => (e ?? '').isNotEmpty)
                                .join(' · '),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.grey),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // -------------------- 시세 그래프 렌더 --------------------
  Widget _buildTrend(Map<String, dynamic> trend) {
    if (trend.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    // 날짜 정렬
    List<String> sortDates(Iterable<String> dates) {
      final list = dates.toList()..sort((a, b) => a.compareTo(b));
      return list;
    }

    // yyyy-mm-dd -> epoch-day(double)
    double dateToX(String ymd) {
      final parts = ymd.split('-');
      if (parts.length != 3) return 0;
      final dt = DateTime(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      return dt.millisecondsSinceEpoch / (24 * 60 * 60 * 1000);
    }

    String fmtLabel(double x) {
      final ms = (x * 24 * 60 * 60 * 1000).toInt();
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final mm = dt.month.toString().padLeft(2, '0');
      final dd = dt.day.toString().padLeft(2, '0');
      return '$mm/$dd';
    }

    // 플랫폼 색상 (신품은 같은 색상에 투명도만 낮춤)
    Color pColor(String platform, {bool isNew = false}) {
      final base = switch (platform) {
        '번개장터' => Colors.redAccent,
        '당근마켓' => Colors.deepOrangeAccent,
        '중고나라' => Colors.blueAccent,
        _ => cs.primary,
      };
      return isNew ? base.withOpacity(0.55) : base;
    }

    // 옵션: used 우선, 없으면 new로 대체
    const bool preferUsed = true;

    final series = <_Series>[];
    final seriesMap = <String, List<FlSpot>>{}; // key: "플랫폼(중고)" / "플랫폼(신품)"

    trend.forEach((platform, datesMap) {
      if (datesMap is! Map) return;
      final dates = sortDates(datesMap.keys.cast<String>());

      if (preferUsed) {
        // used 우선 단일 시리즈(없으면 new로 대체)
        final key = '$platform(중고)';
        final spots = <FlSpot>[];
        for (final d in dates) {
          final daily = datesMap[d];
          if (daily is! Map) continue;
          final used = daily['used'];
          final news = daily['new'];
          num? y;
          if (used is Map && used['avg'] != null) {
            y = used['avg'] as num;
          } else if (news is Map && news['avg'] != null) {
            y = news['avg'] as num; // 대체
          }
          if (y != null) spots.add(FlSpot(dateToX(d), y.toDouble()));
        }
        if (spots.isNotEmpty) {
          seriesMap[key] = spots;
        }
      } else {
        // used/new 각각 별도 시리즈
        final usedSpots = <FlSpot>[];
        final newSpots = <FlSpot>[];
        for (final d in dates) {
          final daily = datesMap[d];
          if (daily is! Map) continue;
          final used = daily['used'];
          final news = daily['new'];
          if (used is Map && used['avg'] != null) {
            usedSpots.add(FlSpot(dateToX(d), (used['avg'] as num).toDouble()));
          }
          if (news is Map && news['avg'] != null) {
            newSpots.add(FlSpot(dateToX(d), (news['avg'] as num).toDouble()));
          }
        }
        if (usedSpots.isNotEmpty) seriesMap['$platform(중고)'] = usedSpots;
        if (newSpots.isNotEmpty) seriesMap['$platform(신품)'] = newSpots;
      }
    });

    if (seriesMap.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('시세 추세 데이터가 부족합니다.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: cs.outline)),
      );
    }

    // _Series 구성
    seriesMap.forEach((name, spots) {
      final isNew = name.endsWith('(신품)');
      final platformName = name.split('(').first;
      series.add(_Series(
        name,
        spots..sort((a, b) => a.x.compareTo(b.x)),
        pColor(platformName, isNew: isNew),
      ));
    });

    final allX = series.expand((s) => s.spots.map((e) => e.x)).toList()..sort();
    final minX = allX.first, maxX = allX.last;
    final allY = series.expand((s) => s.spots.map((e) => e.y)).toList()..sort();
    final minY = allY.first, maxY = allY.last;
    final pad = (maxY - minY) * 0.05;
    final xInterval = ((maxX - minX) / 6.0).clamp(1.0, double.infinity);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text('최근 시세 추세(평균가)',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            for (final s in series)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 3, color: s.color),
                  const SizedBox(width: 6),
                  Text(s.name, style: const TextStyle(fontSize: 12)),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        AspectRatio(
          aspectRatio: 1.6,
          child: LineChart(
            LineChartData(
              minX: minX,
              maxX: maxX,
              minY: (minY - pad).clamp(0, double.infinity),
              maxY: maxY + pad,
              gridData: const FlGridData(show: true),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: true, reservedSize: 44),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: xInterval,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(fmtLabel(v),
                          style: const TextStyle(fontSize: 10)),
                    ),
                  ),
                ),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: true),
              lineBarsData: [
                for (final s in series)
                  LineChartBarData(
                    spots: s.spots,
                    isCurved: true,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    color: s.color,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        children: [
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withOpacity(.4),
                borderRadius: BorderRadius.circular(16),
              ),
              child: _msgs.isEmpty
                  ? Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        '제품 추천/시세/가격 질문을 입력하세요.',
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: cs.outline),
                      ),
                    )
                  : ListView.separated(
                      controller: _scroll,
                      itemCount: _msgs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) {
                        final m = _msgs[i];
                        final isUser = m.role == 'user';
                        return Align(
                          alignment: isUser
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: isUser ? null : double.infinity,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: isUser ? cs.primaryContainer : cs.surface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: isUser
                                  ? CrossAxisAlignment.end
                                  : CrossAxisAlignment.start,
                              children: [
                                if (m.text.isNotEmpty) Text(m.text),
                                if (!isUser && m.trend != null)
                                  _buildTrend(m.trend!),
                                if (!isUser) _buildCards(m.cards),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: CircularProgressIndicator(),
            ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: '메시지를 입력하세요',
                      filled: true,
                      fillColor: cs.surfaceContainerHighest.withOpacity(.6),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 14),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                  label: const Text('보내기'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Series {
  final String name;
  final List<FlSpot> spots;
  final Color color;
  _Series(this.name, this.spots, this.color);
}
