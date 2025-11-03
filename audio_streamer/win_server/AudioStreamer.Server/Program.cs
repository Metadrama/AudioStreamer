using System.Diagnostics;
using System.Buffers;
using System.Runtime.InteropServices;
using Concentus.Enums;
using Concentus.Structs;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Microsoft.AspNetCore.Http.Features;
using System.Runtime.Versioning;

var builder = WebApplication.CreateBuilder(args);

// Settings
int port = GetEnvInt("AUDIOSTREAMER_PORT", 7350);
int pcmPort = GetEnvInt("AUDIOSTREAMER_PCM_PORT", 7352);
int bitrate = GetEnvInt("AUDIOSTREAMER_BITRATE", 192_000);
int frameMs = GetEnvInt("AUDIOSTREAMER_FRAME_MS", 20); // 20ms: lower latency, good stability
int gainDb = GetEnvInt("AUDIOSTREAMER_GAIN_DB", 0); // fixed preamp in dB (default 0 to avoid distortion)
bool normalize = GetEnvBool("AUDIOSTREAMER_NORMALIZE", false); // disable boost by default
int targetPeakDbfs = GetEnvInt("AUDIOSTREAMER_TARGET_PEAK_DBFS", -1); // limiter ceiling
int maxBoostDb = GetEnvInt("AUDIOSTREAMER_MAX_BOOST_DB", 0); // no auto boost; attenuation only
int flushIntervalMs = GetEnvInt("AUDIOSTREAMER_FLUSH_INTERVAL_MS", 40); // slightly larger to smooth bursts
bool opusUseVbr = GetEnvBool("AUDIOSTREAMER_OPUS_USE_VBR", false); // default CBR to avoid burstiness
bool opusVbrConstrained = GetEnvBool("AUDIOSTREAMER_OPUS_VBR_CONSTRAINED", true); // reduce VBR bursts
int opusComplexity = GetEnvInt("AUDIOSTREAMER_OPUS_COMPLEXITY", 10); // 0..10
bool opusRestrictedLowDelay = GetEnvBool("AUDIOSTREAMER_OPUS_RESTRICTED_LOWDELAY", false); // trade quality for latency
bool singleClient = GetEnvBool("AUDIOSTREAMER_SINGLE_CLIENT", true);
bool autoAdbReverse = GetEnvBool("AUDIOSTREAMER_ADB_REVERSE", true);

builder.Services.AddSingleton(new ServerConfig(port, pcmPort, bitrate, frameMs, singleClient, autoAdbReverse, gainDb, normalize, targetPeakDbfs, maxBoostDb, flushIntervalMs,
    opusUseVbr, opusVbrConstrained, opusComplexity, opusRestrictedLowDelay));
builder.Services.AddSingleton<CaptureManager>();
builder.Services.AddHostedService<AdbReverseService>();
builder.Services.AddHostedService<PcmTcpServerService>();

var app = builder.Build();

// Improve Windows timer resolution to reduce scheduling jitter
try
{
    WinMM.TimeBeginPeriod(1);
    try { Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.High; } catch { }
}
catch { }

app.MapGet("/", () => Results.Text("AudioStreamer.Server running. GET /stream.opus for audio."));

var connectionLock = new object();
bool clientConnected = false;

app.MapGet("/stream.opus", async (HttpContext ctx, CaptureManager cap, ServerConfig cfg) =>
{
    ctx.Response.StatusCode = 200;
    ctx.Response.Headers["Content-Type"] = "application/ogg; codecs=opus";
    ctx.Response.Headers["Cache-Control"] = "no-store";
    ctx.Response.Headers["Pragma"] = "no-cache";
    var bodyCtrl = ctx.Features.Get<IHttpBodyControlFeature>();
    if (bodyCtrl != null) bodyCtrl.AllowSynchronousIO = true;

    if (cfg.SingleClient)
    {
        lock (connectionLock)
        {
            if (clientConnected)
            {
                ctx.Response.StatusCode = 409;
                return;
            }
            clientConnected = true;
        }
    }

    var abortToken = ctx.RequestAborted;
    try
    {
        await cap.StreamToAsync(ctx.Response.Body, abortToken);
    }
    catch (OperationCanceledException)
    {
        // client disconnected
    }
    catch (Exception ex)
    {
        Console.WriteLine($"[stream] Error: {ex}");
    }
    finally
    {
        if (cfg.SingleClient)
        {
            lock (connectionLock) clientConnected = false;
        }
        await ctx.Response.Body.FlushAsync();
    }
});

