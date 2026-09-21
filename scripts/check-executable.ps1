[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Win32', 'Win64')]
    [string]$Platform,

    [string]$ExpectedVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedPath = (Resolve-Path -LiteralPath $Path).Path
$stream = [System.IO.File]::OpenRead($resolvedPath)
$reader = [System.IO.BinaryReader]::new($stream)
try {
    if (($stream.Length -lt 64) -or ($reader.ReadUInt16() -ne 0x5A4D)) {
        throw "Not a Windows executable: $resolvedPath"
    }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    if (($peOffset -lt 64) -or (($peOffset + 6) -gt $stream.Length)) {
        throw "Invalid PE header offset: $resolvedPath"
    }
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
        throw "Missing PE signature: $resolvedPath"
    }
    $architecture = switch ($reader.ReadUInt16()) {
        0x014C { 'Win32' }
        0x8664 { 'Win64' }
        default { throw "Unsupported PE architecture: $resolvedPath" }
    }
}
finally {
    $reader.Dispose()
}

if ($architecture -ne $Platform) {
    throw "Expected $Platform, found ${architecture}: $resolvedPath"
}

$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedPath)
$actualVersion = '{0}.{1}.{2}.{3}' -f $versionInfo.FileMajorPart,
    $versionInfo.FileMinorPart, $versionInfo.FileBuildPart, $versionInfo.FilePrivatePart
if ([string]::IsNullOrWhiteSpace($versionInfo.FileVersion)) {
    throw "Missing file version resource: $resolvedPath"
}
if ($ExpectedVersion -and ([version]$actualVersion -ne [version]$ExpectedVersion)) {
    throw "Expected version $ExpectedVersion, found ${actualVersion}: $resolvedPath"
}

if ([System.IO.Path]::GetFileName($resolvedPath) -ine 'HomeLibRu.exe') {
    throw "The distributed application must be named HomeLibRu.exe: $resolvedPath"
}
$expectedFields = @{
    ProductName = 'HomeLib Ru'
    InternalName = 'HomeLibRu'
    OriginalFilename = 'HomeLibRu.exe'
    LegalCopyright = 'Copyright (c) 2008-2026 Oleksiy Penkov'
}
foreach ($field in $expectedFields.Keys) {
    if ($versionInfo.$field -cne $expectedFields[$field]) {
        throw "Invalid $field in ${resolvedPath}: expected '$($expectedFields[$field])', found '$($versionInfo.$field)'."
    }
}
foreach ($field in @('ProductName', 'InternalName', 'OriginalFilename', 'LegalTrademarks')) {
    if ($versionInfo.$field -match 'MyHomeLib') {
        throw "Upstream branding is not permitted in the $field version field: $resolvedPath"
    }
}

if (-not ('MyHomeLib.ReleaseResources' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MyHomeLib {
    public static class ReleaseResources {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint SizeofResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr LockResource(IntPtr resource);
        [DllImport("kernel32.dll")]
        private static extern bool FreeLibrary(IntPtr module);

        public static byte[] ReadManifest(string path) {
            // Data-file loading reads resources without running executable code.
            IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 2);
            if (module == IntPtr.Zero)
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read PE resources");
            try {
                IntPtr resource = FindResource(module, new IntPtr(1), new IntPtr(24));
                if (resource == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(),
                        "Missing embedded application manifest (RT_MANIFEST, ID 1)");
                uint size = SizeofResource(module, resource);
                if (size == 0 || size > 1048576)
                    throw new InvalidOperationException("Invalid application manifest size");
                IntPtr loaded = LoadResource(module, resource);
                if (loaded == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load manifest");
                IntPtr bytes = LockResource(loaded);
                if (bytes == IntPtr.Zero)
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot read manifest");
                byte[] result = new byte[size];
                Marshal.Copy(bytes, result, 0, result.Length);
                return result;
            }
            finally {
                FreeLibrary(module);
            }
        }
    }
}
'@
}

$manifestBytes = [MyHomeLib.ReleaseResources]::ReadManifest($resolvedPath)
$manifestStream = [System.IO.MemoryStream]::new($manifestBytes, $false)
$xmlSettings = [System.Xml.XmlReaderSettings]::new()
$xmlSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
$xmlSettings.XmlResolver = $null
$xmlReader = [System.Xml.XmlReader]::Create($manifestStream, $xmlSettings)
try {
    $manifest = [System.Xml.XmlDocument]::new()
    $manifest.XmlResolver = $null
    $manifest.Load($xmlReader)
}
finally {
    $xmlReader.Dispose()
    $manifestStream.Dispose()
}

$namespaces = [System.Xml.XmlNamespaceManager]::new($manifest.NameTable)
$namespaces.AddNamespace('a', 'urn:schemas-microsoft-com:asm.v1')
$namespaces.AddNamespace('a3', 'urn:schemas-microsoft-com:asm.v3')
$namespaces.AddNamespace('dpi', 'http://schemas.microsoft.com/SMI/2016/WindowsSettings')
$controls = $manifest.SelectSingleNode(
    '/a:assembly/a:dependency/a:dependentAssembly/a:assemblyIdentity[@name="Microsoft.Windows.Common-Controls"]',
    $namespaces)
if (($null -eq $controls) -or ($controls.GetAttribute('version') -ne '6.0.0.0') -or
    ($controls.GetAttribute('publicKeyToken') -ne '6595b64144ccf1df')) {
    throw "Manifest does not enable Windows common controls 6; book links will be unavailable: $resolvedPath"
}
$dpi = $manifest.SelectSingleNode('/a:assembly/a3:application/a3:windowsSettings/dpi:dpiAwareness',
    $namespaces)
if (($null -eq $dpi) -or ($dpi.InnerText.Trim() -ne 'PerMonitorV2')) {
    throw "Manifest does not enable PerMonitorV2 DPI awareness: $resolvedPath"
}

[pscustomobject]@{
    Path = $resolvedPath
    Architecture = $architecture
    FileVersion = $actualVersion
    ProductName = $versionInfo.ProductName
    InternalName = $versionInfo.InternalName
    OriginalFilename = $versionInfo.OriginalFilename
    LegalCopyright = $versionInfo.LegalCopyright
    CommonControlsVersion = $controls.GetAttribute('version')
    DpiAwareness = $dpi.InnerText.Trim()
}
