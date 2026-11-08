// AndroidDC - the test pattern the camera shows while no phone is feeding it:
// seven grey bars with a dark band moving down. The self-test reads the bars
// back to prove frames pass through the Frame Server unchanged.

using System;

namespace AndroidDC.VCam
{
    public static class Pattern
    {
        public static readonly byte[] Bars = { 235, 210, 170, 145, 106, 81, 41 };
        public const int BandHeight = 24;
        public const byte BandY = 16;

        public static int BandTop(long frameNumber)
        {
            return (int)(frameNumber * 6 % (FrameShare.Height - BandHeight));
        }

        public static void Draw(byte[] nv12, long frameNumber)
        {
            int w = FrameShare.Width, h = FrameShare.Height;
            var row = new byte[w];
            for (int x = 0; x < w; x++) row[x] = Bars[x * Bars.Length / w];
            int band = BandTop(frameNumber);
            for (int y = 0; y < h; y++)
            {
                if (y >= band && y < band + BandHeight) Array.Fill(nv12, BandY, y * w, w);
                else Buffer.BlockCopy(row, 0, nv12, y * w, w);
            }
            Array.Fill(nv12, (byte)128, w * h, w * h / 2);
        }

        /// <summary>True if this Y plane shows the bars on a row clear of the band.</summary>
        public static bool Looks(byte[] y, int stride, out string detail)
        {
            int w = FrameShare.Width, h = FrameShare.Height;
            foreach (int row in new[] { h / 4, h / 2, 3 * h / 4 })
            {
                bool ok = true;
                var seen = new int[Bars.Length];
                for (int i = 0; i < Bars.Length; i++)
                {
                    int x = (2 * i + 1) * w / (2 * Bars.Length);
                    seen[i] = y[row * stride + x];
                    if (Math.Abs(seen[i] - Bars[i]) > 4) ok = false;
                }
                detail = "row " + row + ": " + string.Join(",", seen);
                if (ok) return true;
            }
            detail = "no row matched the bars";
            return false;
        }
    }
}
