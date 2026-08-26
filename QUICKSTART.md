# Quickstart

Voraussetzungen: Git, Python 3.12, Windows PowerShell, OpenSSH, Docker Desktop
mit Linux-Containern sowie WSL2 `Ubuntu-24.04` mit dem Benutzer `qwen-eval`.

## 1. Repository einrichten

```powershell
git clone https://github.com/p-keminer/qwen38-27b-cyber-deployment.git
Set-Location .\qwen38-27b-cyber-deployment

wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/install-uv.sh
wsl.exe -d Ubuntu-24.04 -u qwen-eval --cd (Get-Location).Path -- bash scripts/bootstrap-local.sh
```

## 2. Deploymentplan erzeugen

Dieser Befehl startet noch keinen Pod:

```powershell
$Plan = .\scripts\runpod-provision.ps1 -OutputFormat Json | ConvertFrom-Json
$PlanSha256 = $Plan.plan_sha256
$IdentityFile = Read-Host 'Absoluter Pfad zum privaten SSH-Schluessel'
```

## 3. Pod bereitstellen

Der folgende Aufruf startet einen kostenpflichtigen RunPod. Der API-Key bleibt
nur in der aktuellen PowerShell-Sitzung:

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

## 4. Chat oeffnen

```powershell
.\scripts\runpod-connect.ps1
```

Das Skript oeffnet `http://127.0.0.1:4096`. Der Arbeitsordner des Agenten ist
`agent-workspace`.

## 5. Beenden

```powershell
.\scripts\runpod-stop.ps1
```

Danach den Pod im RunPod-Dashboard stoppen oder terminieren, damit keine
weiteren Cloudkosten entstehen.
