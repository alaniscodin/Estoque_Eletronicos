/* ==========================================================================
   BANCO-COMPLETO.sql  —  O BANCO INTEIRO NUM ARQUIVO SÓ
   Trabalho de SQL · Estoque de Eletrônicos (MiauStore) · versão teste
----------------------------------------------------------------------------
   O QUE É ESTE ARQUIVO
   Uma cópia completa do banco `EstoqueEletronicos_Teste`: estrutura E dados.
   Rodar este arquivo do começo ao fim deixa o banco exatamente como estava
   em 09/09/2026 — 15 produtos e 31 movimentações, com os mesmos ids e
   as mesmas datas.

   Gerado a partir do banco em funcionamento. As seções 0 a 4 e a 6 vêm do
   `estoque.sql`, com os comentários originais.

----------------------------------------------------------------------------
   COMO RODAR — três caminhos, escolha um

   A) SQL SERVER MANAGEMENT STUDIO (SSMS) — o mais comum
      1. Abrir o SSMS e conectar na sua instância
      2. Arquivo > Abrir > Arquivo...  e escolher este BANCO-COMPLETO.sql
      3. Teclar F5 (ou clicar em "Executar")
      Não precisa escolher o banco na caixa de cima: o script começa no
      `master` e cria o `EstoqueEletronicos_Teste` sozinho.

   B) LINHA DE COMANDO (sem abrir o SSMS)
      Abrir o PowerShell na pasta deste arquivo e rodar:

          sqlcmd -S "(localdb)\MSSQLLocalDB" -i BANCO-COMPLETO.sql

      Trocando o -S pela sua instância, se for outra
      (ex.: -S "localhost\SQLEXPRESS").

   C) PELO PRÓPRIO SISTEMA — duplo-clique no `1-INSTALAR.bat`
      Ele usa o `estoque.sql` (que faz a mesma coisa, mas semeia os
      dados chamando as procedures). Não precisa deste arquivo.

   DEPOIS DE CRIAR O BANCO, para abrir a tela:
      duplo-clique no `2-INICIAR.bat`  ->  http://localhost:8001

----------------------------------------------------------------------------
   ATENÇÃO: a seção 0 APAGA o banco `EstoqueEletronicos_Teste` se ele já existir, e recria do
   zero. Tudo o que estiver lá dentro se perde. É proposital — o arquivo
   serve justamente para deixar o banco num estado conhecido.

----------------------------------------------------------------------------
   ÍNDICE
     0. Recriação do banco
     1. Tabelas .................. estrutura e restrições nomeadas
     2. Documentação no catálogo . sp_addextendedproperty
     3. View ..................... vw_estoque_atual, o cálculo do estoque
     4. Procedures ............... o CRUD e as movimentações
     5. Os dados ................. INSERTs com os ids e as datas exatos
     6. Consultas de negócio ..... as 4 perguntas que o modelo responde
     7. Ver o banco inteiro ...... só consulta; inspeciona tudo
   ========================================================================== */

/* --------------------------------------------------------------------------
   0. RECRIAÇÃO DO BANCO
   Rodar no contexto do `master` para poder derrubar o banco inteiro.
   SINGLE_USER + ROLLBACK IMMEDIATE: expulsa conexões presas e evita o
   clássico "database is in use" na hora da apresentação.
   -------------------------------------------------------------------------- */
USE master;
GO

IF DB_ID('EstoqueEletronicos_Teste') IS NOT NULL
BEGIN
    ALTER DATABASE EstoqueEletronicos_Teste SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE EstoqueEletronicos_Teste;
END
GO

CREATE DATABASE EstoqueEletronicos_Teste;
GO

USE EstoqueEletronicos_Teste;
GO


/* ==========================================================================
   1. TABELAS
   Ordem de criação = ordem de dependência: as tabelas "pai" (categoria,
   marca, fornecedor) vêm antes das que as referenciam (produto, movimentacao).
   Toda restrição é NOMEADA (CK_/FK_/UQ_) — nome de restrição aparece na
   mensagem de erro e no diagrama, o que ajuda a explicar o modelo.
   ========================================================================== */


/* --------------------------------------------------------------------------
   categoria — lista de categorias (Notebook, Celular, ...).
   Existe como TABELA, e não como texto solto no produto, por NORMALIZAÇÃO:
   evita repetir "Notebook" em N linhas e elimina erro de digitação.
   -------------------------------------------------------------------------- */
