param([Parameter(Mandatory=$true)][string]$Archive,[Parameter(Mandatory=$true)][string]$Destination)
$ErrorActionPreference='Stop'
# Unzip with .NET directly instead of Expand-Archive: on some machines Windows PowerShell 5.1 picks up a newer
# Microsoft.PowerShell.Archive module whose -Force path calls an ExtractToDirectory overload .NET Framework lacks.
# Existing files are overwritten (a half-finished earlier extraction must not block this one).
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = [System.IO.Path]::GetFullPath($Destination)
[void][System.IO.Directory]::CreateDirectory($root)
$prefix = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
try {
  foreach ($entry in $zip.Entries) {
    $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $entry.FullName))
    # An entry must stay inside the destination (no "..\" escapes).
    if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Archive entry escapes the destination: $($entry.FullName)"
    }
    if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
      [void][System.IO.Directory]::CreateDirectory($target)
      continue
    }
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
  }
} finally {
  $zip.Dispose()
}
