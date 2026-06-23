@echo off
setlocal EnableExtensions

cd /d "%~dp0.." || goto fail

rem MSBuild can fail when the process environment contains both PATH and Path.
set "_ORIGINAL_PATH=%Path%"
set "PATH="
set "Path=%_ORIGINAL_PATH%"

set "BUILD_DIR=Build\release"
set "DEST=%USERPROFILE%\Desktop\ITGManiaOnline-Windows-x64"

echo [1/5] Cleaning build folder...
if exist Build rmdir /s /q Build || goto fail
mkdir "%BUILD_DIR%" || goto fail

echo [2/5] Configuring CMake...
cmake -S . -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DWITH_FULL_RELEASE=ON -DWITH_CLUB_FANTASTIC=OFF || goto fail

echo [3/5] Building ITGmania...
cmake --build "%BUILD_DIR%" --config Release --target ITGmania --parallel 4 || goto fail

echo [4/5] Preparing portable folder...
if exist "%DEST%" rmdir /s /q "%DEST%" || goto fail
mkdir "%DEST%" || goto fail

echo [5/5] Copying files...
call :copydir Program
call :copydir Announcers
call :copydir BackgroundEffects
call :copydir BackgroundTransitions
call :copydir BGAnimations
call :copydir Characters
call :copydir Courses
call :copydir Data
call :copydir NoteSkins
call :copydir RandomMovies
call :copydir Songs
call :copydir Themes

copy /y LICENSE "%DEST%\" >nul || goto fail
copy /y README.md "%DEST%\" >nul || goto fail
type nul > "%DEST%\Portable.ini" || goto fail
(
  echo ITGManiaOnline - Windows x64
  echo.
  echo Lance le jeu avec:
  echo Program\ITGmania.exe
  echo.
  echo Ce dossier est portable: les reglages, profils, scores et logs restent dans ce dossier grace a Portable.ini.
  echo Pour ajouter des chansons, copie les packs dans le dossier Songs.
) > "%DEST%\LIRE-MOI.txt" || goto fail

echo.
echo Build release termine:
echo %DEST%
goto done

:copydir
robocopy "%~1" "%DEST%\%~1" /E
if %ERRORLEVEL% GEQ 8 goto fail
exit /b 0

:fail
echo.
echo ERREUR: build release interrompu.
if not defined CODEX_CI pause
exit /b 1

:done
if not defined CODEX_CI pause
exit /b 0
