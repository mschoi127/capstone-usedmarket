// lib/pages/analysis_page.dart
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/api_client.dart';
import '../data/model_storage_resolver.dart';
import '../utils/model_formatters.dart';

/// ---------- 데이터 계층 ----------

class TrendPoint {
  final int? average;
  final int count;
  const TrendPoint({required this.average, required this.count});
}

class PlatformAverage {
  final int average;
  final int count;
  const PlatformAverage({required this.average, required this.count});
}

class TrendResult {
  final Map<String, TrendPoint> timeline;
  final Map<String, PlatformAverage> platformAverages;
  final String? condition;
  final int days;

  TrendResult({
    required this.timeline,
    required this.platformAverages,
    required this.condition,
    required this.days,
  });

  List<DateTime> get orderedDates {
    final dates = timeline.keys
        .map((e) => DateTime.tryParse(e))
        .whereType<DateTime>()
        .map((d) => DateTime(d.year, d.month, d.day))
        .toSet()
        .toList();
    dates.sort();
    return dates;
  }

  List<FlSpot> toLineSpots(List<DateTime> dates) {
    final spots = <FlSpot>[];
    for (var i = 0; i < dates.length; i++) {
      final key = _key(dates[i]);
      final point = timeline[key];
      if (point != null && point.average != null) {
        spots.add(FlSpot(i.toDouble(), point.average!.toDouble()));
      }
    }
    return spots;
  }

  int averageForPlatform(String platform) =>
      platformAverages[platform]?.average ?? 0;

  int countForPlatform(String platform) =>
      platformAverages[platform]?.count ?? 0;

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class MarketSummary {
  final int? averagePrice;
  final int? minPrice;
  final int? maxPrice;
  final double? priceChangePct;
  final int listingCount;
  final double? listingChangePct;

  const MarketSummary({
    required this.averagePrice,
    required this.minPrice,
    required this.maxPrice,
    required this.priceChangePct,
    required this.listingCount,
    required this.listingChangePct,
  });

  factory MarketSummary.fromMap(Map<String, dynamic> map) {
    int? asInt(dynamic value) => value is num ? value.round() : null;
    double? asDouble(dynamic value) =>
        value is num ? double.parse(value.toStringAsFixed(1)) : null;
    return MarketSummary(
      averagePrice: asInt(map['averagePrice']),
      minPrice: asInt(map['minPrice']),
      maxPrice: asInt(map['maxPrice']),
      priceChangePct: asDouble(map['priceChangePct']),
      listingCount: asInt(map['listingCount']) ?? 0,
      listingChangePct: asDouble(map['listingChangePct']),
    );
  }
}

class TrendRepository {
  final ApiClient _api;
  TrendRepository(this._api);

  Future<TrendResult> fetchTrend(
    String keyword, {
    String? model,
    String? storage,
    String? condition,
    List<String>? platforms,
  }) async {
    final query = <String, String>{'keyword': keyword};
    if (model != null && model.isNotEmpty) query['model'] = model;
    if (storage != null && storage.isNotEmpty) query['storage'] = storage;
    if (condition != null && condition.isNotEmpty) {
      query['condition'] = condition;
    }
    if (platforms != null && platforms.isNotEmpty) {
      query['platform'] = platforms.join(',');
    }

    final res =
        await _api.get<Map<String, dynamic>>('/price-trend', query: query);
    final data = res.data ?? {};
    if (data.isEmpty) throw StateError('no-trend');

    final timelineRaw =
        (data['timeline'] as Map?)?.cast<String, dynamic>() ?? const {};
    final timeline = <String, TrendPoint>{};
    timelineRaw.forEach((key, value) {
      final map = (value as Map).cast<String, dynamic>();
      final avg = map['average'];
      final cnt = map['count'];
      timeline[key] = TrendPoint(
        average: avg is num ? avg.round() : null,
        count: cnt is num ? cnt.toInt() : 0,
      );
    });

    final platformRaw =
        (data['platformAverages'] as Map?)?.cast<String, dynamic>() ??
            const {};
    final platformAverages = <String, PlatformAverage>{};
    platformRaw.forEach((key, value) {
      final map = (value as Map).cast<String, dynamic>();
      final avg = map['average'];
      final cnt = map['count'];
      if (avg is num && cnt is num) {
        platformAverages[key] =
            PlatformAverage(average: avg.round(), count: cnt.toInt());
      }
    });

    final conditionResp = data['condition'] as String?;
    final days = data['days'] is num ? (data['days'] as num).toInt() : 7;

    return TrendResult(
      timeline: timeline,
      platformAverages: platformAverages,
      condition: conditionResp,
      days: days,
    );
  }

