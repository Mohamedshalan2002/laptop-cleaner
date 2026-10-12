<#
    Laptop Cleaner - Windows one-click disk cleanup (English UI)
    =============================================================
    Do not run this file directly.
    Double-click: Clean-Laptop.bat

    Removes only regenerable caches and temporary files.
    Never touches personal files.

    What's new in this version:
      * Root-cause fix for pagefile relocation from C: to D:
        - Detects the ACTUALLY ACTIVE pagefile (not just the registry value)
        - Disables crash-dump writing, which was forcing Windows to
          re-create a temporary pagefile on C: after every restart
        - Verifies every value it writes and offers the restart itself
      * Cleans dead Ollama leftovers (interrupted downloads + orphaned models)
      * Cleans Notion's Service Worker cache - the biggest app cache
      * Removes old WPS versions automatically (keeps only the newest)
      * Cleans downloaded WeChat update packages
      * Cleans pip/npm caches directly without needing Python
      * Two optional extras: wipe Docker disk / wipe Android SDK
      * Shows permission status clearly and skips system steps safely
        when they are unavailable, instead of failing silently
#>

param(
    [switch]$NoGui,                # headless mode (testing / automation)
    [string]$TargetProfile = '',   # passed when relaunching elevated
    [string]$TargetLocal = '',     # so we clean the ORIGINAL user's folders
    [string]$TargetRoaming = '',
    [string]$TargetDesktop = '',
    [string]$TargetOllamaModels = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:NoGui = [bool]$NoGui
if (-not $script:NoGui) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

# ==================== Resolve real user paths ====================
# We do NOT trust %LOCALAPPDATA% / %APPDATA% - they can be empty in some
# sessions - and we do NOT trust %USERNAME% because the profile folder
# name may differ. Order: env var -> .NET folder path -> Registry.
# Note: if the tool is elevated under a DIFFERENT admin account, env vars
# point at that admin's profile - so the correct paths are passed as args.

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

function Fail([string]$msg) {
    if ($script:NoGui) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
    [System.Windows.Forms.MessageBox]::Show($msg, 'Laptop Cleaner', 'OK', 'Error') | Out-Null
    exit 1
}

$UP = Resolve-UserPaths
if (-not [string]::IsNullOrWhiteSpace($TargetProfile)) {
    $UP.Profile = $TargetProfile
    if (-not [string]::IsNullOrWhiteSpace($TargetLocal))   { $UP.Local   = $TargetLocal }
    if (-not [string]::IsNullOrWhiteSpace($TargetRoaming)) { $UP.Roaming = $TargetRoaming }
}
$PROFILE = $UP.Profile
$LOCAL   = $UP.Local
$ROAM    = $UP.Roaming

foreach ($chk in @($PROFILE, $LOCAL, $ROAM)) {
    if ([string]::IsNullOrWhiteSpace($chk) -or $chk -notmatch '^[A-Za-z]:\\') {
        Fail "Could not resolve the user profile path.`n`nInvalid path: '$chk'`n`nNothing was deleted."
    }
}

function Get-DesktopPath {
    if (-not [string]::IsNullOrWhiteSpace($script:TargetDesk)) { return $script:TargetDesk }
    $d = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) {
        $d = Join-Path $PROFILE 'Desktop'
    }
    return $d
}
$script:TargetDesk = $TargetDesktop

# ==================== Helpers ====================
$script:FreeStart  = 0.0
$script:Freed      = 0.0
$script:Cancel     = $false
$script:NeedReboot = $false
$script:RebootGB   = 0.0

