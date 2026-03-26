@echo off
chcp 65001 >nul
echo ============================================
echo  Instalando dependencias - WhatsApp Sender
echo ============================================
echo.

pip install selenium
pip install webdriver-manager

echo.
echo ============================================
echo  Instalacao concluida!
echo.
echo  Interface grafica : python app_gui.py
echo  Linha de comando  : python enviarWhatsApp.py
echo ============================================
pause