CREATE TABLE categoria (
    id    INT IDENTITY(1,1)  CONSTRAINT PK_categoria PRIMARY KEY,
    nome  VARCHAR(40)        NOT NULL
          CONSTRAINT UQ_categoria_nome UNIQUE   -- não faz sentido duas categorias iguais
);
GO

/* --------------------------------------------------------------------------
   marca — mesma ideia da categoria. Renomear "Samsung" vira UPDATE de 1 linha.
   -------------------------------------------------------------------------- */
CREATE TABLE marca (
    id    INT IDENTITY(1,1)  CONSTRAINT PK_marca PRIMARY KEY,
    nome  VARCHAR(40)        NOT NULL
          CONSTRAINT UQ_marca_nome UNIQUE
);
GO

/* --------------------------------------------------------------------------
   fornecedor — de quem se compra. Só é usado nas ENTRADAS por compra.
   O CNPJ é UNIQUE: é o identificador legal, não pode repetir.
   -------------------------------------------------------------------------- */
CREATE TABLE fornecedor (
    id        INT IDENTITY(1,1) CONSTRAINT PK_fornecedor PRIMARY KEY,
    nome      VARCHAR(80)  NOT NULL,               -- obrigatório
    cnpj      CHAR(14)     NULL
              CONSTRAINT UQ_fornecedor_cnpj UNIQUE, -- guardado só com dígitos, sem máscara
    telefone  VARCHAR(20)  NULL,
    email     VARCHAR(120) NULL
);
GO

/* --------------------------------------------------------------------------
   produto — o item em si. REPARE: não há coluna de quantidade/estoque.
   O estoque vem da soma das movimentações (view mais abaixo).

     nome           UNIQUE  -> substitui o SKU. O grupo busca por nome; para o
                              nome poder identificar, ele precisa ser único.
     categoria_id \ FK      -> seleção sempre por id, nunca por texto: o front
     marca_id     /            mostra o nome e envia o id (imune a acento/caixa).
     ativo          BIT     -> soft delete. Produto com histórico NÃO se apaga;
                              o "D" do CRUD é ativo = 0 (ver extended property).
   -------------------------------------------------------------------------- */
CREATE TABLE produto (
    id              INT IDENTITY(1,1) CONSTRAINT PK_produto PRIMARY KEY,
    nome            VARCHAR(100) NOT NULL
                    CONSTRAINT UQ_produto_nome UNIQUE,
    categoria_id    INT NOT NULL
                    CONSTRAINT FK_produto_categoria REFERENCES categoria(id),
    marca_id        INT NOT NULL
                    CONSTRAINT FK_produto_marca     REFERENCES marca(id),
    preco_custo     DECIMAL(10,2) NOT NULL
                    CONSTRAINT CK_produto_custo  CHECK (preco_custo  >= 0),
    preco_venda     DECIMAL(10,2) NOT NULL
                    CONSTRAINT CK_produto_venda  CHECK (preco_venda  >= 0),
    estoque_minimo  INT NOT NULL
                    CONSTRAINT DF_produto_minimo DEFAULT (0)
                    CONSTRAINT CK_produto_minimo CHECK (estoque_minimo >= 0),
    ativo           BIT NOT NULL
                    CONSTRAINT DF_produto_ativo  DEFAULT (1)   -- nasce ativo
);
GO

/* --------------------------------------------------------------------------
   movimentacao — o livro-caixa do estoque. Uma linha por entrada e por saída.
   Entrada e saída moram na MESMA tabela de propósito: permite um extrato único
   e o saldo por UMA soma só. Separar em duas tabelas exigiria UNION em toda
   consulta.

   Restrições que valem ponto:
     CK_mov_tipo         -> tipo só pode ser 'E' (entrada) ou 'S' (saída)
     CK_mov_quantidade   -> quantidade SEMPRE positiva; o sinal quem dá é o tipo
     CK_mov_motivo       -> motivo coerente com o tipo (lista fixa, não texto
                            livre — texto livre não agrupa no relatório)
     CK_mov_fornecedor   -> fornecedor obrigatório SÓ na entrada por compra,
                            e proibido em qualquer saída
   -------------------------------------------------------------------------- */
