// AndroidDC - VCamHost: turns the "AndroidDC Camera" on and off and tests it.
//
//   probe        is the virtual camera supported here, and is the source registered?
//   run          turn the camera on; it stays on until this process ends,
//                a line "stop" arrives on stdin, or the stop event is set;
//                a line "switch front|back|id N [WxH|auto]" changes the
//                phone camera while the Windows camera stays on
//   selftest     turn it on, read frames back the way a camera app does,
//                check the test pattern, the frame rate and the shared picture
//
// Exit code 0 means it worked. Nothing here needs administrator rights: only
// registering the source (regsvr32, once) does.

using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32;

namespace AndroidDC.VCam
{
    internal static unsafe class Program
    {
        public const string FriendlyName = "AndroidDC Camera";
        public const string StopEventName = @"Local\AndroidDC.VirtualCamera.Stop";
        private const string SourceId = "{" + "B6F9266A-DE52-4660-AFB9-AC513027B060" + "}";

        private static bool Verbose;

        private static int Main(string[] args)
        {
            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "probe";
            Verbose = Array.IndexOf(args, "-v") >= 0;
            try
            {
                Mf.Check(Mf.MFStartup(Mf.MF_VERSION, 0), "MFStartup");
                switch (mode)
                {
                    case "probe": return Probe();
                    case "run": return Run(args);
                    case "selftest": return SelfTest(args);
                    case "list": Verbose = true; FindDevice("\u0001"); return 0;
                    case "peek": return Peek(args);
                    default:
                        Console.WriteLine("usage: AndroidDC.VCamHost probe|run|selftest|list  [-s serial [--camera-id N|--camera-facing front|back] [--camera-size WxH] [--mirror] [--adb path] [--server path]]");
                        return 2;
                }
            }
            catch (Exception e)
            {
                Console.WriteLine("ERROR " + e.Message);
                return 1;
            }
        }

        // ---------------------------------------------------------------- probe
        private static int Probe()
        {
            int supported;
            int hr = Mf.MFIsVirtualCameraTypeSupported(Mf.MFVirtualCameraType_SoftwareCameraSource, out supported);
            Console.WriteLine("SUPPORTED " + (hr >= 0 && supported != 0 ? "yes" : "no"));
            string dll = RegisteredDll();
            Console.WriteLine("REGISTERED " + (dll ?? "no"));
            return hr >= 0 && supported != 0 && dll != null ? 0 : 1;
        }