function Get-FreeGB {
    try { return [math]::Round((New-Object System.IO.DriveInfo('C')).AvailableFreeSpace / 1GB, 2) }
    catch {
        try { return [math]::Round((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 2) }
        catch { return 0 }
    }
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

# Size (MB) of the pagefile actually ACTIVE on C: - zero when none
function Get-CPagefileMB {
    try {
        $u = Get-CimInstance Win32_PageFileUsage -ErrorAction Stop |
             Where-Object { $_.Name -like 'C:*' } | Select-Object -First 1
        if ($u) { return [int]$u.AllocatedBaseSize }
    } catch { }
    if (Test-Path 'C:\pagefile.sys') {
        try { return [int][math]::Round((Get-Item 'C:\pagefile.sys' -Force -ErrorAction Stop).Length / 1MB) } catch { }
    }
    return 0
}

# ==================== Permission status ====================
$script:IsAdmin = $false
try {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                       ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# Official Ollama model store (may live on D:)
$script:OllamaStore = $TargetOllamaModels
if ([string]::IsNullOrWhiteSpace($script:OllamaStore)) { $script:OllamaStore = $env:OLLAMA_MODELS }
if ([string]::IsNullOrWhiteSpace($script:OllamaStore)) {
    try { $script:OllamaStore = (Get-ItemProperty 'HKCU:\Environment' -Name OLLAMA_MODELS -ErrorAction Stop).OLLAMA_MODELS } catch { }
}

$CPageMB = Get-CPagefileMB

# ==================== Ask for admin (optional) ====================
# The tool works without it for every user-level cleanup, but system
# steps (pagefile move + deep Windows store cleanup) need it.
if (-not $script:NoGui -and -not $script:IsAdmin) {
    $pfNote = if ($CPageMB -gt 0) {
        "and moving the pagefile, which frees ~$([math]::Round($CPageMB/1024,1)) GB on C:"
    } else { "and the deep Windows component-store cleanup" }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "The tool is running with standard permissions.`n`nAll cache cleanups will work normally,`nbut system steps $pfNote`nrequire administrator rights.`n`nRequest administrator rights now?`n`n(Choose 'No' to continue with user-level cleanup only)",
        'Laptop Cleaner', 'YesNo', 'Question')
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        $desk = Get-DesktopPath
        $argList = @(
            '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
            '-File', ('"{0}"' -f $PSCommandPath),
            '-TargetProfile',       ('"{0}"' -f $PROFILE),
            '-TargetLocal',         ('"{0}"' -f $LOCAL),
            '-TargetRoaming',       ('"{0}"' -f $ROAM),
            '-TargetDesktop',       ('"{0}"' -f $desk),
            '-TargetOllamaModels',  ('"{0}"' -f $script:OllamaStore)
        )
        try {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -WindowStyle Hidden -ArgumentList $argList
            exit
        } catch { }
        # Request declined or failed - continue with standard rights
    }
}

# ==================== Output: log + status ====================
function Log([string]$t) {
    if ($script:NoGui) { Write-Host $t; return }
    $log.AppendText("$t`r`n")
    $log.SelectionStart = $log.Text.Length
    $log.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}
function SetStatus([string]$t, [int]$pct) {
    if ($script:NoGui) { return }
    $lblStatus.Text = $t
    if ($pct -ge 0) { $bar.Value = [math]::Min([math]::Max($pct, 0), 100) }
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

# ==================== Steps ====================
# Run options (read from checkboxes, or defaults in -NoGui mode)
$script:Opts = @{ Bin = $false; Page = $true; Docker = $false; Android = $false }

function Build-Steps {
    $steps = @(
        @{ N = 'Temporary files'; F = {
            $script:Freed += Clean-Dir 'C:\Windows\Temp'                          'Windows Temp'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Temp')                   'User Temp'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'CrashDumps')             'Crash dumps'
            $script:Freed += Clean-Dir 'C:\ProgramData\Microsoft\Windows\WER'    'Windows Error Reporting'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WER')  'User Error Reporting'
            $script:Freed += Clean-Dir 'C:\Windows\Logs\CBS'                      'CBS logs'
            $script:Freed += Clean-Dir 'C:\Windows\SoftwareDistribution\Download' 'Windows Update cache'
            $script:Freed += Clean-Dir 'C:\Windows\LiveKernelReports'             'Kernel reports'
        } }
        @{ N = 'Dead Ollama leftovers'; F = {
            $modelsOnC = Join-Path $PROFILE '.ollama\models'
            $store = $script:OllamaStore
            $exists = Test-Path -LiteralPath $modelsOnC
            $orphan = $false
            if ($exists -and -not [string]::IsNullOrWhiteSpace($store) -and
                ($store.TrimEnd('\') -ne $modelsOnC.TrimEnd('\'))) {
                # The official store lives elsewhere (e.g. D:\OllamaModels),
                # so anything on C: is orphaned unless live manifests exist there.
                $man = Join-Path $modelsOnC 'manifests'
                $hasManifests = (Test-Path -LiteralPath $man) -and
                    ((Get-ChildItem -LiteralPath $man -Recurse -File -Force -ErrorAction SilentlyContinue |
                      Measure-Object).Count -gt 0)
                if ($hasManifests) {
                    Log '   ! Live model manifests found on C: - removing interrupted downloads only'
                } else { $orphan = $true }
            }
            if ($orphan) {
                $script:Freed += Drop-Dir $modelsOnC "Orphaned Ollama models on C: (official store: $store)"
            } elseif ($exists -and (Test-Path (Join-Path $modelsOnC 'blobs'))) {
                $b = 0.0
                Get-ChildItem (Join-Path $modelsOnC 'blobs') -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*-partial*' } | ForEach-Object {
                        $b += [math]::Round($_.Length / 1MB, 1)
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                if ($b -gt 0) { Log "   + Interrupted Ollama downloads  ->  $b MB"; $script:Freed += $b }
                else { Log '   - no interrupted downloads' }
            } else { Log '   - no Ollama models on C:' }
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'Ollama\updates_v2') 'Downloaded Ollama update packages (re-fetched if needed)'
        } }
        @{ N = 'Browser caches (Edge / Chrome / Brave)'; F = {
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
        @{ N = 'Notion background cache (Service Worker)'; F = {
            $part = Join-Path $ROAM 'Notion\Partitions\notion'
            if (Test-Path -LiteralPath $part) {
                foreach ($d in @('Service Worker','Cache','Code Cache','GPUCache',
                                 'DawnGraphiteCache','DawnWebGPUCache','Shared Dictionary',
                                 'Crashpad','blob_storage')) {
                    $script:Freed += Clean-Dir (Join-Path $part $d) "Notion: $d"
                }
                if (Get-ProcRunning @('Notion')) {
                    Log '   ! Notion is running - whatever could not be removed now is freed when you close it and clean again'
                }
            } else { Log '   - no Notion cache' }
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Notion\Cache')    'Notion Cache'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Notion\GPUCache')  'Notion GPUCache'
        } }
        @{ N = 'Application caches (Slack / Teams / Discord / VS Code)'; F = {
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
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'cherrystudio-updater')                'Cherry Studio updater leftovers'
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'zwork-updater')                       'Zwork updater leftovers'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'kingsoft\office6\updatenew')           'WPS update leftovers'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'wps_download')                         'Downloaded WPS installers'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\cache')              'WPS cache'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\log')                'WPS logs'
            $script:Freed += Clean-Dir 'C:\Windows\Prefetch'                                  'Prefetch'
        } }
        @{ N = 'Old WPS versions'; F = {
            $wpsRoot = Join-Path $LOCAL 'Kingsoft\WPS Office'
            if (-not (Test-Path -LiteralPath $wpsRoot)) { Log '   - WPS not installed'; return }
            $vers = @(Get-ChildItem -LiteralPath $wpsRoot -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' })
            if ($vers.Count -lt 2) { Log '   - no old versions'; return }
            $sorted = $vers | Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0.0' } } -Descending
            $newest = $sorted[0].Name
            $runningPaths = @()
            foreach ($p in (Get-Process -Name wps,wpscloudsvr,et,wpp -ErrorAction SilentlyContinue)) {
                if ($p.Path) { $runningPaths += $p.Path }
            }
            $sum = 0.0
            foreach ($v in $sorted) {
                if ($v.Name -eq $newest) { continue }
                $busy = $false
                foreach ($rp in $runningPaths) { if ($rp -like "$($v.FullName)*") { $busy = $true; break } }
                if ($busy) { Log "   - version $($v.Name) is running - skipped"; continue }
                $sum += Drop-Dir $v.FullName "old WPS version $($v.Name)"
            }
            if ($sum -gt 0) { Log "   = old versions total: $([math]::Round($sum,0)) MB" }
            $script:Freed += $sum
        } }
        @{ N = 'WeChat leftovers'; F = {
            $script:Freed += Drop-Dir  (Join-Path $ROAM 'Tencent\xwechat\update') 'Downloaded WeChat update packages'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Tencent\xwechat\log')    'WeChat logs'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Tencent\Logs')            'Tencent logs'
        } }
        @{ N = 'Dev tool caches'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pip\cache')                'pip cache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'npm-cache\_cacache')      'npm cache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'npm-cache\_logs')         'npm logs'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pnpm-store\v3\files')    'pnpm store'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Yarn\Cache')              'Yarn cache'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'AutoClaw-oversea-official\toolchain\node\cache\_npx') 'npx cache'
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
        @{ N = 'Anytxt search index'; F = {
            if (Test-Path 'C:\ProgramData\Anytxt\data') {
                if (Get-ProcRunning @('AnyTXT','Anytxt','anyservice','ATService')) {
                    Log '   ! Anytxt is running - skipped. Close it and re-run.'
                } else {
                    $script:Freed += Drop-Dir 'C:\ProgramData\Anytxt\data' 'Anytxt index (rebuilt automatically)'
                }
            } else { Log '   - no Anytxt index' }
        } }
        @{ N = 'Thumbnail and internet caches'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Explorer')  'Thumbnail cache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\INetCache') 'INetCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WebCache')  'WebCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Caches')    'Windows caches'
        } }
    )

    if ($script:Opts.Bin) {
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

    # Pagefile move - placed before the slow steps so the user is not kept waiting
    if ($script:Opts.Page) {
        $steps += @{ N = 'Move pagefile from C: to D:'; F = {
            if (-not (Test-Path 'D:\')) { Log '   ! no D: drive - skipped'; return }
            $cMB = Get-CPagefileMB
            if ($cMB -le 0) { Log '   OK - pagefile is not on C: - already set'; return }
            $cGB = [math]::Round($cMB / 1024, 1)
            if (-not $script:IsAdmin) {
                Log "   ! the active pagefile is on C: and is $cGB GB"
                Log '     moving it needs administrator rights - accept the UAC prompt when the tool starts'
                return
            }
            $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            $ccKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'

            # Was the setting already correct before we started? (deeper warning if it keeps coming back)
            $wasSet = $false
            try {
                $p0 = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction Stop).PagingFiles -join ' '
                $c0 = (Get-ItemProperty -Path $ccKey -Name CrashDumpEnabled -ErrorAction Stop).CrashDumpEnabled
                if ($p0 -match 'D:\\pagefile' -and $p0 -notmatch 'C:\\pagefile' -and $c0 -eq 0) { $wasSet = $true }
            } catch { }

            # 1) Turn off automatic pagefile management
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                if ($cs.AutomaticManagedPagefile) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
                    Log '   + automatic pagefile management turned off'
                }
            } catch { Log "   ! could not disable automatic management: $($_.Exception.Message)" }

            # 2) Point the pagefile at D:
            try {
                Set-ItemProperty -Path $mmKey -Name PagingFiles -Value @('D:\pagefile.sys 8192 16384') -Type MultiString -ErrorAction Stop
                Log '   + pagefile set on D: from 8 to 16 GB'
            } catch { Log "   ! could not set PagingFiles: $($_.Exception.Message)" }

            # 3) Disable crash-dump writing - the root-cause fix:
            #    Windows needs a pagefile on the SYSTEM volume to write crash dumps,
            #    and when it cannot find one it creates a temporary, constantly
            #    growing pagefile on C: that eats all freed space.
            try {
                Set-ItemProperty -Path $ccKey -Name CrashDumpEnabled -Value 0 -Type DWord -ErrorAction Stop
                Log '   + crash-dump writing disabled - this is what kept re-creating the pagefile on C:'
            } catch { Log "   ! could not set CrashDumpEnabled: $($_.Exception.Message)" }

            # 4) Verify every value
            $okP = $false; $okC = $false
            try {
                $p1 = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction Stop).PagingFiles -join ' '
                if ($p1 -match 'D:\\pagefile' -and $p1 -notmatch 'C:\\pagefile') { $okP = $true }
            } catch { }
            try {
                if ((Get-ItemProperty -Path $ccKey -Name CrashDumpEnabled -ErrorAction Stop).CrashDumpEnabled -eq 0) { $okC = $true }
            } catch { }

            if ($okP -and $okC) {
                Log "   + setup complete - ~$cGB GB will be freed from C: after a restart"
                $script:NeedReboot = $true
                $script:RebootGB  = $cGB
                if ($wasSet) {
                    Log '   ! note: the setting was already correct yet the file came back on C:'
                    Log '     if this repeats after the next restart, set it manually via:'
                    Log '     sysdm.cpl -> Advanced -> Performance/Settings -> Advanced -> Virtual Memory'
                }
            } else {
                Log '   ! setup did not complete - see the error messages above'
            }
        } }
    }

    # Optional extras: Docker disk / Android SDK
    if ($script:Opts.Docker) {
        $steps += @{ N = 'Docker WSL disk'; F = {
            $wsl = Join-Path $LOCAL 'Docker\wsl'
            if (-not (Test-Path -LiteralPath $wsl)) { Log '   - no Docker disk'; return }
            if (Get-ProcRunning @('Docker Desktop','com.docker.backend','dockerd','docker')) {
                Log '   ! Docker is running - close it and clean again'; return
            }
            $script:Freed += Drop-Dir $wsl 'Docker disk (removes all images and containers)'
        } }
    }
    if ($script:Opts.Android) {
        $steps += @{ N = 'Android SDK'; F = {
            $a = Join-Path $LOCAL 'Android'
            if (-not (Test-Path -LiteralPath $a)) { Log '   - no Android SDK'; return }
            $script:Freed += Drop-Dir $a 'Android SDK (re-downloaded by Android Studio on demand)'
        } }
    }

    # Windows upgrade leftovers + DISM + built-in Disk Cleanup (slowest, so last)
    $steps += @{ N = 'Windows update leftovers'; F = {
        if (Test-Path 'C:\$WinREAgent') {
            $script:Freed += Drop-Dir 'C:\$WinREAgent' 'Windows upgrade leftovers'
        } else { Log '   - no upgrade leftovers' }

        if (-not $script:IsAdmin) {
            Log '   - component store cleanup and built-in Disk Cleanup need administrator rights - skipped'
            return
        }

        $marker = 'C:\ProgramData\zwork-last-dism.txt'
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

    return $steps
}

# ==================== Full run ====================
function Run-All {
    $script:Freed      = 0.0
    $script:FreeStart = Get-FreeGB
    $script:NeedReboot = $false
    $t0 = Get-Date

    if (-not $script:NoGui) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    Log '========================================'
    Log "Started - $(Get-Date -Format 'HH:mm:ss')"
    Log "Free before: $script:FreeStart GB"
    Log '========================================'

    $steps = Build-Steps
    $i = 0
    foreach ($s in $steps) {
        if ($script:Cancel) { break }
        $i++
        $pct = [int](($i / [math]::Max($steps.Count, 1)) * 92)
        SetStatus $s.N $pct
        Log ''
        Log "> $i/$($steps.Count)  $($s.N)"
        try { & $s.F } catch { Log "   ! error: $($_.Exception.Message)" }
        if (-not $script:NoGui) { [System.Windows.Forms.Application]::DoEvents() }
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

    if (-not $script:NoGui) {
        $lblFree.Text = "C: free space  -  $freeEnd GB"
        $lblFree.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
    }

    if ($script:NeedReboot) {
        Log ''
        Log "NOTICE: a restart is required to free ~$($script:RebootGB) GB on C: and finish the pagefile move"
        Log '  run the tool once more after the restart to confirm the file actually moved'
    }

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

    if ($script:NoGui) { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    # Offer the restart right after a successful pagefile setup
    if ($script:NeedReboot) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "The pagefile was configured successfully.`n`nA restart is required to complete the move`nand free ~$($script:RebootGB) GB on C:.`n`nRestart now?`n(save your open work first - you have 20 seconds)",
            'Laptop Cleaner', 'YesNo', 'Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/r','/t','20','/c','Restart to finish the pagefile move'
            $form.Close()
        }
    }
}

# ==================== Headless mode ====================
if ($script:NoGui) { Run-All; return }

# ==================== Window ====================
$form                   = New-Object System.Windows.Forms.Form
$form.Text              = 'Laptop Cleaner'
$form.Size              = New-Object System.Drawing.Size(620, 684)
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

$lblAdmin           = New-Object System.Windows.Forms.Label
$lblAdmin.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblAdmin.Location  = New-Object System.Drawing.Point(20, 88)
$lblAdmin.Size      = New-Object System.Drawing.Size(560, 22)
if ($script:IsAdmin) {
    $lblAdmin.Text      = 'Running as administrator - all steps available'
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
} else {
    $lblAdmin.Text      = 'Not running as administrator - system steps will be skipped'
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(190, 100, 0)
}
$form.Controls.Add($lblAdmin)

$lblInfo           = New-Object System.Windows.Forms.Label
$lblInfo.Text      = "Cleans: temp files, browser caches, Ollama/WPS/WeChat/Notion leftovers, installer leftovers, dev tool caches.`nNever touches: your documents, bookmarks, saved passwords, or settings."
$lblInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$lblInfo.Location  = New-Object System.Drawing.Point(20, 112)
$lblInfo.Size      = New-Object System.Drawing.Size(560, 40)
$form.Controls.Add($lblInfo)

$chkBin           = New-Object System.Windows.Forms.CheckBox
$chkBin.Text      = 'Also empty the Recycle Bin'
$chkBin.Location  = New-Object System.Drawing.Point(20, 156)
$chkBin.Size      = New-Object System.Drawing.Size(560, 24)
$chkBin.Checked   = $false
$chkBin.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkBin)

