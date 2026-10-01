import 'package:flutter/material.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/session/mvp_session.dart';

class BiosignalScreen extends StatefulWidget {
  const BiosignalScreen({super.key});

  @override
  State<BiosignalScreen> createState() => _BiosignalScreenState();
}

class _BiosignalScreenState extends State<BiosignalScreen> {
  final _apiClient = ApiClient();
  late final TextEditingController _userIdController;
  late final TextEditingController _bpmController;

  bool _isSending = false;
  bool _isLoadingEvents = false;
  String? _errorMessage;
  Map<String, dynamic>? _sendResult;
  List<dynamic> _events = const [];

  @override
  void initState() {
    super.initState();
    _userIdController = TextEditingController(text: MvpSession.userId);
    _bpmController = TextEditingController(text: '72');
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _bpmController.dispose();
    super.dispose();
  }

  String? _readUserId() {
    var userId = _userIdController.text.trim();
    if (userId.isEmpty && MvpSession.userId.isNotEmpty) {
      userId = MvpSession.userId;
      _userIdController.text = userId;
    }
    if (userId.isEmpty) {
      setState(() => _errorMessage = '사용자 ID를 입력해주세요.');
      return null;
    }
    MvpSession.userId = userId;
    return userId;
  }

  Future<void> _sendHeartRate() async {
    final userId = _readUserId();
    if (userId == null) return;
    final bpm = int.tryParse(_bpmController.text.trim());
    if (bpm == null || bpm <= 0) {
      setState(() => _errorMessage = '올바른 BPM을 입력해주세요.');
      return;
    }

    setState(() {
      _isSending = true;
      _errorMessage = null;
      _sendResult = null;
    });
    try {
      final response = await _apiClient.post(
        '/api/v1/biosignal/heart-rate',
        body: {
          'user_id': userId,
          'bpm': bpm,
          'device_id': 'FLUTTER-MOCK',
          'source': 'MANUAL_MOCK',
        },
      );
      if (!mounted) return;
      setState(() {
        _sendResult = Map<String, dynamic>.from(response as Map);
      });
      await _loadEvents(showLoading: false);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _apiError(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '응답 처리 중 오류가 발생했습니다: $error');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _loadEvents({bool showLoading = true}) async {
    final userId = _readUserId();
    if (userId == null) return;
    if (showLoading) {
      setState(() {
        _isLoadingEvents = true;
        _errorMessage = null;
      });
    }
    try {
      final response = await _apiClient.get(
        '/api/v1/users/${Uri.encodeComponent(userId)}/biosignal/events',
      );
      if (!mounted) return;
      setState(() {
        _events = response is List ? response : const [];
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = _apiError(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = '이벤트 조회 중 오류가 발생했습니다: $error');
    } finally {
      if (mounted && showLoading) {
        setState(() => _isLoadingEvents = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseline = _asMap(_sendResult?['baseline']);
    final abnormalEvent = _asMap(_sendResult?['abnormal_event']);

    return Scaffold(
      backgroundColor: kBackground,
      appBar: AppBar(title: const Text('생체 신호'), backgroundColor: kPrimary),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _InfoCard(),
              const SizedBox(height: 16),
              TextField(
                controller: _userIdController,
                decoration: const InputDecoration(
                  labelText: '사용자 ID',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _bpmController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '심박수 BPM',
                  suffixText: 'BPM',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _isSending ? null : _sendHeartRate,
                      icon: _isSending
                          ? const _ButtonProgress()
                          : const Icon(Icons.favorite_outline),
                      label: Text(_isSending ? '전송 중...' : '심박 전송'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isLoadingEvents ? null : _loadEvents,
                      icon: _isLoadingEvents
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      label: const Text('이벤트 조회'),
                    ),
                  ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                _DataCard(
                  title: '요청 실패',
                  lines: [_errorMessage!],
                  color: Colors.red,
                ),
              ],
              if (_sendResult != null) ...[
                const SizedBox(height: 16),
                _DataCard(
                  title: '심박 저장 완료',
                  color: kPrimary,
                  lines: [
                    '로그 ID: ${_text(_sendResult?['heart_rate_log_id'])}',
                    '측정값: ${_text(_sendResult?['bpm'])} BPM',
                    '측정 시각: ${_text(_sendResult?['measured_at'])}',
                    '기준 심박: ${_text(baseline?['resting_bpm'])} BPM',
                    abnormalEvent == null
                        ? '이상 이벤트: 없음'
                        : '이상 이벤트: ${_text(abnormalEvent['event_type'])} / ${_text(abnormalEvent['severity'])}',
                  ],
                ),
              ],
              const SizedBox(height: 22),
              Text(
                '이상 이벤트 ${_events.length}건',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: kText,
                ),
              ),
              const SizedBox(height: 10),
              if (_events.isEmpty)
                const _DataCard(
                  title: '이벤트',
                  lines: ['데이터 없음'],
                  color: kPrimary,
                )
              else
                ..._events.map((event) {
                  final item = _asMap(event) ?? const <String, dynamic>{};
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _DataCard(
                      title: _text(item['event_type']),
                      color: Colors.orange,
                      lines: [
                        '${_text(item['bpm'])} BPM · ${_text(item['severity'])}',
                        '발생 시각: ${_text(item['occurred_at'])}',
                        '상태: ${_text(item['status'])}',
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard();

  @override
  Widget build(BuildContext context) {
    return const _DataCard(
      title: '수동 심박 테스트',
      lines: ['Polar BLE 대신 BPM을 직접 입력해 저장 및 이상 이벤트 생성을 검증합니다.'],
      color: AppColors.legacyViolet,
    );
  }
}

class _DataCard extends StatelessWidget {
  final String title;
  final List<String> lines;
  final Color color;

  const _DataCard({
    required this.title,
    required this.lines,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
          const SizedBox(height: 7),
          ...lines.map(
            (line) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: const TextStyle(color: kText, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ButtonProgress extends StatelessWidget {
  const _ButtonProgress();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 18,
      height: 18,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );
  }
}

Map<String, dynamic>? _asMap(dynamic value) {
  return value is Map ? Map<String, dynamic>.from(value) : null;
}

String _text(dynamic value, {String fallback = '데이터 없음'}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

String _apiError(ApiException error) {
  return error.statusCode == null
      ? error.message
      : '${error.message} (HTTP ${error.statusCode})';
}
