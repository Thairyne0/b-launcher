# Changelog

## 0.0.1 — sviluppo iniziale (experimental-v3)

Prima versione dell'estensione Backend Launcher.

- Legge lo stesso `services.json` dell'app nativa; aggiornamento live (fs.watch).
- Scansione della cartella aperta in VSCode: backend rilevati (Node/Nest, Go, Rust,
  Flutter, Python, Spring, PHP, docker-compose) mostrati e avviabili subito; "Salva
  progetto" per persisterli nel `services.json`.
- Avvia/ferma/riavvia servizio, progetto, tutti — in terminali VSCode veri (PTY: colori
  e input nativi). "Avvia con…" per le varianti di comando. "Avvia stack" (app per ultima).
- Stato reale: pallini fermo/avvio/in esecuzione/esterno via probe porta TCP + health HTTP;
  latenza dell'health check.
- Uptime live, branch git per servizio (con warning di mismatch nel progetto).
- Dashboard "mission control" del progetto: card per servizio con stato, chip
  (readiness/latenza/uptime/branch), controlli e input verso lo stdin; filtro e colore
  del progetto.
- Notifica quando un backend si ferma da solo (con "Riavvia").
- Quick pick globale "Avvia un backend…" (⌘⌥B), apri i file del backend, status bar
  con conteggio attivi.