CREATE TABLE movimentacao (
    id             INT IDENTITY(1,1) CONSTRAINT PK_movimentacao PRIMARY KEY,
    produto_id     INT NOT NULL
                   CONSTRAINT FK_mov_produto    REFERENCES produto(id),
    tipo           CHAR(1) NOT NULL
                   CONSTRAINT CK_mov_tipo       CHECK (tipo IN ('E','S')),
    quantidade     INT NOT NULL
                   CONSTRAINT CK_mov_quantidade CHECK (quantidade > 0),
    motivo         VARCHAR(20) NOT NULL,
    fornecedor_id  INT NULL
                   CONSTRAINT FK_mov_fornecedor REFERENCES fornecedor(id),
    data           DATETIME2 NOT NULL
                   CONSTRAINT DF_mov_data DEFAULT (SYSDATETIME()), -- o banco carimba; o front nunca envia

    /* Motivo tem que casar com o tipo. AJUSTE_INVENTARIO vale para os dois
       lados (sobrou ou faltou no balanço). */
    CONSTRAINT CK_mov_motivo CHECK (
        (tipo = 'E' AND motivo IN ('COMPRA','DEVOLUCAO_CLIENTE','AJUSTE_INVENTARIO')) OR
        (tipo = 'S' AND motivo IN ('VENDA','PERDA','AJUSTE_INVENTARIO'))
    ),

    /* Coerência do fornecedor — a restrição mais "cara" do modelo:
         saída ................... nunca tem fornecedor
         entrada por compra ...... exige fornecedor
         entrada não-compra ...... não tem fornecedor (devolução/ajuste) */
    CONSTRAINT CK_mov_fornecedor CHECK (
        (tipo = 'S' AND fornecedor_id IS NULL) OR
        (tipo = 'E' AND motivo =  'COMPRA' AND fornecedor_id IS NOT NULL) OR
        (tipo = 'E' AND motivo <> 'COMPRA' AND fornecedor_id IS NULL)
    )
);
GO

/* Índice de apoio: quase toda consulta agrupa movimentação por produto
   (o cálculo do saldo). O índice evita varrer a tabela inteira toda vez. */
CREATE INDEX IX_mov_produto ON movimentacao(produto_id);
GO


/* ==========================================================================
   2. DOCUMENTAÇÃO NO CATÁLOGO (sp_addextendedproperty)
   A descrição fica PRESA à coluna, dentro do próprio banco. Sobrevive mesmo
   se o .sql se perder e aparece nas ferramentas de modelagem. Aplicada nas
   colunas discutíveis — as que o professor mais provavelmente vai questionar.
   ========================================================================== */
EXEC sp_addextendedproperty
     @name=N'MS_Description',
     @value=N'Soft delete. 1 = ativo (aparece na lista), 0 = desativado. Produto com movimentação nunca é apagado para preservar o histórico.',
     @level0type=N'SCHEMA', @level0name=N'dbo',
     @level1type=N'TABLE',  @level1name=N'produto',
     @level2type=N'COLUMN', @level2name=N'ativo';

EXEC sp_addextendedproperty
     @name=N'MS_Description',
     @value=N'Quantidade sempre POSITIVA. Quem define entrada/saida é a coluna tipo (E/S), não o sinal do número.',
     @level0type=N'SCHEMA', @level0name=N'dbo',
     @level1type=N'TABLE',  @level1name=N'movimentacao',
     @level2type=N'COLUMN', @level2name=N'quantidade';

EXEC sp_addextendedproperty
     @name=N'MS_Description',
     @value=N'Preenchido SOMENTE em entrada por compra. Nulo em toda saida e em entrada de devolucao/ajuste. Regra garantida pela CK_mov_fornecedor.',
     @level0type=N'SCHEMA', @level0name=N'dbo',
     @level1type=N'TABLE',  @level1name=N'movimentacao',
     @level2type=N'COLUMN', @level2name=N'fornecedor_id';
GO


/* ==========================================================================
   3. VIEW  vw_estoque_atual  —  O CORAÇÃO DO MODELO
   Todas as outras consultas nascem daqui.

   Pontos que valem explicar na banca:
     - LEFT JOIN de produto -> movimentacao: com JOIN normal, um produto SEM
       nenhuma movimentação (estoque zero) sumiria da lista. Não pode sumir.
     - ISNULL(...,0): esse produto sem movimentação tem saldo 0, não NULL.
     - SUM(CASE ...): entrada soma, saída subtrai. É aqui que o "saldo por uma
       soma só" acontece.
     - JOIN em categoria/marca traz o NOME junto do id, pronto para a tela.
   ========================================================================== */
