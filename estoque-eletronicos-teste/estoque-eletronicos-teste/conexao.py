# -*- coding: utf-8 -*-
r"""
============================================================================
 CONEXAO.PY — descobre sozinho como falar com o SQL Server
----------------------------------------------------------------------------
 POR QUE ESTE ARQUIVO EXISTE:
   Cada máquina instala o SQL Server de um jeito. Um colega tem o LocalDB que
   vem com o Visual Studio, outro tem o SQL Server Express, outro tem uma
   instância nomeada. E o driver ODBC pode ser a versão 17, a 18 ou o driver
   antigo "SQL Server" que já vem no Windows.

   Sem este arquivo, quem baixasse o trabalho teria que abrir o app.py e
   editar o nome do servidor na mão antes de conseguir rodar. Aqui o programa
   TESTA as combinações mais comuns e usa a primeira que responder.

 QUEM USA:
   app.py             -> para atender as rotas /api/*
   configurar_banco.py -> para criar o banco na primeira vez

 COMO FORÇAR UMA CONFIGURAÇÃO (se a descoberta automática errar):
   Basta definir as variáveis de ambiente antes de rodar. No PowerShell:
       $env:SQLSERVER_HOST = "localhost\SQLEXPRESS"
       $env:SQLSERVER_DRIVER = "ODBC Driver 17 for SQL Server"
       python app.py
============================================================================
"""

import os
import pyodbc


# Drivers em ordem de preferência: o mais novo primeiro. O último da lista,
# "SQL Server", é o driver antigo que acompanha qualquer Windows — serve de
# último recurso, mesmo sendo limitado.
DRIVERS_PREFERIDOS = [
    "ODBC Driver 18 for SQL Server",
    "ODBC Driver 17 for SQL Server",
    "ODBC Driver 13 for SQL Server",
    "SQL Server Native Client 11.0",
    "SQL Server",
]

# Instâncias mais comuns numa máquina de estudante, em ordem de probabilidade.
SERVIDORES_COMUNS = [
    r"(localdb)\MSSQLLocalDB",   # vem com o Visual Studio / SQL Server Data Tools
    r"localhost\SQLEXPRESS",     # instalação típica do SQL Server Express
    r".\SQLEXPRESS",             # a mesma coisa, escrita de outro jeito
    "localhost",                 # instância padrão (sem nome)
    ".",
]


def drivers_instalados():
    """Só os drivers da lista de preferência que existem NESTA máquina,
    já na ordem certa."""
    instalados = set(pyodbc.drivers())
    return [d for d in DRIVERS_PREFERIDOS if d in instalados]


def montar(driver, servidor, banco):
    """Monta a string de conexão.

    Trusted_Connection=yes -> entra com o login do Windows, sem usuário e
    senha. É o modo mais simples para um trabalho de aula.

    O driver 18 exige criptografia por padrão e recusa o certificado
    autoassinado que o SQL Server local usa. TrustServerCertificate=yes diz
    "confio nesse certificado" — aceitável em localhost, onde o tráfego nem
    sai da máquina."""
    partes = [
        f"DRIVER={{{driver}}}",
        f"SERVER={servidor}",
        f"DATABASE={banco}",
        "Trusted_Connection=yes",
    ]
    if "18" in driver or "17" in driver:
        partes.append("TrustServerCertificate=yes")
    return ";".join(partes) + ";"


def testar(driver, servidor, banco, segundos=4):
    """Tenta abrir a conexão. Devolve True/False em vez de estourar o erro,
    porque aqui a falha é ESPERADA: estamos justamente procurando qual das
    combinações funciona."""
    try:
        cn = pyodbc.connect(montar(driver, servidor, banco), timeout=segundos)
        cn.close()
        return True
    except pyodbc.Error:
        return False


def descobrir(banco="master", verboso=False):
    """Procura a primeira combinação (driver, servidor) que responde.

    Se as variáveis de ambiente estiverem definidas, elas mandam — a
    descoberta automática é só o plano B.

    Devolve (driver, servidor, string_de_conexao).
    Levanta RuntimeError com uma mensagem explicativa se nada funcionar."""
    drv_forcado = os.environ.get("SQLSERVER_DRIVER")
    srv_forcado = os.environ.get("SQLSERVER_HOST")

    drivers   = [drv_forcado] if drv_forcado else drivers_instalados()
    servidores = [srv_forcado] if srv_forcado else SERVIDORES_COMUNS

    if not drivers:
        raise RuntimeError(
            "Nenhum driver ODBC do SQL Server foi encontrado nesta máquina.\n"
            "Instale o 'ODBC Driver 17 for SQL Server' (busque por\n"
            "'Microsoft ODBC Driver for SQL Server' no site da Microsoft)."
        )

    for servidor in servidores:
        for driver in drivers:
            if verboso:
                print(f"  testando {servidor}  com  {driver} ...", end=" ")
            if testar(driver, servidor, banco):
                if verboso:
                    print("OK")
                return driver, servidor, montar(driver, servidor, banco)
            if verboso:
                print("nao")

    raise RuntimeError(
        f"Não consegui falar com nenhum SQL Server (banco '{banco}').\n"
        f"Drivers encontrados: {', '.join(drivers) or 'nenhum'}\n"
        f"Servidores testados: {', '.join(servidores)}\n\n"
        "O que verificar:\n"
        "  1. O SQL Server está instalado e o serviço está rodando?\n"
        "     (tecla Windows -> 'Serviços' -> procure por 'SQL Server')\n"
        "  2. Se o banco ainda não existe, rode antes o 1-INSTALAR.bat.\n"
        "  3. Se a sua instância tem outro nome, informe-a assim:\n"
        r"       $env:SQLSERVER_HOST = 'localhost\SUAINSTANCIA'"
    )
