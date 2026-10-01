import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:polar/polar.dart';

final polarServiceProvider = Provider<PolarService>((ref) => PolarService());

class PolarService {
  final Polar polar = Polar();

  Future<void> requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> connectToSensor(String deviceId) async {
    await requestPermissions();

    final id = deviceId.trim();
    if (id.isEmpty) {
      throw Exception('Polar 기기 ID를 입력해주세요.');
    }

    await polar.connectToDevice(id);

    await polar.sdkFeatureReady
        .firstWhere(
          (event) =>
              event.identifier == id && event.feature == PolarSdkFeature.hr,
        )
        .timeout(const Duration(seconds: 20));
  }

  Future<void> disconnectSensor(String deviceId) async {
    final id = deviceId.trim();
    if (id.isNotEmpty) {
      await polar.disconnectFromDevice(id);
    }
  }

  Stream<int> heartRateStream(String deviceId) {
    return polar.startHrStreaming(deviceId.trim()).expand((data) {
      return data.samples
          .map(
            (sample) => sample.correctedHr > 0 ? sample.correctedHr : sample.hr,
          )
          .where((bpm) => bpm > 0);
    });
  }

  Stream<int> ppiStream(String deviceId) {
    return polar.startPpiStreaming(deviceId.trim()).expand((data) {
      return data.samples.map((sample) => sample.ppi);
    });
  }

  Stream<PolarAccData> accStream(String deviceId) {
    return polar.startAccStreaming(deviceId.trim());
  }
}