CREATE VIEW vw_estoque_atual AS
SELECT
    p.id                        AS produto_id,
    p.nome                      AS produto,
    c.id                        AS categoria_id,
    c.nome                      AS categoria,
    m.id                        AS marca_id,
    m.nome                      AS marca,
    p.preco_custo,
    p.preco_venda,
    p.estoque_minimo,
    p.ativo,
    -- saldo = entradas - saídas; sem movimentação nenhuma, 0.
    ISNULL(SUM(CASE WHEN mv.tipo = 'E' THEN mv.quantidade
                    WHEN mv.tipo = 'S' THEN -mv.quantidade END), 0) AS estoque_atual
FROM       produto      p
JOIN       categoria    c  ON c.id = p.categoria_id
JOIN       marca        m  ON m.id = p.marca_id
LEFT JOIN  movimentacao mv ON mv.produto_id = p.id
GROUP BY
    p.id, p.nome, c.id, c.nome, m.id, m.nome,
    p.preco_custo, p.preco_venda, p.estoque_minimo, p.ativo;
GO


/* ==========================================================================
   4. PROCEDURES
   A regra de negócio mora no banco, em transação. O Python só chama.
   ========================================================================== */


/* --------------------------------------------------------------------------
   sp_produto_cadastrar — o "C" do CRUD.
   Sem quantidade inicial de propósito: o estoque nasce em zero e sobe com a
   primeira entrada. Isso mantém a regra "estoque só existe como movimentação".
   -------------------------------------------------------------------------- */
CREATE PROCEDURE sp_produto_cadastrar
    @nome           VARCHAR(100),
    @categoria_id   INT,
    @marca_id       INT,
    @preco_custo    DECIMAL(10,2),
    @preco_venda    DECIMAL(10,2),
    @estoque_minimo INT
AS
BEGIN
    SET NOCOUNT ON;   -- não devolve "(1 row affected)"; deixa a resposta limpa p/ o Python
    INSERT INTO produto (nome, categoria_id, marca_id, preco_custo, preco_venda, estoque_minimo)
    VALUES (@nome, @categoria_id, @marca_id, @preco_custo, @preco_venda, @estoque_minimo);
    -- devolve o id recém-criado, útil para o front atualizar a linha
    SELECT SCOPE_IDENTITY() AS novo_id;
END
GO


/* --------------------------------------------------------------------------
   sp_produto_editar — o "U" do CRUD (update dos dados cadastrais).
   Altera só o cadastro do produto (nome, categoria, marca, preços, mínimo).
   NÃO mexe em estoque: quantidade nunca é editada aqui — ela só muda por
   entrada/saída, que são movimentações. Isso mantém a regra central intacta.
   -------------------------------------------------------------------------- */
CREATE PROCEDURE sp_produto_editar
    @produto_id     INT,
    @nome           VARCHAR(100),
    @categoria_id   INT,
    @marca_id       INT,
    @preco_custo    DECIMAL(10,2),
    @preco_venda    DECIMAL(10,2),
    @estoque_minimo INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE produto
       SET nome           = @nome,
           categoria_id   = @categoria_id,
           marca_id       = @marca_id,
           preco_custo    = @preco_custo,
           preco_venda    = @preco_venda,
           estoque_minimo = @estoque_minimo
     WHERE id = @produto_id;
END
GO


/* --------------------------------------------------------------------------
   sp_produto_desativar — o "D" do CRUD, que aqui é soft delete.
   Não roda DELETE: marca ativo = 0. O histórico de movimentações continua
   intacto e a integridade referencial nunca é violada.
   -------------------------------------------------------------------------- */
CREATE PROCEDURE sp_produto_desativar
    @produto_id INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE produto SET ativo = 0 WHERE id = @produto_id;
END
GO


/* --------------------------------------------------------------------------
   sp_movimentacao_entrada — registra uma ENTRADA.
   Entrada não precisa validar saldo (só aumenta). Mas precisa da coerência do
   fornecedor, que já é garantida pela CK_mov_fornecedor na tabela — se o
   front mandar errado, o INSERT falha e o erro sobe.
   -------------------------------------------------------------------------- */
CREATE PROCEDURE sp_movimentacao_entrada
    @produto_id    INT,
    @quantidade    INT,
    @motivo        VARCHAR(20),
    @fornecedor_id INT = NULL          -- NULL quando o motivo não é compra
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO movimentacao (produto_id, tipo, quantidade, motivo, fornecedor_id)
    VALUES (@produto_id, 'E', @quantidade, @motivo, @fornecedor_id);
END
GO


