import 'dart:async';
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
  
  // State variables
  ConnectionStatus _status = ConnectionStatus.idle;
  String _url = kDefaultStreamUrl;
  bool _autoConnect = true;
  bool _usePcm = true;
  String? _pcmMessage;
  int _retryAttempt = 0;
  Timer? _retryTimer;
  Timer? _healthTimer;
  
  // Settings
  int _prefBitrate = 320000;
  int _prefFrameMs = 5;
  int _prefFlushMs = 10;
  String? _prefDeviceId;
  List<Map<String, dynamic>> _devices = const [];
  int _prefGainDb = 0;
  int _pcmBufPreset = 1;
  bool _usbDevMode = false;
  
  // Discovery
  bool _discovering = false;
  List<DiscoveredServer> _found = [];
  int? _selectedPcmPort;

  // Getters
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
    
    if (_autoConnect) {
      connectAndPlay();
    }
  }

  void _setupMethodChannel() {
    _pcmChannel.setMethodCallHandler((call) async {
      if (call.method == 'pcmEvent') {
        final args = call.arguments as Map?;
        final type = args?['type'] as String?;
        final msg = args?['message'] as String?;
        _pcmMessage = msg;
        
        switch (type) {
          case 'connected':
            _updateStatus(ConnectionStatus.streaming, 'Streaming (Low Latency)');
            _retryAttempt = 0;
            break;
          case 'disconnected':
            _updateStatus(ConnectionStatus.connecting, 'Signal Lost. Retrying...');
            break;
          case 'error':
            _updateStatus(ConnectionStatus.error, msg ?? 'PCM Error');
            _scheduleReconnect();
            break;
          case 'connecting':
            _updateStatus(ConnectionStatus.connecting, 'Establishing Link...');
            break;
        }
      }
    });
  }

  void _setupPlayerListeners() {
    _player.playerStateStream.listen((state) {
      if (_usePcm) return; // Ignore if in PCM mode
      
      switch (state.processingState) {
        case ProcessingState.idle:
          _updateStatus(ConnectionStatus.idle, 'Ready');
          break;
        case ProcessingState.loading:
        case ProcessingState.buffering:
          _updateStatus(ConnectionStatus.connecting, 'Buffering...');
          break;
        case ProcessingState.ready:
          if (state.playing) {
            _updateStatus(ConnectionStatus.streaming, 'Streaming (Opus)');
            _retryAttempt = 0;
          } else {
            _updateStatus(ConnectionStatus.idle, 'Paused');
          }
          break;
        case ProcessingState.completed:
          _updateStatus(ConnectionStatus.idle, 'Finished');
          _scheduleReconnect();
          break;
      }
    }, onError: (e) {
      _updateStatus(ConnectionStatus.error, 'Player Error: $e');
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

  void setAutoConnect(bool value) {
    _autoConnect = value;
    savePrefs();
    notifyListeners();
  }

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
    if (_status == ConnectionStatus.streaming) {
      await connectAndPlay(); // Restart to apply
    }
  }

  Future<void> connectAndPlay() async {
    if (_status == ConnectionStatus.connecting && _retryAttempt == 0) return;
    
    _retryTimer?.cancel();
    _updateStatus(ConnectionStatus.connecting, 'Connecting...');
    
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
      _updateStatus(ConnectionStatus.error, 'Connect Failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_autoConnect) return;
    _retryTimer?.cancel();
    _retryAttempt++;
    
    final delay = Duration(seconds: _retryAttempt.clamp(1, 10) * 2);
    _statusController.add('Retrying in ${delay.inSeconds}s...');
    
    _retryTimer = Timer(delay, () => connectAndPlay());
  }

  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryAttempt = 0;
    if (_usePcm) {
      await _pcmChannel.invokeMethod('stopPcm');
    }
    await _player.stop();
    _updateStatus(ConnectionStatus.idle, 'Stopped');
  }

  void _startHealthMonitor() {
    _healthTimer?.cancel();
    int failCount = 0;
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_status != ConnectionStatus.streaming && _status != ConnectionStatus.connecting) return;
      
      try {
        final uri = _extractConfigUri(_url);
        final resp = await http.get(uri).timeout(const Duration(seconds: 2));
        if (resp.statusCode == 200) {
          failCount = 0;
        } else {
          failCount++;
        }
      } catch (_) {
        failCount++;
      }

      if (failCount >= 3) {
        _updateStatus(ConnectionStatus.error, 'Server Offline');
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
      
      final bcasts = [
        InternetAddress('255.255.255.255'),
        InternetAddress('192.168.1.255'),
        InternetAddress('192.168.0.255'),
      ];
      
      for (final addr in bcasts) {
        socket.send(data, addr, 7531);
      }

      socket.listen((evt) {
        if (evt == RawSocketEvent.read) {
          final d = socket.receive();
          if (d == null) return;
          try {
            final msg = convert.utf8.decode(d.data);
            if (msg.startsWith('AUDSTRM_OK_V1 ')) {
              final jsonStr = msg.substring('AUDSTRM_OK_V1 '.length);
              final obj = convert.jsonDecode(jsonStr) as Map<String, dynamic>;
              final entry = DiscoveredServer(
                host: d.address.address,
                port: obj['port'] ?? 7350,
                pcmPort: obj['pcm'] ?? 7352,
                name: obj['name'] ?? d.address.address,
              );
              if (!_found.any((e) => e.host == entry.host)) {
                _found.add(entry);
                notifyListeners();
              }
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

  String _extractHost(String url) {
    try { return Uri.parse(url).host; } catch (_) { return '127.0.0.1'; }
  }

  Uri _extractConfigUri(String url) {
    try {
      final u = Uri.parse(url);
      return Uri(scheme: u.scheme, host: u.host, port: u.port, path: '/config');
    } catch (_) {
      return Uri.parse('http://127.0.0.1:7350/config');
    }
  }

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
      if (resp.statusCode == 200) {
        _devices = (convert.jsonDecode(resp.body) as List).cast<Map<String, dynamic>>();
        notifyListeners();
      }
    } catch (_) {}
  }

  void setPrefBitrate(int v) { _prefBitrate = v; savePrefs(); notifyListeners(); }
  void setPrefFrameMs(int v) { _prefFrameMs = v; savePrefs(); notifyListeners(); }
  void setPrefFlushMs(int v) { _prefFlushMs = v; savePrefs(); notifyListeners(); }
  void setPrefGainDb(int v) { _prefGainDb = v; savePrefs(); notifyListeners(); }
  void setPrefDeviceId(String? v) { _prefDeviceId = v; savePrefs(); notifyListeners(); }

  Future<bool> applyServerConfig() async {
    final uri = _extractConfigUri(_url);
    final body = {
      'bitrate': _prefBitrate,
      'frame_ms': _prefFrameMs,
      'flush_ms': _prefFlushMs,
      if (_prefDeviceId != null) 'device_id': _prefDeviceId,
      'gain_db': _prefGainDb,
    };
    try {
      final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: convert.jsonEncode(body));
      if (resp.statusCode == 200) {
        connectAndPlay();
        return true;
      }
    } catch (_) {}
    return false;
  }
}

class DiscoveredServer {
  final String host;
  final int port;
  final int pcmPort;
  final String name;
  DiscoveredServer({required this.host, required this.port, required this.pcmPort, required this.name});
}

class _PcmPreset {
  final int targetMs;
  final int prefillFrames;
  final int capacity;
  const _PcmPreset({required this.targetMs, required this.prefillFrames, required this.capacity});
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
        title: 'AudioStreamer',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.cyan,
            brightness: Brightness.dark,
            surface: const Color(0xFF121212),
          ),
          cardTheme: CardTheme(
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            color: Colors.white.withOpacity(0.05),
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
      body: IndexedStack(
        index: _selectedIndex,
        children: const [
          HomePage(),
          DiscoveryPage(),
          SettingsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (i) => setState(() => _selectedIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.search), selectedIcon: Icon(Icons.manage_search), label: 'Discover'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
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
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(
            title: Text('AudioStreamer', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(24),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildStatusCore(pc),
                const SizedBox(height: 32),
                _buildModeToggle(pc),
                const SizedBox(height: 16),
                _buildConnectionInfo(pc),
              ]),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.large(
        onPressed: () => pc.status == ConnectionStatus.streaming ? pc.stop() : pc.connectAndPlay(),
        backgroundColor: pc.status == ConnectionStatus.streaming ? Colors.redAccent : Theme.of(context).colorScheme.primary,
        child: Icon(
          pc.status == ConnectionStatus.streaming ? Icons.stop : Icons.play_arrow,
          size: 40,
        ),
      ),
    );
  }

  Widget _buildStatusCore(PlayerController pc) {
    Color color;
    IconData icon;
    switch (pc.status) {
      case ConnectionStatus.streaming:
        color = Colors.cyanAccent;
        icon = Icons.waves;
        break;
      case ConnectionStatus.connecting:
        color = Colors.orangeAccent;
        icon = Icons.sync;
        break;
      case ConnectionStatus.error:
        color = Colors.redAccent;
        icon = Icons.error_outline;
        break;
      case ConnectionStatus.idle:
      default:
        color = Colors.white38;
        icon = Icons.power_settings_new;
    }

    return Center(
      child: Column(
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.1),
              border: Border.all(color: color.withOpacity(0.3), width: 2),
              boxShadow: [
                if (pc.status == ConnectionStatus.streaming)
                  BoxShadow(color: color.withOpacity(0.2), blurRadius: 40, spreadRadius: 5),
              ],
            ),
            child: Icon(icon, size: 80, color: color),
          ),
          const SizedBox(height: 24),
          StreamBuilder<String>(
            stream: pc.statusStream,
            initialData: 'Idle',
            builder: (context, snap) {
              return Text(
                snap.data ?? 'Idle',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildModeToggle(PlayerController pc) {
    return Card(
      child: ListTile(
        title: const Text('Low Latency Mode'),
        subtitle: const Text('High-performance PCM stream'),
        trailing: Switch(
          value: pc.usePcm,
          onChanged: (v) => pc.setUsePcm(v),
        ),
      ),
    );
  }

  Widget _buildConnectionInfo(PlayerController pc) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _infoRow(Icons.link, 'Host', pc.url),
            if (pc.usePcm) ...[
              const Divider(height: 32, color: Colors.white10),
              _infoRow(Icons.buffer, 'Buffer', '${pc.pcmBufPreset == 3 ? "Ultra" : pc.pcmBufPreset == 0 ? "Low" : "Normal"}'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Colors.white38),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white38)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class DiscoveryPage extends StatelessWidget {
  const DiscoveryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    
    return Scaffold(
      appBar: AppBar(title: const Text('Discover PCs')),
      body: pc.foundServers.isEmpty && !pc.discovering
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.search_off, size: 64, color: Colors.white24),
                  const SizedBox(height: 16),
                  const Text('No servers found', style: TextStyle(color: Colors.white38)),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () => pc.discoverServers(),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Scan Network'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: pc.foundServers.length,
              itemBuilder: (context, i) {
                final s = pc.foundServers[i];
                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.computer)),
                    title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('${s.host}:${s.port}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      pc.setUrl('http://${s.host}:${s.port}/stream.opus');
                      pc.connectAndPlay();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Connected to ${s.name}')),
                      );
                    },
                  ),
                );
              },
            ),
      floatingActionButton: pc.discovering
          ? null
          : FloatingActionButton(
              onPressed: () => pc.discoverServers(),
              child: const Icon(Icons.refresh),
            ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final pc = context.watch<PlayerController>();
    
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _sectionTitle('Streaming'),
          _buildDropdown<int>(
            'Target Bitrate',
            pc.prefBitrate,
            {128000: '128 kbps', 192000: '192 kbps', 256000: '256 kbps', 320000: '320 kbps'},
            (v) => pc.setPrefBitrate(v!),
          ),
          _buildDropdown<int>(
            'Frame Size',
            pc.prefFrameMs,
            {5: '5 ms', 10: '10 ms', 20: '20 ms'},
            (v) => pc.setPrefFrameMs(v!),
          ),
          const SizedBox(height: 24),
          _sectionTitle('Performance'),
          _buildDropdown<int>(
            'PCM Buffer Preset',
            pc.pcmBufPreset,
            {3: 'Ultra (Extreme)', 0: 'Low', 1: 'Normal', 2: 'Stable'},
            (v) => pc.setPcmBufPreset(v!),
          ),
          const SizedBox(height: 32),
          FilledButton.icon(
            onPressed: () => pc.applyServerConfig(),
            icon: const Icon(Icons.sync_alt),
            label: const Text('Sync with Server'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => pc.stop(),
            child: const Text('Reset All Settings', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.cyan)),
    );
  }

  Widget _buildDropdown<T>(String label, T value, Map<T, String> items, ValueChanged<T?> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        children: [
          Text(label),
          const Spacer(),
          DropdownButton<T>(
            value: value,
            underline: const SizedBox(),
            items: items.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
