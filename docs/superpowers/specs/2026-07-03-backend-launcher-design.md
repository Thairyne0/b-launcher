# Backend Launcher — Design

**Data:** 2026-07-03
**Stato:** approvato

## Obiettivo

App macOS nativa (SwiftUI, stile Liquid Glass) per avviare/fermare i backend del progetto Skillera (SkillLocale), vedere lo status di ognuno e, a richiesta, il terminale (log live) di ogni backend.

## Vincoli

- **Zero modifiche** al progetto `/Users/retr0/Documents/skilllocale/SkillLocale` — il launcher lo usa in sola lettura come working directory dei processi.
- Il launcher vive in `/Users/retr0/Documents/Backend Launcher`.
- Target macOS 26 (Tahoe) — API Liquid Glass native (`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`). Xcode 26.5 disponibile.
- I backend muoiono col launcher: sono processi figli. Alla chiusura, conferma e terminazione pulita.
- pm2 NON usato (non installato); avvio diretto `npm run start:dev`.

## Servizi gestiti

Config statica in `ServiceConfig.swift` (facile da editare a mano).
Root progetto: `/Users/retr0/Documents/skilllocale/SkillLocale` (costante in `ServiceConfig.swift`).

| Servizio | Directory | Porta status | Comando |
|---|---|---|---|
| gateway | `SKILLGATEWAY-BE` | 4000 | `npm run start:dev` |
| id | `SKILLID-BE` | 4001 (OIDC HTTP) | `npm run start:dev` |
| atlas | `SKILLATLAS-BE` | 4003 | `npm run start:dev` |
| hr | `SKILLHR-BE` | 4006 | `npm run start:dev` |
| certet | `SKILLCERTET-BE` | 4010 | `npm run start:dev` |
| bill | `SKILLBILL-BE` | 4012 | `npm run start:dev` |
| infra | root progetto | 4222 (NATS) | `docker compose -f docker-compose.infra.yml up -d` / `stop` |

## Architettura

Swift Package (SPM) + Makefile. `make run` builda e lancia `BackendLauncher.app`; `scripts/make-app.sh` assembla il bundle (Info.plist, binario). Niente `.xcodeproj`.

```
Backend Launcher/
  Package.swift
  Makefile                      # make build / make run / make app / make test
  scripts/make-app.sh           # assembla .app bundle
  Sources/BackendLauncher/
    BackendLauncherApp.swift    # @main, WindowGroup, conferma quit
    Models/
      ServiceConfig.swift       # definizione 6 backend + infra + root path
      ServiceStatus.swift       # enum stato
    Managers/
      ProcessManager.swift      # spawn con process group, killpg, pipe log
      InfraManager.swift        # docker compose up/stop + stato
      PortMonitor.swift         # TCP check porte, poll 2s
      LogStore.swift            # ring buffer 5000 righe/servizio + ricerca
    Views/
      ContentView.swift         # toolbar + card infra + 6 card backend
      ServiceCardView.swift     # status dot, nome, porta, uptime, ▶︎ ■ ↻, chevron
      TerminalView.swift        # log monospace, autoscroll, ricerca, clear
      InfraCardView.swift
  Tests/BackendLauncherTests/   # Swift Testing
```

## Gestione processi

- **Start backend**: `zsh -lc "exec npm run start:dev"` con `cwd` = directory servizio. `zsh -lc` obbligatorio: app GUI non eredita il PATH della shell (nvm/npm non risolvibili altrimenti).
- Ogni processo in **process group dedicato** (posix_spawn con `POSIX_SPAWN_SETPGROUP`): stop = `killpg(SIGTERM)` → attesa max 5s → `SIGKILL`. Ammazza npm + node + watcher NestJS in blocco, zero orfani.
- stdout+stderr → pipe → `LogStore` (ring buffer 5000 righe per servizio).
- **Restart** = stop poi start.
- Nessun autorestart automatico: crash → status rosso → restart manuale.
- **Quit app** con backend attivi → dialog conferma → SIGTERM a tutti i group, attesa max 5s, SIGKILL residui.

## Status (per backend)

Poll porta TCP ogni 2s + osservazione vita processo:

| Stato | Colore | Condizione |
|---|---|---|
| fermo | grigio | nessun processo |
| starting | giallo (pulsante) | processo vivo, porta chiusa |
| running | verde | processo vivo, porta aperta |
| crashed | rosso | processo morto da solo (exit code mostrato) |
| esterno | blu | porta aperta ma processo non del launcher → start disabilitato |

Infra: status = porta NATS 4222 aperta.

## UI (Liquid Glass)

- Finestra unica, sfondo material, dark/light automatici.
- **Toolbar**: "Avvia tutti" / "Ferma tutti" (`.buttonStyle(.glass)`).
  - Avvia tutti: parte infra → attende NATS su (max 30s) → parte i 6 backend.
  - Ferma tutti: ferma i backend, poi l'infra.
- **Card infra** in cima (stile distinto), poi 6 **card backend** in `GlassEffectContainer` con `.glassEffect(.regular, in:)`.
- Card backend: pallino status animato, nome, porta, uptime, bottoni ▶︎ ■ ↻, chevron → **terminale inline espandibile** (~300px, monospace, sfondo scuro, autoscroll disattivabile, campo ricerca/filtro, bottone clear). Più terminali apribili insieme.

## Errori

- npm non trovato (`zsh -lc which npm` fallisce) → alert con fix suggerito.
- Docker spento → card infra "Docker non in esecuzione", start disabilitato.
- "Avvia tutti" con infra giù → parte infra, attende NATS max 30s; timeout → errore visibile, backend non partono.
- Porta occupata da processo esterno → stato "esterno", start disabilitato.

## Test

- Unit (Swift Testing): `LogStore` (ring buffer, ricerca), transizioni `ServiceStatus`, `ServiceConfig`.
- `ProcessManager`/`PortMonitor`: processo fittizio (`sleep`, mini listener TCP locale).
- E2E con backend veri: verifica manuale finale.

## Fuori scope

- Autorestart su crash (PM2-style)
- Link rapidi Swagger/browser
- Gestione servizi non richiesti (lms, ai, mentore, train)
- Modifica `.env` o file del progetto SkillLocale
- Signing/notarizzazione (uso locale, firma ad-hoc)
