// AndroidDC - H.264 to NV12 with the decoder that comes with Windows
// (the Microsoft H.264 Video Decoder MFT), used synchronously.

using System;
using System.Runtime.InteropServices;

namespace AndroidDC.VCam
{
    [ComImport, Guid("BF94C121-5B05-4E6F-8000-BA598961414D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IMFTransform
    {
        [PreserveSig] int GetStreamLimits(out uint inMin, out uint inMax, out uint outMin, out uint outMax);
        [PreserveSig] int GetStreamCount(out uint inputs, out uint outputs);
        [PreserveSig] int GetStreamIDs(uint inSize, IntPtr inIds, uint outSize, IntPtr outIds);
        [PreserveSig] int GetInputStreamInfo(uint id, IntPtr info);
        [PreserveSig] int GetOutputStreamInfo(uint id, IntPtr info);
        [PreserveSig] int GetAttributes(out IMFAttributes attributes);
        [PreserveSig] int GetInputStreamAttributes(uint id, out IntPtr attributes);
        [PreserveSig] int GetOutputStreamAttributes(uint id, out IntPtr attributes);
        [PreserveSig] int DeleteInputStream(uint id);
        [PreserveSig] int AddInputStreams(uint count, IntPtr ids);
        [PreserveSig] int GetInputAvailableType(uint id, uint index, out IMFMediaType type);
        [PreserveSig] int GetOutputAvailableType(uint id, uint index, out IMFMediaType type);
        [PreserveSig] int SetInputType(uint id, IMFMediaType type, uint flags);
        [PreserveSig] int SetOutputType(uint id, IMFMediaType type, uint flags);
        [PreserveSig] int GetInputCurrentType(uint id, out IMFMediaType type);
        [PreserveSig] int GetOutputCurrentType(uint id, out IMFMediaType type);
        [PreserveSig] int GetInputStatus(uint id, out uint flags);
        [PreserveSig] int GetOutputStatus(out uint flags);
        [PreserveSig] int SetOutputBounds(long lower, long upper);
        [PreserveSig] int ProcessEvent(uint id, IntPtr ev);
        [PreserveSig] int ProcessMessage(uint message, UIntPtr param);
        [PreserveSig] int ProcessInput(uint id, IntPtr sample, uint flags);
        [PreserveSig] int ProcessOutput(uint flags, uint count, IntPtr buffers, out uint status);
    }

    internal sealed class H264Decoder : IDisposable
    {
        private static readonly Guid ClsidH264Decoder = new Guid("62CE7E72-4C71-4D20-B15D-452831A87D9D");
        private static Guid MFVideoFormat_H264 = new Guid("34363248-0000-0010-8000-00AA00389B71");
        private static Guid MF_LOW_LATENCY = new Guid("9C27891A-ED7A-40E1-88E8-B22727A024EE");
        private static Guid MF_MT_MINIMUM_DISPLAY_APERTURE = new Guid("D7388766-18FE-48C6-A177-EE894867C8C4");

        private const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);
        private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
        private const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
        private const uint MFT_MESSAGE_NOTIFY_BEGIN_STREAMING = 0x10000000;
        private const uint MFT_MESSAGE_NOTIFY_START_OF_STREAM = 0x10000003;
        private const uint MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x100;

        private readonly IMFTransform mft;
        private readonly IntPtr outputBuffer = Marshal.AllocHGlobal(32);   // one MFT_OUTPUT_DATA_BUFFER (x64)
        private readonly IntPtr streamInfo = Marshal.AllocHGlobal(16);
        private int outSize, stride, width, height, cropX, cropY, cropW, cropH;
        private bool providesSamples;
        private byte[] picture = new byte[0];

        /// <summary>Called with each decoded picture: NV12 bytes, stride, plane height, and the visible area.</summary>
        public Action<byte[], int, int, int, int, int, int> Picture;

        public H264Decoder()
        {
            mft = (IMFTransform)System.Activator.CreateInstance(Type.GetTypeFromCLSID(ClsidH264Decoder, true));
            IMFAttributes attributes;
            if (mft.GetAttributes(out attributes) >= 0 && attributes != null)
            {
                attributes.SetUINT32(ref MF_LOW_LATENCY, 1);
                Marshal.ReleaseComObject(attributes);
            }

            IMFMediaType input;
            Mf.Check(Mf.MFCreateMediaType(out input), "MFCreateMediaType");
            input.SetGUID(ref Mf.MF_MT_MAJOR_TYPE, ref Mf.MFMediaType_Video);
            input.SetGUID(ref Mf.MF_MT_SUBTYPE, ref MFVideoFormat_H264);
            Mf.Check(mft.SetInputType(0, input, 0), "SetInputType");
            Marshal.ReleaseComObject(input);
            PickOutput();

            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, UIntPtr.Zero);
            mft.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, UIntPtr.Zero);
        }

