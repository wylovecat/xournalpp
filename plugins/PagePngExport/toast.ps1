param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

# Read the message from a UTF-8 file so Chinese paths do not have to survive
# Lua -> cmd.exe -> PowerShell command-line quoting.
$message = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
if ([string]::IsNullOrWhiteSpace($message)) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$notification = New-Object System.Windows.Forms.NotifyIcon
try {
    $notification.Icon = [System.Drawing.SystemIcons]::Information
    $notification.BalloonTipTitle = "Xournal++"
    $notification.BalloonTipText = $message.Trim()
    $notification.Visible = $true
    $notification.ShowBalloonTip(2500)
    Start-Sleep -Milliseconds 3000
}
finally {
    $notification.Visible = $false
    $notification.Dispose()
}
