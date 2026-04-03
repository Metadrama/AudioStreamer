import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert' as convert;

const String kDefaultStreamUrl = 'http://127.0.0.1:7350/stream.opus';

enum ConnectionStatus { idle, connecting, streaming, error }

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
  
  ConnectionStatus _status = ConnectionStatus.idle;
  String _url = kDefaultStreamUrl;
  bool _autoConnect = true;
  bool _usePcm = true;
  String? _pcmMessage;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Timer? _healthTimer;
  
  int _prefBitrate = 320000;
  int _prefFrameMs = 5;
  int _prefFlushMs = 10;
  String? _prefDeviceId;
  List<Map<String, dynamic>> _devices = const [];
  int _prefGainDb = 0;
  int _pcmBufPreset = 1;
  bool _usbDevMode = false;
  
  bool _discovering = false;
  List<DiscoveredServer> _found = [];
  int? _selectedPcmPort;

  ConnectionStatus get status => _status;
  Stream<String> get statusStream => _statusController.stream;
  String get url => _url;
  bool get autoConnect => _autoConnect;
  bool get usePcm => _usePcm;
  String? get pcmMessage => _pcmMessage;
  int get prefBitrate => _prefBitrate;
  int get prefFrameMs => _prefFrameMs;
  int get prefFlushMs => _prefFlushMs;
  String? get prefDeviceId => _prefDeviceId;
  List<Map<String, dynamic>> get devices => _devices;
  int get prefGainDb => _prefGainDb;
  int get pcmBufPreset => _pcmBufPreset;
  bool get usbDevMode => _usbDevMode;
  bool get discovering => _discovering;
  List<DiscoveredServer> get foundServers => _found;

  Future<void> init() async {
    await loadPrefs();
    _setupMethodChannel();
    _setupPlayerListeners();
    _startHealthMonitor();
    _refreshDevices();
    if (_autoConnect) connectAndPlay();
  }

  void _setupMethodChannel() {
    _pcmChannel.setMethodCallHandler((call) async {
      if (call.method == 'pcmEvent') {
        final args = call.arguments as Map?;
        final type = args?['type'] as String?;
        final msg = args?['message'] as String?;
        _pcmMessage = msg;
        switch (type) {
          case 'connected': _updateStatus(ConnectionStatus.streaming, 'HYPER-LINK ACTIVE'); _retryAttempt = 0; break;
          case 'disconnected': _updateStatus(ConnectionStatus.connecting, 'RE-SYNCING...'); break;
          case 'error': _updateStatus(ConnectionStatus.error, msg ?? 'PCM ERROR'); _scheduleReconnect(); break;
          case 'connecting': _updateStatus(ConnectionStatus.connecting, 'INITIALIZING...'); break;
        }
      }
    });
  }

  void _setupPlayerListeners() {
    _player.playerStateStream.listen((state) {
      if (_usePcm) return;
      switch (state.processingState) {
        case ProcessingState.idle: _updateStatus(ConnectionStatus.idle, 'STANDBY'); break;
        case ProcessingState.loading:
        case ProcessingState.buffering: _updateStatus(ConnectionStatus.connecting, 'BUFFERING'); break;
        case ProcessingState.ready:
          if (state.playing) {
            _updateStatus(ConnectionStatus.streaming, 'STREAMING OPUS');
            _retryAttempt = 0;
          } else {
            _updateStatus(ConnectionStatus.idle, 'PAUSED');
          }
          break;
        case ProcessingState.completed: _updateStatus(ConnectionStatus.idle, 'FINISHED'); _scheduleReconnect(); break;
      }
    }, onError: (e) {
      _updateStatus(ConnectionStatus.error, 'NODE FAILURE: $e');
      _scheduleReconnect();
    });
  }

  void _updateStatus(ConnectionStatus newStatus, String message) {
    _status = newStatus;
    _statusController.add(message);
    notifyListeners();
  }

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
    _pcmBufPreset = prefs.getInt('pcm_buf_preset') ?? 1;
    _usbDevMode = prefs.getBool('usb_dev_mode') ?? false;
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
  }

  void setUrl(String newUrl) {
    _url = newUrl.trim();
    _selectedPcmPort = null;
    savePrefs();
    notifyListeners();
  }

  void setAutoConnect(bool value) { _autoConnect = value; savePrefs(); notifyListeners(); }

  Future<void> setUsePcm(bool value) async {
    _usePcm = value;
    await savePrefs();
    notifyListeners();
    await stop();
    if (_autoConnect) connectAndPlay();
  }

  Future<void> setPcmBufPreset(int preset) async {
    _pcmBufPreset = preset;
    await savePrefs();
    notifyListeners();
    if (_status == ConnectionStatus.streaming) await connectAndPlay();
  }

  Future<void> connectAndPlay() async {
    if (_status == ConnectionStatus.connecting && _retryAttempt == 0) return;
    _retryTimer?.cancel();
    _updateStatus(ConnectionStatus.connecting, 'CONNECTING...');
    try {
      if (_usePcm) {
        await _player.stop();
        final host = _extractHost(_url);
        final preset = _getPcmPreset(_pcmBufPreset);
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
      } else {
        await _pcmChannel.invokeMethod('stopPcm');
        await _player.setAudioSource(AudioSource.uri(Uri.parse(_url)), preload: false);
        await _player.play();
      }
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'LINK FAILED: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_autoConnect) return;
    _retryTimer?.cancel();
    _retryAttempt++;
    final delay = Duration(seconds: _retryAttempt.clamp(1, 10) * 2);
    _statusController.add('RETRY IN ${delay.inSeconds}S...');
    _retryTimer = Timer(delay, () => connectAndPlay());
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryAttempt = 0;
    if (_usePcm) await _pcmChannel.invokeMethod('stopPcm');
    await _player.stop();
    _updateStatus(ConnectionStatus.idle, 'HALTED');
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    int failCount = 0;
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_status != ConnectionStatus.streaming && _status != ConnectionStatus.connecting) return;
      try {
        final uri = _extractConfigUri(_url);
        final resp = await http.get(uri).timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) failCount = 0; else failCount++;
      } catch (_) { failCount++; }
      if (failCount >= 3) {
        _updateStatus(ConnectionStatus.error, 'NODE OFFLINE');
        _scheduleReconnect();
      }
    });
  }

  Future<void> discoverServers() async {
    _discovering = true;
    _found = [];
    notifyListeners();
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final data = convert.utf8.encode('AUDSTRM_DISCOVER_V1');
      final bcasts = [InternetAddress('255.255.255.255'), InternetAddress('192.168.1.255'), InternetAddress('192.168.0.255')];
      for (final addr in bcasts) socket.send(data, addr, 7531);
      socket.listen((evt) {
        if (evt == RawSocketEvent.read) {
          final d = socket.receive();
          if (d == null) return;
          try {
            final msg = convert.utf8.decode(d.data);
            if (msg.startsWith('AUDSTRM_OK_V1 ')) {
              final jsonStr = msg.substring('AUDSTRM_OK_V1 '.length);
              final obj = convert.jsonDecode(jsonStr) as Map<String, dynamic>;
              final entry = DiscoveredServer(host: d.address.address, port: obj['port'] ?? 7350, pcmPort: obj['pcm'] ?? 7352, name: obj['name'] ?? d.address.address);
              if (!_found.any((e) => e.host == entry.host)) { _found.add(entry); notifyListeners(); }
            }
          } catch (_) {}
        }
      });
      await Future.delayed(const Duration(seconds: 2));
      socket.close();
    } catch (_) {}
    _discovering = false;
    notifyListeners();
  }

  String _extractHost(String url) { try { return Uri.parse(url).host; } catch (_) { return '127.0.0.1'; } }
  Uri _extractConfigUri(String url) { try { final u = Uri.parse(url); return Uri(scheme: u.scheme, host: u.host, port: u.port, path: '/config'); } catch (_) { return Uri.parse('http://127.0.0.1:7350/config'); } }
  _PcmPreset _getPcmPreset(int preset) {
    switch (preset) {
      case 0: return const _PcmPreset(targetMs: 40, prefillFrames: 4, capacity: 12);
      case 3: return const _PcmPreset(targetMs: 15, prefillFrames: 2, capacity: 16);
      case 2: return const _PcmPreset(targetMs: 80, prefillFrames: 8, capacity: 24);
      default: return const _PcmPreset(targetMs: 60, prefillFrames: 6, capacity: 16);
    }
  }

  Future<void> _refreshDevices() async {
    try {
      final uri = _extractConfigUri(_url).replace(path: '/devices');
      final resp = await http.get(uri).timeout(const Duration(seconds: 2));
      if (resp.statusCode == 200) { _devices = (convert.jsonDecode(resp.body) as List).cast<Map<String, dynamic>>(); notifyListeners(); }
    } catch (_) {}
  }

  void setPrefBitrate(int v) { _prefBitrate = v; savePrefs(); notifyListeners(); }
  void setPrefFrameMs(int v) { _prefFrameMs = v; savePrefs(); notifyListeners(); }
  void setPrefFlushMs(int v) { _prefFlushMs = v; savePrefs(); notifyListeners(); }
  void setPrefGainDb(int v) { _prefGainDb = v; savePrefs(); notifyListeners(); }
  void setPrefDeviceId(String? v) { _prefDeviceId = v; savePrefs(); notifyListeners(); }

  Future<bool> applyServerConfig() async {
    final uri = _extractConfigUri(_url);
    final body = { 'bitrate': _prefBitrate, 'frame_ms': _prefFrameMs, 'flush_ms': _prefFlushMs, if (_prefDeviceId != null) 'device_id': _prefDeviceId, 'gain_db': _prefGainDb };
    try {
      final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: convert.jsonEncode(body));
      if (resp.statusCode == 200) { connectAndPlay(); return true; }
    } catch (_) {}
    return false;
  }
}

