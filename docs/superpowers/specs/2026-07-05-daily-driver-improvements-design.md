# Daily-driver: dipendenze avvio, pannello errori, branch, env override, infra per progetto, crash loop, latenza health

**Data:** 2026-07-05 · **Stato:** approvato in sessione ("aggiustiamo questi problemi senza 2, 8 e 10")

Sette interventi dalla review "senior backendista". Esclusi esplicitamente: comando di
stop custom, CLI companion, auto-restart.

## #4 Badge branch git

- `GitBranch.current(in directory:) -> String?` (`git rev-parse --abbrev-ref HEAD`,
  Process, nil fuori da un repo). Poll in AppModel ogni ~10 tick (come templateSync) —
  MAI a render time (spawn di processo).
- `ServiceController.gitBranch: String?` aggiornato dal poller; card lo mostra accanto
  alla riga di stato. Warning (arancio) se diverso dal branch più comune tra i servizi
  dello stesso progetto.

## #6 Spia infra per progetto

- `AppModel.infraUp: [String: Bool]` (chiave = nome progetto) al posto del singolo
  `natsUp` (che resta come derivato per compatibilità: true se il PRIMO progetto con
  check è up — comportamento storico del fallback legacy).
- Poll: controlla la porta di OGNI `StoredProject.infraCheck`.
- Toolbar: l'indicatore mostra il check del progetto selezionato (pagina progetto);
  su Griglia/Focus mostra il primo check configurato (storico).
- `startProject` avvisa col check del SUO progetto.

## #9 Latenza health check

- `checkHealthEndpoints` ritorna `[HealthEndpoint: HealthProbeResult]` con `ok: Bool`
  e `latencyMs: Int?`.
- `ServiceController.healthLatencyMs: Int?`; pill sulla card accanto a CPU/RAM quando
  il servizio è running con probe httpHealth.

## #7 Crash loop

- `ServiceController` registra i timestamp dei crash (veri: exit ≠ 0 non richiesto);
  `isCrashLooping` = ≥3 crash negli ultimi 120s. Reset su start manuale riuscito
  (processo vivo oltre 30s) o stop utente.
- Card: label rossa "crash loop (N in 2 min)". Logica pura testabile
  (`CrashLoopDetector` con clock iniettabile).

## #3 Pannello errori globale

- `LogLine.receivedAt: Date` (timestamp di ingestione).
- Vista "Errori" in sidebar (sotto Focus): righe di errore di TUTTI i servizi,
  ordinate per tempo decrescente, con nome servizio, click → naviga al servizio.
  Derivata on-demand dai LogStore esistenti (nessun secondo buffer).

## #5 File env alternativo (profili env, non-invasivo)

- `StoredService.envFile: String?` (path assoluto, additivo). Allo spawn il launcher
  LEGGE il file (parser dotenv minimale: KEY=VALUE, commenti, virgolette) e INIETTA le
  variabili nell'ambiente del processo figlio — nessuna scrittura nei backend, il
  `.env` su disco resta intatto. Con dotenv/@nestjs/config standard le env di processo
  hanno precedenza sul file.
- Form: campo opzionale "File env alternativo" con picker. Template: campo NON
  esportato (path assoluti personali).
- `SpawnedProcess`: parametro `extraEnvironment: [String: String]` mergiato su
  `childEnvironment()`.

## #1 Ordine di avvio (dipendenze)

- `StoredService.startAfter: [String]?` (nomi di servizi dello stesso progetto,
  additivo; `versionRequired` → 2 se usato, come httpHealth).
- `StartOrchestrator` (logica pura, testabile): ordine topologico con rilevazione
  cicli (ciclo → errore mostrato, avvio piatto come fallback). L'avvio orchestrato
  parte a ondate: prima i servizi senza dipendenze, poi chi dipende SOLO da servizi
  già "ready" (status running) — attesa con timeout configurabile (default 90s a
  servizio; scaduto → il dipendente parte comunque, con riga di log launcher).
- `AppModel.startProject`/`startAll`/`start(profile:)` usano l'orchestratore quando
  almeno un servizio coinvolto ha `startAfter`, altrimenti percorso storico invariato.
- Form: sezione "Parte dopo" con toggle sugli altri servizi del progetto. Validazione
  store: nomi esistenti nel progetto, niente auto-dipendenza.

## Test

GitBranchTests (repo temp), AppModelTests (infraUp per progetto, orchestrazione con
processi fake), UpdateChecker-style Process fixture riusata, HealthProbe latenza,
CrashLoopDetectorTests (clock iniettato), LogStore receivedAt/aggregazione,
EnvFileParser (dotenv minimale), StartOrchestratorTests (topo-sort, cicli, ondate),
ServiceStore/Template round-trip campi nuovi.

## Fuori scope (esclusi dall'utente)

Comando di stop custom (#2), CLI companion (#8), auto-restart (#10).
