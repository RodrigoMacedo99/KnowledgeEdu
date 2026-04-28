# Séries Temporais para Machine Learning

> Como prever dados ao longo do tempo sem quebrar causalidade — do ARIMA ao XGBoost com features temporais.

---

## Índice

1. [Conceitos fundamentais](#1-conceitos-fundamentais)
2. [Exploração e decomposição](#2-exploração-e-decomposição)
3. [Estacionariedade e transformações](#3-estacionariedade-e-transformações)
4. [Split temporal correto](#4-split-temporal-correto)
5. [Features temporais](#5-features-temporais)
6. [ARIMA e SARIMA](#6-arima-e-sarima)
7. [Prophet — forecasting prático](#7-prophet--forecasting-prático)
8. [XGBoost com features temporais](#8-xgboost-com-features-temporais)
9. [Validação walk-forward](#9-validação-walk-forward)
10. [Métricas de forecast](#10-métricas-de-forecast)
11. [Do clássico ao avançado](#11-do-clássico-ao-avançado)

---

## 1. Conceitos fundamentais

Toda série temporal pode ser decomposta em:

```
y_t = T_t + S_t + R_t

T = tendência (crescimento/queda ao longo do tempo)
S = sazonalidade (padrão que se repete — diário, semanal, anual)
R = resíduo (ruído aleatório não explicado)
```

**Exemplos reais:**
- Venda de sorvete: tendência de crescimento + sazonalidade no verão + ruído diário
- Preço de ação: tendência + volatilidade (sem sazonalidade clara)
- Demanda de call center: sazonalidade semanal + sazonalidade diária

---

## 2. Exploração e decomposição

```python
import pandas as pd
import numpy as np
from statsmodels.tsa.seasonal import seasonal_decompose

# Criar série temporal de exemplo (vendas diárias)
np.random.seed(42)
datas = pd.date_range("2022-01-01", periods=365, freq="D")
tendencia = np.linspace(100, 200, 365)
sazonalidade = 20 * np.sin(2 * np.pi * np.arange(365) / 7)  # ciclo semanal
ruido = np.random.normal(0, 5, 365)

serie = pd.Series(tendencia + sazonalidade + ruido, index=datas, name="vendas")

print(serie.describe())
print(f"\nPrimeiros 5 valores:\n{serie.head()}")

# Decomposição aditiva
decomp = seasonal_decompose(serie, model="additive", period=7)

print(f"\nTendência (média): {decomp.trend.dropna().mean():.2f}")
print(f"Sazonalidade (amplitude): {decomp.seasonal.max() - decomp.seasonal.min():.2f}")
print(f"Resíduo (desvio padrão): {decomp.resid.dropna().std():.2f}")
```

```python
# Análise de autocorrelação — encontra padrões recorrentes
from statsmodels.graphics.tsaplots import plot_acf, plot_pacf
from statsmodels.stats.stattools import durbin_watson

# ACF: autocorrelação com todos os lags
# PACF: autocorrelação parcial (controla lags intermediários)

# Em vez de plotar (ambiente sem display), verificar numericamente
from statsmodels.tsa.stattools import acf, pacf

acf_values = acf(serie, nlags=14)
pacf_values = pacf(serie, nlags=14)

print("Autocorrelação nos lags 1-7:")
for lag, val in enumerate(acf_values[1:8], start=1):
    print(f"  Lag {lag}: {val:.3f}")
```

---

## 3. Estacionariedade e transformações

Muitos modelos (ARIMA, regressão com lags) assumem série estacionária — média e variância constantes no tempo.

```python
from statsmodels.tsa.stattools import adfuller, kpss

def testar_estacionariedade(serie: pd.Series, nome: str = "") -> None:
    # ADF: H0 = tem raiz unitária (não-estacionária)
    # p < 0.05 → estacionária
    adf_stat, adf_p, *_ = adfuller(serie.dropna())

    # KPSS: H0 = estacionária
    # p > 0.05 → estacionária
    kpss_stat, kpss_p, *_ = kpss(serie.dropna(), regression="c")

    print(f"\n=== {nome or 'Série'} ===")
    print(f"ADF  | stat={adf_stat:.4f} | p={adf_p:.4f} | {'Estacionária ✓' if adf_p < 0.05 else 'NÃO estacionária ✗'}")
    print(f"KPSS | stat={kpss_stat:.4f} | p={kpss_p:.4f} | {'Estacionária ✓' if kpss_p > 0.05 else 'NÃO estacionária ✗'}")


# Testar série original
testar_estacionariedade(serie, "Original")

# Diferenciação — transforma em estacionária
serie_diff = serie.diff().dropna()
testar_estacionariedade(serie_diff, "Diferenciada (d=1)")

# Log-transform — estabiliza variância (bom quando variação cresce com a escala)
serie_log = np.log1p(serie)
testar_estacionariedade(serie_log, "Log-transform")
```

---

## 4. Split temporal correto

**Regra crítica:** nunca use `train_test_split` com `shuffle=True` em série temporal.  
O modelo nunca pode "ver o futuro" durante o treino.

```python
def temporal_split(
    df: pd.DataFrame,
    target_col: str,
    train_ratio: float = 0.8,
) -> tuple:
    """
    Split preservando ordem temporal.
    Treino = passado | Teste = futuro
    """
    corte = int(len(df) * train_ratio)
    treino = df.iloc[:corte]
    teste  = df.iloc[corte:]

    X_train = treino.drop(columns=[target_col])
    y_train = treino[target_col]
    X_test  = teste.drop(columns=[target_col])
    y_test  = teste[target_col]

    print(f"Treino: {treino.index[0].date()} → {treino.index[-1].date()} ({len(treino)} obs)")
    print(f"Teste:  {teste.index[0].date()} → {teste.index[-1].date()} ({len(teste)} obs)")

    return X_train, X_test, y_train, y_test
```

---

## 5. Features temporais

Features que enriquecem o modelo com padrões de tempo e histórico.

```python
def criar_features_temporais(df: pd.DataFrame, alvo: str) -> pd.DataFrame:
    """
    Cria features de lags, médias móveis e calendário.
    O índice do DataFrame deve ser DatetimeIndex.
    """
    out = df.copy()

    # --- Lags ---
    for lag in [1, 2, 3, 7, 14, 21, 28]:
        out[f"lag_{lag}"] = out[alvo].shift(lag)

    # --- Médias móveis ---
    for janela in [7, 14, 28]:
        out[f"rolling_mean_{janela}"] = out[alvo].shift(1).rolling(janela).mean()
        out[f"rolling_std_{janela}"]  = out[alvo].shift(1).rolling(janela).std()
        out[f"rolling_max_{janela}"]  = out[alvo].shift(1).rolling(janela).max()

    # --- Features de calendário ---
    out["dia_semana"]  = out.index.dayofweek          # 0=segunda ... 6=domingo
    out["mes"]         = out.index.month
    out["trimestre"]   = out.index.quarter
    out["dia_mes"]     = out.index.day
    out["dia_ano"]     = out.index.dayofyear
    out["semana_ano"]  = out.index.isocalendar().week.astype(int)
    out["eh_fim_semana"] = (out.index.dayofweek >= 5).astype(int)
    out["eh_inicio_mes"] = (out.index.day <= 5).astype(int)

    # --- Codificação cíclica (preserva continuidade: dezembro próximo de janeiro) ---
    out["mes_sin"] = np.sin(2 * np.pi * out["mes"] / 12)
    out["mes_cos"] = np.cos(2 * np.pi * out["mes"] / 12)
    out["dia_semana_sin"] = np.sin(2 * np.pi * out["dia_semana"] / 7)
    out["dia_semana_cos"] = np.cos(2 * np.pi * out["dia_semana"] / 7)

    return out.dropna()


# Montar DataFrame com a série
df_ts = serie.to_frame()
df_features = criar_features_temporais(df_ts, "vendas")

print(f"Shape com features: {df_features.shape}")
print(df_features.head(3))
```

---

## 6. ARIMA e SARIMA

Modelos estatísticos clássicos — bons para séries univariadas com estrutura clara.

```
ARIMA(p, d, q):
  p = ordem autoregressiva (quantos lags passados usar)
  d = grau de diferenciação (quantas vezes diferenciar para estacionar)
  q = ordem da média móvel (quantos resíduos passados usar)

SARIMA(p, d, q)(P, D, Q, m):
  Adiciona componentes sazonais com período m
```

```python
from statsmodels.tsa.statespace.sarimax import SARIMAX
import warnings
warnings.filterwarnings("ignore")

# Dados — usar apenas a série sem features extras para ARIMA
y_train = serie.iloc[:300]
y_test  = serie.iloc[300:]

# Treinar SARIMA com sazonalidade semanal (m=7)
model = SARIMAX(
    y_train,
    order=(1, 1, 1),           # p, d, q
    seasonal_order=(1, 1, 1, 7),  # P, D, Q, m
    enforce_stationarity=False,
    enforce_invertibility=False,
)
resultado = model.fit(disp=False)

print(resultado.summary().tables[1])

# Previsão
forecast = resultado.forecast(steps=len(y_test))

from sklearn.metrics import mean_absolute_error, mean_squared_error
mae  = mean_absolute_error(y_test, forecast)
rmse = np.sqrt(mean_squared_error(y_test, forecast))
mape = np.mean(np.abs((y_test.values - forecast.values) / (y_test.values + 1e-10))) * 100

print(f"\nMAE:  {mae:.2f}")
print(f"RMSE: {rmse:.2f}")
print(f"MAPE: {mape:.2f}%")
```

### Auto-ARIMA — selecionar parâmetros automaticamente

```python
# pip install pmdarima
from pmdarima import auto_arima

auto_model = auto_arima(
    y_train,
    seasonal=True,
    m=7,           # período sazonal
    stepwise=True,
    suppress_warnings=True,
    information_criterion="aic",
    trace=True,    # mostra os modelos testados
)

print(f"\nMelhor modelo: {auto_model.order} | sazonal: {auto_model.seasonal_order}")
print(f"AIC: {auto_model.aic():.2f}")
```

---

## 7. Prophet — forecasting prático

Prophet lida automaticamente com tendência, sazonalidade e feriados.

```python
from prophet import Prophet
import pandas as pd

# Prophet exige colunas 'ds' (data) e 'y' (valor)
df_prophet = pd.DataFrame({
    "ds": serie.index,
    "y":  serie.values,
})

train_prophet = df_prophet.iloc[:300]
test_prophet  = df_prophet.iloc[300:]

model_prophet = Prophet(
    seasonality_mode="additive",  # ou "multiplicative" se variância cresce com nível
    weekly_seasonality=True,
    yearly_seasonality=False,
    daily_seasonality=False,
    changepoint_prior_scale=0.05,  # controla flexibilidade da tendência (maior = mais flexível)
)

# Adicionar sazonalidade customizada
model_prophet.add_seasonality(name="mensal", period=30.5, fourier_order=5)

model_prophet.fit(train_prophet)

# Prever
futuro = model_prophet.make_future_dataframe(periods=len(test_prophet))
previsao = model_prophet.predict(futuro)

# Avaliar na janela de teste
prev_test = previsao.iloc[300:][["ds", "yhat", "yhat_lower", "yhat_upper"]]
mae_prophet = mean_absolute_error(test_prophet["y"].values, prev_test["yhat"].values)
print(f"Prophet MAE: {mae_prophet:.2f}")

# Componentes da previsão (tendência + sazonalidades)
print(previsao[["ds", "trend", "weekly", "yhat"]].tail(10))
```

---

## 8. XGBoost com features temporais

Muitas vezes supera ARIMA/Prophet ao combinar lags + features de calendário.

```python
import lightgbm as lgb
from sklearn.metrics import mean_absolute_error

# Usar o DataFrame com features temporais criado na seção 5
X_train, X_test, y_train, y_test = temporal_split(df_features, "vendas")

model_lgbm = lgb.LGBMRegressor(
    n_estimators=500,
    num_leaves=31,
    learning_rate=0.05,
    min_child_samples=10,
    subsample=0.8,
    colsample_bytree=0.8,
    random_state=42,
    verbose=-1,
)

callbacks = [lgb.early_stopping(50, verbose=False), lgb.log_evaluation(100)]

model_lgbm.fit(
    X_train, y_train,
    eval_set=[(X_test, y_test)],
    callbacks=callbacks,
)

y_pred_lgbm = model_lgbm.predict(X_test)
mae_lgbm = mean_absolute_error(y_test, y_pred_lgbm)
print(f"LightGBM MAE: {mae_lgbm:.2f}")

# Feature importance — entender o que o modelo aprendeu
fi = pd.Series(
    model_lgbm.feature_importances_,
    index=X_train.columns,
).sort_values(ascending=False)

print("\nTop 10 features mais importantes:")
print(fi.head(10))
```

---

## 9. Validação walk-forward

Simula como o modelo seria usado em produção — treina no passado, testa no próximo período, avança.

```python
from sklearn.metrics import mean_absolute_error

def walk_forward_validation(
    df: pd.DataFrame,
    target_col: str,
    model,
    n_splits: int = 5,
    horizonte: int = 30,  # dias a prever por fold
) -> list[float]:
    """
    Validação walk-forward: cada fold usa mais dados históricos.
    Mais realista que K-Fold para séries temporais.
    """
    n = len(df)
    tamanho_inicial = n - n_splits * horizonte

    maes = []

    for i in range(n_splits):
        inicio_teste = tamanho_inicial + i * horizonte
        fim_teste    = inicio_teste + horizonte

        treino = df.iloc[:inicio_teste]
        teste  = df.iloc[inicio_teste:fim_teste]

        X_tr = treino.drop(columns=[target_col])
        y_tr = treino[target_col]
        X_te = teste.drop(columns=[target_col])
        y_te = teste[target_col]

        model.fit(X_tr, y_tr)
        pred = model.predict(X_te)

        mae = mean_absolute_error(y_te, pred)
        maes.append(mae)

        print(f"Fold {i+1}: treino até {treino.index[-1].date()} | "
              f"teste {teste.index[0].date()}–{teste.index[-1].date()} | MAE={mae:.2f}")

    print(f"\nMAE médio walk-forward: {np.mean(maes):.2f} ± {np.std(maes):.2f}")
    return maes


maes = walk_forward_validation(
    df_features, "vendas",
    model=lgb.LGBMRegressor(n_estimators=200, verbose=-1),
    n_splits=5,
    horizonte=14,
)
```

---

## 10. Métricas de forecast

```python
import numpy as np
from sklearn.metrics import mean_absolute_error, mean_squared_error

def calcular_metricas_forecast(y_true: np.ndarray, y_pred: np.ndarray) -> dict:
    mae  = mean_absolute_error(y_true, y_pred)
    rmse = np.sqrt(mean_squared_error(y_true, y_pred))

    # MAPE — percentual médio de erro (evitar quando y_true tem zeros)
    mask = y_true != 0
    mape = np.mean(np.abs((y_true[mask] - y_pred[mask]) / y_true[mask])) * 100

    # SMAPE — simétrico, menos sensível a valores pequenos
    smape = np.mean(
        2 * np.abs(y_pred - y_true) / (np.abs(y_true) + np.abs(y_pred) + 1e-10)
    ) * 100

    # Naive baseline — prever o valor anterior (benchmark mínimo)
    y_naive = np.roll(y_true, 1)[1:]
    mae_naive = mean_absolute_error(y_true[1:], y_naive)

    # MASE — MAE do modelo relativo ao baseline naive (< 1 = bom)
    mase = mae / (mae_naive + 1e-10)

    return {"MAE": mae, "RMSE": rmse, "MAPE%": mape, "SMAPE%": smape, "MASE": mase}


metricas = calcular_metricas_forecast(y_test.values, y_pred_lgbm)
for k, v in metricas.items():
    print(f"{k}: {v:.4f}")

print("\nInterpretação:")
print("  MASE < 1.0 → modelo é melhor que predição naive (bom mínimo)")
print("  MAPE < 10% → boa performance em geral")
print("  MAPE cuidado: quando y_true ≈ 0, fica instável")
```

---

## 11. Do clássico ao avançado

| Nível | Modelo | Quando usar |
|---|---|---|
| Básico | ARIMA/SARIMA | Série univariada, poucas features externas |
| Prático | Prophet | Séries com feriados, múltiplas sazonalidades, fácil de usar |
| Avançado | LightGBM + lags | Múltiplas séries, muitas features externas, alta performance |
| Avançado | XGBoost + lags | Similar ao LGBM — testar ambos |
| Deep | LSTM / GRU | Séries com dependências longas (>100 lags) |
| Fundacional | TimesFM, Chronos, Moirai | Zero-shot forecasting sem treino específico |

### Dica de produção

```python
# Comparar sempre com baseline naive antes de celebrar um bom MAE
def baseline_naive(y_true: np.ndarray) -> float:
    """Previsão = valor do dia anterior."""
    return mean_absolute_error(y_true[1:], y_true[:-1])

print(f"MAE baseline naive:    {baseline_naive(y_test.values):.2f}")
print(f"MAE LightGBM:          {mae_lgbm:.2f}")
print(f"Melhoria sobre naive:  {(1 - mae_lgbm/baseline_naive(y_test.values)):.1%}")
```

---

> Em séries temporais, o maior erro é validar errado.  
> Respeitar a linha do tempo já coloca você à frente de 80% das implementações.
