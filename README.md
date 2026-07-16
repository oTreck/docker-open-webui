# Lokaler RAG- und AI-Workspace

Dieses Projekt stellt eine lokale AI- und RAG-Umgebung mit Docker Compose bereit. Die Umgebung kombiniert Open WebUI, Ollama, PostgreSQL mit pgvector, Open WebUI Pipelines, einen eigenen Ingester und ComfyUI.

## Enthaltene Dienste

| Dienst | Container | Aufgabe | Standard-Port |
|---|---|---|---:|
| Open WebUI | `rag-open-webui` | Weboberfläche für lokale LLMs, Pipelines und Bildgenerierung | `8080` |
| Ollama | `rag-ollama` | Lokale Ausführung von Sprach- und Embedding-Modellen | `11434` |
| PostgreSQL/pgvector | `rag-postgres` | Speicherung von Dokumenten, Metadaten und Vektoren | `5432` |
| Pipelines | `rag-pipelines` | OpenAI-kompatible Pipeline-Schnittstelle für Open WebUI | `9099` |
| Ingester | `rag-ingester` | Import und Verarbeitung von Dateien aus dem Workspace | – |
| ComfyUI | `rag-comfyui` | Lokale Bildgenerierung über die Nvidia-GPU | `8188` |

## Voraussetzungen

Auf dem Server müssen folgende Komponenten installiert sein:

- Docker Engine
- Docker Compose Plugin
- Nvidia-Grafikkartentreiber
- Nvidia Container Toolkit
- Eine von Docker erreichbare Nvidia-GPU
- Ausreichend freier Speicherplatz für Modelle, Datenbanken und generierte Bilder

GPU-Zugriff testen:

```bash
nvidia-smi
```

Docker-GPU-Unterstützung testen:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi
```

## Verzeichnisstruktur

Empfohlene Projektstruktur:

```text
.
├── compose.yml
├── .env
├── Dockerfile.open-webui-rag
├── start.sh
├── data
│   ├── comfyui
│   ├── open-webui
│   └── postgres
├── docker
│   ├── ingester
│   │   └── app
│   ├── pipelines
│   └── postgres
│       └── init.sql
└── workspace
```

### Persistente Daten

Die folgenden Daten bleiben nach dem Austausch eines Containers erhalten:

```text
./data/comfyui
./data/open-webui
./data/postgres
./workspace
```

Die Ollama-Modelle werden im benannten Docker-Volume `ollama` gespeichert.

## Umgebungsvariablen

Erstelle im Projektverzeichnis eine `.env`-Datei:

```env
POSTGRES_DB=workspace_order
POSTGRES_USER=workspace_user
POSTGRES_PASSWORD=CHANGE_ME

