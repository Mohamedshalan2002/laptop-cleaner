<#
    أداة تنظيف اللابتوب - الواجهة العربية
    =======================================
    لا تشغّل هذا الملف مباشرة.
    انقر مرتين على: Clean-Laptop-AR.bat

    تنظّف الملفات المؤقتة والكاشات القابلة لإعادة التوليد فقط.
    لا تلمس أي ملف شخصي.

    الجديد في هذه النسخة:
      * إصلاح جذري لنقل ملف الترحيل (pagefile) من C: إلى D:
        - يكتشف الملف الفعلي الشغّال (وليس إعداد الريجستري فقط)
        - يعطّل كتابة تقارير الأعطال التي كانت تجبر ويندوز على
          إعادة إنشاء ملف ترحيل مؤقت على C: بعد كل إعادة تشغيل
        - يتحقق من كل قيمة يكتبها ويطلب إعادة التشغيل بنفسه
      * تنظيف مخلفات Ollama الميتة (تحميلات مقطوعة + موديلات يتيمة)
      * تنظيف كاش Notion الخلفي (Service Worker) - أكبر كاش في البرنامج
      * حذف نسخ WPS القديمة تلقائياً (يبقي الأحدث فقط)
      * تنظيف حزم تحديث WeChat المحمّلة
      * تنظيف كاش pip و npm مباشرة دون الحاجة لبيثون
      * خيارين إضافيين: مسح قرص Docker / مسح Android SDK
      * يعرض حالة الصلاحيات بوضوح ويتخطى خطوات النظام بأمان
        إذا لم تكن متاحة، بدلاً من الفشل بصمت
#>

param(
    [switch]$NoGui,                # تشغيل بدون واجهة (للاختبار أو الأتمتة)
    [string]$TargetProfile = '',   # تُمرَّر عند إعادة التشغيل بصلاحيات مدير
    [string]$TargetLocal = '',     # حتى ننظّف مجلدات المستخدم الصحيح
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
    Add-Type -AssemblyName Microsoft.VisualBasic
}

# ==================== تحديد مسارات المستخدم الحقيقي ====================
# لا نعتمد على %LOCALAPPDATA% و %APPDATA% لأنهما قد تكونان فارغتين،
# ولا على %USERNAME% لأن اسم مجلد الملف الشخصي قد يختلف عنه.
# الأولوية: متغير البيئة ← مجلد الملف الشخصي ← Registry.
# ملاحظة: إذا فتح المستخدم الأداة بصلاحيات حساب مدير آخر، فإن متغيرات
# البيئة ستشير لمجلد ذلك المدير - لذلك نمرّر المسارات الصحيحة كوسائط.

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
    if ($script:NoGui) { Write-Host "خطأ: $msg" -ForegroundColor Red; exit 1 }
    [System.Windows.Forms.MessageBox]::Show($msg, 'أداة تنظيف اللابتوب', 'OK', 'Error') | Out-Null
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

# التحقق من صحة المسارات - إن فشلت الأداة تتوقف بدل أن تحذف في مكان خطأ
foreach ($chk in @($PROFILE, $LOCAL, $ROAM)) {
    if ([string]::IsNullOrWhiteSpace($chk) -or $chk -notmatch '^[A-Za-z]:\\') {
        Fail "تعذّر تحديد مجلد المستخدم بشكل صحيح.`n`nالمسار غير الصالح: '$chk'`n`nلم يُحذف أي شيء."
    }
}

# سطح المكتب (للحفظ في السجل)
function Get-DesktopPath {
    if (-not [string]::IsNullOrWhiteSpace($script:TargetDesk)) { return $script:TargetDesk }
    $d = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($d) -or -not (Test-Path -LiteralPath $d)) {
        $d = Join-Path $PROFILE 'Desktop'
    }
    return $d
}
$script:TargetDesk = $TargetDesktop

# ==================== دوال مساعدة ====================
$script:FreeStart = 0.0
$script:Freed     = 0.0
$script:Cancel    = $false
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

# حجم ملف الترحيل الفعلي الشغّال على C: (ميجا) - صفر إن لم يوجد
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

