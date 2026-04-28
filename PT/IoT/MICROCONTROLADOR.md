# Firmware ESP32 — MicroPython na Prática

> Firmware completo: leitura de sensores reais, Wi-Fi com reconexão, MQTT com TLS, watchdog, OTA e deep sleep.

---

## Índice

1. [Checklist de firmware robusto](#1-checklist-de-firmware-robusto)
2. [Wi-Fi com reconexão automática](#2-wi-fi-com-reconexão-automática)
3. [Sincronização NTP](#3-sincronização-ntp)
4. [Leitura de sensores reais](#4-leitura-de-sensores-reais)
5. [MQTT com TLS e reconexão com backoff](#5-mqtt-com-tls-e-reconexão-com-backoff)
6. [Formato de tópico e payload](#6-formato-de-tópico-e-payload)
7. [Receber comandos do servidor](#7-receber-comandos-do-servidor)
8. [Watchdog timer](#8-watchdog-timer)
9. [Deep sleep para economia de energia](#9-deep-sleep-para-economia-de-energia)
10. [Armazenar credenciais com segurança](#10-armazenar-credenciais-com-segurança)
11. [Firmware completo integrado](#11-firmware-completo-integrado)
12. [Boas práticas e checklist final](#12-boas-práticas-e-checklist-final)

---

## 1. Checklist de firmware robusto

```
[ ] Wi-Fi com reconexão automática e timeout
[ ] NTP para timestamps corretos (obrigatório para TLS e auditoria)
[ ] MQTT com TLS e autenticação
[ ] Reconexão MQTT com exponential backoff
[ ] Leitura de sensor com tratamento de erro
[ ] Payload JSON com device_id + timestamp + schema_version
[ ] Watchdog timer para reinício automático em travamento
[ ] Last will para sinalizar offline
[ ] Credenciais em NVS (não hardcoded no código)
[ ] OTA para atualização sem acesso físico
```

---

## 2. Wi-Fi com reconexão automática

```python
# wifi.py
import network
import time

def conectar_wifi(ssid: str, senha: str, timeout_s: int = 20) -> bool:
    """
    Conecta ao Wi-Fi e aguarda até timeout_s segundos.
    Retorna True se conectou, False se falhou.
    """
    wlan = network.WLAN(network.STA_IF)
    wlan.active(True)

    if wlan.isconnected():
        print(f"[WiFi] Já conectado: {wlan.ifconfig()[0]}")
        return True

    print(f"[WiFi] Conectando em {ssid}...")
    wlan.connect(ssid, senha)

    inicio = time.time()
    while not wlan.isconnected():
        if time.time() - inicio > timeout_s:
            print("[WiFi] Timeout — falha ao conectar")
            return False
        time.sleep(0.5)
        print(".", end="")

    ip, mascara, gateway, dns = wlan.ifconfig()
    print(f"\n[WiFi] Conectado! IP={ip} | Gateway={gateway}")
    return True


def garantir_wifi(ssid: str, senha: str) -> None:
    """
    Garante conexão Wi-Fi — tenta indefinidamente com espera crescente.
    Chame antes de qualquer operação de rede.
    """
    tentativa = 0
    while not conectar_wifi(ssid, senha):
        tentativa += 1
        espera = min(30, 5 * tentativa)  # máximo 30s entre tentativas
        print(f"[WiFi] Tentativa {tentativa} falhou. Aguardando {espera}s...")
        time.sleep(espera)
```

---

## 3. Sincronização NTP

```python
# ntp_sync.py
import ntptime
import time

def sincronizar_ntp(servidor: str = "pool.ntp.org", fuso_horario: int = -3) -> bool:
    """
    Sincroniza o relógio interno do ESP32 com servidor NTP.
    fuso_horario: offset em horas em relação ao UTC (ex: -3 para BRT)
    """
    try:
        ntptime.host = servidor
        ntptime.settime()   # ajusta o RTC interno (UTC)
        print(f"[NTP] Horário sincronizado: {formatar_hora()}")
        return True
    except Exception as e:
        print(f"[NTP] Falha: {e}")
        return False


def timestamp_unix() -> int:
    """Retorna Unix timestamp atual (segundos desde 1970-01-01)."""
    # MicroPython conta desde 2000-01-01 — ajustar epoch
    EPOCH_OFFSET = 946684800  # segundos entre 1970 e 2000
    return time.time() + EPOCH_OFFSET


def formatar_hora() -> str:
    t = time.localtime()
    return f"{t[0]}-{t[1]:02d}-{t[2]:02d} {t[3]:02d}:{t[4]:02d}:{t[5]:02d}"
```

---

## 4. Leitura de sensores reais

### DHT22 — temperatura e umidade

```python
# sensor_dht.py
import dht
from machine import Pin

class SensorDHT22:
    def __init__(self, pino: int = 4):
        self._sensor = dht.DHT22(Pin(pino))

    def ler(self) -> dict | None:
        """
        Retorna dict com temperatura e umidade, ou None em caso de erro.
        DHT22: temperatura -40..80°C, umidade 0..100%RH
        """
        try:
            self._sensor.measure()
            temp = self._sensor.temperature()
            umid = self._sensor.humidity()

            # Validação de range físico
            if not (-40 <= temp <= 85):
                print(f"[DHT22] Temperatura fora do range: {temp}")
                return None
            if not (0 <= umid <= 100):
                print(f"[DHT22] Umidade fora do range: {umid}")
                return None

            return {"temperatura": round(temp, 1), "umidade": round(umid, 1)}

        except Exception as e:
            print(f"[DHT22] Erro na leitura: {e}")
            return None
```

### DS18B20 — temperatura via OneWire (ótimo para líquidos)

```python
# sensor_ds18b20.py
import onewire
import ds18x20
from machine import Pin
import time

class SensorDS18B20:
    def __init__(self, pino: int = 5):
        ow = onewire.OneWire(Pin(pino))
        self._sensor = ds18x20.DS18X20(ow)
        self._roms = self._sensor.scan()
        print(f"[DS18B20] Encontrados {len(self._roms)} sensores")

    def ler(self) -> list[dict]:
        """Retorna lista de leituras — suporta múltiplos sensores no mesmo pino."""
        if not self._roms:
            return []

        self._sensor.convert_temp()
        time.sleep_ms(750)  # conversão leva até 750ms

        leituras = []
        for rom in self._roms:
            try:
                temp = self._sensor.read_temp(rom)
                if -55 <= temp <= 125:  # range válido do DS18B20
                    leituras.append({
                        "sensor_id": "".join(f"{b:02x}" for b in rom),
                        "temperatura": round(temp, 2),
                    })
            except Exception as e:
                print(f"[DS18B20] Erro no sensor {rom}: {e}")

        return leituras
```

### Sensor analógico — tensão, corrente, luz (ADC)

```python
# sensor_analogico.py
from machine import ADC, Pin

class SensorAnalogico:
    def __init__(self, pino: int = 34, amostras: int = 10):
        """
        pino: GPIO com ADC (ESP32: 32-39 são seguros para ADC)
        amostras: média de leituras para reduzir ruído
        """
        self._adc = ADC(Pin(pino))
        self._adc.atten(ADC.ATTN_11DB)   # range: 0-3.3V
        self._adc.width(ADC.WIDTH_12BIT)  # resolução 12 bits (0-4095)
        self._amostras = amostras

    def ler_raw(self) -> int:
        """Média de N leituras brutas (0-4095)."""
        soma = sum(self._adc.read() for _ in range(self._amostras))
        return soma // self._amostras

    def ler_tensao(self) -> float:
        """Converte leitura para tensão em Volts."""
        return round(self.ler_raw() * 3.3 / 4095, 3)

    def ler_porcentagem(self, vmin: float = 0.0, vmax: float = 3.3) -> float:
        """Converte tensão para porcentagem (ex: nível de bateria, luminosidade)."""
        tensao = self.ler_tensao()
        pct = (tensao - vmin) / (vmax - vmin) * 100
        return round(max(0, min(100, pct)), 1)


# Exemplo: ler nível de bateria LiPo (divisor de tensão 4.2V → 3.3V)
class BateriaLiPo:
    """
    Circuito: bateria → R1(100k) → GPIO34 → R2(100k) → GND
    Divisor de tensão: V_gpio = V_bat / 2
    """
    def __init__(self, pino: int = 34):
        self._adc = SensorAnalogico(pino)

    def ler_tensao(self) -> float:
        """Tensão real da bateria (2× a leitura do ADC)."""
        return round(self._adc.ler_tensao() * 2, 2)

    def ler_porcentagem(self) -> float:
        """Porcentagem de carga aproximada de bateria LiPo (3.3V–4.2V)."""
        tensao = self.ler_tensao()
        pct = (tensao - 3.3) / (4.2 - 3.3) * 100
        return round(max(0, min(100, pct)), 1)
```

---

## 5. MQTT com TLS e reconexão com backoff

```python
# mqtt_client.py
import json
import time
from umqtt.simple import MQTTClient

class ClienteMQTT:
    def __init__(
        self,
        broker: str,
        porta: int,
        client_id: str,
        usuario: str,
        senha: str,
        ca_cert_path: str = "/certs/ca.crt",
        qos: int = 1,
    ):
        self._broker = broker
        self._porta = porta
        self._client_id = client_id
        self._usuario = usuario
        self._senha = senha
        self._ca_cert_path = ca_cert_path
        self._qos = qos
        self._client = None
        self._callback_mensagem = None

    def _criar_client(self) -> MQTTClient:
        # Ler certificado CA para TLS
        with open(self._ca_cert_path, "r") as f:
            ca_cert = f.read()

        return MQTTClient(
            client_id=self._client_id,
            server=self._broker,
            port=self._porta,
            user=self._usuario,
            password=self._senha,
            ssl=True,
            ssl_params={"cert": ca_cert, "server_side": False},
            keepalive=60,
        )

    def conectar(self, last_will_topic: bytes = None) -> bool:
        """Conecta ao broker com configuração de last will."""
        try:
            self._client = self._criar_client()

            if last_will_topic:
                self._client.set_last_will(
                    topic=last_will_topic,
                    msg=b'{"status":"offline"}',
                    retain=True,
                    qos=1,
                )

            if self._callback_mensagem:
                self._client.set_callback(self._callback_mensagem)

            self._client.connect()
            print(f"[MQTT] Conectado em {self._broker}:{self._porta}")
            return True

        except Exception as e:
            print(f"[MQTT] Falha na conexão: {e}")
            return False

    def conectar_com_retry(self, last_will_topic: bytes = None, max_tentativas: int = 0) -> None:
        """
        Tenta conectar com exponential backoff.
        max_tentativas=0 → tenta indefinidamente.
        """
        tentativa = 0
        while True:
            if self.conectar(last_will_topic):
                return

            tentativa += 1
            if max_tentativas > 0 and tentativa >= max_tentativas:
                raise RuntimeError(f"[MQTT] Falhou após {tentativa} tentativas")

            # Exponential backoff: 2s, 4s, 8s, ... máximo 60s
            espera = min(60, 2 ** tentativa)
            print(f"[MQTT] Tentativa {tentativa}. Próxima em {espera}s...")
            time.sleep(espera)

    def publicar(self, topico: str, payload: dict) -> bool:
        """Publica payload JSON no tópico. Retorna False se falhar."""
        if not self._client:
            return False
        try:
            self._client.publish(
                topico.encode(),
                json.dumps(payload).encode(),
                qos=self._qos,
                retain=False,
            )
            return True
        except Exception as e:
            print(f"[MQTT] Erro ao publicar: {e}")
            self._client = None  # força reconexão no próximo ciclo
            return False

    def assinar(self, topico: str) -> None:
        if self._client:
            self._client.subscribe(topico.encode(), qos=self._qos)

    def verificar_mensagens(self) -> None:
        """Processar mensagens recebidas (non-blocking)."""
        if self._client:
            self._client.check_msg()

    def on_mensagem(self, callback) -> None:
        """Registrar callback para mensagens recebidas."""
        self._callback_mensagem = callback

    @property
    def conectado(self) -> bool:
        return self._client is not None
```

---

## 6. Formato de tópico e payload

```python
# payload.py

def montar_payload(
    device_id: str,
    dados_sensores: dict,
    schema_version: int = 1,
) -> dict:
    """
    Formato padronizado de payload IoT.
    schema_version permite evoluir o formato sem quebrar consumidores antigos.
    """
    from ntp_sync import timestamp_unix

    return {
        "device_id": device_id,
        "timestamp": timestamp_unix(),
        "schema_version": schema_version,
        "dados": dados_sensores,
    }


# Exemplos de payloads:

# Telemetria normal
{
    "device_id": "esp32-01",
    "timestamp": 1704067200,
    "schema_version": 1,
    "dados": {
        "temperatura": 24.6,
        "umidade": 58.2,
        "bateria_pct": 87.0,
        "bateria_v": 3.95,
    }
}

# Alerta
{
    "device_id": "esp32-01",
    "timestamp": 1704067500,
    "schema_version": 1,
    "tipo": "alerta",
    "dados": {
        "codigo": "TEMP_ALTA",
        "valor": 75.3,
        "limite": 70.0,
    }
}
```

```python
# Estrutura de tópicos recomendada
TOPICOS = {
    "telemetria": "fabrica/{site}/{linha}/{device_id}/telemetria",
    "alerta":     "fabrica/{site}/{linha}/{device_id}/alerta",
    "status":     "fabrica/{site}/{linha}/{device_id}/status",
    "comando":    "fabrica/{site}/{linha}/{device_id}/comando",  # servidor → device
}

def topico(tipo: str, site: str, linha: str, device_id: str) -> str:
    return TOPICOS[tipo].format(site=site, linha=linha, device_id=device_id)
```

---

## 7. Receber comandos do servidor

```python
# O servidor pode publicar em fabrica/linha1/esp32-01/comando
# O ESP32 assina e responde

import json

def processar_comando(topic: bytes, msg: bytes) -> None:
    """
    Callback chamado quando chega mensagem em tópico assinado.
    """
    topico_str = topic.decode()

    if "comando" not in topico_str:
        return

    try:
        comando = json.loads(msg.decode())
        print(f"[CMD] Recebido: {comando}")

        acao = comando.get("acao")

        if acao == "reiniciar":
            print("[CMD] Reiniciando em 3s...")
            import time; time.sleep(3)
            import machine; machine.reset()

        elif acao == "definir_intervalo":
            novo_intervalo = int(comando.get("valor", 10))
            # Atualizar variável global de intervalo
            print(f"[CMD] Novo intervalo: {novo_intervalo}s")

        elif acao == "led":
            estado = comando.get("estado", "off")
            from machine import Pin
            led = Pin(2, Pin.OUT)
            led.value(1 if estado == "on" else 0)
            print(f"[CMD] LED: {estado}")

        else:
            print(f"[CMD] Ação desconhecida: {acao}")

    except Exception as e:
        print(f"[CMD] Erro ao processar comando: {e}")
```

---

## 8. Watchdog timer

```python
# watchdog.py
from machine import WDT

class Watchdog:
    """
    Watchdog reinicia o ESP32 se não for alimentado dentro do timeout.
    Garante que o dispositivo se recupera de travamentos silenciosos.
    """

    def __init__(self, timeout_ms: int = 30000):
        """
        timeout_ms: tempo em ms antes do reset automático.
        Valores típicos: 8000ms (mínimo) a 60000ms.
        """
        self._wdt = WDT(timeout=timeout_ms)
        print(f"[WDT] Watchdog ativado: timeout={timeout_ms}ms")

    def alimentar(self) -> None:
        """
        Chamar periodicamente para evitar reset.
        Se não for chamado dentro do timeout → ESP32 reinicia.
        """
        self._wdt.feed()


# Uso no loop principal:
#
# wdt = Watchdog(timeout_ms=30000)
# while True:
#     wdt.alimentar()   # DEVE chamar em cada ciclo
#     fazer_coisas()
#     time.sleep(10)
```

---

## 9. Deep sleep para economia de energia

```python
# deep_sleep.py
import machine
import time

def ciclo_com_deep_sleep(
    intervalo_s: int,
    funcao_trabalho,
    pino_wakeup: int = None,
) -> None:
    """
    Executa funcao_trabalho, depois coloca ESP32 em deep sleep.
    Ideal para dispositivos a bateria que enviam dados a cada N minutos.

    Deep sleep:
    - Reduz consumo de ~240mA (ativo) para ~10µA
    - A CPU reinicia do zero após wakeup
    - Variáveis em RAM são perdidas — use RTC memory ou NVS para persistir
    """
    print(f"[SLEEP] Executando trabalho...")
    try:
        funcao_trabalho()
    except Exception as e:
        print(f"[SLEEP] Erro no trabalho: {e}")

    print(f"[SLEEP] Dormindo por {intervalo_s}s...")
    machine.deepsleep(intervalo_s * 1000)  # em milissegundos


def salvar_em_rtc_memory(dados: dict) -> None:
    """
    Salva dados em RTC memory — persiste durante deep sleep.
    Útil para manter contadores, timestamps ou estado entre ciclos.
    """
    import json
    rtc = machine.RTC()
    dados_bytes = json.dumps(dados).encode()
    rtc.memory(dados_bytes)


def ler_rtc_memory() -> dict:
    """Recupera dados salvos em RTC memory."""
    import json
    rtc = machine.RTC()
    dados_bytes = rtc.memory()
    if not dados_bytes:
        return {}
    try:
        return json.loads(dados_bytes.decode())
    except:
        return {}


# Exemplo de uso — sensor a bateria enviando a cada 5 minutos
def trabalho():
    from wifi import garantir_wifi
    from ntp_sync import sincronizar_ntp, timestamp_unix
    from sensor_dht import SensorDHT22

    garantir_wifi("MinhaRede", "SenhaWifi")
    sincronizar_ntp()

    sensor = SensorDHT22(pino=4)
    dados = sensor.ler()
    if dados:
        # publicar MQTT aqui
        print(f"Publicado: {dados}")

    # Contar ciclos em RTC memory
    estado = ler_rtc_memory()
    estado["ciclos"] = estado.get("ciclos", 0) + 1
    salvar_em_rtc_memory(estado)

# ciclo_com_deep_sleep(intervalo_s=300, funcao_trabalho=trabalho)
```

---

## 10. Armazenar credenciais com segurança

```python
# config.py — nunca hardcode credentials no firmware
import json

CONFIG_FILE = "/config.json"

def carregar_config() -> dict:
    """
    Carrega configurações do arquivo JSON na flash do ESP32.
    Nunca coloque credenciais reais no código-fonte versionado.
    """
    try:
        with open(CONFIG_FILE, "r") as f:
            return json.load(f)
    except OSError:
        print(f"[CONFIG] Arquivo {CONFIG_FILE} não encontrado")
        return {}


def salvar_config(config: dict) -> None:
    """Salva configurações na flash."""
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f)
    print("[CONFIG] Configurações salvas")


# Exemplo de config.json (copiar para o ESP32 via ampy/mpremote — nunca versionar)
CONFIG_EXEMPLO = {
    "wifi_ssid": "MinhaRede",
    "wifi_senha": "SenhaWifi",
    "mqtt_broker": "iot.seudominio.com",
    "mqtt_porta": 8883,
    "mqtt_user": "device_esp32_01",
    "mqtt_senha": "SenhaDispositivo",
    "device_id": "esp32-01",
    "site": "sp",
    "linha": "linha1",
    "intervalo_s": 30,
}

# Carregar na inicialização:
# cfg = carregar_config()
# if not cfg:
#     salvar_config(CONFIG_EXEMPLO)  # primeira vez
#     cfg = CONFIG_EXEMPLO
```

```bash
# Copiar config.json para o ESP32 (sem versionar no Git)
# Usando mpremote:
mpremote cp config.json :config.json

# Usando ampy:
ampy --port /dev/ttyUSB0 put config.json /config.json

# Adicionar ao .gitignore:
echo "config.json" >> .gitignore
echo "certs/" >> .gitignore
```

---

## 11. Firmware completo integrado

```python
# main.py — firmware principal
import time
import json

from config import carregar_config
from wifi import garantir_wifi
from ntp_sync import sincronizar_ntp, timestamp_unix
from sensor_dht import SensorDHT22
from sensor_analogico import BateriaLiPo
from mqtt_client import ClienteMQTT
from watchdog import Watchdog

# ---- Configuração ----
cfg = carregar_config()

DEVICE_ID  = cfg.get("device_id", "esp32-01")
SITE       = cfg.get("site", "sp")
LINHA      = cfg.get("linha", "linha1")
INTERVALO  = cfg.get("intervalo_s", 30)

TOPICO_TEL    = f"fabrica/{SITE}/{LINHA}/{DEVICE_ID}/telemetria".encode()
TOPICO_STATUS = f"fabrica/{SITE}/{LINHA}/{DEVICE_ID}/status".encode()
TOPICO_CMD    = f"fabrica/{SITE}/{LINHA}/{DEVICE_ID}/comando".encode()

# ---- Instâncias ----
sensor_dht = SensorDHT22(pino=4)
bateria    = BateriaLiPo(pino=34)
wdt        = Watchdog(timeout_ms=60000)

mqtt = ClienteMQTT(
    broker=cfg["mqtt_broker"],
    porta=cfg["mqtt_porta"],
    client_id=DEVICE_ID,
    usuario=cfg["mqtt_user"],
    senha=cfg["mqtt_senha"],
)

# ---- Callback de comandos ----
def on_mensagem(topic, msg):
    from processar_comando import processar_comando
    processar_comando(topic, msg)

mqtt.on_mensagem(on_mensagem)


def publicar_status(status: str) -> None:
    mqtt.publicar(TOPICO_STATUS.decode(), {
        "device_id": DEVICE_ID,
        "status": status,
        "timestamp": timestamp_unix(),
    })


def ciclo_telemetria() -> None:
    """Um ciclo completo de leitura e publicação."""

    # 1. Ler sensores
    dados_dht = sensor_dht.ler()
    if not dados_dht:
        print("[MAIN] Falha na leitura do sensor — pulando ciclo")
        return

    bat_pct = bateria.ler_porcentagem()
    bat_v   = bateria.ler_tensao()

    # 2. Montar payload
    payload = {
        "device_id": DEVICE_ID,
        "timestamp": timestamp_unix(),
        "schema_version": 1,
        "dados": {
            "temperatura": dados_dht["temperatura"],
            "umidade":     dados_dht["umidade"],
            "bateria_pct": bat_pct,
            "bateria_v":   bat_v,
        },
    }

    # 3. Publicar
    ok = mqtt.publicar(TOPICO_TEL.decode(), payload)
    if ok:
        print(f"[MAIN] Publicado: T={dados_dht['temperatura']}°C | "
              f"U={dados_dht['umidade']}% | Bat={bat_pct}%")
    else:
        print("[MAIN] Falha ao publicar — reconectando MQTT...")
        mqtt.conectar_com_retry(last_will_topic=TOPICO_STATUS)
        mqtt.assinar(TOPICO_CMD.decode())
        publicar_status("online")


# ---- Inicialização ----
print(f"[MAIN] Iniciando device_id={DEVICE_ID}")

# 1. Conectar Wi-Fi
garantir_wifi(cfg["wifi_ssid"], cfg["wifi_senha"])

# 2. Sincronizar horário
sincronizar_ntp()

# 3. Conectar MQTT
mqtt.conectar_com_retry(last_will_topic=TOPICO_STATUS)
mqtt.assinar(TOPICO_CMD.decode())
publicar_status("online")

print(f"[MAIN] Pronto! Enviando a cada {INTERVALO}s")

# ---- Loop principal ----
ultimo_envio = 0

while True:
    wdt.alimentar()  # nunca esquecer — senão reinicia

    agora = time.time()

    if agora - ultimo_envio >= INTERVALO:
        ciclo_telemetria()
        ultimo_envio = agora

    # Verificar mensagens de comando (non-blocking)
    mqtt.verificar_mensagens()

    time.sleep(1)
```

---

## 12. Boas práticas e checklist final

```
Segurança:
  [ ] Credenciais em config.json na flash (nunca hardcoded no .py)
  [ ] config.json no .gitignore
  [ ] TLS ativado com ca.crt embarcado
  [ ] Device ID único por equipamento

Robustez:
  [ ] Watchdog ativo com timeout de 30–60s
  [ ] Reconexão Wi-Fi automática com timeout
  [ ] Reconnect MQTT com exponential backoff
  [ ] Leitura de sensor com tratamento de None
  [ ] Last will configurado para status offline

Dados:
  [ ] Timestamp Unix em todo payload
  [ ] schema_version em todo payload
  [ ] device_id em todo payload
  [ ] Payload <= 256 bytes quando possível (memória limitada)

Energia (se a bateria):
  [ ] Deep sleep entre ciclos
  [ ] Bateria monitorada no payload
  [ ] Intervalo maior em bateria baixa
```

---

> O firmware deve ser previsível: publicar dados válidos, reconectar sozinho e falhar de forma segura sem travar.