OPENWEBUI_PORT=8080
OLLAMA_PORT=11434
PIPELINES_PORT=9099
POSTGRES_PORT=5432
COMFYUI_PORT=8188
```

Die `.env`-Datei darf nicht in Git eingecheckt werden:

```bash
echo ".env" >> .gitignore
chmod 600 .env
```

Für produktive oder gemeinsam verwendete Installationen sollten sichere, zufällige Passwörter verwendet werden.

Beispiel:

```bash
openssl rand -hex 32
```

## Docker-Compose-Konfiguration

Die Umgebung wird über Docker Compose gestartet. Die Compose-Datei enthält folgende Dienste:

```yaml
services:
  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest-cuda
    container_name: rag-comfyui
    restart: unless-stopped
    ports:
      - "${COMFYUI_PORT}:8188"
    volumes:
      - ./data/comfyui:/workspace
    environment:
      WEB_ENABLE_AUTH: "false"
      COMFYUI_ARGS: "--listen 0.0.0.0 --port 8188"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  postgres:
    image: pgvector/pgvector:pg17
    container_name: rag-postgres
    restart: unless-stopped
    env_file:
      - .env
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./docker/postgres/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    healthcheck:
      test:
        - CMD-SHELL
        - pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}
      interval: 10s
      timeout: 5s
      retries: 10

  ollama:
    image: ollama/ollama:latest
    container_name: rag-ollama
    restart: unless-stopped
    ports:
      - "${OLLAMA_PORT}:11434"
    volumes:
      - ollama:/root/.ollama
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  pipelines:
    image: ghcr.io/open-webui/pipelines:main
    container_name: rag-pipelines
    restart: unless-stopped
    ports:
      - "${PIPELINES_PORT}:9099"
    volumes:
      - ./docker/pipelines:/app/pipelines
    environment:
      PIPELINES_DIR: /app/pipelines
      PIPELINES_REQUIREMENTS_PATH: /app/pipelines/requirements.txt
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      OLLAMA_BASE_URL: http://ollama:11434
      EMBEDDING_MODEL: nomic-embed-text
      CHAT_MODEL: qwen2.5-coder:7b

  ingester:
    build:
      context: ./docker/ingester
    container_name: rag-ingester
    restart: unless-stopped
    depends_on:
      - postgres
      - ollama
    env_file:
      - .env
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PORT: 5432
      OLLAMA_BASE_URL: http://ollama:11434
      EMBEDDING_MODEL: nomic-embed-text
    volumes:
      - ./docker/ingester/app:/app
      - ./workspace:/workspace
    working_dir: /app
    command:
      - sleep
      - infinity

  open-webui:
    build:
      context: .
      dockerfile: Dockerfile.open-webui-rag
    container_name: rag-open-webui
    restart: unless-stopped
    depends_on:
      - ollama
      - pipelines
      - comfyui
    ports:
      - "${OPENWEBUI_PORT}:8080"
    volumes:
      - ./data/open-webui:/app/backend/data
      - ./workspace:/workspace
    environment:
      OLLAMA_BASE_URL: http://ollama:11434
      OPENAI_API_BASE_URL: http://pipelines:9099
      WEBUI_URL: http://localhost:${OPENWEBUI_PORT}

      ENABLE_IMAGE_GENERATION: "true"
      IMAGE_GENERATION_ENGINE: comfyui
      COMFYUI_BASE_URL: http://comfyui:8188
      IMAGE_SIZE: 1024x1024

volumes:
  ollama:
```

## Eigener Open-WebUI-Build

Open WebUI wird in diesem Projekt nicht direkt aus einem offiziellen Open-WebUI-Image gestartet. Der Service verwendet einen eigenen Build:

```yaml
build:
  context: .
  dockerfile: Dockerfile.open-webui-rag
```

Aktuelle Dockerfile:

```dockerfile
FROM nvidia/cuda:10.2-runtime-ubuntu18.04

WORKDIR /app

