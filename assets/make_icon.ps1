# sgcFSearch: draws the magnifier app icon with System.Drawing and writes
# assets\sgcFSearch.ico (16, 20, 24, 32, 40, 48, 64 px as 32 bpp DIB entries,
# 256 px as a PNG entry). usage: powershell -NoProfile -File make_icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot 'sgcFSearch.ico'
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)

function New-Glyph([int]$size) {
  $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)
  # design grid 256 x 256
  $g.ScaleTransform($size / 256.0, $size / 256.0)
  # small sizes get thicker strokes so the glyph stays readable
  $k = 1.0
  if ($size -le 24) { $k = 1.3 } elseif ($size -le 48) { $k = 1.12 }
  $handle = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 52, 58, 64), (44 * $k))
  $handle.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $handle.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($handle, 160, 160, 226, 226)
  $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 226, 239, 255))
  $g.FillEllipse($fill, 30, 30, 152, 152)
  $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 25, 103, 210), (26 * $k))
  $g.DrawEllipse($ring, 30, 30, 152, 152)
  if ($size -ge 32) {
    $shine = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 255, 255, 255), 12)
    $shine.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $shine.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($shine, 62, 62, 88, 88, 190, 70)
    $shine.Dispose()
  }
  $handle.Dispose(); $fill.Dispose(); $ring.Dispose(); $g.Dispose()
  return $bmp
}

function Get-DibBytes([System.Drawing.Bitmap]$bmp) {
  $size = $bmp.Width
  $rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $pixels = New-Object byte[] ($stride * $size)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
  $bmp.UnlockBits($data)
  $maskRow = [int]([Math]::Floor(($size + 31) / 32) * 4)
  $ms = New-Object System.IO.MemoryStream
  $w = New-Object System.IO.BinaryWriter($ms)
  # BITMAPINFOHEADER, height doubled (XOR + AND mask)
  $w.Write([int32]40); $w.Write([int32]$size); $w.Write([int32]($size * 2))
  $w.Write([int16]1); $w.Write([int16]32); $w.Write([int32]0)
  $w.Write([int32](($size * 4 + $maskRow) * $size)); $w.Write([int32]0); $w.Write([int32]0)
  $w.Write([int32]0); $w.Write([int32]0)
  # XOR bitmap, BGRA, bottom-up
  for ($y = $size - 1; $y -ge 0; $y--) { $w.Write($pixels, $y * $stride, $size * 4) }
  # AND mask, bottom-up, bit set = transparent
  for ($y = $size - 1; $y -ge 0; $y--) {
    $row = New-Object byte[] $maskRow
    for ($x = 0; $x -lt $size; $x++) {
      if ($pixels[$y * $stride + $x * 4 + 3] -eq 0) { $row[[int][Math]::Floor($x / 8)] = $row[[int][Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8)) }
    }
    $w.Write($row)
  }
  $w.Flush()
  return ,$ms.ToArray()
}

$images = @()
foreach ($s in $sizes) {
  $bmp = New-Glyph $s
  if ($s -eq 256) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $images += ,($ms.ToArray())
  } else {
    $images += ,(Get-DibBytes $bmp)
  }
  $bmp.Dispose()
}

$fs = [System.IO.File]::Create($out)
$w = New-Object System.IO.BinaryWriter($fs)
# ICONDIR
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $dim = $s; if ($s -ge 256) { $dim = 0 }
  $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
  $w.Write([int16]1); $w.Write([int16]32)
  $w.Write([int32]$images[$i].Length); $w.Write([int32]$offset)
  $offset += $images[$i].Length
}
foreach ($img in $images) { $w.Write($img) }
$w.Close()
"icon written: $out ($((Get-Item $out).Length) bytes, $($sizes.Count) images)"
