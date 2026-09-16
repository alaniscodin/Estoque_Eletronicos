# Estoque de Eletrônicos — MiauStore
### Trabalho de SQL · versão **teste**

Sistema de controle de estoque com banco **SQL Server**, back-end em **Python
puro** (sem framework) e front-end em **HTML/CSS/JavaScript**.

| | |
|---|---|
| Banco de dados | `EstoqueEletronicos_Teste` |
| Endereço | <http://localhost:8001> |
| Front-end | `mockup-estoque.html` + `estilo.css` — estrutura e aparência separadas |

> **Esta é a versão de TESTE.** Ela usa um banco (`EstoqueEletronicos_Teste`) e uma porta
> (8001) próprios, então pode ser instalada e rodada **ao mesmo tempo** que
> a versão normal, sem uma atrapalhar a outra. O código das duas é o mesmo; a
> diferença de estrutura está na tabela acima.

---

## Como rodar (Windows)

**São dois duplo-cliques, nesta ordem:**

| | Arquivo | O que faz | Quando |
|---|---|---|---|
| 1 | **`1-INSTALAR.bat`** | Instala a biblioteca `pyodbc` e cria o banco com os dados de exemplo | Uma vez só |
| 2 | **`2-INICIAR.bat`** | Sobe o servidor e abre o navegador | Toda vez que for usar |

Para desligar: feche a janela preta do servidor (ou tecle `Ctrl+C` nela).

### O que precisa estar instalado antes

- **Python 3.8 ou mais novo** — <https://python.org/downloads>
  Na instalação, marque a caixa **"Add Python to PATH"**.
- **SQL Server** — qualquer uma destas serve:
  - SQL Server **Express** (gratuito)
  - **LocalDB** (vem junto com o Visual Studio)
  - SQL Server Developer

Não é preciso configurar endereço nem senha: o `conexao.py` testa as
instalações mais comuns e usa a primeira que responder. Ele também entra com
o **login do Windows**, então não há usuário nem senha para digitar.

---

## Os arquivos

| Arquivo | Papel |
|---|---|
| `estoque.sql` | **O banco.** Tabelas, restrições, a view e as procedures. Recria tudo do zero. |
| `app.py` | **O back-end.** Servidor HTTP da biblioteca padrão; expõe as rotas `/api/*`. |
| `conexao.py` | Descobre qual driver ODBC e qual instância de SQL Server existem na máquina. |
| `configurar_banco.py` | Executa o `estoque.sql` lote a lote (é o que o `1-INSTALAR.bat` chama). |
| `mockup-estoque.html` | **O front-end.** Estrutura da página e o JavaScript. |
| `estilo.css` | **A aparência.** Cores, layout, tema escuro e os três degraus do responsivo. |
| `imagens/`, `img/` | Logo e imagens da loja. |

---

## Para quem vai corrigir: onde está cada coisa

### A decisão central da modelagem

**O produto não tem coluna de quantidade.** Cada entrada e cada saída é uma
linha nova em `movimentacao`; o estoque atual é a **soma** dessas linhas,
exposta pela view `vw_estoque_atual`.

É a lógica de um extrato bancário: o saldo não é digitado, é o resultado do
que entrou e do que saiu. Isso dá histórico completo, auditoria e uma
transação de verdade na baixa de estoque.

### Mapa do `estoque.sql`

| Requisito | Onde está | Observação |
|---|---|---|
| Tabelas | seção 1 | 5 tabelas, todas as restrições **nomeadas** (`PK_`, `FK_`, `UQ_`, `CK_`, `DF_`) |
| Normalização | `categoria`, `marca`, `fornecedor` | tabelas próprias em vez de texto solto no produto |
| Documentação no catálogo | seção 2 | `sp_addextendedproperty` nas colunas discutíveis |
| View | seção 3 | `vw_estoque_atual` — `LEFT JOIN` + `SUM(CASE...)`; é a base de tudo |
| Procedures | seção 4 | cadastrar, editar, desativar, entrada, saída |
| Transação | `sp_movimentacao_saida` | `BEGIN TRAN` + `UPDLOCK, HOLDLOCK` + `THROW 50001` se faltar saldo |
| Soft delete | `sp_produto_desativar` | marca `ativo = 0`; nunca `DELETE`, para preservar o histórico |
| Dados de exemplo | seção 5 | 15 produtos e ~31 movimentações, inseridos **pelas próprias procedures** |
| Consultas de negócio | seção 6 | as 4 consultas, cada uma com a pergunta que responde |

