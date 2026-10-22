<# : batch launcher - PowerShell treats this block as a comment
@echo off
set "USBMAKER_SELF=%~f0"
set "USBMAKER_ISO=%~1"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "& ([ScriptBlock]::Create([IO.File]::ReadAllText($env:USBMAKER_SELF))) -IsoPath $env:USBMAKER_ISO"
exit /b
#>

<#
  USB-Boot-Maker.bat  -  USB Boot Maker (Windows + Linux), one single file.

  The top of this file is a tiny batch launcher; everything below is PowerShell.
  Double-click the file to open the window, or drop an ISO/IMG file onto its icon.

  Makes a bootable USB from an image file:
    - Windows / Windows Server ISO -> "Windows" mode: the USB is partitioned
      (MBR or GPT), formatted (FAT32 or NTFS) and the ISO files are copied
      (install.wim is split automatically on FAT32).
    - Linux ISO or raw .img        -> "DD" mode: the image is written raw to
      the USB, sector by sector (same as Rufus "DD mode" or balenaEtcher).

  The mode is picked automatically from the file and can be changed.
  Compressed images (.img.xz, .zip, .gz) must be extracted first.

  The window runs WITHOUT admin rights so drag & drop from Explorer works
  (Windows blocks drag & drop into Administrator windows). The actual work
  runs in a separate Administrator window after the UAC prompt.
#>
param(
    [switch]$Worker,
    [string]$IsoPath,
    [int]$DiskNumber = -1,
    [ValidateSet("Windows", "DD")][string]$Mode = "Windows",
    [ValidateSet("FAT32", "NTFS")][string]$FileSystem = "FAT32",
    [ValidateSet("MBR", "GPT")][string]$PartitionScheme = "MBR",
    [string]$Label = "WINSERVER",
    [long]$DiskSize = 0
)

# Path of this file (the .bat when started by the launcher above)
$script:SelfPath = $PSCommandPath
if (-not $script:SelfPath) { $script:SelfPath = $env:USBMAKER_SELF }

# =====================================================================
#  Shared helpers
# =====================================================================
function Test-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CleanLabel([string]$text) {
    $t = ($text -replace '[^A-Za-z0-9_-]', '').ToUpper()
    if (-not $t) { $t = "WINSERVER" }
    if ($t.Length -gt 11) { $t = $t.Substring(0, 11) }
    return $t
}

# PowerShell command that re-runs this same file with the given arguments
function Get-SelfCommand([string]$Arguments) {
    $p = $script:SelfPath -replace "'", "''"
    return "& ([ScriptBlock]::Create([IO.File]::ReadAllText('$p'))) $Arguments"
}

# Windows ISOs start with an empty system area; Linux "hybrid" ISOs carry an
# MBR boot signature (55 AA) in their first sector so they boot when written raw.
function Get-ImageKind([string]$path) {
    if ([IO.Path]::GetExtension($path) -ieq '.img') { return 'Raw' }
    try {
        $b = New-Object byte[] 512
        $fs = [IO.File]::OpenRead($path)
        try { [void]$fs.Read($b, 0, 512) } finally { $fs.Dispose() }
        if ($b[510] -eq 0x55 -and $b[511] -eq 0xAA) { return 'Hybrid' }
    } catch { }
    return 'Windows'
}

function Read-Full($stream, [byte[]]$buffer, [int]$count) {
    $total = 0
    while ($total -lt $count) {
        $r = $stream.Read($buffer, $total, $count - $total)
        if ($r -le 0) { break }
        $total += $r
    }
    return $total
}

function Get-Padded([int]$n, [int]$align) {
    return [int]([math]::Ceiling($n / $align) * $align)
}