# ==================== الحالة والصلاحيات ====================
$script:IsAdmin = $false
try {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                       ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# مخزن موديلات Ollama الرسمي (قد يكون على D:)
$script:OllamaStore = $TargetOllamaModels
if ([string]::IsNullOrWhiteSpace($script:OllamaStore)) { $script:OllamaStore = $env:OLLAMA_MODELS }
if ([string]::IsNullOrWhiteSpace($script:OllamaStore)) {
    try { $script:OllamaStore = (Get-ItemProperty 'HKCU:\Environment' -Name OLLAMA_MODELS -ErrorAction Stop).OLLAMA_MODELS } catch { }
}

$CPageMB = Get-CPagefileMB

# ==================== طلب صلاحيات المدير (اختياري) ====================
# الأداة تعمل بدونها لكل تنظيفات المستخدم، لكن خطوات النظام
# (نقل ملف الترحيل + تنظيف مخزن ويندوز) تحتاجها.
if (-not $script:NoGui -and -not $script:IsAdmin) {
    $pfNote = if ($CPageMB -gt 0) {
        "ونقل ملف الترحيل الذي سيحرّر ~$([math]::Round($CPageMB/1024,1)) جيجا من C:"
    } else { "وتنظيف مخزن مكونات ويندوز العميق" }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "الأداة تعمل الآن بصلاحيات عادية.`n`nكل تنظيفات الكاشات ستعمل بشكل طبيعي،`nلكن خطوات النظام $pfNote`nتحتاج صلاحيات مدير.`n`nنطلب صلاحيات المدير الآن؟`n`n(اختر «لا» للمتابعة بالتنظيف العادي فقط)",
        'أداة تنظيف اللابتوب', 'YesNo', 'Question')
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
        # رُفض طلب الصلاحيات أو فشل - نكمل بصلاحيات عادية
    }
}

# ==================== الإخراج: سجل + حالة ====================
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

# ==================== الخطوات ====================
# خيارات التشغيل (تُقرأ من مربعات الواجهة، أو افتراضات في وضع -NoGui)
$script:Opts = @{ Bin = $false; Page = $true; Docker = $false; Android = $false }

