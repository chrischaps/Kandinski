@echo off
cd /d "%~dp0"
set SCENE=%1
if "%SCENE%"=="" set SCENE=scenes\kandinski.scene.toml
engine\target\release\flint-player.exe %SCENE% --schemas engine\schemas --schemas schemas --width 1600 --height 900
