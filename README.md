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
│   ├── Arquitetura/           # Arquitetura de software: DDD, padrões e clean architecture
│   ├── CI-CD/                 # Integração e entrega contínua com GitHub Actions
│   ├── Cyberseguranca/        # Segurança aplicada para dev full stack/full cycle
│   ├── Docker/                # Containers do zero ao deploy em produção
│   ├── IoT/                   # Internet das Coisas: camadas, protocolos e configuração ponta a ponta
│   ├── MachineLearning/       # ML do básico ao avançado: estatística, modelos, CV, séries e LLM
│   └── Servidor/              # Infraestrutura VPS multi-serviço — hardening, Traefik, observabilidade
│
└── EN/                        # Documentação em English (em construção)
```

---

## Conteúdo

### PT — Português

| Pasta | Arquivo | O que você vai aprender |
|---|---|---|
| `Servidor` | [`VPS_SETUP.md`](PT/Servidor/VPS_SETUP.md) | Configurar uma VPS multi-serviço do zero: SSH, firewall, Docker, Traefik (proxy por labels + HTTPS automático), observabilidade e segurança |
| `Servidor` | [`OBSERVABILIDADE.md`](PT/Servidor/OBSERVABILIDADE.md) | Métricas, logs e dashboards com Prometheus, Grafana, Loki e Grafana Alloy |
| `Servidor` | [`DEPLOY.md`](PT/Servidor/DEPLOY.md) | Subir backend + banco em produção com Docker Compose e CD automático (exemplo concreto) |
| `Arquitetura` | [`ARQUITETURA_DE_SOFTWARE.md`](PT/Arquitetura/ARQUITETURA_DE_SOFTWARE.md) | Fundamentos de arquitetura de software para full stack/full cycle com UML e exemplos práticos em Python |
| `MachineLearning` | [`MACHINE_LEARNING.md`](PT/MachineLearning/MACHINE_LEARNING.md) | Trilha de ML do básico ao avançado: dedução de fórmulas, regressão, árvore, SVM, estatística, visão computacional, séries temporais, LLM e MLOps |
| `IoT` | [`IOT.md`](PT/IoT/IOT.md) | Arquitetura IoT com camadas, protocolos de comunicação e configuração prática de microcontrolador e servidor |
| `Docker` | [`DOCKER.md`](PT/Docker/DOCKER.md) | Containers, imagens, volumes, redes, Docker Compose e boas práticas |
| `Cyberseguranca` | [`CYBERSEGURANCA.md`](PT/Cyberseguranca/CYBERSEGURANCA.md) | Fundamentos de cybersegurança para dev full stack/full cycle: app, API, CI/CD, Docker e operação |
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
2. Arquitetura/ARQUITETURA_DE_SOFTWARE.md
3. MachineLearning/MACHINE_LEARNING.md
4. IoT/IOT.md
5. Servidor/VPS_SETUP.md
6. Servidor/OBSERVABILIDADE.md
7. Cyberseguranca/CYBERSEGURANCA.md
8. Servidor/DEPLOY.md
9. CI-CD/GITHUB_ACTIONS.md
10. Agentes/AGENTES_IA.md
```

---

## Idiomas

A documentação principal está em **Português (PT)**. A versão em inglês (`EN/`) está em construção.

---

*Conhecimento que não é ensinado é conhecimento perdido.*
