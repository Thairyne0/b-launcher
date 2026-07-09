# Estensione VSCode — MVP orchestratore (standalone)

**Data:** 2026-07-06 · **Stato:** in design · **Branch:** experimental-v3

Estensione VSCode indipendente che legge lo **stesso** `services.json` dell'app nativa,
mostra progetti/servizi in sidebar e li avvia in **terminali VSCode veri** (PTY: colori +
input nativi). Nessuna duplicazione della gestione: creare/modificare progetti resta
nell'app nativa; l'estensione **consuma** il file (contratto condiviso). Standalone perché
andrà sul marketplace.

## Architettura

- Progetto **TypeScript** in `vscode-extension/` (ora sottocartella di questo repo; a
  marketplace-time → repo separata `blauncher-vscode`).
- Legge `~/Library/Application Support/BackendLauncher/services.json` (stesso path e schema
  dell'app). Tollera version v1/v2, ignora chiavi sconosciute (forward-compat). `fs.watch`
  sul file → refresh automatico quando l'app nativa modifica.
- Motore processi = **terminali integrati VSCode** (`createTerminal(cwd) + sendText(cmd)`):
  PTY reale, colori, stdin nativo → il terminale interattivo è gratis.

## Componenti (unità isolate, testabili)

- `store.ts` — localizza, legge, parse `services.json` in tipi TS che rispecchiano
  StoredProject/StoredService/StoredReadiness. Puro, unit-tested.
- `tree.ts` — `TreeDataProvider`: progetti → servizi, icona/colore per stato.
- `runner.ts` — start = crea terminale (cwd, nome) + `sendText(command)`; mappa serviceID →
  terminale; stop = `dispose()`; restart = dispose+ricrea; `onDidCloseTerminal` → aggiorna
  stato. Comando override (varianti) via QuickPick.
- `probes.ts` — readiness in Node: porta TCP (`net.connect`), health HTTP (2xx). Poll dei
  servizi vivi. Readiness a marker → fallback "vivo se terminale aperto" (VSCode non espone
  bene l'output del terminale). Puro/testabile contro un listener locale.
- `extension.ts` — attivazione, registrazione comandi, wiring.

## Comandi / UX

- Icona nella Activity Bar → view "Backend Launcher" con l'albero.
- Inline sui nodi servizio: play / stop / restart. Menu contestuale: idem + "Avvia con…"
  (varianti). Nodi progetto: avvia/ferma progetto.
- Stato: pallino/colore come nell'app (fermo/avvio/in esecuzione/esterno).
- Non frustrante: un click → terminale VSCode reale, niente finestre esterne, niente form.

## MVP: cosa NON fa (onesto)

- Niente creazione/editing/scan/import: si fanno nell'app nativa.
- Readiness a marker → solo "processo vivo" (no lettura output del terminale).
- Orchestrazione `startAfter`/"Avvia stack": fase successiva, non nell'MVP.
- Stop = `terminal.dispose()` (semantica diversa dal killpg nativo, accettabile per MVP).

## Test

- Logica pura (`store` parse, `probes`) → unit test (mocha/vitest), probe contro listener
  locale come nell'app Swift.
- `tree`/`runner` → test con vscode API mockata dove possibile; il resto verificato a mano
  nel dev-host (F5).

## Distribuzione (pre-marketplace)

- Sviluppo: **F5** → Extension Development Host (nessuna pubblicazione).
- Condivisione/prova: `vsce package` → `.vsix`, `code --install-extension`.
- "Installa da blauncher": l'app nativa lancia `code --install-extension <vsix>` (fase
  finale, quando il `.vsix` esiste).

## Fuori scope (→ dopo l'MVP)

Marketplace publish, orchestrazione dipendenze, "Avvia stack" + apertura app, editing dei
progetti dall'estensione, pannello Errori aggregato.
