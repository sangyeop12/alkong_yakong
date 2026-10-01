import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../../../core/constants/app_colors.dart';

/// 심박 이상 이벤트 상세 화면.
/// 알림 탭(또는 생체신호 화면)에서 "심박 이상" 이벤트를 누르면 진입.
/// 이벤트 발생 전후 심박 추이를 그래프로 보여준다.
///
/// **넘겨받은 측정값만 그린다.** 예전에는 "김복자 님 · 14:16 · 125bpm" 같은
/// 데모 샘플을 품고 있었는데, 그대로 열리면 가짜 이벤트가 진짜처럼 보인다.
/// 샘플이 없으면 기록이 없다고 말한다.
/// 위치: lib/features/dashboard/presentation/screens/biosignal_event_screen.dart
class BiosignalEventScreen extends StatelessWidget {
  final Color accent;

  /// 보호자가 볼 때 어르신 이름. 모르면 이름 없이 적는다.
  final String? patientName;

  /// 이벤트 앞뒤로 [sampleInterval]마다 잰 심박. 비어 있으면 빈 화면이다.
  final List<int> samples;

  /// 첫 샘플을 잰 시각.
  final DateTime? startedAt;

  /// 샘플 사이 간격.
  final Duration sampleInterval;

  /// 이벤트 종류. 서버가 알려준 이름을 넘긴다.
  final String eventType;

  const BiosignalEventScreen({
    super.key,
    this.accent = kGuardian,
    this.patientName,
    this.samples = const [],
    this.startedAt,
    this.sampleInterval = const Duration(minutes: 2),
    this.eventType = '빈맥 (빠른 맥박)',
  });

  static const _danger = AppColors.legacyRed;

  /// 이 값을 넘으면 빠른 맥박으로 본다 (아래 설명 문구와 같은 값).
  static const int _tachyBpm = 100;

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  DateTime? _timeAt(int index) => startedAt?.add(sampleInterval * index);

  int get _peakIndex {
    var best = 0;
    for (int i = 1; i < samples.length; i++) {
      if (samples[i] > samples[best]) best = i;
    }
    return best;
  }

  /// 기준을 넘은 샘플 수 × 간격. 넘은 적이 없으면 null.
  String? get _duration {
    final over = samples.where((bpm) => bpm > _tachyBpm).length;
    if (over == 0) return null;
    return '약 ${(sampleInterval * over).inMinutes}분';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          '심박 이상 이벤트',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(child: samples.isEmpty ? _empty() : _content()),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.monitor_heart_outlined,
              size: 44,
              color: Colors.grey[500],
            ),
            const SizedBox(height: 12),
            const Text(
              '표시할 심박 기록이 없어요',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: kText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '이벤트 앞뒤로 측정한 값이 서버에 남아 있지 않아요.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final peakIndex = _peakIndex;
    final peakAt = _timeAt(peakIndex);
    final startAt = _timeAt(0);
    final duration = _duration;
    final who = patientName == null ? '' : '$patientName님 · ';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      children: [
        // ── 요약 카드 ──
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: _danger.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _danger.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.favorite_rounded, size: 22, color: kPrimary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      eventType,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: kText,
                      ),
                    ),
                  ),
                ],
              ),
              if (who.isNotEmpty || peakAt != null) ...[
                const SizedBox(height: 6),
                Text(
                  peakAt == null
                      ? who.replaceAll(' · ', '')
                      : '$who${_hhmm(peakAt)} 발생',
                  style: TextStyle(fontSize: 13.5, color: Colors.grey[600]),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  _metric('최고 심박', '${samples[peakIndex]}', 'bpm', _danger),
                  const SizedBox(width: 12),
                  _metric('지속 시간', duration ?? '–', '', kText),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // ── 그래프 ──
        const Text(
          '심박 추이',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: kText,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${startAt == null ? '' : '${_hhmm(startAt)} ~ '}'
          '${sampleInterval.inMinutes}분 간격',
          style: TextStyle(fontSize: 12.5, color: Colors.grey[500]),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 18, 16, 10),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: SizedBox(height: 200, child: _chart()),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _legend(AppColors.legacyMint, '정상 범위 (60~100)'),
            const SizedBox(width: 16),
            _legend(_danger, '심박'),
          ],
        ),
        const SizedBox(height: 20),

        // ── 설명 ──
        _infoCard(
          icon: Icons.info_outline_rounded,
          title: '빈맥이란?',
          body:
              '안정 상태에서 심박수가 분당 100회를 넘는 경우를 빈맥이라고 해요. '
              '운동·카페인·긴장으로 일시적으로 생기기도 하지만, 자주 반복되면 '
              '확인이 필요해요.',
        ),
        const SizedBox(height: 10),
        _infoCard(
          icon: Icons.medical_services_outlined,
          title: '이럴 땐 상담을 권해요',
          body:
              '안정 시에도 빠른 맥박이 자주 나타나거나, 어지럼·가슴 두근거림·'
              '호흡곤란이 함께 있으면 의사·약사와 상담하는 것이 좋아요.',
          accent: accent,
        ),
      ],
    );
  }

  // ── fl_chart 라인 차트 ──
  Widget _chart() {
    final spots = [
      for (int i = 0; i < samples.length; i++)
        FlSpot(i.toDouble(), samples[i].toDouble()),
    ];
    final lowest = samples.reduce((a, b) => a < b ? a : b);
    final highest = samples.reduce((a, b) => a > b ? a : b);
    // 실제 값이 잘리지 않게 범위를 값에 맞춘다.
    final minY = (lowest < 60 ? (lowest ~/ 20) * 20 : 60).toDouble();
    final maxY = (highest > 140 ? ((highest ~/ 20) + 1) * 20 : 140).toDouble();
    final labelEvery = samples.length <= 5 ? 1 : (samples.length / 4).ceil();
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: samples.length == 1 ? 1 : (samples.length - 1).toDouble(),
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 20,
          getDrawingHorizontalLine: (v) =>
              FlLine(color: AppColors.legacyLine, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 20,
              reservedSize: 34,
              getTitlesWidget: (value, meta) => Text(
                '${value.toInt()}',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              // 잰 시각을 모르면 시각 눈금을 지어 붙이지 않는다.
              showTitles: startedAt != null,
              interval: labelEvery.toDouble(),
              reservedSize: 26,
              getTitlesWidget: (value, meta) {
                final at = _timeAt(value.toInt());
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    at == null ? '' : _hhmm(at),
                    style: TextStyle(fontSize: 10.5, color: Colors.grey[500]),
                  ),
                );
              },
            ),
          ),
        ),
        rangeAnnotations: RangeAnnotations(
          horizontalRangeAnnotations: [
            HorizontalRangeAnnotation(
              y1: 60,
              y2: 100,
              color: AppColors.legacyMint,
            ),
          ],
        ),
        lineTouchData: const LineTouchData(enabled: true),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: _danger,
            barWidth: 3,
            dotData: FlDotData(show: samples.length == 1),
            belowBarData: BarAreaData(
              show: true,
              color: _danger.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, String unit, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                if (unit.isNotEmpty) ...[
                  const SizedBox(width: 3),
                  Text(
                    unit,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _legend(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
      ],
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String title,
    required String body,
    Color? accent,
  }) {
    final c = accent ?? kTextSub;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 19, color: c),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w800,
                  color: kText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontSize: 13.5,
              color: Colors.grey[700],
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
