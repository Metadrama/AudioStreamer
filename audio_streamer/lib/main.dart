import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kDefaultStreamUrl = 'http://127.0.0.1:7350/stream.opus';


class PlayerController extends ChangeNotifier {
  static const MethodChannel _pcmChannel = MethodChannel('pcm_player');
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: const Duration(milliseconds: 150),
        maxBufferDuration: const Duration(milliseconds: 600),
        bufferForPlaybackDuration: const Duration(milliseconds: 75),
        bufferForPlaybackAfterRebufferDuration: const Duration(milliseconds: 150),
        prioritizeTimeOverSizeThresholds: true,
      ),
    ),
  );
  final _statusController = StreamController<String>.broadcast();
  String _url = kDefaultStreamUrl;
  bool _autoConnect = true;
  bool _usePcm = false;
  bool _isConnecting = false;
  int _retryAttempt = 0;
  Timer? _retryTimer;

  Stream<String> get statusStream => _statusController.stream;
  AudioPlayer get player => _player;
  String get url => _url;
  bool get autoConnect => _autoConnect;
  bool get usePcm => _usePcm;
  bool get isConnecting => _isConnecting;

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _url = prefs.getString('stream_url') ?? kDefaultStreamUrl;
    _autoConnect = prefs.getBool('auto_connect') ?? true;
    notifyListeners();
  }

  Future<void> savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('stream_url', _url);
    await prefs.setBool('auto_connect', _autoConnect);
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

  void setUsePcm(bool value) {
    _usePcm = value;
    notifyListeners();
  }

  Future<void> init() async {
    await loadPrefs();
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

  void _scheduleReconnect() {
    if (!_autoConnect) return;
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
        theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
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
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Switch(value: pc.usePcm, onChanged: (v) => setState(() { pc.setUsePcm(v); })),
                const SizedBox(width: 8),
                const Text('Low-latency (PCM over USB)')
              ],
            ),
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
            const Spacer(),
            _Controls(controller: pc),
          ],
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
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            FilledButton.icon(
              icon: Icon(controller.player.playing ? Icons.pause : Icons.play_arrow),
              label: Text(controller.player.playing ? 'Pause' : 'Play'),
              onPressed: () async {
                if (controller.player.playing) {
                  await controller.pause();
                } else {
                  await controller.play();
                }
              },
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Reconnect'),
              onPressed: () async {
                await controller.stop();
                await controller.connectAndPlay();
              },
            ),
          ],
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



