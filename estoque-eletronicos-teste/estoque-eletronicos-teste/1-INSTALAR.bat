@echo off
REM ===========================================================================
REM  1-INSTALAR.bat  --  passo 1 de 2
REM  Instala a unica dependencia (pyodbc) e cria o banco no SQL Server.
REM  De um duplo-clique neste arquivo. So precisa ser feito UMA vez.
REM ===========================================================================
cd /d "%~dp0"
title Instalacao - Estoque de Eletronicos

echo.
echo  ====================================================================
echo   PASSO 1 de 2  --  Instalando e criando o banco
echo  ====================================================================
echo.

REM -- Python esta instalado? ------------------------------------------------
python --version >nul 2>&1
if errorlevel 1 (
  echo  [X] Python nao encontrado.
  echo.
  echo      Instale o Python em https://python.org/downloads
  echo      IMPORTANTE: marque a caixa "Add Python to PATH" na instalacao.
  echo.
  pause
  exit /b 1
)
for /f "delims=" %%v in ('python --version') do echo  [ok] %%v

REM -- Dependencia: pyodbc ---------------------------------------------------
echo.
echo  Instalando a biblioteca pyodbc (ponte entre o Python e o SQL Server)...
python -m pip install --quiet --disable-pip-version-check pyodbc
if errorlevel 1 (
  echo  [X] Falha ao instalar o pyodbc. Verifique sua conexao com a internet.
  pause
  exit /b 1
)
echo  [ok] pyodbc instalado

REM -- Cria o banco ----------------------------------------------------------
python configurar_banco.py
if errorlevel 1 (
  echo.
  echo  A criacao do banco falhou. Leia a mensagem acima.
  pause
  exit /b 1
)

pause
