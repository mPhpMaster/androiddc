// AndroidDC - the COM class Windows creates for the virtual camera.
//
// The Frame Server creates this class from the CLSID given to
// MFCreateVirtualCamera, sets its own attributes on it, then calls
// ActivateObject for the media source. The attributes are handed on to the
// source, as the Windows virtual camera samples do.

using System;
using System.Runtime.InteropServices;

namespace AndroidDC.VCam
{
    [ComVisible(true)]
    [Guid(Activator.ClsidText)]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class Activator : IMFActivate
    {
        public const string ClsidText = "B6F9266A-DE52-4660-AFB9-AC513027B060";

        private readonly IMFAttributes a;
        private MediaSource source;

        public Activator()
        {
            Log.Write("Activator created");
            Mf.Check(Mf.MFCreateAttributes(out a, 4), "MFCreateAttributes");
        }

        public int ActivateObject(ref Guid riid, out IntPtr ppv)
        {
            ppv = IntPtr.Zero;
            try
            {
                lock (this)
                {
                    if (source == null) source = new MediaSource(a);
                }
                IntPtr unknown = Marshal.GetIUnknownForObject(source);
                try { return Marshal.QueryInterface(unknown, ref riid, out ppv); }
                finally { Marshal.Release(unknown); }
            }
            catch (Exception e)
            {
                Log.Write("ActivateObject failed: " + e);
                return e.HResult < 0 ? e.HResult : Mf.E_INVALIDARG;
            }
        }

        public int ShutdownObject()
        {
            lock (this)
            {
                if (source != null) source.Shutdown();
                source = null;
            }
            return Mf.S_OK;
        }

        public int DetachObject()
        {
            lock (this) { source = null; }
            return Mf.S_OK;
        }

        // ---- IMFAttributes, kept by an ordinary attribute store ----
        public int GetItem(ref Guid key, IntPtr pValue) { return a.GetItem(ref key, pValue); }
        public int GetItemType(ref Guid key, out int type) { return a.GetItemType(ref key, out type); }
        public int CompareItem(ref Guid key, IntPtr pValue, out int result) { return a.CompareItem(ref key, pValue, out result); }
        public int Compare(IntPtr pTheirs, int matchType, out int result) { return a.Compare(pTheirs, matchType, out result); }
        public int GetUINT32(ref Guid key, out uint value) { return a.GetUINT32(ref key, out value); }
        public int GetUINT64(ref Guid key, out ulong value) { return a.GetUINT64(ref key, out value); }
        public int GetDouble(ref Guid key, out double value) { return a.GetDouble(ref key, out value); }
        public int GetGUID(ref Guid key, out Guid value) { return a.GetGUID(ref key, out value); }
        public int GetStringLength(ref Guid key, out uint length) { return a.GetStringLength(ref key, out length); }
        public int GetString(ref Guid key, IntPtr buffer, uint size, IntPtr pLength) { return a.GetString(ref key, buffer, size, pLength); }
        public int GetAllocatedString(ref Guid key, out IntPtr ppwsz, out uint length) { return a.GetAllocatedString(ref key, out ppwsz, out length); }
        public int GetBlobSize(ref Guid key, out uint size) { return a.GetBlobSize(ref key, out size); }
        public int GetBlob(ref Guid key, IntPtr buffer, uint size, IntPtr pSize) { return a.GetBlob(ref key, buffer, size, pSize); }
        public int GetAllocatedBlob(ref Guid key, out IntPtr buffer, out uint size) { return a.GetAllocatedBlob(ref key, out buffer, out size); }
        public int GetUnknown(ref Guid key, ref Guid riid, out IntPtr ppv) { return a.GetUnknown(ref key, ref riid, out ppv); }
        public int SetItem(ref Guid key, IntPtr pValue) { return a.SetItem(ref key, pValue); }
        public int DeleteItem(ref Guid key) { return a.DeleteItem(ref key); }
        public int DeleteAllItems() { return a.DeleteAllItems(); }
        public int SetUINT32(ref Guid key, uint value) { return a.SetUINT32(ref key, value); }
        public int SetUINT64(ref Guid key, ulong value) { return a.SetUINT64(ref key, value); }
        public int SetDouble(ref Guid key, double value) { return a.SetDouble(ref key, value); }
        public int SetGUID(ref Guid key, ref Guid value) { return a.SetGUID(ref key, ref value); }
        public int SetString(ref Guid key, string value) { return a.SetString(ref key, value); }
        public int SetBlob(ref Guid key, IntPtr buffer, uint size) { return a.SetBlob(ref key, buffer, size); }
        public int SetUnknown(ref Guid key, IntPtr pUnknown) { return a.SetUnknown(ref key, pUnknown); }
        public int LockStore() { return a.LockStore(); }
        public int UnlockStore() { return a.UnlockStore(); }
        public int GetCount(out uint count) { return a.GetCount(out count); }
        public int GetItemByIndex(uint index, out Guid key, IntPtr pValue) { return a.GetItemByIndex(index, out key, pValue); }
        public int CopyAllItems(IntPtr pDest) { return a.CopyAllItems(pDest); }
    }
}
