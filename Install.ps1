[System.Reflection.Assembly]::LoadWithPartialName("PresentationFramework") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("PresentationCore") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("WindowsBase") | Out-Null

function Get-SelfPath {
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) { return $PSCommandPath }
    return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$SelfPath = Get-SelfPath
$RootDir  = Split-Path -Parent $SelfPath

# Установщику нужны права администратора: он меняет права на папку программы
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
    param($BaseDir)
    if (Test-Path (Join-Path $BaseDir "service.bat")) { return $BaseDir }
    $sub = Get-ChildItem -LiteralPath $BaseDir -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "service.bat") } | Select-Object -First 1
    if ($sub) { return $sub.FullName }
    return $null
}

$ZapretDir = Find-ZapretDir -BaseDir $RootDir
$ExeOutput = Join-Path $RootDir "ZapretGUI.exe"

# Общий код сборки (поиск ps2exe, скачивание с таймаутом, запасной вариант без ps2exe)
$buildTools = Join-Path $RootDir "BuildTools.ps1"
if (-not (Test-Path -LiteralPath $buildTools)) {
    [System.Windows.MessageBox]::Show("Не найден файл BuildTools.ps1 рядом с установщиком.`n`nРаспакуйте архив целиком и запустите Install.bat снова.", "Zapret — установка") | Out-Null
    exit
}
. $buildTools

# ---------------------------------------------------------------
# XAML — интерфейс установщика в стиле основного приложения
# ---------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Установка Zapret" Width="500" Height="650"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="#0B0B12" FontFamily="Segoe UI">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1" ScaleY="1"/>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Trigger.EnterActions>
                        <BeginStoryboard>
                            <Storyboard>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleX" To="1.04" Duration="0:0:0.12"/>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleY" To="1.04" Duration="0:0:0.12"/>
                                <DoubleAnimation Storyboard.TargetProperty="Opacity" To="0.88" Duration="0:0:0.12"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </Trigger.EnterActions>
                    <Trigger.ExitActions>
                        <BeginStoryboard>
                            <Storyboard>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleX" To="1" Duration="0:0:0.15"/>
                                <DoubleAnimation Storyboard.TargetProperty="RenderTransform.ScaleY" To="1" Duration="0:0:0.15"/>
                                <DoubleAnimation Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.15"/>
                            </Storyboard>
                        </BeginStoryboard>
                    </Trigger.ExitActions>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <StackPanel Margin="28">
        <StackPanel Orientation="Horizontal">
            <Border Width="42" Height="42" CornerRadius="21">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
                <TextBlock Text="&#9889;" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Установка Zapret GUI" FontSize="19" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Соберёт готовое приложение и ярлык на рабочем столе" FontSize="11.5" Foreground="#8A8A99" Margin="0,2,0,0"/>
            </StackPanel>
        </StackPanel>

        <Border Background="#12121B" CornerRadius="10" Margin="0,22,0,0" Height="210">
            <ScrollViewer x:Name="logScroll" VerticalScrollBarVisibility="Auto" Padding="16,14">
                <TextBox x:Name="logBox" Background="Transparent" Foreground="#9BE38A" FontFamily="Consolas" FontSize="12"
                         BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"/>
            </ScrollViewer>
        </Border>

        <Border x:Name="progressTrack" Height="7" Width="444" Background="#1B1B27" CornerRadius="4" Margin="0,18,0,0" HorizontalAlignment="Left">
            <Border x:Name="progressFill" Width="0" HorizontalAlignment="Left" CornerRadius="4">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
        </Border>

        <TextBlock x:Name="statusIcon" Text="&#10003;" FontSize="30" Foreground="#00E28A"
                   HorizontalAlignment="Center" Margin="0,14,0,0" Opacity="0"/>

        <CheckBox x:Name="chkDesktop" IsChecked="True" Margin="0,16,0,0">
            <TextBlock Text="Создать ярлык на рабочем столе" TextWrapping="Wrap" Width="420" FontSize="12" Foreground="#B4B4C2"/>
        </CheckBox>

        <CheckBox x:Name="chkLockFolder" IsChecked="True" Margin="0,10,0,0">
            <TextBlock Text="Закрыть папку программы от обычных пользователей (списки и плейлист останутся доступны)" TextWrapping="Wrap" Width="420" FontSize="12" Foreground="#B7B7C2"/>
        </CheckBox>

        <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
            <Button x:Name="btnInstall" Content="Установить" Width="220" Height="44" Foreground="White" BorderThickness="0" FontSize="14.5" Margin="0,0,12,0">
                <Button.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#8E44E0" Offset="0"/>
                        <GradientStop Color="#E63950" Offset="1"/>
                    </LinearGradientBrush>
                </Button.Background>
            </Button>
            <Button x:Name="btnClose" Content="Закрыть" Width="160" Height="44" Background="#1B1B27" Foreground="White" BorderThickness="0" FontSize="14.5"/>
        </StackPanel>
    </StackPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$logBox = $window.FindName("logBox")