app.Lifetime.ApplicationStarted.Register(() =>
{
    Console.WriteLine($"AudioStreamer.Server listening on http://127.0.0.1:{port}/stream.opus");
    Console.WriteLine($"PCM (ultra-low-latency) on tcp://127.0.0.1:{pcmPort}");
    Console.WriteLine("Tip: adb reverse tcp:7350 tcp:7350");
    Console.WriteLine("Tip: adb reverse tcp:7352 tcp:7352");
});

// Restore timer resolution on shutdown
app.Lifetime.ApplicationStopping.Register(() =>
{
    try { WinMM.TimeEndPeriod(1); } catch { }
});

app.Urls.Clear();
app.Urls.Add($"http://127.0.0.1:{port}");

await app.RunAsync();

static int GetEnvInt(string key, int def) => int.TryParse(Environment.GetEnvironmentVariable(key), out var v) ? v : def;
static bool GetEnvBool(string key, bool def) => bool.TryParse(Environment.GetEnvironmentVariable(key), out var v) ? v : def;

record ServerConfig(int Port, int PcmPort, int Bitrate, int FrameMs, bool SingleClient, bool AutoAdbReverse, int GainDb, bool Normalize, int TargetPeakDbfs, int MaxBoostDb, int FlushIntervalMs,
    bool OpusUseVbr, bool OpusVbrConstrained, int OpusComplexity, bool OpusRestrictedLowDelay)
{
    public int SamplesPerFrame => 48000 * FrameMs / 1000; // e.g., 960 for 20ms
    public float GainLinear => (float)Math.Pow(10.0, GainDb / 20.0);
    public float TargetPeakLinear => (float)Math.Pow(10.0, TargetPeakDbfs / 20.0); // e.g., -3 dBFS ≈ 0.7079
    public float MaxBoostLinear => (float)Math.Pow(10.0, MaxBoostDb / 20.0);
}

static class WinMM
{
    [DllImport("winmm.dll")]
    public static extern uint timeBeginPeriod(uint uMilliseconds);
    [DllImport("winmm.dll")]
    public static extern uint timeEndPeriod(uint uMilliseconds);

    public static void TimeBeginPeriod(uint ms) => timeBeginPeriod(ms);
    public static void TimeEndPeriod(uint ms) => timeEndPeriod(ms);
}

class CaptureManager
{
    private readonly ServerConfig _cfg;

    public CaptureManager(ServerConfig cfg)
    {
        _cfg = cfg;
    }