        public static string RegisteredDll()
        {
            using (var key = Registry.ClassesRoot.OpenSubKey(@"CLSID\" + SourceId + @"\InprocServer32"))
            {
                var value = key == null ? null : key.GetValue(null) as string;
                return string.IsNullOrEmpty(value) ? null : value;
            }
        }

        // ---------------------------------------------------------------- camera
        private static IntPtr Create()
        {
            if (RegisteredDll() == null) throw new InvalidOperationException("the camera source is not registered (run regsvr32 once, as administrator)");
            IntPtr camera;
            Mf.Check(Mf.MFCreateVirtualCamera(Mf.MFVirtualCameraType_SoftwareCameraSource,
                Mf.MFVirtualCameraLifetime_Session, Mf.MFVirtualCameraAccess_CurrentUser,
                FriendlyName, SourceId, IntPtr.Zero, 0, out camera), "MFCreateVirtualCamera");
            Mf.Check(Mf.CallSlot(camera, Mf.VCam_Start, IntPtr.Zero), "IMFVirtualCamera.Start");
            return camera;
        }

        private static void Destroy(IntPtr camera)
        {
            if (camera == IntPtr.Zero) return;
            Mf.CallSlot(camera, Mf.VCam_Stop);
            Mf.CallSlot(camera, Mf.VCam_Remove);
            Mf.CallSlot(camera, Mf.VCam_Shutdown);
            Marshal.Release(camera);
        }

        private static string Option(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }

        private static Feeder MakeFeeder(string[] args)
        {
            string serial = Option(args, "-s");
            if (serial == null) return null;
            string root = System.IO.Path.GetFullPath(System.IO.Path.Combine(AppContext.BaseDirectory, "..", "..", ".."));
            return new Feeder
            {
                Serial = serial,
                Adb = Option(args, "--adb") ?? System.IO.Path.Combine(root, "adb.exe"),
                Server = Option(args, "--server") ?? System.IO.Path.Combine(root, "scrcpy-server"),
                ServerVersion = Option(args, "--server-version") ?? "4.1",
                CameraId = Option(args, "--camera-id"),
                CameraFacing = Option(args, "--camera-facing"),
                CameraSize = Option(args, "--camera-size") ?? "1280x720",
                Mirror = Array.IndexOf(args, "--mirror") >= 0,
            };
        }

        private static readonly object outLock = new object();
        private static void Say(string line) { lock (outLock) { Console.WriteLine(line); Console.Out.Flush(); } }

        // the feeder now feeding the camera; a switch replaces it
        private static volatile Feeder current;

        /// <summary>
        /// Feeds on a background thread; reports with FEEDING / FEED-ERROR lines.
        /// When the current feeder's picture ends the camera goes off. A feeder
        /// that never started after a switch leaves the camera on (grey bars),
        /// so the caller can switch again, back to the camera that worked.
        /// </summary>
        private static Thread StartFeeding(Feeder feeder, EventWaitHandle stop, bool switched)
        {
            var t = new Thread(() =>
            {
                try { feeder.Run(Say); }
                catch (Exception e) { Say("FEED-ERROR " + e.Message.Replace('\r', ' ').Replace('\n', ' ')); }
                if (stop != null && ReferenceEquals(current, feeder) && (feeder.Started || !switched))
                    stop.Set();   // no phone picture any more: turn the camera off
            }) { IsBackground = true, Name = "feeder" };
            t.Start();
            return t;
        }

        /// <summary>
        /// "switch front|back|id N [WxH|auto]": another camera of the same phone.
        /// The Windows camera stays on, so an app using it keeps it.
        /// </summary>
        private static void Switch(string line, EventWaitHandle stop, ref Thread feeding)
        {
            var parts = line.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
            Feeder old = current;
            if (old == null) { Say("SWITCH-ERROR no phone is feeding the camera"); return; }
            string id = null, facing = null, size = null;
            int i = 1;
            if (parts.Length > 2 && parts[1].Equals("id", StringComparison.OrdinalIgnoreCase)) { id = parts[2]; i = 3; }
            else if (parts.Length > 1) { facing = parts[1].ToLowerInvariant(); i = 2; }
            if (parts.Length > i) size = parts[i];
            if (id == null && facing != "front" && facing != "back" && facing != "external")
            {
                Say("SWITCH-ERROR say front, back or id N");
                return;
            }
            Say("SWITCHING " + (id != null ? "id " + id : facing));
            var next = old.WithCamera(id, facing, size);
            current = next;
            // the old one first ends on its own thread, so it no longer writes
            // the picture when its share closes
            old.Stop();
            if (feeding != null) feeding.Join(5000);
            old.Dispose();
            feeding = StartFeeding(next, stop, true);
        }

        private static int Run(string[] args)
        {
            bool fresh;
            using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName, out fresh))
            {
                if (!fresh) { Console.WriteLine("ALREADY " + FriendlyName + " is on"); return 3; }
                IntPtr camera = Create();
                Thread feeding = null;
                try
                {
                    Say("READY " + FriendlyName);
                    current = MakeFeeder(args);
                    if (current != null) feeding = StartFeeding(current, stop, false);
                    if (Console.IsInputRedirected)
                    {
                        new Thread(() =>
                        {
                            try
                            {
                                string line;
                                while ((line = Console.ReadLine()) != null)
                                {
                                    // Windows PowerShell starts what it writes with a BOM
                                    line = line.Trim().TrimStart('﻿').Trim();
                                    if (line.Equals("stop", StringComparison.OrdinalIgnoreCase)) break;
                                    if (line.StartsWith("switch", StringComparison.OrdinalIgnoreCase))
                                    {
                                        try { Switch(line, stop, ref feeding); }
                                        catch (Exception e) { Say("SWITCH-ERROR " + e.Message.Replace('\r', ' ').Replace('\n', ' ')); }
                                    }
                                }
                            }
                            catch { }
                            stop.Set();   // "stop", or the parent went away
                        }) { IsBackground = true }.Start();
                    }
                    stop.WaitOne();
                }
                finally
                {
                    Feeder last = current;
                    current = null;
                    if (last != null)
                    {
                        last.Stop();
                        if (feeding != null) feeding.Join(3000);
                        last.Dispose();
                    }
                    Destroy(camera);
                }
            }
            Say("STOPPED");
            return 0;
        }

