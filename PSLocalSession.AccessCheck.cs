using System;
using System.Runtime.InteropServices;

namespace PSLocalSession.Native
{
    // GetEffectiveRightsFromAclW is deprecated in favor of the Authz API, but it is
    // sufficient for this conservative check: it evaluates the DACL for a SID without a
    // token, and any failure or ambiguity falls back to staging a target-readable copy.
    public static class FileAccessCheck
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct TRUSTEE
        {
            public IntPtr pMultipleTrustee;
            public int MultipleTrusteeOperation;
            public int TrusteeForm;
            public int TrusteeType;
            public IntPtr ptstrName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct GENERIC_MAPPING
        {
            public uint GenericRead;
            public uint GenericWrite;
            public uint GenericExecute;
            public uint GenericAll;
        }

        private const int SE_FILE_OBJECT = 1;
        private const int DACL_SECURITY_INFORMATION = 4;
        private const int TRUSTEE_IS_SID = 0;
        private const int TRUSTEE_IS_USER = 1;

        private const uint FILE_GENERIC_READ = 0x00120089;
        private const uint FILE_GENERIC_WRITE = 0x00120116;
        private const uint FILE_GENERIC_EXECUTE = 0x001200A0;
        private const uint FILE_ALL_ACCESS = 0x001F01FF;

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ConvertStringSidToSidW(string stringSid, out IntPtr sid);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetNamedSecurityInfoW(
            string objectName,
            int objectType,
            int securityInfo,
            out IntPtr owner,
            out IntPtr group,
            out IntPtr dacl,
            out IntPtr sacl,
            out IntPtr securityDescriptor);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetEffectiveRightsFromAclW(
            IntPtr acl,
            ref TRUSTEE trustee,
            out uint accessRights);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern void MapGenericMask(
            ref uint accessMask,
            ref GENERIC_MAPPING genericMapping);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        // Returns the effective access mask, or -1 if the ACL or trustee cannot be evaluated.
        public static long GetEffectiveRights(string path, string sid)
        {
            IntPtr sidBytes = IntPtr.Zero;
            IntPtr securityDescriptor = IntPtr.Zero;
            try
            {
                if (!ConvertStringSidToSidW(sid, out sidBytes))
                {
                    return -1;
                }

                TRUSTEE trustee = new TRUSTEE();
                trustee.TrusteeForm = TRUSTEE_IS_SID;
                trustee.TrusteeType = TRUSTEE_IS_USER;
                trustee.ptstrName = sidBytes;

                IntPtr owner;
                IntPtr group;
                IntPtr dacl;
                IntPtr sacl;
                uint result = GetNamedSecurityInfoW(
                    path,
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    out owner,
                    out group,
                    out dacl,
                    out sacl,
                    out securityDescriptor);
                if (result != 0)
                {
                    return -1;
                }
                if (dacl == IntPtr.Zero)
                {
                    return (long)FILE_ALL_ACCESS;
                }

                uint access;
                result = GetEffectiveRightsFromAclW(dacl, ref trustee, out access);
                if (result != 0)
                {
                    return -1;
                }

                GENERIC_MAPPING mapping = new GENERIC_MAPPING();
                mapping.GenericRead = FILE_GENERIC_READ;
                mapping.GenericWrite = FILE_GENERIC_WRITE;
                mapping.GenericExecute = FILE_GENERIC_EXECUTE;
                mapping.GenericAll = FILE_ALL_ACCESS;
                MapGenericMask(ref access, ref mapping);
                return (long)access;
            }
            finally
            {
                if (sidBytes != IntPtr.Zero) { LocalFree(sidBytes); }
                if (securityDescriptor != IntPtr.Zero) { LocalFree(securityDescriptor); }
            }
        }
    }
}