COPY ./ /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libglfw3 \
        libsdl2-dev \
    && rm -rf /var/lib/apt/lists/*

CMD ["bash", "start.sh"]
```

### Wichtiger Hinweis

Diese Dockerfile basiert auf Ubuntu 18.04 und CUDA 10.2. Beide Komponenten sind für einen aktuellen Open-WebUI-Betrieb sehr alt. Außerdem enthält die Dockerfile selbst keine Open-WebUI-Version.

Die tatsächlich gestartete Open-WebUI-Version hängt daher davon ab, welche Dateien durch

```dockerfile
COPY ./ /app
```

in das Image kopiert werden und was die Datei `start.sh` ausführt.

Vor einem Update sollte deshalb geprüft werden:

```bash
cat start.sh
```

Zusätzlich sollte ermittelt werden, aus welcher Quelle der Open-WebUI-Code stammt:

```bash
find . -maxdepth 2 -type f \( -name "package.json" -o -name "pyproject.toml" -o -name "requirements.txt" \)
```

Für eine langfristig wartbare Installation ist ein offizielles Open-WebUI-Image mit einem festen Versionstag in der Regel einfacher als ein eigener CUDA-10.2-Build.

## Konfiguration prüfen

Vor dem ersten Start:

```bash
docker compose config
```

Dieser Befehl prüft die Compose-Datei und löst die Variablen aus `.env` auf.

Achtung: Die Ausgabe kann Passwörter und andere sensible Werte enthalten.

## Umgebung starten

Alle Images herunterladen und eigene Images bauen:

```bash
docker compose pull
docker compose build
```

Alle Dienste im Hintergrund starten:

```bash
docker compose up -d
```

Status prüfen:

```bash
docker compose ps
```

Logs aller Dienste anzeigen:

```bash
docker compose logs --tail=100
```

Logs fortlaufend verfolgen:

```bash
docker compose logs -f
```

## Weboberflächen

Nach erfolgreichem Start sind die Dienste standardmäßig über folgende Adressen erreichbar:

```text
Open WebUI: http://localhost:8080
ComfyUI:    http://localhost:8188
Ollama API: http://localhost:11434
Pipelines:  http://localhost:9099
PostgreSQL: localhost:5432
```

Bei einem Zugriff von einem anderen Computer muss `localhost` durch die IP-Adresse oder den Hostnamen des Servers ersetzt werden.

Beispiel:

```text
http://192.168.1.100:8080
```

## Ollama-Modelle installieren

Verfügbare Modelle anzeigen:

```bash
docker exec -it rag-ollama ollama list
```

Chat-Modell installieren:

```bash
docker exec -it rag-ollama ollama pull qwen2.5-coder:7b
```

Embedding-Modell installieren:

```bash
docker exec -it rag-ollama ollama pull nomic-embed-text
```

Modell testen:

```bash
docker exec -it rag-ollama ollama run qwen2.5-coder:7b
```

## Ingester verwenden

Der Ingester läuft dauerhaft mit:

```text
sleep infinity
```

Dadurch kann er manuell betreten werden:

```bash
docker exec -it rag-ingester bash
```

Der Quellcode befindet sich im Container unter:

```text
/app
```

Der gemeinsame Workspace befindet sich unter:

```text
/workspace
```

Ein Python-Skript kann beispielsweise so ausgeführt werden:

```bash
docker exec -it rag-ingester python /app/ingest.py
```

Der konkrete Befehl hängt von den im Ingester vorhandenen Skripten ab.

## ComfyUI

ComfyUI ist über Open WebUI und direkt über Port `8188` erreichbar.

Direkter Aufruf:

```text
http://localhost:8188
```

Open WebUI verwendet intern:

```text
http://comfyui:8188
```

Da `WEB_ENABLE_AUTH` auf `false` steht, besitzt ComfyUI in dieser Konfiguration keine eigene Anmeldung. Port `8188` sollte daher nicht ungeschützt aus dem Internet erreichbar sein.

## Einzelne Dienste neu starten

Open WebUI:

```bash
docker compose restart open-webui
```

Ollama:

```bash
docker compose restart ollama
```

Pipelines:

```bash
docker compose restart pipelines
```

ComfyUI:

```bash
docker compose restart comfyui
```

## Einzelne Dienste neu bauen

Open WebUI neu bauen:

```bash
docker compose build --no-cache open-webui
docker compose up -d open-webui
```

Ingester neu bauen:

```bash
docker compose build --no-cache ingester
docker compose up -d ingester
```

## Updates

Vor Updates sollte immer ein Backup angelegt werden.

Images aktualisieren:

```bash
docker compose pull
```

Eigene Images neu bauen:

```bash
docker compose build --pull
```

Container mit den neuen Images neu erstellen:

```bash
docker compose up -d
```

Nicht mehr verwendete Images anzeigen:

```bash
docker image prune
```

Nicht ohne Prüfung verwenden:

```bash
docker compose down -v
```

Die Option `-v` löscht benannte Docker-Volumes. Dadurch könnten unter anderem die im `ollama`-Volume gespeicherten Modelle verloren gehen.

## Backups

Backup-Verzeichnis anlegen:

```bash
mkdir -p backups
```

### Open WebUI sichern

```bash
sudo tar -czf \
  "backups/open-webui-$(date +%Y-%m-%d-%H%M%S).tar.gz" \
  ./data/open-webui
```

### PostgreSQL sichern

Datenbank als SQL-Datei exportieren:

```bash
docker exec rag-postgres pg_dump \
  -U "${POSTGRES_USER}" \
  -d "${POSTGRES_DB}" \
  > "backups/postgres-$(date +%Y-%m-%d-%H%M%S).sql"
```

Da die Shell-Variablen aus `.env` nicht automatisch in jeder Shell verfügbar sind, können die Werte alternativ direkt angegeben werden:

```bash
docker exec rag-postgres pg_dump \
  -U workspace_user \
  -d workspace_order \
  > "backups/postgres-$(date +%Y-%m-%d-%H%M%S).sql"
```

### Workspace sichern

```bash
sudo tar -czf \
  "backups/workspace-$(date +%Y-%m-%d-%H%M%S).tar.gz" \
  ./workspace
```

### ComfyUI sichern

```bash
sudo tar -czf \
  "backups/comfyui-$(date +%Y-%m-%d-%H%M%S).tar.gz" \
  ./data/comfyui
```

## Wiederherstellung

Open-WebUI-Daten wiederherstellen:

```bash
docker compose stop open-webui

sudo tar -xzf backups/open-webui-DATUM.tar.gz -C .

docker compose up -d open-webui
```

PostgreSQL-Dump wiederherstellen:

```bash
cat backups/postgres-DATUM.sql | docker exec -i rag-postgres psql \
  -U workspace_user \
  -d workspace_order
```

Wiederherstellungen sollten regelmäßig in einer Testumgebung geprüft werden.

## Fehleranalyse

### Containerstatus

```bash
docker compose ps
```

### Open-WebUI-Logs

```bash
docker compose logs --tail=200 open-webui
```

### Ollama-Logs

```bash
docker compose logs --tail=200 ollama
```

### Pipelines-Logs

```bash
docker compose logs --tail=200 pipelines
```

### PostgreSQL-Logs

```bash
docker compose logs --tail=200 postgres
```

### ComfyUI-Logs

```bash
docker compose logs --tail=200 comfyui
```

### GPU im Ollama-Container prüfen

```bash
docker exec -it rag-ollama nvidia-smi
```

### GPU im ComfyUI-Container prüfen

```bash
docker exec -it rag-comfyui nvidia-smi
```

### Netzwerkverbindung zu Ollama testen

```bash
docker exec -it rag-open-webui curl http://ollama:11434/api/tags
```

### Netzwerkverbindung zu ComfyUI testen

```bash
docker exec -it rag-open-webui curl http://comfyui:8188
```

### PostgreSQL-Verbindung prüfen

```bash
docker exec -it rag-postgres pg_isready \
  -U workspace_user \
  -d workspace_order
```

## Sicherheitshinweise

- `.env` niemals in Git speichern.
- Starke Datenbankpasswörter verwenden.
- ComfyUI nicht ungeschützt ins Internet freigeben.
- PostgreSQL-Port `5432` nicht öffentlich freigeben.
- Ollama-Port `11434` nicht öffentlich freigeben.
- Open WebUI hinter HTTPS und einem Reverse Proxy betreiben.
- Regelmäßige Backups erstellen.
- Restore-Tests durchführen.
- Docker-Images nicht ausschließlich über `latest` oder `main` betreiben, wenn eine reproduzierbare Produktionsumgebung benötigt wird.
- Sicherheitsupdates für Hostsystem, Docker und Nvidia-Treiber regelmäßig installieren.

## Nützliche Docker-Befehle

Alle Container stoppen:

```bash
docker compose stop
```

Alle Container stoppen und entfernen:

```bash
docker compose down
```

Alle Dienste neu starten:

```bash
docker compose restart
```

Ressourcennutzung anzeigen:

```bash
docker stats
```

Speicherverbrauch von Docker anzeigen:

```bash
docker system df
```

Nicht mehr verwendete Images löschen:

```bash
docker image prune
```

## Lizenz und Verantwortung

Dieses Projekt kombiniert mehrere externe Open-Source-Komponenten. Für jede Komponente gelten deren eigene Lizenz-, Sicherheits- und Nutzungsbedingungen.

Vor einem produktiven Einsatz sollten insbesondere Datenschutz, Zugriffsschutz, Backup-Strategie und Modelllizenzen geprüft werden.