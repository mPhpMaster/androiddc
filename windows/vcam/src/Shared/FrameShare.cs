// AndroidDC - the shared picture between the feeder and the camera.
//
// The camera's media source runs inside Windows' Frame Server service, in
// session 0, as LOCAL SERVICE. The feeder that has the phone's picture runs
// in the user's desktop session. Only the service side may create a Global\
// section, so the source creates it, with a security descriptor that lets
// interactive users write to it, and the feeder opens it.
//
// Layout: a 64-byte header, then one NV12 frame of Width x Height.
// The writer makes Sequence odd while it writes and even when the frame is
// whole (a sequence lock), so the reader never takes a half-written frame.

using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading;

namespace AndroidDC.VCam
{
    public sealed unsafe class FrameShare : IDisposable
    {
        public const string Name = @"Global\AndroidDC.VirtualCamera.Frame";
        public const uint Magic = 0x43564441;   // "ADVC"
        public const int Width = 1280;
        public const int Height = 720;
        public const int FrameBytes = Width * Height * 3 / 2;
        public const int HeaderBytes = 64;
        public const int TotalBytes = HeaderBytes + FrameBytes;

        // header offsets
        private const int OffMagic = 0, OffWidth = 4, OffHeight = 8, OffSequence = 16, OffWriteTick = 24;

        // SYSTEM, LOCAL SERVICE and administrators: all; interactive users: read and write.
        private const string Sddl = "D:(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;BA)(A;;GRGW;;;IU)";

        private IntPtr mapping;
        private byte* view;

        private FrameShare(IntPtr mapping, byte* view)
        {
            this.mapping = mapping;
            this.view = view;
        }

        /// <summary>The service side: creates the section (or opens it if it is already there).</summary>
        public static FrameShare Create()
        {
            IntPtr sd;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(Sddl, 1, out sd, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "security descriptor");
            try
            {
                var sa = new SECURITY_ATTRIBUTES { nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>(), lpSecurityDescriptor = sd };
                IntPtr h = CreateFileMappingW(new IntPtr(-1), ref sa, PAGE_READWRITE, 0, TotalBytes, Name);
                if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFileMapping " + Name);
                var share = Map(h, FILE_MAP_ALL_ACCESS);
                *(uint*)(share.view + OffWidth) = Width;
                *(uint*)(share.view + OffHeight) = Height;
                *(uint*)(share.view + OffMagic) = Magic;
                return share;
            }
            finally { LocalFree(sd); }
        }

        /// <summary>The feeder side: opens the section the camera made. Null when the camera is not running.</summary>
        public static FrameShare Open()
        {
            IntPtr h = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, false, Name);
            if (h == IntPtr.Zero) return null;
            var share = Map(h, FILE_MAP_READ | FILE_MAP_WRITE);
            if (*(uint*)(share.view + OffMagic) != Magic) { share.Dispose(); return null; }
            return share;
        }

        private static FrameShare Map(IntPtr h, uint access)
        {
            IntPtr v = MapViewOfFile(h, access, 0, 0, (UIntPtr)TotalBytes);
            if (v == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                CloseHandle(h);
                throw new Win32Exception(error, "MapViewOfFile " + Name);
            }
            return new FrameShare(h, (byte*)v);
        }

        public long Sequence { get { return Volatile.Read(ref *(long*)(view + OffSequence)); } }

        /// <summary>Milliseconds since the feeder last wrote a whole frame; long.MaxValue if it never did.</summary>
        public long AgeMs
        {
            get
            {
                long tick = Volatile.Read(ref *(long*)(view + OffWriteTick));
                if (tick == 0) return long.MaxValue;
                return (long)GetTickCount64() - tick;
            }
        }

        /// <summary>Writes one whole NV12 frame.</summary>
        public void Write(byte* nv12)
        {
            long* seq = (long*)(view + OffSequence);
            long s = Volatile.Read(ref *seq);
            if ((s & 1) != 0) s++;              // a writer died half way: start clean
            Volatile.Write(ref *seq, s + 1);    // odd: writing
            Buffer.MemoryCopy(nv12, view + HeaderBytes, FrameBytes, FrameBytes);
            Volatile.Write(ref *(long*)(view + OffWriteTick), (long)GetTickCount64());
            Volatile.Write(ref *seq, s + 2);    // even: whole
        }

        /// <summary>Copies the newest whole frame into dest. False if none is whole right now.</summary>
        public bool TryRead(byte* dest, out long sequence)
        {
            long* seq = (long*)(view + OffSequence);
            sequence = Volatile.Read(ref *seq);
            if (sequence == 0 || (sequence & 1) != 0) return false;
            Buffer.MemoryCopy(view + HeaderBytes, dest, FrameBytes, FrameBytes);
            return Volatile.Read(ref *seq) == sequence;
        }

        public void Dispose()
        {
            if (view != null) { UnmapViewOfFile((IntPtr)view); view = null; }
            if (mapping != IntPtr.Zero) { CloseHandle(mapping); mapping = IntPtr.Zero; }
        }

        // ---- Win32 ----
        private const uint PAGE_READWRITE = 0x04;
        private const uint FILE_MAP_ALL_ACCESS = 0xF001F;
        private const uint FILE_MAP_WRITE = 0x0002;
        private const uint FILE_MAP_READ = 0x0004;

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileMappingW(IntPtr hFile, ref SECURITY_ATTRIBUTES sa, uint protect, uint sizeHigh, uint sizeLow, string name);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr OpenFileMappingW(uint access, bool inherit, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr MapViewOfFile(IntPtr h, uint access, uint offsetHigh, uint offsetLow, UIntPtr bytes);
        [DllImport("kernel32.dll")] private static extern bool UnmapViewOfFile(IntPtr view);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr h);
        [DllImport("kernel32.dll")] private static extern ulong GetTickCount64();
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr sd, IntPtr size);
    }
}
