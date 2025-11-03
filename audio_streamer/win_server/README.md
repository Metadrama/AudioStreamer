Windows Audio Stream Server (HTTP over ADB)

Overview
- Captures Windows system audio via WASAPI loopback
- Encodes Opus and serves Ogg/Opus over HTTP
- Maintains `adb reverse tcp:7350 tcp:7350` to stream over USB debugging
- Works with the Flutter Android client at http://127.0.0.1:7350/stream.opus

Build
- Open `win_server/AudioStreamer.Server.sln` in Visual Studio 2022+ and build.
- Or CLI: `dotnet build win_server/AudioStreamer.Server/AudioStreamer.Server.csproj -c Release`

Run
- Ensure `adb` is on PATH (`adb --version`).
- Run: `dotnet run --project win_server/AudioStreamer.Server -c Release`
- The server listens on `http://127.0.0.1:7350/stream.opus`.
- If `adb` is available, it periodically issues `adb reverse tcp:7350 tcp:7350`.

Environment Variables (optional)
- `AUDIOSTREAMER_PORT` (default 7350)
- `AUDIOSTREAMER_BITRATE` (default 128000)
- `AUDIOSTREAMER_FRAME_MS` (default 20)
- `AUDIOSTREAMER_SINGLE_CLIENT` (true/false, default true)
- `AUDIOSTREAMER_ADB_REVERSE` (true/false, default true)

Notes
- Most Windows systems use 48 kHz stereo for the system mix. If yours differs, streaming still works, but a future update will add built-in resampling.
- Only one client is allowed at a time (simple and stable). If needed, we can add multi-client fanout later.

