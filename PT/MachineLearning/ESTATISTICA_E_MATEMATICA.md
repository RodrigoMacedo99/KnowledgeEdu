# Estatística e Matemática para Machine Learning

> O núcleo que explica o comportamento dos algoritmos — com intuição, fórmulas e código Python prático.

---

## Índice

1. [Estatística descritiva](#1-estatística-descritiva)
2. [Distribuições de probabilidade](#2-distribuições-de-probabilidade)
3. [Teorema de Bayes](#3-teorema-de-bayes)
4. [Álgebra linear para modelos](#4-álgebra-linear-para-modelos)
5. [Otimização — gradiente descendente](#5-otimização--gradiente-descendente)
6. [Correlação e causalidade](#6-correlação-e-causalidade)
7. [Testes de hipótese](#7-testes-de-hipótese)
8. [Validação e avaliação correta](#8-validação-e-avaliação-correta)

---

## 1. Estatística descritiva

### Medidas de posição e dispersão

```
μ = (1/n) Σ xᵢ                 # média
σ² = (1/n) Σ (xᵢ - μ)²         # variância
σ  = √σ²                        # desvio padrão
```

```python
import numpy as np
import pandas as pd

dados = np.array([10, 20, 20, 30, 40, 50, 60])

print(f"Média:          {dados.mean():.2f}")
print(f"Mediana:        {np.median(dados):.2f}")
print(f"Desvio padrão:  {dados.std():.2f}")
print(f"Variância:      {dados.var():.2f}")
print(f"Mínimo/Máximo:  {dados.min()} / {dados.max()}")
print(f"IQR (Q3 - Q1):  {np.percentile(dados, 75) - np.percentile(dados, 25):.2f}")
```

```python
# Em DataFrame — visão completa de uma vez
df = pd.DataFrame({"valor": dados, "categoria": list("AAABBBB")})

# Resumo numérico
print(df["valor"].describe())

# Por grupo
print(df.groupby("categoria")["valor"].agg(["mean", "std", "count"]))
```

### Detecção de outliers com IQR

```python
def detectar_outliers_iqr(serie: pd.Series) -> pd.Series:
    Q1, Q3 = serie.quantile(0.25), serie.quantile(0.75)
    IQR = Q3 - Q1
    limite_inf = Q1 - 1.5 * IQR
    limite_sup = Q3 + 1.5 * IQR
    return serie[(serie < limite_inf) | (serie > limite_sup)]

outliers = detectar_outliers_iqr(df["valor"])
print(f"Outliers: {outliers.values}")
```

**Por que importa em ML:** média é sensível a outliers — às vezes a mediana ou transformação log é mais adequada para escalar features.

---

## 2. Distribuições de probabilidade

### Normal (Gaussiana)

```python
from scipy import stats
import matplotlib.pyplot as plt

# Gerar amostra de distribuição normal
amostras = stats.norm.rvs(loc=0, scale=1, size=1000, random_state=42)

# Testar se é normal — Shapiro-Wilk (bom até ~5000 amostras)
stat, p_valor = stats.shapiro(amostras[:200])
print(f"Shapiro-Wilk p-valor: {p_valor:.4f}")
print("Normal?" , "Sim" if p_valor > 0.05 else "Não")

# PDF e CDF
x = np.linspace(-4, 4, 100)
pdf = stats.norm.pdf(x)
cdf = stats.norm.cdf(x)

# Probabilidade de um valor cair entre -1 e 1
prob = stats.norm.cdf(1) - stats.norm.cdf(-1)
print(f"P(-1 < X < 1) = {prob:.4f}")  # ≈ 0.6827 (regra 68-95-99.7)
```

### Por que importa em ML

- Regressão linear assume resíduos normais.
- Muitas features em dados reais têm distribuição skewed — log-transform ajuda.
- Z-score (padronização) assume aproximadamente normal.

```python
# Comparar distribuição original vs log-transformada
import numpy as np

receita = np.array([500, 1200, 800, 15000, 950, 750, 22000])  # distribuição skewed

receita_log = np.log1p(receita)  # log(1 + x) evita log(0)

print(f"Skewness original:     {pd.Series(receita).skew():.2f}")
print(f"Skewness log-transform:{pd.Series(receita_log).skew():.2f}")
```

---

## 3. Teorema de Bayes

```
P(A|B) = P(B|A) × P(A) / P(B)

P(A)   = prior (crença antes de ver os dados)
P(B|A) = likelihood (probabilidade dos dados dado o evento)
P(A|B) = posterior (crença atualizada)
```

### Exemplo prático — classificador de spam

```python
# P(spam | "grátis" no email)
# Usando Bayes ingênuo (Naive Bayes)

from sklearn.naive_bayes import MultinomialNB
from sklearn.feature_extraction.text import CountVectorizer

emails = [
    "ganhe dinheiro grátis agora",
    "oferta exclusiva grátis",
    "reunião de equipe amanhã",
    "relatório mensal disponível",
    "promoção imperdível grátis ganhe",
]
labels = [1, 1, 0, 0, 1]  # 1 = spam, 0 = não-spam

vectorizer = CountVectorizer()
X = vectorizer.fit_transform(emails)

model = MultinomialNB()
model.fit(X, labels)

novo_email = ["promoção especial grátis para você"]
X_novo = vectorizer.transform(novo_email)
proba = model.predict_proba(X_novo)[0]
print(f"P(não-spam) = {proba[0]:.2f} | P(spam) = {proba[1]:.2f}")
```

---

## 4. Álgebra linear para modelos

### Produto matricial — base da regressão linear

```
ŷ = Xw + b

X: (n_amostras, n_features)   — matriz de features
w: (n_features,)              — pesos aprendidos
b: escalar                    — bias/intercepto
ŷ: (n_amostras,)              — previsões
```

```python
import numpy as np

# Simulação manual de predição linear
X = np.array([[1, 2], [3, 4], [5, 6]])  # 3 amostras, 2 features
w = np.array([0.5, 0.3])                # pesos
b = 1.0                                 # bias

y_pred = X @ w + b  # @ = produto matricial
print(f"Predições: {y_pred}")
```

### Cosine similarity — base de embeddings e RAG

```
cos(θ) = (a · b) / (||a|| × ||b||)

Resultado em [-1, 1]:
  1.0 = vetores idênticos em direção
  0.0 = vetores ortogonais (sem relação)
 -1.0 = vetores opostos
```

```python
import numpy as np

def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    return np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12)

# Exemplo com embeddings simulados
vec_gato   = np.array([0.9, 0.1, 0.8])
vec_felino = np.array([0.85, 0.15, 0.75])
vec_carro  = np.array([0.1, 0.9, 0.2])

print(f"gato × felino: {cosine_similarity(vec_gato, vec_felino):.4f}")  # alto
print(f"gato × carro:  {cosine_similarity(vec_gato, vec_carro):.4f}")  # baixo
```

### Decomposição de valores singulares (SVD) — intuição

```python
# SVA é usada em PCA, recomendação, compressão
# Exemplo: reduzir dimensionalidade

from sklearn.decomposition import PCA
import numpy as np

X = np.random.randn(100, 10)  # 100 amostras, 10 features

pca = PCA(n_components=2)
X_reduzido = pca.fit_transform(X)

print(f"Shape original: {X.shape}")
print(f"Shape reduzido: {X_reduzido.shape}")
print(f"Variância explicada: {pca.explained_variance_ratio_.sum():.2%}")
```

---

## 5. Otimização — gradiente descendente

### Fórmula e intuição

```
J(w) = função de custo (ex: MSE)
w := w - η × ∂J/∂w

η = learning rate (tamanho do passo)
∂J/∂w = gradiente (direção de subida → subtraímos para descer)
```

### Implementação do zero — regressão linear com GD

```python
import numpy as np

def regressao_linear_gd(X: np.ndarray, y: np.ndarray, lr: float = 0.01, epochs: int = 1000):
    n = len(y)
    w = np.zeros(X.shape[1])
    b = 0.0
    historico_loss = []

    for epoch in range(epochs):
        # Predição
        y_pred = X @ w + b

        # Gradientes
        erro = y_pred - y
        dw = (2 / n) * X.T @ erro
        db = (2 / n) * erro.sum()

        # Atualização
        w -= lr * dw
        b -= lr * db

        # Loss (MSE)
        loss = np.mean(erro ** 2)
        historico_loss.append(loss)

        if epoch % 100 == 0:
            print(f"Época {epoch:4d} | MSE: {loss:.4f}")

    return w, b, historico_loss


# Exemplo
np.random.seed(42)
X = np.random.randn(100, 2)
y_real = 3 * X[:, 0] + 2 * X[:, 1] + np.random.randn(100) * 0.1

w, b, losses = regressao_linear_gd(X, y_real, lr=0.05, epochs=500)
print(f"\nPesos aprendidos: {w}")  # deve ser próximo de [3, 2]
```

### Learning rate — impacto prático

```python
# Learning rate muito alta → diverge
# Learning rate muito baixa → converge lentamente
# Estratégia comum: testar [1e-4, 1e-3, 1e-2, 1e-1] e observar a curva de loss

lrs = [0.001, 0.01, 0.1, 1.0]
for lr in lrs:
    _, _, losses = regressao_linear_gd(X, y_real, lr=lr, epochs=200)
    print(f"lr={lr:.3f} | loss final: {losses[-1]:.4f}")
```

---

## 6. Correlação e causalidade

```python
import pandas as pd
import numpy as np

np.random.seed(42)
df = pd.DataFrame({
    "temperatura": np.random.normal(25, 5, 200),
    "vendas_sorvete": np.random.normal(100, 20, 200),
    "afogamentos": np.random.normal(5, 1, 200),
})

# Simular correlação espúria (ambos sobem no verão)
df["vendas_sorvete"] += df["temperatura"] * 3
df["afogamentos"] += df["temperatura"] * 0.2

# Correlação de Pearson (relação linear)
corr = df.corr(method="pearson")
print(corr)

# Correlação de Spearman (relação monotônica — mais robusta a outliers)
corr_spearman = df.corr(method="spearman")
print(corr_spearman)
```

**Lembre-se:** `sorvete × afogamentos` pode ter correlação alta porque ambos dependem da temperatura — isso é **correlação espúria**, não causalidade.

### Selecionar features por correlação com o target

```python
# Remover features altamente correlacionadas entre si (multicolinearidade)
def remover_multicolinear(df: pd.DataFrame, threshold: float = 0.95) -> list[str]:
    corr_matrix = df.corr().abs()
    upper = corr_matrix.where(np.triu(np.ones(corr_matrix.shape), k=1).astype(bool))
    para_remover = [col for col in upper.columns if any(upper[col] > threshold)]
    return para_remover

colunas_remover = remover_multicolinear(df)
print(f"Colunas a remover: {colunas_remover}")
```

---

## 7. Testes de hipótese

### T-test — comparar duas médias

```python
from scipy import stats

# Pergunta: o grupo A converte mais que o grupo B? (A/B test)
grupo_a = np.array([0.12, 0.15, 0.11, 0.13, 0.14, 0.16, 0.12])  # taxas de conversão
grupo_b = np.array([0.10, 0.09, 0.11, 0.10, 0.09, 0.10, 0.11])

t_stat, p_valor = stats.ttest_ind(grupo_a, grupo_b)
alpha = 0.05

print(f"t-statistic: {t_stat:.4f}")
print(f"p-valor:     {p_valor:.4f}")
print(f"Diferença significativa: {'Sim' if p_valor < alpha else 'Não'}")
```

### Qui-quadrado — variáveis categóricas

```python
# Pergunta: existe relação entre gênero e compra?
from scipy.stats import chi2_contingency

# Tabela de contingência: [comprou, não comprou] × [masculino, feminino]
tabela = np.array([[30, 20],   # masculino
                   [25, 25]])  # feminino

chi2, p, dof, esperado = chi2_contingency(tabela)
print(f"Chi² = {chi2:.4f} | p-valor = {p:.4f}")
print(f"Relação significativa: {'Sim' if p < 0.05 else 'Não'}")
```

### Erro tipo I e tipo II

```
Tipo I (falso positivo):  rejeitar H0 quando é verdadeira — controlado por α (geralmente 0.05)
Tipo II (falso negativo): não rejeitar H0 quando é falsa   — controlado por poder estatístico (1 - β)

Em ML: tipo I = detectar drift falso; tipo II = não detectar drift real.
```

---

## 8. Validação e avaliação correta

### Cross-validation — estimativa mais confiável do erro

```python
from sklearn.model_selection import cross_val_score, StratifiedKFold
from sklearn.ensemble import RandomForestClassifier
from sklearn.datasets import make_classification

X, y = make_classification(n_samples=500, n_features=20, random_state=42)

model = RandomForestClassifier(n_estimators=100, random_state=42)

# K-Fold estratificado mantém proporção de classes em cada fold
cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
scores = cross_val_score(model, X, y, cv=cv, scoring="roc_auc")

print(f"ROC-AUC por fold: {scores.round(4)}")
print(f"Média: {scores.mean():.4f} ± {scores.std():.4f}")
```

### Bootstrap — intervalo de confiança da métrica

```python
from sklearn.utils import resample
from sklearn.metrics import roc_auc_score

def bootstrap_intervalo(y_true, y_proba, n=1000, alpha=0.05):
    """Intervalo de confiança via bootstrap para ROC-AUC."""
    scores = []
    for _ in range(n):
        indices = resample(range(len(y_true)), random_state=None)
        score = roc_auc_score(y_true[indices], y_proba[indices])
        scores.append(score)

    lower = np.percentile(scores, 100 * alpha / 2)
    upper = np.percentile(scores, 100 * (1 - alpha / 2))
    return lower, upper

# Exemplo de uso após treinar modelo
# lower, upper = bootstrap_intervalo(y_test, proba_test)
# print(f"ROC-AUC IC 95%: [{lower:.4f}, {upper:.4f}]")
```

### Overfitting × Underfitting — como diagnosticar

```python
from sklearn.model_selection import learning_curve
import numpy as np

def plotar_learning_curve(model, X, y):
    sizes, train_scores, val_scores = learning_curve(
        model, X, y,
        train_sizes=np.linspace(0.1, 1.0, 10),
        cv=5,
        scoring="roc_auc",
    )

    train_mean = train_scores.mean(axis=1)
    val_mean   = val_scores.mean(axis=1)

    for size, tr, va in zip(sizes, train_mean, val_mean):
        print(f"n={size:4.0f} | treino={tr:.3f} | validação={va:.3f} | gap={tr-va:.3f}")

    # Interpretação:
    # gap grande → overfitting (modelo memoriza treino)
    # ambos baixos → underfitting (modelo não aprende)
    # gap pequeno, ambos altos → bom ajuste

plotar_learning_curve(RandomForestClassifier(n_estimators=100, random_state=42), X, y)
```

---

> Sem base estatística e matemática, ML vira tentativa e erro.  
> Com ela, você consegue diagnosticar, interpretar e corrigir modelos — não só rodá-los.