### As 4 consultas, e onde elas aparecem na tela

| # | Pergunta | Onde ver rodando |
|---|---|---|
| 1 | O que precisa ser reposto? | linhas vermelhas com a etiqueta "abaixo do mínimo" |
| 2 | Quanto de dinheiro está parado na prateleira? | rodapé da tabela: "Valor imobilizado" |
| 3 | Quais itens giram mais? | `SELECT TOP (5)` no fim do `estoque.sql` |
| 4 | Quanto saiu por venda e por perda no mês? | `GROUP BY motivo` no fim do `estoque.sql` |

### As restrições que valem discussão

| Restrição | O que impede |
|---|---|
| `CK_mov_tipo` | tipo fora de `'E'`/`'S'` |
| `CK_mov_quantidade` | quantidade zero ou negativa — quem dá o sinal é o **tipo**, não o número |
| `CK_mov_motivo` | motivo incoerente com o tipo (ex.: uma `VENDA` marcada como entrada) |
| `CK_mov_fornecedor` | fornecedor numa saída; ou entrada por `COMPRA` **sem** fornecedor |

### Como testar a regra de negócio no sistema

1. Abra o sistema e escolha um produto com estoque baixo.
2. Clique em **Saída** e peça uma quantidade **maior que o estoque atual**.
3. A mensagem *"Saldo insuficiente para a saída solicitada."* aparece na tela.

Essa mensagem **vem do banco**, não do JavaScript: é o `THROW 50001` da
procedure `sp_movimentacao_saida`. O Python só repassa o texto. É a prova de
que a regra está no banco, e não na tela.

### O front-end

Uma tela só. A tabela lista os produtos e cada linha traz seus próprios
botões (entrada, saída, editar, desativar) — como o botão já está na linha,
o produto vem escolhido e nenhum formulário precisa de uma caixa de seleção
de produto. O painel de baixo é **um só** para as cinco ações; ele troca de
título e de campos conforme o botão clicado.

Acessibilidade e responsividade que valem conferir:

- **Botões A− / A+** mudam o tamanho de toda a interface (tudo é medido em `rem`).
- **Modo escuro** troca um atributo no `<html>`; nenhuma outra regra de CSS
  precisa saber que ele existe — todas usam variáveis de cor.
- **Responsivo em três degraus:** até 1100px a tabela aperta; até 900px cada
  produto vira um **cartão**; até 640px a página inteira vira layout de celular.
  Diminua a janela do navegador para ver.
- O alerta de estoque baixo **não é só a cor vermelha**: tem a etiqueta escrita
  "abaixo do mínimo", para quem não distingue cores.

---

## Se der problema

| Sintoma | O que fazer |
|---|---|
| `Python nao encontrado` | Instale o Python e marque **"Add Python to PATH"** |
| `NAO FOI POSSIVEL CONECTAR AO BANCO` | O serviço do SQL Server está rodando? (tecla Windows → "Serviços" → procure "SQL Server") |
| Instância com outro nome | No PowerShell, antes de rodar: `$env:SQLSERVER_HOST = "localhost\SUAINSTANCIA"` |
| `Only one usage of each socket address` | Já existe um servidor na porta 8001. Feche a outra janela preta. |
| A tela abre mas a tabela fica vazia | Rode o `1-INSTALAR.bat` — o banco ainda não foi criado |
| Mudei o CSS e nada mudou | `Ctrl+F5` no navegador (recarrega ignorando o cache) |

Para recriar o banco do zero a qualquer momento, é só rodar o
`1-INSTALAR.bat` de novo — ele apaga e refaz tudo.
