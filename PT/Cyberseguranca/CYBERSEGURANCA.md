# Cybersegurança para Dev Full Cycle e Full Stack

> Guia prático do básico ao essencial: não só o que fazer, mas **como fazer**, com exemplos reais de código e comandos.

---

## Índice

1. [Mentalidade de segurança](#1-mentalidade-de-segurança)
2. [Modelo de ameaça](#2-modelo-de-ameaça)
3. [Validação de entrada](#3-validação-de-entrada)
4. [Prevenção de Injection](#4-prevenção-de-injection)
5. [Autenticação e sessões](#5-autenticação-e-sessões)
6. [Autorização e controle de acesso](#6-autorização-e-controle-de-acesso)
7. [Hash de senhas](#7-hash-de-senhas)
8. [Segredos e variáveis de ambiente](#8-segredos-e-variáveis-de-ambiente)
9. [Headers de segurança HTTP](#9-headers-de-segurança-http)
10. [CORS](#10-cors)
11. [Rate limiting e proteção contra abuso](#11-rate-limiting-e-proteção-contra-abuso)
12. [Segurança de APIs e Webhooks](#12-segurança-de-apis-e-webhooks)
13. [Banco de dados](#13-banco-de-dados)
14. [Segurança no frontend](#14-segurança-no-frontend)
15. [Docker e infraestrutura](#15-docker-e-infraestrutura)
16. [CI/CD e supply chain](#16-cicd-e-supply-chain)
17. [Logs e monitoramento](#17-logs-e-monitoramento)
18. [Checklist de produção](#18-checklist-de-produção)

---

## 1. Mentalidade de segurança

Segurança é requisito funcional, não etapa final. A cada feature, pergunte:

| Pergunta | O que fazer |
|---|---|
| O que pode dar errado? | Mapear abuso, fraude, vazamento |
| Qual o impacto? | Dados, financeiro, reputação, legal |
| Qual controle mitiga? | Validação, permissão, criptografia, limite |

**Princípios que guiam as decisões:**

- **Menor privilégio** — usuário, serviço e chave só com o acesso necessário.
- **Negar por padrão** — se não foi explicitamente permitido, está bloqueado.
- **Defesa em camadas** — nunca dependa de um único controle.
- **Falha segura** — erro bloqueia operação crítica, nunca libera acesso.
- **Não confiar na entrada** — toda entrada é potencialmente maliciosa.

---

## 2. Modelo de ameaça

Antes de codar uma feature relevante, preencha rapidamente:

```
Ativo: dados do usuário / token de pagamento / painel admin
Quem pode atacar: usuário malicioso, bot, insider, atacante externo
Superfície: POST /orders, upload de avatar, rota /admin
Controles: autenticação obrigatória, validação de schema, rate limit, log de auditoria
```

Tabela por endpoint:

| Pergunta | Exemplo |
|---|---|
| Quem pode chamar? | Usuário autenticado com role `admin` |
| O que pode enviar? | Somente campos válidos, tamanho máximo definido |
| O que não pode vazar? | Stack trace, token, SQL, CPF, cartão |
| Como evitar abuso? | Rate limit + timeout + log de auditoria |

---

## 3. Validação de entrada

Toda entrada deve ser validada em **tipo, formato, tamanho e whitelist** antes de qualquer processamento.

### Com Zod (Node.js / TypeScript)

```ts
import { z } from 'zod'

const CreateUserSchema = z.object({
  name: z.string().min(2).max(100).trim(),
  email: z.string().email().toLowerCase(),
  password: z.string().min(8).max(128),
  role: z.enum(['user', 'editor']),  // whitelist explícita
})

// No controller:
app.post('/users', (req, res) => {
  const result = CreateUserSchema.safeParse(req.body)

  if (!result.success) {
    // Retorna erros de validação sem expor internos
    return res.status(400).json({ errors: result.error.flatten() })
  }

  const { name, email, password, role } = result.data
  // prossegue com dados validados e tipados
})
```

### Com express-validator

```ts
import { body, validationResult } from 'express-validator'

const validateLogin = [
  body('email').isEmail().normalizeEmail(),
  body('password').isLength({ min: 8, max: 128 }),
  (req, res, next) => {
    const errors = validationResult(req)
    if (!errors.isEmpty()) {
      return res.status(400).json({ errors: errors.array() })
    }
    next()
  },
]

app.post('/login', validateLogin, loginController)
```

### Rejeitar campos inesperados

```ts
// Com Zod: .strip() remove campos extras por padrão
// Com Prisma/ORM: selecione campos explicitamente ao salvar

// Errado — aceita qualquer campo do body:
await User.create({ ...req.body })

// Correto — pega somente os campos validados:
const { name, email } = result.data
await User.create({ name, email })
```

---

## 4. Prevenção de Injection

### SQL Injection

**Vulnerável:**
```ts
// NUNCA faça isso — abre brecha para SQL Injection
const user = await db.query(
  `SELECT * FROM users WHERE email = '${req.body.email}'`
)
// Entrada maliciosa: ' OR '1'='1  →  vaza todos os usuários
```

**Correto com query parametrizada:**
```ts
// PostgreSQL com pg
const { rows } = await db.query(
  'SELECT * FROM users WHERE email = $1',
  [req.body.email]
)

// MySQL com mysql2
const [rows] = await db.execute(
  'SELECT * FROM users WHERE email = ?',
  [req.body.email]
)
```

**Correto com ORM (Prisma):**
```ts
// Prisma escapa automaticamente
const user = await prisma.user.findUnique({
  where: { email: req.body.email },
})
```

### Command Injection

**Vulnerável:**
```ts
import { exec } from 'child_process'
exec(`convert ${req.body.filename} output.png`) // perigoso
// Entrada: "foto.jpg; rm -rf /"
```

**Correto:**
```ts
import { execFile } from 'child_process'

// execFile não passa por shell — argumentos são tratados literalmente
execFile('convert', [req.body.filename, 'output.png'], (err, stdout) => {
  // ...
})

// Ou com validação estrita do filename antes:
const filenameSchema = z.string().regex(/^[a-zA-Z0-9._-]+$/).max(255)
const filename = filenameSchema.parse(req.body.filename)
```

### NoSQL Injection (MongoDB)

**Vulnerável:**
```ts
// req.body.email pode ser { $gt: "" } → retorna todos os usuários
await User.findOne({ email: req.body.email })
```

**Correto:**
```ts
// Valide e force o tipo string antes de consultar
const email = z.string().email().parse(req.body.email)
await User.findOne({ email })
```

---

## 5. Autenticação e sessões

### JWT com refresh token

```ts
import jwt from 'jsonwebtoken'

const ACCESS_SECRET = process.env.JWT_ACCESS_SECRET!
const REFRESH_SECRET = process.env.JWT_REFRESH_SECRET!

// Gerar tokens
function generateTokens(userId: string) {
  const accessToken = jwt.sign(
    { sub: userId },
    ACCESS_SECRET,
    { expiresIn: '15m' }  // curto — minimiza janela de abuso
  )

  const refreshToken = jwt.sign(
    { sub: userId },
    REFRESH_SECRET,
    { expiresIn: '7d' }
  )

  return { accessToken, refreshToken }
}

// Verificar access token (middleware)
function requireAuth(req, res, next) {
  const header = req.headers.authorization
  if (!header?.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' })
  }

  try {
    const token = header.slice(7)
    const payload = jwt.verify(token, ACCESS_SECRET) as { sub: string }
    req.userId = payload.sub
    next()
  } catch {
    // Mensagem genérica — não revela se o token expirou ou é inválido
    return res.status(401).json({ error: 'Unauthorized' })
  }
}
```

### Armazenar refresh token com segurança

```ts
// Salve o refresh token no banco para poder revogá-lo
await prisma.refreshToken.create({
  data: {
    token: hashedRefreshToken,   // guarde o hash, nunca o token puro
    userId,
    expiresAt: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000),
  },
})

// No logout: delete o refresh token do banco
await prisma.refreshToken.deleteMany({ where: { userId } })
```

### Cookie seguro para refresh token

```ts
// Enviar refresh token via cookie httpOnly — não acessível via JS
res.cookie('refreshToken', refreshToken, {
  httpOnly: true,     // inacessível via document.cookie
  secure: true,       // só em HTTPS
  sameSite: 'strict', // proteção contra CSRF
  maxAge: 7 * 24 * 60 * 60 * 1000,
})
```

### Proteção contra brute force no login

```ts
import rateLimit from 'express-rate-limit'

const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 minutos
  max: 10,                   // máximo 10 tentativas por IP
  message: { error: 'Muitas tentativas. Tente novamente em 15 minutos.' },
  skipSuccessfulRequests: true,
})

app.post('/auth/login', loginLimiter, loginController)
```

---

## 6. Autorização e controle de acesso

### Middleware de RBAC

```ts
type Role = 'user' | 'editor' | 'admin'

function requireRole(...roles: Role[]) {
  return (req, res, next) => {
    // requireAuth deve rodar antes e popular req.user
    if (!req.user) {
      return res.status(401).json({ error: 'Unauthorized' })
    }

    if (!roles.includes(req.user.role)) {
      return res.status(403).json({ error: 'Forbidden' })
    }

    next()
  }
}

// Uso:
app.delete('/admin/users/:id', requireAuth, requireRole('admin'), deleteUser)
app.put('/posts/:id', requireAuth, requireRole('editor', 'admin'), updatePost)
```

### Verificar ownership (evitar IDOR)

```ts
// IDOR — Insecure Direct Object Reference
// Errado: permite que um usuário acesse recurso de outro
app.get('/orders/:id', requireAuth, async (req, res) => {
  const order = await prisma.order.findUnique({ where: { id: req.params.id } })
  res.json(order) // qualquer usuário logado vê qualquer pedido
})

// Correto: filtra pelo userId do token
app.get('/orders/:id', requireAuth, async (req, res) => {
  const order = await prisma.order.findFirst({
    where: {
      id: req.params.id,
      userId: req.userId,  // só retorna se for dono
    },
  })

  if (!order) return res.status(404).json({ error: 'Not found' })
  res.json(order)
})
```

---

## 7. Hash de senhas

Nunca guarde senha em texto plano ou com MD5/SHA. Use **bcrypt** ou **Argon2id**.

### Com bcrypt

```ts
import bcrypt from 'bcrypt'

const SALT_ROUNDS = 12  // custo computacional — ajuste conforme hardware

// Ao criar usuário:
async function hashPassword(plaintext: string) {
  return bcrypt.hash(plaintext, SALT_ROUNDS)
}

// Ao fazer login:
async function verifyPassword(plaintext: string, hash: string) {
  return bcrypt.compare(plaintext, hash)
}

// Exemplo completo:
app.post('/auth/register', async (req, res) => {
  const { email, password } = CreateUserSchema.parse(req.body)

  const existing = await prisma.user.findUnique({ where: { email } })
  if (existing) {
    // Resposta genérica para não revelar se o email existe
    return res.status(400).json({ error: 'Dados inválidos.' })
  }

  const passwordHash = await hashPassword(password)
  const user = await prisma.user.create({
    data: { email, passwordHash },
    select: { id: true, email: true },  // nunca retorna o hash
  })

  res.status(201).json(user)
})
```

### Com Argon2 (mais recomendado)

```ts
import argon2 from 'argon2'

const passwordHash = await argon2.hash(password, {
  type: argon2.argon2id,
  memoryCost: 65536,  // 64 MB
  timeCost: 3,
  parallelism: 4,
})

const valid = await argon2.verify(passwordHash, password)
```

---

## 8. Segredos e variáveis de ambiente

### Regras básicas

```bash
# 1. Nunca versione segredos. Adicione ao .gitignore:
echo ".env\n.env.local\n.env.production" >> .gitignore

# 2. Verifique se já tem segredos no histórico Git:
git log --all --full-history -- .env
git grep -i "secret\|password\|token" $(git rev-list --all)

# 3. Se um segredo vazou no Git, considere-o comprometido e rode:
git filter-repo --path .env --invert-paths  # remove do histórico
# E troque todas as credenciais imediatamente
```

### Estrutura recomendada

```bash
# .env.example (versionar — valores fictícios)
DATABASE_URL=postgresql://user:password@localhost:5432/mydb
JWT_ACCESS_SECRET=seu-segredo-aqui
JWT_REFRESH_SECRET=outro-segredo-aqui

# .env (NÃO versionar — valores reais locais)
DATABASE_URL=postgresql://postgres:minhaSenha@localhost:5432/mydb
JWT_ACCESS_SECRET=a8f3...
```

### Validar variáveis na inicialização

```ts
import { z } from 'zod'

const EnvSchema = z.object({
  DATABASE_URL: z.string().url(),
  JWT_ACCESS_SECRET: z.string().min(32),
  JWT_REFRESH_SECRET: z.string().min(32),
  NODE_ENV: z.enum(['development', 'test', 'production']),
  PORT: z.coerce.number().default(3000),
})

// Valida ao iniciar — falha rápido se algo estiver faltando
const env = EnvSchema.parse(process.env)
export { env }
```

### Em produção — usar secret manager

```bash
# AWS Secrets Manager
aws secretsmanager create-secret --name prod/myapp/db \
  --secret-string '{"password":"minhaSenha"}'

aws secretsmanager get-secret-value --secret-id prod/myapp/db

# GitHub Actions — segredos ficam em Settings > Secrets
# No workflow, acesse via:
# ${{ secrets.DATABASE_URL }}
```

---

## 9. Headers de segurança HTTP

### Com Helmet.js (Express)

```ts
import helmet from 'helmet'

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", 'data:', 'https:'],
      connectSrc: ["'self'"],
      fontSrc: ["'self'"],
      objectSrc: ["'none'"],
      upgradeInsecureRequests: [],
    },
  },
  hsts: {
    maxAge: 31536000,      // 1 ano
    includeSubDomains: true,
    preload: true,
  },
}))
```

### Configurar no Nginx (reverse proxy)

```nginx
# /etc/nginx/conf.d/security-headers.conf

add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "DENY" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains; preload" always;
add_header Content-Security-Policy "default-src 'self'; script-src 'self'; object-src 'none'" always;

# Remover header que expõe tecnologia
server_tokens off;
```

### Verificar headers em produção

```bash
# Checar headers de resposta
curl -I https://meudominio.com

# Ou usar o site:
# https://securityheaders.com
# https://observatory.mozilla.org
```

---

## 10. CORS

### Configuração segura (Express)

```ts
import cors from 'cors'

const allowedOrigins = [
  'https://meuapp.com',
  'https://www.meuapp.com',
  ...(process.env.NODE_ENV === 'development' ? ['http://localhost:3000'] : []),
]

app.use(cors({
  origin: (origin, callback) => {
    // Permite requisições sem origin (ex: Postman em dev)
    if (!origin || allowedOrigins.includes(origin)) {
      callback(null, true)
    } else {
      callback(new Error(`Origin ${origin} not allowed`))
    }
  },
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true,  // necessário para enviar cookies
  maxAge: 86400,       // cache do preflight por 24h
}))
```

**Nunca use `origin: '*'` com `credentials: true`** — browsers bloqueiam e é inseguro.

---

## 11. Rate limiting e proteção contra abuso

### Por rota com express-rate-limit

```ts
import rateLimit from 'express-rate-limit'
import RedisStore from 'rate-limit-redis'
import { createClient } from 'redis'

const redis = createClient({ url: process.env.REDIS_URL })

// Rate limit geral
const globalLimiter = rateLimit({
  windowMs: 60 * 1000,  // 1 minuto
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  store: new RedisStore({ sendCommand: (...args) => redis.sendCommand(args) }),
})

// Rate limit agressivo para autenticação
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,  // 15 minutos
  max: 10,
  message: { error: 'Muitas tentativas. Aguarde 15 minutos.' },
  skipSuccessfulRequests: true,
})

// Rate limit para criação de recursos
const createLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 20,
  keyGenerator: (req) => req.userId ?? req.ip,  // por usuário autenticado
})

app.use(globalLimiter)
app.post('/auth/login', authLimiter, loginController)
app.post('/auth/forgot-password', authLimiter, forgotPasswordController)
app.post('/api/posts', requireAuth, createLimiter, createPostController)
```

### Timeout em chamadas externas

```ts
// Sempre defina timeout em fetch/axios para evitar hanging requests
const controller = new AbortController()
const timeout = setTimeout(() => controller.abort(), 5000)  // 5s

try {
  const response = await fetch('https://api.externa.com/dados', {
    signal: controller.signal,
  })
  const data = await response.json()
  return data
} catch (err) {
  if (err.name === 'AbortError') {
    throw new Error('Timeout ao chamar API externa')
  }
  throw err
} finally {
  clearTimeout(timeout)
}

// Com axios:
const response = await axios.get('https://api.externa.com/dados', {
  timeout: 5000,
})
```

---

## 12. Segurança de APIs e Webhooks

### Validação de webhook com HMAC (ex: Stripe, GitHub)

```ts
import crypto from 'crypto'

function verifyWebhookSignature(
  payload: Buffer,
  signature: string,
  secret: string
): boolean {
  const expected = crypto
    .createHmac('sha256', secret)
    .update(payload)
    .digest('hex')

  // comparação segura — evita timing attack
  return crypto.timingSafeEqual(
    Buffer.from(`sha256=${expected}`),
    Buffer.from(signature)
  )
}

// No controller — obrigatório usar o body raw (Buffer), não o parsed
app.post(
  '/webhooks/stripe',
  express.raw({ type: 'application/json' }),
  (req, res) => {
    const signature = req.headers['stripe-signature'] as string

    if (!verifyWebhookSignature(req.body, signature, process.env.STRIPE_WEBHOOK_SECRET!)) {
      return res.status(401).json({ error: 'Invalid signature' })
    }

    const event = JSON.parse(req.body.toString())
    // processar evento com segurança
    res.sendStatus(200)
  }
)
```

### Idempotência para operações críticas

```ts
// Evita cobranças duplicadas, criações em duplicata, etc.
app.post('/orders', requireAuth, async (req, res) => {
  const idempotencyKey = req.headers['idempotency-key'] as string

  if (!idempotencyKey) {
    return res.status(400).json({ error: 'Idempotency-Key header required' })
  }

  // Verifica se já foi processado
  const cached = await redis.get(`idempotency:${idempotencyKey}`)
  if (cached) {
    return res.status(200).json(JSON.parse(cached))
  }

  const order = await createOrder(req.body, req.userId)

  // Guarda resultado por 24h
  await redis.setEx(
    `idempotency:${idempotencyKey}`,
    86400,
    JSON.stringify(order)
  )

  res.status(201).json(order)
})
```

---

## 13. Banco de dados

### Criar usuário com privilégios mínimos (PostgreSQL)

```sql
-- Crie um usuário para a aplicação (nunca use o superuser)
CREATE USER app_user WITH PASSWORD 'senha-segura-aqui';

-- Dê permissão somente no banco da aplicação
GRANT CONNECT ON DATABASE myapp TO app_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_user;

-- Para migrações, use um usuário separado com mais permissões
CREATE USER app_migrator WITH PASSWORD 'outra-senha';
GRANT ALL PRIVILEGES ON DATABASE myapp TO app_migrator;
```

### Configurar TLS na conexão (Prisma)

```env
# .env
DATABASE_URL="postgresql://app_user:senha@db.servidor.com:5432/myapp?sslmode=require"
```

### Backup automático (PostgreSQL + cron)

```bash
#!/bin/bash
# /scripts/backup-db.sh

DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/postgres"
DB_NAME="myapp"

mkdir -p "$BACKUP_DIR"

# Dump comprimido
pg_dump -U postgres -d "$DB_NAME" | gzip > "$BACKUP_DIR/${DB_NAME}_${DATE}.sql.gz"

# Manter somente os últimos 7 dias
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "Backup concluído: ${DB_NAME}_${DATE}.sql.gz"
```

```bash
# Agendar via crontab (todo dia às 2h)
crontab -e
# Adicionar:
0 2 * * * /scripts/backup-db.sh >> /var/log/backup-db.log 2>&1
```

### Restaurar e testar backup

```bash
# Testar restauração (em ambiente de homologação)
gunzip -c /backups/postgres/myapp_20240101_020000.sql.gz | \
  psql -U postgres -d myapp_test
```

---

## 14. Segurança no frontend

### Content Security Policy na prática

```html
<!-- Via meta tag (menos eficaz que header HTTP) -->
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'">
```

```ts
// Nonce para scripts inline (React/Next.js)
// next.config.js
const nonce = Buffer.from(crypto.randomUUID()).toString('base64')

const cspHeader = `
  default-src 'self';
  script-src 'self' 'nonce-${nonce}';
  style-src 'self' 'nonce-${nonce}';
  img-src 'self' blob: data:;
  connect-src 'self';
  font-src 'self';
  object-src 'none';
  base-uri 'self';
  form-action 'self';
  frame-ancestors 'none';
`
```

### Evitar XSS no React

```tsx
// React escapa automaticamente expressões JSX — mas atenção:

// Seguro — React escapa o conteúdo:
<p>{userContent}</p>

// PERIGOSO — injeção de HTML sem sanitização:
<div dangerouslySetInnerHTML={{ __html: userContent }} />

// Correto quando precisar renderizar HTML:
import DOMPurify from 'dompurify'
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(userContent) }} />
```

### Não armazenar tokens em localStorage

```ts
// Ruim — acessível por qualquer JS da página (XSS rouba tudo)
localStorage.setItem('accessToken', token)

// Melhor — token de curta duração em memória; refresh via cookie httpOnly
let accessToken: string | null = null  // variável de módulo em memória

function setAccessToken(token: string) { accessToken = token }
function getAccessToken() { return accessToken }

// Renovar token silenciosamente via refresh token em cookie httpOnly
async function refreshAccessToken() {
  const res = await fetch('/auth/refresh', { credentials: 'include' })
  const { accessToken } = await res.json()
  setAccessToken(accessToken)
  return accessToken
}
```

---

## 15. Docker e infraestrutura

### Dockerfile seguro

```dockerfile
# ---- build stage ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

COPY . .
RUN npm run build

# ---- runtime stage ----
FROM node:20-alpine AS runner

# Cria usuário não-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

# Copia somente o necessário
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY package.json .

# Troca para usuário sem privilégios
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "dist/server.js"]
```

### Docker Compose com hardening

```yaml
services:
  api:
    image: ghcr.io/org/api:sha-abc123  # tag imutável, nunca :latest
    restart: unless-stopped
    user: "10001:10001"               # usuário não-root
    read_only: true                   # filesystem somente leitura
    tmpfs:
      - /tmp                          # permite escrita somente em /tmp
    security_opt:
      - no-new-privileges:true        # impede escalar privilégios
    cap_drop:
      - ALL                           # remove todas as capabilities Linux
    cap_add:
      - NET_BIND_SERVICE              # adiciona somente o necessário
    environment:
      NODE_ENV: production
      # Nunca coloque segredos aqui — use secrets ou env_file fora do repositório
    env_file:
      - .env.production               # não versionar
    ports:
      - "127.0.0.1:3000:3000"        # expõe somente no loopback
    mem_limit: 512m
    cpus: "0.5"
    networks:
      - internal
    depends_on:
      db:
        condition: service_healthy

  db:
    image: postgres:16-alpine
    restart: unless-stopped
    user: "999:999"
    environment:
      POSTGRES_DB: myapp
      POSTGRES_USER: app_user
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - internal
    # Nunca expõe porta 5432 para fora da rede interna
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U app_user -d myapp"]
      interval: 10s
      timeout: 5s
      retries: 5

secrets:
  db_password:
    file: ./secrets/db_password.txt  # não versionar

networks:
  internal:
    driver: bridge

volumes:
  postgres_data:
```

### Scan de vulnerabilidades na imagem

```bash
# Com Trivy (gratuito)
trivy image ghcr.io/org/api:sha-abc123

# Retorna CVEs por severidade — corrija HIGH e CRITICAL antes do deploy

# Instalação:
# brew install aquasecurity/trivy/trivy
# ou via Docker:
docker run --rm aquasec/trivy image ghcr.io/org/api:sha-abc123
```

---

## 16. CI/CD e supply chain

### GitHub Actions com segurança integrada

```yaml
# .github/workflows/ci.yml
name: CI

on:
  push:
    branches: [main]
  pull_request:

permissions:
  contents: read       # princípio de menor privilégio
  security-events: write  # para upload de SARIF

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm

      - run: npm ci
      - run: npm test
      - run: npm run build

  sast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Análise estática com CodeQL
      - uses: github/codeql-action/init@v3
        with:
          languages: javascript-typescript

      - uses: github/codeql-action/analyze@v3

  dependency-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # Auditoria de dependências
      - run: npm audit --audit-level=high

      # Scan de segredos no código
      - uses: trufflesecurity/trufflehog@main
        with:
          path: ./

  container-scan:
    runs-on: ubuntu-latest
    needs: [test]
    steps:
      - uses: actions/checkout@v4

      - name: Build image
        run: docker build -t app:${{ github.sha }} .

      - name: Scan com Trivy
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: app:${{ github.sha }}
          severity: HIGH,CRITICAL
          exit-code: 1  # falha o pipeline se encontrar vulnerabilidade crítica

  deploy:
    runs-on: ubuntu-latest
    needs: [test, sast, dependency-scan, container-scan]
    if: github.ref == 'refs/heads/main'
    environment: production  # requer aprovação manual configurada no GitHub
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        env:
          DEPLOY_KEY: ${{ secrets.DEPLOY_KEY }}  # segredo via GitHub Secrets
        run: ./scripts/deploy.sh
```

### Proteger branch principal

```bash
# Via GitHub CLI — proteger main
gh api repos/:owner/:repo/branches/main/protection \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":["test","sast","container-scan"]}' \
  --field enforce_admins=true \
  --field required_pull_request_reviews='{"required_approving_review_count":1}'
```

---

## 17. Logs e monitoramento

### O que logar (e o que nunca logar)

```ts
// Logar:
// - Login, logout, falha de autenticação
// - Ações administrativas (create, update, delete em recursos sensíveis)
// - Erros de autorização (403)
// - Deploy e mudanças de configuração

// NUNCA logar:
// - Senha, token completo, chave de API
// - CPF, cartão, dados bancários
// - Conteúdo de mensagens privadas
```

### Configuração com Pino (Node.js)

```ts
import pino from 'pino'

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  redact: {
    // Remove campos sensíveis automaticamente dos logs
    paths: [
      'password',
      'passwordHash',
      'token',
      'authorization',
      'cookie',
      'req.headers.authorization',
      'req.headers.cookie',
      'body.password',
      'body.cardNumber',
      'body.cpf',
    ],
    censor: '[REDACTED]',
  },
  serializers: {
    req: pino.stdSerializers.req,
    res: pino.stdSerializers.res,
    err: pino.stdSerializers.err,
  },
})

export { logger }
```

### Middleware de log estruturado (Express + Pino)

```ts
import pinoHttp from 'pino-http'

app.use(pinoHttp({
  logger,
  customLogLevel: (req, res, err) => {
    if (res.statusCode >= 500 || err) return 'error'
    if (res.statusCode >= 400) return 'warn'
    return 'info'
  },
  customSuccessMessage: (req, res) =>
    `${req.method} ${req.url} ${res.statusCode}`,
}))
```

### Log de auditoria para ações sensíveis

```ts
interface AuditEvent {
  action: string
  userId: string
  resource: string
  resourceId: string
  metadata?: Record<string, unknown>
  ip: string
  userAgent: string
}

async function audit(event: AuditEvent) {
  logger.info({ audit: true, ...event }, `AUDIT: ${event.action}`)

  await prisma.auditLog.create({ data: event })
}

// Uso:
await audit({
  action: 'user.delete',
  userId: req.userId,
  resource: 'user',
  resourceId: targetUserId,
  ip: req.ip,
  userAgent: req.headers['user-agent'] || '',
})
```

### Alertas de incidente com Grafana + Loki (básico)

```bash
# Subir stack de monitoramento local
docker run -d \
  --name loki \
  -p 3100:3100 \
  grafana/loki:latest

# Enviar logs do app para Loki via pino-loki
npm install pino-loki

# pino-loki no app:
node server.js | pino-loki --host http://localhost:3100
```

---

## 18. Checklist de produção

Use antes de qualquer go-live:

### Aplicação

- [ ] Validação de entrada em todos os endpoints públicos
- [ ] Nenhuma query com concatenação de string de usuário (SQL/NoSQL)
- [ ] Senhas com Argon2id ou bcrypt (custo ≥ 10)
- [ ] JWT com expiração curta (≤ 15 min) e refresh token revogável
- [ ] Controle de acesso verificado no backend em toda operação sensível
- [ ] IDOR impossível — recursos filtrados por ownership
- [ ] Erro genérico para o cliente, detalhes somente nos logs internos

### Infraestrutura

- [ ] HTTPS ativo com redirect HTTP → HTTPS
- [ ] Headers de segurança no gateway (CSP, nosniff, frame-options, HSTS)
- [ ] CORS restrito às origens da aplicação
- [ ] Rate limit em autenticação e endpoints de criação
- [ ] Container rodando como usuário não-root com `read_only: true`
- [ ] Nenhuma porta de banco exposta publicamente

### Dados

- [ ] Segredos fora do Git e rotacionáveis
- [ ] Variáveis de ambiente validadas na inicialização
- [ ] Backup automático configurado e restauração testada
- [ ] PII mascarado em logs

### CI/CD

- [ ] SAST, scan de dependências e scan de imagem no pipeline
- [ ] Deploy bloqueado em vulnerabilidade HIGH/CRITICAL
- [ ] Segredos somente via secret store da plataforma
- [ ] Branch principal protegida com revisão obrigatória

### Resposta a incidente

- [ ] Logs de auditoria ativos e centralizados
- [ ] Runbook documentado (detectar → conter → preservar → corrigir → comunicar)
- [ ] Tokens/chaves podem ser revogados sem downtime

---

> Combine este guia com [`../Servidor/VPS_SETUP.md`](../Servidor/VPS_SETUP.md), [`../Docker/DOCKER.md`](../Docker/DOCKER.md) e [`../CI-CD/GITHUB_ACTIONS.md`](../CI-CD/GITHUB_ACTIONS.md) para fechar o ciclo da aplicação ao deploy.