  Future<MarketSummary?> fetchSummary(
    String keyword, {
    String? model,
    String? storage,
    String? condition,
    List<String>? platforms,
  }) async {
    final query = <String, String>{'keyword': keyword};
    if (model != null && model.isNotEmpty) query['model'] = model;
    if (storage != null && storage.isNotEmpty) query['storage'] = storage;
    if (condition != null && condition.isNotEmpty) {
      query['condition'] = condition;
    }
    if (platforms != null && platforms.isNotEmpty) {
      query['platform'] = platforms.join(',');
    }

    final res =
        await _api.get<Map<String, dynamic>>('/market-summary', query: query);
    final data = res.data;
    if (data is Map<String, dynamic> && data.isNotEmpty) {
      return MarketSummary.fromMap(data);
    }
    return null;
  }
}

/// ---------- UI 위젯 (Scaffold/AppBar 없음) ----------

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({super.key});
  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage> {
  final _repo = TrendRepository(ApiClient());
  final _kwCtrl = TextEditingController();
  final _fmt = NumberFormat.decimalPattern('ko_KR');

  static const _platformsAll = ['번개장터', '당근마켓', '중고나라'];
  static const _conditionOptions = ['S급', 'A급', 'B급', 'C급'];

  String _condition = 'A급';
  final Set<String> _pickPlatforms = {..._platformsAll};

  bool _loading = false;
  bool _hasSearched = false;
  String? _resolvedModel;
  String? _resolvedStorage;

  TrendResult? _trend;
  List<DateTime> _dates = [];
  MarketSummary? _summary;

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_loading) return;
    final kw = _kwCtrl.text.trim();
    if (kw.isEmpty) {
      _toast('검색어를 입력하세요.');
      return;
    }
    setState(() => _loading = true);

    final model = await ModelStorageResolver.matchModel(kw);
    final storage = await ModelStorageResolver.matchStorage(kw);
    final selectedPlatforms =
        _platformsAll.where(_pickPlatforms.contains).toList();

