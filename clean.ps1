<#
    Laptop Cleaner — Windows one-click disk cleanup
    =================================================
    A single-button GUI tool that safely reclaims disk space on Windows
    by removing regenerable caches and temporary files.

    Designed for heavily loaded work laptops where C: fills up constantly
    (Docker, WSL, package managers, browsers, Office suites).

    Safety model:
      * Never touches user documents, projects, or profile data.
      * Browser Bookmarks / Login Data / History are never removed -
        only cache directories.
      * Recycle Bin and pagefile relocation are opt-in.
      * Locked files are skipped silently instead of forcing or failing.
      * All paths are resolved dynamically (env vars may be empty on
        some corporate machines).

    Requirements: Windows 10/11, PowerShell 5.1+ (bundled with Windows).
    Run: double-click Clean-Laptop.bat (auto-elevates via UAC).
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==================== Resolve real user paths ====================
# We do NOT trust %LOCALAPPDATA% / %APPDATA% - they can be empty in some
# sessions - and we do NOT trust %USERNAME% because the profile folder
# name may differ. Order: env var -> .NET folder path -> Registry.
function Resolve-UserPaths {
    $prof = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($prof)) { $prof = [Environment]::GetFolderPath('UserProfile') }
    if ([string]::IsNullOrWhiteSpace($prof)) {
        try { $prof = (Get-ItemProperty 'HKCU:\Volatile Environment' -Name USERPROFILE).USERPROFILE } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($prof)) { $prof = "C:\Users\$env:USERNAME" }

    $local = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($local)) {
        try { $local = (Get-ItemProperty 'HKCU:\Volatile Environment' -Name LOCALAPPDATA).LOCALAPPDATA } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($local)) { $local = Join-Path $prof 'AppData\Local' }

    $roam = $env:APPDATA
    if ([string]::IsNullOrWhiteSpace($roam)) {
        try { $roam = (Get-ItemProperty 'HKCU:\Volatile Environment' -Name APPDATA).APPDATA } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($roam)) { $roam = Join-Path $prof 'AppData\Roaming' }

    return @{ Profile = $prof; Local = $local; Roaming = $roam }
}

$UP      = Resolve-UserPaths
$PROFILE = $UP.Profile
$LOCAL   = $UP.Local
$ROAM    = $UP.Roaming

foreach ($chk in @($PROFILE, $LOCAL, $ROAM)) {
    if ([string]::IsNullOrWhiteSpace($chk) -or $chk -notmatch '^[A-Za-z]:\\') {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not resolve the user profile path.`n`nInvalid path: '$chk'`n`nNothing was deleted.",
            'Laptop Cleaner', 'OK', 'Error') | Out-Null
        exit 1
    }
}

function Get-DesktopPath {
    $d = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) {
        $d = Join-Path $PROFILE 'Desktop'
    }
    return $d
}

# ==================== Helpers ====================
$script:FreeStart = 0.0
$script:Freed     = 0.0
$script:Cancel    = $false

