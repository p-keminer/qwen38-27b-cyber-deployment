<a id="top"></a>

<div align="center">

[![Deutsch](https://img.shields.io/badge/🇩🇪_Deutsch-24292f?style=for-the-badge)](#deutsch)
[![English](https://img.shields.io/badge/🇬🇧_English-24292f?style=for-the-badge)](#english)

</div>

---

<a id="deutsch"></a>

<div align="center">

`LOCAL LLM` · `RUNPOD` · `CYBER EVALUATION`

# Qwen3.8-27B RunPod Agent

Reproduzierbares A100-Deployment, lokale Modellsicherung, isolierte
Chat-Oberfläche und Cybench-Evaluationswerkzeuge für `Qwen3.8-27B`.

`A100 80 GB` · `Q6_K` · `llama.cpp` · `OpenCode` · `Inspect AI` · `Cybench`

[`Übersicht`](#de-uebersicht) [`Ablauf`](#de-ablauf) [`Einstieg`](#de-einstieg)
[`Skripte`](#de-skripte) [`Lokale Daten`](#de-lokale-daten) [`Lizenz`](#de-lizenz)

</div>

---

<a id="de-uebersicht"></a>

## Übersicht

Das Repository stellt standardmäßig das gepinnte Profil `uncensored-q6` auf
einer `NVIDIA A100 80 GB PCIe` bei RunPod bereit. Der Modellserver läuft auf dem
Pod; ein SSH-Tunnel öffnet die isolierte OpenCode-Oberfläche ausschließlich
unter `http://127.0.0.1:4096`.

| Bereich | Kanonische Quelle |
|---|---|
| Einrichtung und Betrieb | [QUICKSTART.md](QUICKSTART.md#deutsch) |
| Modellvarianten, Revisionen und SHA-256-Werte | [config/models.json](config/models.json) |
| Hardware-, Kosten- und Deploymentvertrag | [config/runpod-a100-pcie-deployment.json](config/runpod-a100-pcie-deployment.json) |
| Projektlizenz | [Apache-2.0](LICENSE) |

<a id="de-ablauf"></a>

## Ablauf

```text
PowerShell-Steuerung -> RunPod API -> A100-Pod -> llama.cpp / Qwen3.8-27B
Lokale OpenCode-GUI <- SSH-Tunnel <- isolierte Agent-Umgebung
Cybench / Inspect AI -> freigegebener Modellendpunkt -> Ergebnisartefakte
```

Ohne `-Execute` erzeugt die Provisionierung nur einen lokalen, prüfbaren
Deploymentplan. Cloud-Ressourcen werden erst mit expliziter Ausführung
erstellt.

<a id="de-einstieg"></a>

## Einstieg

1. Voraussetzungen und lokale Einrichtung in
   [QUICKSTART.md](QUICKSTART.md#deutsch) abschließen.
2. Deploymentplan erzeugen und dessen SHA-256-Wert übernehmen.
3. Den Pod bewusst mit `-Execute` bereitstellen.
4. Tunnel und Oberfläche mit `runpod-connect.ps1` starten.
5. Lokale Prozesse beenden und anschließend den Pod im RunPod-Dashboard
   stoppen oder terminieren.

<a id="de-skripte"></a>

## Wichtige Skripte

| Befehl | Funktion | Ergebnis |
|---|---|---|
| `.\scripts\test-repository.ps1` | Prüft Parser, Manifeste und Tests lokal. | Konsolenergebnis; keine Cloud-Aktion |
| `.\scripts\runpod-model-backup.ps1` | Sichert die standardmäßig ausgewählten Modellartefakte auf `BACKUP_WIN`. | `qwen38-27b-model-backup` auf dem Datenträger |
| `.\scripts\runpod-model-backup.ps1 -VerifyOnly` | Prüft das Archiv ohne Hub-Zugriff. | Aktualisierte Prüfmarker im Archiv |
| `.\scripts\runpod-provision.ps1` | Erstellt nur den lokalen A100-Deploymentplan. | `.runpod/deployments/` |
| `.\scripts\runpod-provision.ps1 -Execute ...` | Erstellt, prüft und konfiguriert den RunPod. | `.runpod/session.json` und laufender Q6-Endpunkt |
| `.\scripts\runpod-connect.ps1` | Startet Tunnel und lokale GUI. | Browserfenster auf `127.0.0.1:4096` |
| `.\scripts\runpod-status.ps1` | Zeigt Pod-, Server-, Tunnel- und GUI-Status. | Konsolenausgabe |
| `.\scripts\runpod-a100-acceptance.ps1` | Prüft den qualifizierten A100-Q6-Endpunkt. | `artifacts/acceptance/` |
| `.\scripts\run-cybench.ps1` | Startet einen Cybench-Lauf. | `artifacts/logs/` und Inspect View |
| `.\scripts\runpod-stop.ps1` | Beendet lokale GUI und Tunnel. | Lokale Prozesse beendet |

<a id="de-lokale-daten"></a>

## Lokale Daten und Kosten

> [!IMPORTANT]
> `.runpod/` enthält lokale Geheimnisse und Sitzungsdaten und darf nicht in Git
> gelangen. API-Schlüssel, SSH-Schlüssel und Modellserver-Schlüssel bleiben
> außerhalb des Repositorys.

> [!WARNING]
> `runpod-stop.ps1` beendet nur die lokale GUI und den Tunnel. Der Pod muss
> danach im RunPod-Dashboard gestoppt oder terminiert werden, damit keine
> weiteren Cloudkosten entstehen.

<a id="de-lizenz"></a>

## Lizenz

Die Projektinhalte stehen unter der [Apache License 2.0](LICENSE). Modelle,
Modellartefakte und weitere Drittinhalte behalten ihre jeweiligen Lizenzen.

<div align="center">

[`Nach oben`](#top)

</div>

---

<a id="english"></a>

<div align="center">

`LOCAL LLM` · `RUNPOD` · `CYBER EVALUATION`

# Qwen3.8-27B RunPod Agent

Reproducible A100 deployment, local model backup, isolated chat interface, and
Cybench evaluation tooling for `Qwen3.8-27B`.

`A100 80 GB` · `Q6_K` · `llama.cpp` · `OpenCode` · `Inspect AI` · `Cybench`

[`Overview`](#en-overview) [`Workflow`](#en-workflow) [`Getting started`](#en-getting-started)
[`Scripts`](#en-scripts) [`Local data`](#en-local-data) [`License`](#en-license)

</div>

---

<a id="en-overview"></a>

## Overview

By default, the repository deploys the pinned `uncensored-q6` profile to an
`NVIDIA A100 80 GB PCIe` on RunPod. The model server runs on the Pod; an SSH
tunnel exposes the isolated OpenCode interface only at
`http://127.0.0.1:4096`.

| Area | Canonical source |
|---|---|
| Setup and operation | [QUICKSTART.md](QUICKSTART.md#english) |
| Model variants, revisions, and SHA-256 values | [config/models.json](config/models.json) |
| Hardware, cost, and deployment contract | [config/runpod-a100-pcie-deployment.json](config/runpod-a100-pcie-deployment.json) |
| Project license | [Apache-2.0](LICENSE) |

<a id="en-workflow"></a>

## Workflow

```text
PowerShell control -> RunPod API -> A100 Pod -> llama.cpp / Qwen3.8-27B
Local OpenCode UI <- SSH tunnel <- isolated agent environment
Cybench / Inspect AI -> approved model endpoint -> result artifacts
```

Without `-Execute`, provisioning creates only a local, reviewable deployment
plan. Cloud resources are created only when execution is explicitly enabled.

<a id="en-getting-started"></a>

## Getting Started

1. Complete the prerequisites and local setup in
   [QUICKSTART.md](QUICKSTART.md#english).
2. Generate the deployment plan and retain its SHA-256 value.
3. Deliberately provision the Pod with `-Execute`.
4. Start the tunnel and interface with `runpod-connect.ps1`.
5. Stop the local processes, then stop or terminate the Pod in the RunPod
   dashboard.

<a id="en-scripts"></a>

## Important Scripts

| Command | Purpose | Result |
|---|---|---|
| `.\scripts\test-repository.ps1` | Runs parsers, manifest checks, and tests locally. | Console result; no cloud action |
| `.\scripts\runpod-model-backup.ps1` | Backs up the default model artifacts to `BACKUP_WIN`. | `qwen38-27b-model-backup` on the selected drive |
| `.\scripts\runpod-model-backup.ps1 -VerifyOnly` | Verifies the archive without Hub access. | Updated verification markers in the archive |
| `.\scripts\runpod-provision.ps1` | Creates only the local A100 deployment plan. | `.runpod/deployments/` |
| `.\scripts\runpod-provision.ps1 -Execute ...` | Creates, verifies, and configures the RunPod Pod. | `.runpod/session.json` and a running Q6 endpoint |
| `.\scripts\runpod-connect.ps1` | Starts the tunnel and local UI. | Browser window at `127.0.0.1:4096` |
| `.\scripts\runpod-status.ps1` | Reports Pod, server, tunnel, and UI status. | Console output |
| `.\scripts\runpod-a100-acceptance.ps1` | Verifies the qualified A100 Q6 endpoint. | `artifacts/acceptance/` |
| `.\scripts\run-cybench.ps1` | Starts a Cybench run. | `artifacts/logs/` and Inspect View |
| `.\scripts\runpod-stop.ps1` | Stops the local UI and tunnel. | Local processes stopped |

<a id="en-local-data"></a>

## Local Data and Cost Boundary

> [!IMPORTANT]
> `.runpod/` contains local secrets and session data and must never enter Git.
> API keys, SSH keys, and model-server keys remain outside the repository.

> [!WARNING]
> `runpod-stop.ps1` stops only the local UI and tunnel. Stop or terminate the
> Pod in the RunPod dashboard afterward to prevent further cloud charges.

<a id="en-license"></a>

## License

Project content is available under the [Apache License 2.0](LICENSE). Models,
model artifacts, and other third-party content retain their respective
licenses.

<div align="center">

[`Back to top`](#top)

</div>