/* --------------------------------------------------------------------------
   sp_movimentacao_saida — registra uma SAÍDA.  ***A procedure mais importante.***
   É onde a transação de verdade acontece: não se pode vender o que não há.

   Por que transação + trava:
     Entre "ler o saldo" e "gravar a saída" duas vendas simultâneas poderiam
     ler o mesmo saldo e vender além do estoque. O par (UPDLOCK, HOLDLOCK)
     segura as linhas do produto até o COMMIT, serializando as saídas do mesmo
     item. XACT_ABORT ON garante que qualquer erro desfaz tudo.
   -------------------------------------------------------------------------- */
CREATE PROCEDURE sp_movimentacao_saida
    @produto_id INT,
    @quantidade INT,
    @motivo     VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;      -- erro em transação = rollback automático

    BEGIN TRY
        BEGIN TRANSACTION;

            /* Saldo atual do produto, com as linhas travadas até o fim da
               transação para impedir venda concorrente além do estoque. */
            DECLARE @saldo INT;
            SELECT @saldo = ISNULL(SUM(CASE WHEN tipo = 'E' THEN quantidade
                                            ELSE -quantidade END), 0)
            FROM movimentacao WITH (UPDLOCK, HOLDLOCK)
            WHERE produto_id = @produto_id;

            /* Regra de negócio: não deixa o saldo ficar negativo.
               THROW devolve mensagem clara — é o texto que o front mostra
               no elemento #erro ("saldo insuficiente"). */
            IF @saldo < @quantidade
                THROW 50001, 'Saldo insuficiente para a saída solicitada.', 1;

            INSERT INTO movimentacao (produto_id, tipo, quantidade, motivo, fornecedor_id)
            VALUES (@produto_id, 'S', @quantidade, @motivo, NULL); -- saída nunca tem fornecedor

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;  -- desfaz a saída pela metade
        THROW;                                    -- repassa o erro para o Python/front
    END CATCH
END
GO


/* ==========================================================================
   5. OS DADOS — o conteúdo real do banco, linha por linha
   --------------------------------------------------------------------------
   DIFERENÇA EM RELAÇÃO AO estoque.sql:
   Lá os dados entram chamando as PROCEDURES (sp_movimentacao_entrada e
   sp_movimentacao_saida). É mais bonito de defender — os dados de exemplo
   passam pelas mesmas regras da aplicação — mas as datas ficam com o
   SYSDATETIME() do momento em que o script rodou, e os ids dependem da ordem.

   Aqui é o contrário: são INSERTs diretos, com os ids e as datas EXATOS.
   O objetivo deste arquivo é reproduzir o banco fielmente, como uma cópia.

   SET IDENTITY_INSERT: as colunas `id` são IDENTITY, ou seja, o banco as
   preenche sozinho e normalmente RECUSA um valor escrito à mão. Este comando
   suspende essa recusa para uma tabela por vez, para que os ids da cópia
   fiquem iguais aos do original — se mudassem, as chaves estrangeiras de
   `produto` e `movimentacao` apontariam para os registros errados.
   ========================================================================== */

USE EstoqueEletronicos_Teste;
GO


/* --- categoria: 5 registros --- */
SET IDENTITY_INSERT categoria ON;
INSERT INTO categoria (id, nome) VALUES
    (1, N'Notebook'),
    (2, N'Celular'),
    (3, N'Áudio'),
    (4, N'Acessório'),
    (5, N'Monitor');
SET IDENTITY_INSERT categoria OFF;
GO

/* --- marca: 7 registros --- */
SET IDENTITY_INSERT marca ON;
INSERT INTO marca (id, nome) VALUES
    (1, N'Dell'),
    (2, N'Samsung'),
    (3, N'JBL'),
    (4, N'Logitech'),
    (5, N'Acer'),
    (6, N'LG'),
    (7, N'Apple');
SET IDENTITY_INSERT marca OFF;
GO

/* --- fornecedor: 3 registros --- */
SET IDENTITY_INSERT fornecedor ON;
INSERT INTO fornecedor (id, nome, cnpj, telefone, email) VALUES
    (1, N'Distribuidora Tech Sul', N'11222333000181', N'(51) 3333-1000', N'vendas@techsul.com.br'),
    (2, N'Nova Import', N'44555666000199', N'(11) 4004-2000', N'comercial@novaimport.com.br'),
    (3, N'Eletro Atacado SP', N'77888999000155', N'(11) 2500-3000', N'pedidos@eletroatacado.com.br');
SET IDENTITY_INSERT fornecedor OFF;
GO

