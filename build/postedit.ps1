# sgcFSearch post-edit sequence for a .pas / .dpr file:
#   1. re-encode UTF-8 -> ANSI (1252)   2. Embarcadero Formatter
#   3. repair the copyright byte (0x3F or EF BF BD -> 0xA9)   4. byte check
# usage: powershell -NoProfile -File postedit.ps1 <file> [-NoFormat]
# Prints only the step 4 line: BOM=False  high=1  <offset>:0xA9
param([Parameter(Mandatory=$true)][string]$File, [switch]$NoFormat)
$ErrorActionPreference = 'Stop'
$f = (Resolve-Path $File).Path
# 1. re-encode
$t = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($f, $t, [Text.Encoding]::GetEncoding(1252))
# 2. format
if (-not $NoFormat) {
  & "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\Formatter.exe" "$f" *> $null
}
# 3. fix the copyright byte
$b = [IO.File]::ReadAllBytes($f)
if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $b = $b[3..($b.Length-1)] }
$o = New-Object Collections.Generic.List[byte]; $i = 0; $d = $false
while ($i -lt $b.Length) {
  if (-not $d -and $i -lt 400 -and $i+2 -lt $b.Length -and $b[$i] -eq 0xEF -and $b[$i+1] -eq 0xBF -and $b[$i+2] -eq 0xBD) { $o.Add(0xA9); $i += 3; $d = $true }
  elseif (-not $d -and $i -lt 400 -and $i+1 -lt $b.Length -and $b[$i] -eq 0xC2 -and $b[$i+1] -eq 0xA9) { $o.Add(0xA9); $i += 2; $d = $true }
  else { $o.Add($b[$i]); $i++ }
}
$b = $o.ToArray(); $a = [Text.Encoding]::GetEncoding(1252)
if (-not $d) {
  for ($i = 100; $i -lt 400 -and $i -lt $b.Length; $i++) {
    if ($b[$i] -eq 0x3F) { $c = $a.GetString($b, [Math]::Max(0, $i-10), 20); if ($c -match 'copyright') { $b[$i] = 0xA9; $d = $true; break } }
  }
}
[IO.File]::WriteAllBytes($f, $b)
# 4. verify by bytes
$b = [IO.File]::ReadAllBytes($f); $h = @()
for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $h += ('{0}:0x{1:X2}' -f $i, $b[$i]) } }
(Split-Path $f -Leaf) + '  BOM=' + ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) + '  high=' + $h.Count + '  ' + ($h -join ' ')