function Build-Steps {
    $steps = @(
        @{ N = 'الملفات المؤقتة للنظام والمستخدم'; F = {
            $script:Freed += Clean-Dir 'C:\Windows\Temp'                          'ملف النظام المؤقت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Temp')                   'ملف المستخدم المؤقت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'CrashDumps')             'تقارير الأعطال'
            $script:Freed += Clean-Dir 'C:\ProgramData\Microsoft\Windows\WER'    'تقارير أخطاء ويندوز'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WER')  'تقارير أخطاء المستخدم'
            $script:Freed += Clean-Dir 'C:\Windows\Logs\CBS'                      'سجلات CBS'
            $script:Freed += Clean-Dir 'C:\Windows\SoftwareDistribution\Download' 'تنزيلات تحديث ويندوز'
            $script:Freed += Clean-Dir 'C:\Windows\LiveKernelReports'             'تقارير النواة'
        } }
        @{ N = 'مخلفات Ollama الميتة'; F = {
            $modelsOnC = Join-Path $PROFILE '.ollama\models'
            $store = $script:OllamaStore
            $exists = Test-Path -LiteralPath $modelsOnC
            $orphan = $false
            if ($exists -and -not [string]::IsNullOrWhiteSpace($store) -and
                ($store.TrimEnd('\') -ne $modelsOnC.TrimEnd('\'))) {
                # المخزن الرسمي في مكان آخر (مثل D:\OllamaModels)
                # فما على C: لا يمكن أن يكون مستخدماً إلا إذا وُجدت قوائم موديلات حية عليه
                $man = Join-Path $modelsOnC 'manifests'
                $hasManifests = (Test-Path -LiteralPath $man) -and
                    ((Get-ChildItem -LiteralPath $man -Recurse -File -Force -ErrorAction SilentlyContinue |
                      Measure-Object).Count -gt 0)
                if ($hasManifests) {
                    Log '   ! وُجدت قوائم موديلات حية على C: - ننظّف التحميلات المقطوعة فقط احتياطيًا'
                } else { $orphan = $true }
            }
            if ($orphan) {
                $script:Freed += Drop-Dir $modelsOnC "موديلات Ollama اليتيمة على C: (المخزن الرسمي: $store)"
            } elseif ($exists -and (Test-Path (Join-Path $modelsOnC 'blobs'))) {
                $b = 0.0
                Get-ChildItem (Join-Path $modelsOnC 'blobs') -File -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like '*-partial*' } | ForEach-Object {
                        $b += [math]::Round($_.Length / 1MB, 1)
                        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    }
                if ($b -gt 0) { Log "   • تحميلات Ollama المقطوعة  ←  $b ميجا"; $script:Freed += $b }
                else { Log '   - لا تحميلات مقطوعة' }
            } else { Log '   - لا موديلات Ollama على C:' }
            $script:Freed += Drop-Dir (Join-Path $LOCAL 'Ollama\updates_v2') 'حزم تحديث Ollama المحمّلة (تُعاد لو لزم)'
        } }
        @{ N = 'كاشات المتصفحات (Edge / Chrome / Brave)'; F = {
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
            if ($hit -eq 0) { Log '   - لا توجد كاشات متصفحات' }
            else { Log "   ═ إجمالي كاشات المتصفحات: $([math]::Round($sum,0)) ميجا" }
            $script:Freed += $sum
        } }
        @{ N = 'كاش Notion الخلفي (Service Worker)'; F = {
            $part = Join-Path $ROAM 'Notion\Partitions\notion'
            if (Test-Path -LiteralPath $part) {
                foreach ($d in @('Service Worker','Cache','Code Cache','GPUCache',
                                 'DawnGraphiteCache','DawnWebGPUCache','Shared Dictionary',
                                 'Crashpad','blob_storage')) {
                    $script:Freed += Clean-Dir (Join-Path $part $d) "Notion: $d"
                }
                if (Get-ProcRunning @('Notion')) {
                    Log '   ! Notion مفتوح الآن - ما تعذّر مسحه سيُحرَّر عند تشغيل التنظيف وهو مغلق'
                }
            } else { Log '   - لا يوجد كاش Notion' }
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Notion\Cache')    'Notion كاش'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Notion\GPUCache')  'Notion GPUCache'
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
        @{ N = 'نسخ WPS القديمة'; F = {
            $wpsRoot = Join-Path $LOCAL 'Kingsoft\WPS Office'
            if (-not (Test-Path -LiteralPath $wpsRoot)) { Log '   - WPS غير مثبّت'; return }
            $vers = @(Get-ChildItem -LiteralPath $wpsRoot -Directory -Force -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' })
            if ($vers.Count -lt 2) { Log '   - لا نسخ قديمة'; return }
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
                if ($busy) { Log "   - نسخة $($v.Name) تعمل الآن - تُخطّت"; continue }
                $sum += Drop-Dir $v.FullName "نسخة WPS قديمة $($v.Name)"
            }
            if ($sum -gt 0) { Log "   ═ إجمالي النسخ القديمة: $([math]::Round($sum,0)) ميجا" }
            $script:Freed += $sum
        } }
        @{ N = 'مخلفات WeChat'; F = {
            $script:Freed += Drop-Dir  (Join-Path $ROAM 'Tencent\xwechat\update') 'حزم تحديث WeChat المحمّلة'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Tencent\xwechat\log')    'سجلات WeChat'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'Tencent\Logs')            'سجلات Tencent'
        } }
        @{ N = 'كاشات أدوات البرمجة'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pip\cache')                'كاش pip'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'npm-cache\_cacache')      'كاش npm'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'npm-cache\_logs')         'سجلات npm'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'pnpm-store\v3\files')    'كاش pnpm'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Yarn\Cache')              'كاش Yarn'
            $script:Freed += Clean-Dir (Join-Path $ROAM 'AutoClaw-oversea-official\toolchain\node\cache\_npx') 'كاش npx'
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
                if (Get-ProcRunning @('AnyTXT','Anytxt','anyservice','ATService')) {
                    Log '   ! Anytxt يعمل الآن - أُجّل التنظيف. أغلقه ثم أعد التشغيل.'
                } else {
                    $script:Freed += Drop-Dir 'C:\ProgramData\Anytxt\data' 'فهرس Anytxt (يُبنى تلقائياً)'
                }
            } else { Log '   - لا فهرس Anytxt' }
        } }
        @{ N = 'كاش المصغّرات وذاكرة الإنترنت'; F = {
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Explorer')  'مصغّرات الصور والأيقونات'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\INetCache') 'ذاكرة الإنترنت'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\WebCache')  'WebCache'
            $script:Freed += Clean-Dir (Join-Path $LOCAL 'Microsoft\Windows\Caches')    'كاش ويندوز'
        } }
    )

    # خطوة اختيارية: سلة المحذوفات
    if ($script:Opts.Bin) {
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

    # نقل ملف الترحيل - قبل الخطوات الطويلة حتى لا ينتظر المستخدم طويلاً
    if ($script:Opts.Page) {
        $steps += @{ N = 'نقل ملف الترحيل من C: إلى D:'; F = {
            if (-not (Test-Path 'D:\')) { Log '   ! لا يوجد درايف D: - تُخطّت'; return }
            $cMB = Get-CPagefileMB
            if ($cMB -le 0) { Log '   ✔ ملف الترحيل غير موجود على C: - مضبوط'; return }
            $cGB = [math]::Round($cMB / 1024, 1)
            if (-not $script:IsAdmin) {
                Log "   ! ملف الترحيل الفعلي يعمل من C: وحجمه $cGB جيجا"
                Log '     نقله يحتاج صلاحيات مدير - وافق على طلب الصلاحيات عند فتح الأداة'
                return
            }
            $mmKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            $ccKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'

            # هل كان الإعداد سليماً قبل الآن؟ (لتحذير أعمق لو تكررت المشكلة)
            $wasSet = $false
            try {
                $p0 = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction Stop).PagingFiles -join ' '
                $c0 = (Get-ItemProperty -Path $ccKey -Name CrashDumpEnabled -ErrorAction Stop).CrashDumpEnabled
                if ($p0 -match 'D:\\pagefile' -and $p0 -notmatch 'C:\\pagefile' -and $c0 -eq 0) { $wasSet = $true }
            } catch { }

            # 1) إغلاق الإدارة التلقائية لحجم ملف الترحيل
            try {
                $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                if ($cs.AutomaticManagedPagefile) {
                    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
                    Log '   • أُغلقت الإدارة التلقائية لحجم ملف الترحيل'
                }
            } catch { Log "   ! تعذّر إغلاق الإدارة التلقائية: $($_.Exception.Message)" }

            # 2) توجيه ملف الترحيل إلى D:
            try {
                Set-ItemProperty -Path $mmKey -Name PagingFiles -Value @('D:\pagefile.sys 8192 16384') -Type MultiString -ErrorAction Stop
                Log '   • حُدِّد ملف الترحيل على D: بحجم من 8 إلى 16 جيجا'
            } catch { Log "   ! تعذّر ضبط PagingFiles: $($_.Exception.Message)" }

            # 3) تعطيل كتابة تقارير الأعطال - هذا هو الإصلاح الجذري:
            #    ويندوز يحتاج ملف ترحيل على قرص النظام لكتابة تقارير الأعطال،
            #    فإن لم يجده أنشأ ملفاً مؤقتاً يتوسع باستمرار على C: يلتهم المساحة.
            try {
                Set-ItemProperty -Path $ccKey -Name CrashDumpEnabled -Value 0 -Type DWord -ErrorAction Stop
                Log '   • عُطِّلت كتابة تقارير الأعطال - هذا ما كان يعيد إنشاء ملف الترحيل على C:'
            } catch { Log "   ! تعذّر ضبط CrashDumpEnabled: $($_.Exception.Message)" }

            # 4) التحقق الفعلي من كل قيمة
            $okP = $false; $okC = $false
            try {
                $p1 = (Get-ItemProperty -Path $mmKey -Name PagingFiles -ErrorAction Stop).PagingFiles -join ' '
                if ($p1 -match 'D:\\pagefile' -and $p1 -notmatch 'C:\\pagefile') { $okP = $true }
            } catch { }
            try {
                if ((Get-ItemProperty -Path $ccKey -Name CrashDumpEnabled -ErrorAction Stop).CrashDumpEnabled -eq 0) { $okC = $true }
            } catch { }

            if ($okP -and $okC) {
                Log "   ✔ اكتمل الإعداد - سيُحرَّر ~$cGB جيجا من C: بعد إعادة التشغيل"
                $script:NeedReboot = $true
                $script:RebootGB  = $cGB
                if ($wasSet) {
                    Log '   ! ملاحظة: كان الإعداد سليماً من قبل ومع ذلك عاد الملف إلى C:'
                    Log '     لو تكرر ذلك بعد إعادة التشغيل القادمة فاضبطه يدوياً من:'
                    Log '     sysdm.cpl ← Advanced ← Performance/Settings ← Advanced ← Virtual Memory'
                }
            } else {
                Log '   ! لم يكتمل الإعداد - راجع رسائل الخطأ أعلاه'
            }
        } }
    }

    # خيارات إضافية: قرص Docker / Android SDK
    if ($script:Opts.Docker) {
        $steps += @{ N = 'قرص Docker الافتراضي'; F = {
            $wsl = Join-Path $LOCAL 'Docker\wsl'
            if (-not (Test-Path -LiteralPath $wsl)) { Log '   - لا يوجد قرص Docker'; return }
            if (Get-ProcRunning @('Docker Desktop','com.docker.backend','dockerd','docker')) {
                Log '   ! Docker يعمل الآن - أغلقه ثم أعد التنظيف'; return
            }
            $script:Freed += Drop-Dir $wsl 'قرص Docker (تُمسح كل الصور والحاويات)'
        } }
    }
    if ($script:Opts.Android) {
        $steps += @{ N = 'Android SDK'; F = {
            $a = Join-Path $LOCAL 'Android'
            if (-not (Test-Path -LiteralPath $a)) { Log '   - لا يوجد Android SDK'; return }
            $script:Freed += Drop-Dir $a 'Android SDK (يُعاد تنزيله من Android Studio عند الحاجة)'
        } }
    }

    # مخلفات ترقية ويندوز + DISM + أداة ويندوز الرسمية (تأتي أخيراً لأنها الأبطأ)
    $steps += @{ N = 'مخلفات تحديثات ويندوز'; F = {
        if (Test-Path 'C:\$WinREAgent') {
            $script:Freed += Drop-Dir 'C:\$WinREAgent' 'مخلفات ترقية ويندوز'
        } else { Log '   - لا مخلفات ترقية ويندوز' }

        if (-not $script:IsAdmin) {
            Log '   — تنظيف مخزن مكونات ويندوز وأداة التنظيف الرسمية يحتاجان صلاحيات مدير - تُخطَّتان'
            return
        }

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

    return $steps
}

# ==================== التشغيل الكامل ====================
function Run-All {
    $script:Freed      = 0.0
    $script:FreeStart = Get-FreeGB
    $script:NeedReboot = $false
    $t0 = Get-Date

    if (-not $script:NoGui) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    Log '════════════════════════════════════'
    Log "بدء التنظيف - $(Get-Date -Format 'HH:mm:ss')"
    Log "المساحة الحرة قبل: $script:FreeStart جيجا"
    Log '════════════════════════════════════'
    Log ''

    $steps = Build-Steps
    $i = 0
    foreach ($s in $steps) {
        if ($script:Cancel) { break }
        $i++
        $pct = [int](($i / [math]::Max($steps.Count, 1)) * 92)
        SetStatus $s.N $pct
        Log ''
        Log "▶ $($i)/$($steps.Count)  $($s.N)"
        try { & $s.F } catch { Log "   ! خطأ: $($_.Exception.Message)" }
        if (-not $script:NoGui) { [System.Windows.Forms.Application]::DoEvents() }
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

    if (-not $script:NoGui) {
        $lblFree.Text = "المساحة الحرة في C:  —  $freeEnd جيجا"
        $lblFree.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
    }

    if ($script:NeedReboot) {
        Log ''
        Log "⚠ لازم إعادة تشغيل لتحرير ~$($script:RebootGB) جيجا من C: وإتمام نقل ملف الترحيل"
        Log '  بعد إعادة التشغيل شغّل الأداة مرة أخرى للتأكد أن الملف انتقل فعلاً'
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

    if ($script:NoGui) { return }

    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    # عرض إعادة التشغيل بعد نجاح ضبط ملف الترحيل
    if ($script:NeedReboot) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "تم ضبط ملف الترحيل بنجاح.`n`nلا بد من إعادة تشغيل لتكتمل العملية`nوتُحرَّر ~$($script:RebootGB) جيجا من C:.`n`nهل نعيد تشغيل الجهاز الآن؟`n(احفظ عملك المفتوح أولاً - لديك 20 ثانية)",
            'أداة تنظيف اللابتوب', 'YesNo', 'Question')
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/r','/t','20','/c','إعادة تشغيل لإتمام نقل ملف الترحيل'
            $form.Close()
        }
    }
}

# ==================== وضع سطر الأوامر ====================
if ($script:NoGui) { Run-All; return }

# ==================== الواجهة ====================
$form                 = New-Object System.Windows.Forms.Form
$form.Text            = 'أداة تنظيف اللابتوب'
$form.Size            = New-Object System.Drawing.Size(600, 668)
$form.StartPosition   = 'CenterScreen'
$form.RightToLeft     = 'Yes'
$form.RightToLeftLayout = $true
$form.BackColor       = [System.Drawing.Color]::FromArgb(250, 250, 252)
$form.Font            = New-Object System.Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox     = $false

$title           = New-Object System.Windows.Forms.Label
$title.Text      = 'تنظيف اللابتوب'
$title.Font      = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::FromArgb(20, 30, 60)
$title.Location  = New-Object System.Drawing.Point(20, 15)
$title.Size      = New-Object System.Drawing.Size(540, 45)
$title.TextAlign = 'MiddleRight'
$form.Controls.Add($title)

$lblFree           = New-Object System.Windows.Forms.Label
$lblFree.Text      = "المساحة الحرة في C:  —  $((Get-FreeGB)) جيجا"
$lblFree.Font      = New-Object System.Drawing.Font('Segoe UI', 12)
$lblFree.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
$lblFree.Location  = New-Object System.Drawing.Point(20, 60)
$lblFree.Size      = New-Object System.Drawing.Size(540, 30)
$lblFree.TextAlign = 'MiddleRight'
$form.Controls.Add($lblFree)

$lblAdmin           = New-Object System.Windows.Forms.Label
$lblAdmin.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblAdmin.Location  = New-Object System.Drawing.Point(20, 90)
$lblAdmin.Size      = New-Object System.Drawing.Size(540, 22)
$lblAdmin.TextAlign = 'MiddleRight'
if ($script:IsAdmin) {
    $lblAdmin.Text      = '✔ يعمل بصلاحيات مدير — كل الخطوات متاحة'
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(0, 130, 60)
} else {
    $lblAdmin.Text      = '⚠ بدون صلاحيات مدير — خطوات النظام ستُخطى'
    $lblAdmin.ForeColor = [System.Drawing.Color]::FromArgb(190, 100, 0)
}
$form.Controls.Add($lblAdmin)

$lblInfo           = New-Object System.Windows.Forms.Label
$lblInfo.Text      = "ينظّف: الملفات المؤقتة، كاشات المتصفحات، مخلفات Ollama وWPS وWeChat وNotion، مخلفات المُثبِّتات، وكاشات أدوات البرمجة.`nلا يلمس: ملفاتك الشخصية، المفضلة، كلمات المرور، أو إعداداتك."
$lblInfo.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
$lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 120)
$lblInfo.Location  = New-Object System.Drawing.Point(20, 114)
$lblInfo.Size      = New-Object System.Drawing.Size(540, 40)
$lblInfo.TextAlign = 'MiddleRight'
$form.Controls.Add($lblInfo)

$chkBin           = New-Object System.Windows.Forms.CheckBox
$chkBin.Text      = 'تفريغ سلة المحذوفات أيضًا'
$chkBin.Location  = New-Object System.Drawing.Point(20, 158)
$chkBin.Size      = New-Object System.Drawing.Size(540, 26)
$chkBin.Checked   = $false
$chkBin.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkBin)

