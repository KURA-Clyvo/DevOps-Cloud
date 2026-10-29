// S4-LOJA-02 - role e usuario do Java no MongoDB. Executado pelo servico one-shot
// `mongo-init` (docker-compose.yml) a CADA `up`, autenticado como root (authSource=admin).
// Idempotente: createRole/updateRole e createUser/updateUser. Schema e indices NAO moram
// aqui - sao do runner do backend-tutor-java (LOJA-03).
// Desenho: .superpowers/sdd/SPRINT_4_PLANNING/loja/S4-JAVA-DESIGN.md secao 8 (repo de planejamento).
const kura = db.getSiblingDB("kura_docs");

const senha = process.env.KURA_MONGO_JAVA_PASSWORD;
if (!senha) {
  throw new Error("KURA_MONGO_JAVA_PASSWORD ausente: abortando antes de criar o usuario");
}

// Acoes por colecao do Java. catalogo_loja SEM "remove": o seed e upsert e produto sai por
// ativo:false. Demais colecoes mantem "remove" (reavaliar no v2 da Loja).
const ACOES_BASE = ["find", "insert", "update", "createCollection", "collMod", "createIndex"];
// dropIndex (S4-JAVA-04, E61): o runner do Java agora dropa e recria, PELO NOME, indice com
// definicao divergente. Sem a acao o drop vira ERROR no boot. So nas colecoes cujo runner
// cuida de indices (catalogo_loja, documentos_tutor); carrinho/pedidos_loja e laudos (dono:
// .NET) NAO ganham.
const COLECOES_DO_JAVA = {
  catalogo_loja: ACOES_BASE.concat(["dropIndex"]),
  carrinho: ACOES_BASE.concat(["remove"]),
  pedidos_loja: ACOES_BASE.concat(["remove"]),
  documentos_tutor: ACOES_BASE.concat(["remove", "dropIndex"])
};

const privilegios = [];
for (const [c, actions] of Object.entries(COLECOES_DO_JAVA)) {
  privilegios.push({ resource: { db: "kura_docs", collection: c }, actions: actions });
}
// laudos: dono e o .NET. O Java so LE.
privilegios.push({ resource: { db: "kura_docs", collection: "laudos" }, actions: ["find"] });
// listCollections e acao de database (o runner pergunta "a colecao existe?").
privilegios.push({ resource: { db: "kura_docs", collection: "" }, actions: ["listCollections"] });

if (kura.getRole("kura_java_runtime") === null) {
  kura.createRole({ role: "kura_java_runtime", privileges: privilegios, roles: [] });
  print("mongo-init: role kura_java_runtime criada");
} else {
  kura.updateRole("kura_java_runtime", { privileges: privilegios, roles: [] });
  print("mongo-init: role kura_java_runtime atualizada");
}

// Usuario existente tem a senha reaplicada a cada execucao (rotacao = trocar a variavel e
// dar `up`); usuario novo e criado.
if (kura.getUser("kura_java") === null) {
  kura.createUser({
    user: "kura_java",
    pwd: senha,
    roles: [{ role: "kura_java_runtime", db: "kura_docs" }]
  });
  print("mongo-init: usuario kura_java criado");
} else {
  kura.updateUser("kura_java", { pwd: senha, roles: [{ role: "kura_java_runtime", db: "kura_docs" }] });
  print("mongo-init: usuario kura_java atualizado");
}
// ---------------------------------------------------------------------------------------
// S4-NET-05 - role e usuario da .NET (kura_dotnet). A .NET e DONA de `laudos`: grava e le,
// mas NUNCA remove (exclusao e logica, stAtivo/removidoEm). `documentos_tutor` e do Java:
// a .NET so LE. listIndexes e acao de colecao (find nao basta). NAO altera o Java acima.
// Contrato: .superpowers/sdd/KURA_BACKLOG_S4_DOTNET/s4-net-01-g0.md secao 5.
// ---------------------------------------------------------------------------------------
const senhaDotnet = process.env.KURA_MONGO_DOTNET_PASSWORD;
if (!senhaDotnet) {
  throw new Error("KURA_MONGO_DOTNET_PASSWORD ausente: abortando antes de criar o usuario");
}

const privilegiosDotnet = [
  { resource: { db: "kura_docs", collection: "laudos" },
    actions: ["find", "insert", "update", "createCollection", "collMod", "createIndex", "listIndexes"] },
  { resource: { db: "kura_docs", collection: "documentos_tutor" }, actions: ["find"] },
  { resource: { db: "kura_docs", collection: "" }, actions: ["listCollections"] }
];

if (kura.getRole("kura_dotnet_runtime") === null) {
  kura.createRole({ role: "kura_dotnet_runtime", privileges: privilegiosDotnet, roles: [] });
  print("mongo-init: role kura_dotnet_runtime criada");
} else {
  kura.updateRole("kura_dotnet_runtime", { privileges: privilegiosDotnet, roles: [] });
  print("mongo-init: role kura_dotnet_runtime atualizada");
}

if (kura.getUser("kura_dotnet") === null) {
  kura.createUser({
    user: "kura_dotnet",
    pwd: senhaDotnet,
    roles: [{ role: "kura_dotnet_runtime", db: "kura_docs" }]
  });
  print("mongo-init: usuario kura_dotnet criado");
} else {
  kura.updateUser("kura_dotnet", { pwd: senhaDotnet, roles: [{ role: "kura_dotnet_runtime", db: "kura_docs" }] });
  print("mongo-init: usuario kura_dotnet atualizado");
}
print("mongo-init: ok");
