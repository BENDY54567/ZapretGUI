[System.Reflection.Assembly]::LoadWithPartialName("PresentationFramework") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("PresentationCore") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("WindowsBase") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null

# Update.ps1 — обновляет УЖЕ УСТАНОВЛЕННУЮ программу из этой (новой) сборки.
# Запускать нужно из свежего распакованного архива новой версии (рядом должны лежать Update.bat,
# Install.bat и папка с service.bat и zapret_gui_v3.ps1). Работает и с закрытой (скрытой) папкой программы.

$SelfPath = $MyInvocation.MyCommand.Path
if (-not $SelfPath) { $SelfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
$RootDir = Split-Path -Parent $SelfPath
$script:BuildToolsPath = Join-Path $RootDir "BuildTools.ps1"

# Нужны права администратора: закрытая папка программы доступна только им
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($SelfPath -like "*.ps1") {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SelfPath`""
    } else {
        Start-Process -FilePath $SelfPath -Verb RunAs
    }
    exit
}

function Find-ZapretDir {
    param([string]$BaseDir)
    if ((-not $BaseDir) -or (-not (Test-Path -LiteralPath $BaseDir))) { return $null }
    if (Test-Path -LiteralPath (Join-Path $BaseDir "service.bat")) { return $BaseDir }
    # -Force: после установки папка программы скрыта
    $sub = Get-ChildItem -LiteralPath $BaseDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "service.bat") } |
        Select-Object -First 1
    if ($sub) { return $sub.FullName }
    return $null
}

$script:SrcDir  = Find-ZapretDir -BaseDir $RootDir   # папка НОВОЙ сборки (источник)
$script:DstDir  = $null                               # установленная папка с service.bat
$script:DstRoot = $null                               # папка, где лежит ZapretGUI.exe
$script:ExePath = $null
$script:Done = $false
$script:HadErrors = $false

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Обновление Zapret" Width="500" Height="740"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0B0B12" FontFamily="Segoe UI">
    <StackPanel Margin="28,24">
        <StackPanel Orientation="Horizontal">
            <Border Width="44" Height="44" CornerRadius="22">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="&#8593;" FontSize="22" FontWeight="Bold" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Обновление Zapret" Foreground="White" FontSize="20" FontWeight="Bold"/>
                <TextBlock Text="Из этой новой сборки в уже установленную программу" Foreground="#8A8A99" FontSize="12"/>
            </StackPanel>
        </StackPanel>

        <Border Background="#12121B" CornerRadius="10" Margin="0,18,0,0" Padding="14,12">
            <StackPanel>
                <TextBlock Text="УСТАНОВЛЕННАЯ ПРОГРАММА" Foreground="Gray" FontSize="10.5"/>
                <Grid Margin="0,6,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBox x:Name="txtTarget" Grid.Column="0" Height="30" Background="#1B1B27" Foreground="White" BorderThickness="0" Padding="8,5" IsReadOnly="True" FontSize="12"/>
                    <Button x:Name="btnBrowse" Grid.Column="1" Content="Выбрать…" Height="30" Margin="8,0,0,0" Background="#1B1B27" Foreground="#D8D8E0" BorderThickness="0" Padding="12,0" Cursor="Hand"/>
                </Grid>
                <TextBlock x:Name="txtVersions" Text="" Foreground="#B7B7C2" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>
            </StackPanel>
        </Border>

        <TextBlock Text="На время обновления защита и программа будут остановлены. Ваши настройки, пользовательские списки, плейлист и ключ сохранятся. Защита включится сама при первом запуске новой версии программы." Foreground="#5E5E6B" FontSize="11" TextWrapping="Wrap" Margin="0,12,0,0"/>

        <TextBox x:Name="logBox" Height="210" Margin="0,14,0,0" IsReadOnly="True" Background="#12121B" Foreground="#B7B7C2" BorderThickness="0" Padding="10,8" FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>

        <Border Width="444" Height="8" CornerRadius="4" Background="#1B1B27" Margin="0,16,0,0" HorizontalAlignment="Left">
            <Border x:Name="progressFill" Width="0" HorizontalAlignment="Left" CornerRadius="4">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
        </Border>
        <TextBlock x:Name="statusText" Text="" Foreground="#8A8A99" FontSize="12" Margin="0,8,0,0" TextWrapping="Wrap"/>

        <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
            <Button x:Name="btnUpdate" Content="Обновить" Width="200" Height="46" Foreground="White" BorderThickness="0" FontSize="14" Cursor="Hand" IsEnabled="False">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnClose" Content="Закрыть" Width="110" Height="46" Margin="10,0,0,0" Background="#1B1B27" Foreground="White" BorderThickness="0" FontSize="14" Cursor="Hand"/>
        </StackPanel>
    </StackPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$txtTarget = $window.FindName("txtTarget")
$btnBrowse = $window.FindName("btnBrowse")
$txtVersions = $window.FindName("txtVersions")
$logBox = $window.FindName("logBox")
$progressFill = $window.FindName("progressFill")
$statusText = $window.FindName("statusText")
$btnUpdate = $window.FindName("btnUpdate")
$btnClose = $window.FindName("btnClose")

function Write-Log {
    param([string]$Message)
    $logBox.AppendText($Message + "`r`n")
    $logBox.ScrollToEnd()
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

function Set-Progress {
    param([int]$Percent)
    $p = [Math]::Max(0, [Math]::Min(100, $Percent))
    $progressFill.Width = $p * 4.44
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# ---------------- права папки: проверка и закрытие (тот же код, что в программе) ----------------
function Test-ZapretFolderLocked {
    param([string]$Dir)
    try {
        $acl = Get-Acl -LiteralPath $Dir -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $broad = @("S-1-5-32-545", "S-1-1-0", "S-1-5-11")   # Пользователи, Все, Прошедшие проверку
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        foreach ($r in $rules) {
            if (($r.AccessControlType -eq "Allow") -and ($broad -contains $r.IdentityReference.Value)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Lock-ZapretFolder {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return "Папка программы не найдена." }
    $open = @((Join-Path $Dir "lists"), (Join-Path $Dir "assets\playlist"))
    foreach ($d in $open) {
        if (-not (Test-Path -LiteralPath $d)) { try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch {} }
    }
    # 1) сначала полный доступ системе и администраторам — пока наследование включено, доступ не пропадает ни на миг
    $out = & icacls.exe $Dir /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" 2>&1
    if ($LASTEXITCODE -ne 0) { return "Не удалось изменить права папки (нужен запуск от имени администратора). $($out -join ' ')" }
    # 2) убираем унаследованные права, в том числе у группы "Пользователи"
    $out = & icacls.exe $Dir /inheritance:r 2>&1
    if ($LASTEXITCODE -ne 0) { return "Не удалось отключить наследование прав. $($out -join ' ')" }
    # 3) обычным пользователям оставляем только lists и плейлист (чтение и запись)
    $failed = @()
    foreach ($d in $open) {
        $out = & icacls.exe $d /grant "*S-1-5-32-545:(OI)(CI)M" 2>&1
        if ($LASTEXITCODE -ne 0) { $failed += $d }
    }
    # 4) скрываем папку (атрибуты "Скрытый" + "Системный")
    try {
        $it = Get-Item -LiteralPath $Dir -Force
        $it.Attributes = [System.IO.FileAttributes]([int]$it.Attributes -bor 6)
    } catch {}
    if ($failed.Count -gt 0) { return "Папка закрыта, но не удалось открыть доступ к: " + ($failed -join ", ") }
    return "Готово: папка скрыта и закрыта от обычных пользователей. Доступны: lists и плейлист."
}

# ---------------- вспомогательное ----------------
function Get-ZapretVersion {
    param([string]$Dir)
    try {
        $m = [regex]::Match((Get-Content -LiteralPath (Join-Path $Dir "service.bat") -Raw -ErrorAction Stop), 'set\s+"LOCAL_VERSION=([^"]+)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch {}
    return "?"
}

# Установленную программу ищем по ярлыку на рабочем столе (его создаёт установщик)
function Find-InstalledRoot {
    foreach ($desk in @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"))) {
        if (-not $desk) { continue }
        $lnk = Join-Path $desk "Zapret.lnk"
        if (-not (Test-Path -LiteralPath $lnk)) { continue }
        try {
            $sh = New-Object -ComObject WScript.Shell
            $target = $sh.CreateShortcut($lnk).TargetPath
            if ($target -and (Test-Path -LiteralPath $target)) {
                $root = Split-Path -Parent $target
                if (Find-ZapretDir -BaseDir $root) { return $root }
            }
        } catch {}
    }
    return $null
}

# Принимает папку с ZapretGUI.exe (или саму папку с service.bat). Возвращает текст ошибки или $null.
function Resolve-Target {
    param([string]$Path)
    if ((-not $Path) -or (-not (Test-Path -LiteralPath $Path))) { return "Папка не найдена." }
    $dir = Find-ZapretDir -BaseDir $Path
    if (-not $dir) { return "В выбранной папке нет установленной программы (не найдена папка с service.bat). Выберите папку, где лежит ZapretGUI.exe." }
    $root = $Path
    if (Test-Path -LiteralPath (Join-Path $Path "service.bat")) { $root = Split-Path -Parent $Path }   # выбрали саму папку zapret
    if ($script:SrcDir) {
        $a = [System.IO.Path]::GetFullPath($dir).TrimEnd('\')
        $b = [System.IO.Path]::GetFullPath($script:SrcDir).TrimEnd('\')
        if ($a -ieq $b) { return "Это папка НОВОЙ сборки, из которой запущено обновление. Выберите папку, куда программа уже установлена." }
    }
    $script:DstRoot = $root
    $script:DstDir = $dir
    return $null
}

function Update-TargetInfo {
    if ($script:DstDir) {
        $txtTarget.Text = $script:DstRoot
        $old = Get-ZapretVersion -Dir $script:DstDir
        $new = "?"
        if ($script:SrcDir) { $new = Get-ZapretVersion -Dir $script:SrcDir }
        $txtVersions.Text = "Установлена версия: $old     →     новая: $new"
        $btnUpdate.IsEnabled = $true
    } else {
        $txtTarget.Text = ""
        $txtVersions.Text = "Установленная программа не найдена автоматически. Нажмите «Выбрать…» и укажите папку, где лежит ZapretGUI.exe."
        $btnUpdate.IsEnabled = $false
    }
}

# Новая сборка должна быть полной; иначе обновление может сломать установленную
function Test-Source {
    if (-not $script:SrcDir) { return "Не найдена папка новой сборки рядом с этим файлом. Запускайте обновление из распакованного нового архива." }
    if (-not (Test-Path -LiteralPath (Join-Path $script:SrcDir "zapret_gui_v3.ps1"))) { return "В этой папке нет zapret_gui_v3.ps1 — похоже, это уже установленная копия. Запускайте обновление из свежего распакованного архива новой версии." }
    if (-not (Test-Path -LiteralPath (Join-Path $script:SrcDir "bin\winws.exe"))) { return "В новой сборке нет bin\winws.exe — архив распакован не полностью." }
    $cnt = @(Get-ChildItem -LiteralPath $script:SrcDir -File -Filter "general*.bat" -Force -ErrorAction SilentlyContinue).Count
    if ($cnt -lt 1) { return "В новой сборке нет файлов стратегий general*.bat." }
    return $null
}

# Какая стратегия установлена как служба (service.bat пишет её имя в реестр)
function Get-InstalledStrategy {
    param([string]$Dir)
    $name = ""
    try {
        $v = (Get-ItemProperty -Path "HKLM:\System\CurrentControlSet\Services\zapret" -Name "zapret-discord-youtube" -ErrorAction Stop)."zapret-discord-youtube"
        if ($v) { $name = [string]$v }
    } catch {}
    if (-not $name) {
        try {
            $f = Join-Path (Join-Path $Dir "utils") "gui_active_strategy.txt"
            if (Test-Path -LiteralPath $f) { $name = (Get-Content -LiteralPath $f -Raw -ErrorAction Stop).Trim() }
        } catch {}
    }
    return $name.Trim()
}

# sc.exe с таймаутом: Stop-Service на этой службе может зависать
function Invoke-ScQuick {
    param([string]$ScArgs, [int]$TimeoutMs = 8000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "sc.exe"
        $psi.Arguments = $ScArgs
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
    } catch {}
}

function Stop-ZapretForUpdate {
    Get-Process -Name "ZapretGUI" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Get-Service -Name "zapret" -ErrorAction SilentlyContinue) {
        Invoke-ScQuick -ScArgs "stop zapret"
        Invoke-ScQuick -ScArgs "delete zapret"
    }
    foreach ($drv in @("WinDivert", "WinDivert14")) {
        if (Get-Service -Name $drv -ErrorAction SilentlyContinue) {
            Invoke-ScQuick -ScArgs "stop $drv"
            Invoke-ScQuick -ScArgs "delete $drv"
        }
    }
    Start-Sleep -Milliseconds 900
}

# Что делать с файлом новой сборки (путь относительно папки с service.bat):
#   skip      — не копировать (скрипт интерфейса и сборщик: из них собирается exe)
#   ifmissing — копировать только если у пользователя такого файла ещё нет (его настройки и данные)
#   update    — заменить, если содержимое отличается
function Get-UpdateAction {
    param([string]$Rel)
    $r = $Rel.ToLowerInvariant()
    if (($r -eq "zapret_gui_v3.ps1") -or ($r -eq "build-exe.bat")) { return "skip" }
    if ($r -like ".git*") { return "skip" }
    if (($r -like "utils\*") -and ($r -notlike "*.ps1")) { return "ifmissing" }          # флаги: game_filter.enabled, license.dat и т.п.
    if (($r -eq "lists\ipset-all.txt") -or ($r -eq "lists\ipset-all.txt.backup")) { return "ifmissing" }   # режим ipset пользователя
    if ($r -like "assets\*") { return "ifmissing" }                                        # плейлист и ресурсы
    return "update"
}

function Sync-ZapretFiles {
    param([string]$Src, [string]$Dst)
    $stat = @{ Updated = 0; Added = 0; Same = 0; Kept = 0; Failed = @(); Removed = @() }
    $srcFull = [System.IO.Path]::GetFullPath($Src).TrimEnd('\')
    foreach ($f in (Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($srcFull.Length + 1)
        $action = Get-UpdateAction -Rel $rel
        if ($action -eq "skip") { continue }
        $dstPath = Join-Path $Dst $rel
        $exists = Test-Path -LiteralPath $dstPath
        if (($action -eq "ifmissing") -and $exists) { $stat.Kept++; continue }
        if ($exists) {
            $same = $false
            try {
                $di = Get-Item -LiteralPath $dstPath -Force
                if ($di.Length -eq $f.Length) {
                    $same = ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $dstPath -Algorithm SHA256).Hash)
                }
            } catch {}
            if ($same) { $stat.Same++; continue }
        }
        try {
            $dstDir = Split-Path -Parent $dstPath
            if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            if ($exists) { (Get-Item -LiteralPath $dstPath -Force).IsReadOnly = $false }
            Copy-Item -LiteralPath $f.FullName -Destination $dstPath -Force -ErrorAction Stop
            if ($exists) { $stat.Updated++; Write-Log ("  обновлён: " + $rel) }
            else { $stat.Added++; Write-Log ("  добавлен: " + $rel) }
        } catch {
            $stat.Failed += $rel
            Write-Log ("  НЕ УДАЛОСЬ: " + $rel + " — " + $_.Exception.Message)
        }
    }

    # Стратегии, которых в новой версии больше нет, убираем — иначе они остались бы в списке программы.
    # (Только general*.bat в корне папки; пользовательские файлы с другими именами не трогаем.)
    $srcNames = @(Get-ChildItem -LiteralPath $Src -File -Filter "general*.bat" -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($srcNames.Count -ge 1) {
        foreach ($old in (Get-ChildItem -LiteralPath $Dst -File -Filter "general*.bat" -Force -ErrorAction SilentlyContinue)) {
            if ($srcNames -notcontains $old.Name) {
                try {
                    Remove-Item -LiteralPath $old.FullName -Force -ErrorAction Stop
                    $stat.Removed += $old.Name
                    Write-Log ("  удалена устаревшая стратегия: " + $old.Name)
                } catch {}
            }
        }
    }
    return $stat
}

function Invoke-Update {
    $src = $script:SrcDir
    $dst = $script:DstDir
    $dstRoot = $script:DstRoot
    $oldVer = Get-ZapretVersion -Dir $dst
    $newVer = Get-ZapretVersion -Dir $src

    Set-Progress -Percent 3
    Write-Log ("Обновление: {0}  →  {1}" -f $oldVer, $newVer)
    Write-Log ("Папка установки: " + $dstRoot)
    try {
        if ([version]$newVer -lt [version]$oldVer) { Write-Log "ВНИМАНИЕ: устанавливается более СТАРАЯ версия, чем текущая." }
    } catch {}

    $wasLocked = Test-ZapretFolderLocked -Dir $dst
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    $wasRunning = [bool](Get-Process -Name "winws" -ErrorAction SilentlyContinue) -or ($svc -and ($svc.Status -eq "Running"))
    $strategy = Get-InstalledStrategy -Dir $dst
    if ($wasRunning) { Write-Log ("Защита сейчас включена" + $(if ($strategy) { ": " + $strategy } else { "" })) }

    Set-Progress -Percent 10
    Write-Log "Останавливаю защиту и закрываю программу..."
    Stop-ZapretForUpdate

    Set-Progress -Percent 22
    Write-Log "Копирую файлы новой версии..."
    $stat = Sync-ZapretFiles -Src $src -Dst $dst
    Write-Log ("Итог: обновлено {0}, добавлено {1}, без изменений {2}, сохранено ваших {3}, удалено устаревших стратегий {4}." -f $stat.Updated, $stat.Added, $stat.Same, $stat.Kept, $stat.Removed.Count)
    if ($stat.Failed.Count -gt 0) {
        $script:HadErrors = $true
        Write-Log ("ВНИМАНИЕ: не удалось заменить файлов: " + $stat.Failed.Count + " (возможно, они заняты другой программой).")
    }
    Set-Progress -Percent 45

    # Просим новую версию программы включить прежнюю стратегию при первом запуске
    if ($wasRunning -and $strategy) {
        try {
            $utilsDir = Join-Path $dst "utils"
            if (-not (Test-Path -LiteralPath $utilsDir)) { New-Item -ItemType Directory -Path $utilsDir -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $utilsDir "gui_restore_after_update.txt") -Value $strategy -Encoding UTF8 -Force
            Write-Log "Прежняя стратегия будет включена при запуске программы."
        } catch { Write-Log ("Не удалось сохранить прежнюю стратегию: " + $_.Exception.Message) }
    }

    # ---- пересборка ZapretGUI.exe из новой версии интерфейса ----
    Write-Log "Проверка модуля ps2exe..."
    try {
        if (-not (Test-Path -LiteralPath $script:BuildToolsPath)) { throw "не найден файл BuildTools.ps1 рядом с Update.ps1" }
        . $script:BuildToolsPath
        $tick = { $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null }
        $ps2exeRef = Find-Ps2exe -RootDir $RootDir
        if (-not $ps2exeRef) {
            Write-Log "Модуль не установлен, скачиваю напрямую (не дольше 90 сек)..."
            $dl = Get-Ps2exe -TimeoutSec 90 -OnTick $tick -OnProgress { param($sec) Write-Log ("  ...скачивание идёт, прошло $sec с") }
            if (-not $dl.Ok) {
                $why = if ($dl.TimedOut) { "таймаут 90 секунд (нет интернета?)" } else { $dl.Output }
                throw ("не удалось скачать ps2exe: " + $why)
            }
            $ps2exeRef = Find-Ps2exe -RootDir $RootDir
            if (-not $ps2exeRef) { throw "ps2exe скачан, но не найден" }
        }
        Set-Progress -Percent 60

        $guiScript = Join-Path $src "zapret_gui_v3.ps1"
        $tmpExe = Join-Path $dstRoot "ZapretGUI.update.exe"
        $exePath = Join-Path $dstRoot "ZapretGUI.exe"
        Remove-Item -LiteralPath $tmpExe -Force -ErrorAction SilentlyContinue
        Write-Log "Сборка новой версии программы..."
        $iconFile = Join-Path $src "assets\zapret.ico"
        $bld = Build-ZapretExe -Ps2exeRef $ps2exeRef -InputFile $guiScript -OutputFile $tmpExe -IconFile $iconFile -TimeoutSec 240 -OnTick $tick -OnProgress { param($sec) Write-Log ("  ...идёт сборка, прошло $sec с") }
        if (-not $bld.Ok) {
            $why = if ($bld.TimedOut) { "сборка не уложилась в 240 секунд" } else { $bld.Output }
            throw $why
        }
        if (-not (Test-Path -LiteralPath $tmpExe)) { throw "Файл программы не был создан." }
        Move-Item -LiteralPath $tmpExe -Destination $exePath -Force -ErrorAction Stop
        $script:ExePath = $exePath
        Write-Log ("Готово: " + $exePath)
    } catch {
        $script:HadErrors = $true
        Write-Log ("ОШИБКА пересборки программы: " + $_.Exception.Message)
        Write-Log "Файлы zapret обновлены, но сама программа осталась прежней версии."
        $old = Join-Path $dstRoot "ZapretGUI.exe"
        if (Test-Path -LiteralPath $old) { $script:ExePath = $old }
    }
    Set-Progress -Percent 85

    # ярлык: создаём, только если его ещё нет
    try {
        $hasLnk = (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath("Desktop")) "Zapret.lnk")) -or (Test-Path -LiteralPath (Join-Path ([Environment]::GetFolderPath("CommonDesktopDirectory")) "Zapret.lnk"))
        if ((-not $hasLnk) -and $script:ExePath) {
            $sh = New-Object -ComObject WScript.Shell
            $lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "Zapret.lnk"))
            $lnk.TargetPath = $script:ExePath
            $lnk.WorkingDirectory = $dstRoot
            $lnk.Description = "Zapret GUI BETA"
            $lnk.IconLocation = $script:ExePath + ",0"
            $lnk.Save()
            Write-Log "Ярлык на рабочем столе создан."
        }
    } catch {}

    # если папка была закрыта — подтверждаем защиту заново (новые файлы наследуют права, но на всякий случай)
    if ($wasLocked) {
        Write-Log "Возвращаю защиту папки программы..."
        Write-Log (Lock-ZapretFolder -Dir $dst)
    }

    Set-Progress -Percent 100
    return $true
}

# ---------------- обработчики ----------------
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "Выберите папку, где установлена программа (там лежит ZapretGUI.exe)"
    $dlg.ShowNewFolderButton = $false
    if ($script:DstRoot) { $dlg.SelectedPath = $script:DstRoot }
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $err = Resolve-Target -Path $dlg.SelectedPath
        if ($err) { Write-Log $err }
        Update-TargetInfo
    }
})

$btnClose.Add_Click({ $window.Close() })

$btnUpdate.Add_Click({
    if ($script:Done) {
        try { if ($script:ExePath -and (Test-Path -LiteralPath $script:ExePath)) { Start-Process -FilePath $script:ExePath -Verb RunAs -WorkingDirectory $script:DstRoot } } catch {}
        $window.Close()
        return
    }
    $srcErr = Test-Source
    if ($srcErr) { Write-Log ("ОШИБКА: " + $srcErr); return }
    if (-not $script:DstDir) { Write-Log "ОШИБКА: не выбрана установленная программа."; return }

    $ask = [System.Windows.MessageBox]::Show("Защита и программа будут остановлены на время обновления. Продолжить?", "Обновление Zapret", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ask -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $btnUpdate.IsHitTestVisible = $false
    $btnUpdate.Opacity = 0.5
    $btnBrowse.IsEnabled = $false
    $btnClose.IsEnabled = $false
    $ok = $false
    try {
        $ok = [bool](Invoke-Update)
    } catch {
        Write-Log ("ОШИБКА: " + $_.Exception.Message)
    } finally {
        $btnBrowse.IsEnabled = $true
        $btnClose.IsEnabled = $true
        $btnUpdate.IsHitTestVisible = $true
        $btnUpdate.Opacity = 1
    }
    if ($ok) {
        $script:Done = $true
        Write-Log ""
        if ($script:HadErrors) {
            Write-Log "ОБНОВЛЕНИЕ ЗАВЕРШЕНО С ЗАМЕЧАНИЯМИ — см. строки выше."
            $statusText.Text = "Готово, но есть замечания (см. журнал)."
        } else {
            Write-Log "ОБНОВЛЕНИЕ ЗАВЕРШЕНО."
            $statusText.Text = "Готово. Запустите программу — защита включится сама."
        }
        $btnUpdate.Content = "Запустить Zapret"
        $btnBrowse.IsEnabled = $false
    } else {
        $statusText.Text = "Обновление не выполнено — см. журнал."
    }
})

$window.Add_ContentRendered({
    $srcErr = Test-Source
    if ($srcErr) {
        Write-Log ("ОШИБКА: " + $srcErr)
    } else {
        $auto = Find-InstalledRoot
        if ($auto) {
            $err = Resolve-Target -Path $auto
            if ($err) { Write-Log $err }
        }
    }
    Update-TargetInfo
})

[void]$window.ShowDialog()
