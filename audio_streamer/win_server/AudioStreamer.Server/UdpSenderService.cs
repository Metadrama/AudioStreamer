using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using NAudio.CoreAudioApi;
using NAudio.Wave;

class UdpSenderService : BackgroundService
{
    private readonly MutableConfig _live;
    private readonly CaptureManager _cap;
    private readonly ILogger<UdpSenderService> _logger;

    public UdpSenderService(MutableConfig cfg, CaptureManager cap, ILogger<UdpSenderService> logger)
    {
        _live = cfg;
        _cap = cap;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        // Port for UDP audio: 7354 (as proposed)
        using var udp = new UdpClient();
        udp.EnableBroadcast = true;
        var endpoint = new IPEndPoint(IPAddress.Broadcast, 7354);

        _logger.LogInformation("[udp] Sniper sender started on port 7354 (Broadcast)");

        try
        {
            await StreamUdpAsync(udp, endpoint, _live.Snapshot(), ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _logger.LogError(ex, "[udp] Global error");
        }
    }

    private async Task StreamUdpAsync(UdpClient udp, IPEndPoint endpoint, ServerConfig cfg, CancellationToken ct)
    {
        using var mm = new MMDeviceEnumerator();
        MMDevice? devCandidate = null;
        try { if (!string.IsNullOrWhiteSpace(cfg.DeviceId)) devCandidate = mm.GetDevice(cfg.DeviceId); } catch { }
        using var device = devCandidate ?? mm.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        
        using var capture = new WasapiLoopbackCapture(device);
        var buffered = new BufferedWaveProvider(capture.WaveFormat) { DiscardOnBufferOverflow = true, BufferDuration = TimeSpan.FromMilliseconds(120), ReadFully = true };
        capture.DataAvailable += (s, a) => buffered.AddSamples(a.Buffer, 0, a.BytesRecorded);
        capture.StartRecording();

        ISampleProvider sampleProvider = buffered.ToSampleProvider();
        if (capture.WaveFormat.SampleRate != 48000) sampleProvider = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(sampleProvider, 48000);
        if (capture.WaveFormat.Channels == 1) sampleProvider = new NAudio.Wave.SampleProviders.MonoToStereoSampleProvider(sampleProvider);
        else if (capture.WaveFormat.Channels != 2) sampleProvider = new DownmixToStereoSampleProvider(sampleProvider);

        int samplesPerFrame = 48000 * 10 / 1000; // 10ms
        int frameBytes = samplesPerFrame * 2 * 2; // 480 * 2ch * 2 bytes
        var floatBuf = new float[samplesPerFrame * 2];
        var shortBuf = new short[samplesPerFrame * 2];
        var packetBuf = new byte[14 + frameBytes];
        
        List<byte[]> fecGroup = new();
        ushort seq = 0;
        long totalSamples = 0;
        
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var frameDuration = TimeSpan.FromMilliseconds(10);
        TimeSpan nextDue = TimeSpan.Zero;

        while (!ct.IsCancellationRequested)
        {
            int read = sampleProvider.Read(floatBuf, 0, floatBuf.Length);
            if (read < floatBuf.Length) Array.Clear(floatBuf, read, floatBuf.Length - read);

            // Simple Gain/Limit
            float gain = cfg.GainLinear;
            for (int i = 0; i < floatBuf.Length; i++) {
                float s = floatBuf[i] * gain;
                shortBuf[i] = (short)Math.Clamp(Math.Round(s * 32767.0f), short.MinValue, short.MaxValue);
            }

            // Construct Packet
            BinaryPrimitives.WriteInt64LittleEndian(packetBuf.AsSpan(0, 8), totalSamples);
            BinaryPrimitives.WriteUInt16LittleEndian(packetBuf.AsSpan(8, 2), seq);
            BinaryPrimitives.WriteUInt16LittleEndian(packetBuf.AsSpan(10, 2), (ushort)frameBytes);
            BinaryPrimitives.WriteUInt16LittleEndian(packetBuf.AsSpan(12, 2), 0); // Flags: 0 = Data
            Buffer.BlockCopy(shortBuf, 0, packetBuf, 14, frameBytes);

            // Send Data
            await udp.SendAsync(packetBuf, packetBuf.Length, endpoint);
            
            // FEC Logic (XOR)
            byte[] payloadCopy = new byte[frameBytes];
            Buffer.BlockCopy(packetBuf, 14, payloadCopy, 0, frameBytes);
            fecGroup.Add(payloadCopy);

            if (fecGroup.Count == 4)
            {
                byte[] parity = new byte[frameBytes];
                for (int i = 0; i < frameBytes; i++)
                    parity[i] = (byte)(fecGroup[0][i] ^ fecGroup[1][i] ^ fecGroup[2][i] ^ fecGroup[3][i]);

                byte[] parityPacket = new byte[14 + frameBytes];
                BinaryPrimitives.WriteInt64LittleEndian(parityPacket.AsSpan(0, 8), totalSamples);
                BinaryPrimitives.WriteUInt16LittleEndian(parityPacket.AsSpan(8, 2), (ushort)(seq + 10000)); // Distinct seq for parity? Or just rely on flags
                BinaryPrimitives.WriteUInt16LittleEndian(parityPacket.AsSpan(10, 2), (ushort)frameBytes);
                BinaryPrimitives.WriteUInt16LittleEndian(parityPacket.AsSpan(12, 2), 1); // Flags: 1 = XOR Parity
                Buffer.BlockCopy(parity, 0, parityPacket, 14, frameBytes);
                
                await udp.SendAsync(parityPacket, parityPacket.Length, endpoint);
                fecGroup.Clear();
            }

            seq++;
            totalSamples += samplesPerFrame;

            nextDue += frameDuration;
            var sleep = nextDue - sw.Elapsed;
            if (sleep > TimeSpan.Zero) await Task.Delay(sleep, ct);
        }
    }
}
