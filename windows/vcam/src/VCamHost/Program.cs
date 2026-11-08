// AndroidDC - VCamHost: turns the "AndroidDC Camera" on and off and tests it.
//
//   probe        is the virtual camera supported here, and is the source registered?
//   run          turn the camera on; it stays on until this process ends,
//                a line "stop" arrives on stdin, or the stop event is set
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
                    case "run": return Run();
                    case "selftest": return SelfTest();
                    case "list": Verbose = true; FindDevice("\u0001"); return 0;
                    default:
                        Console.WriteLine("usage: AndroidDC.VCamHost probe|run|selftest");
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

        private static int Run()
        {
            IntPtr camera = Create();
            using (var stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopEventName))
            {
                Console.WriteLine("READY " + FriendlyName);
                Console.Out.Flush();
                var reader = new Thread(() =>
                {
                    try
                    {
                        string line;
                        while ((line = Console.ReadLine()) != null)
                            if (line.Trim().Equals("stop", StringComparison.OrdinalIgnoreCase)) break;
                    }
                    catch { }
                    // stdin closed or "stop": with a parent that went away, stop too
                    stop.Set();
                }) { IsBackground = true };
                if (!Console.IsInputRedirected) reader = null;
                if (reader != null) reader.Start();
                stop.WaitOne();
            }
            Destroy(camera);
            Console.WriteLine("STOPPED");
            return 0;
        }

        // ---------------------------------------------------------------- selftest
        private static int SelfTest()
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

                var y = new byte[FrameShare.Width * FrameShare.Height];
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
                Console.WriteLine(ok ? "RESULT pass" : "RESULT fail");
                return ok ? 0 : 1;
            }
            finally
            {
                if (reader != null) Marshal.ReleaseComObject(reader);
                Destroy(camera);
            }
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
