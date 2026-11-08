// AndroidDC - the camera's one video stream.
//
// Each RequestSample is answered at once with the newest picture: the one
// the feeder last wrote to the shared section, or a test pattern while no
// feeder is writing. The Frame Server asks at the frame rate it was given.

using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace AndroidDC.VCam
{
    [ClassInterface(ClassInterfaceType.None)]
    public sealed unsafe class MediaStream : IMFMediaStream2, IMFMediaStream, IMFMediaEventGenerator
    {
        public const int Fps = 30;
        private const long FrameDuration = 10000000L / Fps;
        private const long StaleMs = 1500;   // feeder silent this long: show the pattern again

        private readonly object gate = new object();
        private readonly MediaSource source;
        private readonly IMFMediaEventQueue queue;
        private readonly IMFAttributes attributes;
        private readonly IMFStreamDescriptor descriptor;
        private readonly byte[] frame = new byte[FrameShare.FrameBytes];
        private int state = Mf.MF_STREAM_STATE_STOPPED;
        private bool shut;
        private long count;
        private FrameShare share;
        private long lastShareTry;
        private long lastSequence;
        private bool feeding;
        private readonly System.Collections.Generic.Queue<IntPtr> pending = new System.Collections.Generic.Queue<IntPtr>();
        private Thread pacer;

        public MediaStream(MediaSource source, uint id)
        {
            this.source = source;
            Mf.Check(Mf.MFCreateEventQueue(out queue), "MFCreateEventQueue");
            Mf.Check(Mf.MFCreateAttributes(out attributes, 8), "MFCreateAttributes");

            IMFMediaType type;
            Mf.Check(Mf.MFCreateMediaType(out type), "MFCreateMediaType");
            type.SetGUID(ref Mf.MF_MT_MAJOR_TYPE, ref Mf.MFMediaType_Video);
            type.SetGUID(ref Mf.MF_MT_SUBTYPE, ref Mf.MFVideoFormat_NV12);
            type.SetUINT64(ref Mf.MF_MT_FRAME_SIZE, Mf.Pack(FrameShare.Width, FrameShare.Height));
            type.SetUINT64(ref Mf.MF_MT_FRAME_RATE, Mf.Pack(Fps, 1));
            type.SetUINT64(ref Mf.MF_MT_PIXEL_ASPECT_RATIO, Mf.Pack(1, 1));
            type.SetUINT32(ref Mf.MF_MT_INTERLACE_MODE, Mf.MFVideoInterlace_Progressive);
            type.SetUINT32(ref Mf.MF_MT_ALL_SAMPLES_INDEPENDENT, 1);
            type.SetUINT32(ref Mf.MF_MT_FIXED_SIZE_SAMPLES, 1);
            type.SetUINT32(ref Mf.MF_MT_SAMPLE_SIZE, FrameShare.FrameBytes);
            type.SetUINT32(ref Mf.MF_MT_DEFAULT_STRIDE, FrameShare.Width);

            attributes.SetGUID(ref Mf.MF_DEVICESTREAM_STREAM_CATEGORY, ref Mf.PINNAME_VIDEO_CAPTURE);
            attributes.SetUINT32(ref Mf.MF_DEVICESTREAM_STREAM_ID, id);
            attributes.SetUINT32(ref Mf.MF_DEVICESTREAM_FRAMESERVER_SHARED, 1);
            attributes.SetUINT32(ref Mf.MF_DEVICESTREAM_ATTRIBUTE_FRAMESOURCE_TYPES, Mf.MFFrameSourceTypes_Color);

            IntPtr typePtr = Marshal.GetComInterfaceForObject(type, typeof(IMFMediaType));
            try
            {
                Mf.Check(Mf.MFCreateStreamDescriptor(id, 1, new[] { typePtr }, out descriptor), "MFCreateStreamDescriptor");
            }
            finally { Marshal.Release(typePtr); }

            IMFMediaTypeHandler handler;
            Mf.Check(descriptor.GetMediaTypeHandler(out handler), "GetMediaTypeHandler");
            Mf.Check(handler.SetCurrentMediaType(type), "SetCurrentMediaType");
            Marshal.ReleaseComObject(handler);
            Marshal.ReleaseComObject(type);

            IntPtr descriptorAsAttributes = Marshal.GetComInterfaceForObject(descriptor, typeof(IMFStreamDescriptor));
            try { Mf.Check(attributes.CopyAllItems(descriptorAsAttributes), "CopyAllItems"); }
            finally { Marshal.Release(descriptorAsAttributes); }

            Pattern.Draw(frame, 0);
        }

        internal bool IsOn { get { return state == Mf.MF_STREAM_STATE_RUNNING; } }

        internal IntPtr DescriptorPointer()
        {
            return Marshal.GetComInterfaceForObject(descriptor, typeof(IMFStreamDescriptor));
        }

        internal IntPtr AttributesPointer()
        {
            return Marshal.GetComInterfaceForObject(attributes, typeof(IMFAttributes));
        }

        internal void Start()
        {
            lock (gate)
            {
                state = Mf.MF_STREAM_STATE_RUNNING;
                using (var time = new PropVariantI8(Mf.MFGetSystemTime()))
                {
                    Guid none = Guid.Empty;
                    queue.QueueEventParamVar(Mf.MEStreamStarted, ref none, Mf.S_OK, time.Pointer);
                }
            }
        }

        internal void Stop()
        {
            lock (gate)
            {
                state = Mf.MF_STREAM_STATE_STOPPED;
                DropPending();
                Guid none = Guid.Empty;
                queue.QueueEventParamVar(Mf.MEStreamStopped, ref none, Mf.S_OK, IntPtr.Zero);
            }
        }

        internal void Shutdown()
        {
            lock (gate)
            {
                if (shut) return;
                shut = true;
                state = Mf.MF_STREAM_STATE_STOPPED;
                DropPending();
                queue.Shutdown();
                if (share != null) { share.Dispose(); share = null; }
            }
        }

        // ---- IMFMediaEventGenerator ----
        public int GetEvent(uint flags, out IntPtr ppEvent)
        {
            ppEvent = IntPtr.Zero;
            if (shut) return Mf.MF_E_SHUTDOWN;
            return queue.GetEvent(flags, out ppEvent);
        }

        public int BeginGetEvent(IntPtr pCallback, IntPtr punkState)
        {
            lock (gate) { if (shut) return Mf.MF_E_SHUTDOWN; return queue.BeginGetEvent(pCallback, punkState); }
        }

        public int EndGetEvent(IntPtr pResult, out IntPtr ppEvent)
        {
            ppEvent = IntPtr.Zero;
            lock (gate) { if (shut) return Mf.MF_E_SHUTDOWN; return queue.EndGetEvent(pResult, out ppEvent); }
        }

        public int QueueEvent(int met, ref Guid extendedType, int hrStatus, IntPtr pValue)
        {
            lock (gate) { if (shut) return Mf.MF_E_SHUTDOWN; return queue.QueueEventParamVar(met, ref extendedType, hrStatus, pValue); }
        }

        // ---- IMFMediaStream ----
        public int GetMediaSource(out IntPtr ppMediaSource)
        {
            ppMediaSource = IntPtr.Zero;
            if (shut) return Mf.MF_E_SHUTDOWN;
            ppMediaSource = Marshal.GetComInterfaceForObject(source, typeof(IMFMediaSource));
            return Mf.S_OK;
        }

        public int GetStreamDescriptor(out IntPtr ppStreamDescriptor)
        {
            ppStreamDescriptor = IntPtr.Zero;
            if (shut) return Mf.MF_E_SHUTDOWN;
            ppStreamDescriptor = DescriptorPointer();
            return Mf.S_OK;
        }

        public int RequestSample(IntPtr pToken)
        {
            lock (gate)
            {
                if (shut) return Mf.MF_E_SHUTDOWN;
                if (state != Mf.MF_STREAM_STATE_RUNNING) return Mf.MF_E_INVALIDREQUEST;
                if (pToken != IntPtr.Zero) Marshal.AddRef(pToken);
                pending.Enqueue(pToken);
                if (pacer == null)
                {
                    pacer = new Thread(Pace) { IsBackground = true, Name = "AndroidDC camera pacer" };
                    pacer.Start();
                }
                return Mf.S_OK;
            }
        }

        /// <summary>Answers one waiting request per frame period, so apps get a steady 30 fps.</summary>
        private void Pace()
        {
            IntPtr timer = CreateWaitableTimerExW(IntPtr.Zero, null, 2 /* HIGH_RESOLUTION */, 0x1F0003);
            if (timer == IntPtr.Zero) timer = CreateWaitableTimerExW(IntPtr.Zero, null, 0, 0x1F0003);
            var clock = System.Diagnostics.Stopwatch.StartNew();
            long tick = 0;
            try
            {
                while (true)
                {
                    tick++;
                    long dueMs = tick * 1000 / Fps;
                    long waitMs = dueMs - clock.ElapsedMilliseconds;
                    if (waitMs < -200) { tick = clock.ElapsedMilliseconds * Fps / 1000; waitMs = 0; }   // fell far behind: catch up, do not burst
                    if (waitMs > 0)
                    {
                        long due = -waitMs * 10000;   // relative, 100 ns units
                        if (timer != IntPtr.Zero && SetWaitableTimer(timer, ref due, 0, IntPtr.Zero, IntPtr.Zero, false))
                            WaitForSingleObject(timer, 0xFFFFFFFF);
                        else
                            Thread.Sleep((int)waitMs);
                    }
                    lock (gate)
                    {
                        if (shut) return;
                        if (pending.Count == 0) continue;
                        IntPtr token = pending.Dequeue();
                        try { if (state == Mf.MF_STREAM_STATE_RUNNING) Deliver(token); }
                        catch (Exception e) { Log.Write("sample failed: " + e.Message); }
                        finally { if (token != IntPtr.Zero) Marshal.Release(token); }
                    }
                }
            }
            finally
            {
                if (timer != IntPtr.Zero) CloseHandle(timer);
            }
        }

        private void DropPending()
        {
            while (pending.Count > 0)
            {
                IntPtr token = pending.Dequeue();
                if (token != IntPtr.Zero) Marshal.Release(token);
            }
        }

        private void Deliver(IntPtr pToken)
        {
            NextFrame();

            IMFMediaBuffer buffer;
            Mf.Check(Mf.MFCreateMemoryBuffer(FrameShare.FrameBytes, out buffer), "MFCreateMemoryBuffer");
            IMFSample sample = null;
            try
            {
                IntPtr data; uint max, cur;
                Mf.Check(buffer.Lock(out data, out max, out cur), "Lock");
                Marshal.Copy(frame, 0, data, FrameShare.FrameBytes);
                buffer.Unlock();
                buffer.SetCurrentLength(FrameShare.FrameBytes);

                Mf.Check(Mf.MFCreateSample(out sample), "MFCreateSample");
                IntPtr bufferPtr = Marshal.GetComInterfaceForObject(buffer, typeof(IMFMediaBuffer));
                try { Mf.Check(sample.AddBuffer(bufferPtr), "AddBuffer"); }
                finally { Marshal.Release(bufferPtr); }
                sample.SetSampleTime(Mf.MFGetSystemTime());
                sample.SetSampleDuration(FrameDuration);
                if (pToken != IntPtr.Zero) sample.SetUnknown(ref Mf.MFSampleExtension_Token, pToken);

                IntPtr samplePtr = Marshal.GetIUnknownForObject(sample);
                try
                {
                    Guid none = Guid.Empty;
                    Mf.Check(queue.QueueEventParamUnk(Mf.MEMediaSample, ref none, Mf.S_OK, samplePtr), "QueueEventParamUnk");
                }
                finally { Marshal.Release(samplePtr); }
            }
            finally
            {
                Marshal.ReleaseComObject(buffer);
                if (sample != null) Marshal.ReleaseComObject(sample);
            }
            count++;
            if (count == 1 || count % 900 == 0) Log.Write("frames sent: " + count + (feeding ? " (phone)" : " (test pattern)"));
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWaitableTimerExW(IntPtr attributes, string name, uint flags, uint access);
        [DllImport("kernel32.dll")]
        private static extern bool SetWaitableTimer(IntPtr timer, ref long due, int period, IntPtr completion, IntPtr arg, bool resume);
        [DllImport("kernel32.dll")]
        private static extern uint WaitForSingleObject(IntPtr handle, uint ms);
        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        /// <summary>Puts the newest picture in frame: the feeder's, or the moving test pattern.</summary>
        private void NextFrame()
        {
            if (share == null && Environment.TickCount64 - lastShareTry > 2000)
            {
                lastShareTry = Environment.TickCount64;
                try { share = FrameShare.Create(); Log.Write("shared frame section ready"); }
                catch (Exception e) { Log.Write("shared frame section: " + e.Message); }
            }

            bool fed = false;
            if (share != null && share.AgeMs < StaleMs)
            {
                if (share.Sequence == lastSequence)
                {
                    fed = true;   // nothing new: send the last picture again
                }
                else
                {
                    long seq;
                    fixed (byte* p = frame)
                    {
                        if (share.TryRead(p, out seq)) { lastSequence = seq; fed = true; }
                    }
                }
            }
            if (fed != feeding)
            {
                feeding = fed;
                Log.Write(fed ? "picture: phone" : "picture: test pattern");
            }
            if (!fed) Pattern.Draw(frame, count);
        }

        // ---- IMFMediaStream2 ----
        public int SetStreamState(int value)
        {
            lock (gate)
            {
                if (shut) return Mf.MF_E_SHUTDOWN;
                if (value == state) return Mf.S_OK;
                if (value == Mf.MF_STREAM_STATE_RUNNING) { Start(); return Mf.S_OK; }
                if (value == Mf.MF_STREAM_STATE_STOPPED) { Stop(); return Mf.S_OK; }
                return Mf.MF_E_INVALIDREQUEST;   // paused: not for a live camera
            }
        }

        public int GetStreamState(out int value)
        {
            value = state;
            return shut ? Mf.MF_E_SHUTDOWN : Mf.S_OK;
        }
    }
}
