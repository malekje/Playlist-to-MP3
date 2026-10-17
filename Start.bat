@echo off
title Playlist to MP3 - setup
cd /d "%~dp0"
rem Opened from inside the zip: Windows only extracts this file, so app.ps1 is missing
if not exist app.ps1 (
  echo Please right-click the zip, choose "Extract All", then run Start.bat from the extracted folder.
  pause
  exit /b
)
if not exist tools mkdir tools

if exist tools\yt-dlp.exe goto deno
echo [1/3] Downloading yt-dlp...
curl -L --fail -o tools\yt-dlp.part https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe || goto fail
ren tools\yt-dlp.part yt-dlp.exe

:deno
if exist tools\deno.exe goto ffmpeg
echo [2/3] Downloading Deno...
curl -L --fail -o tools\deno.zip https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip || goto fail
tar -xf tools\deno.zip -C tools || goto fail
del tools\deno.zip

:ffmpeg
if exist tools\ffmpeg.exe goto run
echo [3/3] Downloading FFmpeg (first time only)...
curl -L --fail -o tools\ffmpeg.zip https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip || goto fail
if exist tools\ffx rmdir /s /q tools\ffx
mkdir tools\ffx
tar -xf tools\ffmpeg.zip -C tools\ffx || goto fail
for /r "tools\ffx" %%f in (ffmpeg*.exe ffprobe*.exe) do copy /y "%%f" tools\ >nul
rmdir /s /q tools\ffx
del tools\ffmpeg.zip
if not exist tools\ffmpeg.exe goto fail

:run
start "" powershell -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0app.ps1"
exit /b

:fail
echo.
echo Setup failed. Check your internet connection and run Start.bat again.
del /q tools\*.zip tools\*.part 2>nul
if exist tools\ffx rmdir /s /q tools\ffx
pause