# Writes an image raw to $Target. The first 4 MB (partition table) is written
# LAST, so Windows sees an empty disk - and mounts nothing - while we write.
function Write-RawImage([string]$ImagePath, [IO.Stream]$Target, [int]$Align = 4096) {
    $chunk = 4MB
    $buf = New-Object byte[] $chunk
    $src = [IO.File]::OpenRead($ImagePath)
    try {
        $total = $src.Length

        # 1) blank the start of the disk
        $Target.Position = 0
        $Target.Write($buf, 0, $chunk)

        # 2) everything after the first chunk
        $src.Position = [math]::Min([long]$chunk, $total)
        $Target.Position = $chunk
        $written = [long][math]::Min([long]$chunk, $total)
        $lastPct = -1
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $n = Read-Full $src $buf $chunk
            if ($n -le 0) { break }
            $len = Get-Padded $n $Align
            if ($len -gt $n) { [Array]::Clear($buf, $n, $len - $n) }
            $Target.Write($buf, 0, $len)
            $written += $n
            $pct = [int][math]::Floor(100 * $written / $total)
            if ($pct -ne $lastPct) {
                $secs = [math]::Max($sw.Elapsed.TotalSeconds, 0.1)
                $status = "{0:N0} / {1:N0} MB   ({2:N1} MB/s)" -f ($written / 1MB), ($total / 1MB), ($written / 1MB / $secs)
                Write-Progress -Activity "Writing image to USB" -Status $status -PercentComplete ([math]::Min(100, $pct))
                $lastPct = $pct
            }
        }

        # 3) the first chunk (MBR / GPT) last
        [Array]::Clear($buf, 0, $chunk)
        $src.Position = 0
        $n = Read-Full $src $buf $chunk
        $len = Get-Padded $n $Align
        $Target.Position = 0
        $Target.Write($buf, 0, $len)
        if ($Target -is [IO.FileStream]) { $Target.Flush($true) } else { $Target.Flush() }
        Write-Progress -Activity "Writing image to USB" -Completed
    }
    finally {
        $src.Dispose()
    }
}

