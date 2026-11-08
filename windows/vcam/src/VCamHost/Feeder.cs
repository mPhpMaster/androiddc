// AndroidDC - feeds the phone's camera into the virtual camera.
//
// It starts scrcpy's own server on the phone with the camera as its video
// source and a raw H.264 stream (no scrcpy headers), reads that stream over
// an adb forward, decodes it with Windows' H.264 decoder, fits each picture
// into 1280x720 and writes it to the camera's shared section.

using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace AndroidDC.VCam
{
    internal sealed unsafe class Feeder : IDisposable
    {
        private const string RemoteServer = "/data/local/tmp/scrcpy-server.jar";

        public string Adb, Server, Serial, ServerVersion = "4.1";
        public string CameraId, CameraFacing, CameraSize = "1280x720";
        public int CameraFps = 30;
        public bool Mirror;

        private Process shell;
        private string forwardPort;
        private TcpClient client;
        private volatile bool stopping;
        private readonly byte[] target = new byte[FrameShare.FrameBytes];
        private FrameShare share;
        private long frames;
        private long lastOpenTry;
        private readonly StringBuilder serverLog = new StringBuilder();

        public long Frames { get { return Interlocked.Read(ref frames); } }

        /// <summary>The phone's picture reached here at least once.</summary>
        public volatile bool Started;

        /// <summary>The same phone and settings, another camera (an id, or a facing).</summary>
        public Feeder WithCamera(string id, string facing, string size)
        {
            return new Feeder
            {
                Adb = Adb, Server = Server, Serial = Serial, ServerVersion = ServerVersion,
                CameraId = id, CameraFacing = facing, CameraSize = size ?? CameraSize,
                CameraFps = CameraFps, Mirror = Mirror,
            };
        }

        /// <summary>Runs until Stop or until the phone's stream ends. Throws with a reason on failure.</summary>
        public void Run(Action<string> status)
        {
            if (!File.Exists(Server)) throw new FileNotFoundException("scrcpy-server not found", Server);
            AdbText("push", Server, RemoteServer);

            string scid = (new Random().Next(1, int.MaxValue)).ToString("x8");
            forwardPort = AdbText("forward", "tcp:0", "localabstract:scrcpy_" + scid).Trim();
            int port;
            if (!int.TryParse(forwardPort, out port)) throw new InvalidOperationException("adb forward gave no port: " + forwardPort);

            var options = new StringBuilder();
            options.Append("scid=").Append(scid)
                .Append(" log_level=info video_source=camera video_codec=h264 audio=false control=false")
                .Append(" tunnel_forward=true raw_stream=true cleanup=true")
                .Append(" camera_fps=").Append(CameraFps);
            // "auto": the phone has no 1280x720, let scrcpy pick; the picture is fitted anyway
            if (!string.IsNullOrEmpty(CameraSize) && CameraSize != "auto") options.Append(" camera_size=").Append(CameraSize);
            if (!string.IsNullOrEmpty(CameraId)) options.Append(" camera_id=").Append(CameraId);
            else if (!string.IsNullOrEmpty(CameraFacing)) options.Append(" camera_facing=").Append(CameraFacing);

            var psi = new ProcessStartInfo(Adb)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            foreach (var a in new[] { "-s", Serial, "shell", "CLASSPATH=" + RemoteServer, "app_process", "/", "com.genymobile.scrcpy.Server", ServerVersion })
                psi.ArgumentList.Add(a);
            foreach (var a in options.ToString().Split(' ')) psi.ArgumentList.Add(a);
            shell = Process.Start(psi);
            shell.OutputDataReceived += (s, e) => { if (e.Data != null) lock (serverLog) serverLog.AppendLine(e.Data); };
            shell.ErrorDataReceived += (s, e) => { if (e.Data != null) lock (serverLog) serverLog.AppendLine(e.Data); };
            shell.BeginOutputReadLine();
            shell.BeginErrorReadLine();

            NetworkStream stream = Connect(port);
            Started = true;
            status("FEEDING");

            using (var decoder = new H264Decoder())
            {
                decoder.Picture = OnPicture;
                ReadNals(stream, decoder);
            }
            if (!stopping) throw new IOException("the phone's camera stream ended" + ServerReason());
        }

        private NetworkStream Connect(int port)
        {
            // An adb forward accepts at once even before the server listens; the
            // connection then closes without data. Retry until bytes arrive.
            var watch = Stopwatch.StartNew();
            while (!stopping && watch.ElapsedMilliseconds < 15000)
            {
                if (shell.HasExited) throw new IOException("the phone's camera server stopped" + ServerReason());
                var c = new TcpClient();
                try
                {
                    c.Connect("127.0.0.1", port);
                    // Same connection until data or end: the server takes only one.
                    while (!stopping && watch.ElapsedMilliseconds < 15000)
                    {
                        if (!c.Client.Poll(500 * 1000, SelectMode.SelectRead)) continue;   // nothing yet: camera still opening
                        if (c.Client.Available > 0) { client = c; return c.GetStream(); }
                        break;   // readable with no data: closed, nobody listened yet
                    }
                }
                catch (SocketException) { }
                c.Dispose();
                Thread.Sleep(200);
            }
            throw new IOException("no picture from the phone's camera" + ServerReason());
        }

        private string ServerReason()
        {
            string text;
            lock (serverLog) text = serverLog.ToString();
            foreach (var line in text.Split('\n'))
            {
                string l = line.Trim();
                if (l.StartsWith("ERROR", StringComparison.Ordinal) || l.Contains("Exception"))
                    return ": " + l;
            }
            return "";
        }

        /// <summary>Splits the Annex B stream on start codes and hands whole NAL units to the decoder.</summary>
        private void ReadNals(NetworkStream stream, H264Decoder decoder)
        {
            var buf = new byte[1 << 20];
            int len = 0;
            var chunk = new byte[64 * 1024];
            while (!stopping)
            {
                int n;
                try { n = stream.Read(chunk, 0, chunk.Length); }
                catch (IOException) { if (stopping) return; throw; }
                if (n <= 0) return;
                if (len + n > buf.Length) Array.Resize(ref buf, Math.Max(buf.Length * 2, len + n));
                Buffer.BlockCopy(chunk, 0, buf, len, n);
                len += n;

                // find start codes; everything between two of them is one NAL unit
                int start = FindStart(buf, 0, len);
                if (start < 0) { if (len > 4) { Buffer.BlockCopy(buf, len - 3, buf, 0, 3); len = 3; } continue; }
                while (true)
                {
                    int next = FindStart(buf, start + 3, len);
                    if (next < 0) break;
                    decoder.Push(buf, start, next - start);
                    start = next;
                }
                Buffer.BlockCopy(buf, start, buf, 0, len - start);
                len -= start;
            }
        }

        private static int FindStart(byte[] b, int from, int len)
        {
            for (int i = from; i + 3 <= len; i++)
            {
                if (b[i] == 0 && b[i + 1] == 0)
                {
                    if (b[i + 2] == 1) return (i > 0 && b[i - 1] == 0 && i - 1 >= from) ? i - 1 : i;
                }
            }
            return -1;
        }

        /// <summary>Fits the decoded picture into 1280x720 (black bars, aspect kept) and writes it.</summary>
        private void OnPicture(byte[] src, int stride, int planeHeight, int cx, int cy, int cw, int ch)
        {
            int W = FrameShare.Width, H = FrameShare.Height;
            double scale = Math.Min((double)W / cw, (double)H / ch);
            int dw = Math.Max(2, ((int)(cw * scale)) & ~1), dh = Math.Max(2, ((int)(ch * scale)) & ~1);
            int ox = ((W - dw) / 2) & ~1, oy = ((H - dh) / 2) & ~1;

            Array.Fill(target, (byte)16, 0, W * H);
            Array.Fill(target, (byte)128, W * H, W * H / 2);

            var xs = new int[dw];
            for (int x = 0; x < dw; x++)
            {
                int sx = cx + x * cw / dw;
                xs[x] = Mirror ? (cx + cw - 1 - (sx - cx)) : sx;
            }
            for (int y = 0; y < dh; y++)
            {
                int sy = cy + y * ch / dh;
                int srow = sy * stride, drow = (oy + y) * W + ox;
                for (int x = 0; x < dw; x++) target[drow + x] = src[srow + xs[x]];
            }
            int uvSrc = stride * planeHeight, uvDst = W * H;
            for (int y = 0; y < dh / 2; y++)
            {
                int sy = (cy + y * 2 * ch / dh) / 2;
                int srow = uvSrc + sy * stride, drow = uvDst + (oy / 2 + y) * W + ox;
                for (int x = 0; x < dw / 2; x++)
                {
                    int sx = xs[x * 2] & ~1;
                    target[drow + x * 2] = src[srow + sx];
                    target[drow + x * 2 + 1] = src[srow + sx + 1];
                }
            }
            Interlocked.Increment(ref frames);
            // The camera's source makes the shared section when an app first
            // opens the camera; until then the pictures go nowhere.
            if (share == null)
            {
                if (Environment.TickCount64 - lastOpenTry < 500) return;
                lastOpenTry = Environment.TickCount64;
                share = FrameShare.Open();
                if (share == null) return;
            }
            fixed (byte* p = target) share.Write(p);
        }

        private string AdbText(params string[] args)
        {
            var psi = new ProcessStartInfo(Adb)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-s");
            psi.ArgumentList.Add(Serial);
            foreach (var a in args) psi.ArgumentList.Add(a);
            using (var p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                string error = p.StandardError.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0) throw new IOException("adb " + args[0] + " failed: " + (error + output).Trim());
                return output;
            }
        }

        public void Stop()
        {
            stopping = true;
            try { if (client != null) client.Dispose(); } catch { }
        }

        public void Dispose()
        {
            Stop();
            try { if (shell != null && !shell.HasExited) shell.Kill(); } catch { }
            try { if (shell != null) shell.Dispose(); } catch { }
            if (forwardPort != null)
            {
                try { AdbText("forward", "--remove", "tcp:" + forwardPort.Trim()); } catch { }
                forwardPort = null;
            }
            if (share != null) { share.Dispose(); share = null; }
        }
    }
}
