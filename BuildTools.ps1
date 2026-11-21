# BuildTools.ps1 — общий код установщика (Install.ps1) и обновлятора (Update.ps1):
# поиск/скачивание модуля ps2exe и сборка ZapretGUI.exe.
#
# Почему отдельный файл: раньше установка вызывала Install-Module прямо в окне установщика.
# В Windows PowerShell 5.1 без включённого TLS 1.2 это молча висит минутами (PowerShell Gallery не
# отвечает), а окно не обновляется — со стороны выглядит как зависание. Здесь всё тяжёлое
# выполняется в отдельном процессе с жёстким таймаутом, окно при этом остаётся живым.

function ConvertTo-PsLiteral {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# Запускает код PowerShell в отдельном скрытом процессе. По таймауту убивает процесс вместе с потомками.
#   $OnTick     — вызывается каждые ~150 мс (чтобы обновлять окно; может бросить исключение для отмены)
#   $OnProgress — вызывается каждые ~5 сек с числом прошедших секунд
function Invoke-ChildPs {
    param(
        [string]$Code,
        [int]$TimeoutSec = 60,
        [scriptblock]$OnTick = $null,
        [scriptblock]$OnProgress = $null
    )
    $id  = [guid]::NewGuid().ToString('N')
    $tmp = Join-Path $env:TEMP ("zapret_step_" + $id + ".ps1")
    $out = $tmp + ".out"
    $err = $tmp + ".err"
    $res = [pscustomobject]@{ Ok = $false; TimedOut = $false; ExitCode = -1; Output = "" }
    $p = $null
    try {
        [System.IO.File]::WriteAllText($tmp, $Code, (New-Object System.Text.UTF8Encoding($true)))
        $p = Start-Process -FilePath "powershell.exe" `
            -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"" + $tmp + "`"") `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastNote = 0
        while (-not $p.HasExited) {
            if ($OnTick) { & $OnTick }
            Start-Sleep -Milliseconds 150
            $el = [int]$sw.Elapsed.TotalSeconds
            if ($OnProgress -and (($el - $lastNote) -ge 5)) { $lastNote = $el; & $OnProgress $el }
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
                $res.TimedOut = $true
                break
            }
        }
        if (-not $res.TimedOut) {
            $p.WaitForExit(3000) | Out-Null
            $res.ExitCode = $p.ExitCode
            $res.Ok = ($p.ExitCode -eq 0)
        }
    } catch {
        if ($_.Exception.Message -eq "ABORT") { throw }
        $res.Output = "Не удалось запустить PowerShell: " + $_.Exception.Message
    } finally {
        if ($p -and -not $p.HasExited) {
            try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch {}
        }
    }
    $text = ""
    foreach ($f in @($out, $err)) {
        if (Test-Path -LiteralPath $f) {
            try { $text += [System.IO.File]::ReadAllText($f) + "`n" } catch {}
        }
    }
    $res.Output = ($res.Output + "`n" + $text).Trim()
    foreach ($f in @($tmp, $out, $err)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return $res
}

function Get-Ps2exeCacheDir {
    return (Join-Path $env:LOCALAPPDATA "ZapretGUI\ps2exe")
}

# Возвращает то, что можно передать в Import-Module (имя или путь), либо $null, если модуля нет.
function Find-Ps2exe {
    param([string]$RootDir)
    if (Get-Module -ListAvailable -Name ps2exe -ErrorAction SilentlyContinue) { return "ps2exe" }
    $candidates = @()
    if ($RootDir) { $candidates += (Join-Path $RootDir "tools\ps2exe\ps2exe.psd1") }
    $candidates += (Join-Path (Get-Ps2exeCacheDir) "ps2exe.psd1")
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    return $null
}

# Скачивает ps2exe напрямую (без PowerShellGet и NuGet) в папку кэша.
function Get-Ps2exe {
    param(
        [int]$TimeoutSec = 90,
        [scriptblock]$OnTick = $null,
        [scriptblock]$OnProgress = $null
    )
    $template = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$dest = __DEST__
$urls = @('https://www.powershellgallery.com/api/v2/package/ps2exe', 'https://github.com/MScholtes/PS2EXE/archive/refs/heads/master.zip')
foreach ($u in $urls) {
    try {
        $zip = Join-Path $env:TEMP ('ps2exe_' + [guid]::NewGuid().ToString('N') + '.zip')
        $x   = Join-Path $env:TEMP ('ps2exe_x_' + [guid]::NewGuid().ToString('N'))
        Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 40
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
        $psd1 = Get-ChildItem -LiteralPath $x -Recurse -Filter 'ps2exe.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($psd1) {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path (Join-Path $psd1.DirectoryName '*') -Destination $dest -Recurse -Force
            Remove-Item -LiteralPath $zip, $x -Recurse -Force -ErrorAction SilentlyContinue
            Write-Output 'OK'
            exit 0
        }
        Write-Output ('В архиве с ' + $u + ' нет ps2exe.psd1')
    } catch {
        Write-Output ('Ошибка загрузки с ' + $u + ': ' + $_.Exception.Message)
    }
}
exit 1
'@
    $code = $template.Replace('__DEST__', (ConvertTo-PsLiteral (Get-Ps2exeCacheDir)))
    return (Invoke-ChildPs -Code $code -TimeoutSec $TimeoutSec -OnTick $OnTick -OnProgress $OnProgress)
}