# =====================================================================
#  WORKER (runs as Administrator)
# =====================================================================
if ($Worker) {
    $ErrorActionPreference = "Stop"
    $Host.UI.RawUI.WindowTitle = "USB Boot Maker"
    function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

    function Invoke-DiskPart([string[]]$Commands) {
        $f = Join-Path $env:TEMP "usbmaker_diskpart.txt"
        $Commands | Set-Content -Path $f -Encoding ASCII
        diskpart /s "$f" | Out-Host
        $code = $LASTEXITCODE
        Remove-Item $f -ErrorAction SilentlyContinue
        if ($code -ne 0) { throw "DiskPart failed (exit code $code)." }
    }

    $Label = Get-CleanLabel $Label
    $mountedHere = $false
    $ok = $false
    $usb = $null
    $raw = $null

    try {
        if (-not (Test-Admin)) { throw "Administrator rights are required." }
        if (-not (Test-Path -LiteralPath $IsoPath)) { throw "Image not found: $IsoPath" }

        # --- Safety checks on the target disk ---
        $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
        if (-not $disk) { throw "Disk $DiskNumber not found." }
        if ($disk.IsSystem -or $disk.IsBoot) { throw "Disk $DiskNumber is a system/boot disk. Aborted." }
        if ($disk.BusType -ne "USB") { throw "Disk $DiskNumber is not a USB disk (BusType=$($disk.BusType)). Aborted." }
        if ($DiskSize -gt 0 -and [math]::Abs($disk.Size - $DiskSize) -gt ($DiskSize * 0.1)) {
            throw "Disk $DiskNumber is not the drive that was selected (was the USB unplugged?). Aborted."
        }

        $imgBytes = (Get-Item -LiteralPath $IsoPath).Length
        Write-Host "Target : Disk $DiskNumber - $($disk.FriendlyName) - $([math]::Round($disk.Size/1GB,1)) GB"
        Write-Host "Image  : $IsoPath ($([math]::Round($imgBytes/1GB,2)) GB)"

        if ($Mode -eq "DD") {
            # ================= DD mode (Linux / raw images) =================
            Write-Host "Mode   : DD - raw image write"
            if ($disk.Size -lt $imgBytes) { throw "The USB is too small for this image." }

            Step "Wiping Disk $DiskNumber..."
            Invoke-DiskPart @("select disk $DiskNumber", "clean")
            Start-Sleep -Seconds 2

            if (-not ("RawDisk" -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class RawDisk
{
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFile(string fileName, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);

    public static FileStream Open(int diskNumber)
    {
        // GENERIC_READ|GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE,
        // OPEN_EXISTING, FILE_FLAG_WRITE_THROUGH
        SafeFileHandle h = CreateFile(@"\\.\PhysicalDrive" + diskNumber,
            0xC0000000, 3, IntPtr.Zero, 3, 0x80000000, IntPtr.Zero);
        if (h.IsInvalid)
            throw new IOException("Cannot open PhysicalDrive" + diskNumber +
                " (Win32 error " + Marshal.GetLastWin32Error() + ")");
        return new FileStream(h, FileAccess.ReadWrite, 1);
    }
}
'@
            }

            Step "Writing the image (this takes several minutes)..."
            $raw = [RawDisk]::Open($DiskNumber)
            $align = [math]::Max(4096, [int]$disk.LogicalSectorSize)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Write-RawImage -ImagePath $IsoPath -Target $raw -Align $align
            $raw.Dispose()
            $raw = $null
            Write-Host ("Written {0:N0} MB in {1:hh\:mm\:ss}" -f ($imgBytes / 1MB), $sw.Elapsed)

            Update-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
            $ok = $true
        }
        else {
            # ================= Windows mode =================
            Write-Host "Mode   : Windows - $PartitionScheme / $FileSystem (label $Label)"
            $isGpt = ($PartitionScheme -eq "GPT")
            if ($isGpt -and $FileSystem -eq "NTFS") {
                throw "GPT needs FAT32: UEFI firmware can't boot from NTFS. Choose FAT32, or MBR for NTFS."
            }

            $partSizeArg = ""
            $partBytes = $disk.Size
            if ($FileSystem -eq "FAT32" -and $disk.Size -gt 32GB) {
                $partSizeArg = " size=32000"   # Windows can't format FAT32 larger than 32 GB
                $partBytes = 32000MB
            }
            if ($partBytes -lt $imgBytes * 1.05) { throw "The USB is too small for this ISO." }

            # --- 1) Mount and check the ISO BEFORE touching the USB ---
            Step "Mounting the ISO..."
            if (-not (Get-DiskImage -ImagePath $IsoPath).Attached) {
                Mount-DiskImage -ImagePath $IsoPath | Out-Null
                $mountedHere = $true
            }
            $src = $null
            for ($i = 0; $i -lt 15 -and -not $src; $i++) {
                $l = (Get-DiskImage -ImagePath $IsoPath | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
                if ("$l" -match '^[A-Z]$') { $src = "${l}:" } else { Start-Sleep -Seconds 1 }
            }
            if (-not $src) { throw "Could not get a drive letter for the mounted ISO." }
            if (-not (Test-Path "$src\sources") -or -not (Test-Path "$src\boot\bootsect.exe")) {
                throw "This ISO doesn't look like a Windows installation ISO. For Linux images use DD mode."
            }
            Write-Host "ISO mounted as $src"

            # --- 2) Wipe + partition (MBR or GPT) + format ---
            Step "Wiping Disk $DiskNumber and formatting it as $PartitionScheme / $FileSystem..."
            try {
                Invoke-DiskPart @(
                    "select disk $DiskNumber"
                    "clean"
                    "convert $($PartitionScheme.ToLower())"
                    "create partition primary$partSizeArg"
                    "format fs=$($FileSystem.ToLower()) quick label=$Label"
                    "assign"
                )
            } catch {
                if ($isGpt) { throw "$($_.Exception.Message) This USB may not accept GPT - try MBR instead." }
                throw
            }

            for ($i = 0; $i -lt 15 -and -not $usb; $i++) {
                Start-Sleep -Seconds 1
                $l = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                     Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } |
                     Select-Object -First 1 -ExpandProperty DriveLetter
                if ("$l" -match '^[A-Z]$') { $usb = "${l}:" }
            }
            if (-not $usb) { throw "Could not get a drive letter for the USB." }
            Write-Host "USB formatted as $usb"

            if (-not $isGpt) {
                try { Set-Partition -DriveLetter $usb[0] -IsActive $true -ErrorAction Stop }
                catch { Write-Host "Note: could not mark the partition active (only matters for Legacy BIOS)." -ForegroundColor Yellow }
            }

            # --- 3) Copy files ---
            $wim = Get-Item "$src\sources\install.wim" -ErrorAction SilentlyContinue
            $split = ($FileSystem -eq "FAT32") -and $wim -and ($wim.Length -ge 4GB)

            Step "Copying files to $usb (this takes several minutes)..."
            if ($split) {
                robocopy "$src\" "$usb\" /E /R:1 /W:1 /NDL /NJH /XF install.wim
            } else {
                robocopy "$src\" "$usb\" /E /R:1 /W:1 /NDL /NJH
            }
            if ($LASTEXITCODE -ge 8) { throw "Copy failed (robocopy code $LASTEXITCODE)." }

            # --- 4) FAT32 only: split install.wim into parts under 4 GB ---
            if ($split) {
                Step "Splitting install.wim (FAT32 can't hold files over 4 GB)..."
                dism /Split-Image /ImageFile:"$src\sources\install.wim" /SWMFile:"$usb\sources\install.swm" /FileSize:3800
                if ($LASTEXITCODE -ne 0) { throw "DISM split failed (code $LASTEXITCODE)." }
            }

            # --- 5) Boot code for Legacy BIOS (MBR only - GPT boots through UEFI's \EFI\BOOT) ---
            if (-not $isGpt) {
                Step "Writing boot code..."
                & "$src\boot\bootsect.exe" /nt60 $usb /mbr /force
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "bootsect returned code $LASTEXITCODE (only matters for Legacy BIOS)." -ForegroundColor Yellow
                }
            }
            if (-not (Test-Path "$usb\efi\boot\bootx64.efi")) {
                $note = "Note: this ISO has no UEFI boot file (efi\boot\bootx64.efi): it will only boot in Legacy BIOS."
                if ($isGpt) { $note += " Use MBR for this ISO." }
                Write-Host $note -ForegroundColor Yellow
            }

            $ok = $true
        }
    }
    catch {
        Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
        if ($Mode -eq "DD" -and $_.Exception.Message -match 'denied') {
            Write-Host "Windows blocked writing to the USB. Close any Explorer windows showing it," -ForegroundColor Yellow
            Write-Host "unplug and re-plug the USB, then try again." -ForegroundColor Yellow
        }
    }
    finally {
        if ($raw) { $raw.Dispose() }
        if ($mountedHere) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null }
    }

    if ($ok) {
        if ($Mode -eq "DD") {
            Write-Host "`nDONE! The image was written to the USB." -ForegroundColor Green
            Write-Host "If Windows pops up 'You need to format the disk' - click CANCEL (do NOT format)." -ForegroundColor Yellow
            Write-Host "It's normal that Windows can't open the USB now: it holds Linux partitions."
        } else {
            Write-Host "`nDONE! The USB ($usb) is ready." -ForegroundColor Green
            if ($PartitionScheme -eq "GPT") {
                Write-Host "GPT: boots in UEFI mode only. In the BIOS boot menu pick the 'UEFI: ...' entry for the USB."
            } elseif ($FileSystem -eq "FAT32") {
                Write-Host "Boots in UEFI mode (and Legacy BIOS on most machines)."
            } else {
                Write-Host "Boots in Legacy BIOS / CSM mode. UEFI-only servers may not see it - use FAT32 instead." -ForegroundColor Yellow
            }
        }
    }
    Read-Host "`nPress Enter to close"
    exit
}