        private void PickOutput()
        {
            for (uint i = 0; ; i++)
            {
                IMFMediaType type;
                int hr = mft.GetOutputAvailableType(0, i, out type);
                if (hr < 0) throw new COMException("the decoder offers no NV12 output", hr);
                Guid subtype;
                type.GetGUID(ref Mf.MF_MT_SUBTYPE, out subtype);
                if (subtype == Mf.MFVideoFormat_NV12)
                {
                    Mf.Check(mft.SetOutputType(0, type, 0), "SetOutputType");
                    ulong size;
                    if (type.GetUINT64(ref Mf.MF_MT_FRAME_SIZE, out size) >= 0) { width = (int)(size >> 32); height = (int)(size & 0xFFFFFFFF); }
                    uint s;
                    stride = type.GetUINT32(ref Mf.MF_MT_DEFAULT_STRIDE, out s) >= 0 && (int)s > 0 ? (int)s : width;
                    cropX = 0; cropY = 0; cropW = width; cropH = height;
                    IntPtr area = Marshal.AllocHGlobal(16);
                    try
                    {
                        if (type.GetBlob(ref MF_MT_MINIMUM_DISPLAY_APERTURE, area, 16, IntPtr.Zero) >= 0)
                        {
                            // MFVideoArea: OffsetX {fract, value}, OffsetY {fract, value}, cx, cy
                            cropX = Marshal.ReadInt16(area, 2);
                            cropY = Marshal.ReadInt16(area, 6);
                            cropW = Marshal.ReadInt32(area, 8);
                            cropH = Marshal.ReadInt32(area, 12);
                            if (cropW <= 0 || cropH <= 0 || cropX + cropW > width || cropY + cropH > height) { cropX = 0; cropY = 0; cropW = width; cropH = height; }
                        }
                    }
                    finally { Marshal.FreeHGlobal(area); }
                    Marshal.ReleaseComObject(type);
                    Mf.Check(mft.GetOutputStreamInfo(0, streamInfo), "GetOutputStreamInfo");
                    providesSamples = (Marshal.ReadInt32(streamInfo, 0) & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) != 0;
                    outSize = Math.Max(Marshal.ReadInt32(streamInfo, 4), stride * height * 3 / 2);
                    if (picture.Length < outSize) picture = new byte[outSize];
                    return;
                }
                Marshal.ReleaseComObject(type);
            }
        }

