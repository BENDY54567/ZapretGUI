@echo off
chcp 1251 >nul
setlocal
set "SRC=%~dp0zapret_gui_v3.ps1"
set "OUT=%~dp0..\ZapretGUI.exe"
set "ICO=%~dp0assets\zapret.ico"

echo Собираю ZapretGUI.exe...
echo (Если у вас нет модуля ps2exe, лучше запустите Install.bat из корня архива:
echo  он скачивает модуль с таймаутом и умеет собрать программу без интернета.)
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}; ^
   if (-not (Get-Module -ListAvailable -Name ps2exe)) { Install-Module -Name ps2exe -Scope CurrentUser -Force }; ^
   Import-Module ps2exe -Force; ^
   if (Test-Path '%ICO%') { Invoke-ps2exe -inputFile '%SRC%' -outputFile '%OUT%' -noConsole -requireAdmin -STA -title 'Zapret GUI' -iconFile '%ICO%' } ^
   else { Invoke-ps2exe -inputFile '%SRC%' -outputFile '%OUT%' -noConsole -requireAdmin -STA -title 'Zapret GUI' }"

if exist "%OUT%" (
    echo.
    echo Готово! ZapretGUI.exe создан рядом с этой папкой.
    echo Удаляю временные файлы сборки из папки zapret...
    del /f /q "%SRC%" 2>nul
    del /f /q "%~dp0ZapretGUI.bat" 2>nul
    echo Готово. Окно закроется через несколько секунд.
    timeout /t 3 >nul
    (goto) 2>nul & del "%~f0"
) else (
    echo.
    echo Что-то пошло не так, exe не создан. Файлы сборки оставлены на месте.
    pause
)
