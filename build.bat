@echo off
cd /d "%~dp0engine"
cargo build --release --bin flint-player --bin flint
if errorlevel 1 (
    echo Build failed!
    exit /b 1
)
echo Build successful: engine\target\release\flint-player.exe / flint.exe