    try {
      final trend = await _repo.fetchTrend(
        kw,
        model: model,
        storage: storage,
        condition: _condition,
        platforms: selectedPlatforms,
      );
      final dates = trend.orderedDates;
      if (dates.isEmpty) throw StateError('no-dates');

      final summary = await _repo.fetchSummary(
        kw,
        model: model,
        storage: storage,
        condition: _condition,
        platforms: selectedPlatforms,
      );

      setState(() {
        _trend = trend;
        _dates = dates;
        _summary = summary;
        _hasSearched = true;
        _resolvedModel = model;
        _resolvedStorage = storage;
      });
    } catch (_) {
      setState(() {
        _trend = null;
        _dates = [];
        _summary = null;
        _hasSearched = true;
        _resolvedModel = model;
        _resolvedStorage = storage;
      });
      _toast('데이터 없음.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Widget _resolvedChip(String label) => Chip(
        label: Text(label),
        backgroundColor:
            Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(.6),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final modelLabel = formatModelLabel(_resolvedModel);
    final storageLabel = formatStorageLabel(_resolvedStorage);
    final trend = _trend;
    final hasTrend = trend != null && _dates.isNotEmpty;
    final summary = _summary;
    final selectedPlatforms =
        _platformsAll.where(_pickPlatforms.contains).toList();
    final lineSpots =
        hasTrend ? trend!.toLineSpots(_dates) : <FlSpot>[];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _kwCtrl,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '키워드를 입력하세요',
                        filled: true,
                        fillColor: cs.surfaceContainerHighest.withOpacity(.6),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _loading ? null : _search,
                    icon: const Icon(Icons.search),
                    label: const Text('검색'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  DropdownButton<String>(
                    value: _condition,
                    onChanged: (v) {
                      if (v == null || v == _condition) return;
                      setState(() => _condition = v);
                      if (_hasSearched) _search();
                    },
                    items: _conditionOptions
                        .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                        .toList(),
                  ),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    children: _platformsAll.map((p) {
                      final on = _pickPlatforms.contains(p);
                      return FilterChip(
                        label: Text(p),
                        selected: on,
                        onSelected: (selected) {
                          var changed = false;
                          setState(() {
                            if (selected) {
                              changed = _pickPlatforms.add(p);
                            } else if (_pickPlatforms.length > 1) {
                              changed = _pickPlatforms.remove(p);
                            }
                          });
                          if (changed && _hasSearched) _search();
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
              if (modelLabel != null || storageLabel != null) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (modelLabel != null)
                      _resolvedChip('모델 $modelLabel'),
                    if (storageLabel != null)
                      _resolvedChip('용량 $storageLabel'),
                  ],
                ),
              ],
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              children: [
                if (_hasSearched)
                  ChartCard(
                    title: '시세 정보',
                    child: summary == null
                        ? const _Empty('데이터 없음')
                        : MarketSummaryView(
                            summary: summary,
                            formatter: _fmt,
                          ),
                  ),
                if (_hasSearched) const SizedBox(height: 16),
                ChartCard(
                  title: '날짜별 평균 가격',
                  child: hasTrend && lineSpots.isNotEmpty
                      ? TrendLineChart(
                          dates: _dates,
                          series: [
                            LineSeries(
                              label: '전체',
                              spots: lineSpots,
                            ),
                          ],
                          yLabelFormatter: (v) => _fmt.format(v),
                        )
                      : const _Empty('데이터 없음'),
                ),
                const SizedBox(height: 16),
                ChartCard(
                  title: '플랫폼별 평균 가격',
                  child: hasTrend
                      ? PlatformBarChart(
                          bars: selectedPlatforms
                              .map((p) => BarDatum(
                                    platform: p,
                                    value: trend!.averageForPlatform(p),
                                  ))
                              .toList(),
                          yLabelFormatter: (v) => _fmt.format(v),
                        )
                      : const _Empty('데이터 없음'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// ---------- 작은 UI 조각 ----------

class ChartCard extends StatelessWidget {
  final String title;
  final Widget child;
  const ChartCard({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(.35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 240, child: Center(child: Text(text)));
}

class MarketSummaryView extends StatelessWidget {
  final MarketSummary summary;
  final NumberFormat formatter;
  const MarketSummaryView({
    super.key,
    required this.summary,
    required this.formatter,
  });

  String _formatPrice(int? value) =>
      value == null ? '-' : '${formatter.format(value)}원';

  String _formatRange(int? min, int? max) {
    if (min == null || max == null) return '-';
    return '${formatter.format(min)}원 ~ ${formatter.format(max)}원';
  }

  String _formatChange(double? value) {
    if (value == null) return '-';
    final adjusted = value.abs() < 0.05 ? 0 : value;
    if (adjusted == 0) return '0.0%';
    final sign = adjusted > 0 ? '+' : '';
    return '$sign${adjusted.toStringAsFixed(1)}%';
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row('평균 가격', _formatPrice(summary.averagePrice)),
        _row('가격 범위', _formatRange(summary.minPrice, summary.maxPrice)),
        _row('가격 변화', _formatChange(summary.priceChangePct)),
      ],
    );
  }
}

/// ---------- 차트 전용 타입/위젯 ----------

class LineSeries {
  final String label;
  final List<FlSpot> spots;
  LineSeries({required this.label, required this.spots});
}

class BarDatum {
  final String platform;
  final int value;
  BarDatum({required this.platform, required this.value});
}

/// 플랫폼별 고정 색상 매핑
const platformColors = {
  '중고나라': Colors.green,
  '당근마켓': Colors.orange,
  '번개장터': Colors.red,
};

class TrendLineChart extends StatelessWidget {
  final List<DateTime> dates;
  final List<LineSeries> series;
  final String Function(num) yLabelFormatter;

  const TrendLineChart({
    super.key,
    required this.dates,
    required this.series,
    required this.yLabelFormatter,
  });

  @override
  Widget build(BuildContext context) {
    final double interval = max(1.0, (dates.length / 6).floorToDouble());

    // 보기 좋은 y축 범위 (5만 단위 라운딩)
    const double priceInterval = 100000;
    const double minY = 0;
    double maxY = priceInterval;
    final hasData = series.any((s) => s.spots.isNotEmpty);
    if (hasData) {
      final allY = series.expand((s) => s.spots.map((p) => p.y)).toList();
      if (allY.isNotEmpty) {
        final ma = allY.reduce(max);
        final steps = max(1, (ma / priceInterval).ceil());
        maxY = steps * priceInterval;
      }
    }

    final fallback = Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: 280,
      child: LineChart(
        LineChartData(
          minY: minY,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: true,
            horizontalInterval: priceInterval,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.grey.withOpacity(.2),
                strokeWidth: 1,
                dashArray: [4, 4]),
            getDrawingVerticalLine: (_) =>
                FlLine(color: Colors.grey.withOpacity(.12), strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 56,
                interval: priceInterval,
                getTitlesWidget: (v, _) => Text(
                  yLabelFormatter(v),
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: interval,
                reservedSize: 48,
                getTitlesWidget: (v, _) {
                  final i = v.round();
                  if (i < 0 || i >= dates.length) {
                    return const SizedBox.shrink();
                  }
                  final d = dates[i];
                  return Transform.rotate(
                    angle: -0.8,
                    child: Text(
                      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
                      style:
                          const TextStyle(fontSize: 10, color: Colors.black54),
                    ),
                  );
                },
              ),
            ),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          lineBarsData: series.map(
            (s) {
              final color = platformColors[s.label] ?? fallback;
              return LineChartBarData(
                spots: s.spots,
                isCurved: true,
                curveSmoothness: 0.25,
                barWidth: 3,
                color: color,
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (p, _, __, ___) => FlDotCirclePainter(
                    radius: 2.8,
                    color: Colors.white,
                    strokeWidth: 2,
                    strokeColor: color,
                  ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    colors: [color.withOpacity(.18), Colors.transparent],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              );
            },
          ).toList(),
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => Colors.black.withOpacity(.75),
              getTooltipItems: (items) => items.map((e) {
                final i = e.x.toInt();
                final label = (i >= 0 && i < dates.length)
                    ? '${dates[i].month}-${dates[i].day}'
                    : '';
                final price = yLabelFormatter(e.y);
                return LineTooltipItem(
                  '${series[e.barIndex].label}\n$label • ₩$price',
                  const TextStyle(fontSize: 12, color: Colors.white),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}

class PlatformBarChart extends StatelessWidget {
  final List<BarDatum> bars;
  final String Function(num) yLabelFormatter;

  const PlatformBarChart({
    super.key,
    required this.bars,
    required this.yLabelFormatter,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Theme.of(context).colorScheme.primary;
    const double priceInterval = 100000;
    double maxY = priceInterval;
    if (bars.isNotEmpty) {
      final values = bars.map((b) => b.value.toDouble()).toList();
      if (values.isNotEmpty) {
        final ma = values.reduce(max);
        final steps = max(1, (ma / priceInterval).ceil());
        maxY = steps * priceInterval;
      }
    }
    return SizedBox(
      height: 260,
      child: BarChart(
        BarChartData(
          minY: 0,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: priceInterval,
            getDrawingHorizontalLine: (_) => FlLine(
                color: Colors.grey.withOpacity(.2),
                strokeWidth: 1,
                dashArray: [4, 4]),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 56,
                interval: priceInterval,
                getTitlesWidget: (v, _) => Text(
                  yLabelFormatter(v),
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= bars.length) return const SizedBox.shrink();
                  return Text(bars[i].platform,
                      style: const TextStyle(fontSize: 12));
                },
              ),
            ),
            rightTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            topTitles:
                const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          ),
          barGroups: List.generate(
            bars.length,
            (i) {
              final color = platformColors[bars[i].platform] ?? fallback;
              return BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: bars[i].value.toDouble(),
                    width: 18,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [color, color.withOpacity(.55)],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
