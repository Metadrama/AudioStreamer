import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert' as convert;

// Default server URL (enter your PC's IP for Wi-Fi/LAN use)
const String kDefaultStreamUrl = 'http://127.0.0.1:7350/stream.opus';


enum ConnectMode { wifi }

class PlayerController extends ChangeNotifier {
  static const MethodChannel _pcmChannel = MethodChannel('pcm_player');
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: const Duration(milliseconds: 60),
        maxBufferDuration: const Duration(milliseconds: 300),
        bufferForPlaybackDuration: const Duration(milliseconds: 35),
        bufferForPlaybackAfterRebufferDuration: const Duration(milliseconds: 60),
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
  int _prefFrameMs = 5;
  int _prefFlushMs = 10;
  String? _prefDeviceId;
  List<Map<String, dynamic>> _devices = const [];
  DateTime _lastPcmStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _prefGainDb = 0; // software preamp on server
  bool _pcmRunning = false;
  int _pcmBufPreset = 1;
  bool _usbDevMode = false;
  String? _usbStatus;
  bool _usbChecking = false;
  // Discovery state
  bool _discovering = false;
  List<DiscoveredServer> _found = const [];
  // Connection mode (USB tethering removed; always Wi‑Fi/host or ADB localhost)
  ConnectMode _mode = ConnectMode.wifi;
  // Last known transport status
  String _transportLabel = '';

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
  int get pcmBufPreset => _pcmBufPreset;
  bool get usbDevMode => _usbDevMode;
  String? get usbStatus => _usbStatus;
  bool get usbChecking => _usbChecking;
  bool get discovering => _discovering;
  List<DiscoveredServer> get foundServers => _found;
  ConnectMode get mode => _mode;
  String get transportLabel => _transportLabel;
  int? _selectedPcmPort;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('stream_url') ?? kDefaultStreamUrl;
    _autoConnect = prefs.getBool('auto_connect') ?? true;
    _usePcm = prefs.getBool('use_pcm') ?? true;
    _prefBitrate = prefs.getInt('pref_bitrate') ?? 320000;
    _prefFrameMs = prefs.getInt('pref_frame_ms') ?? 5;
    _prefFlushMs = prefs.getInt('pref_flush_ms') ?? 10;
    _prefDeviceId = prefs.getString('pref_device_id');
    _prefGainDb = prefs.getInt('pref_gain_db') ?? 0;
  _pcmBufPreset = prefs.getInt('pcm_buf_preset') ?? 2; // default to higher stability
    _usbDevMode = prefs.getBool('usb_dev_mode') ?? false;
    // USB tethering removed; force Wi‑Fi mode
    _mode = ConnectMode.wifi;
    if (_usbDevMode) {
      _usbStatus ??= 'USB mode enabled. Use Verify to check connectivity.';
    }
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
    await prefs.setInt('pcm_buf_preset', _pcmBufPreset);
    await prefs.setBool('usb_dev_mode', _usbDevMode);
    await prefs.setString('connect_mode', 'wifi');
  }

  void setUrl(String newUrl) {
    _url = newUrl.trim();
    _selectedPcmPort = null; // reset PCM port when URL is manually changed
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

  // setMode retained for compatibility; USB mode no longer supported
  Future<void> setMode(ConnectMode m) async {
    if (_mode == m) return;
    _mode = ConnectMode.wifi;
    await savePrefs();
    notifyListeners();
    await stop();
    await connectAndPlay();
  }

  Future<void> setPcmBufPreset(int preset) async {
    _pcmBufPreset = preset.clamp(0, 2);
    await savePrefs();
    notifyListeners();
  }

  Future<void> setUsbDevMode(bool enabled, {bool acceptDisclaimer = false}) async {
    _usbDevMode = enabled;
    if (_usbDevMode) {
      if (!acceptDisclaimer) {
        // no-op placeholder for future disclaimer handling
      }
      _url = 'http://127.0.0.1:7350/stream.opus';
      _usbStatus = 'USB mode enabled. Use Verify to check connectivity.';
    } else {
      _usbStatus = null;
      _usbChecking = false;
    }
    await savePrefs();
    notifyListeners();
  }

  Future<UsbCheckResult> verifyUsbReverse({Duration timeout = const Duration(milliseconds: 1500)}) async {
    _usbChecking = true;
    notifyListeners();
    bool httpOk = false;
    bool pcmOk = false;
    try {
  final resp = await http.get(Uri.parse('http://127.0.0.1:7350/config')).timeout(timeout);
      httpOk = resp.statusCode >= 200 && resp.statusCode < 500;
    } catch (_) {
      httpOk = false;
    }
    try {
  final socket = await Socket.connect('127.0.0.1', 7352, timeout: timeout);
      await socket.close();
      pcmOk = true;
    } catch (_) {
      pcmOk = false;
    }
    final result = UsbCheckResult(httpOk: httpOk, pcmOk: pcmOk);
    _usbStatus = result.isReady
        ? 'USB streaming: ready'
        : 'USB check: ${httpOk ? 'HTTP ok' : 'HTTP failed'} / ${pcmOk ? 'PCM ok' : 'PCM failed'}';
    _usbChecking = false;
    notifyListeners();
    return result;
  }

  // USB tethering support removed; no network binding or tether settings hooks.

  _PcmPreset _pcmPresetParams(int preset) {
    switch (preset) {
      case 0:
        return const _PcmPreset(targetMs: 40, prefillFrames: 4, capacity: 12);
      case 2:
        return const _PcmPreset(targetMs: 80, prefillFrames: 8, capacity: 24);
      default:
        return const _PcmPreset(targetMs: 60, prefillFrames: 6, capacity: 16);
    }
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
      'opus_use_vbr': true,
      'opus_rld': true,
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
        switch (type) {
          case 'connected':
            _pcmRunning = true;
            _isConnecting = false;
            _emitStatus('Playing (PCM)');
            break;
          case 'disconnected':
            _pcmRunning = false;
            _isConnecting = true;
            _emitStatus('Reconnecting...');
            break;
          case 'stopped':
            _pcmRunning = false;
            _isConnecting = false;
            _emitStatus('Idle');
            break;
          case 'connecting':
            _isConnecting = true;
            _emitStatus('Connecting...');
            break;
        }
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
          _emitStatus('Connecting...');
          break;
        case ProcessingState.buffering:
          _emitStatus('Buffering...');
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

  // UDP discovery: broadcast probe and collect responses briefly
  Future<List<DiscoveredServer>> discoverServers({Duration timeout = const Duration(seconds: 1)}) async {
    _discovering = true;
    _found = const [];
    notifyListeners();
    final List<DiscoveredServer> results = [];
    try {
      // USB tethering removed; perform standard discovery only
      // Include ADB reverse (localhost) option only when developer features are enabled
      if (_usbDevMode) {
        try {
          final resp = await http.get(Uri.parse('http://127.0.0.1:7350/config')).timeout(const Duration(milliseconds: 1000));
          if (resp.statusCode >= 200 && resp.statusCode < 500) {
            results.add(DiscoveredServer(host: '127.0.0.1', port: 7350, pcmPort: 7352, name: 'ADB (localhost)'));
          }
        } catch (_) {}
      }
      // Use RawDatagramSocket to send a broadcast and receive replies
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final probe = 'AUDSTRM_DISCOVER_V1';
  final data = convert.utf8.encode(probe);
      // Send to limited set of common broadcast addresses
      final bcasts = <InternetAddress>[
        InternetAddress('255.255.255.255'),
        // Common private subnets
        InternetAddress('192.168.42.255'),
        InternetAddress('192.168.137.255'),
        InternetAddress('172.20.23.255'),
        InternetAddress('10.0.0.255'),
      ];
      for (final addr in bcasts) {
        socket.send(data, addr, 7531);
      }
      final endAt = DateTime.now().add(timeout + const Duration(milliseconds: 300));
      socket.listen((evt) {
        if (evt == RawSocketEvent.read) {
          final d = socket.receive();
          if (d == null) return;
          try {
            final msg = convert.utf8.decode(d.data);
            if (msg.startsWith('AUDSTRM_OK_V1 ')) {
              final jsonStr = msg.substring('AUDSTRM_OK_V1 '.length);
              final obj = convert.jsonDecode(jsonStr) as Map<String, dynamic>;
              final host = d.address.address; // use source IP
              final port = (obj['port'] as num?)?.toInt() ?? 7350;
              final pcm = (obj['pcm'] as num?)?.toInt() ?? 7352;
              final name = (obj['name'] as String?) ?? host;
              final entry = DiscoveredServer(host: host, port: port, pcmPort: pcm, name: name);
              if (!results.any((e) => e.host == entry.host && e.port == entry.port)) {
                results.add(entry);
              }
            }
          } catch (_) {}
        }
      });
      while (DateTime.now().isBefore(endAt)) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
      socket.close();
      // Keep binding if USB mode; otherwise we don't need to explicitly unbind here
    } catch (_) {}
    _found = results;
    _discovering = false;
    notifyListeners();
    return results;
  }

  Future<void> connectAndPlay() async {
    _retryTimer?.cancel();
    _retryAttempt = 0;
    _isConnecting = true;
    notifyListeners();
    try {
      // USB tethering removed; default to Wi‑Fi/LAN or ADB (USB) label
      try {
        if (Platform.isAndroid) {
          _transportLabel = 'via Wi‑Fi/LAN';
        } else {
          _transportLabel = 'via network';
        }
      } catch (_) { _transportLabel = 'via network'; }
      if (_usePcm) {
        // Stop Opus player if running
        try { await _player.stop(); } catch (_) {}
        final host = _safeHostFromUrl(_url) ?? '127.0.0.1';
        if (Platform.isAndroid && host == '127.0.0.1' && _usbDevMode) {
          _transportLabel = 'via ADB (USB)';
        }
        final preset = _pcmPresetParams(_pcmBufPreset);
        await _pcmChannel.invokeMethod('startPcm', {
          'host': host,
          'port': _selectedPcmPort ?? 7352,
          'sampleRate': 48000,
          'channels': 2,
          'bits': 16,
          'targetMs': preset.targetMs,
          'prefill': preset.prefillFrames,
          'capacity': preset.capacity,
        });
        _lastPcmStart = DateTime.now();
        _pcmRunning = false;
        _emitStatus('Connecting...');
      } else {
        // Stop PCM if running
        try { await _pcmChannel.invokeMethod('stopPcm'); } catch (_) {}
        await _player.setAudioSource(
          AudioSource.uri(Uri.parse(_url)),
          preload: false,
        );
        final host = _safeHostFromUrl(_url) ?? '';
        if (Platform.isAndroid && host == '127.0.0.1' && _usbDevMode) {
          _transportLabel = 'via ADB (USB)';
        }
        await _player.play();
      }
      _isConnecting = !_usePcm;
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
                final host = _usbDevMode ? '127.0.0.1' : (_safeHostFromUrl(_url) ?? '127.0.0.1');
                final preset = _pcmPresetParams(_pcmBufPreset);
                await _pcmChannel.invokeMethod('startPcm', {
                  'host': host,
                  'port': 7352,
                  'sampleRate': 48000,
                  'channels': 2,
                  'bits': 16,
                  'targetMs': preset.targetMs,
                  'prefill': preset.prefillFrames,
                  'capacity': preset.capacity,
                });
                _lastPcmStart = DateTime.now();
                _pcmRunning = false;
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
        _emitStatus('Server down, attempting reconnect...');
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
    _emitStatus('Reconnecting in ${delay.inSeconds}s.');
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
    // USB tethering removed; nothing to unbind
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _statusController.close();
    _player.dispose();
    super.dispose();
  }

  // Extract a host from a URL string safely; returns null if invalid.
  String? _safeHostFromUrl(String url) {
    try {
      final u = Uri.parse(url);
      return u.host.isNotEmpty ? u.host : null;
    } catch (_) {
      return null;
    }
  }
}

class UsbCheckResult {
  final bool httpOk;
  final bool pcmOk;
  const UsbCheckResult({required this.httpOk, required this.pcmOk});
  bool get isReady => httpOk && pcmOk;
}

class _PcmPreset {
  final int targetMs;
  final int prefillFrames;
  final int capacity;
  const _PcmPreset({required this.targetMs, required this.prefillFrames, required this.capacity});
}

class DiscoveredServer {
  final String host;
  final int port;
  final int pcmPort;
  final String name;
  DiscoveredServer({required this.host, required this.port, required this.pcmPort, required this.name});
  String get opusUrl => 'http://$host:$port/stream.opus';
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
  // USB tethering auto-picker removed

  @override
  void initState() {
    super.initState();
    final pc = context.read<PlayerController>();
    _urlCtrl = TextEditingController(text: pc.url);
    // USB tethering auto-picker removed
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    // No lifecycle observer needed
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
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
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
              // Connection: Wi‑Fi/LAN or ADB (Advanced)
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
                    const Text('Low-latency (PCM)')
                  ]),
                ],
              ),
              if (pc.usePcm) ...[
                const SizedBox(height: 8),
                Row(children: [
                  const Text('PCM jitter buffer'),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: pc.pcmBufPreset,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Low (~40 ms)')),
                      DropdownMenuItem(value: 1, child: Text('Normal (~60 ms)')),
                      DropdownMenuItem(value: 2, child: Text('High (~80 ms)')),
                    ],
                    onChanged: (v) async { if (v != null) await pc.setPcmBufPreset(v); },
                  ),
                ]),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Server URL', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      // Allow editing in both Opus and PCM modes; PCM uses the same host on port 7352
                      enabled: _editing,
                      decoration: const InputDecoration(
                        hintText: kDefaultStreamUrl,
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _DiscoverButton(),
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
              const SizedBox(height: 8),
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

  Future<void> _showDiscoverSheet(BuildContext context) async {
    final controller = context.read<PlayerController>();
    await controller.discoverServers(timeout: const Duration(seconds: 1));
    if (!context.mounted) return;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        final list = controller.foundServers;
        if (list.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No PCs found. Ensure the phone and PC are on the same network — or enable ADB reverse for USB debugging under Advanced settings.'),
          );
        }
        return ListView.builder(
          itemCount: list.length,
          itemBuilder: (c, i) {
            final s = list[i];
            return ListTile(
              leading: const Icon(Icons.computer),
              title: Text(s.name),
              subtitle: Text('${s.host}  •  Opus:${s.port}  PCM:${s.pcmPort}'),
              onTap: () async {
                controller.setUrl(s.opusUrl);
                // Remember the PCM port for low-latency mode
                controller._selectedPcmPort = s.pcmPort;
                await controller.savePrefs();
                // Auto-connect after selecting a host
                await controller.connectAndPlay();
                if (context.mounted) Navigator.of(context).pop();
              },
            );
          },
        );
      },
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
      initialData: controller.isConnecting ? 'Connecting...' : 'Idle',
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
                      const SizedBox(height: 4),
                      if (controller.transportLabel.isNotEmpty)
                        Text('Streaming: ${controller.transportLabel}',
                            style: TextStyle(color: Colors.teal.shade200)),
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

