import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
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

// ─── Runtime configuration ─────────────────────────────────────────────────
const int _modelWindowSamples = 180;
const int _signalBufferSamples = 260;
const int _stabilizationSeconds = 40;
const int _chartHistoryBeats = 6;
const int _chartBeatSamples = 96;
const int _chartBeatGapSamples = 10;

class EvaluationRow {
  final String recordId;
  final int centerSample;
  final String annotationSymbol;
  final int gtClassId;
  final String gtClassName;
  final String gtClassShort;
  final List<double> raw;
  final List<double> morph;

  const EvaluationRow({
    required this.recordId,
    required this.centerSample,
    required this.annotationSymbol,
    required this.gtClassId,
    required this.gtClassName,
    required this.gtClassShort,
    required this.raw,
    required this.morph,
  });
}

class BluetoothBeatTag {
  final int sampleIndex;
  final String shortClass;

  const BluetoothBeatTag({required this.sampleIndex, required this.shortClass});

  BluetoothBeatTag copyWith({int? sampleIndex, String? shortClass}) {
    return BluetoothBeatTag(
      sampleIndex: sampleIndex ?? this.sampleIndex,
      shortClass: shortClass ?? this.shortClass,
    );
  }
}

class ChartBeatFrame {
  final List<double> samples;
  final int rPeakIndex;
  final String shortClass;

  const ChartBeatFrame({
    required this.samples,
    required this.rPeakIndex,
    required this.shortClass,
  });
}

class ChartSeriesData {
  final List<FlSpot> spots;
  final List<BluetoothBeatTag> beatTags;