$chkPage           = New-Object System.Windows.Forms.CheckBox
if ($CPageMB -gt 0) {
    $chkPage.Text = "نقل ملف الترحيل من C: إلى D:  (يحرّر ~$([math]::Round($CPageMB/1024,1)) جيجا بعد إعادة التشغيل)"
} else {
    $chkPage.Text = 'ملف الترحيل مضبوط على D: بالفعل ✔'
}
$chkPage.Location  = New-Object System.Drawing.Point(20, 184)
$chkPage.Size      = New-Object System.Drawing.Size(540, 26)
$chkPage.Checked   = $true
$chkPage.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkPage)

$chkDocker           = New-Object System.Windows.Forms.CheckBox
$chkDocker.Text      = 'مسح قرص Docker الافتراضي (يمسح كل الصور والحاويات) — ~5 جيجا'
$chkDocker.Location  = New-Object System.Drawing.Point(20, 210)
$chkDocker.Size      = New-Object System.Drawing.Size(540, 26)
$chkDocker.Checked   = $false
$chkDocker.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkDocker)

$chkAndroid           = New-Object System.Windows.Forms.CheckBox
$chkAndroid.Text      = 'مسح Android SDK (يُعاد تنزيله من Android Studio عند الحاجة) — ~2 جيجا'
$chkAndroid.Location  = New-Object System.Drawing.Point(20, 236)
$chkAndroid.Size      = New-Object System.Drawing.Size(540, 26)
$chkAndroid.Checked   = $false
$chkAndroid.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 70)
$form.Controls.Add($chkAndroid)