$logScroll = $window.FindName("logScroll")
$progressFill = $window.FindName("progressFill")
$statusIcon = $window.FindName("statusIcon")
$btnInstall = $window.FindName("btnInstall")
$btnClose = $window.FindName("btnClose")
$chkLockFolder = $window.FindName("chkLockFolder")
$chkDesktop = $window.FindName("chkDesktop")

function Write-Log {
    param([string]$Text)
    $logBox.Text += "$Text`r`n"
    $logBox.CaretIndex = $logBox.Text.Length
    $logBox.ScrollToEnd()
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

function Set-Progress {
    param([double]$Percent)
    $targetWidth = [Math]::Round(444 * ($Percent / 100))
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.To = $targetWidth
    $anim.Duration = [TimeSpan]::FromMilliseconds(450)
    $anim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $anim.EasingFunction.EasingMode = "EaseOut"
    $progressFill.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $anim)
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

# ---------------- Защита папки программы ----------------
# Закрывает папку zapret от обычных пользователей Windows и скрывает её, но оставляет доступ к спискам (lists)
# и плейлисту (assets\playlist). Это защита от случайного захода, а не от опытного пользователя-администратора:
# Проводник предложит ему "Продолжить" и откроет папку после подтверждения UAC.
# До вложенных папок можно добраться по полному пути, даже если родительскую открыть нельзя:
# право "Обход перекрёстной проверки" включено у всех пользователей по умолчанию.
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

$script:Installed = $false
$script:Aborting = $false
$window.Add_Closing({ $script:Aborting = $true })

$btnClose.Add_Click({ $window.Close() })

$btnInstall.Add_Click({
  try {
    if ($script:Installed) {
        Start-Process -FilePath $ExeOutput -Verb RunAs -WorkingDirectory $RootDir
        $window.Close()
        return
    }

    $btnInstall.IsHitTestVisible = $false
    $btnInstall.Opacity = 0.6
    Set-Progress -Percent 5
    Write-Log "Поиск папки zapret..."

    if (-not $ZapretDir) {
        Write-Log "ОШИБКА: папка с service.bat не найдена рядом с установщиком."
        $btnInstall.IsHitTestVisible = $true
        $btnInstall.Opacity = 1
        return
    }
    Write-Log "Найдено: $ZapretDir"

    $guiScript = Join-Path $ZapretDir "zapret_gui_v3.ps1"
    if (-not (Test-Path $guiScript)) {
        Write-Log "ОШИБКА: не найден файл интерфейса zapret_gui_v3.ps1 внутри папки."
        $btnInstall.IsHitTestVisible = $true
        $btnInstall.Opacity = 1
        return
    }

    Set-Progress -Percent 15
    $iconFile = Join-Path $ZapretDir "assets\zapret.ico"
    # Окно живёт, пока работают внешние процессы; закрытие окна отменяет установку
    $tick = {
        $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
        if ($script:Aborting) { throw "ABORT" }
    }

    Write-Log "Проверка модуля ps2exe..."
    $ps2exeRef = Find-Ps2exe -RootDir $RootDir
    if (-not $ps2exeRef) {
        Write-Log "Модуль не установлен, скачиваю напрямую (не дольше 90 сек)..."
        Set-Progress -Percent 25
        $dl = Get-Ps2exe -TimeoutSec 90 -OnTick $tick -OnProgress { param($sec) Write-Log ("  ...скачивание идёт, прошло $sec с") }
        if ($dl.Ok) {
            $ps2exeRef = Find-Ps2exe -RootDir $RootDir
            Write-Log "ps2exe скачан."
        } elseif ($dl.TimedOut) {
            Write-Log "Скачивание не уложилось в 90 секунд (нет интернета или сайт недоступен)."
        } else {
            Write-Log "Не удалось скачать ps2exe."
            if ($dl.Output) { Write-Log $dl.Output }
        }
    }

    $built = $false
    $usedLauncher = $false
    if ($ps2exeRef) {
        Set-Progress -Percent 45
        Write-Log "Сборка ZapretGUI.exe (обычно 20-60 секунд)..."
        $b = Build-ZapretExe -Ps2exeRef $ps2exeRef -InputFile $guiScript -OutputFile $ExeOutput -IconFile $iconFile -TimeoutSec 240 -OnTick $tick -OnProgress { param($sec) Write-Log ("  ...идёт сборка, прошло $sec с") }
        if ($b.Ok) {
            $built = $true
        } else {
            if ($b.TimedOut) { Write-Log "Сборка не уложилась в 240 секунд." } else { Write-Log "Сборка через ps2exe не удалась." }
            if ($b.Output) { Write-Log $b.Output }
        }
    }

    if (-not $built) {
        Write-Log "Собираю запасной вариант без ps2exe и без интернета..."
        Set-Progress -Percent 60
        $rel = $guiScript.Substring($RootDir.TrimEnd('\').Length).TrimStart('\')
        $lc = New-LauncherExe -OutputFile $ExeOutput -ScriptRelPath $rel -IconFile $iconFile -TimeoutSec 90 -OnTick $tick -OnProgress { param($sec) Write-Log ("  ...сборка, прошло $sec с") }
        if ($lc.Ok) {
            $built = $true
            $usedLauncher = $true
            Write-Log "Готово: ZapretGUI.exe запускает zapret_gui_v3.ps1 (файл интерфейса остаётся в папке программы)."
        } else {
            Write-Log "ОШИБКА: не удалось собрать ZapretGUI.exe."
            if ($lc.Output) { Write-Log $lc.Output }
            $btnInstall.IsHitTestVisible = $true
            $btnInstall.Opacity = 1
            return
        }
    }

    if (-not (Test-Path $ExeOutput)) {
        Write-Log "ОШИБКА: файл ZapretGUI.exe не был создан."
        $btnInstall.IsHitTestVisible = $true
        $btnInstall.Opacity = 1
        return
    }
    Set-Progress -Percent 78
    Write-Log "Готово: $ExeOutput"

    Write-Log "Очистка временных файлов установки..."
    if (-not $usedLauncher) {
        Remove-Item $guiScript -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $ZapretDir "Build-EXE.bat") -Force -ErrorAction SilentlyContinue
    }
    Set-Progress -Percent 90

    if ($chkDesktop.IsChecked) {
        Write-Log "Создание ярлыка на рабочем столе..."
        $made = $false
        $desktops = @([Environment]::GetFolderPath("Desktop"), [Environment]::GetFolderPath("CommonDesktopDirectory"))
        foreach ($dk in $desktops) {
            if ($made -or -not $dk -or -not (Test-Path -LiteralPath $dk)) { continue }
            try {
                $WshShell = New-Object -ComObject WScript.Shell
                $shortcut = $WshShell.CreateShortcut((Join-Path $dk "Zapret.lnk"))
                $shortcut.TargetPath = $ExeOutput
                $shortcut.WorkingDirectory = $RootDir
                $shortcut.Description = "Zapret GUI BETA"
                $shortcut.IconLocation = "$ExeOutput,0"
                $shortcut.Save()
                $made = $true
                Write-Log "Ярлык создан: $dk"
            } catch {
                Write-Log "Не удалось создать ярлык в $dk : $($_.Exception.Message)"
            }
        }
        if (-not $made) { Write-Log "Ярлык создать не удалось — запускайте ZapretGUI.exe из папки программы." }
    } else {
        Write-Log "Ярлык на рабочем столе пропущен (галочка снята)."
    }

    if ($chkLockFolder.IsChecked) {
        Write-Log "Закрываю папку программы от обычных пользователей..."
        Write-Log (Lock-ZapretFolder -Dir $ZapretDir)
        Write-Log "Списки и плейлист открываются кнопками в настройках программы."
    }

    Set-Progress -Percent 100
    Write-Log ""
    Write-Log "УСТАНОВКА ЗАВЕРШЕНА."
    Write-Log "Установщик можно удалить — он больше не нужен."

    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0
    $fadeIn.To = 1
    $fadeIn.Duration = [TimeSpan]::FromMilliseconds(400)
    $statusIcon.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fadeIn)

    $script:Installed = $true
    $btnInstall.Content = "Запустить Zapret"
    $btnInstall.IsHitTestVisible = $true
    $btnInstall.Opacity = 1
  } catch {
    if ($script:Aborting) { return }
    [System.Windows.MessageBox]::Show(
        "Ошибка установки: $($_.Exception.Message)`n`nСтрока $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())",
        "Zapret — ошибка"
    ) | Out-Null
    $btnInstall.IsHitTestVisible = $true
    $btnInstall.Opacity = 1
  }
})

[void]$window.ShowDialog()
