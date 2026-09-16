@echo off
REM ===========================================================================
REM  2-INICIAR.bat  --  passo 2 de 2
REM  Sobe o servidor Python e abre o sistema no navegador.
REM  Use este arquivo sempre que quiser abrir o sistema.
REM  Para desligar: feche esta janela preta ou tecle Ctrl+C nela.
REM ===========================================================================
chcp 65001 >nul
cd /d "%~dp0"
title Servidor - Estoque de Eletronicos  (feche para desligar)

echo.
echo  ====================================================================
echo   PASSO 2 de 2  --  Subindo o servidor
echo  ====================================================================
echo.
echo   O navegador abre sozinho em alguns segundos.
echo   NAO FECHE esta janela enquanto estiver usando o sistema.
echo.

REM  -u = saida sem buffer, para o banner aparecer na hora
python -u app.py
if errorlevel 1 (
  echo.
  echo  O servidor nao subiu. Se a mensagem acima fala em banco de dados,
  echo  rode antes o 1-INSTALAR.bat.
)
pause
