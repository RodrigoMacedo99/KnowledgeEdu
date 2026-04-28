# Modelos Supervisionados — Regressão, Árvore, Ensemble e mais

> Pipeline completo: do dado bruto à avaliação correta, com os algoritmos que resolvem a maioria dos problemas reais.

---

## Índice

1. [Pipeline completo de treino](#1-pipeline-completo-de-treino)
2. [Pré-processamento com sklearn Pipeline](#2-pré-processamento-com-sklearn-pipeline)
3. [Regressão Linear e Logística](#3-regressão-linear-e-logística)
4. [Árvore de Decisão](#4-árvore-de-decisão)
5. [Random Forest](#5-random-forest)
6. [XGBoost e LightGBM](#6-xgboost-e-lightgbm)
7. [SVM](#7-svm)
8. [Métricas de avaliação](#8-métricas-de-avaliação)
9. [Tuning de hiperparâmetros](#9-tuning-de-hiperparâmetros)
10. [Desbalanceamento de classes](#10-desbalanceamento-de-classes)
11. [Feature importance e interpretabilidade](#11-feature-importance-e-interpretabilidade)
12. [Quando usar cada modelo](#12-quando-usar-cada-modelo)

---

## 1. Pipeline completo de treino

```python
import pandas as pd
import numpy as np
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split

# Dados de exemplo — substituir pelo seu dataset
X, y = make_classification(
    n_samples=2000,
    n_features=20,
    n_informative=10,
    n_redundant=5,
    weights=[0.8, 0.2],  # 80/20 — desbalanceado
    random_state=42,
)

# Split estratificado — mantém proporção de classes
X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.2, stratify=y, random_state=42
)

print(f"Treino: {X_train.shape} | Teste: {X_test.shape}")
print(f"Proporção positivos treino: {y_train.mean():.2%}")
print(f"Proporção positivos teste:  {y_test.mean():.2%}")
```

---

## 2. Pré-processamento com sklearn Pipeline

Usar `Pipeline` garante que o pré-processamento seja aplicado corretamente em treino e teste — sem data leakage.

```python
from sklearn.pipeline import Pipeline
from sklearn.compose import ColumnTransformer
from sklearn.preprocessing import StandardScaler, OneHotEncoder, LabelEncoder
from sklearn.impute import SimpleImputer

# Exemplo com dataset misto (numérico + categórico)
df = pd.DataFrame({
    "idade":     [25, 32, np.nan, 45, 28, 55, np.nan, 38],
    "renda":     [3000, 5000, 4000, 8000, 3500, 12000, 6000, 7000],
    "cidade":    ["SP", "RJ", "SP", "MG", np.nan, "SP", "RJ", "MG"],
    "contratou": [0, 1, 0, 1, 0, 1, 1, 1],
})

X = df.drop(columns=["contratou"])
y = df["contratou"]

colunas_numericas = ["idade", "renda"]
colunas_categoricas = ["cidade"]

preprocessor = ColumnTransformer(
    transformers=[
        ("num", Pipeline([
            ("imputer", SimpleImputer(strategy="median")),  # preenche nulos com mediana
            ("scaler", StandardScaler()),                   # normaliza
        ]), colunas_numericas),

        ("cat", Pipeline([
            ("imputer", SimpleImputer(strategy="most_frequent")),  # preenche nulos com moda
            ("encoder", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
        ]), colunas_categoricas),
    ]
)

# Pipeline completo: pré-processamento + modelo
from sklearn.ensemble import RandomForestClassifier

pipeline = Pipeline([
    ("preprocessor", preprocessor),
    ("model", RandomForestClassifier(n_estimators=100, random_state=42)),
])

from sklearn.model_selection import cross_val_score, StratifiedKFold

cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
scores = cross_val_score(pipeline, X, y, cv=cv, scoring="roc_auc")
print(f"ROC-AUC: {scores.mean():.4f} ± {scores.std():.4f}")
```

**Por que Pipeline importa:**
- Evita que o scaler veja dados de teste durante o `fit` (data leakage).
- Salvar o pipeline salva pré-processamento + modelo junto — pronto para produção.

---

## 3. Regressão Linear e Logística

### Regressão Linear — prever valor contínuo

```
ŷ = w₀ + w₁x₁ + w₂x₂ + ... + wₙxₙ

Cada coeficiente wᵢ: variação esperada em ŷ ao aumentar xᵢ em 1 unidade,
mantendo as demais constantes.
```

```python
from sklearn.linear_model import LinearRegression, Ridge, Lasso
from sklearn.datasets import make_regression
from sklearn.metrics import mean_squared_error, r2_score
import numpy as np

X, y = make_regression(n_samples=500, n_features=10, noise=20, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Regressão simples
lr = LinearRegression()
lr.fit(X_train, y_train)
y_pred = lr.predict(X_test)

rmse = np.sqrt(mean_squared_error(y_test, y_pred))
r2 = r2_score(y_test, y_pred)
print(f"RMSE: {rmse:.2f} | R²: {r2:.4f}")

# Coeficientes — interpretabilidade
for i, coef in enumerate(lr.coef_):
    print(f"  Feature {i}: {coef:.3f}")

# Ridge (L2) e Lasso (L1) — reduzem overfitting com regularização
ridge = Ridge(alpha=1.0)    # penaliza pesos grandes
lasso = Lasso(alpha=0.1)    # zera pesos irrelevantes (seleção automática de features)
```

### Regressão Logística — classificação binária

```
P(y=1 | x) = σ(w·x + b) = 1 / (1 + e^{-(w·x + b)})

Saída: probabilidade entre 0 e 1
Threshold padrão: 0.5 (mas ajustar conforme custo do erro)
```

```python
from sklearn.linear_model import LogisticRegression
from sklearn.datasets import make_classification

X, y = make_classification(n_samples=1000, n_features=10, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

lr = LogisticRegression(C=1.0, max_iter=1000, random_state=42)
lr.fit(X_train, y_train)

# Probabilidades — mais úteis que classe pura
proba = lr.predict_proba(X_test)[:, 1]

# Ajustar threshold — ex: quando falso negativo custa mais
threshold = 0.3  # mais sensível = captura mais positivos
y_pred_ajustado = (proba >= threshold).astype(int)

from sklearn.metrics import classification_report
print(classification_report(y_test, y_pred_ajustado))
```

---

## 4. Árvore de Decisão

```python
from sklearn.tree import DecisionTreeClassifier, export_text

X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# max_depth controla complexidade — sem limite → overfitting garantido
tree = DecisionTreeClassifier(
    max_depth=5,
    min_samples_leaf=20,   # folha precisa de ao menos 20 amostras
    criterion="gini",
    random_state=42,
)
tree.fit(X_train, y_train)

# Visualizar regras de decisão
print(export_text(tree, max_depth=3))

# Feature importance
importances = pd.Series(
    tree.feature_importances_,
    index=[f"feature_{i}" for i in range(X.shape[1])]
).sort_values(ascending=False)
print(importances.head(5))
```

**Quando usar árvore:** quando precisar de explicabilidade total (regras de negócio legíveis, auditoria, conformidade).

---

## 5. Random Forest

```python
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import cross_val_score

rf = RandomForestClassifier(
    n_estimators=300,    # mais árvores = mais estável (diminishing returns após ~300)
    max_depth=None,      # deixar crescer (forest controla overfitting por voting)
    min_samples_leaf=5,
    max_features="sqrt", # cada árvore vê sqrt(n_features) — diversidade
    random_state=42,
    n_jobs=-1,           # usar todos os cores
)

# Avaliar com cross-validation
cv_scores = cross_val_score(rf, X, y, cv=5, scoring="roc_auc")
print(f"RF ROC-AUC: {cv_scores.mean():.4f} ± {cv_scores.std():.4f}")

# Treinar no treino completo para teste final
rf.fit(X_train, y_train)
proba_rf = rf.predict_proba(X_test)[:, 1]
```

---

## 6. XGBoost e LightGBM

Os modelos que mais ganham competições de ML em dados tabulares.

### XGBoost

```python
from xgboost import XGBClassifier
from sklearn.metrics import roc_auc_score

xgb = XGBClassifier(
    n_estimators=500,
    max_depth=6,
    learning_rate=0.05,        # menor = mais lento mas mais preciso
    subsample=0.8,             # usa 80% das amostras por árvore
    colsample_bytree=0.8,      # usa 80% das features por árvore
    min_child_weight=5,        # regularização
    use_label_encoder=False,
    eval_metric="auc",
    early_stopping_rounds=50,  # para antes de overfitar
    random_state=42,
    n_jobs=-1,
)

# early stopping requer eval_set
xgb.fit(
    X_train, y_train,
    eval_set=[(X_test, y_test)],
    verbose=50,
)

proba_xgb = xgb.predict_proba(X_test)[:, 1]
print(f"XGB ROC-AUC: {roc_auc_score(y_test, proba_xgb):.4f}")
```

### LightGBM — mais rápido, bom em datasets grandes

```python
import lightgbm as lgb

lgbm = lgb.LGBMClassifier(
    n_estimators=500,
    max_depth=-1,           # sem limite — controla com num_leaves
    num_leaves=31,          # main parâmetro de complexidade no LGBM
    learning_rate=0.05,
    min_child_samples=20,
    subsample=0.8,
    colsample_bytree=0.8,
    random_state=42,
    n_jobs=-1,
    verbose=-1,
)

# Com early stopping via callbacks
callbacks = [lgb.early_stopping(50, verbose=False), lgb.log_evaluation(100)]

lgbm.fit(
    X_train, y_train,
    eval_set=[(X_test, y_test)],
    callbacks=callbacks,
)

proba_lgbm = lgbm.predict_proba(X_test)[:, 1]
print(f"LGBM ROC-AUC: {roc_auc_score(y_test, proba_lgbm):.4f}")
```

### Quando XGB/LGBM são a melhor escolha

- Dados tabulares estruturados (tabelas com features numéricas e categóricas).
- Precisão máxima importa mais que velocidade de treino.
- Competições de Kaggle — quase sempre vence em dados tabulares.

---

## 7. SVM

```python
from sklearn.svm import SVC
from sklearn.preprocessing import StandardScaler
from sklearn.pipeline import Pipeline

# SVM é sensível a escala — sempre normalizar
svm_pipeline = Pipeline([
    ("scaler", StandardScaler()),
    ("svm", SVC(
        kernel="rbf",        # RBF = fronteiras não-lineares
        C=1.0,               # regularização — maior C = menos margem, mais ajuste
        gamma="scale",       # escala automática do kernel
        probability=True,    # habilitar predict_proba (mais lento)
        random_state=42,
    )),
])

svm_pipeline.fit(X_train, y_train)
proba_svm = svm_pipeline.predict_proba(X_test)[:, 1]
print(f"SVM ROC-AUC: {roc_auc_score(y_test, proba_svm):.4f}")
```

**Quando usar SVM:** dados com poucas amostras mas muitas features (texto com TF-IDF, por exemplo).

---

## 8. Métricas de avaliação

```python
from sklearn.metrics import (
    accuracy_score, precision_score, recall_score,
    f1_score, roc_auc_score, average_precision_score,
    confusion_matrix, classification_report,
)

def avaliar_classificacao(nome: str, y_true, y_proba, threshold: float = 0.5):
    y_pred = (y_proba >= threshold).astype(int)

    print(f"\n=== {nome} ===")
    print(f"Accuracy:   {accuracy_score(y_true, y_pred):.4f}  ← cuidado se classes desbalanceadas")
    print(f"Precision:  {precision_score(y_true, y_pred):.4f}  ← dos que prediz positivo, quantos são?")
    print(f"Recall:     {recall_score(y_true, y_pred):.4f}  ← dos positivos reais, quantos captura?")
    print(f"F1 Score:   {f1_score(y_true, y_pred):.4f}  ← harmônica entre precision e recall")
    print(f"ROC-AUC:    {roc_auc_score(y_true, y_proba):.4f}  ← independe do threshold")
    print(f"PR-AUC:     {average_precision_score(y_true, y_proba):.4f}  ← melhor para classes desbalanceadas")

    cm = confusion_matrix(y_true, y_pred)
    print(f"\nMatriz de confusão:\n{cm}")
    print(f"  TN={cm[0,0]} FP={cm[0,1]}")
    print(f"  FN={cm[1,0]} TP={cm[1,1]}")

    print(f"\n{classification_report(y_true, y_pred)}")

avaliar_classificacao("Random Forest", y_test, proba_rf)
avaliar_classificacao("XGBoost",       y_test, proba_xgb)
```

### Como escolher a métrica principal

```
Usar ROC-AUC quando:
  - Classes razoavelmente balanceadas
  - Você precisa comparar modelos independente de threshold

Usar PR-AUC quando:
  - Classes muito desbalanceadas (detecção de fraude, doença rara)

Usar Recall quando:
  - Falso negativo custa mais (perder um caso de doença, não detectar fraude)

Usar Precision quando:
  - Falso positivo custa mais (spam chegando na caixa de entrada, alarme falso)

Nunca usar Accuracy como métrica principal em dados desbalanceados:
  - 95% negativo → modelo que chuta "negativo" sempre tem 95% de accuracy
```

---

## 9. Tuning de hiperparâmetros

### Com Optuna (mais eficiente que GridSearch)

```python
import optuna
from sklearn.model_selection import cross_val_score, StratifiedKFold

optuna.logging.set_verbosity(optuna.logging.WARNING)

def objective(trial):
    params = {
        "n_estimators": trial.suggest_int("n_estimators", 100, 500),
        "max_depth": trial.suggest_int("max_depth", 3, 8),
        "learning_rate": trial.suggest_float("learning_rate", 1e-3, 0.3, log=True),
        "subsample": trial.suggest_float("subsample", 0.6, 1.0),
        "colsample_bytree": trial.suggest_float("colsample_bytree", 0.6, 1.0),
        "min_child_weight": trial.suggest_int("min_child_weight", 1, 10),
    }

    model = XGBClassifier(**params, use_label_encoder=False,
                          eval_metric="auc", random_state=42, n_jobs=-1)

    cv = StratifiedKFold(n_splits=3, shuffle=True, random_state=42)
    scores = cross_val_score(model, X_train, y_train, cv=cv, scoring="roc_auc")
    return scores.mean()


study = optuna.create_study(direction="maximize")
study.optimize(objective, n_trials=30)

print(f"Melhor ROC-AUC: {study.best_value:.4f}")
print(f"Melhores params: {study.best_params}")

# Treinar com os melhores parâmetros
melhor = XGBClassifier(**study.best_params, use_label_encoder=False,
                        eval_metric="auc", random_state=42, n_jobs=-1)
melhor.fit(X_train, y_train)
```

---

## 10. Desbalanceamento de classes

```python
from imblearn.over_sampling import SMOTE
from imblearn.pipeline import Pipeline as ImbPipeline

print(f"Proporção antes do SMOTE: {y_train.mean():.2%} positivos")

# SMOTE — gera amostras sintéticas da classe minoritária
smote = SMOTE(sampling_strategy=0.5, random_state=42)  # até 50% de positivos
X_bal, y_bal = smote.fit_resample(X_train, y_train)

print(f"Proporção após SMOTE:  {y_bal.mean():.2%} positivos")

# Alternativa mais simples: class_weight
model_balanced = XGBClassifier(
    scale_pos_weight=(y_train == 0).sum() / (y_train == 1).sum(),  # peso inverso
    n_estimators=200,
    random_state=42,
)
model_balanced.fit(X_train, y_train)
```

---

## 11. Feature importance e interpretabilidade

```python
import shap

# SHAP — explica cada predição individualmente
explainer = shap.TreeExplainer(xgb)
shap_values = explainer.shap_values(X_test[:100])

# Importância média de cada feature
shap.summary_plot(shap_values, X_test[:100], plot_type="bar", show=False)

# Explicar uma predição específica
shap.force_plot(
    explainer.expected_value,
    shap_values[0],
    X_test[0],
    show=False,
)

# Feature importance padrão (menos confiável que SHAP)
fi = pd.Series(xgb.feature_importances_, name="importance")
fi.sort_values(ascending=False).head(10)
```

---

## 12. Quando usar cada modelo

| Modelo | Melhor para | Cuidado |
|---|---|---|
| Regressão Linear/Logística | Baseline, interpretabilidade total, dados lineares | Não captura relações não lineares |
| Árvore de Decisão | Regras de negócio explícitas, auditoria | Overfita facilmente sem limites |
| Random Forest | Robustez sem muito tuning, datasets médios | Mais lento que LGBM, menos preciso que XGB |
| XGBoost | Máxima performance em tabulares, competições | Muitos hiperparâmetros, treino mais lento |
| LightGBM | Datasets grandes (>100k), velocidade | Pode overfitar em datasets pequenos |
| SVM | Texto com TF-IDF, datasets pequenos/médios | Lento em datasets grandes, escala é obrigatória |

---

> Antes de deep learning, domine esses modelos.  
> Eles resolvem a maioria dos problemas reais com custo de treino, explicabilidade e manutenção bem menores.