function Get-FreeGB {
    try { return [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2) }
    catch { return 0 }
}
function Get-DirMB([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return 0.0 }
    try {
        return [math]::Round((Get-ChildItem -LiteralPath $dir -Recurse -Force -File -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum / 1MB, 1)
    } catch { return 0.0 }
}
function Get-ProcRunning([string[]]$names) {
    try { return (Get-Process -Name $names -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0 }
    catch { return $false }
}

# ==================== Window ====================
$form                   = New-Object System.Windows.Forms.Form
$form.Text              = 'Laptop Cleaner'
$form.Size              = New-Object System.Drawing.Size(620, 640)
$form.StartPosition     = 'CenterScreen'
$form.BackColor         = [System.Drawing.Color]::FromArgb(250, 250, 252)
$form.Font              = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle   = 'FixedDialog'
$form.MaximizeBox       = $false

$title           = New-Object System.Windows.Forms.Label
$title.Text      = 'Laptop Cleaner'
$title.Font      = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(20, 30, 60)
$title.Location  = New-Object System.Drawing.Point(20, 14)
$title.Size      = New-Object System.Drawing.Size(560, 42)
$form.Controls.Add($title)

$lblFree           = New-Object System.Windows.Forms.Label
$lblFree.Text      = "C: free space  -  $((Get-FreeGB)) GB"
$lblFree.Font      = New-Object System.Drawing.Font('Segoe UI', 12)
$lblFree.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$lblFree.Location  = New-Object System.Drawing.Point(20, 58)
$lblFree.Size      = New-Object System.Drawing.Size(560, 28)
$form.Controls.Add($lblFree)

$lblInfo           = New-Object System.Windows.Forms.Label
$lblInfo.Text      = "Cleans: temp files, browser caches, app caches, installer leftovers, dev tool caches.`nNever touches: your documents, bookmarks, saved passwords, or settings."
$lblInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$lblInfo.Location  = New-Object System.Drawing.Point(20, 88)
$lblInfo.Size      = New-Object System.Drawing.Size(560, 40)
$form.Controls.Add($lblInfo)

$chkBin           = New-Object System.Windows.Forms.CheckBox
$chkBin.Text      = 'Also empty the Recycle Bin'
$chkBin.Location  = New-Object System.Drawing.Point(20, 132)
$chkBin.Size      = New-Object System.Drawing.Size(560, 24)
$chkBin.Checked   = $false
$chkBin.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkBin)

$chkPage           = New-Object System.Windows.Forms.CheckBox
$chkPage.Text      = 'Move pagefile from C: to D:  (frees ~8 GB, needs a restart)'
$chkPage.Location  = New-Object System.Drawing.Point(20, 158)
$chkPage.Size      = New-Object System.Drawing.Size(560, 24)
$chkPage.Checked   = $false
$chkPage.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkPage)

$bar           = New-Object System.Windows.Forms.ProgressBar
$bar.Location  = New-Object System.Drawing.Point(20, 192)
$bar.Size      = New-Object System.Drawing.Size(560, 22)
$bar.Style     = 'Continuous'
$bar.Maximum   = 100
$form.Controls.Add($bar)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Ready. Press the button to start.'
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
$lblStatus.Location  = New-Object System.Drawing.Point(20, 218)
$lblStatus.Size      = New-Object System.Drawing.Size(560, 24)
$form.Controls.Add($lblStatus)

$log            = New-Object System.Windows.Forms.TextBox
$log.Location   = New-Object System.Drawing.Point(20, 246)
$log.Size       = New-Object System.Drawing.Size(560, 280)
$log.Multiline  = $true
$log.ReadOnly   = $true
$log.ScrollBars = 'Vertical'
$log.Font       = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor  = [System.Drawing.Color]::White
$form.Controls.Add($log)

$btnStart           = New-Object System.Windows.Forms.Button
$btnStart.Text      = 'Clean now'
$btnStart.Location  = New-Object System.Drawing.Point(20, 538)
$btnStart.Size      = New-Object System.Drawing.Size(360, 52)
$btnStart.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$form.Controls.Add($btnStart)

$btnClose           = New-Object System.Windows.Forms.Button
$btnClose.Text      = 'Close'
$btnClose.Location  = New-Object System.Drawing.Point(400, 538)
$btnClose.Size      = New-Object System.Drawing.Size(180, 52)
$btnClose.Font      = New-Object System.Drawing.Font('Segoe UI', 11)
$btnClose.FlatStyle = 'Flat'
$form.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })

function Log([string]$t) {
    $log.AppendText("$t`r`n")
    $log.SelectionStart = $log.Text.Length
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}
function SetStatus([string]$t, [int]$pct) {
    $lblStatus.Text = $t
    if ($pct -ge 0) { $bar.Value = [math]::Min($pct, 100) }
    [System.Windows.Forms.Application]::DoEvents()
}

