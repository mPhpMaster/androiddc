// AndroidDC - the virtual camera's media source: one live NV12 video stream.

using System;
using System.Runtime.InteropServices;

namespace AndroidDC.VCam
{
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class MediaSource : IMFMediaSourceEx, IMFMediaSource, IMFMediaEventGenerator, IMFGetService, IKsControl
    {
        private readonly object gate = new object();
        private IMFMediaEventQueue queue;
        private readonly IMFAttributes attributes;
        private readonly IMFPresentationDescriptor presentation;
        private readonly MediaStream stream;
        private bool shut;

        public MediaSource(IMFAttributes activatorAttributes)
        {
            Mf.Check(Mf.MFCreateEventQueue(out queue), "MFCreateEventQueue");
            Mf.Check(Mf.MFCreateAttributes(out attributes, 4), "MFCreateAttributes");
            if (activatorAttributes != null)
            {
                IntPtr dest = Marshal.GetComInterfaceForObject(attributes, typeof(IMFAttributes));
                try { activatorAttributes.CopyAllItems(dest); }
                finally { Marshal.Release(dest); }
            }

            stream = new MediaStream(this, 0);
            IntPtr descriptor = stream.DescriptorPointer();
            try
            {
                Mf.Check(Mf.MFCreatePresentationDescriptor(1, new[] { descriptor }, out presentation), "MFCreatePresentationDescriptor");
            }
            finally { Marshal.Release(descriptor); }
            Mf.Check(presentation.SelectStream(0), "SelectStream");
            Log.Write("MediaSource created");
        }

        private int Alive()
        {
            return shut ? Mf.MF_E_SHUTDOWN : Mf.S_OK;
        }

        internal void QueueSourceEvent(int type, int hr, IntPtr value)
        {
            Guid none = Guid.Empty;
            queue.QueueEventParamVar(type, ref none, hr, value);
        }

        // ---- IMFMediaEventGenerator ----
        public int GetEvent(uint flags, out IntPtr ppEvent)
        {
            ppEvent = IntPtr.Zero;
            IMFMediaEventQueue q;
            lock (gate) { if (shut) return Mf.MF_E_SHUTDOWN; q = queue; }
            return q.GetEvent(flags, out ppEvent);   // may block: outside the lock
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

        // ---- IMFMediaSource ----
        public int GetCharacteristics(out uint characteristics)
        {
            characteristics = Mf.MFMEDIASOURCE_IS_LIVE;
            return Alive();
        }

        public int CreatePresentationDescriptor(out IntPtr ppPresentationDescriptor)
        {
            ppPresentationDescriptor = IntPtr.Zero;
            lock (gate)
            {
                if (shut) return Mf.MF_E_SHUTDOWN;
                return presentation.Clone(out ppPresentationDescriptor);
            }
        }

        public int Start(IntPtr pPresentationDescriptor, IntPtr pguidTimeFormat, IntPtr pvarStartPosition)
        {
            try
            {
                lock (gate)
                {
                    if (shut) return Mf.MF_E_SHUTDOWN;
                    if (pPresentationDescriptor == IntPtr.Zero) return Mf.E_POINTER;
                    if (pguidTimeFormat != IntPtr.Zero && Marshal.PtrToStructure<Guid>(pguidTimeFormat) != Guid.Empty)
                        return unchecked((int)0xC00D36B5);   // MF_E_UNSUPPORTED_TIME_FORMAT

                    var pd = (IMFPresentationDescriptor)Marshal.GetObjectForIUnknown(pPresentationDescriptor);
                    try
                    {
                        uint count;
                        Mf.Check(pd.GetStreamDescriptorCount(out count), "GetStreamDescriptorCount");
                        for (uint i = 0; i < count; i++)
                        {
                            int selected;
                            IntPtr sdPtr;
                            Mf.Check(pd.GetStreamDescriptorByIndex(i, out selected, out sdPtr), "GetStreamDescriptorByIndex");
                            uint id;
                            try
                            {
                                var sd = (IMFStreamDescriptor)Marshal.GetObjectForIUnknown(sdPtr);
                                Mf.Check(sd.GetStreamIdentifier(out id), "GetStreamIdentifier");
                                Marshal.ReleaseComObject(sd);
                            }
                            finally { Marshal.Release(sdPtr); }
                            if (id != 0) return Mf.MF_E_INVALIDSTREAMNUMBER;

                            if (selected != 0)
                            {
                                bool wasOn = stream.IsOn;
                                IntPtr unknown = Marshal.GetIUnknownForObject(stream);
                                try
                                {
                                    Guid none = Guid.Empty;
                                    queue.QueueEventParamUnk(wasOn ? Mf.MEUpdatedStream : Mf.MENewStream, ref none, Mf.S_OK, unknown);
                                }
                                finally { Marshal.Release(unknown); }
                                stream.Start();
                            }
                            else if (stream.IsOn)
                            {
                                stream.Stop();
                            }
                        }
                    }
                    finally { Marshal.ReleaseComObject(pd); }

                    using (var time = new PropVariantI8(Mf.MFGetSystemTime()))
                        QueueSourceEvent(Mf.MESourceStarted, Mf.S_OK, time.Pointer);
                    Log.Write("Start");
                    return Mf.S_OK;
                }
            }
            catch (Exception e)
            {
                Log.Write("Start failed: " + e);
                return e.HResult < 0 ? e.HResult : Mf.E_INVALIDARG;
            }
        }

        public int Stop()
        {
            lock (gate)
            {
                if (shut) return Mf.MF_E_SHUTDOWN;
                if (stream.IsOn) stream.Stop();
                QueueSourceEvent(Mf.MESourceStopped, Mf.S_OK, IntPtr.Zero);
                Log.Write("Stop");
                return Mf.S_OK;
            }
        }

        public int Pause()
        {
            return shut ? Mf.MF_E_SHUTDOWN : Mf.MF_E_INVALIDREQUEST;   // a live camera does not pause
        }

        public int Shutdown()
        {
            lock (gate)
            {
                if (shut) return Mf.MF_E_SHUTDOWN;
                shut = true;
                stream.Shutdown();
                queue.Shutdown();
                Log.Write("Shutdown");
                return Mf.S_OK;
            }
        }

        // ---- IMFMediaSourceEx ----
        public int GetSourceAttributes(out IntPtr ppAttributes)
        {
            ppAttributes = IntPtr.Zero;
            if (shut) return Mf.MF_E_SHUTDOWN;
            ppAttributes = Marshal.GetComInterfaceForObject(attributes, typeof(IMFAttributes));
            return Mf.S_OK;
        }

        public int GetStreamAttributes(uint streamIdentifier, out IntPtr ppAttributes)
        {
            ppAttributes = IntPtr.Zero;
            if (shut) return Mf.MF_E_SHUTDOWN;
            if (streamIdentifier != 0) return Mf.MF_E_INVALIDSTREAMNUMBER;
            ppAttributes = stream.AttributesPointer();
            return Mf.S_OK;
        }

        public int SetD3DManager(IntPtr pManager)
        {
            return Alive();   // frames are made in system memory
        }

        // ---- IMFGetService ----
        public int GetService(ref Guid service, ref Guid riid, out IntPtr ppv)
        {
            ppv = IntPtr.Zero;
            return Mf.MF_E_UNSUPPORTED_SERVICE;
        }

        // ---- IKsControl: this camera has no controls ----
        public int KsProperty(IntPtr property, uint propertyLength, IntPtr data, uint dataLength, IntPtr bytesReturned) { return Mf.ERROR_SET_NOT_FOUND; }
        public int KsMethod(IntPtr method, uint methodLength, IntPtr data, uint dataLength, IntPtr bytesReturned) { return Mf.ERROR_SET_NOT_FOUND; }
        public int KsEvent(IntPtr ksEvent, uint eventLength, IntPtr data, uint dataLength, IntPtr bytesReturned) { return Mf.ERROR_SET_NOT_FOUND; }
    }

    /// <summary>A PROPVARIANT of type VT_I8 in unmanaged memory, for start events.</summary>
    internal sealed class PropVariantI8 : IDisposable
    {
        public IntPtr Pointer { get; private set; }

        public PropVariantI8(long value)
        {
            Pointer = Marshal.AllocCoTaskMem(24);
            for (int i = 0; i < 24; i += 8) Marshal.WriteInt64(Pointer, i, 0);
            Marshal.WriteInt16(Pointer, 0, 20);   // VT_I8
            Marshal.WriteInt64(Pointer, 8, value);
        }

        public void Dispose()
        {
            if (Pointer != IntPtr.Zero) { Marshal.FreeCoTaskMem(Pointer); Pointer = IntPtr.Zero; }
        }
    }
}
