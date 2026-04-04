# KnowledgeEdu

> Base de conhecimento técnico estruturada em Markdown — cada pasta é um assunto, cada arquivo ensina tudo o que você precisa saber sobre ele.

---

## O que é este projeto?

**KnowledgeEdu** é um repositório de documentação técnica com foco educacional. O objetivo é simples: pegar um assunto complexo e escrever um guia que ensine **tudo**, do zero ao avançado, de forma clara, prática e acessível.

Cada documento aqui foi escrito com a mentalidade de quem quer entender de verdade — não apenas copiar e colar comandos, mas saber **o que cada coisa faz e por quê**.

---

## Princípios

- **Ensine o raciocínio, não só o comando** — toda instrução vem acompanhada de explicação
- **Sequência lógica** — os conceitos são apresentados em ordem de dependência
- **Exemplos reais** — exemplos baseados em cenários reais de desenvolvimento
- **Progressivo** — começa no básico e avança naturalmente para o avançado

---

## Estrutura

```
KnowledgeEdu/
├── PT/                        # Documentação em Português
│   ├── Agentes/               # Agentes de IA — construção e orquestração
│   ├── CI-CD/                 # Integração e entrega contínua com GitHub Actions
│   ├── Docker/                # Containers do zero ao deploy em produção
│   └── Servidor/              # Infraestrutura VPS — hardening, Nginx, SSL
│
└── EN/                        # Documentação em English (em construção)
```

---

## Conteúdo

### PT — Português

| Pasta | Arquivo | O que você vai aprender |
|---|---|---|
| `Servidor` | [`VPS_SETUP.md`](PT/Servidor/VPS_SETUP.md) | Configurar uma VPS do zero: SSH, firewall, Nginx, SSL, Docker e segurança |
| `Servidor` | [`DEPLOY.md`](PT/Servidor/DEPLOY.md) | Subir backend + banco em produção com Docker Compose e CD automático |
| `Docker` | [`DOCKER.md`](PT/Docker/DOCKER.md) | Containers, imagens, volumes, redes, Docker Compose e boas práticas |
| `CI-CD` | [`GITHUB_ACTIONS.md`](PT/CI-CD/GITHUB_ACTIONS.md) | Pipelines CI/CD com GitHub Actions: lint, testes, build e deploy automático |
| `Agentes` | [`AGENTES_IA.md`](PT/Agentes/AGENTES_IA.md) | Agentes de IA: conceitos, construção com Claude API e orquestração de tarefas |

---

## Para quem é?

- Desenvolvedores que querem entender infraestrutura e DevOps de verdade
- Pessoas que estão começando e precisam de um guia que explique o porquê das coisas
- Profissionais que querem uma referência clara para revisitar conceitos

---

## Como usar

Navegue pelas pastas de acordo com o assunto que quer estudar. Cada arquivo é autocontido — você não precisa ler outros documentos para seguir um guia, mas os conceitos estão interligados quando faz sentido.

Sugestão de ordem para quem está começando:

```
1. Docker/DOCKER.md
2. Servidor/VPS_SETUP.md
3. Servidor/DEPLOY.md
4. CI-CD/GITHUB_ACTIONS.md
5. Agentes/AGENTES_IA.md
```

---

## Idiomas

A documentação principal está em **Português (PT)**. A versão em inglês (`EN/`) está em construção.

---

*Conhecimento que não é ensinado é conhecimento perdido.*
