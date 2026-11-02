# SPDX-License-Identifier: GPL-3.0-or-later
# Create or repair an Emacs shortcut and return its path and creation status as JSON.
[CmdletBinding()]
param(
    [string]$ShortcutPath,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
)

[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$ErrorActionPreference = 'Stop'
$appId = 'GNU.Emacs'
if (!$shortcutPath) {
    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Emacs.lnk'
}
$shortcutPath = [IO.Path]::GetFullPath($shortcutPath)
if ([IO.Path]::GetExtension($shortcutPath) -ine '.lnk') {
    throw 'ShortcutPath must name a Windows shortcut (.lnk).'
}
$created = -not (Test-Path -LiteralPath $shortcutPath)
if ($created) {
    if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
        throw "Emacs executable not found: $targetPath"
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($shortcutPath))
    $wscript = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        $link = $wscript.CreateShortcut($shortcutPath)
        $link.TargetPath = $targetPath
        $link.WorkingDirectory = [IO.Path]::GetDirectoryName($targetPath)
        $link.IconLocation = "$targetPath,0"
        $link.Description = 'GNU Emacs'
        $link.Save()
    } finally {
        if ($null -ne $link) {
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
        }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($wscript)
    }
} elseif (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    throw "ShortcutPath is not a file: $shortcutPath"
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace EmacsToast
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;
    }

    // The union starts at byte 8; the largest native union is 16 bytes on x64.
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort VariantType;
        [FieldOffset(8)] public IntPtr StringValue;
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    public static class ShortcutProperties
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        private static extern int SHGetPropertyStoreFromParsingName(
            string path, IntPtr bindContext, uint flags, ref Guid iid,
            [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        [DllImport("ole32.dll", ExactSpelling = true)]
        private static extern int PropVariantClear(ref PropVariant variant);

        public static void SetAppId(string shortcutPath, string appId)
        {
            Guid iid = typeof(IPropertyStore).GUID;
            IPropertyStore store;
            // GPS_READWRITE opens the shortcut's property store for editing.
            Marshal.ThrowExceptionForHR(SHGetPropertyStoreFromParsingName(
                shortcutPath, IntPtr.Zero, 2, ref iid, out store));
            PropVariant value = new PropVariant();
            try
            {
                PropertyKey key = new PropertyKey {
                    FormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
                    PropertyId = 5 // System.AppUserModel.ID
                };
                // InitPropVariantFromString is an inline SDK helper, not a DLL export.
                value.StringValue = Marshal.StringToCoTaskMemUni(appId);
                value.VariantType = 31; // VT_LPWSTR
                Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref value));
                Marshal.ThrowExceptionForHR(store.Commit());
            }
            finally
            {
                PropVariantClear(ref value);
                Marshal.FinalReleaseComObject(store);
            }
        }
    }
}
'@
[EmacsToast.ShortcutProperties]::SetAppId($shortcutPath, $appId)
# Read independently of IPropertyStore and Start Menu indexing.
$shell = New-Object -ComObject Shell.Application
$folder = $null
$item = $null
try {
    $folder = $shell.Namespace([IO.Path]::GetDirectoryName($shortcutPath))
    $item = $folder.ParseName([IO.Path]::GetFileName($shortcutPath))
    $storedAppId = $item.ExtendedProperty('System.AppUserModel.ID')
    if ($storedAppId -ne $appId) {
        throw "Shortcut AppUserModelID verification failed: '$storedAppId'."
    }
} finally {
    if ($null -ne $item) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item)
    }
    if ($null -ne $folder) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($folder)
    }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
}
[pscustomobject]@{ shortcut = $shortcutPath; created = $created } | ConvertTo-Json -Compress
