Windows Audio Stream Server (HTTP over ADB)

Overview
- Captures Windows system audio via WASAPI loopback
- Encodes Opus and serves Ogg/Opus over HTTP
- Provides ultra-low-latency raw PCM over TCP for Android client
- Maintains `adb reverse` for both ports (7350 = Opus, 7352 = PCM) when available
- Works with the Flutter Android client at:
  - Opus: http://127.0.0.1:7350/stream.opus
  - PCM:  tcp://127.0.0.1:7352

Build
- Open `win_server/AudioStreamer.Server.sln` in Visual Studio 2022+ and build.
- Or CLI: `dotnet build win_server/AudioStreamer.Server/AudioStreamer.Server.csproj -c Release`

Run
- Ensure `adb` is on PATH (`adb --version`).
- Run: `dotnet run --project win_server/AudioStreamer.Server -c Release`
- The server listens on `http://127.0.0.1:7350/stream.opus` (Opus) and `tcp://127.0.0.1:7352` (PCM).
- If `adb` is available, it periodically issues `adb reverse tcp:7350 tcp:7350` and `adb reverse tcp:7352 tcp:7352`.

Environment Variables (optional)
- `AUDIOSTREAMER_PORT` (default 7350)
- `AUDIOSTREAMER_PCM_PORT` (default 7352)
- `AUDIOSTREAMER_BITRATE` (default 192000)
- `AUDIOSTREAMER_FRAME_MS` (default 20)
- `AUDIOSTREAMER_FLUSH_INTERVAL_MS` (default 20)
- `AUDIOSTREAMER_GAIN_DB` (default 0)
- `AUDIOSTREAMER_NORMALIZE` (default false)
- `AUDIOSTREAMER_TARGET_PEAK_DBFS` (default -1)
- `AUDIOSTREAMER_MAX_BOOST_DB` (default 0)
- `AUDIOSTREAMER_OPUS_USE_VBR` (true/false, default false)
- Defaults aim for smooth playback: CBR, 20 ms frames, 40 ms flush.
- `AUDIOSTREAMER_OPUS_VBR_CONSTRAINED` (true/false, default true)
- `AUDIOSTREAMER_OPUS_COMPLEXITY` (0-10, default 10)
- `AUDIOSTREAMER_OPUS_RESTRICTED_LOWDELAY` (true/false, default false)
- `AUDIOSTREAMER_SINGLE_CLIENT` (true/false, default true)
- `AUDIOSTREAMER_ADB_REVERSE` (true/false, default true)

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
