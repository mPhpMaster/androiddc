// AndroidDC - a small log for the camera source, which runs inside a
// Windows service where nothing else can be seen. It is written next to the
// DLL when that folder can be written, else to the service's temp folder.

using System;
using System.IO;

namespace AndroidDC.VCam
{
    internal static class Log
    {
        private static readonly object gate = new object();
        private static string path;

        public static void Write(string line)
        {
            try
            {
                lock (gate)
                {
                    if (path == null) path = Pick();
                    var info = new FileInfo(path);
                    if (info.Exists && info.Length > 512 * 1024) File.Delete(path);
                    File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + "  [" +
                        Environment.ProcessId + "] " + line + Environment.NewLine);
                }
            }
            catch { }
        }

        private static string Pick()
        {
            string here = Path.GetDirectoryName(typeof(Log).Assembly.Location);
            string candidate = Path.Combine(here ?? ".", "vcam-source.log");
            try
            {
                File.AppendAllText(candidate, "");
                return candidate;
            }
            catch
            {
                return Path.Combine(Path.GetTempPath(), "androiddc-vcam-source.log");
            }
        }
    }
}
