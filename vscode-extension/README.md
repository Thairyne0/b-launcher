# Backend Launcher — estensione VSCode

Estensione **standalone** che legge lo stesso `services.json` dell'app nativa Backend
Launcher e ti fa avviare/gestire i backend dei tuoi progetti in **terminali VSCode veri**
(colori + input nativi), senza uscire dall'editor.

Stato: **in sviluppo** su `experimental-v3` (Fase 0 — scaffold).

## Sviluppo

```bash
cd vscode-extension
npm install
npm run build      # bundle → dist/extension.js
```

Poi in VSCode apri la cartella `vscode-extension/` e premi **F5**: si apre l'Extension
Development Host (una seconda finestra VSCode) con l'estensione caricata. Nessuna
pubblicazione necessaria.

## Pacchetto locale (senza marketplace)

```bash
npm run package    # → backend-launcher-x.y.z.vsix
code --install-extension backend-launcher-*.vsix
```

## Roadmap (MVP)

- **Fase 0** — scaffold (sidebar + comando refresh) ✅
- **Fase 1** — legge `services.json`, mostra progetti/servizi (read-only, live)
- **Fase 2** — avvia i servizi in terminali VSCode veri (play/stop/restart)
- **Fase 3** — stato/readiness (porta TCP + health HTTP)
- **Fase 4** — azioni progetto + `.vsix`
- **Fase 5** — "installa da blauncher" (dall'app nativa)

Dettagli: `../docs/superpowers/specs/2026-07-06-vscode-extension-mvp-design.md`.