  const ChartSeriesData({required this.spots, required this.beatTags});
}

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
  Timer? _calibrationTimer;
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

  List<EvaluationRow> _evaluationRows = [];
  String? _uploadedCsvName;
  bool _hasUploadedCsv = false;
  int _currentEvalIndex = 0;

  String _currentGroundTruthShort = '—';
  String _currentGroundTruthLong = '—';

  int _evalCorrect = 0;
  int _evalWrong = 0;
  int _evalTotal = 0;
  double _evalAccuracy = 0.0;

  bool _isCalibrating = false;
  int _calibrationSecondsLeft = _stabilizationSeconds;

  final List<double> _signalBuffer = List.generate(
    _signalBufferSamples,
    (_) => 0.0,
  );

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
  double _lastInferenceMs = 0.0;
  double _lastCpuAtInference = 0.0;
  String _duration = '00:00';
  String _sensorName = '—';

  int _tick = 0;
  int _sessionSeconds = 0;
  int _heartRate = 0;
  int _rrIntervalMs = 0;
  int _hrPacketCount = 0;
  bool _isBluetoothInferenceBusy = false;
  List<ChartBeatFrame> _chartBeatFrames = [];

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

    _pulseAnim = Tween<double>(
      begin: 1.0,
      end: 0.25,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

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

  Future<void> _activateSimulationMode() async {
    await _disconnectPolarSensor(resetMode: false);
    final loaded = await _pickAndLoadCsv();
    if (!loaded || !mounted) return;

    setState(() {
      _isSimulationMode = true;
      _sensorName = '—';
      _status = 'Mode evaluasi aktif · ${_uploadedCsvName ?? 'CSV'}';
    });
  }

  Future<bool> _pickAndLoadCsv() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        if (mounted) {
          setState(() {
            _status = 'Pemilihan file dibatalkan';
          });
        }
        return false;
      }

      final picked = result.files.single;
      String text;

      if (picked.bytes != null) {
        text = utf8.decode(picked.bytes!, allowMalformed: true);
      } else if (picked.path != null) {
        text = await File(picked.path!).readAsString();
      } else {
        throw Exception('File CSV tidak dapat dibaca');
      }

      final rows = _parseCsvText(text);
      if (rows.isEmpty) {
        throw Exception('CSV tidak memiliki data evaluasi yang valid');
      }

      if (!mounted) return false;
      setState(() {
        _evaluationRows = rows;
        _uploadedCsvName = picked.name;
        _hasUploadedCsv = true;
        _currentEvalIndex = 0;
        _currentGroundTruthShort = '—';
        _currentGroundTruthLong = '—';
        _status = 'Dataset evaluasi berhasil dimuat (${rows.length} sampel)';
      });

      _loadRowIntoSignalBuffer(rows.first);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _evaluationRows = [];
          _hasUploadedCsv = false;
          _uploadedCsvName = null;
          _status = 'Gagal memuat CSV: $e';
        });
      }
      return false;
    }
  }

  List<EvaluationRow> _parseCsvText(String text) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = const LineSplitter()
        .convert(normalized)
        .where((line) => line.trim().isNotEmpty)
        .toList();

    if (lines.length < 2) {
      throw Exception('CSV kosong atau hanya berisi header');
    }

    final headers = lines.first
        .split(',')
        .map((h) => h.trim().replaceFirst('﻿', ''))
        .toList();

    int idx(String name) => headers.indexOf(name);

    final recordIdIdx = idx('record_id');
    final centerSampleIdx = idx('center_sample');
    final annotationSymbolIdx = idx('annotation_symbol');
    final gtClassIdIdx = idx('gt_class_id');
    final gtClassNameIdx = idx('gt_class_name');
    final gtClassShortIdx = idx('gt_class_short');

    if ([
      recordIdIdx,
      centerSampleIdx,
      annotationSymbolIdx,
      gtClassIdIdx,
      gtClassNameIdx,
      gtClassShortIdx,
    ].contains(-1)) {
      throw Exception('Header metadata CSV tidak lengkap');
    }

    final rawIndexes = List<int>.generate(
      _modelWindowSamples,
      (i) => idx('raw_$i'),
    );
    final morphIndexes = List<int>.generate(37, (i) => idx('morph_$i'));

    if (rawIndexes.contains(-1) || morphIndexes.contains(-1)) {
      throw Exception(
        'Kolom raw_0..raw_${_modelWindowSamples - 1} atau morph_0..morph_36 tidak lengkap',
      );
    }

    final rows = <EvaluationRow>[];

    for (final line in lines.skip(1)) {
      final cols = line.split(',');
      if (cols.length < headers.length) {
        continue;
      }

      try {
        final raw = [for (final i in rawIndexes) double.parse(cols[i].trim())];
        final morph = [
          for (final i in morphIndexes) double.parse(cols[i].trim()),
        ];

        if (raw.length != _modelWindowSamples || morph.length != 37) {
          continue;
        }

        rows.add(
          EvaluationRow(
            recordId: cols[recordIdIdx].trim(),
            centerSample: int.tryParse(cols[centerSampleIdx].trim()) ?? 0,
            annotationSymbol: cols[annotationSymbolIdx].trim(),
            gtClassId: int.tryParse(cols[gtClassIdIdx].trim()) ?? 0,
            gtClassName: cols[gtClassNameIdx].trim(),
            gtClassShort: cols[gtClassShortIdx].trim(),
            raw: raw,
            morph: morph,
          ),
        );
      } catch (_) {
        continue;
      }
    }

    return rows;
  }

  void _loadRowIntoSignalBuffer(EvaluationRow row) {
    for (int i = 0; i < _signalBuffer.length; i++) {
      _signalBuffer[i] = 0.0;
    }

    final offset = max(0, _signalBuffer.length - row.raw.length);
    for (
      int i = 0;
      i < row.raw.length && (offset + i) < _signalBuffer.length;
      i++
    ) {
      _signalBuffer[offset + i] = row.raw[i];
    }
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
                  'Mode evaluasi memakai CSV berlabel untuk menguji model. Mode Bluetooth memakai Polar H10 untuk inferensi real-time dan pengukuran performa.',
                  style: TextStyle(color: T.txt2, fontSize: 14),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _activateSimulationMode();
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: T.txt,
                          side: const BorderSide(color: T.brd),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.upload_file_rounded, size: 18),
                        label: const Text('Upload & Evaluasi'),
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
                        label: const Text('Bluetooth'),
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
        final alreadyConnected =
            msg.contains('already connected') ||
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
        throw Exception(
          'Characteristic Heart Rate Measurement tidak ditemukan',
        );
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

    final effectiveRrMs = rrMs > 0 ? rrMs : _rrIntervalMs;

    if (_isRunning && !_isSimulationMode) {
      _signalBuffer.removeAt(0);
      _signalBuffer.add(hr.toDouble());
      if (!_isCalibrating) {
        _hrPacketCount++;
        _beatsProcessed = _hrPacketCount;
        _detectedRPeaks = _hrPacketCount;
      }
    }

    final fallbackClass = _classifyLiveBeat(hr: hr, rrMs: effectiveRrMs);

    if (!mounted) return;
    setState(() {
      _heartRate = hr;
      if (effectiveRrMs > 0) {
        _rrIntervalMs = effectiveRrMs;
      }

      if (_isRunning && !_isSimulationMode && !_isCalibrating) {
        _status = _isBluetoothInferenceBusy
            ? 'Bluetooth aktif - Menyelesaikan inferensi sebelumnya'
            : 'Bluetooth aktif - Menjalankan inferensi model';
      } else {
        _status = _isCalibrating
            ? 'Stabilisasi sinyal Bluetooth... $_calibrationSecondsLeft detik'
            : 'Sensor terhubung: $_sensorName';
      }
    });

    if (_isRunning && !_isSimulationMode && !_isCalibrating) {
      unawaited(
        _runBluetoothInference(
          hr: hr,
          rrMs: effectiveRrMs,
          fallbackClass: fallbackClass,
        ),
      );
    }
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
      _isBluetoothInferenceBusy = false;
      _chartBeatFrames = [];
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
                  'Aplikasi sedang mencari Polar H10 untuk mode Bluetooth real-time.',
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
                  'Nyalakan Bluetooth terlebih dahulu untuk menjalankan mode sensor Polar H10, atau lanjutkan dengan mode evaluasi CSV.',
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
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _activateSimulationMode();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Upload CSV'),
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
                  'Pastikan Polar H10 aktif dan dapat dipindai, lalu coba lagi atau jalankan mode evaluasi CSV.',
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
                        onPressed: () async {
                          Navigator.of(sheetCtx).pop();
                          await _activateSimulationMode();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: T.green,
                          foregroundColor: T.bg,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Upload CSV'),
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

  void _startCalibrationPhase() {
    _calibrationTimer?.cancel();
    if (_isSimulationMode) {
      setState(() {
        _isCalibrating = false;
        _calibrationSecondsLeft = 0;
      });
      _startActiveSessionTimers();
      return;
    }

    setState(() {
      _isCalibrating = true;
      _calibrationSecondsLeft = _stabilizationSeconds;
      _status =
          'Stabilisasi sinyal Bluetooth... $_calibrationSecondsLeft detik';
    });
    unawaited(_readCpuUsage());

    _calibrationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_isRunning) {
        timer.cancel();
        return;
      }

      if (_calibrationSecondsLeft <= 1) {
        timer.cancel();
        setState(() {
          _isCalibrating = false;
          _calibrationSecondsLeft = 0;
        });
        _startActiveSessionTimers();
        return;
      }

      setState(() {
        _calibrationSecondsLeft -= 1;
        _status =
            'Stabilisasi sinyal Bluetooth... $_calibrationSecondsLeft detik';
      });
    });
  }

  void _startActiveSessionTimers() {
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();
    _inferenceTimer?.cancel();

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _sessionSeconds++;
      final mm = (_sessionSeconds ~/ 60).toString().padLeft(2, '0');
      final ss = (_sessionSeconds % 60).toString().padLeft(2, '0');
      if (mounted) {
        setState(() {
          _duration = '$mm:$ss';
        });
      }
    });

    _cpuTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_readCpuUsage());
    });
    unawaited(_readCpuUsage());

    if (_isSimulationMode) {
      _status = 'Mode evaluasi aktif · Menjalankan inferensi';
      unawaited(_runStreamingInference());
      _inferenceTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
        unawaited(_runStreamingInference());
      });
    } else {
      _status = 'Bluetooth aktif · Menunggu data sensor';
    }
  }

  String _buildEvaluationExplanation({
    required String predictedShort,
    required String gtShort,
    required bool isCorrect,
  }) {
    final base = _buildExplanationText(
      predictedShort: predictedShort,
      isBluetoothMode: false,
    );

    final compareText = isCorrect
        ? 'Prediksi sesuai dengan ground truth dari file CSV.'
        : 'Prediksi tidak sesuai dengan ground truth ($gtShort) pada sampel ini.';

    return '$base $compareText';
  }

  void _startSession() {
    if (_interpreter == null) {
      setState(() => _status = 'Model belum siap');
      return;
    }

    if (_isRunning) return;

    if (_isSimulationMode) {
      if (!_hasUploadedCsv || _evaluationRows.isEmpty) {
        setState(() {
          _status = 'Upload file CSV ground truth terlebih dahulu';
        });
        return;
      }
    } else if (!_isPolarConnected) {
      setState(() => _status = 'Sensor Bluetooth belum tersambung');
      return;
    }

    _resetSessionState();
    _startCalibrationPhase();
  }

  void _resetSessionState() {
    for (int i = 0; i < _signalBuffer.length; i++) {
      _signalBuffer[i] = _isSimulationMode
          ? 0.0
          : (_heartRate > 0 ? _heartRate.toDouble() : 0.0);
    }

    if (_isSimulationMode && _evaluationRows.isNotEmpty) {
      _loadRowIntoSignalBuffer(_evaluationRows.first);
    }

    _lastFilteredLive = 0.0;
    _prevLive1 = 0.0;
    _prevLive2 = 0.0;
    _liveSampleIndex = 0;
    _lastPeakIndex = -1000;
    _recentPeakIndices.clear();

    setState(() {
      _isRunning = true;
      _isCalibrating = false;
      _calibrationSecondsLeft = _isSimulationMode ? 0 : _stabilizationSeconds;
      _tick = 0;
      _sessionSeconds = 0;
      _duration = '00:00';
      _hrPacketCount = 0;
      _isBluetoothInferenceBusy = false;

      _lastPredictionClass = '—';
      _lastPredictionShort = '—';
      _predictionConfidence = 0.0;
      _lastInferenceMs = 0.0;
      _lastCpuAtInference = 0.0;
      _chartBeatFrames = [];
      _currentGroundTruthShort = '—';
      _currentGroundTruthLong = '—';
      _explanationText = _isSimulationMode
          ? 'Menunggu inferensi dari file evaluasi.'
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

      _evalCorrect = 0;
      _evalWrong = 0;
      _evalTotal = 0;
      _evalAccuracy = 0.0;
      _currentEvalIndex = 0;

      if (_isSimulationMode) {
        _status = 'Mode evaluasi siap · Memulai inferensi';
      } else {
        _status = 'Bluetooth siap · Menunggu stabilisasi sinyal';
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
    _calibrationTimer?.cancel();

    _simulationTimer = null;
    _inferenceTimer = null;
    _sessionTimer = null;
    _cpuTimer = null;
    _calibrationTimer = null;

    if (mounted) {
      setState(() {
        _isRunning = false;
        _isCalibrating = false;
        _isBluetoothInferenceBusy = false;
      });
    }

    if (showSummary) {
      final canShowSummary = _isSimulationMode
          ? _evalTotal > 0
          : (_isPolarConnected ||
                _sensorName != '—' ||
                _lastPredictionShort != '—');

      if (canShowSummary) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showSessionSummaryDrawer();
        });
      }
    }
  }

  void _showSessionSummaryDrawer() {
    if (!mounted) return;

    final title = _isSimulationMode
        ? 'Sesi evaluasi selesai'
        : 'Sesi Bluetooth selesai';

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
                      child: const Icon(Icons.insights_rounded, color: T.green),
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
                _SummaryLine(
                  'Mode',
                  _isSimulationMode ? 'Evaluasi CSV' : 'Bluetooth',
                ),
                if (_isSimulationMode && _uploadedCsvName != null)
                  _SummaryLine('File CSV', _uploadedCsvName!),
                _SummaryLine('Klasifikasi terakhir', _lastPredictionClass),
                if (_isSimulationMode)
                  _SummaryLine('Ground truth', _groundTruthLabel),
                _SummaryLine(
                  'Confidence',
                  _predictionConfidence > 0
                      ? '${(100 * _predictionConfidence).toStringAsFixed(1)}%'
                      : '—',
                ),
                _SummaryLine(
                  'Waktu inferensi terakhir',
                  _lastInferenceMs > 0
                      ? '${_lastInferenceMs.toStringAsFixed(3)} ms'
                      : '—',
                ),
                _SummaryLine(
                  'CPU saat prediksi',
                  _formatCpuValue(_lastCpuAtInference),
                ),
                if (_isSimulationMode) ...[
                  _SummaryLine(
                    'Total sampel',
                    '$_evalTotal / ${_evaluationRows.length}',
                  ),
                  _SummaryLine('Benar', '$_evalCorrect'),
                  _SummaryLine('Salah', '$_evalWrong'),
                  _SummaryLine(
                    'Akurasi',
                    '${(_evalAccuracy * 100).toStringAsFixed(1)}%',
                  ),
                ],
                if (!_isSimulationMode) ...[
                  _SummaryLine(
                    'Sensor',
                    _isPolarConnected ? _sensorName : 'Belum tersambung',
                  ),
                  _SummaryLine('Data sensor', _bluetoothReferenceLabel),
                  _SummaryLine(
                    'Distribusi dominan sesi',
                    _dominantClassFromCounts(_classCounts),
                  ),
                ],
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
                    !_isSimulationMode
                        ? 'Catatan mode:\n'
                              'Mode Bluetooth memakai sinyal live sensor tanpa label referensi sehingga ringkasan ini tidak menghitung tingkat ketepatan. Ringkasan ini difokuskan pada prediksi live, waktu inferensi, CPU, dan kestabilan sensor.'
                        : 'Penjelasan hasil:\n$_explanationText\n\n'
                              'Ground truth:\n$_groundTruthCaption',
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

  bool _isValidCpuUsage(double? value) {
    return value != null &&
        value.isFinite &&
        !value.isNaN &&
        value >= 0 &&
        value <= 100;
  }

  String _formatCpuValue(
    double value, {
    int decimals = 2,
    bool compact = false,
    String unavailable = '—',
  }) {
    if (!_isValidCpuUsage(value)) return unavailable;
    final suffix = compact ? '%' : ' %';
    return '${value.toStringAsFixed(decimals)}$suffix';
  }

  Future<double?> _sampleCpuUsageSafe() async {
    double? cpu;

    try {
      final value = await _perfChannel.invokeMethod<double>('getCpuUsage');
      if (_isValidCpuUsage(value)) cpu = value;
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
          if (total > 0) {
            final sampled = (busy / total) * 100.0;
            if (_isValidCpuUsage(sampled)) cpu = sampled;
          }
        }
      } catch (_) {}
    }

    return cpu;
  }

  Future<void> _readCpuUsage() async {
    final cpu = await _sampleCpuUsageSafe();
    final rssMb = _readMemoryUsageMb();

    if (!mounted) return;

    setState(() {
      _updateMemoryStats(rssMb: rssMb);
      if (cpu != null) {
        _updateCpuStats(cpu);
      }
    });
  }

  void _updateSimulationSignal() {
    // Legacy dummy simulation is no longer used.
  }

  Future<void> _runStreamingInference() async {
    if (_interpreter == null || !_isSimulationMode || _isCalibrating) return;
    if (_currentEvalIndex >= _evaluationRows.length) {
      _stopSession(showSummary: true);
      return;
    }

    try {
      final row = _evaluationRows[_currentEvalIndex];
      _loadRowIntoSignalBuffer(row);

      final rawInput = [
        row.raw.map((v) => [v]).toList(),
      ];
      final morphInput = [row.morph];

      final inputs = [rawInput, morphInput];
      final output = {0: List.generate(1, (_) => List.filled(5, 0.0))};

      final sw = Stopwatch()..start();
      _interpreter!.runForMultipleInputs(inputs, output);
      sw.stop();

      final latencyMs = sw.elapsedMicroseconds / 1000.0;
      _latencyHistoryMs.add(latencyMs);
      _updateLatencyStats();
      _updateMemoryStats();
      final cpuAtInference = await _sampleCpuUsageSafe();

      final probs = (output[0] as List<List<double>>)[0];
      int bestIdx = 0;
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > probs[bestIdx]) bestIdx = i;
      }

      final predictedClass = _classNames[bestIdx];
      final predictedShort = _classShort[predictedClass] ?? '—';
      final confidence = probs[bestIdx].clamp(0.0, 1.0);
      final isCorrect = predictedClass == row.gtClassName;

      _totalInferenceRuns++;
      _evalTotal++;
      if (isCorrect) {
        _evalCorrect++;
      } else {
        _evalWrong++;
      }
      _evalAccuracy = _evalTotal == 0 ? 0.0 : _evalCorrect / _evalTotal;
      _beatsProcessed = _evalTotal;
      _detectedRPeaks = _evalTotal;
      _throughput = _sessionSeconds > 0
          ? _totalInferenceRuns / _sessionSeconds
          : 0;

      _incrementCountForShortClass(predictedShort);

      if (!mounted) return;
      setState(() {
        _pushChartBeatFrame(_buildCsvChartBeatFrame(row, predictedShort));
        _lastPredictionClass = predictedClass;
        _lastPredictionShort = predictedShort;
        _predictionConfidence = confidence;
        _lastInferenceMs = latencyMs;
        if (cpuAtInference != null) {
          _lastCpuAtInference = cpuAtInference;
          _updateCpuStats(cpuAtInference);
        }
        _currentGroundTruthShort = row.gtClassShort;
        _currentGroundTruthLong = row.gtClassName;
        _explanationText = _buildEvaluationExplanation(
          predictedShort: predictedShort,
          gtShort: row.gtClassShort,
          isCorrect: isCorrect,
        );
        _status =
            'Mode evaluasi aktif · Pred $predictedShort vs GT ${row.gtClassShort}';
      });

      _currentEvalIndex++;
      if (_currentEvalIndex >= _evaluationRows.length) {
        Future.microtask(() => _stopSession(showSummary: true));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Kesalahan inferensi: $e');
    }
  }

  Future<void> _runBluetoothInference({
    required int hr,
    required int rrMs,
    required Map<String, String> fallbackClass,
  }) async {
    if (_interpreter == null ||
        !_isRunning ||
        _isSimulationMode ||
        _isCalibrating ||
        _isBluetoothInferenceBusy) {
      return;
    }

    _isBluetoothInferenceBusy = true;

    try {
      final rawWindow = _buildLiveRawWindow();
      final morph = _buildLiveMorphFeatures(
        rawWindow: rawWindow,
        hr: hr,
        rrMs: rrMs,
      );

      final rawInput = [
        rawWindow.map((v) => [v]).toList(),
      ];
      final morphInput = [morph];
      final output = {0: List.generate(1, (_) => List.filled(5, 0.0))};

      final sw = Stopwatch()..start();
      _interpreter!.runForMultipleInputs([rawInput, morphInput], output);
      sw.stop();

      final latencyMs = sw.elapsedMicroseconds / 1000.0;
      _latencyHistoryMs.add(latencyMs);
      _updateLatencyStats();
      _updateMemoryStats();
      final cpuAtInference = await _sampleCpuUsageSafe();

      final probs = (output[0] as List<List<double>>)[0];
      int bestIdx = 0;
      for (int i = 1; i < probs.length; i++) {
        if (probs[i] > probs[bestIdx]) bestIdx = i;
      }

      final predictedClass = _classNames[bestIdx];
      final predictedShort =
          _classShort[predictedClass] ?? fallbackClass['short']!;
      final confidence = probs[bestIdx].clamp(0.0, 1.0);

      _totalInferenceRuns++;
      _throughput = _sessionSeconds > 0
          ? _totalInferenceRuns / _sessionSeconds
          : 0;
      _incrementCountForShortClass(predictedShort);

      if (!mounted) return;
      setState(() {
        _pushChartBeatFrame(
          _buildSyntheticChartBeatFrame(shortClass: predictedShort, rrMs: rrMs),
        );
        _lastPredictionClass = predictedClass;
        _lastPredictionShort = predictedShort;
        _predictionConfidence = confidence;
        _lastInferenceMs = latencyMs;
        if (cpuAtInference != null) {
          _lastCpuAtInference = cpuAtInference;
          _updateCpuStats(cpuAtInference);
        }
        _explanationText = _buildExplanationText(
          predictedShort: predictedShort,
          isBluetoothMode: true,
        );
        _status = 'Bluetooth aktif - Inferensi $predictedShort';
      });
    } catch (_) {
      final predictedShort = fallbackClass['short'] ?? 'Q';
      final predictedClass = fallbackClass['full'] ?? 'Unknown';

      _totalInferenceRuns++;
      _throughput = _sessionSeconds > 0
          ? _totalInferenceRuns / _sessionSeconds
          : 0;
      _incrementCountForShortClass(predictedShort);
      final cpuAtInference = await _sampleCpuUsageSafe();

      if (!mounted) return;
      setState(() {
        _pushChartBeatFrame(
          _buildSyntheticChartBeatFrame(shortClass: predictedShort, rrMs: rrMs),
        );
        _lastPredictionClass = predictedClass;
        _lastPredictionShort = predictedShort;
        _predictionConfidence = 0.0;
        if (cpuAtInference != null) {
          _lastCpuAtInference = cpuAtInference;
          _updateCpuStats(cpuAtInference);
        }
        _explanationText = _buildExplanationText(
          predictedShort: predictedShort,
          isBluetoothMode: true,
        );
        _status = 'Bluetooth aktif - Fallback $predictedShort';
      });
    } finally {
      _isBluetoothInferenceBusy = false;
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
      return 'Mode Bluetooth memakai sinyal live sensor tanpa label referensi. Hasil ini menampilkan prediksi model TFLite, waktu inferensi, dan CPU berdasarkan buffer sinyal live dari paket HR/RR sensor.';
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

  Map<String, String> _classifyLiveBeat({required int hr, required int rrMs}) {
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

  double _readMemoryUsageMb() {
    try {
      return ProcessInfo.currentRss / (1024 * 1024);
    } catch (_) {
      return _ramCurrentMb;
    }
  }

  void _updateMemoryStats({double? rssMb}) {
    final value = rssMb ?? _readMemoryUsageMb();
    _ramCurrentMb = value;
    if (_ramMinMb == 0 || value < _ramMinMb) _ramMinMb = value;
    if (value > _ramMaxMb) _ramMaxMb = value;
  }

  void _updateCpuStats(double cpu) {
    if (!_isValidCpuUsage(cpu)) return;
    _cpuCurrent = cpu;
    if (_cpuMin == 0 || cpu < _cpuMin) _cpuMin = cpu;
    if (cpu > _cpuMax) _cpuMax = cpu;
  }

  List<double> _buildLiveRawWindow() {
    const windowSize = _modelWindowSamples;
    final start = max(0, _signalBuffer.length - windowSize);
    final window = List<double>.from(_signalBuffer.sublist(start));

    while (window.length < windowSize) {
      window.insert(0, window.isEmpty ? 0.0 : window.first);
    }

    final mean = window.reduce((a, b) => a + b) / window.length;
    final variance =
        window.map((v) => pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) /
        window.length;
    final std = sqrt(variance);
    final scale = std < 1e-6 ? 1.0 : std;

    return [for (final value in window) (value - mean) / scale];
  }

  List<double> _buildLiveMorphFeatures({
    required List<double> rawWindow,
    required int hr,
    required int rrMs,
  }) {
    final sorted = List<double>.from(rawWindow)..sort();
    final diffs = <double>[
      for (int i = 1; i < rawWindow.length; i++)
        rawWindow[i] - rawWindow[i - 1],
    ];
    final mean = rawWindow.reduce((a, b) => a + b) / rawWindow.length;
    final variance =
        rawWindow
            .map((v) => pow(v - mean, 2).toDouble())
            .reduce((a, b) => a + b) /
        rawWindow.length;
    final std = sqrt(variance);
    final minVal = sorted.first;
    final maxVal = sorted.last;
    final range = maxVal - minVal;
    final median = sorted[sorted.length ~/ 2];
    final p10 = sorted[((sorted.length - 1) * 0.10).round()];
    final p25 = sorted[((sorted.length - 1) * 0.25).round()];
    final p75 = sorted[((sorted.length - 1) * 0.75).round()];
    final p90 = sorted[((sorted.length - 1) * 0.90).round()];
    final rms = sqrt(
      rawWindow.map((v) => v * v).reduce((a, b) => a + b) / rawWindow.length,
    );
    final meanAbs =
        rawWindow.map((v) => v.abs()).reduce((a, b) => a + b) /
        rawWindow.length;
    final energy =
        rawWindow.map((v) => v * v).reduce((a, b) => a + b) / rawWindow.length;
    final diffMean = diffs.reduce((a, b) => a + b) / diffs.length;
    final diffVariance =
        diffs
            .map((v) => pow(v - diffMean, 2).toDouble())
            .reduce((a, b) => a + b) /
        diffs.length;
    final diffStd = sqrt(diffVariance);
    final diffAbsMean =
        diffs.map((v) => v.abs()).reduce((a, b) => a + b) / diffs.length;

    int zeroCrossings = 0;
    for (int i = 1; i < diffs.length; i++) {
      final previous = diffs[i - 1];
      final current = diffs[i];
      if ((previous <= 0 && current > 0) || (previous >= 0 && current < 0)) {
        zeroCrossings++;
      }
    }

    int peakCount = 0;
    int troughCount = 0;
    for (int i = 1; i < rawWindow.length - 1; i++) {
      if (rawWindow[i] > rawWindow[i - 1] && rawWindow[i] > rawWindow[i + 1]) {
        peakCount++;
      }
      if (rawWindow[i] < rawWindow[i - 1] && rawWindow[i] < rawWindow[i + 1]) {
        troughCount++;
      }
    }

    final half = rawWindow.length ~/ 2;
    final left = rawWindow.sublist(0, half);
    final right = rawWindow.sublist(half);
    final leftMean = left.reduce((a, b) => a + b) / left.length;
    final rightMean = right.reduce((a, b) => a + b) / right.length;
    final centerStart = max(0, half - 5);
    final centerEnd = min(rawWindow.length, half + 5);
    final centerSlice = rawWindow.sublist(centerStart, centerEnd);
    final centerMean = centerSlice.reduce((a, b) => a + b) / centerSlice.length;
    final lag1 = _autocorrelation(rawWindow, 1);
    final lag2 = _autocorrelation(rawWindow, 2);
    final slope = (rawWindow.last - rawWindow.first) / (rawWindow.length - 1);
    final positiveRatio =
        rawWindow.where((v) => v > 0).length / rawWindow.length;
    final consistency = rrMs > 0 ? ((hr * rrMs) / 60000.0) : 0.0;

    return [
      mean,
      std,
      minVal,
      maxVal,
      range,
      median,
      p10,
      p25,
      p75,
      p90,
      rms,
      meanAbs,
      energy,
      diffMean,
      diffStd,
      diffAbsMean,
      diffs.reduce(min),
      diffs.reduce(max),
      zeroCrossings / diffs.length,
      positiveRatio,
      peakCount / rawWindow.length,
      troughCount / rawWindow.length,
      rawWindow.first,
      rawWindow[half],
      rawWindow.last,
      leftMean,
      rightMean,
      rightMean - leftMean,
      lag1,
      lag2,
      slope,
      hr / 200.0,
      rrMs / 2000.0,
      consistency,
      centerMean,
      rawWindow.map((v) => v.abs()).reduce(max),
      variance,
    ];
  }

  double _autocorrelation(List<double> values, int lag) {
    if (lag <= 0 || lag >= values.length) return 0.0;

    final mean = values.reduce((a, b) => a + b) / values.length;
    double numerator = 0.0;
    double denominator = 0.0;

    for (int i = 0; i < values.length; i++) {
      final centered = values[i] - mean;
      denominator += centered * centered;
      if (i + lag < values.length) {
        numerator += centered * (values[i + lag] - mean);
      }
    }

    if (denominator == 0.0) return 0.0;
    return numerator / denominator;
  }

  void _pushChartBeatFrame(ChartBeatFrame frame) {
    _chartBeatFrames.add(frame);
    if (_chartBeatFrames.length > _chartHistoryBeats) {
      _chartBeatFrames.removeRange(
        0,
        _chartBeatFrames.length - _chartHistoryBeats,
      );
    }
  }

  ChartBeatFrame _buildCsvChartBeatFrame(EvaluationRow row, String shortClass) {
    final normalized = _normalizeEcgSamples(row.raw);
    final samples = _resampleSignal(normalized, _chartBeatSamples);
    return ChartBeatFrame(
      samples: samples,
      rPeakIndex: _findRPeakIndex(samples),
      shortClass: shortClass,
    );
  }

  ChartBeatFrame _buildSyntheticChartBeatFrame({
    required String shortClass,
    int rrMs = 0,
  }) {
    final sampleCount = (rrMs > 0 ? (rrMs / 14).round() : _chartBeatSamples)
        .clamp(72, 112);
    final profile = switch (shortClass) {
      'S' => {
        'pAmp': 0.17,
        'qAmp': -0.12,
        'rAmp': 0.92,
        'sAmp': -0.26,
        'tAmp': 0.28,
        'rSigma': 0.015,
        'tCenter': 0.72,
      },
      'V' => {
        'pAmp': 0.06,
        'qAmp': -0.08,
        'rAmp': 1.18,
        'sAmp': -0.48,
        'tAmp': 0.16,
        'rSigma': 0.024,
        'tCenter': 0.76,
      },
      'F' => {
        'pAmp': 0.12,
        'qAmp': -0.10,
        'rAmp': 0.88,
        'sAmp': -0.24,
        'tAmp': 0.24,
        'rSigma': 0.018,
        'tCenter': 0.73,
      },
      'Q' => {
        'pAmp': 0.09,
        'qAmp': -0.08,
        'rAmp': 0.72,
        'sAmp': -0.20,
        'tAmp': 0.18,
        'rSigma': 0.017,
        'tCenter': 0.74,
      },
      _ => {
        'pAmp': 0.14,
        'qAmp': -0.12,
        'rAmp': 1.00,
        'sAmp': -0.30,
        'tAmp': 0.32,
        'rSigma': 0.014,
        'tCenter': 0.73,
      },
    };

    double gaussian(double x, double center, double sigma, double amplitude) {
      final variance = sigma * sigma * 2;
      return amplitude * exp(-pow(x - center, 2) / variance);
    }

    final samples = List<double>.generate(sampleCount, (i) {
      final x = i / (sampleCount - 1);
      final baseline = 0.01 * sin(x * pi * 2.2);
      return baseline +
          gaussian(x, 0.18, 0.045, profile['pAmp']!) +
          gaussian(x, 0.37, 0.014, profile['qAmp']!) +
          gaussian(x, 0.40, profile['rSigma']!, profile['rAmp']!) +
          gaussian(x, 0.435, 0.016, profile['sAmp']!) +
          gaussian(x, profile['tCenter']!, 0.085, profile['tAmp']!);
    });

    final normalized = _normalizeEcgSamples(samples);
    return ChartBeatFrame(
      samples: normalized,
      rPeakIndex: _findRPeakIndex(normalized),
      shortClass: shortClass,
    );
  }

  List<double> _normalizeEcgSamples(List<double> raw) {
    if (raw.isEmpty) return const [0.0];

    final mean = raw.reduce((a, b) => a + b) / raw.length;
    final centered = [for (final value in raw) value - mean];
    final maxAbs = centered.fold<double>(
      0.0,
      (best, value) => max(best, value.abs()),
    );
    if (maxAbs < 1e-6) return List<double>.filled(raw.length, 0.0);

    final normalized = [for (final value in centered) (value / maxAbs) * 0.98];
    return List<double>.generate(normalized.length, (i) {
      if (i == 0 || i == normalized.length - 1) return normalized[i];
      return (normalized[i - 1] * 0.08) +
          (normalized[i] * 0.84) +
          (normalized[i + 1] * 0.08);
    });
  }

  List<double> _resampleSignal(List<double> source, int targetLength) {
    if (source.isEmpty) return List<double>.filled(targetLength, 0.0);
    if (source.length == 1) {
      return List<double>.filled(targetLength, source.first);
    }
    if (source.length == targetLength) return List<double>.from(source);

    return List<double>.generate(targetLength, (i) {
      final position = (i * (source.length - 1)) / (targetLength - 1);
      final left = position.floor();
      final right = min(source.length - 1, left + 1);
      final fraction = position - left;
      return (source[left] * (1 - fraction)) + (source[right] * fraction);
    });
  }

  int _findRPeakIndex(List<double> samples) {
    if (samples.isEmpty) return 0;
    int bestIndex = 0;
    double bestValue = samples.first;
    for (int i = 1; i < samples.length; i++) {
      if (samples[i] > bestValue) {
        bestValue = samples[i];
        bestIndex = i;
      }
    }
    return bestIndex;
  }

  ChartBeatFrame? _previewChartBeatFrame() {
    if (_isSimulationMode && _evaluationRows.isNotEmpty) {
      final previewIndex = min(_currentEvalIndex, _evaluationRows.length - 1);
      final row = _evaluationRows[previewIndex];
      final shortClass = _lastPredictionShort != '—'
          ? _lastPredictionShort
          : row.gtClassShort;
      return _buildCsvChartBeatFrame(row, shortClass);
    }

    if (!_isSimulationMode && _lastPredictionShort != '—') {
      return _buildSyntheticChartBeatFrame(
        shortClass: _lastPredictionShort,
        rrMs: _rrIntervalMs,
      );
    }

    return null;
  }

  ChartSeriesData _buildChartSeriesData() {
    final previewFrame = _previewChartBeatFrame();
    final frames = _chartBeatFrames.isNotEmpty
        ? _chartBeatFrames
        : (previewFrame == null ? const <ChartBeatFrame>[] : [previewFrame]);

    if (frames.isEmpty) {
      return const ChartSeriesData(spots: [], beatTags: []);
    }

    final spots = <FlSpot>[];
    final beatTags = <BluetoothBeatTag>[];
    int cursor = 0;

    for (int frameIndex = 0; frameIndex < frames.length; frameIndex++) {
      final frame = frames[frameIndex];
      for (int i = 0; i < frame.samples.length; i++) {
        spots.add(FlSpot((cursor + i).toDouble(), frame.samples[i]));
      }

      beatTags.add(
        BluetoothBeatTag(
          sampleIndex: cursor + frame.rPeakIndex,
          shortClass: frame.shortClass,
        ),
      );

      cursor += frame.samples.length;
      if (frameIndex == frames.length - 1) continue;

      for (int gap = 0; gap < _chartBeatGapSamples; gap++) {
        spots.add(FlSpot((cursor + gap).toDouble(), 0.0));
      }
      cursor += _chartBeatGapSamples;
    }

    return ChartSeriesData(spots: spots, beatTags: beatTags);
  }

  double _chartMinYFor(List<FlSpot> spots) {
    if (spots.isEmpty) return -1.15;
    final minValue = spots
        .map((spot) => spot.y)
        .reduce((value, next) => min(value, next));
    return minValue - 0.18;
  }

  double _chartMaxYFor(List<FlSpot> spots) {
    if (spots.isEmpty) return 1.2;
    final maxValue = spots
        .map((spot) => spot.y)
        .reduce((value, next) => max(value, next));
    return maxValue + 0.28;
  }

  List<Widget> _buildBeatClassOverlays({
    required double chartWidth,
    required double chartHeight,
    required List<FlSpot> spots,
    required List<BluetoothBeatTag> beatTags,
    required double minY,
    required double maxY,
  }) {
    if (spots.isEmpty || beatTags.isEmpty) {
      return const [];
    }

    final xMax = max(1, spots.length - 1).toDouble();
    final ySpan = max(0.001, maxY - minY);
    final overlays = <Widget>[];

    for (final tag in beatTags) {
      final localIndex = tag.sampleIndex;
      if (localIndex < 0 || localIndex >= spots.length) {
        continue;
      }

      final spot = spots[localIndex];
      final dx = (spot.x / xMax) * chartWidth;
      final normalizedY = (maxY - spot.y) / ySpan;
      final dy = (normalizedY * chartHeight) - 28;

      overlays.add(
        Positioned(
          left: dx - 14,
          top: dy.clamp(4.0, chartHeight - 34.0).toDouble(),
          child: _SignalClassBadge(shortClass: tag.shortClass),
        ),
      );
    }

    return overlays;
  }

  int get _totalBeats => _classCounts.values.fold(0, (a, b) => a + b);

  String get _groundTruthLabel {
    if (!_isSimulationMode) return 'Tidak digunakan pada mode Bluetooth';

    if (_currentGroundTruthShort == '—' || _currentGroundTruthLong == '—') {
      return '—';
    }
    return '$_currentGroundTruthLong ($_currentGroundTruthShort)';
  }

  String get _groundTruthCaption {
    if (!_isSimulationMode) {
      return 'Ground truth hanya digunakan pada mode evaluasi CSV, bukan mode Bluetooth.';
    }

    return 'Ground truth berasal dari file CSV evaluasi yang di-upload pengguna.';
  }

  String get _bluetoothReferenceLabel {
    if (_isSimulationMode) {
      return '—';
    }

    final hrText = _heartRate > 0 ? 'HR $_heartRate bpm' : 'HR —';
    final rrText = _rrIntervalMs > 0 ? 'RR $_rrIntervalMs ms' : 'RR —';
    final liveDominant = _dominantClassFromCounts(_classCounts);
    return '$hrText · $rrText · Distribusi dominan sesi $liveDominant';
  }

  String get _modeLabel {
    if (_isPolarConnected && !_isSimulationMode) {
      return _sensorName != '—'
          ? _sensorName.toUpperCase()
          : 'BLUETOOTH REAL-TIME';
    }

    if (_isSimulationMode) {
      return 'EVALUASI CSV';
    }

    return 'MONITORING ECG';
  }

  String _shortFileName(String name) {
    if (name.length <= 22) return name;
    return '${name.substring(0, 19)}...';
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

  Map<String, int> get _referenceDatasetCounts {
    final counts = {
      'Normal': 0,
      'SVEB': 0,
      'VEB': 0,
      'Fusion': 0,
      'Unknown': 0,
    };

    for (final row in _evaluationRows) {
      final key = row.gtClassName;
      if (counts.containsKey(key)) {
        counts[key] = counts[key]! + 1;
      }
    }

    return counts;
  }

  int get _referenceDatasetTotal {
    return _referenceDatasetCounts.values.fold(0, (a, b) => a + b);
  }

  String _dominantClassFromCounts(Map<String, int> counts) {
    String bestClass = '—';
    int bestCount = -1;

    counts.forEach((key, value) {
      if (value > bestCount) {
        bestClass = key;
        bestCount = value;
      }
    });

    return bestClass;
  }

  double _classPercent(Map<String, int> counts, String className) {
    final total = counts.values.fold(0, (a, b) => a + b);
    if (total == 0) return 0.0;
    return ((counts[className] ?? 0) / total) * 100.0;
  }

  String get _bluetoothDatasetReferenceLabel {
    if (_evaluationRows.isEmpty) {
      return 'Dataset referensi belum di-upload';
    }

    final dominant = _dominantClassFromCounts(_referenceDatasetCounts);
    final percent = _classPercent(_referenceDatasetCounts, dominant);
    final fileName = _uploadedCsvName ?? 'CSV referensi';

    return '$fileName · Dominan $dominant (${percent.toStringAsFixed(1)}%)';
  }

  String get _bluetoothComparisonCaption {
    if (_evaluationRows.isEmpty) {
      return 'Belum ada dataset referensi yang di-upload, sehingga justifikasi Bluetooth masih terbatas pada hasil live sensor.';
    }

    final liveDominant = _dominantClassFromCounts(_classCounts);
    final refDominant = _dominantClassFromCounts(_referenceDatasetCounts);
    final livePercent = _classPercent(_classCounts, liveDominant);
    final refPercent = _classPercent(_referenceDatasetCounts, refDominant);

    return 'Sesi Bluetooth dibandingkan secara agregat dengan dataset referensi yang di-upload. '
        'Distribusi live didominasi $liveDominant (${livePercent.toStringAsFixed(1)}%), '
        'sedangkan dataset referensi didominasi $refDominant (${refPercent.toStringAsFixed(1)}%). '
        'Perbandingan ini dipakai sebagai justifikasi pola, bukan ground truth beat-per-beat.';
  }

  @override
  void dispose() {
    _simulationTimer?.cancel();
    _inferenceTimer?.cancel();
    _sessionTimer?.cancel();
    _cpuTimer?.cancel();
    _calibrationTimer?.cancel();

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
          border: Border(top: BorderSide(color: T.brd)),
        ),
        child: Row(
          children: [
            Expanded(child: _RefreshButton(onTap: _refreshSensorFlow)),
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
    final chartData = _buildChartSeriesData();
    final chartSpots = chartData.spots;
    final minY = _chartMinYFor(chartSpots);
    final maxY = _chartMaxYFor(chartSpots);

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
            height: _isSimulationMode ? 198 : 228,
            decoration: BoxDecoration(
              color: T.card2,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: T.brd),
            ),
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final chartWidth = _isSimulationMode
                          ? constraints.maxWidth
                          : max(
                              constraints.maxWidth,
                              max(560.0, chartSpots.length * 1.8),
                            );

                      final chart = SizedBox(
                        width: chartWidth,
                        height: constraints.maxHeight,
                        child: Stack(
                          children: [
                            LineChart(
                              LineChartData(
                                minX: 0,
                                maxX: max(0, chartSpots.length - 1).toDouble(),
                                minY: minY,
                                maxY: maxY,
                                clipData: const FlClipData.all(),
                                lineTouchData: const LineTouchData(
                                  enabled: false,
                                ),
                                gridData: FlGridData(
                                  show: true,
                                  drawVerticalLine: true,
                                  verticalInterval: _isSimulationMode ? 24 : 14,
                                  horizontalInterval: 0.25,
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
                                  border: Border.all(
                                    color: const Color(0x18FFFFFF),
                                  ),
                                ),
                                lineBarsData: [
                                  LineChartBarData(
                                    spots: chartSpots,
                                    isCurved: false,
                                    curveSmoothness: 0,
                                    color: T.green,
                                    barWidth: _isSimulationMode ? 2.1 : 2.0,
                                    isStrokeCapRound: false,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      gradient: const LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [
                                          Color(0x2600D09E),
                                          Color(0x0400D09E),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              duration: Duration.zero,
                              curve: Curves.linear,
                            ),
                            ..._buildBeatClassOverlays(
                              chartWidth: chartWidth,
                              chartHeight: constraints.maxHeight,
                              spots: chartSpots,
                              beatTags: chartData.beatTags,
                              minY: minY,
                              maxY: maxY,
                            ),
                          ],
                        ),
                      );

                      if (_isSimulationMode) {
                        return chart;
                      }

                      return SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        reverse: true,
                        physics: const BouncingScrollPhysics(),
                        child: chart,
                      );
                    },
                  ),
                ),
                if (!_isSimulationMode) ...[
                  const SizedBox(height: 10),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chevron_left_rounded, color: T.txt2, size: 18),
                      SizedBox(width: 4),
                      Text(
                        'Geser untuk melihat sinyal',
                        style: TextStyle(
                          color: T.txt2,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: T.txt2,
                        size: 18,
                      ),
                    ],
                  ),
                ],
              ],
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
    final accent = hasPrediction
        ? _predictionAccent(_lastPredictionShort)
        : T.blue;
    final dimAccent = hasPrediction
        ? _predictionDimAccent(_lastPredictionShort)
        : T.blueDim;
    final brdAccent = hasPrediction
        ? _predictionBorderAccent(_lastPredictionShort)
        : T.blueBrd;

    final leftLabel = _isSimulationMode ? 'Sampel diproses' : 'Detak jantung';
    final leftValue = _isSimulationMode
        ? '$_evalTotal'
        : (_heartRate > 0 ? '$_heartRate' : '—');
    final leftFooter = _isSimulationMode
        ? '/ ${_evaluationRows.length}'
        : 'detak / menit';
    final leftColor = _isSimulationMode ? T.green : T.red;

    final rightLabel = _isSimulationMode
        ? 'Prediksi Model'
        : 'Klasifikasi Detak';
    final rightShort = hasPrediction ? _lastPredictionShort : '—';
    final rightValue = hasPrediction ? _lastPredictionClass : 'Menunggu data';
    final rightFooter = _isSimulationMode
        ? (_evalTotal > 0
              ? 'GT $_currentGroundTruthShort · Acc ${(100 * _evalAccuracy).toStringAsFixed(1)}%'
              : 'Menunggu inferensi dari CSV')
        : (hasPrediction
              ? 'Live dari paket data sensor terbaru'
              : (_isCalibrating
                    ? 'Stabilisasi $_calibrationSecondsLeft detik'
                    : 'Menunggu paket data dari sensor'));

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
                _Label(leftLabel),
                const SizedBox(height: 4),
                Text(
                  leftValue,
                  style: TextStyle(
                    color: leftColor,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  leftFooter,
                  style: const TextStyle(color: T.txt2, fontSize: 11),
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
    if (_isSimulationMode) {
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
                const Spacer(),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Total sampel',
                    value: '${_evaluationRows.length}',
                    accent: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'Diproses',
                    value: '$_evalTotal',
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
                    label: 'Benar',
                    value: '$_evalCorrect',
                    accent: _evalCorrect > 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'Salah',
                    value: '$_evalWrong',
                    accent: _evalWrong > 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Akurasi',
                    value: _evalTotal > 0
                        ? '${(_evalAccuracy * 100).toStringAsFixed(1)}%'
                        : '—',
                    accent: _evalTotal > 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'Ground truth',
                    value: _currentGroundTruthShort,
                    accent: _currentGroundTruthShort != '—',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Inferensi',
                    value: _lastInferenceMs > 0
                        ? '${_lastInferenceMs.toStringAsFixed(2)} ms'
                        : '—',
                    accent: _lastInferenceMs > 0,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MiniStat(
                    label: 'CPU prediksi',
                    value: _formatCpuValue(
                      _lastCpuAtInference,
                      decimals: 1,
                      compact: true,
                    ),
                    accent: _isValidCpuUsage(_lastCpuAtInference),
                  ),
                ),
              ],
            ),
            if (_uploadedCsvName != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: _MiniInfoTile(
                  label: 'File CSV',
                  value: _uploadedCsvName!,
                ),
              ),
            ],
          ],
        ),
      );
    }

    final leftLabel = 'Paket HR';
    final rightLabel = 'RR interval';
    final leftValue = '$_hrPacketCount';
    final rightValue = _rrIntervalMs > 0 ? '$_rrIntervalMs ms' : '—';

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
              const Spacer(),
              if (_isCalibrating)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: T.amberDim,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: T.amberBrd),
                  ),
                  child: Text(
                    'Stabilisasi $_calibrationSecondsLeft dtk',
                    style: const TextStyle(
                      color: T.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
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
                  label: 'Klasifikasi',
                  value: _lastPredictionShort,
                  accent: _lastPredictionShort != '—',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: 'Status sensor',
                  value: _isPolarConnected ? 'Tersambung' : '—',
                  accent: _isPolarConnected,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  label: 'Inferensi',
                  value: _lastInferenceMs > 0
                      ? '${_lastInferenceMs.toStringAsFixed(2)} ms'
                      : '—',
                  accent: _lastInferenceMs > 0,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MiniStat(
                  label: 'CPU prediksi',
                  value: _formatCpuValue(
                    _lastCpuAtInference,
                    decimals: 1,
                    compact: true,
                  ),
                  accent: _isValidCpuUsage(_lastCpuAtInference),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDebugPanel() {
    final debugChildren = <Widget>[
      _Chip(label: 'Model', active: _interpreter != null),
      _Chip(label: 'Bluetooth', active: _isPolarConnected),
      _Chip(
        label: 'Adapter ${_adapterState.name}',
        active: _adapterState == BluetoothAdapterState.on,
      ),
      _Chip(label: 'Evaluasi CSV', active: _isSimulationMode),
      _Chip(label: 'Running', active: _isRunning),
    ];

    if (_isSimulationMode) {
      debugChildren.add(_Chip(label: 'CSV', active: _hasUploadedCsv));
      if (_uploadedCsvName != null) {
        debugChildren.add(
          _Chip(label: _shortFileName(_uploadedCsvName!), active: true),
        );
      }
      debugChildren.add(
        _Chip(
          label: 'Row $_evalTotal/${_evaluationRows.length}',
          active: _hasUploadedCsv,
        ),
      );
      if (_currentGroundTruthShort != '—') {
        debugChildren.add(
          _Chip(label: 'GT $_currentGroundTruthShort', active: true),
        );
      }
      if (_lastPredictionShort != '—') {
        debugChildren.add(
          _Chip(label: 'Pred $_lastPredictionShort', active: true),
        );
      }
      debugChildren.add(
        _Chip(label: 'Benar $_evalCorrect', active: _evalCorrect > 0),
      );
      debugChildren.add(
        _Chip(label: 'Salah $_evalWrong', active: _evalWrong > 0),
      );
      if (_evalTotal > 0) {
        debugChildren.add(
          _Chip(
            label: 'Acc ${(100 * _evalAccuracy).toStringAsFixed(1)}%',
            active: true,
          ),
        );
      }
    } else {
      debugChildren.add(
        _Chip(label: 'HR $_heartRate bpm', active: _heartRate > 0),
      );
      debugChildren.add(
        _Chip(label: 'RR $_rrIntervalMs ms', active: _rrIntervalMs > 0),
      );
      debugChildren.add(_Chip(label: 'Pkt $_hrPacketCount', active: true));
      if (_lastPredictionShort != '—') {
        debugChildren.add(
          _Chip(label: 'Kls $_lastPredictionShort', active: true),
        );
      }
    }

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Debug pipeline'),
          Wrap(spacing: 6, runSpacing: 6, children: debugChildren),
        ],
      ),
    );
  }

  Widget _buildLatencyPanel() {
    final hasInferenceMetrics = _totalInferenceRuns > 0;
    final throughputLabel = _sessionSeconds > 0
        ? '${_throughput.toStringAsFixed(2)} inf/dtk'
        : '—';

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _PanelTitle('Performa inferensi model'),
          _MetricRow(
            'Waktu inferensi terakhir',
            hasInferenceMetrics
                ? '${_lastInferenceMs.toStringAsFixed(3)} ms'
                : '—',
          ),
          _MetricRow(
            'CPU saat prediksi terakhir',
            hasInferenceMetrics ? _formatCpuValue(_lastCpuAtInference) : '—',
          ),
          _MetricRow(
            'Rata-rata waktu inferensi',
            hasInferenceMetrics ? '${_latencyAvg.toStringAsFixed(3)} ms' : '—',
          ),
          _MetricRow(
            'Minimum',
            hasInferenceMetrics ? '${_latencyMin.toStringAsFixed(3)} ms' : '—',
          ),
          _MetricRow(
            'Maksimum',
            hasInferenceMetrics ? '${_latencyMax.toStringAsFixed(3)} ms' : '—',
          ),
          _MetricRow(
            'Laju pemrosesan',
            hasInferenceMetrics ? throughputLabel : '—',
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
          _MetricRow(
            'Penggunaan RAM',
            '${_ramCurrentMb.toStringAsFixed(2)} MB',
          ),
          _MetricRow('RAM minimum', '${_ramMinMb.toStringAsFixed(2)} MB'),
          _MetricRow('RAM maksimum', '${_ramMaxMb.toStringAsFixed(2)} MB'),
          _MetricRow('Penggunaan CPU', _formatCpuValue(_cpuCurrent)),
          _MetricRow(
            'CPU saat prediksi terakhir',
            _formatCpuValue(_lastCpuAtInference),
          ),
          _MetricRow('CPU minimum', _formatCpuValue(_cpuMin)),
          _MetricRow('CPU maksimum', _formatCpuValue(_cpuMax)),
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
      style: const TextStyle(color: T.txt2, fontSize: 10, letterSpacing: 1.2),
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
      width: double.infinity,
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
  const _MiniInfoTile({required this.label, required this.value});

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
            : const Border(bottom: BorderSide(color: Color(0x10FFFFFF))),
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

class _SignalClassBadge extends StatelessWidget {
  const _SignalClassBadge({required this.shortClass});

  final String shortClass;

  @override
  Widget build(BuildContext context) {
    final accent = _beatColors[shortClass] ?? T.green;
    final border = _beatBrdColors[shortClass] ?? T.greenBrd;

    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: accent,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x30000000),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        shortClass,
        style: const TextStyle(
          color: T.bg,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
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
              style: const TextStyle(color: T.txt, fontWeight: FontWeight.w600),
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
    final label = isSimulationMode ? 'EVAL' : (isRunning ? 'LIVE' : 'IDLE');

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
              Icon(Icons.refresh_rounded, color: T.txt2, size: 18),
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
