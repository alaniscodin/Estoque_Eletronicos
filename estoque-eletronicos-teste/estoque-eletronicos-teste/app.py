# -*- coding: utf-8 -*-
"""
============================================================================
 TRABALHO DE SQL — BACK-END DO ESTOQUE DE ELETRÔNICOS
 Python SEM framework (só biblioteca padrão) + pyodbc para o SQL Server.
----------------------------------------------------------------------------
 POR QUE SEM FRAMEWORK:
   O trabalho pede back "cru". Um http.server da biblioteca padrão já resolve:
   ele serve o HTML da colega E responde as rotas JSON no MESMO endereço.
   Servir do mesmo endereço é o que evita o bloqueio de CORS do navegador
   (o "ponto de atenção" da seção 9 do documento de estado).

 O QUE ESTE ARQUIVO FAZ:
   1. Sobe um servidor HTTP em http://localhost:8000
   2. Em "/"           -> devolve a página (o HTML do front)
   3. Em "/api/..."    -> devolve/recebe JSON conforme o contrato da seção 9
   4. Toda a REGRA DE NEGÓCIO fica no BANCO (views e procedures). O Python é
      só o carteiro: recebe o JSON, chama a procedure certa, devolve o JSON.

 COMO RODAR:
   1. pip install pyodbc
   2. Ter o banco criado (rodar antes o estoque.sql)
   3. Ajustar SERVIDOR/BANCO/DRIVER abaixo (ou por variáveis de ambiente)
   4. python app.py   ->  abrir http://localhost:8000
============================================================================
"""

import os
import re
import json
import mimetypes
import posixpath
import http.server
import socketserver
import webbrowser
import pyodbc

# conexao.py mora nesta mesma pasta. Ele é quem descobre COMO falar com o
# SQL Server desta máquina (qual driver ODBC, qual instância).
import conexao

# Pasta base = onde este arquivo está. Todo estático (HTML, logo) é servido
# daqui, e nunca de fora dela (proteção contra path traversal, ex.: ../../).
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------
# CONFIGURAÇÃO DA CONEXÃO
# ---------------------------------------------------------------------------
# O nome do banco é a única coisa fixa aqui. QUEM é o servidor e QUAL driver
# ODBC usar quem decide é o conexao.py: ele testa as instalações mais comuns
# (LocalDB, SQL Server Express, instância padrão) e fica com a primeira que
# responder.
#
# POR QUE NÃO DEIXAR O ENDEREÇO ESCRITO AQUI:
# Cada máquina instala o SQL Server de um jeito. Com o endereço fixo, todo
# colega que baixasse o trabalho teria que editar esta linha antes de rodar.
#
# Para forçar uma configuração específica, defina as variáveis de ambiente
# antes de rodar (no PowerShell):
#     $env:SQLSERVER_HOST   = "localhost\SQLEXPRESS"
#     $env:SQLSERVER_DRIVER = "ODBC Driver 17 for SQL Server"
#     $env:SQLSERVER_DB     = "OutroBanco"
# ---------------------------------------------------------------------------
BANCO = os.environ.get("SQLSERVER_DB", "EstoqueEletronicos_Teste")

try:
    DRIVER, SERVIDOR, CONN_STR = conexao.descobrir(BANCO)
except RuntimeError as erro:
    # Falhar aqui, no começo, com uma mensagem clara, é melhor do que subir o
    # servidor e só dar erro quando a tela pedir os produtos.
    print("\n" + "=" * 68)
    print(" NAO FOI POSSIVEL CONECTAR AO BANCO")
    print("=" * 68)
    print(erro)
    print("=" * 68 + "\n")
    raise SystemExit(1)

PORTA   = int(os.environ.get("PORTA", "8001"))
# Arquivo HTML que será servido na raiz. Troca para o da colega quando ela
# entregar; por enquanto aponta para o protótipo.
ARQUIVO_HTML = os.environ.get("HTML", "mockup-estoque.html")


