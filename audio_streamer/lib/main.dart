import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert' as convert;

const String kDefaultStreamUrl = 'http://127.0.0.1:7350/stream.opus';


class PlayerController extends ChangeNotifier {
  static const MethodChannel _pcmChannel = MethodChannel('pcm_player');
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: const Duration(milliseconds: 200),
        maxBufferDuration: const Duration(milliseconds: 800),
        bufferForPlaybackDuration: const Duration(milliseconds: 80),
        bufferForPlaybackAfterRebufferDuration: const Duration(milliseconds: 160),
        prioritizeTimeOverSizeThresholds: true,
      ),
    ),
  );
  final _statusController = StreamController<String>.broadcast();
  String _url = kDefaultStreamUrl;
  bool _autoConnect = true;
  bool _usePcm = true;
  String? _pcmStatus;
  bool _isConnecting = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Timer? _healthTimer;
  // Preferences for server
  int _prefBitrate = 320000;
  int _prefFrameMs = 10;
  int _prefFlushMs = 30;
  String? _prefDeviceId;
  List<Map<String, dynamic>> _devices = const [];
  DateTime _lastPcmStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _prefGainDb = 0; // software preamp on server
  bool _pcmRunning = false;

  Stream<String> get statusStream => _statusController.stream;
  AudioPlayer get player => _player;
  String get url => _url;
  bool get autoConnect => _autoConnect;
  bool get usePcm => _usePcm;
  bool get isConnecting => _isConnecting;
  bool get isConnected => _usePcm ? _pcmRunning : _player.playerState.playing;
  String? get pcmStatus => _pcmStatus;
  int get prefBitrate => _prefBitrate;
  int get prefFrameMs => _prefFrameMs;
  int get prefFlushMs => _prefFlushMs;
  String? get prefDeviceId => _prefDeviceId;
  List<Map<String, dynamic>> get devices => _devices;
  int get prefGainDb => _prefGainDb;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('stream_url') ?? kDefaultStreamUrl;
    _autoConnect = prefs.getBool('auto_connect') ?? true;
    _usePcm = prefs.getBool('use_pcm') ?? true;
    _prefBitrate = prefs.getInt('pref_bitrate') ?? 320000;
    _prefFrameMs = prefs.getInt('pref_frame_ms') ?? 10;
    _prefFlushMs = prefs.getInt('pref_flush_ms') ?? 30;
    _prefDeviceId = prefs.getString('pref_device_id');
    _prefGainDb = prefs.getInt('pref_gain_db') ?? 0;
    notifyListeners();
  }

  Future<void> savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stream_url', _url);
    await prefs.setBool('auto_connect', _autoConnect);
    await prefs.setBool('use_pcm', _usePcm);
    await prefs.setInt('pref_bitrate', _prefBitrate);
    await prefs.setInt('pref_frame_ms', _prefFrameMs);
    await prefs.setInt('pref_flush_ms', _prefFlushMs);
    if (_prefDeviceId != null) await prefs.setString('pref_device_id', _prefDeviceId!);
    await prefs.setInt('pref_gain_db', _prefGainDb);
  }

  void setUrl(String newUrl) {
    _url = newUrl.trim();
    notifyListeners();
  }

  void setAutoConnect(bool value) {
    _autoConnect = value;
    savePrefs();
    notifyListeners();
  }

  Future<void> setUsePcm(bool value) async {
    _usePcm = value;
    await savePrefs();
    notifyListeners();
    // Seamlessly switch paths to avoid double playback/echo
    await stop();
    await connectAndPlay();
  }

  void setPrefBitrate(int bps) {
    _prefBitrate = bps;
    savePrefs();
    notifyListeners();
  }
  void setPrefFrameMs(int ms) {
    _prefFrameMs = ms;
    savePrefs();
    notifyListeners();
  }
  void setPrefFlushMs(int ms) {
    _prefFlushMs = ms;
    savePrefs();
    notifyListeners();
  }
  void setPrefDeviceId(String? id) {
    _prefDeviceId = id;
    savePrefs();
    notifyListeners();
  }
  void setPrefGainDb(int db) {
    _prefGainDb = db.clamp(0, 18);
    savePrefs();
    notifyListeners();
  }

  Uri _configUri() {
    try {
      final u = Uri.parse(_url);
      return Uri(scheme: u.scheme, host: u.host, port: u.port, path: '/config');
    } catch (_) {
      return Uri.parse('http://127.0.0.1:7350/config');
    }
  }

  Future<bool> applyServerConfig() async {
    final uri = _configUri();
    final body = {
      'bitrate': _prefBitrate,
      'frame_ms': _prefFrameMs,
      'flush_ms': _prefFlushMs,
      // keep current defaults for latency/quality
      'opus_use_vbr': false,
      if (_prefDeviceId != null) 'device_id': _prefDeviceId,
      'gain_db': _prefGainDb,
      'target_peak_dbfs': -1,
    };
    try {
      final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: convert.jsonEncode(body));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        // Reconnect to apply new snapshot
        await stop();
        await connectAndPlay();
        return true;
      }
    } catch (e) {
      _emitStatus('Apply failed: $e');
    }
    return false;
  }

  Future<void> init() async {
    await loadPrefs();
    _startHealthMonitor();
    _refreshDevices();
    _pcmChannel.setMethodCallHandler((call) async {
      if (call.method == 'pcmEvent') {
        final args = call.arguments as Map?;
        final type = args?['type'] as String?;
        final msg = args?['message'] as String?;
        _pcmStatus = type == null ? null : (msg == null ? type : ('$type: ' + msg));
        notifyListeners();
      }
    });
    _player.playbackEventStream.listen((event) {}, onError: (e, st) {
      _emitStatus('Error: ${e.toString()}');
      _scheduleReconnect();
    });
    _player.playerStateStream.listen((state) {
      switch (state.processingState) {
        case ProcessingState.idle:
          _emitStatus('Idle');
          break;
        case ProcessingState.loading:
          _emitStatus('Connectingâ€¦');
          break;
        case ProcessingState.buffering:
          _emitStatus('Bufferingâ€¦');
          break;
        case ProcessingState.ready:
          _emitStatus(state.playing ? 'Playing' : 'Ready');
          break;
        case ProcessingState.completed:
          _emitStatus('Completed');
          _scheduleReconnect();
          break;
      }
      notifyListeners();
    });

    if (_autoConnect) {
      connectAndPlay();
    }
  }

  Future<void> connectAndPlay() async {
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _isConnecting = true;
    notifyListeners();
    try {
      if (_usePcm) {
        // Stop Opus player if running
        try { await _player.stop(); } catch (_) {}
        await _pcmChannel.invokeMethod('startPcm', {
          'host': '127.0.0.1',
          'port': 7352,
          'sampleRate': 48000,
          'channels': 2,
          'bits': 16,
        });
        _lastPcmStart = DateTime.now();
        _pcmRunning = true;
      } else {
        // Stop PCM if running
        try { await _pcmChannel.invokeMethod('stopPcm'); } catch (_) {}
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(_url)),
          preload: true,
        );
        await _player.play();
      }
      _isConnecting = false;
      notifyListeners();
    } catch (e) {
      _emitStatus('Connect failed: ${e.toString()}');
      _isConnecting = false;
      notifyListeners();
      _scheduleReconnect();
    }
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    int failCount = 0;
    _healthTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final uri = _configUri();
      try {
        final resp = await http.get(uri).timeout(const Duration(seconds: 1));
        if (resp.statusCode >= 200 && resp.statusCode < 500) {
          failCount = 0;
          // Nudge PCM service if chosen
          if (_usePcm && !_isConnecting) {
            try {
              if (DateTime.now().difference(_lastPcmStart) > const Duration(seconds: 30)) {
                await _pcmChannel.invokeMethod('startPcm', {
                  'host': '127.0.0.1',
                  'port': 7352,
                  'sampleRate': 48000,
                  'channels': 2,
                  'bits': 16,
                });
                _lastPcmStart = DateTime.now();
                _pcmRunning = true;
              }
            } catch (_) {}
          }
          return;
        }
        failCount++;
      } catch (_) {
        failCount++;
      }
      if (failCount >= 3 && _autoConnect) {
        _emitStatus('Server down, attempting reconnect…');
        _scheduleReconnect();
      }
    });
  }

  Future<void> _refreshDevices() async {
    try {
      final uri = _configUri().replace(path: '/devices');
      final resp = await http.get(uri).timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) {
        final list = convert.jsonDecode(resp.body) as List<dynamic>;
        _devices = list.cast<Map<String, dynamic>>();
        notifyListeners();
      }
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (!_autoConnect) return;
    _pcmRunning = false;
    _retryTimer?.cancel();
    _retryAttempt = (_retryAttempt + 1).clamp(1, 8);
    final delay = Duration(seconds: [2, 3, 5, 8, 13, 21, 30, 45][_retryAttempt - 1]);
    _emitStatus('Reconnecting in ${delay.inSeconds}sâ€¦');
    _retryTimer = Timer(delay, () {
      connectAndPlay();
    });
  }

  void _emitStatus(String s) {
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> play() async {
    if (_player.processingState == ProcessingState.idle) {
      await connectAndPlay();
    } else {
      await _player.play();
    }
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    if (_usePcm) {
      try { await _pcmChannel.invokeMethod('stopPcm'); } catch (_) {}
    }
    await _player.stop();
    _pcmRunning = false;
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _statusController.close();
    _player.dispose();
    super.dispose();
  }
}

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController()..init(),
      child: MaterialApp(
        title: 'Audio Stream Client',
        themeMode: ThemeMode.dark,
        theme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark, useMaterial3: true),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _urlCtrl;
  bool _editing = false;

  @override
  void initState() {
    super.initState();
    final pc = context.read<PlayerController>();
    _urlCtrl = TextEditingController(text: pc.url);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Stream Client'),
        actions: [
          IconButton(
            tooltip: _editing ? 'Save URL' : 'Edit URL',
            icon: Icon(_editing ? Icons.check : Icons.edit),
            onPressed: () async {
              if (_editing) {
                pc.setUrl(_urlCtrl.text);
                await pc.savePrefs();
              }
              setState(() => _editing = !_editing);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (pc.usePcm)
                Container(
                  padding: const EdgeInsets.all(8),
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(pc.pcmStatus ?? 'PCM mode (foreground service)',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Switch(value: pc.usePcm, onChanged: (v) async { await pc.setUsePcm(v); }),
                    const SizedBox(width: 8),
                    const Text('Low-latency (PCM over USB)')
                  ]),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('USB URL', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      enabled: _editing && !pc.usePcm,
                      decoration: const InputDecoration(
                        hintText: kDefaultStreamUrl,
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(value: pc.autoConnect, onChanged: (v) => pc.setAutoConnect(v)),
                  const SizedBox(width: 8),
                  const Text('Auto-connect on launch'),
                ],
              ),
              const SizedBox(height: 16),
              _StatusCard(controller: pc),
              const SizedBox(height: 16),
              _Controls(controller: pc),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final PlayerController controller;
  const _StatusCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<String>(
      stream: controller.statusStream,
      initialData: controller.isConnecting ? 'Connectingâ€¦' : 'Idle',
      builder: (context, snap) {
        final status = snap.data ?? 'Idle';
        final playerState = controller.player.playerState;
        final icon = playerState.playing
            ? Icons.graphic_eq
            : (controller.isConnecting ? Icons.sync : Icons.pause_circle_outline);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(icon, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(status, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(controller.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Controls extends StatelessWidget {
  final PlayerController controller;
  const _Controls({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Preferences', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Bitrate'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: controller.prefBitrate,
                        items: const [96,128,160,192,256,320]
                            .map((k) => DropdownMenuItem<int>(value: k*1000, child: Text('${k} kbps')))
                            .toList(),
                        onChanged: (v) { if (v!=null) controller.setPrefBitrate(v); },
                      ),
                    ]),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Frame'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: controller.prefFrameMs,
                        items: const [10,20,40]
                            .map((k) => DropdownMenuItem<int>(value: k, child: Text('${k} ms')))
                            .toList(),
                        onChanged: (v) { if (v!=null) controller.setPrefFrameMs(v); },
                      ),
                    ]),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Flush'),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: controller.prefFlushMs,
                        items: const [20,30,40,60]
                            .map((k) => DropdownMenuItem<int>(value: k, child: Text('${k} ms')))
                            .toList(),
                        onChanged: (v) { if (v!=null) controller.setPrefFlushMs(v); },
                      ),
                    ]),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Output device'),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: controller.prefDeviceId ?? '',
                        items: [
                          const DropdownMenuItem<String>(value: '', child: Text('Default (system)')),
                          ...controller.devices.map((d) => DropdownMenuItem<String>(
                                value: d['id'] as String,
                                child: Text(d['name'] as String),
                              ))
                        ],
                        onChanged: (v) { controller.setPrefDeviceId((v != null && v.isNotEmpty) ? v : null); },
                      ),
                      IconButton(
                        tooltip: 'Refresh devices',
                        onPressed: () async { await controller._refreshDevices(); },
                        icon: const Icon(Icons.refresh),
                      )
                    ]),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const Text('Volume boost'),
                  Expanded(
                    child: Slider(
                      value: controller.prefGainDb.toDouble(),
                      min: 0,
                      max: 18,
                      divisions: 18,
                      label: '+${controller.prefGainDb} dB',
                      onChanged: (v) { controller.setPrefGainDb(v.round()); },
                    ),
                  ),
                  SizedBox(
                      width: 48,
                      child: Text('+${controller.prefGainDb} dB', textAlign: TextAlign.right)),
                ]),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.tune),
                    label: const Text('Apply to Server'),
                    onPressed: () async { await controller.applyServerConfig(); },
                  ),
                ),
              ],
            ),
          ),
        ),
        Center(
          child: FilledButton.icon(
            icon: controller.isConnecting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : (controller.isConnected ? const Icon(Icons.check_circle) : const Icon(Icons.power_settings_new)),
            label: Text(controller.isConnecting
                ? 'Connecting…'
                : (controller.isConnected ? 'Connected' : 'Connect')),
            style: FilledButton.styleFrom(
              backgroundColor: controller.isConnected ? Colors.green : null,
            ),
            onPressed: (controller.isConnected || controller.isConnecting)
                ? null
                : () async {
                    await controller.connectAndPlay();
                  },
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Ensure USB debugging is enabled and the PC app has established adb reverse.',
          textAlign: TextAlign.center,
        )
      ],
    );
  }
}