        /// <summary>Feeds one NAL unit (with its start code).</summary>
        public void Push(byte[] data, int offset, int length)
        {
            IMFMediaBuffer buffer;
            Mf.Check(Mf.MFCreateMemoryBuffer((uint)length, out buffer), "MFCreateMemoryBuffer");
            IMFSample sample;
            Mf.Check(Mf.MFCreateSample(out sample), "MFCreateSample");
            try
            {
                IntPtr p; uint max, cur;
                Mf.Check(buffer.Lock(out p, out max, out cur), "Lock");
                Marshal.Copy(data, offset, p, length);
                buffer.Unlock();
                buffer.SetCurrentLength((uint)length);
                IntPtr bufferPtr = Marshal.GetComInterfaceForObject(buffer, typeof(IMFMediaBuffer));
                try { sample.AddBuffer(bufferPtr); } finally { Marshal.Release(bufferPtr); }
                IntPtr samplePtr = Marshal.GetComInterfaceForObject(sample, typeof(IMFSample));
                try
                {
                    int hr = mft.ProcessInput(0, samplePtr, 0);
                    if (hr == MF_E_NOTACCEPTING) { Drain(); hr = mft.ProcessInput(0, samplePtr, 0); }
                    Mf.Check(hr, "ProcessInput");
                }
                finally { Marshal.Release(samplePtr); }
            }
            finally
            {
                Marshal.ReleaseComObject(sample);
                Marshal.ReleaseComObject(buffer);
            }
            Drain();
        }

        private void Drain()
        {
            while (true)
            {
                IMFSample sample = null;
                IMFMediaBuffer buffer = null;
                IntPtr samplePtr = IntPtr.Zero;
                if (!providesSamples)
                {
                    Mf.Check(Mf.MFCreateMemoryBuffer((uint)outSize, out buffer), "MFCreateMemoryBuffer");
                    Mf.Check(Mf.MFCreateSample(out sample), "MFCreateSample");
                    IntPtr bufferPtr = Marshal.GetComInterfaceForObject(buffer, typeof(IMFMediaBuffer));
                    try { sample.AddBuffer(bufferPtr); } finally { Marshal.Release(bufferPtr); }
                    samplePtr = Marshal.GetComInterfaceForObject(sample, typeof(IMFSample));
                }
                for (int i = 0; i < 32; i += 8) Marshal.WriteInt64(outputBuffer, i, 0);
                Marshal.WriteIntPtr(outputBuffer, 8, samplePtr);
                uint status;
                int hr = mft.ProcessOutput(0, 1, outputBuffer, out status);
                IntPtr events = Marshal.ReadIntPtr(outputBuffer, 24);
                if (events != IntPtr.Zero) Marshal.Release(events);
                IntPtr produced = Marshal.ReadIntPtr(outputBuffer, 8);
                try
                {
                    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
                    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) { PickOutput(); continue; }
                    Mf.Check(hr, "ProcessOutput");
                    Deliver(produced);
                }
                finally
                {
                    if (providesSamples && produced != IntPtr.Zero) Marshal.Release(produced);
                    if (samplePtr != IntPtr.Zero) Marshal.Release(samplePtr);
                    if (sample != null) Marshal.ReleaseComObject(sample);
                    if (buffer != null) Marshal.ReleaseComObject(buffer);
                }
            }
        }

        private void Deliver(IntPtr samplePtr)
        {
            if (samplePtr == IntPtr.Zero || Picture == null) return;
            var sample = (IMFSample)Marshal.GetObjectForIUnknown(samplePtr);
            try
            {
                IntPtr bufferPtr;
                Mf.Check(sample.ConvertToContiguousBuffer(out bufferPtr), "ConvertToContiguousBuffer");
                var buffer = (IMFMediaBuffer)Marshal.GetObjectForIUnknown(bufferPtr);
                Marshal.Release(bufferPtr);
                try
                {
                    IntPtr p; uint max, cur;
                    Mf.Check(buffer.Lock(out p, out max, out cur), "Lock");
                    try
                    {
                        int n = Math.Min((int)cur, picture.Length);
                        Marshal.Copy(p, picture, 0, n);
                    }
                    finally { buffer.Unlock(); }
                }
                finally { Marshal.ReleaseComObject(buffer); }
            }
            finally { Marshal.ReleaseComObject(sample); }
            Picture(picture, stride, height, cropX, cropY, cropW, cropH);
        }

        public void Dispose()
        {
            try { Marshal.ReleaseComObject(mft); } catch { }
            Marshal.FreeHGlobal(outputBuffer);
            Marshal.FreeHGlobal(streamInfo);
        }
    }
}
