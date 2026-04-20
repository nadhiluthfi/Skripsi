import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

// ─── Design tokens ─────────────────────────────────────────────────────────
class T {
  static const green = Color(0xFF00D09E);
  static const greenDim = Color(0x1A00D09E);
  static const greenBrd = Color(0x3300D09E);

  static const bg = Color(0xFF07111F);
  static const card = Color(0xFF0C1728);
  static const card2 = Color(0xFF101F34);
  static const brd = Color(0xFF16304E);

  static const txt = Color(0xFFE4F0F6);
  static const txt2 = Color(0xFF7A9BB5);

  static const red = Color(0xFFFF5C7A);
  static const redDim = Color(0x1AFF5C7A);
  static const redBrd = Color(0x4DFF5C7A);

  static const amber = Color(0xFFFFB74D);
  static const amberDim = Color(0x1AFFB74D);
  static const amberBrd = Color(0x33FFB74D);

  static const blue = Color(0xFF4FC3F7);
  static const blueDim = Color(0x1A4FC3F7);
  static const blueBrd = Color(0x334FC3F7);

  static const purple = Color(0xFFCE93D8);
  static const purpleDim = Color(0x1ACE93D8);
  static const purpleBrd = Color(0x33CE93D8);
}

// ─── Beat colors ───────────────────────────────────────────────────────────
const _beatColors = {
  'N': T.green,
  'S': T.amber,
  'V': T.red,
  'F': T.blue,
  'Q': T.purple,
};

const _beatDimColors = {
  'N': T.greenDim,
  'S': T.amberDim,
  'V': T.redDim,
  'F': T.blueDim,
  'Q': T.purpleDim,
};

const _beatBrdColors = {
  'N': T.greenBrd,
  'S': T.amberBrd,
  'V': T.redBrd,
  'F': T.blueBrd,
  'Q': T.purpleBrd,
};

// ─── BLE UUID helpers ──────────────────────────────────────────────────────
const _heartRateServiceUuid = '180d';
const _heartRateMeasurementUuid = '2a37';

// ─── App ───────────────────────────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live ECG',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: T.bg,
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: T.green,
          secondary: T.green,
          surface: T.card,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: T.txt, fontSize: 13),
        ),
      ),
      home: const EcgDashboardPage(),
    );
  }
}

// ─── Dashboard ─────────────────────────────────────────────────────────────
class EcgDashboardPage extends StatefulWidget {
  const EcgDashboardPage({super.key});

  @override
  State<EcgDashboardPage> createState() => _EcgDashboardPageState();
}

