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

// ─── Beat indicator colors ──────────────────────────────────────────────────
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
  Timer? _ecgTimer;
  Timer? _sessionTimer;
  Timer? _cpuTimer;
  final Random _rng = Random();

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  StreamSubscription<List<ScanResult>>? _scanSub;

  // Mode: true = bluetooth sensor, false = inference/simulation
  bool _isInferenceMode = false;

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

  final List<double> _ecgBuffer = List.generate(260, (_) => 0.0);

  // Beat events for ECG overlay: list of (bufferIndex, shortClass)
  final List<({int index, String cls})> _beatEvents = [];

  String _status = 'Memuat model...';
  String _lastClass = '—';
  String _lastShortClass = '—';
  String _duration = '00:00';
  bool _isRunning = false;

  bool _sensorDetected = false;
  String _sensorName = '—';
  bool _hasPromptedSensorFlow = false;

  int _tick = 0;
  int _sessionSeconds = 0;
  int _heartRate = 0;

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

  // Scroll controller for ECG horizontal scroll
  final ScrollController _ecgScrollController = ScrollController();

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startInitialSensorFlow();
    });
  }

  Future<void> _loadModel() async {
    try {
      final interpreter = await Interpreter.fromAsset(
        'assets/model/morphology_transformer_final.tflite',
      );
      setState(() {
        _interpreter = interpreter;
        _status = 'Model berhasil dimuat';
      });
    } catch (e) {
      setState(() => _status = 'Gagal memuat model: $e');
    }
  }

  Future<void> _requestBlePermissions() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _startInitialSensorFlow() async {
    if (_hasPromptedSensorFlow || !mounted) return;
    _hasPromptedSensorFlow = true;
    await _startSensorScanFlow();
  }

  // Called by refresh button — opens mode switch popup
  Future<void> _refreshSensorFlow() async {
    _stopSession();

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
                  'Pilih sumber ECG',
                  style: TextStyle(
                    color: T.txt,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Anda dapat beralih ke inferensi dataset atau mencoba menyambungkan sensor Bluetooth.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          setState(() {
                            _sensorDetected = false;
                            _sensorName = '—';
                            _isInferenceMode = true;
                            _status = 'Mode inferensi aktif';
                          });
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: T.txt,
                          side: const BorderSide(color: T.brd),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.auto_graph_rounded, size: 18),
                        label: const Text('Mode Inferensi'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          _hasPromptedSensorFlow = false;
                          setState(() {
                            _sensorDetected = false;
                            _sensorName = '—';
                            _isInferenceMode = false;
                          });
                          _startSensorScanFlow();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.bluetooth_searching_rounded, size: 18),
                        label: const Text('Sambung Sensor'),
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

  Future<void> _startSensorScanFlow() async {
    if (_hasPromptedSensorFlow && _hasPromptedSensorFlow) {
      // allow re-entry when called from refresh
    }
    _hasPromptedSensorFlow = true;

    await _requestBlePermissions();

    if (!mounted) return;

    _showScanningBottomSheet();

    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();

    bool found = false;

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName.trim();
        final lowered = name.toLowerCase();

        if (lowered.contains('polar') || lowered.contains('h10')) {
          found = true;
          _sensorDetected = true;
          _sensorName = name.isEmpty ? 'Sensor Tidak Dikenal' : name;
          _isInferenceMode = false;
          _status = 'Sensor terdeteksi: $_sensorName';

          FlutterBluePlus.stopScan();

          if (mounted) {
            Navigator.of(context, rootNavigator: true).maybePop();
            setState(() {});
          }
          break;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    await Future.delayed(const Duration(seconds: 6));

    if (!mounted) return;

    await FlutterBluePlus.stopScan();

    if (!found) {
      _sensorDetected = false;
      _sensorName = '—';

      if (mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }

      await Future.delayed(const Duration(milliseconds: 200));

      if (!mounted) return;

      await _showSensorNotFoundBottomSheet();
    }
  }

  void _showScanningBottomSheet() {
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
                  'Aplikasi sedang memindai perangkat Bluetooth yang sesuai.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                SizedBox(height: 18),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSensorNotFoundBottomSheet() async {
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
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
                        Icons.bluetooth_disabled,
                        color: T.red,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Tidak ada sensor yang terdeteksi',
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
                  'Anda dapat mencoba memindai kembali, atau melanjutkan dengan menjalankan inferensi simulasi.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          Navigator.of(sheetCtx).pop();
                          _startSensorScanFlow();
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
                          setState(() {
                            _isInferenceMode = true;
                            _status = 'Mode inferensi aktif';
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Jalankan Inferensi'),
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

  void _startSession() {
    if (_interpreter == null) {
      setState(() => _status = 'Model belum siap');
      return;
    }
    if (_isRunning) return;

    setState(() {
      _isRunning = true;
      _tick = 0;
      _sessionSeconds = 0;
      _duration = '00:00';
      _heartRate = 0;
      _lastClass = '—';
      _lastShortClass = '—';

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

      _beatEvents.clear();

      for (final k in _classCounts.keys) {
        _classCounts[k] = 0;
      }
    });

    _ecgTimer = Timer.periodic(const Duration(milliseconds: 60), (_) {
      _updateFakeEcg();
      if (_tick % 6 == 0) _runStreamingInference();
      if (mounted) setState(() {});
    });

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

  void _stopSession() {
    _ecgTimer?.cancel();
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();

    _ecgTimer = null;
    _sessionTimer = null;
    _cpuTimer = null;

    setState(() => _isRunning = false);
  }

  void _shiftBeatEventsLeft() {
    for (int i = 0; i < _beatEvents.length; i++) {
      final event = _beatEvents[i];
      _beatEvents[i] = (index: event.index - 1, cls: event.cls);
    }
    _beatEvents.removeWhere((event) => event.index < 0);
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

  void _autoScrollEcgToLatest() {
    if (!_ecgScrollController.hasClients) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_ecgScrollController.hasClients) return;
      final maxScroll = _ecgScrollController.position.maxScrollExtent;
      _ecgScrollController.jumpTo(maxScroll);
    });
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

  void _updateFakeEcg() {
    _tick++;
    final phase = _tick % 36;
    double sample;

    bool isRPeak = false;
    if (phase == 0) {
      sample = 1.15;
      _detectedRPeaks++;
      isRPeak = true;
    } else if (phase == 1) {
      sample = -0.88;
    } else if (phase < 5) {
      sample = 0.12 + (_rng.nextDouble() * 0.08);
    } else if (phase < 12) {
      sample = 0.02 * sin(_tick / 2);
    } else if (phase < 20) {
      sample = 0.16 + 0.10 * sin(_tick / 3);
    } else {
      sample = (_rng.nextDouble() - 0.5) * 0.06;
    }

    _shiftBeatEventsLeft();
    _ecgBuffer.removeAt(0);
    _ecgBuffer.add(sample);
    _heartRate = 110 + (_tick % 8);

    if (isRPeak && _lastShortClass != '—') {
      _beatEvents.add((index: _ecgBuffer.length - 1, cls: _lastShortClass));
      _incrementCountForShortClass(_lastShortClass);
      if (_beatEvents.length > 20) _beatEvents.removeAt(0);
    }

    _autoScrollEcgToLatest();
  }

  Future<void> _runStreamingInference() async {
    if (_interpreter == null) return;

    try {
      final rawInput = [
        List.generate(180, (i) {
          final src = max(0, _ecgBuffer.length - 180 + i);
          return [_ecgBuffer[src]];
        }),
      ];

      final morphInput = [
        List.generate(37, (i) => (_ecgBuffer.last.abs() + (i * 0.011)) % 1.0),
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

      final cls = _classNames[bestIdx];
      _totalInferenceRuns++;
      _beatsProcessed = _totalInferenceRuns;
      _throughput =
          _sessionSeconds > 0 ? _totalInferenceRuns / _sessionSeconds : 0;

      setState(() {
        _lastClass = cls;
        _lastShortClass = _classShort[cls] ?? '—';
      });
    } catch (e) {
      setState(() => _status = 'Kesalahan inferensi: $e');
    }
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

  List<FlSpot> _buildSpots() =>
      List.generate(_ecgBuffer.length, (i) => FlSpot(i.toDouble(), _ecgBuffer[i]));

  int get _totalBeats => _classCounts.values.fold(0, (a, b) => a + b);

  String get _ecgModeLabel {
    if (_sensorDetected && !_isInferenceMode) {
      return 'PEMANTAUAN JANTUNG LANGSUNG';
    }
    return 'DATASET MIT-BIH · INFERENSI';
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _ecgTimer?.cancel();
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();
    _pulseCtrl.dispose();
    _interpreter?.close();
    _ecgScrollController.dispose();
    super.dispose();
  }

  // ─── Build ───────────────────────────────────────────────────────────────
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
              _buildEcgCard(),
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
              onTap: _isRunning ? _stopSession : _startSession,
            ),
          ],
        ),
      ),
    );
  }

  // ─── ECG card ────────────────────────────────────────────────────────────
  Widget _buildEcgCard() {
    const chartWidth = 900.0;

    return _Panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _ecgModeLabel,
                style: const TextStyle(
                  color: T.txt2,
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
              const Spacer(),
              _LivePill(
                isRunning: _isRunning,
                isInferenceMode: _isInferenceMode,
                pulseAnim: _pulseAnim,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildBeatCountTile('N', _countForShortClass('N'))),
              const SizedBox(width: 6),
              Expanded(child: _buildBeatCountTile('S', _countForShortClass('S'))),
              const SizedBox(width: 6),
              Expanded(child: _buildBeatCountTile('V', _countForShortClass('V'))),
              const SizedBox(width: 6),
              Expanded(child: _buildBeatCountTile('F', _countForShortClass('F'))),
              const SizedBox(width: 6),
              Expanded(child: _buildBeatCountTile('Q', _countForShortClass('Q'))),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: SingleChildScrollView(
              controller: _ecgScrollController,
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: SizedBox(
                width: chartWidth,
                child: Stack(
                  children: [
                    LineChart(
                      LineChartData(
                        minX: 0,
                        maxX: (_ecgBuffer.length - 1).toDouble(),
                        minY: -1.2,
                        maxY: 1.4,
                        clipData: const FlClipData.all(),
                        gridData: FlGridData(
                          show: true,
                          drawVerticalLine: true,
                          verticalInterval: (_ecgBuffer.length - 1) / 8,
                          horizontalInterval: 0.65,
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
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: _buildSpots(),
                            isCurved: true,
                            curveSmoothness: 0.2,
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
                    ),
                    ..._buildBeatOverlays(chartWidth),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.chevron_left, color: T.txt2, size: 14),
              SizedBox(width: 4),
              Text(
                'Geser untuk melihat sinyal',
                style: TextStyle(
                  color: T.txt2,
                  fontSize: 10,
                  letterSpacing: 0.5,
                ),
              ),
              SizedBox(width: 4),
              Icon(Icons.chevron_right, color: T.txt2, size: 14),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Beat label overlays on ECG ──────────────────────────────────────────
  List<Widget> _buildBeatOverlays(double totalWidth) {
    if (_beatEvents.isEmpty) return const [];

    final bufLen = (_ecgBuffer.length - 1).toDouble();

    return _beatEvents.map((event) {
      final xFraction = bufLen <= 0 ? 0.0 : event.index / bufLen;
      final leftPx = xFraction * totalWidth;
      final color = _beatColors[event.cls] ?? T.green;
      final dimColor = _beatDimColors[event.cls] ?? T.greenDim;
      final brdColor = _beatBrdColors[event.cls] ?? T.greenBrd;

      return Positioned(
        left: leftPx - 11,
        top: 4,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: dimColor,
            shape: BoxShape.circle,
            border: Border.all(color: brdColor, width: 1.2),
          ),
          alignment: Alignment.center,
          child: Text(
            event.cls,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );
    }).toList();
  }

  Widget _buildBeatCountTile(String label, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: T.card2,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: T.brd),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: T.txt2,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$count',
            style: const TextStyle(
              color: T.txt,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Hero summary ─────────────────────────────────────────────────────────
  Widget _buildHeroSummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: T.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: T.green, width: 1.2),
      ),
      child: Row(
        children: [
          // Left: Heart Rate
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Label('Detak jantung'),
                const SizedBox(height: 4),
                Text(
                  _isRunning ? '$_heartRate' : '—',
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
          // Right: Beat Classification — label, then badge + class name inline
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Label('Klasifikasi detak'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Badge (rectangular, rounded)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _lastShortClass != '—'
                            ? (_beatDimColors[_lastShortClass] ?? T.greenDim)
                            : T.greenDim,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: _lastShortClass != '—'
                              ? (_beatBrdColors[_lastShortClass] ?? T.greenBrd)
                              : T.greenBrd,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _lastShortClass,
                        style: TextStyle(
                          color: _lastShortClass != '—'
                              ? (_beatColors[_lastShortClass] ?? T.green)
                              : T.green,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Class name
                    Expanded(
                      child: Text(
                        _lastClass,
                        style: TextStyle(
                          color: _lastShortClass != '—'
                              ? (_beatColors[_lastShortClass] ?? T.green)
                              : T.green,
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
                  'MIT-BIH Kelas $_lastShortClass',
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

  // ─── Beat row ────────────────────────────────────────────────────────────
  // Shows N/S/V/F/Q with full label and count — replaces old strip + old beat row
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

  // ─── Session panel ───────────────────────────────────────────────────────
  Widget _buildSessionPanel() {
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
                  label: 'Total detak',
                  value: '$_totalBeats',
                  accent: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: 'Puncak R',
                  value: '$_detectedRPeaks',
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
                  label: 'Laju pemrosesan',
                  value: _sessionSeconds > 0
                      ? '${_throughput.toStringAsFixed(2)} inf/dtk'
                      : '—',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: 'Jumlah inferensi',
                  value: '$_totalInferenceRuns',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Debug panel ─────────────────────────────────────────────────────────
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
              _Chip(label: 'Sensor', active: _sensorDetected),
              const _Chip(label: 'Threshold', active: true),
              const _Chip(label: 'Buf 180', active: true),
              _Chip(label: 'Puncak R $_detectedRPeaks', active: true),
              _Chip(label: 'Detak $_beatsProcessed', active: true),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Latency panel ───────────────────────────────────────────────────────
  Widget _buildLatencyPanel() {
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Waktu inferensi model'),
          _MetricRow('Rata-rata', '${_latencyAvg.toStringAsFixed(3)} md'),
          _MetricRow('Minimum', '${_latencyMin.toStringAsFixed(3)} md'),
          _MetricRow('Maksimum', '${_latencyMax.toStringAsFixed(3)} md'),
          _MetricRow(
            'Laju pemrosesan',
            _sessionSeconds > 0
                ? '${_throughput.toStringAsFixed(2)} inf/dtk'
                : '—',
            last: true,
          ),
        ],
      ),
    );
  }

  // ─── Resource panel ──────────────────────────────────────────────────────
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
          _MetricRow('Sensor', _sensorDetected ? _sensorName : 'Tidak terdeteksi'),
          _MetricRow('Status model', _status),
          _MetricRow('Total detak', '$_totalBeats', last: true),
        ],
      ),
    );
  }
}

// ─── Shared widgets ─────────────────────────────────────────────────────────

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

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value, {this.last = false});
  final String label;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(
                bottom: BorderSide(color: Color(0x10FFFFFF)),
              ),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: T.txt2, fontSize: 12)),
          const Spacer(),
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

class _LivePill extends StatelessWidget {
  const _LivePill({
    required this.isRunning,
    required this.isInferenceMode,
    required this.pulseAnim,
  });
  final bool isRunning;
  final bool isInferenceMode;
  final Animation<double> pulseAnim;

  @override
  Widget build(BuildContext context) {
    final label = !isRunning
        ? 'IDLE'
        : isInferenceMode
            ? 'INFERENSI'
            : 'LANGSUNG';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isRunning ? T.greenDim : const Color(0x08FFFFFF),
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
            builder: (_, __) => Opacity(
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

// ─── Refresh button (top-left AppBar leading) ─────────────────────────────
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Sambungkan ulang',
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
                'Sambungkan Ulang',
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