    public async Task StreamToAsync(Stream output, CancellationToken ct)
    {
        try { System.Threading.Thread.CurrentThread.Priority = System.Threading.ThreadPriority.AboveNormal; } catch { }
        using var mm = new MMDeviceEnumerator();
        using var device = mm.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        using var capture = new WasapiLoopbackCapture(device);

        if (capture.WaveFormat.SampleRate != 48000 || capture.WaveFormat.Channels != 2)
        {
            Console.WriteLine($"[info] Mix format: {capture.WaveFormat.SampleRate} Hz, {capture.WaveFormat.Channels} ch. Resampling/Channel adjust will be applied.");
        }

        var buffered = new BufferedWaveProvider(capture.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromMilliseconds(200), // keep small to avoid buildup
            ReadFully = false
        };

        capture.DataAvailable += (s, a) =>
        {
            buffered.AddSamples(a.Buffer, 0, a.BytesRecorded);
        };

        capture.StartRecording();

        // Build sample pipeline -> float32 -> (optional) resample to 48000
        ISampleProvider sampleProvider = buffered.ToSampleProvider();
        if (capture.WaveFormat.SampleRate != 48000)
        {
            sampleProvider = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(sampleProvider, 48000);
        }
        // Channel adjust to stereo if needed
        if (capture.WaveFormat.Channels == 1)
        {
            sampleProvider = new NAudio.Wave.SampleProviders.MonoToStereoSampleProvider(sampleProvider);
        }
        else if (capture.WaveFormat.Channels != 2)
        {
            sampleProvider = new DownmixToStereoSampleProvider(sampleProvider);
        }

        int samplesPerFrame = _cfg.SamplesPerFrame; // per channel
        int frameSamplesInterleaved = samplesPerFrame * 2;

        var application = _cfg.OpusRestrictedLowDelay ? Concentus.Enums.OpusApplication.OPUS_APPLICATION_RESTRICTED_LOWDELAY
                                                      : Concentus.Enums.OpusApplication.OPUS_APPLICATION_AUDIO;
        var enc = new Concentus.Structs.OpusEncoder(48000, 2, application);
        enc.Bitrate = _cfg.Bitrate;
        enc.UseVBR = _cfg.OpusUseVbr;
        enc.MaxBandwidth = Concentus.Enums.OpusBandwidth.OPUS_BANDWIDTH_FULLBAND;
        enc.Complexity = Math.Clamp(_cfg.OpusComplexity, 0, 10);
        // If available in newer Concentus, we can set SignalType and VBR constraints
        // Keep defaults here for compatibility. Avoid in-band FEC for minimal latency.

        using var bufferedOut = new BufferedStream(output, 16384);
        using var ogg = new OggOpusStreamWriter(bufferedOut, 48000, 2);
        await bufferedOut.FlushAsync(ct); // push OpusHead/OpusTags immediately

        var floatBuf = new float[frameSamplesInterleaved];
        var shortBuf = new short[frameSamplesInterleaved];
        var maxPacket = 4096; // sufficient for stereo @ 20ms
        var packet = new byte[maxPacket];
        float lastL = 0f, lastR = 0f;

        var sw = System.Diagnostics.Stopwatch.StartNew();
        long lastFlushMs = 0;
        long nextDueMs = sw.ElapsedMilliseconds; // wall-clock pacing
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int read = 0;
                int zeroReads = 0;
                while (read < floatBuf.Length && !ct.IsCancellationRequested)
                {
                    int n = sampleProvider.Read(floatBuf, read, floatBuf.Length - read);
                    if (n == 0)
                    {
                        if (zeroReads < 5)
                        {
                            zeroReads++;
                            await Task.Delay(1, ct); // short wait to avoid padding with silence
                            continue;
                        }
                        // After short grace, pad remainder with last sample to avoid clicks
                        for (int i = read; i < floatBuf.Length; i += 2)
                        {
                            floatBuf[i] = lastL;
                            floatBuf[i + 1] = lastR;
                        }
                        read = floatBuf.Length;
                        break;
                    }
                    zeroReads = 0;
                    read += n;
                }
                if (ct.IsCancellationRequested) break;

                // Apply fixed gain with a peak limiter (attenuation only)
                float gain = _cfg.GainLinear;
                float peak = 0f;
                for (int i = 0; i < floatBuf.Length; i++)
                {
                    float a = MathF.Abs(floatBuf[i]);
                    if (a > peak) peak = a;
                }
                if (peak > 1e-9f)
                {
                    float postPeak = peak * gain;
                    float ceiling = _cfg.TargetPeakLinear; // e.g., -1 dBFS
                    if (postPeak > ceiling)
                    {
                        float atten = ceiling / postPeak;
                        gain *= atten;
                    }
                }
                for (int i = 0; i < floatBuf.Length; i++)
                {
                    float s = floatBuf[i] * gain;
                    if (s > 1f) s = 1f; if (s < -1f) s = -1f;
                    int v = (int)Math.Round(s * 32767.0f);
                    if (v > short.MaxValue) v = short.MaxValue;
                    if (v < short.MinValue) v = short.MinValue;
                    shortBuf[i] = (short)v;
                }
                // Track last sample to smooth underrun padding
                lastL = floatBuf[floatBuf.Length - 2];
                lastR = floatBuf[floatBuf.Length - 1];

                // Encode to Opus
                int encoded = enc.Encode(shortBuf, 0, samplesPerFrame, packet, 0, packet.Length);
                if (encoded > 0)
                {
                    ogg.WritePacket(packet, encoded, samplesPerFrame);
                }
                // Coalesce writes and flush periodically to reduce USB/HTTP overhead
                var nowMs = sw.ElapsedMilliseconds;
                if (nowMs - lastFlushMs >= _cfg.FlushIntervalMs)
                {
                    await bufferedOut.FlushAsync(ct);
                    lastFlushMs = nowMs;
                }

                // Real-time pacing: target one packet every frameMs
                nextDueMs += _cfg.FrameMs;
                var sleep = (int)(nextDueMs - sw.ElapsedMilliseconds);
                if (sleep > 0)
                {
                    await Task.Delay(sleep, ct);
                }
            }
        }
        finally
        {
            try { ogg.Finish(); } catch { /* ignore */ }
            if (capture.CaptureState == CaptureState.Capturing)
            {
                try { capture.StopRecording(); } catch { /* ignore */ }
            }
        }
    }
}

