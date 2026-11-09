@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo.
echo  桌面框 · 安装
echo  ----------------
echo  在桌面创建一个「桌面框」图标，只占几 KB。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create_shortcut.ps1"
if errorlevel 1 goto fail

echo.
echo  完成。去桌面双击「桌面框」就能打开。
echo  第一次打开会自动弹出设置，让你选择要显示的目录。
echo.
echo  不想用的时候：点框右上角 x，或托盘图标右键退出。
echo.
pause
exit /b 0

:fail
echo.
echo  [X] 创建失败，请看上面的错误信息。
echo      备用方案：双击 run_make_box.bat，在桌面生成一个真实文件夹。
echo.
pause
exit /b 1
