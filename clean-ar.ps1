<#
    أداة تنظيف اللابتوب - الواجهة الرسومية
    ========================================
    لا تشغّل هذا الملف مباشرة.
    انقر مرتين على: تنظيف-اللابتوب.bat

    تنظّف الملفات المؤقتة والكاشات القابلة لإعادة التوليد فقط.
    لا تلمس أي ملف شخصي.
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# ==================== تحديد مسارات المستخدم الحقيقي ====================
# لا نعتمد على %LOCALAPPDATA% و %APPDATA% لأنهما قد تكونان فارغتين،
# ولا على %USERNAME% لأن اسم مجلد الملف الشخصي قد يختلف عنه.
# الأولوية: متغير البيئة ← مجلد الملف الشخصي ← Registry.

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

# التحقق من صحة المسارات - إن فشلت الأداة تتوقف بدل أن تحذف في مكان خطأ
foreach ($chk in @($PROFILE, $LOCAL, $ROAM)) {
    if ([string]::IsNullOrWhiteSpace($chk) -or $chk -notmatch '^[A-Za-z]:\\') {
        [System.Windows.Forms.MessageBox]::Show(
            "تعذّر تحديد مجلد المستخدم بشكل صحيح.`n`nالمسار غير الصالح: '$chk'`n`nلم يُحذف أي شيء.",
            'أداة تنظيف اللابتوب', 'OK', 'Error') | Out-Null
        exit 1
    }
}

# سطح المكتب (للحفظ في السجل) - لا نفترض English
function Get-DesktopPath {
    $d = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) {
        $d = Join-Path $PROFILE 'Desktop'
    }
    return $d
}

# ==================== دوال مساعدة ====================
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

# ==================== الواجهة ====================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'أداة تنظيف اللابتوب'
$form.Size            = New-Object System.Drawing.Size(600, 620)
$form.StartPosition   = 'CenterScreen'
$form.RightToLeft     = 'Yes'
$form.RightToLeftLayout = $true
$form.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 252)
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

# العنوان
$title           = New-Object System.Windows.Forms.Label
$title.Text      = 'تنظيف اللابتوب'
$title.Font      = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(20, 30, 60)
$title.Location  = New-Object System.Drawing.Point(20, 15)
$title.Size      = New-Object System.Drawing.Size(540, 45)
$title.TextAlign = 'MiddleRight'
$form.Controls.Add($title)

# المساحة الحرة
$lblFree           = New-Object System.Windows.Forms.Label
$lblFree.Text      = "المساحة الحرة في C:  —  $((Get-FreeGB)) جيجا"
$lblFree.Font      = New-Object System.Drawing.Font('Segoe UI', 12)
$lblFree.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$lblFree.Location  = New-Object System.Drawing.Point(20, 62)
$lblFree.Size      = New-Object System.Drawing.Size(540, 30)
$lblFree.TextAlign = 'MiddleRight'
$form.Controls.Add($lblFree)

# الشرح
$lblInfo           = New-Object System.Windows.Forms.Label
$lblInfo.Text      = "ينظّف: الملفات المؤقتة، كاشات المتصفحات والتطبيقات، مخلفات المُثبِّتات، وكاشات أدوات البرمجة.`nلا يلمس: ملفاتك الشخصية، المفضلة، كلمات المرور، أو إعداداتك."
$lblInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$lblInfo.Location  = New-Object System.Drawing.Point(20, 94)
$lblInfo.Size      = New-Object System.Drawing.Size(540, 40)
$lblInfo.TextAlign = 'MiddleRight'
$form.Controls.Add($lblInfo)

# خيارات
$chkBin           = New-Object System.Windows.Forms.CheckBox
$chkBin.Text      = 'تفريغ سلة المحذوفات أيضًا'
$chkBin.Location  = New-Object System.Drawing.Point(20, 140)
$chkBin.Size      = New-Object System.Drawing.Size(540, 26)
$chkBin.Checked   = $false
$chkBin.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkBin)

$chkPage           = New-Object System.Windows.Forms.CheckBox
$chkPage.Text      = 'نقل ملف الترحيل من C: إلى D:  (يحتاج إعادة تشغيل — يحرّر ~8 جيجا)'
$chkPage.Location  = New-Object System.Drawing.Point(20, 168)
$chkPage.Size      = New-Object System.Drawing.Size(540, 26)
$chkPage.Checked   = $true
$chkPage.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkPage)