$chkPage           = New-Object System.Windows.Forms.CheckBox
if ($CPageMB -gt 0) {
    $chkPage.Text = "Move pagefile from C: to D:  (frees ~$([math]::Round($CPageMB/1024,1)) GB after a restart)"
} else {
    $chkPage.Text = 'Pagefile is already on D:  (nothing to move)'
}
$chkPage.Location  = New-Object System.Drawing.Point(20, 182)
$chkPage.Size      = New-Object System.Drawing.Size(560, 24)
$chkPage.Checked   = $true
$chkPage.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkPage)

$chkDocker           = New-Object System.Windows.Forms.CheckBox
$chkDocker.Text      = 'Wipe the Docker WSL disk (removes all images and containers) - ~5 GB'
$chkDocker.Location  = New-Object System.Drawing.Point(20, 208)
$chkDocker.Size      = New-Object System.Drawing.Size(560, 24)
$chkDocker.Checked   = $false
$chkDocker.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkDocker)

$chkAndroid           = New-Object System.Windows.Forms.CheckBox
$chkAndroid.Text      = 'Wipe the Android SDK (re-downloaded by Android Studio on demand) - ~2 GB'
$chkAndroid.Location  = New-Object System.Drawing.Point(20, 234)
$chkAndroid.Size      = New-Object System.Drawing.Size(560, 24)
$chkAndroid.Checked   = $false
$chkAndroid.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkAndroid)