# =====================================================================
#  GUI (no admin, so drag & drop from Explorer works)
# =====================================================================
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $cmd = Get-SelfCommand ""
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command `"$cmd`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

# The window runs hidden from a console, so show unexpected errors in a message box
trap {
    [void][Windows.Forms.MessageBox]::Show("Unexpected error:`n`n$($_.Exception.Message)", "USB Boot Maker",
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
    break
}

$script:isoPath   = $null
$script:imageKind = $null
$script:disks     = @()

function Get-UsbDisks {
    try {
        $all = Get-Disk -ErrorAction Stop
        return @($all | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsSystem -and -not $_.IsBoot } | ForEach-Object {
            $d = $_
            $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
                Where-Object { "$($_.DriveLetter)" -match '^[A-Z]$' } |
                ForEach-Object { "$($_.DriveLetter):" }) -join ' '
            [pscustomobject]@{ Number = [int]$d.Number; Name = $d.FriendlyName; Size = [long]$d.Size; Letters = $letters }
        })
    } catch {
        # Fallback if Get-Disk needs admin rights on this PC
        return @(Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'USB' } | ForEach-Object {
            [pscustomobject]@{ Number = [int]$_.Index; Name = $_.Model; Size = [long]$_.Size; Letters = '' }
        })
    }
}

