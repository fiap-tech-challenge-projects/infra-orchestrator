# FIAP Tech Challenge - Infrastructure Orchestrator

Orquestrador central para deploy de toda a infraestrutura do projeto FIAP Tech Challenge Phase 3.

## Visao Geral

Este repositorio contem workflows que orquestram o deploy de todos os componentes na ordem correta:

```
1. kubernetes-core-infra  →  VPC, EKS Cluster, SigNoz
2. database-managed-infra →  RDS PostgreSQL, Secrets Manager
3. lambda-api-handler     →  Lambda Auth, API Gateway
4. k8s-main-service       →  Aplicacao principal no EKS
```

## Pre-requisitos

### 1. Secrets no GitHub

Configure os seguintes secrets em **todos os repositorios** (incluindo este):

| Secret | Descricao |
|--------|-----------|
| `AWS_ACCESS_KEY_ID` | Access Key da AWS |
| `AWS_SECRET_ACCESS_KEY` | Secret Key da AWS |
| `GH_PAT` | Personal Access Token do GitHub com permissao `repo` e `workflow` |

### 2. Personal Access Token (GH_PAT)

O token precisa das seguintes permissoes:
- `repo` (Full control of private repositories)
- `workflow` (Update GitHub Action workflows)

Para criar:
1. GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token (classic)
3. Selecione `repo` e `workflow`
4. Copie o token e adicione como secret `GH_PAT` em todos os repos

## Workflows Disponiveis

### 1. Bootstrap (`bootstrap.yml`)

Cria os recursos base necessarios para o Terraform:
- S3 Bucket para Terraform state
- DynamoDB Table para locking

**Uso:**
1. Va em Actions → Bootstrap AWS Infrastructure
2. Selecione `create`
3. Run workflow

### 2. Deploy All (`deploy-all.yml`)

Deploya toda a infraestrutura na ordem correta:

```
validate → deploy-eks → deploy-database → deploy-lambda → deploy-app
```

**Uso:**
1. Va em Actions → Deploy All Infrastructure
2. Selecione o environment (staging/production)
3. Opcionalmente, pule componentes ja existentes
4. Run workflow

**Opcoes:**
- `skip_eks`: Pula deploy do EKS (se ja existe)
- `skip_database`: Pula deploy do RDS (se ja existe)
- `skip_lambda`: Pula deploy das Lambdas
- `skip_app`: Pula deploy da aplicacao K8s

### 3. Destroy All (`destroy-all.yml`)

Destroi toda a infraestrutura (ordem reversa):

```
destroy-app → destroy-lambda → destroy-database → destroy-eks
```

**Uso:**
1. Va em Actions → Destroy All Infrastructure
2. Selecione o environment
3. Digite `DESTROY` para confirmar
4. Run workflow

## Fluxo de Deploy Completo

```bash
# Primeira vez (ambiente novo)
1. Rodar Bootstrap (create)
2. Rodar Deploy All (staging)

# Atualizacoes subsequentes
# Push nas branches dos repos individuais dispara deploys automaticos

# Destruir ambiente
1. Rodar Destroy All (staging)
2. Rodar Bootstrap (destroy) - opcional, remove bucket S3
```

## Ambientes

| Branch | Environment | Trigger |
|--------|-------------|---------|
| `develop` | staging | Push automatico |
| `main` | production | Push automatico |

## Estrutura dos Repositorios

```
fiap/
├── infra-orchestrator/      ← Este repo (orquestrador)
├── kubernetes-core-infra/   ← VPC, EKS, SigNoz
├── database-managed-infra/  ← RDS PostgreSQL
├── lambda-api-handler/      ← Lambda Auth Functions
├── k8s-main-service/        ← Aplicacao NestJS
└── fiap-tech-challenge/     ← Codigo legado (fases 1-2)
```

## Troubleshooting

### Erro: "Resource not found"

Os workflows dependem uns dos outros. Se um falhar, verifique:
1. O workflow anterior completou com sucesso?
2. Os recursos foram criados corretamente?

### Erro: "Bad credentials" ou "Resource not accessible"

O `GH_PAT` pode estar:
- Expirado
- Sem permissoes suficientes
- Nao configurado em todos os repos

### Timeout

Alguns recursos demoram para criar:
- EKS Cluster: ~15-20 minutos
- RDS: ~10-15 minutos

Os workflows tem timeouts adequados, mas podem precisar de ajuste.

## Custos AWS

Estimativa mensal (ambiente staging):

| Recurso | Custo Estimado |
|---------|---------------|
| EKS Cluster | ~$73/mes |
| EC2 (2x t3.medium) | ~$60/mes |
| RDS (db.t3.micro) | ~$15/mes |
| NAT Gateway | ~$32/mes |
| Lambda | ~$0 (free tier) |
| **Total** | **~$180/mes** |

Para reduzir custos:
- Use `Destroy All` quando nao estiver usando
- AWS Academy: creditos disponiveis
