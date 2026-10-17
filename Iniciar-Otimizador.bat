@echo off
setlocal
title Otimizador Gamer
cd /d "%~dp0"

set "SCRIPT=%~dp0OtimizadorGamer.ps1"
if not exist "%SCRIPT%" (
  echo ERRO: nao encontrei OtimizadorGamer.ps1 nesta pasta.
  echo Extraia todos os arquivos do pacote antes de executar.
  pause
  exit /b 1
)

where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo ERRO: Windows PowerShell nao foi encontrado.
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo O otimizador encerrou com codigo %RC%.
  pause
)
exit /b %RC%
