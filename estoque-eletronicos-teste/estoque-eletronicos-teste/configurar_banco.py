# -*- coding: utf-8 -*-
"""
============================================================================
 CONFIGURAR_BANCO.PY — cria o banco do zero, executando o estoque.sql
----------------------------------------------------------------------------
 O QUE FAZ:
   Lê o arquivo estoque.sql e manda o conteúdo para o SQL Server, do mesmo
   jeito que o SSMS faria — só que sem precisar abrir o SSMS.

 POR QUE NÃO BASTA UM "cursor.execute(arquivo_inteiro)":
   O estoque.sql é dividido por linhas com a palavra GO. GO não é um comando
   do SQL: é um SEPARADOR DE LOTES que só o SSMS e o sqlcmd entendem. Ele
   marca onde um pedaço termina e outro começa — e algumas instruções
   (CREATE VIEW, CREATE PROCEDURE) EXIGEM ser o primeiro comando do lote.
   Por isso este script quebra o arquivo nos GO e envia lote por lote.

 ATENÇÃO: o estoque.sql APAGA e recria o banco. Tudo o que estiver lá dentro
 se perde. É proposital — o script foi feito para deixar o banco sempre no
 mesmo estado conhecido, com os 15 produtos de exemplo.

 COMO RODAR:
   python configurar_banco.py
   (ou dê um duplo-clique no 1-INSTALAR.bat, que faz isso e mais um pouco)
============================================================================
"""

import io
import os
import re
import sys

import pyodbc
import conexao

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ARQUIVO_SQL = os.path.join(BASE_DIR, "estoque.sql")


def ler_script():
    """Lê o .sql. O encoding é utf-8 porque o arquivo tem acento (Áudio,
    Acessório) — ler como ANSI transformaria os acentos em lixo."""
    if not os.path.exists(ARQUIVO_SQL):
        sys.exit(f"ERRO: não encontrei o arquivo {ARQUIVO_SQL}")
    return io.open(ARQUIVO_SQL, encoding="utf-8").read()


def nome_do_banco(script):
    """Descobre o nome do banco lendo o próprio script, em vez de deixá-lo
    escrito aqui também. Assim as duas versões do trabalho (a normal e a de
    teste) usam este mesmo arquivo sem nenhuma alteração."""
    m = re.search(r"CREATE\s+DATABASE\s+(\w+)", script, re.I)
    return m.group(1) if m else "EstoqueEletronicos"


def separar_lotes(script):
    """Quebra o script nas linhas que contêm só GO.

    A expressão regular exige que o GO esteja SOZINHO na linha (^\\s*GO\\s*$),
    com re.M para que ^ e $ valham por linha. Sem esse cuidado, a palavra
    "go" no meio de um texto qualquer partiria o script no lugar errado."""
    lotes = re.split(r"^\s*GO\s*;?\s*$", script, flags=re.I | re.M)
    return [lote.strip() for lote in lotes if lote.strip()]


def main():
    print()
    print("=" * 68)
    print(" CONFIGURACAO DO BANCO — Estoque de Eletronicos")
    print("=" * 68)

    script = ler_script()
    banco = nome_do_banco(script)
    lotes = separar_lotes(script)
    print(f"\n  Arquivo .......... {os.path.basename(ARQUIVO_SQL)}")
    print(f"  Banco a criar .... {banco}")
    print(f"  Lotes (GO) ....... {len(lotes)}")

    # Conecta no 'master', e não no banco do trabalho: o script começa
    # justamente derrubando esse banco, então não dá para estar dentro dele.
    print("\n  Procurando o SQL Server nesta maquina:")
    try:
        driver, servidor, conn_str = conexao.descobrir("master", verboso=True)
    except RuntimeError as e:
        print("\n" + "-" * 68)
        print(e)
        print("-" * 68)
        sys.exit(1)

    print(f"\n  Conectado em ..... {servidor}")
    print(f"  Driver ........... {driver}")

    # autocommit=True porque CREATE DATABASE e ALTER DATABASE não podem rodar
    # dentro de uma transação. As procedures do script abrem as próprias
    # transações onde precisam (é o caso da saída de estoque).
    cn = pyodbc.connect(conn_str, autocommit=True)
    cur = cn.cursor()

    print("\n  Executando:")
    for i, lote in enumerate(lotes, 1):
        # Só para a mensagem ficar legível: a primeira linha útil do lote.
        titulo = next(
            (l.strip() for l in lote.splitlines()
             if l.strip() and not l.strip().startswith(("--", "/*", "*"))),
            "(comentario)",
        )[:56]
        try:
            cur.execute(lote)
            # Um lote pode devolver vários resultados (as consultas do fim do
            # script). Precisam ser consumidos antes do próximo execute.
            while True:
                if cur.description:
                    cur.fetchall()
                if not cur.nextset():
                    break
            print(f"   [{i:2}/{len(lotes)}] ok   {titulo}")
        except pyodbc.Error as e:
            print(f"   [{i:2}/{len(lotes)}] ERRO {titulo}")
            print(f"\n   {e}\n")
            print("   O banco pode ter ficado pela metade. Corrija o erro")
            print("   acima e rode este script de novo — ele recria tudo.")
            cn.close()
            sys.exit(1)

    # Conferência final: mostra o que realmente entrou no banco.
    print("\n  Conferindo o resultado:")
    cur.execute(f"USE {banco}")
    cur.execute("""
        SELECT 'categoria' t, COUNT(*) n FROM categoria
        UNION ALL SELECT 'marca',        COUNT(*) FROM marca
        UNION ALL SELECT 'fornecedor',   COUNT(*) FROM fornecedor
        UNION ALL SELECT 'produto',      COUNT(*) FROM produto
        UNION ALL SELECT 'movimentacao', COUNT(*) FROM movimentacao
    """)
    for tabela, qtd in cur.fetchall():
        print(f"   {tabela:<14} {qtd:>4} registros")

    cur.execute("SELECT COUNT(*) FROM vw_estoque_atual WHERE estoque_atual < estoque_minimo")
    print(f"\n   {cur.fetchval()} produtos abaixo do estoque minimo (a Consulta 1 do trabalho)")

    cn.close()
    print("\n" + "=" * 68)
    print(" BANCO PRONTO. Agora rode o 2-INICIAR.bat para abrir o sistema.")
    print("=" * 68 + "\n")


if __name__ == "__main__":
    main()
