<a id="top"></a>

<div align="center">

[![Deutsch](https://img.shields.io/badge/🇩🇪_Deutsch-24292f?style=for-the-badge)](#deutsch)
[![English](https://img.shields.io/badge/🇬🇧_English-24292f?style=for-the-badge)](#english)

</div>

---

<a id="deutsch"></a>

<div align="center">

`SETUP` · `DEPLOY` · `CONNECT` · `STOP`

# Quickstart

Vom frischen Klon bis zur lokalen OpenCode-Oberfläche.

`Windows` · `PowerShell` · `WSL2` · `Docker` · `RunPod`

[`Voraussetzungen`](#de-voraussetzungen) [`Einrichten`](#de-einrichten)
[`Deployment`](#de-deployment) [`Verbinden`](#de-verbinden) [`Beenden`](#de-beenden)

</div>

---

<a id="de-voraussetzungen"></a>

## Voraussetzungen

- Git
- Python `3.12`
- Windows PowerShell und OpenSSH
- Docker Desktop mit Linux-Containern
- WSL2 `Ubuntu-24.04` mit dem Benutzer `qwen-eval`
- RunPod-Konto und API-Key nur für die tatsächliche Bereitstellung

<a id="de-einrichten"></a>

## 1. Repository einrichten

```powershell
git clone https://github.com/p-keminer/qwen38-27b-cyber-deployment.git
Set-Location .\qwen38-27b-cyber-deployment

wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/install-uv.sh
wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/bootstrap-local.sh
```

<a id="de-deployment"></a>

## 2. Deploymentplan erzeugen

Dieser Befehl startet noch keinen Pod:

```powershell
$Plan = .\scripts\runpod-provision.ps1 -OutputFormat Json | ConvertFrom-Json
$PlanSha256 = $Plan.plan_sha256
$IdentityFile = Read-Host 'Absoluter Pfad zum privaten SSH-Schlüssel'
```

## 3. Pod bereitstellen

> [!WARNING]
> Der folgende Aufruf startet einen kostenpflichtigen RunPod.

Der API-Key bleibt nur in der aktuellen PowerShell-Sitzung:

```powershell
$SecureKey = Read-Host 'RunPod Control API key' -AsSecureString
$KeyPointer = [IntPtr]::Zero
try {
    $KeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    $env:RUNPOD_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($KeyPointer)
    .\scripts\runpod-provision.ps1 -Execute `
        -ExpectedPlanSha256 $PlanSha256 `
        -IdentityFile $IdentityFile
}
finally {
    Remove-Item Env:RUNPOD_API_KEY -ErrorAction SilentlyContinue
    if ($KeyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($KeyPointer)
    }
}
```

<a id="de-verbinden"></a>

## 4. Chat öffnen

```powershell
.\scripts\runpod-connect.ps1
```

Das Skript öffnet `http://127.0.0.1:4096`. Der Arbeitsordner des Agenten ist
`agent-workspace`.

<a id="de-beenden"></a>

## 5. Beenden

```powershell
.\scripts\runpod-stop.ps1
```

> [!IMPORTANT]
> Danach den Pod im RunPod-Dashboard stoppen oder terminieren, damit keine
> weiteren Cloudkosten entstehen.

<div align="center">

[`README`](README.md#deutsch) [`Nach oben`](#top)

</div>

---

<a id="english"></a>

<div align="center">

`SETUP` · `DEPLOY` · `CONNECT` · `STOP`

# Quickstart

From a fresh clone to the local OpenCode interface.

`Windows` · `PowerShell` · `WSL2` · `Docker` · `RunPod`

[`Prerequisites`](#en-prerequisites) [`Setup`](#en-setup)
[`Deployment`](#en-deployment) [`Connect`](#en-connect) [`Stop`](#en-stop)

</div>

---

<a id="en-prerequisites"></a>

## Prerequisites

- Git
- Python `3.12`
- Windows PowerShell and OpenSSH
- Docker Desktop with Linux containers
- WSL2 `Ubuntu-24.04` with the `qwen-eval` user
- A RunPod account and API key only for actual provisioning

<a id="en-setup"></a>

## 1. Set Up the Repository

```powershell
git clone https://github.com/p-keminer/qwen38-27b-cyber-deployment.git
Set-Location .\qwen38-27b-cyber-deployment

wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/install-uv.sh
wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/bootstrap-local.sh
```

<a id="en-deployment"></a>

## 2. Generate the Deployment Plan

This command does not start a Pod:

```powershell
$Plan = .\scripts\runpod-provision.ps1 -OutputFormat Json | ConvertFrom-Json
$PlanSha256 = $Plan.plan_sha256
$IdentityFile = Read-Host 'Absolute path to the private SSH key'
```

## 3. Provision the Pod

> [!WARNING]
> The following command starts a billable RunPod Pod.

The API key remains only in the current PowerShell session:

```powershell
$SecureKey = Read-Host 'RunPod Control API key' -AsSecureString
$KeyPointer = [IntPtr]::Zero
try {
    $KeyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureKey)
    $env:RUNPOD_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($KeyPointer)
    .\scripts\runpod-provision.ps1 -Execute `
        -ExpectedPlanSha256 $PlanSha256 `
        -IdentityFile $IdentityFile
}
finally {
    Remove-Item Env:RUNPOD_API_KEY -ErrorAction SilentlyContinue
    if ($KeyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($KeyPointer)
    }
}
```

<a id="en-connect"></a>

## 4. Open the Chat Interface

```powershell
.\scripts\runpod-connect.ps1
```

The script opens `http://127.0.0.1:4096`. The agent workspace is
`agent-workspace`.

<a id="en-stop"></a>

## 5. Stop

```powershell
.\scripts\runpod-stop.ps1
```

> [!IMPORTANT]
> Stop or terminate the Pod in the RunPod dashboard afterward to prevent
> further cloud charges.

<div align="center">

[`README`](README.md#english) [`Back to top`](#top)

</div>
