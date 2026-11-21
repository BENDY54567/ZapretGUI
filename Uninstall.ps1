[System.Reflection.Assembly]::LoadWithPartialName("PresentationFramework") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("PresentationCore") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("WindowsBase") | Out-Null

function Get-SelfPath {
    if ($PSScriptRoot -and (Test-Path $PSScriptRoot)) { return $PSCommandPath }
    return [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
$SelfPath = Get-SelfPath
$RootDir  = Split-Path -Parent $SelfPath

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    if ($SelfPath -like "*.ps1") {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$SelfPath`""
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
$ExePath   = Join-Path $RootDir "ZapretGUI.exe"
$Shortcut  = Join-Path ([Environment]::GetFolderPath("Desktop")) "Zapret.lnk"

function Invoke-ScCommand {
    param([string]$Arguments, [int]$TimeoutMs = 4000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "sc.exe"
        $psi.Arguments = $Arguments
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        if (-not $p.WaitForExit($TimeoutMs)) { try { $p.Kill() } catch {} }
    } catch {}
}

# ---------------------------------------------------------------
# XAML — интерфейс деинсталлятора в стиле основного приложения
# ---------------------------------------------------------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Удаление Zapret" Width="500" Height="580"
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
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#B7B7C2"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Margin" Value="0,0,0,10"/>
        </Style>
    </Window.Resources>

    <StackPanel Margin="28">
        <StackPanel Orientation="Horizontal">
            <Border Width="42" Height="42" CornerRadius="21" Background="#3A1F1F">
                <TextBlock Text="&#128465;" FontSize="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
                <TextBlock Text="Полное удаление Zapret" FontSize="19" FontWeight="Bold" Foreground="White"/>
                <TextBlock Text="Остановит службу и удалит файлы программы" FontSize="11.5" Foreground="#8A8A99" Margin="0,2,0,0"/>
            </StackPanel>
        </StackPanel>

        <CheckBox x:Name="chkPs2exe" Content="Также удалить модуль PowerShell ps2exe" IsChecked="True" Margin="0,22,0,8"/>
        <CheckBox x:Name="chkFolder" Content="Удалить папку с файлами zapret полностью" IsChecked="True"/>

        <Border Background="#12121B" CornerRadius="10" Margin="0,14,0,0" Height="180">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,14">
                <TextBox x:Name="logBox" Background="Transparent" Foreground="#FF9B9B" FontFamily="Consolas" FontSize="12"
                         BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"/>
            </ScrollViewer>
        </Border>

        <Border x:Name="progressTrack" Height="7" Width="444" Background="#1B1B27" CornerRadius="4" Margin="0,18,0,0" HorizontalAlignment="Left">
            <Border x:Name="progressFill" Width="0" HorizontalAlignment="Left" CornerRadius="4" Background="#B4324A"/>
        </Border>

        <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
            <Button x:Name="btnUninstall" Content="Удалить" Width="220" Height="44" Background="#B4324A" Foreground="White" BorderThickness="0" FontSize="14.5" Margin="0,0,12,0"/>
            <Button x:Name="btnClose" Content="Отмена" Width="160" Height="44" Background="#1B1B27" Foreground="White" BorderThickness="0" FontSize="14.5"/>
        </StackPanel>
    </StackPanel>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$logBox = $window.FindName("logBox")
$progressFill = $window.FindName("progressFill")
$chkPs2exe = $window.FindName("chkPs2exe")
$chkFolder = $window.FindName("chkFolder")
$btnUninstall = $window.FindName("btnUninstall")
$btnClose = $window.FindName("btnClose")

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
    $anim.Duration = [TimeSpan]::FromMilliseconds(400)
    $anim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $anim.EasingFunction.EasingMode = "EaseOut"
    $progressFill.BeginAnimation([System.Windows.FrameworkElement]::WidthProperty, $anim)
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
}

$btnClose.Add_Click({ $window.Close() })

$script:UninstallDone = $false

$btnUninstall.Add_Click({
  if ($script:UninstallDone) {
    $window.Close()
    return
  }
  try {
    $btnUninstall.IsHitTestVisible = $false
    $btnUninstall.Opacity = 0.6
    $chkPs2exe.IsEnabled = $false
    $chkFolder.IsEnabled = $false

    Set-Progress -Percent 10
    Write-Log "Останавливаю процессы и службы..."
    Get-Process -Name "ZapretGUI" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    Set-Progress -Percent 30
    $svc = Get-Service -Name "zapret" -ErrorAction SilentlyContinue
    if ($svc) {
        Invoke-ScCommand -Arguments "stop zapret"
        Invoke-ScCommand -Arguments "delete zapret"
        Write-Log "Служба zapret удалена."
    }
    $wd = Get-Service -Name "WinDivert" -ErrorAction SilentlyContinue
    if ($wd) {
        Invoke-ScCommand -Arguments "stop WinDivert"
        Invoke-ScCommand -Arguments "delete WinDivert"
        Write-Log "WinDivert удалён."
    }

    Set-Progress -Percent 55
    if (Test-Path $Shortcut) {
        Remove-Item $Shortcut -Force -ErrorAction SilentlyContinue
        Write-Log "Ярлык на рабочем столе удалён."
    }
    if (Test-Path $ExePath) {
        Remove-Item $ExePath -Force -ErrorAction SilentlyContinue
        Write-Log "ZapretGUI.exe удалён."
    }

    Set-Progress -Percent 75
    if ($chkFolder.IsChecked -and $ZapretDir -and (Test-Path $ZapretDir)) {
        Remove-Item $ZapretDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Папка с файлами zapret удалена."
    }

    Set-Progress -Percent 90
    if ($chkPs2exe.IsChecked) {
        Write-Log "Удаляю модуль ps2exe..."
        try {
            Uninstall-Module -Name ps2exe -AllVersions -ErrorAction SilentlyContinue
            Write-Log "Модуль ps2exe удалён."
        } catch {
            Write-Log "Не удалось удалить ps2exe: $($_.Exception.Message)"
        }
    }

    Set-Progress -Percent 100
    Write-Log ""
    Write-Log "УДАЛЕНИЕ ЗАВЕРШЕНО."
    $btnUninstall.Content = "Готово"
    $btnUninstall.IsHitTestVisible = $true
    $btnUninstall.Opacity = 1
    $script:UninstallDone = $true
  } catch {
    [System.Windows.MessageBox]::Show(
        "Ошибка удаления: $($_.Exception.Message)`n`nСтрока $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())",
        "Zapret — ошибка"
    ) | Out-Null
    $btnUninstall.IsHitTestVisible = $true
    $btnUninstall.Opacity = 1
  }
})

[void]$window.ShowDialog()