# ---------------------------------------------------------------------------
# MAPA DE MOTIVOS
# O banco guarda o motivo em CÓDIGO (maiúsculo, sem acento) porque é o que o
# CHECK e o GROUP BY das consultas esperam. A tela mostra o rótulo bonito.
# Aceito os dois: se vier o rótulo, converto para código antes de gravar.
# ---------------------------------------------------------------------------
ROTULO_PARA_CODIGO = {
    "Compra":                "COMPRA",
    "Devolução de cliente":  "DEVOLUCAO_CLIENTE",
    "Ajuste de inventário":  "AJUSTE_INVENTARIO",
    "Venda":                 "VENDA",
    "Perda":                 "PERDA",
}

def normaliza_motivo(valor):
    """Converte o rótulo da tela em código do banco. Se já vier em código
    (achou nos valores do mapa), devolve como está."""
    if valor in ROTULO_PARA_CODIGO:          # veio o rótulo bonito
        return ROTULO_PARA_CODIGO[valor]
    return valor                             # já é código (COMPRA, VENDA, ...)


# ---------------------------------------------------------------------------
# ACESSO AO BANCO
# Uma função por operação do contrato. Cada uma abre a conexão, faz o trabalho
# e fecha (o `with` garante o fechamento mesmo se der erro). Para um trabalho
# de aula isso é suficiente e mantém o código simples de ler.
# ---------------------------------------------------------------------------

def conectar():
    """Abre uma conexão nova com o SQL Server."""
    return pyodbc.connect(CONN_STR)


def linhas_como_dicts(cursor):
    """Transforma o resultado de um SELECT em lista de dicionários {coluna: valor},
    que é o que vira JSON limpo para o front. cursor.description traz os nomes
    das colunas na ordem em que o SELECT as devolveu."""
    colunas = [c[0] for c in cursor.description]
    return [dict(zip(colunas, linha)) for linha in cursor.fetchall()]


def listar_produtos():
    """Contrato: 'listar produtos'. Lê da VIEW de estoque (o saldo NÃO é coluna
    do produto — vem da soma das movimentações). Só produtos ativos, como a tela."""
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute("""
            SELECT produto_id, produto, categoria_id, categoria,
                   marca_id, marca, preco_custo, preco_venda,
                   estoque_minimo, estoque_atual
            FROM   vw_estoque_atual
            WHERE  ativo = 1
            ORDER  BY produto
        """)
        return linhas_como_dicts(cur)


def listar_categorias():
    """Contrato: 'listar categorias'. id + nome, para os <select> da tela."""
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute("SELECT id, nome FROM categoria ORDER BY nome")
        return linhas_como_dicts(cur)


def listar_marcas():
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute("SELECT id, nome FROM marca ORDER BY nome")
        return linhas_como_dicts(cur)


def listar_fornecedores():
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute("SELECT id, nome FROM fornecedor ORDER BY nome")
        return linhas_como_dicts(cur)


def cadastrar_produto(d):
    """Contrato: 'cadastrar produto'. Sem quantidade inicial de propósito — o
    estoque nasce em zero e sobe com a primeira entrada. Chama a procedure,
    que devolve o id novo."""
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "EXEC sp_produto_cadastrar ?, ?, ?, ?, ?, ?",
            d["nome"], d["categoria_id"], d["marca_id"],
            d["preco_custo"], d["preco_venda"], d["estoque_minimo"],
        )
        novo_id = cur.fetchone()[0]   # SELECT SCOPE_IDENTITY() dentro da procedure
        cn.commit()
        return {"novo_id": int(novo_id)}


def editar_produto(d):
    """Edita o cadastro do produto (nome, categoria, marca, preços, mínimo).
    Não toca no estoque — quantidade só muda por movimentação. Chama a
    procedure sp_produto_editar."""
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "EXEC sp_produto_editar ?, ?, ?, ?, ?, ?, ?",
            d["produto_id"], d["nome"], d["categoria_id"], d["marca_id"],
            d["preco_custo"], d["preco_venda"], d["estoque_minimo"],
        )
        cn.commit()
        return {}