        // ---------------------------------------------------------------- peek
        /// <summary>Opens the camera that is already on, like an app would, and says what it shows.</summary>
        private static int Peek(string[] args)
        {
            IntPtr source = FindDevice(FriendlyName);
            if (source == IntPtr.Zero) { Console.WriteLine("NONE the camera is not on"); return 1; }
            IMFSourceReader reader;
            try { Mf.Check(Mf.MFCreateSourceReaderFromMediaSource(source, IntPtr.Zero, out reader), "MFCreateSourceReaderFromMediaSource"); }
            finally { Marshal.Release(source); }
            try
            {
                var y = new byte[FrameShare.FrameBytes];
                var watch = Stopwatch.StartNew();
                int frames = 0, phone = 0;
                long firstPhoneMs = -1;
                string detail;
                while (watch.ElapsedMilliseconds < 6000)
                {
                    if (!ReadFrame(reader, y)) continue;
                    frames++;
                    if (!Pattern.Looks(y, FrameShare.Width, out detail))
                    {
                        phone++;
                        if (firstPhoneMs < 0) firstPhoneMs = watch.ElapsedMilliseconds;
                    }
                }
                Console.WriteLine("FRAMES " + frames + " in 6 s, " + phone + " from the phone, first after " + firstPhoneMs + " ms");
                string snap = Option(args, "--snapshot");
                if (snap != null) SaveBmp(y, snap);
                return phone > 0 ? 0 : 1;
            }
            finally { Marshal.ReleaseComObject(reader); }
        }

