# Qwen3.8-27B RunPod Agent

Dieses Repository stellt das gepinnte Profil `uncensored-q6` auf einer
RunPod-A100 bereit und oeffnet eine isolierte OpenCode-Oberflaeche unter
`http://127.0.0.1:4096`.

- Einstieg: [QUICKSTART.md](QUICKSTART.md)
- Modellpins und SHA-256-Werte: [config/models.json](config/models.json)
- Deploymentvertrag: [config/runpod-a100-pcie-deployment.json](config/runpod-a100-pcie-deployment.json)
- Lizenz: [Apache-2.0](LICENSE)

## Wichtige Skripte

| Befehl | Funktion | Ergebnis |
|---|---|---|
| `.\scripts\test-repository.ps1` | Prueft Parser, Manifeste und Tests lokal. | Konsolenergebnis; keine Cloud-Aktion |
| `.\scripts\runpod-model-backup.ps1` | Sichert die standardmaessig ausgewaehlten Modellartefakte auf `BACKUP_WIN`. | `qwen38-27b-model-backup` auf dem Datentraeger |
| `.\scripts\runpod-model-backup.ps1 -VerifyOnly` | Prueft das Archiv ohne Hub-Zugriff. | Aktualisierte Pruefmarker im Archiv |
| `.\scripts\runpod-provision.ps1` | Erstellt nur den lokalen A100-Deploymentplan. | `.runpod/deployments/` |
| `.\scripts\runpod-provision.ps1 -Execute ...` | Erstellt, prueft und konfiguriert den RunPod. | `.runpod/session.json` und laufender Q6-Endpunkt |
| `.\scripts\runpod-connect.ps1` | Startet Tunnel und lokale GUI. | Browserfenster auf `127.0.0.1:4096` |
| `.\scripts\runpod-status.ps1` | Zeigt Pod-, Server-, Tunnel- und GUI-Status. | Konsolenausgabe |
| `.\scripts\runpod-a100-acceptance.ps1` | Prueft den qualifizierten A100-Q6-Endpunkt. | `artifacts/acceptance/` |
| `.\scripts\run-cybench.ps1` | Startet einen Cybench-Lauf. | `artifacts/logs/` und Inspect View |
| `.\scripts\runpod-stop.ps1` | Beendet lokale GUI und Tunnel. | Lokale Prozesse beendet |

`.runpod/` enthaelt lokale Geheimnisse und Sitzungsdaten und darf nicht in Git
gelangen. `runpod-stop.ps1` beendet nicht die RunPod-Abrechnung; den Pod danach
im RunPod-Dashboard stoppen oder terminieren.