function Show-Msg($text, $icon = "Information") {
    [void][Windows.Forms.MessageBox]::Show($text, "USB Boot Maker",
        [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]$icon)
}

function Ask-YesNo($text, $title) {
    $r = [Windows.Forms.MessageBox]::Show($text, $title,
        [Windows.Forms.MessageBoxButtons]::YesNo,
        [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2)
    return ($r -eq [Windows.Forms.DialogResult]::Yes)
}

# ---------- Form ----------
$regular = New-Object Drawing.Font("Segoe UI", 9.5)
$bold    = New-Object Drawing.Font("Segoe UI", 10, [Drawing.FontStyle]::Bold)

$form = New-Object Windows.Forms.Form
$form.Text = "USB Boot Maker  -  Windows & Linux"
$form.ClientSize = New-Object Drawing.Size(520, 612)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = $regular

function New-Label($text, $x, $y, $font = $null, $color = $null, $parent = $null) {
    $l = New-Object Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object Drawing.Point($x, $y)
    $l.AutoSize = $true
    $l.UseMnemonic = $false
    if ($font)  { $l.Font = $font }
    if ($color) { $l.ForeColor = $color }
    if ($parent) { $parent.Controls.Add($l) } else { $form.Controls.Add($l) }
    return $l
}

# 1) Image file
[void](New-Label "1) Image file  (ISO / IMG)" 15 12 $bold)

$dropPanel = New-Object Windows.Forms.Panel
$dropPanel.Location = New-Object Drawing.Point(15, 38)
$dropPanel.Size = New-Object Drawing.Size(490, 95)
$dropPanel.BorderStyle = "FixedSingle"
$dropPanel.BackColor = [Drawing.Color]::FromArgb(240, 246, 255)

$dropText = New-Object Windows.Forms.Label
$dropText.Dock = "Fill"
$dropText.TextAlign = "MiddleCenter"
$dropText.UseMnemonic = $false
$dropText.ForeColor = [Drawing.Color]::FromArgb(40, 70, 120)
$dropText.Text = "Drag & drop an ISO or IMG file here"
if (Test-Admin) {
    $dropText.Text += "`n`n(Running as Administrator: Windows blocks drag & drop - use Browse)"
}
$dropPanel.Controls.Add($dropText)
$form.Controls.Add($dropPanel)

$btnBrowse = New-Object Windows.Forms.Button
$btnBrowse.Text = "Browse..."
$btnBrowse.Location = New-Object Drawing.Point(405, 139)
$btnBrowse.Size = New-Object Drawing.Size(100, 28)
$form.Controls.Add($btnBrowse)

$lblKind = New-Label "" 15 144 $null ([Drawing.Color]::DimGray)

# 2) USB drive
[void](New-Label "2) USB drive" 15 180 $bold)
[void](New-Label "(everything on it will be erased)" 125 182 $null ([Drawing.Color]::Firebrick))

$combo = New-Object Windows.Forms.ComboBox
$combo.DropDownStyle = "DropDownList"
$combo.Location = New-Object Drawing.Point(15, 206)
$combo.Size = New-Object Drawing.Size(380, 28)
$form.Controls.Add($combo)

$btnRefresh = New-Object Windows.Forms.Button
$btnRefresh.Text = "Refresh"
$btnRefresh.Location = New-Object Drawing.Point(405, 205)
$btnRefresh.Size = New-Object Drawing.Size(100, 28)
$form.Controls.Add($btnRefresh)

# 3) Write mode
$grpMode = New-Object Windows.Forms.GroupBox
$grpMode.Text = "3) Write mode"
$grpMode.Font = $bold
$grpMode.Location = New-Object Drawing.Point(15, 250)
$grpMode.Size = New-Object Drawing.Size(490, 82)
$form.Controls.Add($grpMode)

$rbModeWin = New-Object Windows.Forms.RadioButton
$rbModeWin.Text = "Windows installer  -  format + copy files"
$rbModeWin.Font = $regular
$rbModeWin.Location = New-Object Drawing.Point(15, 24)
$rbModeWin.AutoSize = $true
$rbModeWin.Checked = $true
$grpMode.Controls.Add($rbModeWin)

$rbModeDD = New-Object Windows.Forms.RadioButton
$rbModeDD.Text = "Linux / other images  -  DD raw write (like Rufus DD / Etcher)"
$rbModeDD.Font = $regular
$rbModeDD.Location = New-Object Drawing.Point(15, 50)
$rbModeDD.AutoSize = $true
$grpMode.Controls.Add($rbModeDD)

# 4) Windows options
$grpWin = New-Object Windows.Forms.GroupBox
$grpWin.Text = "4) Windows options"
$grpWin.Font = $bold
$grpWin.Location = New-Object Drawing.Point(15, 342)
$grpWin.Size = New-Object Drawing.Size(490, 174)
$form.Controls.Add($grpWin)

# Each pair of radio buttons sits in its own panel so the two choices are independent
function New-RadioPair($parent, $y, $caption, $textA, $textB) {
    [void](New-Label $caption 15 $y $regular ([Drawing.Color]::DimGray) $parent)
    $p = New-Object Windows.Forms.Panel
    $p.Location = New-Object Drawing.Point(130, ($y - 4))
    $p.Size = New-Object Drawing.Size(350, 52)
    $parent.Controls.Add($p)
    $a = New-Object Windows.Forms.RadioButton
    $a.Text = $textA; $a.Font = $regular; $a.AutoSize = $true; $a.Checked = $true
    $a.Location = New-Object Drawing.Point(0, 2)
    $b = New-Object Windows.Forms.RadioButton
    $b.Text = $textB; $b.Font = $regular; $b.AutoSize = $true
    $b.Location = New-Object Drawing.Point(0, 27)
    $p.Controls.Add($a); $p.Controls.Add($b)
    return @($a, $b)
}

$rbMbr, $rbGpt = New-RadioPair $grpWin 26 "Partition scheme:" `
    "MBR  -  BIOS (Legacy) + UEFI  (recommended)" `
    "GPT  -  UEFI only  (FAT32)"

$rbFat, $rbNtfs = New-RadioPair $grpWin 84 "File system:" `
    "FAT32  -  UEFI + Legacy BIOS  (recommended)" `
    "NTFS   -  Legacy BIOS / CSM only  (MBR)"

[void](New-Label "Volume label:" 15 142 $regular ([Drawing.Color]::DimGray) $grpWin)
$txtLabel = New-Object Windows.Forms.TextBox
$txtLabel.Font = $regular
$txtLabel.Location = New-Object Drawing.Point(130, 139)
$txtLabel.Size = New-Object Drawing.Size(150, 26)
$txtLabel.MaxLength = 11
$txtLabel.CharacterCasing = "Upper"
$txtLabel.Text = "WINSERVER"
$grpWin.Controls.Add($txtLabel)

# Start
$btnStart = New-Object Windows.Forms.Button
$btnStart.Text = "START  (erase USB and write image)"
$btnStart.Font = $bold
$btnStart.Location = New-Object Drawing.Point(15, 528)
$btnStart.Size = New-Object Drawing.Size(490, 45)
$form.Controls.Add($btnStart)

$status = New-Label "" 15 584 $null ([Drawing.Color]::DimGray)

# ---------- Logic ----------
function Set-Iso([string]$path) {
    $script:isoPath = $path
    $script:imageKind = Get-ImageKind $path
    $gb = (Get-Item -LiteralPath $path).Length / 1GB
    $dropText.Text = "{0}`n{1:N2} GB`n`n(drop another file to change it)" -f [IO.Path]::GetFileName($path), $gb
    $dropText.ForeColor = [Drawing.Color]::DarkGreen
    $dropPanel.BackColor = [Drawing.Color]::FromArgb(232, 245, 233)
    switch ($script:imageKind) {
        'Windows' {
            $lblKind.Text = "Detected: Windows ISO  ->  Windows mode"
            $rbModeWin.Enabled = $true
            $rbModeWin.Checked = $true
        }
        'Hybrid' {
            $lblKind.Text = "Detected: Linux / hybrid ISO  ->  DD mode"
            $rbModeWin.Enabled = $true
            $rbModeDD.Checked = $true
        }
        default {
            $lblKind.Text = "Detected: raw disk image (.img)  ->  DD mode"
            $rbModeDD.Checked = $true
            $rbModeWin.Enabled = $false
        }
    }
}

function Update-UsbList {
    $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    $combo.Items.Clear()
    $script:disks = @(Get-UsbDisks)
    foreach ($d in $script:disks) {
        $txt = "Disk {0}  -  {1}  -  {2:N1} GB" -f $d.Number, $d.Name, ($d.Size / 1GB)
        if ($d.Letters) { $txt += "  [$($d.Letters)]" }
        [void]$combo.Items.Add($txt)
    }
    if ($combo.Items.Count -gt 0) {
        $combo.SelectedIndex = 0
        $status.Text = "$($combo.Items.Count) USB drive(s) found."
    } else {
        $status.Text = "No USB drive found. Plug one in and click Refresh."
    }
    $form.Cursor = [Windows.Forms.Cursors]::Default
}

$onDragEnter = {
    param($s, $e)
    $okDrop = $false
    if ($e.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $files = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
        if ($files.Count -eq 1 -and $files[0] -match '\.(iso|img)$') { $okDrop = $true }
    }
    if ($okDrop) { $e.Effect = [Windows.Forms.DragDropEffects]::Copy }
    else         { $e.Effect = [Windows.Forms.DragDropEffects]::None }
}
$onDragDrop = {
    param($s, $e)
    $files = $e.Data.GetData([Windows.Forms.DataFormats]::FileDrop)
    if ($files -and $files[0] -match '\.(iso|img)$') { Set-Iso $files[0] }
}
foreach ($c in @($form, $dropPanel, $dropText)) {
    $c.AllowDrop = $true
    $c.Add_DragEnter($onDragEnter)
    $c.Add_DragDrop($onDragDrop)
}

$rbModeWin.Add_CheckedChanged({ $grpWin.Enabled = $rbModeWin.Checked })

# GPT means UEFI, and UEFI firmware boots from FAT32 only
$rbGpt.Add_CheckedChanged({
    if ($rbGpt.Checked) { $rbFat.Checked = $true }
    $rbNtfs.Enabled = -not $rbGpt.Checked
})

$btnBrowse.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "Disk images (*.iso;*.img)|*.iso;*.img"
    $dlg.Title = "Choose an ISO or IMG file"
    $dl = Join-Path $env:USERPROFILE "Downloads"
    if (Test-Path $dl) { $dlg.InitialDirectory = $dl }
    if ($dlg.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { Set-Iso $dlg.FileName }
})