# شريط التقدم
$bar           = New-Object System.Windows.Forms.ProgressBar
$bar.Location  = New-Object System.Drawing.Point(20, 205)
$bar.Size      = New-Object System.Drawing.Size(540, 24)
$bar.Style     = 'Continuous'
$bar.Minimum   = 0
$bar.Maximum   = 100
$bar.Value     = 0
$form.Controls.Add($bar)

# الحالة
$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'جاهز. اضغط الزر للبدء.'
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
$lblStatus.Location  = New-Object System.Drawing.Point(20, 234)
$lblStatus.Size      = New-Object System.Drawing.Size(540, 26)
$lblStatus.TextAlign = 'MiddleRight'
$form.Controls.Add($lblStatus)

# السجل
$log              = New-Object System.Windows.Forms.TextBox
$log.Location     = New-Object System.Drawing.Point(20, 264)
$log.Size         = New-Object System.Drawing.Size(540, 240)
$log.Multiline    = $true
$log.ReadOnly     = $true
$log.ScrollBars   = 'Vertical'
$log.Font         = New-Object System.Drawing.Font('Segoe UI', 9)
$log.BackColor    = [System.Drawing.Color]::White
$log.RightToLeft  = 'Yes'
$form.Controls.Add($log)

# زر البدء
$btnStart           = New-Object System.Windows.Forms.Button
$btnStart.Text      = 'ابدأ التنظيف الآن'
$btnStart.Location  = New-Object System.Drawing.Point(60, 515)
$btnStart.Size      = New-Object System.Drawing.Size(280, 50)
$btnStart.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$form.Controls.Add($btnStart)

# زر الإغلاق
$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'إغلاق'
$btnClose.Location = New-Object System.Drawing.Point(360, 515)
$btnClose.Size     = New-Object System.Drawing.Size(180, 50)
$btnClose.Font     = New-Object System.Drawing.Font('Segoe UI', 11)
$btnClose.FlatStyle = 'Flat'
$form.Controls.Add($btnClose)

$btnClose.Add_Click({ $form.Close() })

