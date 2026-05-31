# Local-only permission check for New-TemporaryFile on Unix.
# Expected on Linux/macOS: created temp file is owner-readable/writable only (-rw------- / 600).
$ErrorActionPreference = 'Stop'
$temp = New-TemporaryFile
try {
    $mode = if ($IsWindows) { (Get-Acl -LiteralPath $temp.FullName).AccessToString } else { (stat -c '%a %A %U:%G' -- $temp.FullName) }
    [pscustomobject]@{
        Path = $temp.FullName
        Mode = $mode
        Classification = 'No issue if Unix mode is 600; review separately on non-Unix ACLs.'
    }
}
finally {
    Remove-Item -LiteralPath $temp.FullName -Force -ErrorAction SilentlyContinue
}