class DownmixToStereoSampleProvider : ISampleProvider
{
    private readonly ISampleProvider _source;
    private readonly int _sourceChannels;
    public DownmixToStereoSampleProvider(ISampleProvider source)
    {
        _source = source;
        _sourceChannels = source.WaveFormat.Channels;
        if (_sourceChannels < 1) throw new ArgumentException("Source must have at least 1 channel");
    }

    public WaveFormat WaveFormat => WaveFormat.CreateIeeeFloatWaveFormat(_source.WaveFormat.SampleRate, 2);

    public int Read(float[] buffer, int offset, int count)
    {
        int framesRequested = count / 2;
        int srcCount = framesRequested * _sourceChannels;
        var temp = ArrayPool<float>.Shared.Rent(srcCount);
        try
        {
            int read = _source.Read(temp, 0, srcCount);
            int srcFramesRead = read / _sourceChannels;
            for (int i = 0; i < srcFramesRead; i++)
            {
                float l, r;
                if (_sourceChannels >= 2)
                {
                    l = temp[i * _sourceChannels + 0];
                    r = temp[i * _sourceChannels + 1];
                }
                else
                {
                    var m = temp[i * _sourceChannels + 0];
                    l = m; r = m;
                }
                buffer[offset + i * 2 + 0] = l;
                buffer[offset + i * 2 + 1] = r;
            }
            return srcFramesRead * 2;
        }
        finally
        {
            ArrayPool<float>.Shared.Return(temp);
        }
    }
}

class AdbReverseService : BackgroundService
{
    private readonly ServerConfig _cfg;
    public AdbReverseService(ServerConfig cfg) => _cfg = cfg;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        if (!_cfg.AutoAdbReverse) return;
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                RunAdb($"reverse tcp:{_cfg.Port} tcp:{_cfg.Port}");
                RunAdb($"reverse tcp:{_cfg.PcmPort} tcp:{_cfg.PcmPort}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[adb] {ex.Message}");
            }
            await Task.Delay(TimeSpan.FromSeconds(15), stoppingToken);
        }
    }

    private static void RunAdb(string args)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "adb",
            Arguments = args,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var p = Process.Start(psi);
        if (p == null) throw new Exception("Failed to start adb");
        p.WaitForExit(5000);
        if (p.ExitCode != 0)
        {
            var err = p.StandardError.ReadToEnd();
            if (!string.IsNullOrWhiteSpace(err))
                Console.WriteLine($"[adb] {err.Trim()}");
        }
    }
}