$bar           = New-Object System.Windows.Forms.ProgressBar
$bar.Location  = New-Object System.Drawing.Point(20, 266)
$bar.Size      = New-Object System.Drawing.Size(540, 24)
$bar.Style     = 'Continuous'
$bar.Minimum   = 0
$bar.Maximum   = 100
$bar.Value     = 0
$form.Controls.Add($bar)

$lblStatus           = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'جاهز. اضغط الزر للبدء.'
$lblStatus.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(30, 90, 180)
$lblStatus.Location  = New-Object System.Drawing.Point(20, 294)
$lblStatus.Size      = New-Object System.Drawing.Size(540, 26)
$lblStatus.TextAlign = 'MiddleRight'
$form.Controls.Add($lblStatus)

$log              = New-Object System.Windows.Forms.TextBox
$log.Location     = New-Object System.Drawing.Point(20, 324)
$log.Size         = New-Object System.Drawing.Size(540, 230)
$log.Multiline    = $true
$log.ReadOnly     = $true
$log.ScrollBars   = 'Vertical'
$log.Font         = New-Object System.Drawing.Font('Segoe UI', 9)
$log.BackColor    = [System.Drawing.Color]::White
$log.RightToLeft  = 'Yes'
$form.Controls.Add($log)

$btnStart           = New-Object System.Windows.Forms.Button
$btnStart.Text      = 'ابدأ التنظيف الآن'
$btnStart.Location  = New-Object System.Drawing.Point(60, 562)
$btnStart.Size      = New-Object System.Drawing.Size(280, 50)
$btnStart.Font      = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = 'Flat'
$form.Controls.Add($btnStart)

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = 'إغلاق'
$btnClose.Location = New-Object System.Drawing.Point(360, 562)
$btnClose.Size     = New-Object System.Drawing.Size(180, 50)
$btnClose.Font     = New-Object System.Drawing.Font('Segoe UI', 11)
$btnClose.FlatStyle = 'Flat'
$form.Controls.Add($btnClose)

$btnClose.Add_Click({ $form.Close() })

$btnStart.Add_Click({
    $btnStart.Enabled  = $false
    $chkBin.Enabled    = $false
    $chkPage.Enabled   = $false
    $chkDocker.Enabled = $false
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
    $btnStart.Text      = 'تنظيف مرة أخرى'
})

$form.Add_FormClosing({ $script:Cancel = $true })

[void]$form.ShowDialog()