/* --- produto: 15 registros --- */
SET IDENTITY_INSERT produto ON;
INSERT INTO produto (id, nome, categoria_id, marca_id, preco_custo, preco_venda, estoque_minimo, ativo) VALUES
    (1, N'Notebook Dell Inspiron 15', 1, 1, 2800.00, 3499.00, 5, 1),
    (2, N'Notebook Acer Aspire 5', 1, 5, 2100.00, 2799.00, 6, 1),
    (3, N'Notebook Apple MacBook Air', 1, 7, 7200.00, 8999.00, 3, 1),
    (4, N'Celular Samsung Galaxy S24', 2, 2, 3400.00, 4199.00, 8, 1),
    (5, N'Celular Apple iPhone 15', 2, 7, 5100.00, 6499.00, 6, 1),
    (6, N'Fone JBL Tune 510 Preto', 3, 3, 120.00, 199.00, 15, 1),
    (7, N'Caixa JBL Go 3', 3, 3, 180.00, 279.00, 12, 1),
    (8, N'Headset Logitech H390', 3, 4, 140.00, 229.00, 10, 1),
    (9, N'Mouse Logitech M170', 4, 4, 42.00, 79.90, 10, 1),
    (10, N'Teclado Logitech K120', 4, 4, 55.00, 99.90, 10, 1),
    (11, N'Carregador Turbo 33W', 4, 2, 35.00, 89.90, 20, 1),
    (12, N'Cabo USB-C 2m', 4, 2, 18.00, 49.90, 25, 1),
    (13, N'Monitor LG 24 IPS', 5, 6, 750.00, 999.00, 5, 1),
    (14, N'Monitor Dell 27 QHD', 5, 1, 1400.00, 1899.00, 4, 1),
    (15, N'Webcam Logitech C920', 4, 4, 260.00, 399.00, 8, 1);
SET IDENTITY_INSERT produto OFF;
GO

/* --- movimentacao: 31 registros --- */
SET IDENTITY_INSERT movimentacao ON;
INSERT INTO movimentacao (id, produto_id, tipo, quantidade, motivo, fornecedor_id, data) VALUES
    (1, 1, N'E', 15, N'COMPRA', 1, '2026-09-05T21:33:15.230023'),
    (2, 2, N'E', 10, N'COMPRA', 1, '2026-09-05T21:33:15.231521'),
    (3, 3, N'E', 4, N'COMPRA', 2, '2026-09-05T21:33:15.231521'),
    (4, 4, N'E', 12, N'COMPRA', 2, '2026-09-05T21:33:15.232021'),
    (5, 5, N'E', 8, N'COMPRA', 2, '2026-09-05T21:33:15.232520'),
    (6, 6, N'E', 60, N'COMPRA', 3, '2026-09-05T21:33:15.232520'),
    (7, 7, N'E', 40, N'COMPRA', 3, '2026-09-05T21:33:15.233021'),
    (8, 8, N'E', 25, N'COMPRA', 1, '2026-09-05T21:33:15.233021'),
    (9, 9, N'E', 50, N'COMPRA', 3, '2026-09-05T21:33:15.233521'),
    (10, 10, N'E', 45, N'COMPRA', 3, '2026-09-05T21:33:15.233521'),
    (11, 11, N'E', 70, N'COMPRA', 3, '2026-09-05T21:33:15.234021'),
    (12, 12, N'E', 90, N'COMPRA', 3, '2026-09-05T21:33:15.234021'),
    (13, 13, N'E', 10, N'COMPRA', 1, '2026-09-05T21:33:15.234521'),
    (14, 14, N'E', 6, N'COMPRA', 1, '2026-09-05T21:33:15.234521'),
    (15, 15, N'E', 14, N'COMPRA', 2, '2026-09-05T21:33:15.234521'),
    (16, 1, N'E', 2, N'DEVOLUCAO_CLIENTE', NULL, '2026-09-05T21:33:15.235021'),
    (17, 9, N'E', 3, N'DEVOLUCAO_CLIENTE', NULL, '2026-09-05T21:33:15.235021'),
    (18, 1, N'S', 5, N'VENDA', NULL, '2026-09-05T21:33:15.241080'),
    (19, 2, N'S', 8, N'VENDA', NULL, '2026-09-05T21:33:15.242096'),
    (20, 3, N'S', 2, N'VENDA', NULL, '2026-09-05T21:33:15.242096'),
    (21, 4, N'S', 11, N'VENDA', NULL, '2026-09-05T21:33:15.242096'),
    (22, 5, N'S', 5, N'VENDA', NULL, '2026-09-05T21:33:15.243116'),
    (23, 6, N'S', 20, N'VENDA', NULL, '2026-09-05T21:33:15.243116'),
    (24, 7, N'S', 32, N'VENDA', NULL, '2026-09-05T21:33:15.243116'),
    (25, 9, N'S', 25, N'VENDA', NULL, '2026-09-05T21:33:15.243116'),
    (26, 11, N'S', 55, N'VENDA', NULL, '2026-09-05T21:33:15.243116'),
    (27, 13, N'S', 6, N'VENDA', NULL, '2026-09-05T21:33:15.244129'),
    (28, 6, N'S', 2, N'PERDA', NULL, '2026-09-05T21:33:15.244129'),
    (29, 12, N'S', 5, N'AJUSTE_INVENTARIO', NULL, '2026-09-05T21:33:15.244129'),
    (30, 12, N'S', 10, N'VENDA', NULL, '2026-09-05T21:33:38.023135'),
    (31, 6, N'S', 5, N'VENDA', NULL, '2026-09-05T21:34:06.138367');
