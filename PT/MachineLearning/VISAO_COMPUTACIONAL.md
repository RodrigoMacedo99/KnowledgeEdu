# Visão Computacional para Desenvolvedores

> Pipeline completo: do dado bruto ao modelo em produção, com CNN do zero e transfer learning real.

---

## Índice

1. [Pipeline completo de CV](#1-pipeline-completo-de-cv)
2. [Preparar dataset com DataLoader](#2-preparar-dataset-com-dataloader)
3. [Augmentação de dados](#3-augmentação-de-dados)
4. [CNN do zero](#4-cnn-do-zero)
5. [Transfer learning com ResNet / EfficientNet](#5-transfer-learning-com-resnet--efficientnet)
6. [Loop de treino completo](#6-loop-de-treino-completo)
7. [Avaliação com matriz de confusão](#7-avaliação-com-matriz-de-confusão)
8. [Fine-tuning — descongelar camadas](#8-fine-tuning--descongelar-camadas)
9. [Inferência e exportação](#9-inferência-e-exportação)
10. [Avançado — detecção e segmentação](#10-avançado--detecção-e-segmentação)

---

## 1. Pipeline completo de CV

```
1. Coletar e rotular imagens
2. Dividir em treino / validação / teste
3. Pré-processar (resize, normalizar)
4. Augmentação no treino (não no teste)
5. Escolher arquitetura (CNN do zero ou transfer learning)
6. Treinar com early stopping
7. Avaliar com métricas por classe
8. Inspecionar erros (falsos positivos/negativos)
9. Exportar para produção (TorchScript / ONNX)
```

**Regra geral:** qualidade de rotulagem impacta mais resultado que a escolha de arquitetura.

---

## 2. Preparar dataset com DataLoader

```python
import torch
from torch.utils.data import Dataset, DataLoader
from torchvision import transforms
from pathlib import Path
from PIL import Image

class ImageDataset(Dataset):
    """
    Estrutura esperada de diretório:
      data/
        train/
          gato/
            img001.jpg
          cachorro/
            img002.jpg
        val/
          gato/
          cachorro/
    """

    def __init__(self, root_dir: str, transform=None):
        self.root = Path(root_dir)
        self.transform = transform

        # Descobrir classes automaticamente pelos subdiretórios
        self.classes = sorted([d.name for d in self.root.iterdir() if d.is_dir()])
        self.class_to_idx = {c: i for i, c in enumerate(self.classes)}

        # Listar todos os arquivos com rótulos
        self.samples: list[tuple[Path, int]] = []
        for classe in self.classes:
            for img_path in (self.root / classe).glob("*.jpg"):
                self.samples.append((img_path, self.class_to_idx[classe]))

        print(f"Dataset {root_dir}: {len(self.samples)} imagens | classes: {self.classes}")

    def __len__(self) -> int:
        return len(self.samples)

    def __getitem__(self, idx: int) -> tuple:
        img_path, label = self.samples[idx]
        img = Image.open(img_path).convert("RGB")
        if self.transform:
            img = self.transform(img)
        return img, label


# Estatísticas de normalização do ImageNet (usar com modelos pré-treinados)
IMAGENET_MEAN = [0.485, 0.456, 0.406]
IMAGENET_STD  = [0.229, 0.224, 0.225]
```

---

## 3. Augmentação de dados

```python
import torchvision.transforms as T

# Treino — augmentação para regularização
transform_treino = T.Compose([
    T.Resize((256, 256)),
    T.RandomCrop(224),                         # crop aleatório
    T.RandomHorizontalFlip(p=0.5),             # espelhar horizontalmente
    T.RandomVerticalFlip(p=0.1),               # espelhar vertical (para algumas tarefas)
    T.RandomRotation(degrees=15),              # rotação até 15°
    T.ColorJitter(brightness=0.3, contrast=0.3, saturation=0.3, hue=0.1),
    T.RandomGrayscale(p=0.05),
    T.ToTensor(),
    T.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
])

# Validação/Teste — sem augmentação (deve ser determinístico)
transform_val = T.Compose([
    T.Resize((256, 256)),
    T.CenterCrop(224),   # crop central — consistente
    T.ToTensor(),
    T.Normalize(mean=IMAGENET_MEAN, std=IMAGENET_STD),
])


def criar_dataloaders(data_dir: str, batch_size: int = 32) -> tuple:
    train_ds = ImageDataset(f"{data_dir}/train", transform=transform_treino)
    val_ds   = ImageDataset(f"{data_dir}/val",   transform=transform_val)

    train_loader = DataLoader(
        train_ds,
        batch_size=batch_size,
        shuffle=True,           # embaralhar somente no treino
        num_workers=4,          # paralelismo de carregamento
        pin_memory=True,        # acelera transferência para GPU
    )
    val_loader = DataLoader(
        val_ds,
        batch_size=batch_size,
        shuffle=False,          # não embaralhar na avaliação
        num_workers=4,
        pin_memory=True,
    )

    return train_loader, val_loader, train_ds.classes
```

---

## 4. CNN do zero

```python
import torch
import torch.nn as nn
import torch.nn.functional as F

class SimpleCNN(nn.Module):
    """
    CNN simples para classificação.
    Boa para entender convoluções, mas use transfer learning em produção.
    """

    def __init__(self, n_classes: int = 2, in_channels: int = 3):
        super().__init__()

        # Bloco de extração de features
        self.features = nn.Sequential(
            # Bloco 1: 3 → 32 canais, 224×224 → 112×112
            nn.Conv2d(in_channels, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),   # normaliza ativações → treino mais estável
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            # Bloco 2: 32 → 64 canais, 112×112 → 56×56
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),

            # Bloco 3: 64 → 128 canais, 56×56 → 28×28
            nn.Conv2d(64, 128, kernel_size=3, padding=1),
            nn.BatchNorm2d(128),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
        )

        # Classificador
        self.classifier = nn.Sequential(
            nn.AdaptiveAvgPool2d((1, 1)),  # reduz para 128×1×1 independente do input size
            nn.Flatten(),
            nn.Linear(128, 256),
            nn.ReLU(inplace=True),
            nn.Dropout(p=0.5),             # regularização — importante em CNNs
            nn.Linear(256, n_classes),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        x = self.features(x)
        return self.classifier(x)


# Verificar tamanho das saídas
model = SimpleCNN(n_classes=3)
dummy = torch.randn(4, 3, 224, 224)  # batch=4, RGB, 224×224
output = model(dummy)
print(f"Input:  {dummy.shape}")
print(f"Output: {output.shape}")   # [4, 3]
print(f"Parâmetros: {sum(p.numel() for p in model.parameters()):,}")
```

---

## 5. Transfer learning com ResNet / EfficientNet

```python
import torchvision.models as models
import torch.nn as nn

def criar_modelo(arquitetura: str, n_classes: int, congelar_base: bool = True):
    """
    Cria modelo com transfer learning.

    congelar_base=True  → treina só a última camada (mais rápido, menos dados)
    congelar_base=False → fine-tuning completo (mais dados, melhor resultado)
    """
    if arquitetura == "resnet18":
        model = models.resnet18(weights=models.ResNet18_Weights.DEFAULT)
        in_features = model.fc.in_features
        model.fc = nn.Sequential(
            nn.Dropout(p=0.3),
            nn.Linear(in_features, n_classes),
        )

    elif arquitetura == "resnet50":
        model = models.resnet50(weights=models.ResNet50_Weights.DEFAULT)
        in_features = model.fc.in_features
        model.fc = nn.Sequential(
            nn.Dropout(p=0.3),
            nn.Linear(in_features, n_classes),
        )

    elif arquitetura == "efficientnet_b0":
        model = models.efficientnet_b0(weights=models.EfficientNet_B0_Weights.DEFAULT)
        in_features = model.classifier[1].in_features
        model.classifier = nn.Sequential(
            nn.Dropout(p=0.2),
            nn.Linear(in_features, n_classes),
        )

    else:
        raise ValueError(f"Arquitetura desconhecida: {arquitetura}")

    # Congelar todos os parâmetros exceto a última camada
    if congelar_base:
        for name, param in model.named_parameters():
            if "fc" not in name and "classifier" not in name:
                param.requires_grad = False

    params_treinaveis = sum(p.numel() for p in model.parameters() if p.requires_grad)
    params_totais     = sum(p.numel() for p in model.parameters())
    print(f"Parâmetros treináveis: {params_treinaveis:,} / {params_totais:,}")

    return model


# Criar modelo
modelo = criar_modelo("resnet18", n_classes=3, congelar_base=True)
```

---

## 6. Loop de treino completo

```python
import torch
import torch.optim as optim
from torch.optim.lr_scheduler import CosineAnnealingLR

def treinar(
    model: nn.Module,
    train_loader: DataLoader,
    val_loader: DataLoader,
    n_classes: int,
    epochs: int = 20,
    lr: float = 1e-3,
    device: str = "auto",
) -> dict:
    if device == "auto":
        device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Treinando em: {device}")

    model = model.to(device)

    # Pesos de classe para dados desbalanceados
    # class_weights = torch.tensor([1.0, 2.5, 1.5]).to(device)  # ajustar por classe
    criterio = nn.CrossEntropyLoss()

    otimizador = optim.AdamW(
        filter(lambda p: p.requires_grad, model.parameters()),
        lr=lr,
        weight_decay=1e-4,  # regularização L2
    )

    # Scheduler: reduz lr ao longo do treino
    scheduler = CosineAnnealingLR(otimizador, T_max=epochs)

    historico = {"treino_loss": [], "treino_acc": [], "val_loss": [], "val_acc": []}
    melhor_val_acc = 0.0
    melhor_pesos = None

    for epoch in range(1, epochs + 1):
        # ---- TREINO ----
        model.train()
        total_loss, total_corretos, total = 0.0, 0, 0

        for imgs, labels in train_loader:
            imgs, labels = imgs.to(device), labels.to(device)

            otimizador.zero_grad()
            saidas = model(imgs)
            loss = criterio(saidas, labels)
            loss.backward()
            otimizador.step()

            total_loss += loss.item() * imgs.size(0)
            preds = saidas.argmax(dim=1)
            total_corretos += (preds == labels).sum().item()
            total += imgs.size(0)

        treino_loss = total_loss / total
        treino_acc  = total_corretos / total

        # ---- VALIDAÇÃO ----
        model.eval()
        val_loss, val_corretos, val_total = 0.0, 0, 0

        with torch.no_grad():
            for imgs, labels in val_loader:
                imgs, labels = imgs.to(device), labels.to(device)
                saidas = model(imgs)
                loss = criterio(saidas, labels)

                val_loss += loss.item() * imgs.size(0)
                preds = saidas.argmax(dim=1)
                val_corretos += (preds == labels).sum().item()
                val_total += imgs.size(0)

        val_loss /= val_total
        val_acc   = val_corretos / val_total

        scheduler.step()

        historico["treino_loss"].append(treino_loss)
        historico["treino_acc"].append(treino_acc)
        historico["val_loss"].append(val_loss)
        historico["val_acc"].append(val_acc)

        print(f"Época {epoch:3d}/{epochs} | "
              f"treino loss={treino_loss:.4f} acc={treino_acc:.2%} | "
              f"val loss={val_loss:.4f} acc={val_acc:.2%}")

        # Salvar melhor modelo
        if val_acc > melhor_val_acc:
            melhor_val_acc = val_acc
            melhor_pesos = {k: v.clone() for k, v in model.state_dict().items()}
            print(f"  ↑ Novo melhor modelo: {melhor_val_acc:.2%}")

    # Restaurar melhor modelo
    model.load_state_dict(melhor_pesos)
    print(f"\nMelhor val acc: {melhor_val_acc:.2%}")
    return historico


# Uso (com dataloaders reais)
# train_loader, val_loader, classes = criar_dataloaders("data/")
# modelo = criar_modelo("resnet18", n_classes=len(classes))
# historico = treinar(modelo, train_loader, val_loader, n_classes=len(classes))
```

---

## 7. Avaliação com matriz de confusão

```python
import numpy as np
from sklearn.metrics import (
    classification_report, confusion_matrix,
    accuracy_score, f1_score,
)

def avaliar_modelo(model, loader, classes, device="cpu"):
    model.eval()
    todos_preds, todos_labels, todas_probas = [], [], []

    with torch.no_grad():
        for imgs, labels in loader:
            imgs = imgs.to(device)
            saidas = model(imgs)
            probas = torch.softmax(saidas, dim=1).cpu().numpy()
            preds = saidas.argmax(dim=1).cpu().numpy()

            todos_preds.extend(preds)
            todos_labels.extend(labels.numpy())
            todas_probas.extend(probas)

    todos_preds  = np.array(todos_preds)
    todos_labels = np.array(todos_labels)

    print(f"Accuracy: {accuracy_score(todos_labels, todos_preds):.2%}")
    print(f"F1 Macro: {f1_score(todos_labels, todos_preds, average='macro'):.4f}")
    print()
    print(classification_report(todos_labels, todos_preds, target_names=classes))

    cm = confusion_matrix(todos_labels, todos_preds)
    print("Matriz de confusão:")
    print(f"Classes: {classes}")
    print(cm)

    # Encontrar os casos mais errados — útil para análise de erro
    erros = np.where(todos_preds != todos_labels)[0]
    print(f"\nTotal de erros: {len(erros)}")

    return {"preds": todos_preds, "labels": todos_labels, "probas": np.array(todas_probas)}


# Uso
# resultados = avaliar_modelo(modelo, val_loader, classes)
```

---

## 8. Fine-tuning — descongelar camadas

```python
def descongelar_para_fine_tuning(model, arquitetura: str, n_camadas_descongelar: int = 2):
    """
    Estratégia gradual:
    1. Primeiro treino: somente última camada (lr alta)
    2. Fine-tuning: descongelar últimas camadas (lr menor)
    """
    if arquitetura.startswith("resnet"):
        # ResNet tem layer1, layer2, layer3, layer4, fc
        camadas = ["layer4", "layer3", "layer2", "layer1"]
        for camada in camadas[:n_camadas_descongelar]:
            for param in getattr(model, camada).parameters():
                param.requires_grad = True

    elif arquitetura == "efficientnet_b0":
        # Descongelar últimos blocos
        todos_blocos = list(model.features.children())
        for bloco in todos_blocos[-n_camadas_descongelar:]:
            for param in bloco.parameters():
                param.requires_grad = True

    params_treinaveis = sum(p.numel() for p in model.parameters() if p.requires_grad)
    print(f"Parâmetros treináveis após descongelar: {params_treinaveis:,}")
    return model


# Fluxo típico de fine-tuning
# Passo 1: treinar somente head (épocas rápidas)
# modelo = criar_modelo("resnet18", n_classes=3, congelar_base=True)
# treinar(modelo, train_loader, val_loader, epochs=5, lr=1e-3)

# Passo 2: fine-tuning das últimas camadas (lr menor)
# modelo = descongelar_para_fine_tuning(modelo, "resnet18", n_camadas_descongelar=2)
# treinar(modelo, train_loader, val_loader, epochs=10, lr=1e-4)
```

---

## 9. Inferência e exportação

```python
import torch

def inferir(model, imagem_path: str, classes: list, device: str = "cpu") -> dict:
    """Inferência em produção para uma imagem."""
    from PIL import Image

    model.eval()
    img = Image.open(imagem_path).convert("RGB")
    tensor = transform_val(img).unsqueeze(0).to(device)  # adiciona dimensão batch

    with torch.no_grad():
        saida = model(tensor)
        probas = torch.softmax(saida, dim=1)[0]

    resultado = {
        "classe": classes[probas.argmax().item()],
        "confianca": probas.max().item(),
        "probabilidades": {c: probas[i].item() for i, c in enumerate(classes)},
    }
    return resultado


# Exportar para TorchScript (sem dependência de Python em produção)
def exportar_torchscript(model, caminho: str, device: str = "cpu"):
    model.eval()
    dummy = torch.randn(1, 3, 224, 224).to(device)
    traced = torch.jit.trace(model, dummy)
    traced.save(caminho)
    print(f"Modelo salvo em {caminho}")


# Carregar e usar
# modelo_ts = torch.jit.load("modelo.pt")


# Exportar para ONNX (interoperável com outras linguagens)
def exportar_onnx(model, caminho: str, n_classes: int):
    dummy = torch.randn(1, 3, 224, 224)
    torch.onnx.export(
        model, dummy, caminho,
        export_params=True,
        input_names=["image"],
        output_names=["logits"],
        dynamic_axes={"image": {0: "batch_size"}, "logits": {0: "batch_size"}},
        opset_version=17,
    )
    print(f"Modelo ONNX exportado: {caminho}")
```

---

## 10. Avançado — detecção e segmentação

### Detecção com YOLOv8 (ultra-fast)

```python
# pip install ultralytics
from ultralytics import YOLO

# Usar modelo pré-treinado
model_yolo = YOLO("yolov8n.pt")  # n=nano, s=small, m=medium, l=large, x=extra

# Detecção em imagem
results = model_yolo("foto.jpg")
for r in results:
    boxes  = r.boxes.xyxy.numpy()   # coordenadas [x1, y1, x2, y2]
    confs  = r.boxes.conf.numpy()   # confiança
    labels = r.boxes.cls.numpy()    # classe
    for box, conf, label in zip(boxes, confs, labels):
        print(f"Classe: {model_yolo.names[int(label)]} | Confiança: {conf:.2%} | Caixa: {box}")

# Fine-tuning em dados próprios
# model_yolo.train(data="dataset.yaml", epochs=50, imgsz=640)
```

### Segmentação semântica com torchvision

```python
from torchvision.models.segmentation import deeplabv3_resnet50, DeepLabV3_ResNet50_Weights

seg_model = deeplabv3_resnet50(weights=DeepLabV3_ResNet50_Weights.DEFAULT)
seg_model.eval()

img_tensor = transform_val(Image.open("foto.jpg")).unsqueeze(0)

with torch.no_grad():
    output = seg_model(img_tensor)["out"]
    mascara = output.argmax(dim=1).squeeze().numpy()

print(f"Máscara de segmentação shape: {mascara.shape}")
print(f"Classes encontradas: {np.unique(mascara)}")
```

---

> Em visão computacional, a qualidade dos dados e da rotulagem geralmente impacta mais que trocar arquitetura.  
> Use transfer learning desde o início — treinar do zero só faz sentido com datasets grandes (>100k imagens).