        // ---------------------------------------------------------------- selftest
        private static int SelfTest(string[] args)
        {
            IntPtr camera = IntPtr.Zero;
            IMFSourceReader reader = null;
            bool ok = true;
            try
            {
                var watch = Stopwatch.StartNew();
                camera = Create();
                Console.WriteLine("camera on (" + watch.ElapsedMilliseconds + " ms)");

                IntPtr source = IntPtr.Zero;
                for (int i = 0; i < 40 && source == IntPtr.Zero; i++)
                {
                    source = FindDevice(FriendlyName);
                    if (source == IntPtr.Zero) Thread.Sleep(250);
                }
                if (source == IntPtr.Zero) { Console.WriteLine("FAIL the camera did not appear in the device list"); return 1; }
                Console.WriteLine("PASS listed as a camera (" + watch.ElapsedMilliseconds + " ms)");

                try { Mf.Check(Mf.MFCreateSourceReaderFromMediaSource(source, IntPtr.Zero, out reader), "MFCreateSourceReaderFromMediaSource"); }
                finally { Marshal.Release(source); }

                IMFMediaType type;
                Mf.Check(reader.GetCurrentMediaType(Mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM, out type), "GetCurrentMediaType");
                ulong size; Guid subtype;
                type.GetUINT64(ref Mf.MF_MT_FRAME_SIZE, out size);
                type.GetGUID(ref Mf.MF_MT_SUBTYPE, out subtype);
                Marshal.ReleaseComObject(type);
                Console.WriteLine("format " + (size >> 32) + "x" + (size & 0xFFFFFFFF) + " " + (subtype == Mf.MFVideoFormat_NV12 ? "NV12" : subtype.ToString()));

                var y = new byte[FrameShare.FrameBytes];
                string detail;

                // 1. the test pattern arrives unchanged
                if (!ReadFrame(reader, y)) { Console.WriteLine("FAIL no frame arrived"); return 1; }
                bool bars = Pattern.Looks(y, FrameShare.Width, out detail);
                Console.WriteLine((bars ? "PASS" : "FAIL") + " test pattern (" + detail + ")");
                ok &= bars;

                // 2. frame rate
                watch.Restart();
                int frames = 0;
                while (watch.ElapsedMilliseconds < 3000) { if (ReadFrame(reader, y)) frames++; }
                double fps = frames * 1000.0 / watch.ElapsedMilliseconds;
                bool rate = fps >= 24 && fps <= 36;
                Console.WriteLine((rate ? "PASS" : "FAIL") + " frame rate " + fps.ToString("0.0") + " fps");
                ok &= rate;

                // 3. a picture written to the shared section from this desktop session shows up
                FrameShare share = null;
                for (int i = 0; i < 20 && share == null; i++) { share = FrameShare.Open(); if (share == null) Thread.Sleep(100); }
                if (share == null) { Console.WriteLine("FAIL the shared picture section is not there"); ok = false; }
                else
                {
                    using (share)
                    {
                        var flat = new byte[FrameShare.FrameBytes];
                        Array.Fill(flat, (byte)99, 0, FrameShare.Width * FrameShare.Height);
                        Array.Fill(flat, (byte)128, FrameShare.Width * FrameShare.Height, FrameShare.Width * FrameShare.Height / 2);
                        bool seen = false;
                        watch.Restart();
                        while (!seen && watch.ElapsedMilliseconds < 3000)
                        {
                            fixed (byte* p = flat) share.Write(p);
                            if (ReadFrame(reader, y))
                                seen = Math.Abs(y[FrameShare.Width * 360 + 640] - 99) <= 4 && Math.Abs(y[FrameShare.Width * 100 + 100] - 99) <= 4;
                        }
                        Console.WriteLine((seen ? "PASS" : "FAIL") + " shared picture reaches the camera (" + watch.ElapsedMilliseconds + " ms)");
                        ok &= seen;

                        // 4. once the feeder goes quiet the pattern comes back
                        watch.Restart();
                        bool back = false;
                        while (!back && watch.ElapsedMilliseconds < 5000)
                            if (ReadFrame(reader, y)) back = Pattern.Looks(y, FrameShare.Width, out detail);
                        Console.WriteLine((back ? "PASS" : "FAIL") + " test pattern returns when the feeder stops (" + watch.ElapsedMilliseconds + " ms)");
                        ok &= back;
                    }
                }
                // 5. with a phone: its camera reaches the virtual camera
                Feeder feeder = MakeFeeder(args);
                if (feeder != null)
                {
                    using (feeder)
                    {
                        watch.Restart();
                        StartFeeding(feeder, null, false);
                        bool phone = false;
                        while (!phone && watch.ElapsedMilliseconds < 20000)
                        {
                            if (ReadFrame(reader, y) && feeder.Frames > 0) phone = !Pattern.Looks(y, FrameShare.Width, out detail);
                        }
                        Console.WriteLine((phone ? "PASS" : "FAIL") + " phone camera picture arrives (" + watch.ElapsedMilliseconds + " ms after start)");
                        ok &= phone;
                        if (phone)
                        {
                            long before = feeder.Frames;
                            watch.Restart();
                            int got = 0;
                            while (watch.ElapsedMilliseconds < 5000) if (ReadFrame(reader, y)) got++;
                            double phoneFps = (feeder.Frames - before) * 1000.0 / watch.ElapsedMilliseconds;
                            double camFps = got * 1000.0 / watch.ElapsedMilliseconds;
                            bool steady = phoneFps >= 15 && camFps >= 24;
                            Console.WriteLine((steady ? "PASS" : "FAIL") + " phone " + phoneFps.ToString("0.0") + " fps decoded, camera " + camFps.ToString("0.0") + " fps");
                            ok &= steady;
                            long sum = 0;
                            for (int i = 0; i < y.Length; i += 97) sum += y[i];
                            Console.WriteLine("  mean brightness " + (sum * 97 / y.Length));
                            string snap = Option(args, "--snapshot");
                            if (snap != null) { SaveBmp(y, snap); Console.WriteLine("  snapshot " + snap); }
                        }
                    }
                }
                Console.WriteLine(ok ? "RESULT pass" : "RESULT fail");
                return ok ? 0 : 1;
            }
            finally
            {
                if (reader != null) Marshal.ReleaseComObject(reader);
                Destroy(camera);
            }
        }