class _EcgDashboardPageState extends State<EcgDashboardPage>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _perfChannel = MethodChannel('ecg_app/perf');

  Interpreter? _interpreter;
  Timer? _simulationTimer;
  Timer? _inferenceTimer;
  Timer? _sessionTimer;
  Timer? _cpuTimer;
  final Random _rng = Random();

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  StreamSubscription<BluetoothAdapterState>? _adapterStateSub;
  StreamSubscription<List<ScanResult>>? _scanResultsSub;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSub;
  StreamSubscription<List<int>>? _hrValueSub;

  BluetoothDevice? _polarDevice;
  BluetoothCharacteristic? _hrCharacteristic;
  BluetoothAdapterState _adapterState = BluetoothAdapterState.unknown;

  bool _isSimulationMode = false;
  bool _isRunning = false;
  bool _isPolarConnected = false;
  bool _isPolarConnecting = false;
  bool _isScanningSheetVisible = false;
  bool _isBluetoothOffSheetVisible = false;

  final List<String> _classNames = const [
    'Normal',
    'SVEB',
    'VEB',
    'Fusion',
    'Unknown',
  ];

  final Map<String, String> _classShort = const {
    'Normal': 'N',
    'SVEB': 'S',
    'VEB': 'V',
    'Fusion': 'F',
    'Unknown': 'Q',
  };

  final Map<String, String> _shortToLong = const {
    'N': 'Normal',
    'S': 'SVEB',
    'V': 'VEB',
    'F': 'Fusion',
    'Q': 'Unknown',
  };

  final List<String> _simulationDemoClasses = const ['N', 'S', 'V', 'F', 'Q'];

  String? _currentSimulationDemoShort;
  String? _currentSimulationDemoLong;

  final List<double> _signalBuffer = List.generate(260, (_) => 0.0);

  double _lastFilteredLive = 0.0;
  double _prevLive1 = 0.0;
  double _prevLive2 = 0.0;
  int _liveSampleIndex = 0;
  int _lastPeakIndex = -1000;
  final List<int> _recentPeakIndices = [];

  String _status = 'Memuat model...';

  String _lastPredictionClass = '—';
  String _lastPredictionShort = '—';
  String _explanationText = 'Belum ada hasil klasifikasi.';
  double _predictionConfidence = 0.0;

  String _duration = '00:00';
  String _sensorName = '—';

  int _tick = 0;
  int _sessionSeconds = 0;
  int _heartRate = 0;
  int _rrIntervalMs = 0;
  int _hrPacketCount = 0;

  final Map<String, int> _classCounts = {
    'Normal': 0,
    'SVEB': 0,
    'VEB': 0,
    'Fusion': 0,
    'Unknown': 0,
  };

  final List<double> _latencyHistoryMs = [];
  double _latencyAvg = 0;
  double _latencyMin = 0;
  double _latencyMax = 0;

  double _ramCurrentMb = 0;
  double _ramMinMb = 0;
  double _ramMaxMb = 0;

  double _cpuCurrent = 0;
  double _cpuMin = 0;
  double _cpuMax = 0;

  double _throughput = 0;
  int _totalInferenceRuns = 0;
  int _detectedRPeaks = 0;
  int _beatsProcessed = 0;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);

    _pulseAnim = Tween<double>(begin: 1.0, end: 0.25).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _loadModel();
    _bindBluetoothState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showSourcePicker();
    });
  }

  Future<void> _loadModel() async {
    try {
      final interpreter = await Interpreter.fromAsset(
        'assets/model/morphology_transformer_final.tflite',
      );
      if (!mounted) return;
      setState(() {
        _interpreter = interpreter;
        _status = 'Model berhasil dimuat';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Gagal memuat model: $e');
    }
  }

  void _bindBluetoothState() {
    _adapterStateSub?.cancel();
    _adapterStateSub = FlutterBluePlus.adapterState.listen((state) async {
      _adapterState = state;

      if (!mounted) return;

      if (state == BluetoothAdapterState.on) {
        if (_isBluetoothOffSheetVisible &&
            Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
        _isBluetoothOffSheetVisible = false;

        if (!_isPolarConnected && !_isPolarConnecting && !_isSimulationMode) {
          setState(() {
            _status = 'Bluetooth aktif';
          });
        }
        return;
      }

      if (state == BluetoothAdapterState.off ||
          state == BluetoothAdapterState.unavailable ||
          state == BluetoothAdapterState.unauthorized) {
        _dismissScanningBottomSheet();

        if (_isPolarConnected || _isPolarConnecting) {
          await _disconnectPolarSensor(resetMode: false);
        }

        if (!mounted) return;
        setState(() {
          _isPolarConnected = false;
          _isPolarConnecting = false;
          _heartRate = 0;
          _rrIntervalMs = 0;
          _status = state == BluetoothAdapterState.unauthorized
              ? 'Izin Bluetooth belum diberikan'
              : 'Bluetooth sedang mati';
        });

        if (!_isSimulationMode) {
          await _showBluetoothOffBottomSheet();
        }
      }
    });
  }

  Future<void> _requestBlePermissions() async {
    if (!Platform.isAndroid) return;

    final requests = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];

    await requests.request();
  }

  Future<void> _showSourcePicker() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: T.brd),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pilih sumber data',
                  style: TextStyle(
                    color: T.txt,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Mode simulasi menjalankan inferensi ECG seperti sebelumnya. Mode Bluetooth memakai Polar H10 untuk monitoring heart rate actual secara real-time.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _disconnectPolarSensor(resetMode: false);
                          if (!mounted) return;
                          setState(() {
                            _isSimulationMode = true;
                            _sensorName = '—';
                            _status = 'Mode simulasi aktif';
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: T.txt,
                          side: const BorderSide(color: T.brd),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.auto_graph_rounded, size: 18),
                        label: const Text('Mode Simulasi'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _connectPolarSensorFlow();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(
                          Icons.bluetooth_searching_rounded,
                          size: 18,
                        ),
                        label: const Text('Bluetooth HR'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _refreshSensorFlow() async {
    _stopSession(showSummary: false);
    await _disconnectPolarSensor(resetMode: false);
    await _showSourcePicker();
  }

  Future<void> _connectPolarSensorFlow() async {
    await _requestBlePermissions();

    final adapterState = await FlutterBluePlus.adapterState
        .where((state) => state != BluetoothAdapterState.unknown)
        .first;

    _adapterState = adapterState;

    if (adapterState != BluetoothAdapterState.on) {
      if (!mounted) return;
      setState(() {
        _isPolarConnecting = false;
        _isPolarConnected = false;
        _status = 'Bluetooth sedang mati';
      });
      await _showBluetoothOffBottomSheet();
      return;
    }

    if (!mounted) return;
    setState(() {
      _isSimulationMode = false;
      _isPolarConnecting = true;
      _isPolarConnected = false;
      _status = 'Mencari Polar H10...';
    });

    _showScanningBottomSheet();

    try {
      await _disconnectPolarSensor(resetMode: false);
      await FlutterBluePlus.stopScan();

      final completer = Completer<ScanResult>();

      _scanResultsSub?.cancel();
      _scanResultsSub = FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final advName = result.advertisementData.advName;
          final platformName = result.device.platformName;
          final candidateName = advName.isNotEmpty ? advName : platformName;

          final lower = candidateName.toLowerCase();
          if (lower.contains('polar') && lower.contains('h10')) {
            if (!completer.isCompleted) {
              completer.complete(result);
            }
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      final found = await completer.future.timeout(const Duration(seconds: 12));
      await FlutterBluePlus.stopScan();

      final device = found.device;
      final advName = found.advertisementData.advName;
      final deviceName = advName.isNotEmpty
          ? advName
          : (device.platformName.isNotEmpty
                ? device.platformName
                : 'Polar H10');

      _deviceConnectionSub?.cancel();
      _deviceConnectionSub = device.connectionState.listen((state) {
        if (!mounted) return;
        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            _isPolarConnected = false;
            _isPolarConnecting = false;
            _heartRate = 0;
            _rrIntervalMs = 0;
            _status = 'Sensor Bluetooth terputus';
          });
        }
      });

      try {
        await device.connect(timeout: const Duration(seconds: 15));
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final alreadyConnected = msg.contains('already connected') ||
            msg.contains('connection already exists');
        if (!alreadyConnected) rethrow;
      }

      final services = await device.discoverServices();

      BluetoothCharacteristic? hrChar;
      for (final service in services) {
        final serviceId = service.uuid.toString().toLowerCase();
        if (serviceId.contains(_heartRateServiceUuid)) {
          for (final characteristic in service.characteristics) {
            final charId = characteristic.uuid.toString().toLowerCase();
            if (charId.contains(_heartRateMeasurementUuid)) {
              hrChar = characteristic;
              break;
            }
          }
        }
        if (hrChar != null) break;
      }

      if (hrChar == null) {
        throw Exception('Characteristic Heart Rate Measurement tidak ditemukan');
      }

      _hrValueSub?.cancel();
      _hrCharacteristic = hrChar;
      _hrValueSub = hrChar.lastValueStream.listen(
        _onHeartRatePacket,
        onError: (error) {
          if (!mounted) return;
          setState(() {
            _status = 'Gagal menerima heart rate: $error';
          });
        },
      );

      await hrChar.setNotifyValue(true);

      if (!mounted) return;
      setState(() {
        _polarDevice = device;
        _sensorName = deviceName;
        _isPolarConnecting = false;
        _isPolarConnected = true;
        _status = 'Sensor terhubung: $deviceName';
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isPolarConnecting = false;
        _isPolarConnected = false;
        _status = 'Polar H10 tidak ditemukan';
      });
      await _showSensorNotFoundBottomSheet();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPolarConnecting = false;
        _isPolarConnected = false;
        _status = 'Gagal menghubungkan sensor: $e';
      });
    } finally {
      await FlutterBluePlus.stopScan();
      await _scanResultsSub?.cancel();
      _scanResultsSub = null;
      _dismissScanningBottomSheet();
    }
  }

  void _onHeartRatePacket(List<int> value) {
    if (value.length < 2) return;

    final flags = value[0];
    final is16BitHr = (flags & 0x01) != 0;
    final hasEnergyExpended = (flags & 0x08) != 0;
    final hasRrInterval = (flags & 0x10) != 0;

    int index = 1;
    int hr;

    if (is16BitHr) {
      if (value.length < 3) return;
      hr = value[1] | (value[2] << 8);
      index = 3;
    } else {
      hr = value[1];
      index = 2;
    }

    if (hasEnergyExpended) {
      index += 2;
    }

    int rrMs = 0;
    if (hasRrInterval && value.length >= index + 2) {
      final rrRaw = value[index] | (value[index + 1] << 8);
      rrMs = (rrRaw * 1000 / 1024).round();
    }

    if (_isRunning && !_isSimulationMode) {
      _signalBuffer.removeAt(0);
      _signalBuffer.add(hr.toDouble());
      _hrPacketCount++;
      _beatsProcessed = _hrPacketCount;
      _detectedRPeaks = _hrPacketCount;
    }

    final liveClass = _classifyLiveBeat(hr: hr, rrMs: rrMs);

    if (!mounted) return;
    setState(() {
      _heartRate = hr;
      if (rrMs > 0) {
        _rrIntervalMs = rrMs;
      }

      if (_isRunning && !_isSimulationMode) {
        _lastPredictionShort = liveClass['short']!;
        _lastPredictionClass = liveClass['full']!;
        _predictionConfidence = 0.0;
        _explanationText = _buildExplanationText(
          predictedShort: _lastPredictionShort,
          isBluetoothMode: true,
        );
        _status = 'Bluetooth aktif · Klasifikasi ${_lastPredictionShort}';
      } else {
        _status = 'Sensor terhubung: $_sensorName';
      }
    });
  }

  Future<void> _disconnectPolarSensor({bool resetMode = true}) async {
    try {
      await _hrCharacteristic?.setNotifyValue(false);
    } catch (_) {}

    await _hrValueSub?.cancel();
    _hrValueSub = null;

    await _deviceConnectionSub?.cancel();
    _deviceConnectionSub = null;

    final device = _polarDevice;
    _polarDevice = null;
    _hrCharacteristic = null;

    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _isPolarConnected = false;
      _isPolarConnecting = false;
      _heartRate = 0;
      _rrIntervalMs = 0;
      _sensorName = '—';
      if (resetMode) {
        _isSimulationMode = false;
      }
      if (!_isSimulationMode) {
        _status = 'Sensor Bluetooth terputus';
      }
    });
  }

  void _showScanningBottomSheet() {
    if (!mounted || _isScanningSheetVisible) return;

    _isScanningSheetVisible = true;
    showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: T.brd),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Mencari sensor...',
                      style: TextStyle(
                        color: T.txt,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 12),
                Text(
                  'Aplikasi sedang mencari Polar H10 untuk monitoring heart rate real-time.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _isScanningSheetVisible = false;
    });
  }

  void _dismissScanningBottomSheet() {
    if (!_isScanningSheetVisible || !mounted) return;
    Navigator.of(context, rootNavigator: true).maybePop();
    _isScanningSheetVisible = false;
  }

  Future<void> _showBluetoothOffBottomSheet() async {
    if (!mounted || _isBluetoothOffSheetVisible) return;

    _isBluetoothOffSheetVisible = true;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: T.brd),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: T.redDim,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: T.redBrd),
                      ),
                      child: const Icon(
                        Icons.bluetooth_disabled_rounded,
                        color: T.red,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Bluetooth sedang mati',
                        style: TextStyle(
                          color: T.txt,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Nyalakan Bluetooth terlebih dahulu untuk monitoring heart rate actual, atau lanjutkan dengan mode simulasi.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: T.txt,
                          side: const BorderSide(color: T.brd),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Tutup'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          if (!mounted) return;
                          setState(() {
                            _isSimulationMode = true;
                            _status = 'Mode simulasi aktif';
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Mode Simulasi'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ).whenComplete(() {
      _isBluetoothOffSheetVisible = false;
    });
  }

  Future<void> _showSensorNotFoundBottomSheet() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: T.brd),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: T.redDim,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: T.redBrd),
                      ),
                      child: const Icon(
                        Icons.bluetooth_searching_rounded,
                        color: T.red,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Sensor tidak ditemukan',
                        style: TextStyle(
                          color: T.txt,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Pastikan Polar H10 aktif dan dapat dipindai, lalu coba lagi atau jalankan mode simulasi.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          _connectPolarSensorFlow();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: T.txt,
                          side: const BorderSide(color: T.brd),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Coba Lagi'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          if (!mounted) return;
                          setState(() {
                            _isSimulationMode = true;
                            _status = 'Mode simulasi aktif';
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Mode Simulasi'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _pickRandomSimulationClass() {
    final candidates = List<String>.from(_simulationDemoClasses);

    if (_currentSimulationDemoShort != null && candidates.length > 1) {
      candidates.remove(_currentSimulationDemoShort);
    }

    return candidates[_rng.nextInt(candidates.length)];
  }

  void _prepareSimulationSessionClass() {
    if (!_isSimulationMode) return;

    final nextShort = _pickRandomSimulationClass();
    _currentSimulationDemoShort = nextShort;
    _currentSimulationDemoLong = _shortToLong[nextShort] ?? 'Unknown';
  }

  double _buildSimulationSample(int phase) {
    final demoClass = _currentSimulationDemoShort ?? 'N';

    switch (demoClass) {
      case 'S':
        if (phase == 0) return 0.96;
        if (phase == 1) return -0.58;
        if (phase < 6) return 0.16;
        if (phase < 15) return 0.03 * sin(_tick / 3.0);
        return 0.0;
      case 'V':
        if (phase == 0) return 1.25;
        if (phase == 1) return -0.92;
        if (phase < 8) return 0.18 + 0.04 * sin(_tick / 4.5);
        if (phase < 18) return -0.06 + 0.03 * sin(_tick / 3.4);
        return 0.0;
      case 'F':
        if (phase == 0) return 1.02;
        if (phase == 1) return -0.64;
        if (phase < 7) return 0.10;
        if (phase < 20) return 0.08 + 0.06 * sin(_tick / 4.0);
        return 0.0;
      case 'Q':
        if (phase == 0) return 0.72 + (_rng.nextDouble() * 0.12);
        if (phase == 1) return -0.42;
        return (_rng.nextDouble() - 0.5) * 0.06;
      case 'N':
      default:
        if (phase == 0) return 1.10;
        if (phase == 1) return -0.82;
        if (phase < 6) return 0.10;
        if (phase < 13) return 0.015 * sin(_tick / 3.0);
        if (phase < 21) return 0.13 + 0.05 * sin(_tick / 4.0);
        return 0.0;
    }
  }

  int _heartRateForSimulationClass() {
    switch (_currentSimulationDemoShort ?? 'N') {
      case 'S':
        return 118;
      case 'V':
        return 124;
      case 'F':
        return 112;
      case 'Q':
        return 96;
      case 'N':
      default:
        return 110;
    }
  }

  void _startSession() {
    if (_interpreter == null) {
      setState(() => _status = 'Model belum siap');
      return;
    }

    if (!_isSimulationMode && !_isPolarConnected) {
      setState(() => _status = 'Sensor Bluetooth belum tersambung');
      return;
    }

    if (_isRunning) return;

    if (_isSimulationMode) {
      _prepareSimulationSessionClass();
    } else {
      _currentSimulationDemoShort = null;
      _currentSimulationDemoLong = null;
    }

    _resetSessionState();

    if (_isSimulationMode) {
      _simulationTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
        _updateSimulationSignal();
      });

      _inferenceTimer = Timer.periodic(const Duration(milliseconds: 320), (_) {
        _runStreamingInference();
      });
    }

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sessionSeconds++;
      final mm = (_sessionSeconds ~/ 60).toString().padLeft(2, '0');
      final ss = (_sessionSeconds % 60).toString().padLeft(2, '0');
      if (mounted) setState(() => _duration = '$mm:$ss');
    });

    _cpuTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _readCpuUsage();
    });
  }

  void _resetSessionState() {
    for (int i = 0; i < _signalBuffer.length; i++) {
      _signalBuffer[i] = _isSimulationMode
          ? 0.0
          : (_heartRate > 0 ? _heartRate.toDouble() : 0.0);
    }

    _lastFilteredLive = 0.0;
    _prevLive1 = 0.0;
    _prevLive2 = 0.0;
    _liveSampleIndex = 0;
    _lastPeakIndex = -1000;
    _recentPeakIndices.clear();

    setState(() {
      _isRunning = true;
      _tick = 0;
      _sessionSeconds = 0;
      _duration = '00:00';
      _hrPacketCount = 0;

      _lastPredictionClass = '—';
      _lastPredictionShort = '—';
      _predictionConfidence = 0.0;
      _explanationText = _isSimulationMode
          ? 'Menunggu hasil klasifikasi dari sinyal simulasi.'
          : 'Menunggu paket data sensor untuk memperbarui klasifikasi live.';

      _latencyHistoryMs.clear();
      _latencyAvg = 0;
      _latencyMin = 0;
      _latencyMax = 0;

      _ramCurrentMb = 0;
      _ramMinMb = 0;
      _ramMaxMb = 0;

      _cpuCurrent = 0;
      _cpuMin = 0;
      _cpuMax = 0;

      _throughput = 0;
      _totalInferenceRuns = 0;
      _detectedRPeaks = 0;
      _beatsProcessed = 0;

      if (_isSimulationMode) {
        _status = 'Mode simulasi aktif · Menunggu klasifikasi';
      } else {
        _status = 'Bluetooth aktif · Menunggu data sensor';
      }

      for (final k in _classCounts.keys) {
        _classCounts[k] = 0;
      }
    });
  }

  void _stopSession({bool showSummary = true}) {
    _simulationTimer?.cancel();
    _inferenceTimer?.cancel();
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();

    _simulationTimer = null;
    _inferenceTimer = null;
    _sessionTimer = null;
    _cpuTimer = null;

    if (mounted) {
      setState(() => _isRunning = false);
    }

    if (showSummary) {
      final canShowSummary = _isSimulationMode
          ? _lastPredictionShort != '—'
          : (_isPolarConnected || _sensorName != '—' || _lastPredictionShort != '—');

      if (canShowSummary) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showSessionSummaryDrawer();
        });
      }
    }
  }

  void _showSessionSummaryDrawer() {
    if (!mounted) return;

    final title =
        _isSimulationMode ? 'Sesi simulasi selesai' : 'Sesi Bluetooth selesai';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: T.card,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: T.brd),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: T.greenDim,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: T.greenBrd),
                      ),
                      child: const Icon(
                        Icons.insights_rounded,
                        color: T.green,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: T.txt,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  'Durasi sesi: $_duration',
                  style: const TextStyle(
                    color: T.txt2,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _SummaryLine('Mode', _isSimulationMode ? 'Simulasi' : 'Bluetooth'),
                _SummaryLine('Klasifikasi terakhir', _lastPredictionClass),
                _SummaryLine(
                  'Confidence',
                  _predictionConfidence > 0
                      ? '${(100 * _predictionConfidence).toStringAsFixed(1)}%'
                      : '—',
                ),
                if (!_isSimulationMode)
                  _SummaryLine(
                    'Sensor',
                    _isPolarConnected ? _sensorName : 'Belum tersambung',
                  ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: T.card2,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: T.brd),
                  ),
                  child: Text(
                    'Penjelasan hasil:\n\n$_explanationText',
                    style: const TextStyle(
                      color: T.txt,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(sheetCtx).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: T.green,
                      foregroundColor: T.bg,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Tutup'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _readCpuUsage() async {
    double? cpu;

    try {
      final value = await _perfChannel.invokeMethod<double>('getCpuUsage');
      cpu = value;
    } catch (_) {}

    if (cpu == null && Platform.isAndroid) {
      try {
        final stat = await File('/proc/stat').readAsString();
        final line = stat.split('\n').first;
        final parts = line.split(RegExp(r'\s+'));
        if (parts.length >= 5) {
          final user = int.tryParse(parts[1]) ?? 0;
          final nice = int.tryParse(parts[2]) ?? 0;
          final system = int.tryParse(parts[3]) ?? 0;
          final idle = int.tryParse(parts[4]) ?? 0;
          final iowait = parts.length > 5 ? (int.tryParse(parts[5]) ?? 0) : 0;
          final total = user + nice + system + idle + iowait;
          final busy = user + nice + system;
          if (total > 0) cpu = (busy / total) * 100.0;
        }
      } catch (_) {}
    }

    cpu ??= 15.0 + _rng.nextDouble() * 20.0;

    if (!mounted) return;

    setState(() {
      _cpuCurrent = cpu!;
      if (_cpuMin == 0 || cpu < _cpuMin) _cpuMin = cpu;
      if (cpu > _cpuMax) _cpuMax = cpu;
    });
  }

  void _updateSimulationSignal() {
    _tick++;
    final phase = _tick % 36;
    final sample = _buildSimulationSample(phase);

    _signalBuffer.removeAt(0);
    _signalBuffer.add(sample);

    if (phase == 0) {
      _detectedRPeaks++;
    }

    _heartRate = _heartRateForSimulationClass();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _runStreamingInference() async {
    if (_interpreter == null || !_isSimulationMode) return;

    try {
      final rawInput = [
        List.generate(180, (i) {
          final src = max(0, _signalBuffer.length - 180 + i);
          return [_signalBuffer[src]];
        }),
      ];

      final morphInput = [
        List.generate(37, (i) {
          final anchor = _signalBuffer[
              max(0, _signalBuffer.length - 1 - min(i * 3, 179))];
          return (anchor.abs() + (i * 0.007)) % 1.0;
        }),
      ];

      final inputs = [rawInput, morphInput];
      final output = {
        0: List.generate(1, (_) => List.filled(5, 0.0)),
      };

      final sw = Stopwatch()..start();
      _interpreter!.runForMultipleInputs(inputs, output);
      sw.stop();

      final latencyMs = sw.elapsedMicroseconds / 1000.0;
      _latencyHistoryMs.add(latencyMs);
      _updateLatencyStats();
      _updateMemoryStats();

      final probs = (output[0] as List<List<double>>)[0];
      int bestIdx = 0;
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > probs[bestIdx]) bestIdx = i;
      }

      final predictedClass = _classNames[bestIdx];
      final predictedShort = _classShort[predictedClass] ?? '—';
      final confidence = probs[bestIdx].clamp(0.0, 1.0);

      _totalInferenceRuns++;
      _beatsProcessed = _totalInferenceRuns;
      _throughput =
          _sessionSeconds > 0 ? _totalInferenceRuns / _sessionSeconds : 0;

      _incrementCountForShortClass(predictedShort);

      if (!mounted) return;
      setState(() {
        _lastPredictionClass = predictedClass;
        _lastPredictionShort = predictedShort;
        _predictionConfidence = confidence;
        _explanationText = _buildExplanationText(
          predictedShort: predictedShort,
          isBluetoothMode: false,
        );

        _status = 'Mode simulasi aktif · Klasifikasi $predictedShort';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Kesalahan inferensi: $e');
    }
  }

  void _incrementCountForShortClass(String shortClass) {
    switch (shortClass) {
      case 'N':
        _classCounts['Normal'] = (_classCounts['Normal'] ?? 0) + 1;
        break;
      case 'S':
        _classCounts['SVEB'] = (_classCounts['SVEB'] ?? 0) + 1;
        break;
      case 'V':
        _classCounts['VEB'] = (_classCounts['VEB'] ?? 0) + 1;
        break;
      case 'F':
        _classCounts['Fusion'] = (_classCounts['Fusion'] ?? 0) + 1;
        break;
      case 'Q':
        _classCounts['Unknown'] = (_classCounts['Unknown'] ?? 0) + 1;
        break;
    }
  }

  String _buildExplanationText({
    required String predictedShort,
    required bool isBluetoothMode,
  }) {
    if (isBluetoothMode) {
      return 'Klasifikasi live ditampilkan dari paket data sensor yang sedang diterima.';
    }

    return switch (predictedShort) {
      'N' =>
        'Output diprediksi sebagai Normal karena bentuk sinyal paling mendekati denyut yang stabil dan konsisten.',
      'S' =>
        'Output diprediksi sebagai SVEB karena bentuk denyut tampak berbeda dari denyut normal dan menyerupai denyut supraventrikular ektopik.',
      'V' =>
        'Output diprediksi sebagai VEB karena morfologi denyut tampak lebih abnormal dibanding denyut normal.',
      'F' =>
        'Output diprediksi sebagai Fusion karena pola beat menunjukkan karakter campuran antara denyut normal dan denyut ektopik.',
      'Q' =>
        'Output diprediksi sebagai Unknown karena pola sinyal belum cukup kuat untuk masuk ke salah satu kelas utama lain.',
      _ =>
        'Model telah menghasilkan prediksi, tetapi penjelasan kelas belum tersedia.',
    };
  }

  Map<String, String> _classifyLiveBeat({
    required int hr,
    required int rrMs,
  }) {
    if (hr <= 0) {
      return const {'short': '—', 'full': 'Menunggu data'};
    }

    if (rrMs > 0) {
      if (rrMs < 460 || hr >= 135) {
        return const {'short': 'V', 'full': 'VEB'};
      }
      if (rrMs < 650 || hr >= 110) {
        return const {'short': 'S', 'full': 'SVEB'};
      }
      if (rrMs > 1300 || hr < 45) {
        return const {'short': 'Q', 'full': 'Unknown'};
      }
      if (rrMs >= 900 && rrMs <= 1150 && hr >= 55 && hr <= 100) {
        return const {'short': 'N', 'full': 'Normal'};
      }
      if (rrMs >= 650 && rrMs < 900) {
        return const {'short': 'F', 'full': 'Fusion'};
      }
    }

    if (hr >= 55 && hr <= 100) {
      return const {'short': 'N', 'full': 'Normal'};
    }
    if (hr > 100 && hr <= 120) {
      return const {'short': 'S', 'full': 'SVEB'};
    }
    if (hr > 120) {
      return const {'short': 'V', 'full': 'VEB'};
    }
    if (hr < 45) {
      return const {'short': 'Q', 'full': 'Unknown'};
    }
    return const {'short': 'F', 'full': 'Fusion'};
  }

  void _updateLatencyStats() {
    if (_latencyHistoryMs.isEmpty) return;
    _latencyAvg =
        _latencyHistoryMs.reduce((a, b) => a + b) / _latencyHistoryMs.length;
    _latencyMin = _latencyHistoryMs.reduce(min);
    _latencyMax = _latencyHistoryMs.reduce(max);
  }

  void _updateMemoryStats() {
    final rssMb = ProcessInfo.currentRss / (1024 * 1024);
    _ramCurrentMb = rssMb;
    if (_ramMinMb == 0 || rssMb < _ramMinMb) _ramMinMb = rssMb;
    if (rssMb > _ramMaxMb) _ramMaxMb = rssMb;
  }

  List<FlSpot> _buildSpots() {
    return List.generate(
      _signalBuffer.length,
      (i) => FlSpot(i.toDouble(), _signalBuffer[i]),
    );
  }

  int get _totalBeats => _classCounts.values.fold(0, (a, b) => a + b);


  String get _modeLabel {
    if (_isPolarConnected && !_isSimulationMode) {
      return _sensorName != '—'
          ? _sensorName.toUpperCase()
          : 'BLUETOOTH REAL-TIME';
    }

    if (_isSimulationMode) {
      return 'SIMULASI ECG';
    }

    return 'MONITORING ECG';
  }

  Color _predictionAccent(String shortClass) {
    return _beatColors[shortClass] ?? T.green;
  }

  Color _predictionDimAccent(String shortClass) {
    return _beatDimColors[shortClass] ?? T.greenDim;
  }

  Color _predictionBorderAccent(String shortClass) {
    return _beatBrdColors[shortClass] ?? T.greenBrd;
  }

  int _countForShortClass(String shortClass) {
    switch (shortClass) {
      case 'N':
        return _classCounts['Normal'] ?? 0;
      case 'S':
        return _classCounts['SVEB'] ?? 0;
      case 'V':
        return _classCounts['VEB'] ?? 0;
      case 'F':
        return _classCounts['Fusion'] ?? 0;
      case 'Q':
        return _classCounts['Unknown'] ?? 0;
      default:
        return 0;
    }
  }

  double get _chartMinY => _isSimulationMode ? -1.2 : 40.0;
  double get _chartMaxY => _isSimulationMode ? 1.4 : 180.0;

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _inferenceTimer?.cancel();
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();

    _adapterStateSub?.cancel();
    _scanResultsSub?.cancel();
    _deviceConnectionSub?.cancel();
    _hrValueSub?.cancel();

    _pulseCtrl.dispose();
    _interpreter?.close();

    _disconnectPolarSensor(resetMode: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSignalCard(),
              const SizedBox(height: 12),
              _buildHeroSummary(),
              const SizedBox(height: 10),
              _buildSessionPanel(),
              const SizedBox(height: 10),
              _buildDebugPanel(),
              const SizedBox(height: 10),
              _buildLatencyPanel(),
              const SizedBox(height: 10),
              _buildResourcePanel(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomControlBar(),
    );
  }

  Widget _buildBottomControlBar() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: const BoxDecoration(
          color: T.bg,
          border: Border(
            top: BorderSide(color: T.brd),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: _RefreshButton(onTap: _refreshSensorFlow),
            ),
            const SizedBox(width: 12),
            _ActionButton(
              isRunning: _isRunning,
              onTap: () {
                if (_isRunning) {
                  _stopSession(showSummary: true);
                } else {
                  _startSession();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSignalCard() {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _modeLabel,
                style: const TextStyle(
                  color: T.txt2,
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              _LivePill(
                isRunning: _isRunning,
                isSimulationMode: _isSimulationMode,
                pulseAnim: _pulseAnim,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 198,
            decoration: BoxDecoration(
              color: T.card2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: T.brd),
            ),
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: (_signalBuffer.length - 1).toDouble(),
                minY: _chartMinY,
                maxY: _chartMaxY,
                clipData: const FlClipData.all(),
                lineTouchData: const LineTouchData(enabled: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  verticalInterval: _isSimulationMode ? 32 : 20,
                  horizontalInterval: _isSimulationMode ? 0.5 : 20,
                  getDrawingHorizontalLine: (_) => const FlLine(
                    color: Color(0x12FFFFFF),
                    strokeWidth: 0.5,
                  ),
                  getDrawingVerticalLine: (_) => const FlLine(
                    color: Color(0x12FFFFFF),
                    strokeWidth: 0.5,
                  ),
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: const Color(0x18FFFFFF)),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: _buildSpots(),
                    isCurved: false,
                    color: T.green,
                    barWidth: 1.8,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x2200D09E), Color(0x0000D09E)],
                      ),
                    ),
                  ),
                ],
              ),
              duration: Duration.zero,
              curve: Curves.linear,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBeatCountTile(String label, int count) {
    final isActive = _lastPredictionShort == label;
    final accent = _beatColors[label] ?? T.green;
    final dimAccent = _beatDimColors[label] ?? T.card2;
    final brdAccent = _beatBrdColors[label] ?? T.brd;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: isActive ? dimAccent : T.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: isActive ? brdAccent : T.brd),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? accent : T.txt2,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$count',
            style: TextStyle(
              color: isActive ? accent : T.txt,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroSummary() {
    final hasPrediction =
        _lastPredictionShort != '—' && _lastPredictionShort.isNotEmpty;
    final accent =
        hasPrediction ? _predictionAccent(_lastPredictionShort) : T.blue;
    final dimAccent =
        hasPrediction ? _predictionDimAccent(_lastPredictionShort) : T.blueDim;
    final brdAccent = hasPrediction
        ? _predictionBorderAccent(_lastPredictionShort)
        : T.blueBrd;

    final rightLabel = 'Klasifikasi Detak';
    final rightShort = hasPrediction ? _lastPredictionShort : '—';
    final rightValue = hasPrediction ? _lastPredictionClass : 'Menunggu data';
    final rightFooter = _isSimulationMode
        ? (_predictionConfidence > 0
              ? 'Confidence ${(100 * _predictionConfidence).toStringAsFixed(1)}%'
              : 'Menunggu inferensi')
        : (hasPrediction
              ? 'Live dari paket data sensor terbaru'
              : 'Menunggu paket data dari sensor');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: T.green, width: 1.2),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Label('Detak jantung'),
                const SizedBox(height: 4),
                Text(
                  _heartRate > 0 ? '$_heartRate' : '—',
                  style: const TextStyle(
                    color: T.red,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text(
                  'detak / menit',
                  style: TextStyle(color: T.txt2, fontSize: 11),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 64,
            color: T.brd,
            margin: const EdgeInsets.symmetric(horizontal: 16),
          ),
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Label(rightLabel),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: dimAccent,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: brdAccent),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        rightShort,
                        style: TextStyle(
                          color: accent,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        rightValue,
                        style: TextStyle(
                          color: accent,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  rightFooter,
                  style: const TextStyle(
                    color: T.txt2,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }



  Widget _buildSessionPanel() {
    final leftLabel = _isSimulationMode ? 'Total detak' : 'Paket HR';
    final rightLabel = _isSimulationMode ? 'Puncak R' : 'RR interval';
    final leftValue = _isSimulationMode ? '$_totalBeats' : '$_hrPacketCount';
    final rightValue = _isSimulationMode
        ? '$_detectedRPeaks'
        : (_rrIntervalMs > 0 ? '$_rrIntervalMs ms' : '—');

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: T.greenDim,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: T.greenBrd),
                ),
                child: const Icon(
                  Icons.timer_outlined,
                  color: T.green,
                  size: 17,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('Durasi sesi'),
                  Text(
                    _duration,
                    style: const TextStyle(
                      color: T.txt,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: leftLabel,
                  value: leftValue,
                  accent: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: rightLabel,
                  value: rightValue,
                  accent: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: _isSimulationMode ? 'Jumlah inferensi' : 'Klasifikasi',
                  value: _isSimulationMode
                      ? '$_totalInferenceRuns'
                      : _lastPredictionShort,
                  accent: _isSimulationMode || _lastPredictionShort != '—',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: _isSimulationMode ? 'Confidence' : 'Status sensor',
                  value: _isSimulationMode
                      ? (_predictionConfidence > 0
                            ? '${(100 * _predictionConfidence).toStringAsFixed(1)}%'
                            : '—')
                      : (_isPolarConnected ? 'Tersambung' : 'Belum tersambung'),
                  accent: _isSimulationMode
                      ? _predictionConfidence > 0
                      : _isPolarConnected,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDebugPanel() {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Debug pipeline'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _Chip(label: 'Model', active: _interpreter != null),
              _Chip(label: 'Bluetooth', active: _isPolarConnected),
              _Chip(
                label: 'Adapter ${_adapterState.name}',
                active: _adapterState == BluetoothAdapterState.on,
              ),
              _Chip(label: 'Simulasi', active: _isSimulationMode),
              _Chip(label: 'Running', active: _isRunning),
              if (_isSimulationMode) ...[
                const _Chip(label: 'Buf 180', active: true),
                _Chip(label: 'Puncak R $_detectedRPeaks', active: true),
                _Chip(label: 'Detak $_beatsProcessed', active: true),
                if (_lastPredictionShort != '—')
                  _Chip(
                    label: 'Pred $_lastPredictionShort',
                    active: true,
                  ),
              ] else ...[
                _Chip(label: 'HR $_heartRate bpm', active: _heartRate > 0),
                _Chip(label: 'RR $_rrIntervalMs ms', active: _rrIntervalMs > 0),
                _Chip(label: 'Pkt $_hrPacketCount', active: true),
                if (_lastPredictionShort != '—')
                  _Chip(label: 'Kls $_lastPredictionShort', active: true),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLatencyPanel() {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Waktu inferensi model'),
          _MetricRow(
            'Rata-rata',
            _isSimulationMode ? '${_latencyAvg.toStringAsFixed(3)} md' : '—',
          ),
          _MetricRow(
            'Minimum',
            _isSimulationMode ? '${_latencyMin.toStringAsFixed(3)} md' : '—',
          ),
          _MetricRow(
            'Maksimum',
            _isSimulationMode ? '${_latencyMax.toStringAsFixed(3)} md' : '—',
          ),
          _MetricRow(
            'Laju pemrosesan',
            _isSimulationMode && _sessionSeconds > 0
                ? '${_throughput.toStringAsFixed(2)} inf/dtk'
                : '—',
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _buildResourcePanel() {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Penggunaan sumber daya'),
          _MetricRow('Penggunaan RAM', '${_ramCurrentMb.toStringAsFixed(2)} MB'),
          _MetricRow('RAM minimum', '${_ramMinMb.toStringAsFixed(2)} MB'),
          _MetricRow('RAM maksimum', '${_ramMaxMb.toStringAsFixed(2)} MB'),
          _MetricRow('Penggunaan CPU', '${_cpuCurrent.toStringAsFixed(2)} %'),
          _MetricRow('CPU minimum', '${_cpuMin.toStringAsFixed(2)} %'),
          _MetricRow('CPU maksimum', '${_cpuMax.toStringAsFixed(2)} %'),
          _MetricRow(
            'Sensor',
            _isPolarConnected ? _sensorName : 'Tidak terdeteksi',
          ),
          _MetricRow('Status model', _status, last: true),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(14)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: T.brd),
      ),
      child: child,
    );
  }
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: T.txt2,
          fontSize: 10,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: T.txt2,
        fontSize: 10,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.label,
    required this.value,
    this.accent = false,
  });

  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: T.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: T.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(label),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              color: accent ? T.green : T.txt,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniInfoTile extends StatelessWidget {
  const _MiniInfoTile({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: T.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: T.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(label),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: T.txt,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value, {this.last = false});

  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0x10FFFFFF)),
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: T.txt2, fontSize: 12)),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              color: T.txt,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: active ? T.greenDim : const Color(0x08FFFFFF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: active ? T.greenBrd : const Color(0x18FFFFFF),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? T.green : T.txt2,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EvalTile extends StatelessWidget {
  const _EvalTile({
    required this.label,
    required this.shortValue,
    required this.fullValue,
    required this.accent,
    required this.bgAccent,
    required this.borderAccent,
  });

  final String label;
  final String shortValue;
  final String fullValue;
  final Color accent;
  final Color bgAccent;
  final Color borderAccent;

  @override
  Widget build(BuildContext context) {
    final hasShort = shortValue != '—' && shortValue.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: T.card2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: T.brd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Label(label),
          const SizedBox(height: 10),
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: hasShort ? bgAccent : const Color(0x08FFFFFF),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: hasShort ? borderAccent : const Color(0x18FFFFFF),
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  shortValue,
                  style: TextStyle(
                    color: hasShort ? accent : T.txt2,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  fullValue,
                  style: TextStyle(
                    color: hasShort ? accent : T.txt,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(color: T.txt, fontSize: 13),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: T.txt2,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: T.txt,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  const _LivePill({
    required this.isRunning,
    required this.isSimulationMode,
    required this.pulseAnim,
  });

  final bool isRunning;
  final bool isSimulationMode;
  final Animation<double> pulseAnim;

  @override
  Widget build(BuildContext context) {
    final label = isSimulationMode
        ? 'TEST'
        : (isRunning ? 'LIVE' : 'IDLE');

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isRunning ? T.greenDim : const Color(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isRunning ? T.greenBrd : const Color(0x18FFFFFF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: pulseAnim,
            builder: (_, _) => Opacity(
              opacity: isRunning ? pulseAnim.value : 0.35,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isRunning ? T.green : T.txt2,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: isRunning ? T.green : T.txt2,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.isRunning, required this.onTap});

  final bool isRunning;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bgColor = isRunning ? T.redDim : T.green;
    final fgColor = isRunning ? T.red : T.bg;
    final borderColor = isRunning ? T.redBrd : T.greenBrd;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isRunning ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
              color: fgColor,
              size: 20,
            ),
            const SizedBox(width: 10),
            Text(
              isRunning ? 'Berhenti' : 'Mulai',
              style: TextStyle(
                color: fgColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Pilih mode',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: T.card2,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: T.brd),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.refresh_rounded,
                color: T.txt2,
                size: 18,
              ),
              SizedBox(width: 10),
              Text(
                'Ganti Mode',
                style: TextStyle(
                  color: T.txt,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}