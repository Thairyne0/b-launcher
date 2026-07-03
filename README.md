# Backend Launcher

App macOS nativa (SwiftUI, Liquid Glass) per avviare/fermare i backend Skillera
e vederne status e log, senza toccare il progetto SkillLocale.

## Requisiti

- macOS 26 (Tahoe), Xcode 26 (per compilare)
- `npm` in `/opt/homebrew/bin` (Homebrew) — risolto via `zsh -l`
- Progetto Skillera in `/Users/retr0/Documents/skilllocale/SkillLocale`
- Infra (NATS/Redis/Milvus) già attiva in Docker: il launcher NON la gestisce,
  mostra solo la spia NATS in toolbar

## Uso

```bash
make run     # builda dist/Backend Launcher.app e la apre
make dev     # build+run veloce senza bundle (swift run)
make test    # unit test
make app     # builda solo il bundle
make clean
```

## Servizi gestiti

gateway :4000 · id :4001 · atlas :4003 · hr :4006 · certet :4010 · bill :4012

Ogni backend parte con `npm run start:dev` nella sua directory, in un process
group dedicato: lo stop (SIGTERM → 5s → SIGKILL sul group) non lascia orfani.

## Configurazione

Tutto statico in `Sources/BackendLauncher/Models/ServiceConfig.swift`
(path progetto, servizi, porte). Edita quel file e `make run`.

## Stati

- ⚪️ fermo · 🟡 avvio… · 🟢 in esecuzione (porta aperta) · 🟠 arresto…
- 🔴 crash (exit code mostrato) · 🔵 attivo fuori dal launcher (start disabilitato)

## Chiusura

Cmd-Q con backend attivi → conferma → stop pulito di tutto (niente orfani).