class DiscoveredServer { final String host; final int port; final int pcmPort; final String name; DiscoveredServer({required this.host, required this.port, required this.pcmPort, required this.name}); }
class _PcmPreset { final int targetMs; final int prefillFrames; final int capacity; const _PcmPreset({required this.targetMs, required this.prefillFrames, required this.capacity}); }

void main() { runApp(const MainApp()); }

class MainApp extends StatelessWidget {
  const MainApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PlayerController()..init(),
      child: MaterialApp(
        title: 'AudioStreamer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF080808),
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.cyanAccent, brightness: Brightness.dark, surface: const Color(0xFF0F0F0F)),
          textTheme: const TextTheme(
            displayLarge: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, letterSpacing: 2),
            bodyMedium: TextStyle(fontFamily: 'monospace', letterSpacing: 0.5),
          ),
        ),
        home: const AppShell(),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(center: Alignment.topRight, radius: 1.5, colors: [Color(0xFF1A1F25), Color(0xFF080808)]),
        ),
        child: IndexedStack(index: _selectedIndex, children: const [HomePage(), DiscoveryPage(), SettingsPage()]),
      ),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: NavigationBar(
            backgroundColor: Colors.black.withOpacity(0.5),
            indicatorColor: Colors.cyanAccent.withOpacity(0.2),
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.hub_outlined, color: Colors.white54), selectedIcon: Icon(Icons.hub, color: Colors.cyanAccent), label: 'NODE'),
              NavigationDestination(icon: Icon(Icons.radar_outlined, color: Colors.white54), selectedIcon: Icon(Icons.radar, color: Colors.cyanAccent), label: 'SCAN'),
              NavigationDestination(icon: Icon(Icons.settings_input_component_outlined, color: Colors.white54), selectedIcon: Icon(Icons.settings_input_component, color: Colors.cyanAccent), label: 'CORE'),
            ],
          ),
        ),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('NEURAL AUDIO LINK', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 4, color: Colors.white24)),
            ),
            Expanded(child: Center(child: _buildMainControl(pc))),
            _buildQuickStats(pc),
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _buildMainControl(PlayerController pc) {
    bool active = pc.status == ConnectionStatus.streaming;
    bool connecting = pc.status == ConnectionStatus.connecting;
    Color glowColor = active ? Colors.cyanAccent : (connecting ? Colors.orangeAccent : (pc.status == ConnectionStatus.error ? Colors.redAccent : Colors.white10));

    return GestureDetector(
      onTap: () => active ? pc.stop() : pc.connectAndPlay(),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Outer Glow
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            width: active ? 280 : 240,
            height: active ? 280 : 240,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: glowColor.withOpacity(active ? 0.2 : 0.05), blurRadius: 60, spreadRadius: 10)],
            ),
          ),
          // Main Ring
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: glowColor.withOpacity(0.3), width: 1),
              gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Colors.white.withOpacity(0.1), Colors.transparent]),
            ),
            child: ClipOval(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(active ? Icons.stop_rounded : Icons.play_arrow_rounded, size: 80, color: glowColor),
                      const SizedBox(height: 8),
                      StreamBuilder<String>(
                        stream: pc.statusStream,
                        initialData: 'READY',
                        builder: (context, snap) => Text(snap.data!.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 2, color: glowColor)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Orbital dots (visual flair)
          if (active || connecting) _OrbitalPulse(color: glowColor),
        ],
      ),
    );
  }

  Widget _buildQuickStats(PlayerController pc) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            padding: const EdgeInsets.all(20),
            color: Colors.white.withOpacity(0.03),
            child: Column(
              children: [
                _statItem('HOST', pc.url.split('://').last.split('/').first, Icons.dns_outlined),
                const Divider(height: 24, color: Colors.white10),
                _statItem('MODE', pc.usePcm ? 'NATIVE-PCM' : 'OPUS-NET', Icons.Bolt),
                const Divider(height: 24, color: Colors.white10),
                _statItem('JITTER', '${pc.pcmBufPreset == 3 ? "ULTRA" : pc.pcmBufPreset == 0 ? "LOW" : "STABLE"}', Icons.waves),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _statItem(String label, String value, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white24),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.white24, fontWeight: FontWeight.bold, letterSpacing: 1)),
        const Spacer(),
        Expanded(child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white70, overflow: TextOverflow.ellipsis))),
      ],
    );
  }
}

