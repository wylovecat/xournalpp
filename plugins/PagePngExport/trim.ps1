# Trims transparent borders of a PNG in place.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File trim.ps1 -Path <file.png> [-Margin 10] [-VerticalOnly]
#
# Prints one line on success: "<oldW>x<oldH> -> <newW>x<newH>", or "EMPTY".
# Exit code 1 on failure.
#
# Uses System.Drawing (ships with Windows), so no extra software is needed.

param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Margin = 10,
    [switch]$VerticalOnly,
    [int]$AlphaThreshold = 8
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$source = @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

public class PngTrim
{
    // Returns the descriptive string, or throws on a hard error.
    // The cropped image is written from memory after the source bitmap is
    // disposed, because GDI+ locks the file while it is open.
    public static string Trim(string path, int margin, bool verticalOnly, int alphaThreshold)
    {
        int w, h;
        byte[] cropped = null;
        string result;

        using (var bmp = new Bitmap(path))
        {
            w = bmp.Width;
            h = bmp.Height;

            var data = bmp.LockBits(new Rectangle(0, 0, w, h),
                                    ImageLockMode.ReadOnly,
                                    PixelFormat.Format32bppArgb);
            int stride = data.Stride;
            byte[] bytes = new byte[stride * h];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            bmp.UnlockBits(data);

            int minX = w, minY = h, maxX = -1, maxY = -1;
            for (int y = 0; y < h; y++)
            {
                int row = y * stride;
                for (int x = 0; x < w; x++)
                {
                    if (bytes[row + x * 4 + 3] > alphaThreshold)
                    {
                        if (x < minX) minX = x;
                        if (x > maxX) maxX = x;
                        if (y < minY) minY = y;
                        if (y > maxY) maxY = y;
                    }
                }
            }

            if (maxY < 0)
                return "EMPTY";

            if (verticalOnly) { minX = 0; maxX = w - 1; }

            minX = Math.Max(0, minX - margin);
            minY = Math.Max(0, minY - margin);
            maxX = Math.Min(w - 1, maxX + margin);
            maxY = Math.Min(h - 1, maxY + margin);

            int cw = maxX - minX + 1;
            int ch = maxY - minY + 1;

            if (cw == w && ch == h)
                return w + "x" + h + " -> unchanged";

            using (var crop = bmp.Clone(new Rectangle(minX, minY, cw, ch), PixelFormat.Format32bppArgb))
            using (var ms = new MemoryStream())
            {
                crop.Save(ms, ImageFormat.Png);
                cropped = ms.ToArray();
            }
            result = w + "x" + h + " -> " + cw + "x" + ch;
        }

        File.WriteAllBytes(path, cropped);
        return result;
    }
}
"@

Add-Type -TypeDefinition $source -ReferencedAssemblies System.Drawing

try {
    [PngTrim]::Trim($Path, $Margin, [bool]$VerticalOnly, $AlphaThreshold)
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