def registrar_entrada(d):
    """Contrato: 'registrar entrada'. Fornecedor só vem quando o motivo é compra;
    a coerência é garantida pelo CHECK da tabela, então se vier errado o banco
    recusa e o erro sobe para o front."""
    motivo = normaliza_motivo(d["motivo"])
    fornecedor = d.get("fornecedor_id") or None   # "" ou ausente -> NULL
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "EXEC sp_movimentacao_entrada ?, ?, ?, ?",
            d["produto_id"], d["quantidade"], motivo, fornecedor,
        )
        cn.commit()
        return {}


def registrar_saida(d):
    """Contrato: 'registrar saída'. A procedure valida o saldo dentro de uma
    transação; se faltar estoque, ela dá THROW e o pyodbc levanta erro — que a
    camada de resposta transforma na mensagem 'saldo insuficiente' do front."""
    motivo = normaliza_motivo(d["motivo"])
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute(
            "EXEC sp_movimentacao_saida ?, ?, ?",
            d["produto_id"], d["quantidade"], motivo,
        )
        cn.commit()
        return {}


def desativar_produto(d):
    """Contrato: 'desativar produto'. Soft delete — marca ativo = 0. O produto
    sai da lista mas o histórico de movimentações continua no banco."""
    with conectar() as cn:
        cur = cn.cursor()
        cur.execute("EXEC sp_produto_desativar ?", d["produto_id"])
        cn.commit()
        return {}


# Tabela de rotas: método + caminho -> função. As de GET não recebem corpo;
# as de POST recebem o dicionário lido do JSON enviado pelo front.
ROTAS_GET = {
    "/api/produtos":     listar_produtos,
    "/api/categorias":   listar_categorias,
    "/api/marcas":       listar_marcas,
    "/api/fornecedores": listar_fornecedores,
}
ROTAS_POST = {
    "/api/produtos":           cadastrar_produto,
    "/api/produtos/editar":    editar_produto,
    "/api/entradas":           registrar_entrada,
    "/api/saidas":             registrar_saida,
    "/api/produtos/desativar": desativar_produto,
}