class _OrbitalPulse extends StatefulWidget {
  final Color color;
  const _OrbitalPulse({required this.color});
  @override
  State<_OrbitalPulse> createState() => _OrbitalPulseState();
}

class _OrbitalPulseState extends State<_OrbitalPulse> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() { super.initState(); _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat(); }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: SizedBox(
        width: 260,
        height: 260,
        child: Stack(
          children: [
            Positioned(top: 0, left: 130, child: Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color, boxShadow: [BoxShadow(color: widget.color, blurRadius: 10)]))),
          ],
        ),
      ),
    );
  }
}

class DiscoveryPage extends StatelessWidget {
  const DiscoveryPage({super.key});
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('NODE DISCOVERY', style: TextStyle(fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.bold)), backgroundColor: Colors.transparent, elevation: 0),
      body: pc.foundServers.isEmpty && !pc.discovering
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.radar, size: 64, color: Colors.white.withOpacity(0.05)),
                  const SizedBox(height: 24),
                  const Text('SILENCE ON FREQUENCY', style: TextStyle(color: Colors.white24, letterSpacing: 2, fontSize: 12)),
                  const SizedBox(height: 32),
                  _glassButton('INITIATE SCAN', () => pc.discoverServers(), Icons.refresh),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(24),
              itemCount: pc.foundServers.length,
              itemBuilder: (context, i) {
                final s = pc.foundServers[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _glassCard(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      title: Text(s.name.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1)),
                      subtitle: Text('${s.host} • PCM:${s.pcmPort}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 14, color: Colors.cyanAccent),
                      onTap: () { pc.setUrl('http://${s.host}:${s.port}/stream.opus'); pc.connectAndPlay(); },
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: pc.discovering ? null : FloatingActionButton(onPressed: () => pc.discoverServers(), backgroundColor: Colors.cyanAccent, child: const Icon(Icons.radar, color: Colors.black)),
    );
  }

  Widget _glassButton(String label, VoidCallback onTap, IconData icon) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(30), border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)), color: Colors.cyanAccent.withOpacity(0.05)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18, color: Colors.cyanAccent), const SizedBox(width: 12), Text(label, style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, letterSpacing: 1.5))]),
      ),
    );
  }

  Widget _glassCard({required Widget child}) {
    return ClipRRect(borderRadius: BorderRadius.circular(20), child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10), child: Container(color: Colors.white.withOpacity(0.03), child: child)));
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('CORE CONFIG', style: TextStyle(fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.bold)), backgroundColor: Colors.transparent, elevation: 0),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _sectionHeader('STREAM-LINK'),
          _glassSetting('BITRATE', pc.prefBitrate, {128000: '128KB', 192000: '192KB', 256000: '256KB', 320000: '320KB'}, (v) => pc.setPrefBitrate(v!)),
          _glassSetting('LATENCY', pc.prefFrameMs, {5: '5MS', 10: '10MS', 20: '20MS'}, (v) => pc.setPrefFrameMs(v!)),
          const SizedBox(height: 32),
          _sectionHeader('NATIVE-CORE'),
          _glassSetting('BUFFER', pc.pcmBufPreset, {3: 'ULTRA', 0: 'LOW', 1: 'MID', 2: 'STABLE'}, (v) => pc.setPcmBufPreset(v!)),
          const SizedBox(height: 48),
          _glassAction('SYNC CONFIGURATION', () => pc.applyServerConfig(), Icons.sync_alt),
          const SizedBox(height: 16),
          _glassAction('TERMINATE ALL', () => pc.stop(), Icons.power_settings_new, color: Colors.redAccent),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) { return Padding(padding: const EdgeInsets.only(bottom: 16, left: 4), child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.cyanAccent, letterSpacing: 2))); }

  Widget _glassSetting<T>(String label, T value, Map<T, String> items, ValueChanged<T?> onChanged) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), color: Colors.white.withOpacity(0.03)),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white38)),
          const Spacer(),
          DropdownButton<T>(value: value, underline: const SizedBox(), items: items.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)))).toList(), onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _glassAction(String label, VoidCallback onTap, IconData icon, {Color color = Colors.cyanAccent}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 60,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), border: Border.all(color: color.withOpacity(0.3)), gradient: LinearGradient(colors: [color.withOpacity(0.1), Colors.transparent])),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 20, color: color), const SizedBox(width: 12), Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, letterSpacing: 1.5))]),
      ),
    );
  }
}