$btnRefresh.Add_Click({ Update-UsbList })

$btnStart.Add_Click({
    if (-not $script:isoPath -or -not (Test-Path -LiteralPath $script:isoPath)) {
        Show-Msg "Please choose an ISO or IMG file first (drag & drop or Browse)."
        return
    }
    if ($combo.SelectedIndex -lt 0 -or $combo.SelectedIndex -ge $script:disks.Count) {
        Show-Msg "Please choose a USB drive."
        return
    }
    $d        = $script:disks[$combo.SelectedIndex]
    $isDD     = $rbModeDD.Checked
    $imgBytes = (Get-Item -LiteralPath $script:isoPath).Length

    if ($d.Size -lt $imgBytes) {
        Show-Msg "This USB drive is too small for the image." "Error"
        return
    }
    if (-not $isDD -and $script:imageKind -eq 'Raw') {
        Show-Msg "IMG files can only be written in DD mode."
        return
    }
    if ($isDD -and $script:imageKind -eq 'Windows') {
        $warn = "This ISO is not a hybrid image (Windows ISOs aren't).`n" +
                "Written in DD mode it will most likely NOT boot.`n`nContinue anyway?"
        if (-not (Ask-YesNo $warn "Not a hybrid image")) { return }
    }

    $fs       = if ($rbNtfs.Checked) { "NTFS" } else { "FAT32" }
    $scheme   = if ($rbGpt.Checked) { "GPT" } else { "MBR" }
    $label    = Get-CleanLabel $txtLabel.Text
    $modeArg  = if ($isDD) { "DD" } else { "Windows" }
    $modeText = if ($isDD) { "DD - raw image write" } else { "Windows - $scheme, $fs, label $label" }

    $msg = "ALL DATA on this USB drive will be ERASED:`n`n" +
           ("Disk {0}  -  {1}  -  {2:N1} GB`n`n" -f $d.Number, $d.Name, ($d.Size / 1GB)) +
           "Mode : $modeText`n" +
           ("Image : {0}  ({1:N2} GB)`n`n" -f [IO.Path]::GetFileName($script:isoPath), ($imgBytes / 1GB)) +
           "Continue?"
    if (-not (Ask-YesNo $msg "Confirm - erase USB")) { return }

    $isoArg     = $script:isoPath -replace "'", "''"
    $workerArgs = "-Worker -IsoPath '$isoArg' -DiskNumber $($d.Number) -Mode $modeArg " +
                  "-FileSystem $fs -PartitionScheme $scheme -Label '$label' -DiskSize $($d.Size)"
    $argList    = "-NoProfile -ExecutionPolicy Bypass -Command `"$(Get-SelfCommand $workerArgs)`""
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        $form.Close()
    } catch {
        Show-Msg "Administrator rights are needed to write the USB (the UAC prompt was cancelled)." "Error"
    }
})

$form.Add_Shown({
    Update-UsbList
    if ($IsoPath -and (Test-Path -LiteralPath $IsoPath)) { Set-Iso (Resolve-Path -LiteralPath $IsoPath).Path }
    $grpWin.Enabled = $rbModeWin.Checked
    $form.Activate()
})

[void]$form.ShowDialog()