SET IDENTITY_INSERT movimentacao OFF;
GO

/* ==========================================================================
   6. CONSULTAS DE NEGÓCIO
   Uma frase por consulta dizendo que pergunta ela responde — como pede a
   documentação. Todas nascem da view vw_estoque_atual.
   ========================================================================== */

PRINT '--- Consulta base: estoque atual de todos os produtos ativos ---';
SELECT produto, categoria, marca, estoque_atual, estoque_minimo, preco_venda
FROM   vw_estoque_atual
WHERE  ativo = 1
ORDER  BY produto;

/* CONSULTA 1 — "O que precisa ser reposto?"  (linha vermelha na tela) */
PRINT '--- Consulta 1: produtos abaixo do estoque mínimo ---';
SELECT produto, estoque_atual, estoque_minimo,
       (estoque_minimo - estoque_atual) AS faltam
FROM   vw_estoque_atual
WHERE  ativo = 1
  AND  estoque_atual < estoque_minimo
ORDER  BY faltam DESC;

/* CONSULTA 2 — "Quanto de dinheiro está parado na prateleira?" (rodapé da tela)
   Imobilizado = saldo x preço de CUSTO (é o que se pagou, não o que se venderá). */
PRINT '--- Consulta 2: valor total imobilizado em estoque ---';
SELECT SUM(estoque_atual * preco_custo) AS valor_imobilizado
FROM   vw_estoque_atual
WHERE  ativo = 1;

/* CONSULTA 3 — "Quais itens giram?"  Note o TOP (T-SQL), não LIMIT. */
PRINT '--- Consulta 3: os 5 produtos que mais saíram ---';
SELECT TOP (5)
       p.nome,
       SUM(mv.quantidade) AS total_saidas
FROM   movimentacao mv
JOIN   produto p ON p.id = mv.produto_id
WHERE  mv.tipo = 'S'
GROUP  BY p.nome
ORDER  BY total_saidas DESC;

/* CONSULTA 4 — "Quanto saiu por venda e quanto por perda, no mês corrente?"
   É esta consulta que justifica MOTIVO ser lista fixa: texto livre não agrupa. */
PRINT '--- Consulta 4: saídas por motivo no mês corrente ---';
SELECT motivo,
       COUNT(*)          AS qtd_lancamentos,
       SUM(quantidade)   AS total_itens
FROM   movimentacao
WHERE  tipo = 'S'
  AND  YEAR(data)  = YEAR(SYSDATETIME())
  AND  MONTH(data) = MONTH(SYSDATETIME())
GROUP  BY motivo
ORDER  BY total_itens DESC;
GO

/* ==========================================================================
   7. VER O BANCO INTEIRO
   --------------------------------------------------------------------------
   Esta seção não altera nada: só CONSULTA. Rode-a sozinha (selecione daqui
   para baixo e tecle F5 no SSMS) sempre que quiser inspecionar o banco.

   Ela responde, em ordem: o que existe, como se liga, o que garante as
   regras, o que está documentado e o que tem dentro.
   ========================================================================== */

PRINT '';
PRINT '==== 7.1  OBJETOS DO BANCO ====';
SELECT  o.type_desc                              AS tipo,
        o.name                                   AS objeto,
        o.create_date                            AS criado_em
FROM    sys.objects o
WHERE   o.type IN ('U','V','P')      -- U = tabela, V = view, P = procedure
ORDER BY o.type_desc, o.name;

