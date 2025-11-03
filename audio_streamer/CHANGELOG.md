Changelog

All notable changes to this project are documented here.

0.4.0 – Ultra‑Low‑Latency PCM (2025‑11‑03)
- Added PCM over TCP for ultra‑low‑latency playback
  - Windows server: new TCP listener on tcp://127.0.0.1:7352 streaming 48 kHz, stereo, 16‑bit PCM in 10 ms frames.
  - Android: foreground service PcmService using AudioTrack (low‑latency mode) to play the PCM stream.
  - ADB reverse for PCM added (adb reverse tcp:7352 tcp:7352).
  - Flutter: mode toggle (PCM vs Compatibility/Opus) with PCM as default; preference persisted.
  - Foreground media playback: continues with screen off; notification shown.
- Audio quality improvements
  - Removed aggressive auto‑boost by default; added clean peak limiter (attenuation only) with default ceiling at −1 dBFS.
  - Optional fixed gain via AUDIOSTREAMER_GAIN_DB (defaults to 0 dB).
- UX
  - Added simple banner indicating PCM mode; groundwork for native “connected/error” events.

0.3.0 – Robust Streaming + Stability (2025‑11‑03)
- Custom Ogg/Opus streaming pipeline (server)
  - WASAPI loopback capture → resample/downmix → Opus encode (Concentus) → Ogg packetization on the fly.
  - Correct Ogg page termination (adds zero‑length lacing when needed) to avoid extractor stalls.
  - Enabled sync response writes for the /stream.opus endpoint; added application/ogg; codecs=opus content type.
  - Real‑time pacing (per‑frame) to maintain steady cadence and prevent bursts/gaps.
  - Coalesced HTTP writes (flush interval configurable) to reduce tunneling overhead.
  - Silence fill when capture starves (prevents decoder under‑runs and compounding stutter).
- Tuning defaults (favor stability first)
  - Frame size and buffer defaults adjusted; flush interval introduced.
  - All knobs exposed via environment variables (see below).

0.2.0 – Android Client Latency + Reliability (2025‑11‑03)
- Flutter client (Compatibility mode):
  - just_audio ExoPlayer with low‑latency buffer settings (min/max/thresholds).
  - Removed just_audio_background due to sqflite lock in debug; simplified foreground handling for Opus path.
  - Persistence for URL and auto‑connect.
  - Status UI (Connecting/Buffering/Playing/Reconnecting) + manual Reconnect.
- Android network security: cleartext allowed for loopback; manifest updated with INTERNET and foreground service permission.

0.1.0 – Initial MVP (2025‑11‑03)
- Windows server
  - .NET 8 app with WASAPI loopback capture (NAudio) and Opus encoding (Concentus).
  - HTTP endpoint /stream.opus served via Kestrel bound to 127.0.0.1:PORT.
  - ADB reverse management (periodically re‑applies for connected devices).
- Android Flutter client
  - Basic UI; streams Opus from http://127.0.0.1:7350/stream.opus.

Environment Variables (Windows server)
- AUDIOSTREAMER_PORT (default 7350) – HTTP Ogg/Opus port
- AUDIOSTREAMER_PCM_PORT (default 7352) – TCP PCM port
- AUDIOSTREAMER_BITRATE (default 160000) – Opus bitrate (bps)
- AUDIOSTREAMER_FRAME_MS – Opus frame size (ms) (e.g., 10/20/40)
- AUDIOSTREAMER_FLUSH_INTERVAL_MS – HTTP flush cadence (ms)
- AUDIOSTREAMER_SINGLE_CLIENT (default true) – enforce single client
- AUDIOSTREAMER_ADB_REVERSE (default true) – auto‑run adb reverse
- AUDIOSTREAMER_GAIN_DB (default 0) – fixed preamp gain (dB)
- AUDIOSTREAMER_TARGET_PEAK_DBFS (default -1) – limiter ceiling (dBFS)
- AUDIOSTREAMER_MAX_BOOST_DB (default 0) – limiter boost cap (kept at 0 to avoid pumping)

Notes
- Use Release builds on both Windows and Android to measure real latency and stability.
- Only one mode is active at a time (PCM or Opus). The app stops the other path when switching.
- If the device disconnects, the server re‑applies adb reverse every ~15s.

Known Issues / Next
- Add native → Flutter events for PCM (connected, error, disconnected) with toasts and status.
- Optional diagnostics panel: jitter/latency estimate from AudioTrack queued frames.
- Convert server Ogg/Opus writes to fully async (remove AllowSynchronousIO) once validated.
- Optional tray UI for Windows server (start/stop, bitrate/frame presets, device status).