# Собирает ZapretGUI.exe через ps2exe (с иконкой, если указан .ico).
function Build-ZapretExe {
    param(
        [string]$Ps2exeRef,
        [string]$InputFile,
        [string]$OutputFile,
        [string]$IconFile = "",
        [int]$TimeoutSec = 240,
        [scriptblock]$OnTick = $null,
        [scriptblock]$OnProgress = $null
    )
    $iconArg = ""
    if ($IconFile -and (Test-Path -LiteralPath $IconFile)) { $iconArg = " -iconFile " + (ConvertTo-PsLiteral $IconFile) }
    $template = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module __MODULE__ -Force
Invoke-ps2exe -inputFile __IN__ -outputFile __OUT__ -noConsole -requireAdmin -STA -title 'Zapret GUI BETA'__ICON__
'@
    $code = $template.Replace('__MODULE__', (ConvertTo-PsLiteral $Ps2exeRef)).Replace('__IN__', (ConvertTo-PsLiteral $InputFile)).Replace('__OUT__', (ConvertTo-PsLiteral $OutputFile)).Replace('__ICON__', $iconArg)
    Remove-Item -LiteralPath $OutputFile -Force -ErrorAction SilentlyContinue
    $r = Invoke-ChildPs -Code $code -TimeoutSec $TimeoutSec -OnTick $OnTick -OnProgress $OnProgress
    if ($r.Ok -and -not (Test-Path -LiteralPath $OutputFile)) { $r.Ok = $false }
    if ($r.Ok -and ((Get-Item -LiteralPath $OutputFile).Length -le 0)) { $r.Ok = $false }
    return $r
}

# Запасной вариант без ps2exe и без интернета: крошечный exe-запускатель, собранный штатным csc.exe
# из .NET Framework (он есть в каждой Windows). Он просто запускает zapret_gui_v3.ps1 от администратора.
# В этом случае сам .ps1 остаётся на месте.
function New-LauncherExe {
    param(
        [string]$OutputFile,
        [string]$ScriptRelPath,
        [string]$IconFile = "",
        [int]$TimeoutSec = 90,
        [scriptblock]$OnTick = $null,
        [scriptblock]$OnProgress = $null
    )
    $csc = $null
    foreach ($c in @((Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"), (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe"))) {
        if (Test-Path -LiteralPath $c) { $csc = $c; break }
    }
    if (-not $csc) {
        return [pscustomobject]@{ Ok = $false; TimedOut = $false; ExitCode = -1; Output = "csc.exe (.NET Framework 4) не найден." }
    }
    $id = [guid]::NewGuid().ToString('N')
    $srcFile = Join-Path $env:TEMP ("zapret_launcher_" + $id + ".cs")
    $manFile = Join-Path $env:TEMP ("zapret_launcher_" + $id + ".manifest")
    $csTemplate = @'
using System;
using System.Diagnostics;
using System.IO;

static class ZapretLauncher
{
    [STAThread]
    static int Main()
    {
        string dir = Path.GetDirectoryName(Process.GetCurrentProcess().MainModule.FileName);
        string ps1 = Path.Combine(dir, @"__PS1__");
        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File \"" + ps1 + "\"");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = dir;
        Process.Start(psi);
        return 0;
    }
}
'@
    $manifest = @'
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
'@
    [System.IO.File]::WriteAllText($srcFile, $csTemplate.Replace('__PS1__', $ScriptRelPath), (New-Object System.Text.UTF8Encoding($true)))
    [System.IO.File]::WriteAllText($manFile, $manifest, (New-Object System.Text.UTF8Encoding($false)))
    $template = @'
$ErrorActionPreference = 'Continue'
& __CSC__ /nologo /target:winexe __OUTARG__ __MANARG__ __ICON__ __SRC__
exit $LASTEXITCODE
'@
    $code = $template.Replace('__CSC__', (ConvertTo-PsLiteral $csc))
    $code = $code.Replace('__OUTARG__', (ConvertTo-PsLiteral ("/out:" + $OutputFile)))
    $code = $code.Replace('__MANARG__', (ConvertTo-PsLiteral ("/win32manifest:" + $manFile)))
    $code = $code.Replace('__SRC__', (ConvertTo-PsLiteral $srcFile))
    if ($IconFile -and (Test-Path -LiteralPath $IconFile)) {
        $code = $code.Replace('__ICON__', (ConvertTo-PsLiteral ("/win32icon:" + $IconFile)))
    } else {
        $code = $code.Replace('__ICON__', '')
    }
    Remove-Item -LiteralPath $OutputFile -Force -ErrorAction SilentlyContinue
    $r = Invoke-ChildPs -Code $code -TimeoutSec $TimeoutSec -OnTick $OnTick -OnProgress $OnProgress
    Remove-Item -LiteralPath $srcFile, $manFile -Force -ErrorAction SilentlyContinue
    if ($r.Ok -and -not (Test-Path -LiteralPath $OutputFile)) { $r.Ok = $false }
    return $r
}