PRINT '';
PRINT '==== 7.2  COLUNAS DE CADA TABELA ====';
SELECT  t.name                                   AS tabela,
        c.column_id                              AS ordem,
        c.name                                   AS coluna,
        ty.name                                  AS tipo,
        CASE WHEN ty.name IN ('varchar','char')      THEN CAST(c.max_length AS VARCHAR(10))
             WHEN ty.name IN ('nvarchar','nchar')    THEN CAST(c.max_length/2 AS VARCHAR(10))
             WHEN ty.name = 'decimal' THEN CAST(c.precision AS VARCHAR(10)) + ',' + CAST(c.scale AS VARCHAR(10))
             ELSE '' END                         AS tamanho,
        CASE c.is_nullable WHEN 1 THEN 'NULL' ELSE 'NOT NULL' END AS aceita_nulo,
        CASE c.is_identity  WHEN 1 THEN 'IDENTITY' ELSE '' END    AS identity_,
        CAST(ep.value AS NVARCHAR(400))          AS descricao_no_catalogo
FROM    sys.tables t
JOIN    sys.columns c  ON c.object_id = t.object_id
JOIN    sys.types ty   ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.extended_properties ep
       ON ep.major_id = c.object_id AND ep.minor_id = c.column_id
      AND ep.name = 'MS_Description'
ORDER BY t.name, c.column_id;

PRINT '';
PRINT '==== 7.3  CHAVES PRIMARIAS, UNIQUE E INDICES ====';
SELECT  t.name AS tabela, i.name AS indice,
        CASE WHEN i.is_primary_key = 1 THEN 'PRIMARY KEY'
             WHEN i.is_unique      = 1 THEN 'UNIQUE'
             ELSE 'indice de apoio' END          AS papel,
        i.type_desc                              AS tipo
FROM    sys.indexes i
JOIN    sys.tables  t ON t.object_id = i.object_id
WHERE   i.name IS NOT NULL
ORDER BY t.name, i.name;

PRINT '';
PRINT '==== 7.4  CHAVES ESTRANGEIRAS (as relacoes) ====';
SELECT  fk.name                                  AS constraint_,
        tp.name + '.' + cp.name                  AS de_,
        tr.name + '.' + cr.name                  AS para_,
        fk.delete_referential_action_desc        AS on_delete
FROM    sys.foreign_keys fk
JOIN    sys.foreign_key_columns k ON k.constraint_object_id = fk.object_id
JOIN    sys.tables  tp ON tp.object_id = fk.parent_object_id
JOIN    sys.columns cp ON cp.object_id = tp.object_id AND cp.column_id = k.parent_column_id
JOIN    sys.tables  tr ON tr.object_id = fk.referenced_object_id
JOIN    sys.columns cr ON cr.object_id = tr.object_id AND cr.column_id = k.referenced_column_id
ORDER BY tp.name, fk.name;

PRINT '';
PRINT '==== 7.5  RESTRICOES CHECK (a regra de negocio no banco) ====';
SELECT  OBJECT_NAME(cc.parent_object_id)         AS tabela,
        cc.name                                  AS constraint_,
        cc.definition                            AS regra,
        CASE WHEN cc.is_disabled = 0 AND cc.is_not_trusted = 0
             THEN 'ativa e confiavel' ELSE 'VERIFICAR' END AS estado
FROM    sys.check_constraints cc
ORDER BY tabela, cc.name;

PRINT '';
PRINT '==== 7.6  CONTEUDO DAS TABELAS ====';
SELECT * FROM categoria    ORDER BY id;
SELECT * FROM marca        ORDER BY id;
SELECT * FROM fornecedor   ORDER BY id;
SELECT * FROM produto      ORDER BY id;
SELECT * FROM movimentacao ORDER BY id;

PRINT '';
PRINT '==== 7.7  A VIEW: o estoque calculado ====';
SELECT * FROM vw_estoque_atual ORDER BY produto;

PRINT '';
PRINT '==== 7.8  RESUMO ====';
SELECT 'categoria' AS tabela, COUNT(*) AS registros FROM categoria
UNION ALL SELECT 'marca',        COUNT(*) FROM marca
UNION ALL SELECT 'fornecedor',   COUNT(*) FROM fornecedor
UNION ALL SELECT 'produto',      COUNT(*) FROM produto
UNION ALL SELECT 'movimentacao', COUNT(*) FROM movimentacao;

SELECT  COUNT(*)                                   AS produtos_ativos,
        SUM(CASE WHEN estoque_atual < estoque_minimo THEN 1 ELSE 0 END) AS abaixo_do_minimo,
        SUM(estoque_atual * preco_custo)           AS valor_imobilizado
FROM    vw_estoque_atual
WHERE   ativo = 1;
GO