$bar           = New-Object System.Windows.Forms.ProgressBar
$bar.Location  = New-Object System.Drawing.Point(20, 264)
$bar.Size      = New-Object System.Drawing.Size(560, 22)
$bar.Style     = 'Continuous'
$bar.Minimum   = 0
$bar.Maximum   = 100
$bar.Value     = 0
$form.Controls.Add($bar)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Ready. Press the button to start.'
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
$lblStatus.Location  = New-Object System.Drawing.Point(20, 290)
$lblStatus.Size      = New-Object System.Drawing.Size(560, 24)
$form.Controls.Add($lblStatus)

$log            = New-Object System.Windows.Forms.TextBox
$log.Location   = New-Object System.Drawing.Point(20, 318)
$log.Size       = New-Object System.Drawing.Size(560, 248)
$log.Multiline  = $true
$log.ReadOnly   = $true
$log.ScrollBars = 'Vertical'
$log.Font       = New-Object System.Drawing.Font('Consolas', 9)
$log.BackColor  = [System.Drawing.Color]::White
$form.Controls.Add($log)

$btnStart           = New-Object System.Windows.Forms.Button
$btnStart.Text      = 'Clean now'
$btnStart.Location  = New-Object System.Drawing.Point(20, 578)
$btnStart.Size      = New-Object System.Drawing.Size(360, 52)
$btnStart.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$form.Controls.Add($btnStart)

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(400, 578)
$btnClose.Size     = New-Object System.Drawing.Size(180, 52)
$btnClose.Font     = New-Object System.Drawing.Font('Segoe UI', 11)
$btnClose.FlatStyle = 'Flat'
$form.Controls.Add($btnClose)

$btnClose.Add_Click({ $form.Close() })

$btnStart.Add_Click({
    $btnStart.Enabled   = $false
    $chkBin.Enabled     = $false
    $chkPage.Enabled    = $false
    $chkDocker.Enabled  = $false
    $chkAndroid.Enabled = $false
    $script:Opts.Bin     = $chkBin.Checked
    $script:Opts.Page    = $chkPage.Checked
    $script:Opts.Docker  = $chkDocker.Checked
    $script:Opts.Android = $chkAndroid.Checked

    Run-All

    $btnStart.Enabled   = $true
    $chkBin.Enabled     = $true
    $chkPage.Enabled    = $true
    $chkDocker.Enabled  = $true
    $chkAndroid.Enabled = $true
    $btnStart.Text      = 'Clean again'
})

$form.Add_FormClosing({ $script:Cancel = $true })

[void]$form.ShowDialog()
