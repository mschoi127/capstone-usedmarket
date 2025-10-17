// lib/pages/analysis_page.dart
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../data/api_client.dart';

/// ---------- 데이터 계층 ----------

class TrendResult {
  /// result[platform][yyyy-mm-dd]['new'|'used'] => { avg, count }
  final Map<String, Map<String, Map<String, dynamic>>> result;

  TrendResult(this.result);

  List<DateTime> get orderedDates {
    final set = <DateTime>{};
    for (final byDate in result.values) {
      for (final d in byDate.keys) {
        final dt = DateTime.tryParse(d);
        if (dt != null) set.add(DateTime(dt.year, dt.month, dt.day));
      }
    }
    final list = set.toList()..sort();
    return list;
  }

  List<FlSpot> toLineSpots(String platform, List<DateTime> dates,
      {required bool isNew}) {
    final byDate = result[platform] ?? const {};
    final spots = <FlSpot>[];
    for (var i = 0; i < dates.length; i++) {
      final key = _key(dates[i]);
      final avg = (byDate[key]?[isNew ? 'new' : 'used']?['avg']) as num?;
      if (avg != null) spots.add(FlSpot(i.toDouble(), avg.toDouble()));
    }
    return spots;
  }

  int avgPrice(String platform, List<DateTime> dates, {required bool isNew}) {
    final byDate = result[platform] ?? const {};
    int sum = 0, count = 0;
    for (final d in dates) {
      final key = _key(d);
      final avg = (byDate[key]?[isNew ? 'new' : 'used']?['avg']) as num?;
      if (avg != null) {
        sum += avg.round();
        count++;
      }
    }
    return count == 0 ? 0 : (sum / count).round();
  }

  static String _key(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class PriceRecommendation {
  final int? recommended;
  final List<num>? range;
  final int? sampleCount;
  PriceRecommendation({this.recommended, this.range, this.sampleCount});
}

class TrendRepository {
  final ApiClient _api;
  TrendRepository(this._api);

  /// ApiClient.baseUrl 가 “…/products” 라면 path는 '/price-trend', '/recommend-price'
  Future<TrendResult> fetchTrend(String keyword) async {
    final res = await _api
        .get<Map<String, dynamic>>('/price-trend', query: {'keyword': keyword});
    final raw = (res.data ?? {});
    if (raw.isEmpty) throw StateError('no-trend');

    final casted = raw.map(
      (p, v) => MapEntry(
        p,
        (v as Map).cast<String, dynamic>().map(
              (d, dv) => MapEntry(d, (dv as Map).cast<String, dynamic>()),
            ),
      ),
    );
    return TrendResult(casted);
  }

  Future<PriceRecommendation?> fetchRecommendation(String keyword,
      {required bool isNew}) async {
    final res = await _api.get<Map<String, dynamic>>('/recommend-price',
        query: {'keyword': keyword});
    final m = (res.data ?? {});
    final pick = isNew ? m['new'] : m['used'];
    if (pick == null) return null;
    final map = (pick as Map).cast<String, dynamic>();
    return PriceRecommendation(
      recommended: map['recommended'],
      range: (map['range'] as List?)?.cast<num>(),
      sampleCount: map['sampleCount'],
    );
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

  String _condition = '중고'; // '중고' | '새제품'
  final Set<String> _pickPlatforms = {..._platformsAll};

  bool _loading = false;
  bool _hasSearched = false;

  TrendResult? _trend;
  List<DateTime> _dates = [];
  PriceRecommendation? _rec;

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final kw = _kwCtrl.text.trim();
    if (kw.isEmpty) {
      _toast('검색어를 입력하세요.');
      return;
    }
    setState(() => _loading = true);

    try {
      final trend = await _repo.fetchTrend(kw);
      final dates = trend.orderedDates;
      if (dates.isEmpty) throw StateError('no-dates');

      final rec =
          await _repo.fetchRecommendation(kw, isNew: _condition == '새제품');

      setState(() {
        _trend = trend;
        _dates = dates;
        _rec = rec;
        _hasSearched = true;
      });
    } catch (_) {
      setState(() {
        _trend = null;
        _dates = [];
        _rec = null;
        _hasSearched = true;
      });
      _toast('데이터 없음.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isNew = _condition == '새제품';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('시세 분석', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
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
                      if (v == null) return;
                      setState(() => _condition = v);
                      if (_hasSearched) _search();
                    },
                    items: const [
                      DropdownMenuItem(value: '중고', child: Text('중고')),
                      DropdownMenuItem(value: '새제품', child: Text('새제품')),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Wrap(
                    spacing: 8,
                    children: _platformsAll.map((p) {
                      final on = _pickPlatforms.contains(p);
                      return FilterChip(
                        label: Text(p),
                        selected: on,
                        onSelected: (s) {
                          setState(() {
                            if (s) {
                              _pickPlatforms.add(p);
                            } else {
                              _pickPlatforms.remove(p);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ],
              ),
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
                ChartCard(
                  title: '날짜별 평균가 (선 그래프)',
                  child: (_trend == null || _dates.isEmpty)
                      ? const _Empty('데이터 없음')
                      : TrendLineChart(
                          dates: _dates,
                          series: _pickPlatforms
                              .map((p) => LineSeries(
                                    label: p,
                                    spots: _trend!
                                        .toLineSpots(p, _dates, isNew: isNew),
                                  ))
                              .where((s) => s.spots.isNotEmpty)
                              .toList(),
                          yLabelFormatter: (v) => _fmt.format(v),
                        ),
                ),
                const SizedBox(height: 16),
                ChartCard(
                  title: '플랫폼별 평균가 (바 차트)',
                  child: (_trend == null || _dates.isEmpty)
                      ? const _Empty('데이터 없음')
                      : PlatformBarChart(
                          bars: _pickPlatforms
                              .map((p) => BarDatum(
                                    platform: p,
                                    value: _trend!
                                        .avgPrice(p, _dates, isNew: isNew),
                                  ))
                              .toList(),
                          yLabelFormatter: (v) => _fmt.format(v),
                        ),
                ),
                const SizedBox(height: 16),
                if (_rec != null)
                  ChartCard(
                    title: '적정가 추천',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('추천 가격: ${_fmt.format(_rec!.recommended ?? 0)}원'),
                        if (_rec!.range != null)
                          Text(
                              '예상 범위: ${_fmt.format(_rec!.range![0])}원 ~ ${_fmt.format(_rec!.range![1])}원'),
                        if (_rec!.sampleCount != null)
                          Text('샘플 수: ${_rec!.sampleCount}개'),
                      ],
                    ),
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
    double? minY, maxY;
    if (series.isNotEmpty && series.first.spots.isNotEmpty) {
      final allY = series.expand((s) => s.spots.map((p) => p.y)).toList();
      final mi = allY.reduce(min), ma = allY.reduce(max);
      int round5(x) => (x / 50000).floor() * 50000;
      int round5up(x) => ((x / 50000).ceil()) * 50000;
      minY = round5(mi.toInt()).toDouble();
      maxY = round5up(ma.toInt()).toDouble();
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
            horizontalInterval: 50000,
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
                interval: 50000,
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
    return SizedBox(
      height: 260,
      child: BarChart(
        BarChartData(
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 50000,
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
                interval: 50000,
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
