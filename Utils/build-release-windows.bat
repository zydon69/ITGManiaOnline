@echo off
setlocal EnableExtensions

cd /d "%~dp0.." || goto fail

rem MSBuild can fail when the process environment contains both PATH and Path.
set "_ORIGINAL_PATH=%Path%"
set "PATH="
set "Path=%_ORIGINAL_PATH%"

set "BUILD_DIR=Build\release"
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
if "%PARALLEL%"=="" set "PARALLEL=4"

echo [1/5] Configuring full release with Club Fantastic...
cmake -S . -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DWITH_FULL_RELEASE=On -DWITH_CLUB_FANTASTIC=On || goto fail

echo [2/5] Building full release...
cmake --build "%BUILD_DIR%" --config Release --parallel %PARALLEL% || goto fail

echo [3/5] Packaging Club Fantastic build...
cmake --build "%BUILD_DIR%" --config Release --target package || goto fail

echo [4/5] Configuring full release without Club Fantastic...
cmake -S . -B "%BUILD_DIR%" -G "Visual Studio 17 2022" -A x64 -DWITH_FULL_RELEASE=On -DWITH_CLUB_FANTASTIC=Off || goto fail

echo [5/5] Packaging standard build...
cmake --build "%BUILD_DIR%" --config Release --target package || goto fail

echo.
echo Windows release build complete.
goto done

:fail
echo.
echo ERROR: Windows release build failed.
if not defined CODEX_CI pause
exit /b 1

:done
if not defined CODEX_CI pause
exit /b 0