# ---------------------------------------------------------------------------
# SERVIDOR HTTP
# Uma única classe trata tudo. do_GET serve o HTML e as consultas; do_POST
# trata as operações que gravam. Toda resposta é JSON no mesmo formato:
#   sucesso -> {"ok": true,  ...dados}
#   erro    -> {"ok": false, "erro": "mensagem"}
# ---------------------------------------------------------------------------
class Handler(http.server.BaseHTTPRequestHandler):

    def _json(self, status, payload):
        """Escreve uma resposta JSON com o status HTTP dado."""
        corpo = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _ok(self, dados=None):
        payload = {"ok": True}
        if dados:
            payload.update(dados)
        self._json(200, payload)

    def _erro(self, mensagem, status=400):
        self._json(status, {"ok": False, "erro": mensagem})

    def _extrai_msg_sql(self, erro):
        """Puxa a mensagem legível de dentro do erro do pyodbc (que vem cheio de
        códigos). É aqui que 'Saldo insuficiente...' do THROW chega ao front.
        O erro do pyodbc é algo como:
          ('50001', '[...][ODBC Driver 17...][SQL Server]Saldo insuficiente... (50001) (SQLExecDirectW)')
        Pego o texto depois do último ']' e tiro a sujeira técnica do fim."""
        texto = str(erro).split("]")[-1].strip()
        # Remove o rabo tipo " (50001) (SQLExecDirectW)')" que o ODBC anexa.
        texto = re.sub(r"\s*\(\d+\)\s*\(SQL\w+\)'?\)?\s*$", "", texto)
        texto = texto.rstrip("')\" ")   # tira aspas/parênteses soltos no fim
        return texto or "Erro no banco de dados."

    # ---- GET: serve o HTML e as consultas -------------------------------
    def do_GET(self):
        caminho = self.path.split("?")[0]   # ignora querystring

        # Raiz -> devolve a página. Servida daqui para não dar CORS.
        if caminho in ("/", "/index.html"):
            return self._servir_html()

        # Rotas de consulta do contrato.
        if caminho in ROTAS_GET:
            try:
                return self._ok({"dados": ROTAS_GET[caminho]()})
            except Exception as e:
                return self._erro(self._extrai_msg_sql(e), 500)

        # Qualquer outro GET é pedido de arquivo estático (a logo, imagens, css...).
        return self._servir_estatico(caminho)

    # ---- POST: operações que gravam -------------------------------------
    def do_POST(self):
        caminho = self.path.split("?")[0]
        funcao = ROTAS_POST.get(caminho)
        if funcao is None:
            return self._erro("Rota não encontrada.", 404)

        # Lê o corpo (JSON) enviado pelo front.
        try:
            tamanho = int(self.headers.get("Content-Length", 0))
            bruto = self.rfile.read(tamanho) if tamanho else b"{}"
            dados = json.loads(bruto.decode("utf-8"))
        except (ValueError, json.JSONDecodeError):
            return self._erro("Corpo da requisição não é um JSON válido.")

        # Chama a operação. Erros de regra do banco (ex.: saldo insuficiente,
        # nome duplicado, CHECK violado) viram mensagem amigável no front.
        try:
            resultado = funcao(dados)
            return self._ok(resultado)
        except KeyError as e:
            return self._erro(f"Campo obrigatório ausente: {e.args[0]}.")
        except pyodbc.Error as e:
            return self._erro(self._extrai_msg_sql(e))
        except Exception as e:
            return self._erro(self._extrai_msg_sql(e), 500)

    # ---- utilidades -----------------------------------------------------
    def _servir_html(self):
        """Lê o arquivo HTML do disco e devolve. Se não achar, avisa claramente."""
        try:
            with open(ARQUIVO_HTML, "rb") as f:
                corpo = f.read()
        except FileNotFoundError:
            return self._erro(f"Arquivo '{ARQUIVO_HTML}' não encontrado.", 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def _servir_estatico(self, caminho):
        """Serve um arquivo do disco (imagem, css, etc.) de forma segura.
        Só entrega o que estiver DENTRO de BASE_DIR: normaliza o caminho e
        recusa qualquer tentativa de sair da pasta (../.. e afins)."""
        # Monta o caminho relativo limpo a partir da URL.
        relativo = posixpath.normpath(caminho.lstrip("/"))
        destino = os.path.normpath(os.path.join(BASE_DIR, relativo))

        # Trava de segurança: o destino tem que continuar dentro de BASE_DIR.
        if not destino.startswith(BASE_DIR) or not os.path.isfile(destino):
            return self._erro("Arquivo não encontrado.", 404)

        # Descobre o tipo (image/png, text/css...) pelo nome do arquivo.
        tipo = mimetypes.guess_type(destino)[0] or "application/octet-stream"
        with open(destino, "rb") as f:
            corpo = f.read()
        self.send_response(200)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def log_message(self, *args):
        """Silencia o log padrão barulhento; deixa só o que a gente imprime."""
        pass


def main():
    # ThreadingTCPServer: atende uma requisição sem travar as outras. Suficiente
    # e seguro aqui porque cada requisição usa a sua própria conexão ao banco.
    with socketserver.ThreadingTCPServer(("", PORTA), Handler) as servidor:
        endereco = f"http://localhost:{PORTA}"
        print()
        print("=" * 68)
        print(f" SISTEMA NO AR:  {endereco}")
        print("=" * 68)
        print(f" Banco ....... {BANCO}")
        print(f" Servidor .... {SERVIDOR}")
        print(f" Driver ...... {DRIVER}")
        print(f" Pagina ...... {ARQUIVO_HTML}")
        print("=" * 68)
        print(" Ctrl+C para parar. Feche esta janela para desligar.")
        print()

        # Abre o navegador sozinho. Neste ponto o socket JÁ está escutando
        # (quem faz isso é o construtor do ThreadingTCPServer, na linha do
        # `with`), então a primeira requisição do navegador fica na fila e é
        # atendida assim que o serve_forever() começar. Não há corrida.
        try:
            webbrowser.open(endereco)
        except Exception:
            pass   # sem navegador disponível o sistema continua funcionando
        try:
            servidor.serve_forever()
        except KeyboardInterrupt:
            print("\nServidor encerrado.")


if __name__ == "__main__":
    main()