// Ultra-low-latency PCM over TCP for Android AudioTrack client
class PcmTcpServerService : BackgroundService
{
    private readonly ServerConfig _cfg;
    private readonly CaptureManager _cap;
    public PcmTcpServerService(ServerConfig cfg, CaptureManager cap)
    {
        _cfg = cfg; _cap = cap;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, _cfg.PcmPort);
        listener.Server.NoDelay = true;
        listener.Start();
        Console.WriteLine("[pcm] TCP listener started");
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stoppingToken);
                _ = Task.Run(() => HandleClientAsync(client, stoppingToken));
            }
        }
        catch (OperationCanceledException) { }
        finally { listener.Stop(); }
    }

    private async Task HandleClientAsync(System.Net.Sockets.TcpClient client, CancellationToken ct)
    {
        Console.WriteLine("[pcm] client connected");
        client.NoDelay = true;
        using var stream = client.GetStream();
        try
        {
            await StreamPcmAsync(stream, ct);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[pcm] error: {ex.Message}");
        }
        finally
        {
            client.Close();
            Console.WriteLine("[pcm] client disconnected");
        }
    }

    private async Task StreamPcmAsync(Stream output, CancellationToken ct)
    {
        try { System.Threading.Thread.CurrentThread.Priority = System.Threading.ThreadPriority.AboveNormal; } catch { }
        using var mm = new MMDeviceEnumerator();
        using var device = mm.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        using var capture = new WasapiLoopbackCapture(device);

        var buffered = new BufferedWaveProvider(capture.WaveFormat)
        {
            DiscardOnBufferOverflow = true,
            BufferDuration = TimeSpan.FromMilliseconds(50),
            ReadFully = false
        };
        capture.DataAvailable += (s, a) => buffered.AddSamples(a.Buffer, 0, a.BytesRecorded);
        capture.StartRecording();

        ISampleProvider sampleProvider = buffered.ToSampleProvider();
        if (capture.WaveFormat.SampleRate != 48000)
            sampleProvider = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(sampleProvider, 48000);
        if (capture.WaveFormat.Channels == 1)
            sampleProvider = new NAudio.Wave.SampleProviders.MonoToStereoSampleProvider(sampleProvider);
        else if (capture.WaveFormat.Channels != 2)
            sampleProvider = new DownmixToStereoSampleProvider(sampleProvider);

        int samplesPerFrame = 48000 * 10 / 1000; // 10ms frames for PCM
        int frameSamplesInterleaved = samplesPerFrame * 2;
        var floatBuf = new float[frameSamplesInterleaved];
        var shortBuf = new short[frameSamplesInterleaved];
        var byteBuf = new byte[frameSamplesInterleaved * 2];

        var sw = System.Diagnostics.Stopwatch.StartNew();
        long due = sw.ElapsedMilliseconds;
        float lastL = 0f, lastR = 0f;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                int read = 0;
                int zeroReads = 0;
                while (read < floatBuf.Length && !ct.IsCancellationRequested)
                {
                    int n = sampleProvider.Read(floatBuf, read, floatBuf.Length - read);
                    if (n == 0)
                    {
                        if (zeroReads < 3)
                        {
                            zeroReads++;
                            await Task.Delay(1, ct);
                            continue;
                        }
                        for (int i = read; i < floatBuf.Length; i += 2)
                        {
                            floatBuf[i] = lastL;
                            floatBuf[i + 1] = lastR;
                        }
                        read = floatBuf.Length;
                        break;
                    }
                    zeroReads = 0;
                    read += n;
                }

                // convert with fixed gain + peak limiter (attenuation only)
                float gain = _cfg.GainLinear;
                float peak = 0f;
                for (int i = 0; i < floatBuf.Length; i++) { var a = MathF.Abs(floatBuf[i]); if (a > peak) peak = a; }
                if (peak > 1e-9f)
                {
                    float postPeak = peak * gain;
                    float ceiling = _cfg.TargetPeakLinear;
                    if (postPeak > ceiling)
                    {
                        float atten = ceiling / postPeak;
                        gain *= atten;
                    }
                }
                for (int i = 0; i < floatBuf.Length; i++)
                {
                    float s = floatBuf[i] * gain;
                    if (s > 1f) s = 1f; if (s < -1f) s = -1f;
                    short v = (short)Math.Round(s * 32767.0f);
                    shortBuf[i] = v;
                }
                Buffer.BlockCopy(shortBuf, 0, byteBuf, 0, byteBuf.Length);
                lastL = floatBuf[floatBuf.Length - 2];
                lastR = floatBuf[floatBuf.Length - 1];
                await output.WriteAsync(byteBuf, 0, byteBuf.Length, ct);
                await output.FlushAsync(ct);

                due += 10;
                int sleep = (int)(due - sw.ElapsedMilliseconds);
                if (sleep > 0) await Task.Delay(sleep, ct);
            }
        }
        finally
        {
            try { capture.StopRecording(); } catch { }
        }
    }
}