// Lifecycle observer no longer needed (USB tethering removed)

class _Controls extends StatelessWidget {
  final PlayerController controller;
  const _Controls({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
                ? 'Connecting...'
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
          'Tip: For Play Store use, connect over Wi‑Fi/LAN. Enter your PC\'s IP in Server URL. The PCM path will use the same host on port 7352.',
          textAlign: TextAlign.center,
        )
      ],
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<PlayerController>();
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
                            items: const [5,10,20,40]
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
                            items: const [5,10,20,30,40,60]
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
            Card(
              child: ExpansionTile(
                title: const Text('Advanced'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch(
                        value: controller.usbDevMode,
                        onChanged: (v) async { await controller.setUsbDevMode(v, acceptDisclaimer: true); },
                      ),
                      const SizedBox(width: 8),
                      const Flexible(child: Text('USB debugging (ADB reverse)')),
                    ],
                  ),
                  if (controller.usbDevMode) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.check_circle_outline),
                          label: const Text('Verify localhost (ADB reverse)'),
                          onPressed: () async { await controller.verifyUsbReverse(); },
                        ),
                        if (controller.usbStatus != null) Text(controller.usbStatus!),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  const Text(
                    'Enable only if you intentionally use ADB port reverse (USB debugging). This option is provided under Advanced to comply with Play Store policies.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}





class _DiscoverButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    return IconButton(
      tooltip: pc.discovering ? 'Searching...' : 'Find PCs',
      onPressed: pc.discovering
          ? null
          : () async {
              final controller = context.read<PlayerController>();
              await controller.discoverServers(timeout: const Duration(seconds: 1));
              if (!context.mounted) return;
              showModalBottomSheet(
                context: context,
                showDragHandle: true,
                builder: (ctx) {
                  final list = controller.foundServers;
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No PCs found on your network. Ensure your PC and phone are on the same Wi‑Fi and firewall allows UDP 7531.'),
                    );
                  }
                  return ListView.builder(
                    itemCount: list.length,
                    itemBuilder: (c, i) {
                      final s = list[i];
                      return ListTile(
                        leading: const Icon(Icons.computer),
                        title: Text(s.name),
                        subtitle: Text('${s.host}  •  Opus:${s.port}  PCM:${s.pcmPort}'),
                        onTap: () async {
                          controller.setUrl(s.opusUrl);
                          controller._selectedPcmPort = s.pcmPort;
                          await controller.savePrefs();
                          // Auto-connect after selecting a host
                          await controller.connectAndPlay();
                          if (context.mounted) Navigator.of(context).pop();
                        },
                      );
                    },
                  );
                },
              );
            },
      icon: pc.discovering
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.wifi_find),
    );
  }
}