# ==================== كتابة السجل ====================
function Log([string]$t, [string]$color = 'Dark') {
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

# ==================== محرك التنظيف ====================
function Clean-Dir([string]$dir, [string]$label) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0.0 }
    $before = Get-DirMB $dir
    if ($before -le 0) { return 0.0 }
    foreach ($i in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
    $freed = [math]::Round($before - (Get-DirMB $dir), 1)
    if ($freed -gt 0) { Log "   • $label  ←  $freed ميجا" } else { Log "   - $label (ملفات مقفلة)" }
    return $freed
}
function Drop-Dir([string]$dir, [string]$label) {
    if (-not (Test-Path -LiteralPath $dir)) { return 0.0 }
    $mb = Get-DirMB $dir
    try { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if (-not (Test-Path -LiteralPath $dir)) { Log "   • $label  ←  $mb ميجا" ; return $mb }
    Log "   - $label (ملفات مقفلة)"; return 0.0
}

# ==================== الحدث الرئيسي ====================
$btnStart.Add_Click({
    $btnStart.Enabled = $false
    $chkBin.Enabled   = $false
    $chkPage.Enabled  = $false
    $script:Freed     = 0.0
    $script:FreeStart = Get-FreeGB
    $t0 = Get-Date

    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Log "════════════════════════════════════"
    Log "بدء التنظيف - $(Get-Date -Format 'HH:mm:ss')"
    Log "المساحة الحرة قبل: $script:FreeStart جيجا"
    Log "════════════════════════════════════"
    Log ''

    $steps = @(
        @{ N = 'الملفات المؤقتة للنظام والمستخدم'; F = {
            $script:Freed += Clean-Dir 'C:\Windows\Temp'                          'حفظ النظام المؤقت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Temp')                   'حفظ المستخدم المؤقت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'CrashDumps')             'تقارير الأعطال'
            $script:Freed += Clean-Dir 'C:\ProgramData\Microsoft\Windows\WER'     'تقارير أخطاء ويندوز'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WER')  'تقارير أخطاء المستخدم'
            $script:Freed += Clean-Dir 'C:\Windows\Logs\CBS'                      'سجلات CBS'
            $script:Freed += Clean-Dir 'C:\Windows\SoftwareDistribution\Download' 'تنزيلات تحديث ويندوز'
            $script:Freed += Clean-Dir 'C:\Windows\LiveKernelReports'             'تقارير النواة'
        } }
        @{ N = 'كاشات المتصفحات (Edge / Chrome / Brave)'; F = {
            $names = @('Cache','Code Cache','GPUCache','GrShaderCache','ShaderCache','Crashpad',
                       'DawnCache','DawnGraphicCache','DawnWebGPUCache','CacheStorage','Media Cache')
            $roots = @(
                (Join-Path $LOCAL 'Microsoft\Edge\User Data'),
                (Join-Path $LOCAL 'Google\Chrome\User Data'),
                (Join-Path $LOCAL 'BraveSoftware\Brave-Browser\User Data')
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
            if ($hit -eq 0) { Log '   - لا توجد كاشات متصفحات' }
            else { Log "   ═ إجمالي كاشات المتصفحات: $([math]::Round($sum,0)) ميجا" }
            $script:Freed += $sum
        } }
        @{ N = 'كاشات التطبيقات (Slack / Teams / Discord / VS Code)'; F = {
            $apps = @(
                @{P=(Join-Path $ROAM 'Slack\Service Worker'); L='Slack Service Worker'}
                @{P=(Join-Path $ROAM 'Slack\Cache');          L='Slack كاش'}
                @{P=(Join-Path $ROAM 'Slack\Code Cache');     L='Slack كاش برمجي'}
                @{P=(Join-Path $ROAM 'Slack\logs');           L='Slack سجلات'}
                @{P=(Join-Path $ROAM 'discord\Cache');        L='Discord كاش'}
                @{P=(Join-Path $ROAM 'discord\Code Cache');   L='Discord كاش برمجي'}
                @{P=(Join-Path $ROAM 'discord\GPUCache');     L='Discord GPUCache'}
                @{P=(Join-Path $ROAM 'Zoom\logs');            L='Zoom سجلات'}
                @{P=(Join-Path $ROAM 'Zoom\ZoomDownload');    L='Zoom تنزيلات'}
                @{P=(Join-Path $ROAM 'Notion\Cache');         L='Notion كاش'}
                @{P=(Join-Path $ROAM 'Notion\GPUCache');      L='Notion GPUCache'}
                @{P=(Join-Path $ROAM 'Code\Cache');           L='VS Code كاش'}
                @{P=(Join-Path $ROAM 'Code\CachedData');      L='VS Code بيانات مخزّنة'}
                @{P=(Join-Path $ROAM 'Code\logs');            L='VS Code سجلات'}
                @{P=(Join-Path $LOCAL 'Postman\logs');        L='Postman سجلات'}
                @{P=(Join-Path $LOCAL 'Microsoft\Teams\logs'); L='Teams سجلات'}
                @{P=(Join-Path $ROAM 'Figma\logs');           L='Figma سجلات'}
            )
            foreach ($a in $apps) { $script:Freed += Clean-Dir $a.P $a.L }
        } }
        @{ N = 'مخلفات المُثبِّتات والمحدِّثات'; F = {
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'Google\GoogleUpdater\crx_cache')      'مخلفات محدّث جوجل'
            $script:Freed += Drop-Dir 'C:\Program Files (x86)\Google\GoogleUpdater\crx_cache' 'مخلفات محدّث جوجل (برامج)'
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'cherrystudio-updater')                'مخلفات محدّث Cherry Studio'
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'zwork-updater')                       'مخلفات محدّث Zwork'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'kingsoft\office6\updatenew')           'مخلفات تحديث WPS'
            $script:Freed += Drop-Dir (Join-Path $ROAM 'wps_download')                         'مُثبِّتات WPS المحمّلة'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\cache')              'كاش WPS'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'kingsoft\office6\log')                'سجلات WPS'
            $script:Freed += Clean-Dir 'C:\Windows\Prefetch'                                  'Prefetch'
        } }
        @{ N = 'حزم إضافات WPS'; F = {
            $pool = (Join-Path $ROAM 'kingsoft\wps\addons\pool')
            if (Test-Path -LiteralPath $pool) {
                if (Get-ProcRunning @('wps','wpscloudsvr','et','wpp','ksomisc')) {
                    Log "   ! WPS يعمل الآن - أُجّل التنظيف ($(Get-DirMB $pool) ميجا). أغلقه ثم أعد التشغيل."
                } else {
                    $script:Freed += Drop-Dir $pool 'حزم إضافات WPS (تُعاد عند الطلب)'
                }
            } else { Log '   - لا حزم إضافات WPS' }
        } }
        @{ N = 'فهرس برنامج البحث Anytxt'; F = {
            if (Test-Path 'C:\ProgramData\Anytxt\data') {
                if (Get-ProcRunning @('AnyTXT','Anytxt','anyservice')) {
                    Log '   ! Anytxt يعمل الآن - أُجّل التنظيف. أغلقه ثم أعد التشغيل.'
                } else {
                    $script:Freed += Drop-Dir 'C:\ProgramData\Anytxt\data' 'فهرس Anytxt (يُبنى تلقائيًا)'
                }
            } else { Log '   - لا فهرس Anytxt' }
        } }
        @{ N = 'كاشات أدوات البرمجة'; F = {
            $pyCache = Join-Path $LOCAL 'pip'
            if (Get-Command python -ErrorAction SilentlyContinue) {
                $b = Get-DirMB $pyCache
                python -m pip cache purge 2>&1 | Out-Null
                Log "   • كاش pip  ←  $b ميجا" ; $script:Freed += $b
            } else { Log '   - pip غير مثبّت' }
            if (Get-Command npm -ErrorAction SilentlyContinue) {
                $b = Get-DirMB (Join-Path $LOCAL 'npm-cache')
                npm cache clean --force 2>&1 | Out-Null
                Log "   • كاش npm  ←  $b ميجا" ; $script:Freed += $b
            } else { Log '   - npm غير مثبّت' }
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pnpm-store\v3\files') 'كاش pnpm'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Yarn\Cache')          'كاش Yarn'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'AutoClaw-oversea-official\toolchain\node\cache\_npx') 'كاش npx'
        } }
        @{ N = 'كاش المصغّرات وذاكرة الإنترنت'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Explorer')  'مصغّرات الصور والأيقونات'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\INetCache') 'ذاكرة الإنترنت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WebCache')  'WebCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Caches')    'كاش ويندوز'
        } }
    )

    # خطوة اختيارية: سلة المحذوفات
    if ($chkBin.Checked) {
        $steps += @{ N = 'سلة المحذوفات'; F = {
            $mb = 0.0
            foreach ($d in @('C:','D:')) {
                $rb = "$d\`$Recycle.Bin"
                if (Test-Path -LiteralPath $rb) { $mb += Get-DirMB $rb }
            }
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            Log "   • تم تفريغ سلة المحذوفات  ←  $([math]::Round($mb,0)) ميجا"
            $script:Freed += $mb
        } }
    }

    # مخلفات ترقية ويندوز
    $steps += @{ N = 'مخلفات تحديثات ويندوز'; F = {
        if (Test-Path 'C:\$WinREAgent') {
            $script:Freed += Drop-Dir 'C:\$WinREAgent' 'مخلفات ترقية ويندوز'
        } else { Log '   - لا مخلفات ترقية ويندوز' }

        $marker = 'C:\ProgramData\zwork-last-dism.txt'
        $doDism = $true
        if (Test-Path -LiteralPath $marker) {
            try {
                $last = [datetime]::Parse((Get-Content -LiteralPath $marker -Raw).Trim())
                $days = [int]((Get-Date) - $last).TotalDays
                if ($days -lt 60) { $doDism = $false ; Log "   - مخزن المكونات نُظّف قبل $days يومًا" }
            } catch { }
        }
        if ($doDism) {
            Log '   ... جارٍ تنظيف مخزن مكونات ويندوز (10-30 دقيقة)'
            SetStatus 'جارٍ تنظيف مخزن مكونات ويندوز...' -1
            $fb = Get-FreeGB
            DISM /Online /Cleanup-Image /StartComponentCleanup 2>&1 | Out-Null
            $g = [math]::Round((Get-FreeGB) - $fb, 2)
            Set-Content -LiteralPath $marker -Value (Get-Date).ToString('o') -Encoding UTF8
            Log "   • مخزن مكونات ويندوز  ←  $g جيجا"
            $script:Freed += ($g * 1024)
        }

        Log '   ... جارٍ تشغيل أداة ويندوز الرسمية للتنظيف'
        SetStatus 'جارٍ تشغيل أداة ويندوز الرسمية...' -1
        $sageset = 65535
        Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches' -ErrorAction SilentlyContinue |
            ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name "StateFlags$sageset" -Value 2 -Type DWord -ErrorAction SilentlyContinue }
        foreach ($skip in @('Recycle Bin','Downloads','Windows ESD installation files','Previous Installations')) {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\$skip" `
                -Name "StateFlags$sageset" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        }
        if (Test-Path "$env:SystemRoot\System32\cleanmgr.exe") {
            Start-Process "$env:SystemRoot\System32\cleanmgr.exe" -ArgumentList "/sagerun:$sageset" -Wait -WindowStyle Hidden
            Log '   • أداة ويندوز الرسمية للتنظيف'
        }
    } }

    # خطوة اختيارية: ملف الترحيل
    if ($chkPage.Checked) {
        $steps += @{ N = 'نقل ملف الترحيل إلى D:'; F = {
            try {
                $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
                $cs = Get-CimInstance Win32_ComputerSystem
                if ($cs.AutomaticManagedPagefile) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }
                }
                $pf = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction SilentlyContinue).PagingFiles
                if (($pf -join ' ') -match 'C:\\pagefile') {
                    Set-ItemProperty -Path $mmKey -Name PagingFiles -Value @('D:\pagefile.sys 8192 16384') -Type MultiString
                    Log '   • تم ضبط ملف الترحيل على D:  —  سيُحرَّر ~8 جيجا بعد إعادة التشغيل'
                } else {
                    Log '   - ملف الترحيل مضبوط على D: أصلًا'
                }
            } catch { Log "   ! تعذّر ضبط ملف الترحيل: $($_.Exception.Message)" }
        } }
    }

    # تنفيذ الخطوات
    $i = 0
    foreach ($s in $steps) {
        if ($script:Cancel) { break }
        $i++
        $pct = [int](($i / [math]::Max($steps.Count,1)) * 92)
        SetStatus $s.N $pct
        Log ''
        Log "▶ $($i)/$($steps.Count)  $($s.N)"
        try { & $s.F } catch { Log "   ! خطأ: $($_.Exception.Message)" }
        [System.Windows.Forms.Application]::DoEvents()
    }

    # النتيجة
    SetStatus 'اكتمل التنظيف' 100
    $freeEnd = Get-FreeGB
    $gained  = [math]::Round($freeEnd - $script:FreeStart, 2)
    $secs    = [int]((Get-Date) - $t0).TotalSeconds

    Log ''
    Log '════════════════════════════════════'
    Log "   المساحة الحرة قبل :  $script:FreeStart جيجا"
    Log "   المساحة الحرة بعد :  $freeEnd جيجا"
    Log "   الذي تحرّر        :  $gained جيجا"
    Log "   الزمن             :  $secs ثانية"
    Log '════════════════════════════════════'

    $lblFree.Text = "المساحة الحرة في C:  —  $freeEnd جيجا"
    $lblFree.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
    Log ''

    if ($chkPage.Checked) {
        Log '⚠ مهم: أعد تشغيل الجهاز ليكتمل نقل ملف الترحيل.'
        Log ''
    }

    # حفظ السجل
    try {
        $lg = Join-Path (Get-DesktopPath) 'سجل-التنظيف.txt'
        @(
          "سجل تنظيف اللابتوب - $(Get-Date -Format 'yyyy-MM-dd HH:mm')",
          "الحرة قبل : $script:FreeStart جيجا",
          "الحرة بعد : $freeEnd جيجا",
          "تحرّر     : $gained جيجا",
          "الزمن     : $secs ثانية"
        ) | Set-Content -LiteralPath $lg -Encoding UTF8
        Log "حُفظ السجل في: $lg"
    } catch { }

    $form.Cursor      = [System.Windows.Forms.Cursors]::Default
    $btnStart.Enabled = $true
    $chkBin.Enabled   = $true
    $chkPage.Enabled  = $true
    $btnStart.Text    = 'تنظيف مرة أخرى'
})

$form.Add_FormClosing({ $script:Cancel = $true })

[void]$form.ShowDialog()
