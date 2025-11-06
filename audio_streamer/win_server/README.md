Windows Audio Stream Server (HTTP/TCP over LAN)

Overview
- Captures Windows system audio via WASAPI loopback
- Encodes Opus and serves Ogg/Opus over HTTP
- Provides ultra-low-latency raw PCM over TCP for Android client
- Listens on all interfaces (0.0.0.0) so Android can connect over Wi‑Fi/LAN
- Works with the Flutter Android client at:
  - Opus: http://127.0.0.1:7350/stream.opus
  - PCM:  tcp://127.0.0.1:7352

Build
- Open `win_server/AudioStreamer.Server.sln` in Visual Studio 2022+ and build.
- Or CLI: `dotnet build win_server/AudioStreamer.Server/AudioStreamer.Server.csproj -c Release`

Run
- Ensure `adb` is on PATH (`adb --version`) if you plan to use USB debugging (ADB reverse).
- Run: `dotnet run --project win_server/AudioStreamer.Server -c Release`
- By default, the server auto-applies `adb reverse` every ~15s for all connected devices (can be disabled via env below).
- The server listens on `http://0.0.0.0:7350/stream.opus` (Opus) and `tcp://0.0.0.0:7352` (PCM).
  Use your PC's LAN IP (e.g., `http://192.168.1.50:7350/stream.opus`) in the Android app. PCM mode will use the same host on port 7352.

Environment Variables (optional)
- `AUDIOSTREAMER_PORT` (default 7350)
- `AUDIOSTREAMER_PCM_PORT` (default 7352)
- `AUDIOSTREAMER_BITRATE` (default 320000)
- `AUDIOSTREAMER_FRAME_MS` (default 10)
- `AUDIOSTREAMER_FLUSH_INTERVAL_MS` (default 30)
- `AUDIOSTREAMER_GAIN_DB` (default 0)
- `AUDIOSTREAMER_NORMALIZE` (default false)
- `AUDIOSTREAMER_TARGET_PEAK_DBFS` (default -1)
- `AUDIOSTREAMER_MAX_BOOST_DB` (default 0)
- `AUDIOSTREAMER_OPUS_USE_VBR` (true/false, default false)
- Defaults aim for smooth playback: CBR, 10 ms frames, 30 ms flush.
- `AUDIOSTREAMER_OPUS_VBR_CONSTRAINED` (true/false, default true)
- `AUDIOSTREAMER_OPUS_COMPLEXITY` (0-10, default 10)
- `AUDIOSTREAMER_OPUS_RESTRICTED_LOWDELAY` (true/false, default false)
- `AUDIOSTREAMER_DEVICE_ID` (optional) – WASAPI device ID to capture; defaults to system multimedia device
- `AUDIOSTREAMER_SINGLE_CLIENT` (true/false, default true)
- `AUDIOSTREAMER_ADB_REVERSE` (true/false, default true) — auto-apply `adb reverse` for HTTP/PCM ports

Wi‑Fi/LAN setup
- Ensure Windows Firewall allows inbound TCP on ports 7350 and 7352 for this app.
- For automatic discovery, also allow inbound UDP on port 7531.
- Phone and PC must be on the same network (Wi‑Fi/LAN) or reachable via VPN.
- In the Android app, set Server URL to `http://<PC_LAN_IP>:7350/stream.opus` and tap Connect.

Automatic discovery (optional)
- The server listens for UDP discovery on port 7531. The Android app can broadcast a probe and the server replies with its Opus/PCM ports and hostname.
Notes
- Most Windows systems use 48 kHz stereo for the system mix. If yours differs, streaming still works — the server resamples to 48 kHz stereo.
- Only one client is allowed at a time (simple and stable). If needed, we can add multi-client fanout later.

Latency tips
- Use the PCM endpoint on Android for the lowest possible latency.
- For Opus, lower `AUDIOSTREAMER_FRAME_MS` (e.g., 10–20) and keep `AUDIOSTREAMER_FLUSH_INTERVAL_MS` close to the frame size.
- If you hear micro-stutters, try:
  - Constrained VBR: `AUDIOSTREAMER_OPUS_USE_VBR=true` and `AUDIOSTREAMER_OPUS_VBR_CONSTRAINED=true`
  - Or CBR: `AUDIOSTREAMER_OPUS_USE_VBR=false`
  - Slightly higher flush: `AUDIOSTREAMER_FLUSH_INTERVAL_MS=40`
  - As a last resort for minimum algorithmic delay: `AUDIOSTREAMER_OPUS_RESTRICTED_LOWDELAY=true`

Runtime preferences
- GET `http://127.0.0.1:7350/config` returns current settings.
- POST `http://127.0.0.1:7350/config` with JSON to apply for next streams (current streams keep their snapshot):
  `{ "bitrate": 320000, "frame_ms": 20, "flush_ms": 40, "opus_use_vbr": false }`
- List devices: GET `http://127.0.0.1:7350/devices` (returns `[{id,name,state,isDefault,isDefaultComm}]`)
