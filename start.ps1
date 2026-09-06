<#
.SYNOPSIS
    Startet das Gateway und, falls eingerichtet, die lokale Suchquelle.

.DESCRIPTION
    Prueft zuerst, was fehlt, und sagt es beim Namen - statt mit einer
    unverstaendlichen Meldung abzubrechen, wenn schon die Haelfte laeuft.

    Das Gateway laeuft im Vordergrund; Strg+C beendet es. SearXNG laeuft als
    Container weiter, bis es mit `-StopSearch` oder
    `docker compose -f search/compose.yaml down` beendet wird.

.PARAMETER NoSearch
    SearXNG nicht starten, auch wenn es eingerichtet ist.

.PARAMETER StopSearch
    Nur SearXNG beenden, sonst nichts.

.EXAMPLE
    .\start.ps1
    .\start.ps1 -NoSearch
    .\start.ps1 -StopSearch
#>
[CmdletBinding()]
param(
    [switch]$NoSearch,
    [switch]$StopSearch
)

$ErrorActionPreference = 'Stop'
$wurzel = $PSScriptRoot

function Schritt($text)  { Write-Host "  $text" }
function Gut($text)      { Write-Host "  [ok]   $text" -ForegroundColor Green }
function Hinweis($text)  { Write-Host "  [i]    $text" -ForegroundColor DarkGray }
function Warnung($text)  { Write-Host "  [!]    $text" -ForegroundColor Yellow }
function Fehler($text)   { Write-Host "  [x]    $text" -ForegroundColor Red }

function Test-Port([int]$port) {
    # Ein freier Port ist der Normalfall, kein Fehler. Get-NetTCPConnection
    # sieht das anders und schreibt eine CIM-Meldung ins Bild.
    try {
        $treffer = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
        return [bool]$treffer
    } catch {
        return $false
    }
}

function Lies-Env([string]$pfad) {
    $werte = @{}
    if (Test-Path $pfad) {
        foreach ($zeile in Get-Content $pfad) {
            $z = $zeile.Trim()
            if (-not $z -or $z.StartsWith('#') -or -not $z.Contains('=')) { continue }
            $teile = $z.Split('=', 2)
            $werte[$teile[0].Trim()] = $teile[1].Trim().Trim('"').Trim("'")
        }
    }
    return $werte
}

# --- Nur beenden? ---------------------------------------------------------

if ($StopSearch) {
    Write-Host "`nSuchquelle beenden" -ForegroundColor Cyan
    docker compose -f (Join-Path $wurzel 'search\compose.yaml') --env-file (Join-Path $wurzel 'search\.env') down
    Gut "SearXNG beendet."
    exit 0
}

Write-Host "`nLocal AI Remote" -ForegroundColor Cyan
Write-Host "===============`n"

# --- Voraussetzungen ------------------------------------------------------

Write-Host "Voraussetzungen"

$envPfad = Join-Path $wurzel 'gateway\.env'
if (-not (Test-Path $envPfad)) {
    Fehler "gateway\.env fehlt."
    Hinweis "Vorlage kopieren und Token setzen:"
    Hinweis "  Copy-Item gateway\.env.example gateway\.env"
    exit 1
}

$konf = Lies-Env $envPfad
if (-not $konf['GATEWAY_TOKEN'] -or $konf['GATEWAY_TOKEN'].Length -lt 16) {
    Fehler "GATEWAY_TOKEN fehlt oder ist zu kurz (mindestens 16 Zeichen)."
    Hinweis "Ein frisches Geheimnis erzeugen:"
    Hinweis '  python -c "import secrets; print(secrets.token_urlsafe(32))"'
    exit 1
}
Gut "gateway\.env sieht brauchbar aus."

try { python --version | Out-Null; Gut "Python gefunden." }
catch { Fehler "Python nicht im PATH."; exit 1 }

try {
    python -c "import fastapi, uvicorn, httpx, psutil" 2>$null
    if ($LASTEXITCODE -ne 0) { throw }
    Gut "Python-Pakete vollstaendig."
} catch {
    Fehler "Pakete fehlen."
    Hinweis "  pip install -r gateway\requirements.txt"
    exit 1
}

