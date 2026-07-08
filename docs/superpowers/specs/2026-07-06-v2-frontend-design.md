# v2 — Supporto frontend: app principale, Avvia stack, varianti di comando

**Data:** 2026-07-06 · **Stato:** approvato in sessione · **Branch:** v2

Per chi lavora sul frontend (web, Flutter, Expo, desktop) e ha bisogno dello stack
backend su e verde prima di lavorare. Principio: il frontend è un servizio come gli
altri (qualsiasi comando); il launcher garantisce lo stack e, opzionalmente, lancia
l'app per ultima.

## App principale + "Avvia stack"

- `StoredService.isMainApp: Bool?` (additivo): al più UNA per progetto — lo store la
  fa rispettare (flaggarne una nuova sflagga le altre).
- `StoredService.appURL: String?` (additivo): URL dell'app per i frontend web
  (es. http://localhost:5173) o della doc API di un backend. Esportato nei template
  (localhost è portabile).
- Azione `startStack(progetto)`: orchestrazione a ondate esistente con l'app
  principale forzata in ULTIMA ondata (dipendenza implicita da tutti gli altri del
  set), attesa readiness anche dell'ultima ondata, poi: browser sull'`appURL` della
  main app se presente; notifica "Stack pronto" + toast in ogni caso.
- Toolbar pagina progetto: se il progetto ha una main app, il bottone prominente
  diventa "Avvia stack" (stesso posto di "Avvia progetto").
- Flutter/nativo: niente stdin nella pipe → niente hot-reload interattivo dal
  launcher; l'app parte e logga, il ciclo di sviluppo resta nell'IDE. La main app è
  opzionale: senza, "Avvia stack" non compare (resta "Avvia progetto").

## Bottone "apri" sull'URL app

Card: se `appURL` è valorizzato, icona safari accanto ai controlli → apre il browser.

## Scanner Flutter

`pubspec.yaml` → comando `flutter run`, readiness processAlive, hint
"pubspec.yaml (Flutter)". (Expo non serve un caso speciale: ha `package.json` con
script `start`, già riconosciuto.)

## Varianti di comando

- `StoredService.commandVariants: [String]?` (additivo, esportato nei template):
  comandi alternativi, es. `flutter run -d macos` / `-d iphone` / `-d chrome`, o
  `npm run start:debug` per un backend.
- Card: nel menu contestuale, submenu "Avvia con…" con le varianti → avvio one-shot
  con quel comando (il comando di default resta invariato nello store).
- `ServiceController.start(commandOverride:)`: usa l'override solo per quello spawn.

## Test

Store round-trip + enforcement singola main app; template round-trip; orchestrazione
startStack (main parte per ultima, onReady dopo la readiness della main); scanner
pubspec; controller start con override (e2e echo); varianti round-trip.

## Fuori scope

Gestione device Flutter integrata (`flutter devices`), proxy/mock API, stdin
interattivo verso i processi.
