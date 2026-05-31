[CmdletBinding()]
param(
    [ValidateSet("ui", "headless")]
    [string]$Mode = "ui",

    [Alias("Host")]
    [string]$MaterializeHost = "127.0.0.1",
    [int]$Port = 6875,
    [string]$Database = "materialize",
    [string]$Schema = "tpcc",
    [string]$DbUser = "mz_system",
    [string]$Password = "N<_n!BN6v[D=fo5_",
    [ValidateSet("disable", "require")]
    [string]$SslMode = "require",
    [string]$Cluster = "quickstart",

    [int]$Users = 10,
    [double]$SpawnRate = 2,
    [string]$RunTime = "5m",

    [string]$VenvPath = ".venv",
    [string]$LocustFile = "locustfile.py",
    [switch]$SkipInstall,

    [switch]$AutoPortForward,
    [string]$K8sNamespace = "materialize-environment",
    [string]$K8sService = "mzy49fo679im-balancerd",
    [int]$LocalPort = 6875,
    [int]$RemotePort = 6875,

    [switch]$UseK8sSecret,
    [string]$SecretNamespace = "materialize-environment",
    [string]$SecretName = "main-materialize-backend",
    [string]$SecretKey = "external_login_password_mz_system",

    [string[]]$ExtraLocustArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-PythonCommand {
    if (Get-Command py -ErrorAction SilentlyContinue) {
        return @("py", "-3")
    }
    if (Get-Command python -ErrorAction SilentlyContinue) {
        return @("python")
    }
    throw "Python was not found on PATH. Install Python 3 first."
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

if ($UseK8sSecret -and [string]::IsNullOrWhiteSpace($Password)) {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "kubectl is required when -UseK8sSecret is set."
    }

    Write-Host "Reading Materialize password from Kubernetes secret $SecretNamespace/$SecretName..."
    $jsonPath = "{.data.$SecretKey}"
    $passwordB64 = kubectl -n $SecretNamespace get secret $SecretName -o jsonpath=$jsonPath
    if ([string]::IsNullOrWhiteSpace($passwordB64)) {
        throw "Secret key '$SecretKey' was empty or not found in $SecretNamespace/$SecretName."
    }

    $Password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($passwordB64))
}

if ([string]::IsNullOrWhiteSpace($Password)) {
    Write-Warning "No Materialize password supplied. Use -Password or -UseK8sSecret if your endpoint requires auth."
}

$pythonCmd = Get-PythonCommand
$pythonExe = $pythonCmd[0]
$pythonArgs = @()
if ($pythonCmd.Count -gt 1) {
    $pythonArgs = $pythonCmd[1..($pythonCmd.Count - 1)]
}

$activatePath = Join-Path $VenvPath "Scripts\Activate.ps1"
if (-not (Test-Path $activatePath)) {
    Write-Host "Creating virtual environment at $VenvPath..."
    & $pythonExe @pythonArgs -m venv $VenvPath
}

. $activatePath

if (-not $SkipInstall) {
    Write-Host "Installing Python dependencies..."
    python -m pip install --upgrade pip | Out-Null
    python -m pip install -r requirements.txt
}

$portForwardProc = $null

if ($AutoPortForward) {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "kubectl is required when -AutoPortForward is set."
    }

    Write-Host "Starting kubectl port-forward svc/$K8sService $LocalPort`:$RemotePort -n $K8sNamespace ..."
    $kubectlArgs = @("port-forward", "svc/$K8sService", "$LocalPort`:$RemotePort", "-n", $K8sNamespace)
    $portForwardProc = Start-Process -FilePath "kubectl" -ArgumentList $kubectlArgs -NoNewWindow -PassThru
    Start-Sleep -Seconds 1
    if ($portForwardProc.HasExited) {
        throw "kubectl port-forward failed to start."
    }

    # talk to the forwarded port on localhost
    $MaterializeHost = "localhost"
    $Port = $LocalPort
}

$env:MATERIALIZE_HOST = $MaterializeHost
$env:MATERIALIZE_PORT = "$Port"
$env:MATERIALIZE_DATABASE = $Database
$env:MATERIALIZE_SCHEMA = $Schema
$env:MATERIALIZE_USER = $DbUser
$env:MATERIALIZE_PASSWORD = $Password
$env:MATERIALIZE_SSLMODE = $SslMode
$env:MATERIALIZE_CLUSTER = $Cluster

$locustArgs = @("-f", $LocustFile)
if ($Mode -eq "headless") {
    $locustArgs += @("--headless", "-u", "$Users", "-r", "$SpawnRate", "--run-time", $RunTime)
}
if ($ExtraLocustArgs) {
    $locustArgs += $ExtraLocustArgs
}

Write-Host "Starting Locust in $Mode mode..."
if ($Mode -eq "ui") {
    Write-Host "Open http://localhost:8089"
}

try {
    locust @locustArgs
} finally {
    if ($portForwardProc -ne $null) {
        Write-Host "Stopping kubectl port-forward (pid $($portForwardProc.Id))..."
        Stop-Process -Id $portForwardProc.Id -ErrorAction SilentlyContinue
    }
}