# --- Backends -------------------------------------------------------------

Write-Host "`nInferenz-Server"

foreach ($b in @(
    @{ Name = 'Ollama';    Port = 11434; Hinweis = 'startet normalerweise mit Windows' },
    @{ Name = 'LM Studio'; Port = 1234;  Hinweis = 'GUI starten oder: lms server start' }
)) {
    if (Test-Port $b.Port) { Gut "$($b.Name) laeuft (Port $($b.Port))." }
    else { Warnung "$($b.Name) laeuft nicht - $($b.Hinweis)." }
}

# Ein fehlendes Backend ist kein Abbruchgrund: das Gateway zeigt es als
# "nicht erreichbar" an, und das andere funktioniert weiter.

# --- Suchquelle -----------------------------------------------------------

Write-Host "`nSuchquelle"

$suchAn = $konf['GATEWAY_SEARCH_PROVIDER'] -eq 'searxng' -and -not $NoSearch
if (-not $suchAn) {
    if ($NoSearch) { Hinweis "Uebersprungen (-NoSearch)." }
    else { Hinweis "GATEWAY_SEARCH_PROVIDER ist nicht 'searxng' - nichts zu starten." }
} elseif (Test-Port 8888) {
    Gut "SearXNG laeuft bereits (Port 8888)."
} else {
    try { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { throw } }
    catch {
        Warnung "Docker laeuft nicht - Suche bleibt aus, der Rest funktioniert."
        Hinweis "Docker Desktop starten und dieses Skript erneut aufrufen."
        $suchAn = $false
    }
    if ($suchAn) {
        $searchEnv = Join-Path $wurzel 'search\.env'
        if (-not (Test-Path $searchEnv)) {
            Schritt "search\.env anlegen ..."
            $geheim = python -c "import secrets; print(secrets.token_hex(32))"
            "SEARXNG_SECRET=$geheim" | Set-Content -Path $searchEnv -Encoding utf8
            Gut "Geheimnis erzeugt."
        }
        Schritt "SearXNG starten ..."
        docker compose -f (Join-Path $wurzel 'search\compose.yaml') --env-file $searchEnv up -d
        Start-Sleep -Seconds 8
        if (Test-Port 8888) { Gut "SearXNG laeuft auf http://127.0.0.1:8888" }
        else { Warnung "SearXNG antwortet noch nicht - beim ersten Start dauert es laenger." }
    }
}

# --- Fernzugriff ----------------------------------------------------------

Write-Host "`nFernzugriff"

if (Get-Command tailscale -ErrorAction SilentlyContinue) {
    $status = (tailscale serve status 2>&1 | Out-String)
    if ($status -match '8765') {
        Gut "tailscale serve leitet bereits auf 8765 weiter."
        ($status -split "`n" | Where-Object { $_ -match 'https://' } | Select-Object -First 1) |
            ForEach-Object { Hinweis "Adresse fuer die App: $($_.Trim())" }
    } else {
        Warnung "tailscale serve ist nicht eingerichtet."
        Hinweis "Einmalig, damit das Telefon herankommt:"
        Hinweis "  tailscale serve --bg 8765"
    }
} else {
    Hinweis "Tailscale nicht gefunden - lokal geht trotzdem alles."
}

# --- Gateway --------------------------------------------------------------

Write-Host "`nGateway" -ForegroundColor Cyan

if (Test-Port 8765) {
    Fehler "Port 8765 ist schon belegt - laeuft das Gateway bereits?"
    Hinweis "Den Prozess findest du mit:"
    Hinweis "  Get-NetTCPConnection -LocalPort 8765 -State Listen | Select-Object OwningProcess"
    exit 1
}

Hinweis "Strg+C beendet das Gateway. SearXNG laeuft weiter (.\start.ps1 -StopSearch)."
Write-Host ""
Push-Location $wurzel
try { python -m gateway.main } finally { Pop-Location }