# ==================== Cleanup primitives ====================
# Remove a folder's CONTENTS, keep the folder, skip locked items.
function Clean-Dir([string]$dir, [string]$label) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0.0 }
    $before = Get-DirMB $dir
    if ($before -le 0) { return 0.0 }
    foreach ($i in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    $freed = [math]::Round($before - (Get-DirMB $dir), 1)
    if ($freed -gt 0) { Log "   + $label  ->  $freed MB" } else { Log "   - $label (locked)" }
    return $freed
}
# Remove an entire folder tree.
function Drop-Dir([string]$dir, [string]$label) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0.0 }
    $mb = Get-DirMB $dir
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (-not (Test-Path -LiteralPath $dir)) { Log "   + $label  ->  $mb MB" ; return $mb }
    Log "   - $label (locked)"; return 0.0
}

# ==================== Main action ====================
$btnStart.Add_Click({
    $btnStart.Enabled = $false
    $chkBin.Enabled   = $false
    $chkPage.Enabled  = $false
    $script:Freed     = 0.0
    $script:FreeStart = Get-FreeGB
    $t0 = Get-Date

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Log '========================================'
    Log "Started - $(Get-Date -Format 'HH:mm:ss')"
    Log "Free before: $script:FreeStart GB"
    Log '========================================'

    $steps = @(
        @{ N = 'Temporary files'; F = {
            $script:Freed += Clean-Dir 'C:\Windows\Temp'                            'Windows Temp'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Temp')                    'User Temp'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'CrashDumps')              'Crash dumps'
            $script:Freed += Clean-Dir 'C:\ProgramData\Microsoft\Windows\WER'       'Windows Error Reporting'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WER')   'User Error Reporting'
            $script:Freed += Clean-Dir 'C:\Windows\Logs\CBS'                        'CBS logs'
            $script:Freed += Clean-Dir 'C:\Windows\SoftwareDistribution\Download'   'Windows Update cache'
            $script:Freed += Clean-Dir 'C:\Windows\LiveKernelReports'               'Kernel reports'
        } }
        @{ N = 'Browser caches'; F = {
            $names = @('Cache','Code Cache','GPUCache','GrShaderCache','ShaderCache','Crashpad',
                       'DawnCache','DawnGraphicCache','DawnWebGPUCache','CacheStorage','Media Cache')
            $roots = @(
                (Join-Path $LOCAL 'Microsoft\Edge\User Data'),
                (Join-Path $LOCAL 'Google\Chrome\User Data'),
                (Join-Path $LOCAL 'BraveSoftware\Brave-Browser\User Data'),
                (Join-Path $LOCAL 'Chromium\User Data')
            )
            $sum = 0.0 ; $hit = 0
            foreach ($r in $roots) {
                if (-not (Test-Path -LiteralPath $r)) { continue }
                foreach ($d in (Get-ChildItem -LiteralPath $r -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                                Where-Object { $names -contains $_.Name })) {
                    $sum += (Clean-Dir $d.FullName "$($d.Name) [$($d.Parent.Name)]")
                    $hit++
                }
            }
            if ($hit -eq 0) { Log '   - no browser caches found' }
            else { Log "   = browser caches total: $([math]::Round($sum,0)) MB" }
            $script:Freed += $sum
        } }
        @{ N = 'Application caches'; F = {
            $apps = @(
                @{P=(Join-Path $ROAM 'Slack\Service Worker'); L='Slack Service Worker'}
                @{P=(Join-Path $ROAM 'Slack\Cache');          L='Slack Cache'}
                @{P=(Join-Path $ROAM 'Slack\Code Cache');     L='Slack Code Cache'}
                @{P=(Join-Path $ROAM 'Slack\logs');           L='Slack logs'}
                @{P=(Join-Path $ROAM 'discord\Cache');        L='Discord Cache'}
                @{P=(Join-Path $ROAM 'discord\Code Cache');   L='Discord Code Cache'}
                @{P=(Join-Path $ROAM 'discord\GPUCache');     L='Discord GPUCache'}
                @{P=(Join-Path $ROAM 'Zoom\logs');            L='Zoom logs'}
                @{P=(Join-Path $ROAM 'Zoom\ZoomDownload');    L='Zoom downloads'}
                @{P=(Join-Path $ROAM 'Notion\Cache');         L='Notion Cache'}
                @{P=(Join-Path $ROAM 'Notion\GPUCache');      L='Notion GPUCache'}
                @{P=(Join-Path $ROAM 'Code\Cache');           L='VS Code Cache'}
                @{P=(Join-Path $ROAM 'Code\CachedData');      L='VS Code CachedData'}
                @{P=(Join-Path $ROAM 'Code\logs');            L='VS Code logs'}
                @{P=(Join-Path $LOCAL 'Postman\logs');        L='Postman logs'}
                @{P=(Join-Path $LOCAL 'Microsoft\Teams\logs'); L='Teams logs'}
                @{P=(Join-Path $ROAM 'Figma\logs');           L='Figma logs'}
            )
            foreach ($a in $apps) { $script:Freed += Clean-Dir $a.P $a.L }
        } }
        @{ N = 'Installer leftovers'; F = {
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'Google\GoogleUpdater\crx_cache')      'Google updater cache'
            $script:Freed += Drop-Dir 'C:\Program Files (x86)\Google\GoogleUpdater\crx_cache' 'Google updater cache (Program Files)'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'kingsoft\office6\updatenew')           'WPS update leftovers'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'wps_download')                         'WPS downloads'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\cache')              'WPS cache'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\log')                'WPS logs'
            $script:Freed += Clean-Dir 'C:\Windows\Prefetch'                                   'Prefetch'
        } }
        @{ N = 'WPS add-on packages'; F = {
            $pool = (Join-Path $ROAM 'kingsoft\wps\addons\pool')
            if (Test-Path -LiteralPath $pool) {
                if (Get-ProcRunning @('wps','wpscloudsvr','et','wpp','ksomisc')) {
                    Log "   ! WPS is running - skipped ($(Get-DirMB $pool) MB). Close WPS and re-run."
                } else {
                    $script:Freed += Drop-Dir $pool 'WPS add-on pool (re-downloaded on demand)'
                }
            } else { Log '   - no WPS add-on pool' }
        } }
        @{ N = 'Thumbnail and internet caches'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Explorer')  'Thumbnail cache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\INetCache') 'INetCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WebCache')  'WebCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Caches')    'Windows caches'
        } }
        @{ N = 'Dev tool caches'; F = {
            if (Get-Command python -ErrorAction SilentlyContinue) {
                $pyCache = Join-Path $LOCAL 'pip'
                $b = Get-DirMB $pyCache
                python -m pip cache purge 2>&1 | Out-Null
                Log "   + pip cache  ->  $b MB" ; $script:Freed += $b
            } else { Log '   - python not found' }
            if (Get-Command npm -ErrorAction SilentlyContinue) {
                $b = Get-DirMB (Join-Path $LOCAL 'npm-cache')
                npm cache clean --force 2>&1 | Out-Null
                Log "   + npm cache  ->  $b MB" ; $script:Freed += $b
            } else { Log '   - npm not found' }
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pnpm-store\v3\files') 'pnpm store'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Yarn\Cache')          'Yarn cache'
        } }
    )

    if ($chkBin.Checked) {
        $steps += @{ N = 'Recycle Bin'; F = {
            $mb = 0.0
            foreach ($d in @('C:','D:')) {
                $rb = "$d\`$Recycle.Bin"
                if (Test-Path -LiteralPath $rb) { $mb += Get-DirMB $rb }
            }
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Log "   + Recycle Bin emptied  ->  $([math]::Round($mb,0)) MB"
            $script:Freed += $mb
        } }
    }

    $steps += @{ N = 'Windows update leftovers'; F = {
        if (Test-Path 'C:\$WinREAgent') {
            $script:Freed += Drop-Dir 'C:\$WinREAgent' 'Windows upgrade leftovers'
        } else { Log '   - no upgrade leftovers' }

        $marker = Join-Path $env:ProgramData 'laptop-cleaner-last-dism.txt'
        $doDism = $true
        if (Test-Path -LiteralPath $marker) {
            try {
                $last = [datetime]::Parse((Get-Content -LiteralPath $marker -Raw).Trim())
                $days = [int]((Get-Date) - $last).TotalDays
                if ($days -lt 60) { $doDism = $false ; Log "   - component store cleaned $days days ago" }
            } catch { }
        }
        if ($doDism) {
            Log '   ... cleaning Windows component store (10-30 min, DISM)'
            SetStatus 'Cleaning Windows component store...' -1
            $fb = Get-FreeGB
            DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1 | Out-Null
            $g = [math]::Round((Get-FreeGB) - $fb, 2)
            Set-Content -LiteralPath $marker -Value (Get-Date).ToString('o') -Encoding UTF8
            Log "   + component store  ->  $g GB"
            $script:Freed += ($g * 1024)
        }

        Log '   ... running Windows Disk Cleanup (cleanmgr)'
        SetStatus 'Running Windows Disk Cleanup...' -1
        $sageset = 65535
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches' -ErrorAction SilentlyContinue |
            ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name "StateFlags$sageset" -Value 2 -Type DWord -ErrorAction SilentlyContinue }
        foreach ($skip in @('Recycle Bin','Downloads','Windows ESD installation files','Previous Installations')) {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$skip" `
                -Name "StateFlags$sageset" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        }
        if (Test-Path "$env:SystemRoot\System32\cleanmgr.exe") {
            Start-Process "$env:SystemRoot\System32\cleanmgr.exe" -ArgumentList "/sagerun:$sageset" -Wait -WindowStyle Hidden
            Log '   + Windows Disk Cleanup finished'
        }
    } }

    if ($chkPage.Checked) {
        $steps += @{ N = 'Pagefile relocation'; F = {
            try {
                $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
                $cs = Get-CimInstance Win32_ComputerSystem
                if ($cs.AutomaticManagedPagefile) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
                }
                $pf = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles
                if (($pf -join ' ') -match 'C:\\pagefile' -and (Test-Path 'D:\')) {
                    Set-ItemProperty -Path $mmKey -Name PagingFiles -Value @('D:\pagefile.sys 8192 16384') -Type MultiString
                    Log '   + pagefile set to D:  -  ~8 GB freed after restart'
                } else {
                    Log '   - pagefile already off C: (or no D: drive)'
                }
            } catch { Log "   ! could not set pagefile: $($_.Exception.Message)" }
        } }
    }

    $i = 0
    foreach ($s in $steps) {
        if ($script:Cancel) { break }
        $i++
        SetStatus $s.N ([int](($i / [math]::Max($steps.Count,1)) * 92))
        Log ''
        Log "> $i/$($steps.Count)  $($s.N)"
        try { & $s.F } catch { Log "   ! error: $($_.Exception.Message)" }
        [System.Windows.Forms.Application]::DoEvents()
    }

    SetStatus 'Cleanup complete' 100
    $freeEnd = Get-FreeGB
    $gained  = [math]::Round($freeEnd - $script:FreeStart, 2)
    $secs    = [int]((Get-Date) - $t0).TotalSeconds

    Log ''
    Log '========================================'
    Log "   Free before :  $script:FreeStart GB"
    Log "   Free after  :  $freeEnd GB"
    Log "   Reclaimed   :  $gained GB"
    Log "   Duration    :  $secs s"
    Log '========================================'

    $lblFree.Text      = "C: free space  -  $freeEnd GB"
    $lblFree.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)

    if ($chkPage.Checked) { Log '' ; Log 'NOTICE: restart Windows to finish the pagefile move.' }

    try {
        $lg = Join-Path (Get-DesktopPath) 'laptop-cleaner-log.txt'
        @(
          "Laptop Cleaner log - $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
          "Free before : $script:FreeStart GB",
          "Free after  : $freeEnd GB",
          "Reclaimed   : $gained GB",
          "Duration    : $secs s"
        ) | Set-Content -LiteralPath $lg -Encoding UTF8
        Log "Saved log: $lg"
    } catch { }

    $form.Cursor      = [System.Windows.Forms.Cursors]::Default
    $btnStart.Enabled = $true
    $chkBin.Enabled   = $true
    $chkPage.Enabled  = $true
    $btnStart.Text    = 'Clean again'
})

$form.Add_FormClosing({ $script:Cancel = $true })

[void]$form.ShowDialog()
