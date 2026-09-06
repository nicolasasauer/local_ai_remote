"""Konfiguration des Gateways, komplett über Umgebungsvariablen."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

#: Neben der Umgebung wird eine .env im Gateway-Ordner gelesen. Ohne das
#: bliebe GATEWAY_TOKEN leer, obwohl die Datei angelegt wurde - und ein leerer
#: Token schaltet die Auth still ab.
_ENV_FILE = Path(__file__).resolve().parent / ".env"


def _load_env_file(path: Path = _ENV_FILE) -> None:
    """Minimaler .env-Leser. Echte Umgebungsvariablen haben Vorrang, damit
    ein Start mit ``GATEWAY_TOKEN=… python -m gateway.main`` die Datei
    übersteuert statt umgekehrt."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


class ConfigError(RuntimeError):
    """Startfehler, der nicht still übergangen werden darf."""


@dataclass(frozen=True)
class Config:
    token: str

    #: Getrenntes Token fuer die OpenAI-kompatible Oberflaeche. Leer heisst:
    #: diese Oberflaeche gibt es nicht. Agenten-Werkzeuge legen ihren
    #: Schluessel im Klartext ab; ein eigenes Token laesst sich zurueckziehen,
    #: ohne die App neu einzurichten.
    agent_token: str
    ollama_url: str
    lmstudio_url: str
    bind_host: str
    bind_port: int
    request_timeout: float
    telemetry_interval: float
    max_request_bytes: int

    #: Recherche-Werkzeuge (Websuche, Seitenabruf). Standardmaessig aus: es
    #: ist die einzige Stelle, an der das Gateway etwas ausfuehrt.
    research_enabled: bool
    search_provider: str
    searxng_url: str
    brave_key: str
    research_timeout: float
    research_max_results: int
    research_max_chars: int

    @classmethod
    def from_env(cls) -> "Config":
        _load_env_file()
        return cls(
            token=os.getenv("GATEWAY_TOKEN", "").strip(),
            agent_token=os.getenv("GATEWAY_AGENT_TOKEN", "").strip(),
            ollama_url=os.getenv("OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/"),
            lmstudio_url=os.getenv("LMSTUDIO_URL", "http://127.0.0.1:1234").rstrip("/"),
            # Standardmaessig nur lokal: tailscale serve reicht die Verbindung
            # von aussen weiter, das Gateway selbst braucht keine offene Bindung.
            bind_host=os.getenv("GATEWAY_HOST", "127.0.0.1"),
            bind_port=int(os.getenv("GATEWAY_PORT", "8765")),
            request_timeout=float(os.getenv("GATEWAY_TIMEOUT", "600")),
            telemetry_interval=float(os.getenv("TELEMETRY_INTERVAL", "1.0")),
            # Agenten-Werkzeuge schicken grosse Prompts. Eine Obergrenze
            # schuetzt den Desktop davor, sich an einer einzigen Anfrage
            # den Speicher vollzuladen.
            max_request_bytes=int(os.getenv("GATEWAY_MAX_REQUEST_BYTES", str(32 * 1024 * 1024))),
            research_enabled=os.getenv("GATEWAY_RESEARCH", "").strip().lower()
            in ("1", "true", "ja", "an"),
            search_provider=os.getenv("GATEWAY_SEARCH_PROVIDER", "none").strip().lower(),
            searxng_url=os.getenv("GATEWAY_SEARXNG_URL", "").strip(),
            brave_key=os.getenv("GATEWAY_BRAVE_KEY", "").strip(),
            research_timeout=float(os.getenv("GATEWAY_RESEARCH_TIMEOUT", "20")),
            research_max_results=int(os.getenv("GATEWAY_RESEARCH_MAX_RESULTS", "6")),
            research_max_chars=int(os.getenv("GATEWAY_RESEARCH_MAX_CHARS", "12000")),
        )

    def check(self) -> None:
        """Läuft beim Start, nicht beim Import - ein Testlauf ohne Token soll
        möglich bleiben, ein Server ohne Token nicht."""
        if not self.token:
            raise ConfigError(
                "GATEWAY_TOKEN ist leer - ohne Token wäre jede Anfrage im Tailnet "
                f"erlaubt. Token in {_ENV_FILE} setzen (Vorlage: .env.example)."
            )
        if len(self.token) < 16:
            raise ConfigError(
                f"GATEWAY_TOKEN ist mit {len(self.token)} Zeichen zu kurz; "
                "mindestens 16 verwenden."
            )
        if self.agent_token:
            if len(self.agent_token) < 16:
                raise ConfigError(
                    f"GATEWAY_AGENT_TOKEN ist mit {len(self.agent_token)} Zeichen "
                    "zu kurz; mindestens 16 verwenden."
                )
            if self.agent_token == self.token:
                raise ConfigError(
                    "GATEWAY_AGENT_TOKEN ist mit GATEWAY_TOKEN identisch. Dann "
                    "laesst sich der Agentenzugang nicht getrennt zurueckziehen "
                    "- bitte ein eigenes Geheimnis verwenden."
                )

    @property
    def agents_enabled(self) -> bool:
        return bool(self.agent_token)

    @property
    def suche_verfuegbar(self) -> bool:
        """Ob eine Suchquelle wirklich benutzbar ist.

        Eine Suche anzubieten, die dann an fehlender Konfiguration scheitert,
        kostet das Modell einen Zug und den Nutzer eine Freigabe fuer nichts.
        """
        if self.search_provider == "searxng":
            return bool(self.searxng_url)
        if self.search_provider == "brave":
            return bool(self.brave_key)
        return False


CONFIG = Config.from_env()
