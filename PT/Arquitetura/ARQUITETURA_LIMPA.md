# Arquitetura Limpa (Clean Architecture) na Prática

> Organizando o sistema para proteger regras de negócio e reduzir dependência de frameworks e bibliotecas externas.

---

## Índice

1. [Princípio central](#1-princípio-central)
2. [Camadas e responsabilidades](#2-camadas-e-responsabilidades)
3. [Regra de dependência](#3-regra-de-dependência)
4. [Diagrama da arquitetura](#4-diagrama-da-arquitetura)
5. [Estrutura de pastas](#5-estrutura-de-pastas)
6. [Exemplo completo em Python](#6-exemplo-completo-em-python)
7. [Exemplo completo em TypeScript](#7-exemplo-completo-em-typescript)
8. [Como testar cada camada](#8-como-testar-cada-camada)
9. [Erros comuns](#9-erros-comuns)

---

## 1. Princípio central

As regras de negócio **não dependem** de:

- framework web (Flask, FastAPI, Express, NestJS),
- banco de dados (PostgreSQL, MongoDB, SQLite),
- fila ou mensageria (RabbitMQ, Kafka, SQS),
- UI ou API transport (REST, GraphQL, gRPC).

Esses elementos são detalhes de implementação e podem ser trocados sem tocar no núcleo do sistema.

**Teste simples:** se você consegue rodar os casos de uso com `pytest` ou `jest` sem subir banco ou servidor HTTP, a arquitetura está certa.

---

## 2. Camadas e responsabilidades

| Camada | O que contém | O que não pode ter |
|---|---|---|
| **Domain** | Entidades, Value Objects, regras puras, interfaces de repositório | Import de ORM, framework, lib externa |
| **Application** | Casos de uso, orquestração de domínio, DTOs de entrada/saída | Import de Express/FastAPI, Prisma/SQLAlchemy |
| **Interface Adapters** | Controllers, Presenters, transformação de dados | Regra de negócio, acesso direto ao banco |
| **Infrastructure** | ORM, HTTP clients, filas, cache, email | Regra de negócio |

---

## 3. Regra de dependência

```
As dependências sempre apontam para dentro — do detalhe para o núcleo.

    Infrastructure  →  Application  →  Domain
    Adapters       →  Application  →  Domain
    Domain                          (não depende de ninguém)
```

Quando Infrastructure precisa de algo do Domain, usa uma **interface** (port) definida no Domain.  
A implementação concreta fica em Infrastructure.  
Isso é Inversão de Dependência (o D do SOLID).

---

## 4. Diagrama da arquitetura

```mermaid
flowchart TB
    INFRA["Infrastructure\n(Prisma, SQLAlchemy, Redis, Stripe)"]
    ADAPTERS["Interface Adapters\n(Controllers, Presenters)"]
    APP["Application\n(Use Cases / Services)"]
    DOMAIN["Domain\n(Entities, Value Objects, Rules)"]

    INFRA --> ADAPTERS
    ADAPTERS --> APP
    APP --> DOMAIN

    style DOMAIN fill:#2d6a4f,color:#fff,stroke:#1b4332
    style APP fill:#1d3557,color:#fff,stroke:#0d2137
    style ADAPTERS fill:#457b9d,color:#fff
    style INFRA fill:#6c757d,color:#fff
```

```mermaid
flowchart LR
    subgraph "Detalhe (pode trocar)"
        DB[(Banco)]
        HTTP[HTTP/REST]
        MQ[(Fila)]
    end

    subgraph "Núcleo (estável)"
        UC[Use Cases]
        ENT[Entities]
    end

    DB -->|implementa| UC
    HTTP -->|chama| UC
    MQ -->|chama| UC
    UC --> ENT
```

---

## 5. Estrutura de pastas

### Python

```
src/
├── domain/
│   ├── entities/
│   │   └── pedido.py          # Pedido, ItemPedido
│   ├── value_objects/
│   │   └── dinheiro.py        # Dinheiro (imutável)
│   └── repositories/
│       └── pedido_repository.py   # interface (ABC)
│
├── application/
│   └── use_cases/
│       ├── criar_pedido.py
│       └── cancelar_pedido.py
│
├── adapters/
│   └── http/
│       └── pedido_controller.py   # FastAPI router
│
└── infrastructure/
    └── repositories/
        └── pedido_sqlalchemy_repo.py
```

### TypeScript

```
src/
├── domain/
│   ├── Order.ts
│   ├── OrderItem.ts
│   └── OrderRepository.ts     # interface
│
├── application/
│   ├── CreateOrder.ts
│   └── CancelOrder.ts
│
├── adapters/
│   └── http/
│       └── OrderController.ts
│
├── infrastructure/
│   └── PrismaOrderRepository.ts
│
└── main.ts                    # composition root
```

---

## 6. Exemplo completo em Python

### Domain — Entidade e interface de repositório

```python
# domain/entities/pedido.py
from __future__ import annotations
from dataclasses import dataclass, field
from uuid import uuid4

@dataclass
class ItemPedido:
    produto_id: str
    quantidade: int
    preco_unit: float

    def subtotal(self) -> float:
        return self.quantidade * self.preco_unit


@dataclass
class Pedido:
    id: str
    cliente_id: str
    itens: list[ItemPedido] = field(default_factory=list)
    status: str = "ABERTO"

    @classmethod
    def criar(cls, cliente_id: str) -> Pedido:
        return cls(id=str(uuid4()), cliente_id=cliente_id)

    def adicionar_item(self, produto_id: str, quantidade: int, preco_unit: float) -> None:
        if self.status != "ABERTO":
            raise ValueError("Pedido não aceita alterações")
        if quantidade <= 0 or preco_unit <= 0:
            raise ValueError("Item inválido")
        self.itens.append(ItemPedido(produto_id, quantidade, preco_unit))

    def total(self) -> float:
        return sum(i.subtotal() for i in self.itens)

    def confirmar_pagamento(self) -> None:
        if not self.itens:
            raise ValueError("Pedido sem itens")
        self.status = "PAGO"

    def cancelar(self) -> None:
        if self.status == "PAGO":
            raise ValueError("Pedido pago não pode ser cancelado")
        self.status = "CANCELADO"
```

```python
# domain/repositories/pedido_repository.py
from abc import ABC, abstractmethod
from domain.entities.pedido import Pedido

class PedidoRepository(ABC):
    @abstractmethod
    def save(self, pedido: Pedido) -> None: ...

    @abstractmethod
    def find_by_id(self, pedido_id: str) -> Pedido | None: ...
```

### Application — Caso de uso

```python
# application/use_cases/criar_pedido.py
from dataclasses import dataclass
from domain.entities.pedido import Pedido
from domain.repositories.pedido_repository import PedidoRepository


@dataclass
class ItemInput:
    produto_id: str
    quantidade: int
    preco_unit: float


@dataclass
class CriarPedidoInput:
    cliente_id: str
    itens: list[ItemInput]


@dataclass
class CriarPedidoOutput:
    pedido_id: str
    total: float


class CriarPedido:
    def __init__(self, pedido_repo: PedidoRepository) -> None:
        self._repo = pedido_repo

    def execute(self, data: CriarPedidoInput) -> CriarPedidoOutput:
        if not data.itens:
            raise ValueError("Pedido deve ter ao menos um item")

        pedido = Pedido.criar(cliente_id=data.cliente_id)
        for item in data.itens:
            pedido.adicionar_item(item.produto_id, item.quantidade, item.preco_unit)

        self._repo.save(pedido)

        return CriarPedidoOutput(pedido_id=pedido.id, total=pedido.total())
```

### Infrastructure — Repositório concreto com SQLAlchemy

```python
# infrastructure/repositories/pedido_sqlalchemy_repo.py
from sqlalchemy.orm import Session
from domain.entities.pedido import Pedido, ItemPedido
from domain.repositories.pedido_repository import PedidoRepository
from infrastructure.models import PedidoModel, ItemPedidoModel  # ORM models


class PedidoSQLAlchemyRepository(PedidoRepository):
    def __init__(self, session: Session) -> None:
        self._session = session

    def save(self, pedido: Pedido) -> None:
        existing = self._session.get(PedidoModel, pedido.id)

        if existing:
            existing.status = pedido.status
        else:
            model = PedidoModel(
                id=pedido.id,
                cliente_id=pedido.cliente_id,
                status=pedido.status,
                itens=[
                    ItemPedidoModel(
                        produto_id=i.produto_id,
                        quantidade=i.quantidade,
                        preco_unit=i.preco_unit,
                    )
                    for i in pedido.itens
                ],
            )
            self._session.add(model)

        self._session.commit()

    def find_by_id(self, pedido_id: str) -> Pedido | None:
        model = self._session.get(PedidoModel, pedido_id)
        if not model:
            return None

        pedido = Pedido.criar(model.cliente_id)
        pedido.id = model.id
        pedido.status = model.status
        for item in model.itens:
            pedido.itens.append(ItemPedido(item.produto_id, item.quantidade, float(item.preco_unit)))
        return pedido
```

### Adapter — Controller FastAPI

```python
# adapters/http/pedido_router.py
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from application.use_cases.criar_pedido import CriarPedido, CriarPedidoInput, ItemInput
from adapters.dependencies import get_criar_pedido_use_case  # factory de DI

router = APIRouter(prefix="/pedidos", tags=["pedidos"])


class ItemRequest(BaseModel):
    produto_id: str
    quantidade: int
    preco_unit: float


class CriarPedidoRequest(BaseModel):
    cliente_id: str
    itens: list[ItemRequest]


@router.post("/", status_code=201)
def criar_pedido(
    body: CriarPedidoRequest,
    use_case: CriarPedido = Depends(get_criar_pedido_use_case),
):
    try:
        output = use_case.execute(
            CriarPedidoInput(
                cliente_id=body.cliente_id,
                itens=[ItemInput(i.produto_id, i.quantidade, i.preco_unit) for i in body.itens],
            )
        )
        return {"pedido_id": output.pedido_id, "total": output.total}
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))
```

### Composition root (main.py)

```python
# main.py — único lugar que monta todas as dependências
from fastapi import FastAPI
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from infrastructure.repositories.pedido_sqlalchemy_repo import PedidoSQLAlchemyRepository
from application.use_cases.criar_pedido import CriarPedido
from adapters.http.pedido_router import router

engine = create_engine("postgresql://user:pass@localhost/mydb")
SessionLocal = sessionmaker(bind=engine)

def get_criar_pedido_use_case():
    session = SessionLocal()
    repo = PedidoSQLAlchemyRepository(session)
    return CriarPedido(repo)

app = FastAPI()
app.include_router(router)
```

---

## 7. Exemplo completo em TypeScript

### Domain

```ts
// src/domain/Order.ts
import { randomUUID } from 'crypto'

export type OrderStatus = 'OPEN' | 'PAID' | 'CANCELLED'

export interface OrderItem {
  productId: string
  quantity: number
  unitPrice: number
}

export class Order {
  readonly id: string
  readonly customerId: string
  private _items: OrderItem[] = []
  private _status: OrderStatus = 'OPEN'

  constructor(customerId: string, id = randomUUID()) {
    this.id = id
    this.customerId = customerId
  }

  get items(): ReadonlyArray<OrderItem> { return this._items }
  get status(): OrderStatus { return this._status }

  addItem(productId: string, quantity: number, unitPrice: number): void {
    if (this._status !== 'OPEN') throw new Error('Pedido não aceita alterações')
    if (quantity <= 0 || unitPrice <= 0) throw new Error('Item inválido')
    this._items.push({ productId, quantity, unitPrice })
  }

  total(): number {
    return this._items.reduce((sum, i) => sum + i.quantity * i.unitPrice, 0)
  }

  confirmPayment(): void {
    if (this._items.length === 0) throw new Error('Pedido sem itens')
    this._status = 'PAID'
  }

  cancel(): void {
    if (this._status === 'PAID') throw new Error('Pedido pago não pode ser cancelado')
    this._status = 'CANCELLED'
  }
}
```

```ts
// src/domain/OrderRepository.ts
import { Order } from './Order'

export interface OrderRepository {
  save(order: Order): Promise<void>
  findById(id: string): Promise<Order | null>
}
```

### Application — Caso de uso

```ts
// src/application/CreateOrder.ts
import { Order } from '../domain/Order'
import { OrderRepository } from '../domain/OrderRepository'

interface ItemInput { productId: string; quantity: number; unitPrice: number }

interface CreateOrderInput { customerId: string; items: ItemInput[] }
interface CreateOrderOutput { orderId: string; total: number }

export class CreateOrder {
  constructor(private readonly repo: OrderRepository) {}

  async execute(input: CreateOrderInput): Promise<CreateOrderOutput> {
    if (input.items.length === 0) throw new Error('Pedido deve ter ao menos um item')

    const order = new Order(input.customerId)
    for (const item of input.items) {
      order.addItem(item.productId, item.quantity, item.unitPrice)
    }

    await this.repo.save(order)
    return { orderId: order.id, total: order.total() }
  }
}
```

### Infrastructure — Repositório com Prisma

```ts
// src/infrastructure/PrismaOrderRepository.ts
import { PrismaClient } from '@prisma/client'
import { Order } from '../domain/Order'
import { OrderRepository } from '../domain/OrderRepository'

export class PrismaOrderRepository implements OrderRepository {
  constructor(private readonly prisma: PrismaClient) {}

  async save(order: Order): Promise<void> {
    await this.prisma.order.upsert({
      where: { id: order.id },
      create: {
        id: order.id,
        customerId: order.customerId,
        status: order.status,
        items: { create: order.items.map((i) => ({ ...i })) },
      },
      update: { status: order.status },
    })
  }

  async findById(id: string): Promise<Order | null> {
    const row = await this.prisma.order.findUnique({ where: { id }, include: { items: true } })
    if (!row) return null

    const order = new Order(row.customerId, row.id)
    for (const item of row.items) {
      order.addItem(item.productId, item.quantity, item.unitPrice.toNumber())
    }
    return order
  }
}
```

### Adapter — Controller Express

```ts
// src/adapters/http/OrderController.ts
import { Request, Response } from 'express'
import { z } from 'zod'
import { CreateOrder } from '../../application/CreateOrder'

const Schema = z.object({
  customerId: z.string().uuid(),
  items: z.array(z.object({
    productId: z.string().uuid(),
    quantity: z.number().int().positive(),
    unitPrice: z.number().positive(),
  })).min(1),
})

export class OrderController {
  constructor(private readonly createOrder: CreateOrder) {}

  async create(req: Request, res: Response): Promise<void> {
    const result = Schema.safeParse(req.body)
    if (!result.success) {
      res.status(400).json({ errors: result.error.flatten() })
      return
    }

    try {
      const output = await this.createOrder.execute(result.data)
      res.status(201).json(output)
    } catch (err: any) {
      res.status(422).json({ error: err.message })
    }
  }
}
```

---

## 8. Como testar cada camada

### Testar o domain (sem nenhuma dependência externa)

```python
# Python
def test_pedido_nao_aceita_item_invalido():
    pedido = Pedido.criar(cliente_id="cli-1")
    with pytest.raises(ValueError):
        pedido.adicionar_item("prod-1", quantidade=0, preco_unit=10.0)

def test_total_do_pedido():
    pedido = Pedido.criar(cliente_id="cli-1")
    pedido.adicionar_item("prod-1", 2, 50.0)
    pedido.adicionar_item("prod-2", 1, 30.0)
    assert pedido.total() == 130.0
```

```ts
// TypeScript
test('Order rejects invalid item', () => {
  const order = new Order('customer-1')
  expect(() => order.addItem('prod-1', 0, 10)).toThrow('Item inválido')
})

test('Order total is correct', () => {
  const order = new Order('customer-1')
  order.addItem('prod-1', 2, 50)
  order.addItem('prod-2', 1, 30)
  expect(order.total()).toBe(130)
})
```

### Testar o caso de uso com repositório fake

```python
# Python — repositório in-memory
class FakePedidoRepository(PedidoRepository):
    def __init__(self):
        self.store: dict[str, Pedido] = {}

    def save(self, pedido: Pedido) -> None:
        self.store[pedido.id] = pedido

    def find_by_id(self, pedido_id: str) -> Pedido | None:
        return self.store.get(pedido_id)


def test_criar_pedido():
    repo = FakePedidoRepository()
    use_case = CriarPedido(repo)
    output = use_case.execute(CriarPedidoInput(
        cliente_id="cli-1",
        itens=[ItemInput("prod-1", 2, 50.0)],
    ))
    assert output.total == 100.0
    assert repo.find_by_id(output.pedido_id) is not None
```

```ts
// TypeScript — repositório in-memory
class FakeOrderRepository implements OrderRepository {
  private store = new Map<string, Order>()
  async save(order: Order) { this.store.set(order.id, order) }
  async findById(id: string) { return this.store.get(id) ?? null }
}

test('CreateOrder saves and returns total', async () => {
  const repo = new FakeOrderRepository()
  const useCase = new CreateOrder(repo)
  const output = await useCase.execute({
    customerId: 'cust-1',
    items: [{ productId: 'prod-1', quantity: 2, unitPrice: 50 }],
  })
  expect(output.total).toBe(100)
  expect(await repo.findById(output.orderId)).not.toBeNull()
})
```

---

## 9. Erros comuns

| Erro | Problema | Solução |
|---|---|---|
| Regra de negócio no controller | Vaza responsabilidade, dificulta teste | Mover para use case ou entidade |
| Entidade importando ORM | Domínio dependente de detalhe externo | Criar interface no domain, implementar em infra |
| Caso de uso importando Flask/Express | Acoplamento com transporte | Use case só conhece interfaces, controller é adapter |
| Validação de domínio misturada com validação HTTP | Dois conceitos conflitando | Pydantic/Zod valida formato na borda; domínio valida regras de negócio |
| Camadas com nomes mas sem fronteiras | Estrutura cosmética | Garantir que imports nunca atravessem a fronteira errada |

---

> Arquitetura Limpa não é sobre quantidade de pastas; é sobre direção correta de dependências.  
> Se o domínio não importa nada externo, você pode trocar banco, framework e fila sem reescrever regras de negócio.