// Minimal Ogg/Opus streaming writer for a single stream
sealed class OggOpusStreamWriter : IDisposable
{
    private readonly Stream _out;
    private readonly int _rate;
    private readonly int _channels;
    private readonly uint _serial;
    private uint _seq;
    private long _granule;
    private bool _disposed;
    private readonly ArrayPool<byte> _pool = ArrayPool<byte>.Shared;

    public OggOpusStreamWriter(Stream output, int sampleRate, int channels)
    {
        _out = output;
        _rate = sampleRate;
        _channels = channels;
        _serial = (uint)Random.Shared.Next();
        _seq = 0;
        _granule = 0;

        WriteOpusHead();
        WriteOpusTags();
    }

    public void WritePacket(byte[] data, int length, int samplesPerPacket)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(OggOpusStreamWriter));
        _granule += samplesPerPacket;
        WriteOggPage(data, length, 0x00, _granule, terminatePacket: true);
    }

    public void Finish()
    {
        if (_disposed) return;
        _disposed = true;
        // Optionally write EOS page; many players do not require it for live streams
    }

    public void Dispose()
    {
        Finish();
    }

    private void WriteOpusHead()
    {
        var payload = _pool.Rent(19);
        try
        {
            var span = payload.AsSpan(0, 19);
            WriteAscii(span, 0, "OpusHead");
            span[8] = 1; // version
            span[9] = (byte)_channels;
            WriteLE16(span, 10, 0); // pre-skip
            WriteLE32(span, 12, (uint)_rate);
            WriteLE16(span, 16, 0); // output gain
            span[18] = 0; // mapping family
            WriteOggPage(payload, 19, 0x02, 0); // BOS
            _out.Flush();
        }
        finally { _pool.Return(payload); }
    }

    private void WriteOpusTags()
    {
        var vendorBytes = System.Text.Encoding.UTF8.GetBytes("AudioStreamer.Server");
        int payloadLen = 8 + 4 + vendorBytes.Length + 4;
        var payload = _pool.Rent(payloadLen);
        try
        {
            var span = payload.AsSpan(0, payloadLen);
            WriteAscii(span, 0, "OpusTags");
            WriteLE32(span, 8, (uint)vendorBytes.Length);
            vendorBytes.AsSpan().CopyTo(span.Slice(12, vendorBytes.Length));
            WriteLE32(span, 12 + vendorBytes.Length, 0);
            WriteOggPage(payload, payloadLen, 0x00, 0);
            _out.Flush();
        }
        finally { _pool.Return(payload); }
    }

    private void WriteOggPage(byte[] payload, int payloadLen, byte headerType, long granulePos, bool terminatePacket = false)
    {
        int segCount = (payloadLen + 254) / 255;
        if (terminatePacket && segCount > 0 && (payloadLen % 255 == 0)) segCount += 1;

        int headerLen = 27 + segCount;
        int totalLen = headerLen + payloadLen;
        var arr = _pool.Rent(totalLen);
        try
        {
            var span = arr.AsSpan(0, totalLen);
            // Header
            WriteAscii(span, 0, "OggS");
            span[4] = 0; // version
            span[5] = headerType; // header type
            WriteLE64(span, 6, (ulong)granulePos);
            WriteLE32(span, 14, _serial);
            WriteLE32(span, 18, (uint)_seq++);
            WriteLE32(span, 22, 0); // checksum placeholder
            span[26] = (byte)segCount;
            // Lacing
            int off = 27;
            int remaining = payloadLen;
            while (remaining > 0)
            {
                int seg = Math.Min(255, remaining);
                span[off++] = (byte)seg;
                remaining -= seg;
            }
            if (terminatePacket && (payloadLen % 255 == 0))
            {
                span[off++] = 0;
            }
            // Body
            payload.AsSpan(0, payloadLen).CopyTo(span.Slice(off, payloadLen));
            // CRC over totalLen
            SetChecksum(arr, totalLen);
            _out.Write(arr, 0, totalLen);
        }
        finally { _pool.Return(arr); }
    }

    private static void SetChecksum(byte[] page, int length)
    {
        // CRC is at offset 22
        page[22] = page[23] = page[24] = page[25] = 0;
        uint crc = 0;
        for (int i = 0; i < length; i++)
        {
            byte b = page[i];
            crc = (crc << 8) ^ CrcTable[((crc >> 24) ^ b) & 0xFF];
        }
        page[22] = (byte)(crc & 0xFF);
        page[23] = (byte)((crc >> 8) & 0xFF);
        page[24] = (byte)((crc >> 16) & 0xFF);
        page[25] = (byte)((crc >> 24) & 0xFF);
    }

    private static readonly uint[] CrcTable = CreateCrcTable();
    private static uint[] CreateCrcTable()
    {
        const uint poly = 0x04C11DB7;
        var table = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            uint r = i << 24;
            for (int j = 0; j < 8; j++)
            {
                if ((r & 0x80000000) != 0)
                    r = (r << 1) ^ poly;
                else
                    r <<= 1;
            }
            table[i] = r;
        }
        return table;
    }

    private static void WriteAscii(Span<byte> span, int offset, string text)
    {
        var bytes = System.Text.Encoding.ASCII.GetBytes(text);
        bytes.AsSpan().CopyTo(span.Slice(offset, bytes.Length));
    }
    private static void WriteLE16(Span<byte> span, int offset, ushort value)
    {
        span[offset] = (byte)(value & 0xFF);
        span[offset + 1] = (byte)((value >> 8) & 0xFF);
    }
    private static void WriteLE32(Span<byte> span, int offset, uint value)
    {
        span[offset] = (byte)(value & 0xFF);
        span[offset + 1] = (byte)((value >> 8) & 0xFF);
        span[offset + 2] = (byte)((value >> 16) & 0xFF);
        span[offset + 3] = (byte)((value >> 24) & 0xFF);
    }
    private static void WriteLE64(Span<byte> span, int offset, ulong value)
    {
        span[offset] = (byte)(value & 0xFF);
        span[offset + 1] = (byte)((value >> 8) & 0xFF);
        span[offset + 2] = (byte)((value >> 16) & 0xFF);
        span[offset + 3] = (byte)((value >> 24) & 0xFF);
        span[offset + 4] = (byte)((value >> 32) & 0xFF);
        span[offset + 5] = (byte)((value >> 40) & 0xFF);
        span[offset + 6] = (byte)((value >> 48) & 0xFF);
        span[offset + 7] = (byte)((value >> 56) & 0xFF);
    }
}