        /// <summary>Writes an NV12 frame as a 24-bit BMP, to look at what the camera shows.</summary>
        private static void SaveBmp(byte[] nv12, string path)
        {
            int w = FrameShare.Width, h = FrameShare.Height, rowBytes = w * 3;
            var bmp = new byte[54 + rowBytes * h];
            BitConverter.GetBytes((ushort)0x4D42).CopyTo(bmp, 0);
            BitConverter.GetBytes(bmp.Length).CopyTo(bmp, 2);
            BitConverter.GetBytes(54).CopyTo(bmp, 10);
            BitConverter.GetBytes(40).CopyTo(bmp, 14);
            BitConverter.GetBytes(w).CopyTo(bmp, 18);
            BitConverter.GetBytes(-h).CopyTo(bmp, 22);   // top-down
            BitConverter.GetBytes((ushort)1).CopyTo(bmp, 26);
            BitConverter.GetBytes((ushort)24).CopyTo(bmp, 28);
            for (int yy = 0; yy < h; yy++)
                for (int x = 0; x < w; x++)
                {
                    int Y = nv12[yy * w + x] - 16, uv = w * h + (yy / 2) * w + (x & ~1);
                    int U = nv12[uv] - 128, V = nv12[uv + 1] - 128;
                    int r = (298 * Y + 409 * V + 128) >> 8, g = (298 * Y - 100 * U - 208 * V + 128) >> 8, b = (298 * Y + 516 * U + 128) >> 8;
                    int o = 54 + yy * rowBytes + x * 3;
                    bmp[o] = (byte)Math.Clamp(b, 0, 255); bmp[o + 1] = (byte)Math.Clamp(g, 0, 255); bmp[o + 2] = (byte)Math.Clamp(r, 0, 255);
                }
            System.IO.File.WriteAllBytes(path, bmp);
        }

        /// <summary>Activates the video capture device with this friendly name; IntPtr.Zero if none.</summary>
        private static IntPtr FindDevice(string name)
        {
            IMFAttributes query;
            Mf.Check(Mf.MFCreateAttributes(out query, 1), "MFCreateAttributes");
            query.SetGUID(ref Mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, ref Mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
            IntPtr list; uint count;
            Mf.Check(Mf.MFEnumDeviceSources(query, out list, out count), "MFEnumDeviceSources");
            Marshal.ReleaseComObject(query);
            IntPtr found = IntPtr.Zero;
            for (int i = 0; i < count; i++)
            {
                IntPtr p = Marshal.ReadIntPtr(list, i * IntPtr.Size);
                var activate = (IMFActivate)Marshal.GetObjectForIUnknown(p);
                if (found == IntPtr.Zero)
                {
                    IntPtr text; uint length;
                    if (activate.GetAllocatedString(ref Mf.MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, out text, out length) >= 0)
                    {
                        string friendly = Marshal.PtrToStringUni(text);
                        Marshal.FreeCoTaskMem(text);
                        if (Verbose) Console.WriteLine("  device: " + friendly);
                        if (friendly == name || friendly.StartsWith(name + " (", StringComparison.Ordinal))
                        {
                            Guid iid = Mf.IID_IMFMediaSource;
                            IntPtr src;
                            if (activate.ActivateObject(ref iid, out src) >= 0) found = src;
                        }
                    }
                }
                Marshal.ReleaseComObject(activate);
                Marshal.Release(p);
            }
            Marshal.FreeCoTaskMem(list);
            return found;
        }

        /// <summary>Reads one frame and copies its Y plane; false if none came.</summary>
        private static bool ReadFrame(IMFSourceReader reader, byte[] y)
        {
            for (int attempt = 0; attempt < 10; attempt++)
            {
                uint index, flags; long time; IntPtr samplePtr;
                Mf.Check(reader.ReadSample(Mf.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, out index, out flags, out time, out samplePtr), "ReadSample");
                if (samplePtr == IntPtr.Zero) continue;
                var sample = (IMFSample)Marshal.GetObjectForIUnknown(samplePtr);
                Marshal.Release(samplePtr);
                try
                {
                    IntPtr bufferPtr;
                    Mf.Check(sample.ConvertToContiguousBuffer(out bufferPtr), "ConvertToContiguousBuffer");
                    var buffer = (IMFMediaBuffer)Marshal.GetObjectForIUnknown(bufferPtr);
                    Marshal.Release(bufferPtr);
                    try
                    {
                        IntPtr data; uint max, cur;
                        Mf.Check(buffer.Lock(out data, out max, out cur), "Lock");
                        try { Marshal.Copy(data, y, 0, Math.Min(y.Length, (int)cur)); }
                        finally { buffer.Unlock(); }
                    }
                    finally { Marshal.ReleaseComObject(buffer); }
                }
                finally { Marshal.ReleaseComObject(sample); }
                return true;
            }
            return false;
        }
    }
}
