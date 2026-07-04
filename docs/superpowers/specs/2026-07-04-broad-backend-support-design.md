# Supporto backend più ampio: scanner esteso, .env.example, opt-out badge, health HTTP

**Data:** 2026-07-04 · **Stato:** approvato in sessione ("fai tutti i punti tranne il 5")

Quattro feature indipendenti che allargano la platea di backend supportati.

## 1. Scanner esteso (Python, Java/Spring, PHP, docker-compose)

`ProjectScanner.scanService` oggi riconosce package.json / go.mod / Cargo.toml.
Nuovi rilevamenti, sempre deterministici (nessuna AI, solo convenzioni):

- **Python**: `manage.py` → `python manage.py runserver` (Django). Altrimenti
  `pyproject.toml`/`requirements.txt`: contiene "fastapi" → `uvicorn main:app --reload`;
  contiene "flask" → `flask run`; altrimenti `python main.py` solo se `main.py` esiste.
- **Java/Spring**: `pom.xml` contenente "spring-boot" → `./mvnw spring-boot:run` se `mvnw`
  esiste, altrimenti `mvn spring-boot:run`. `build.gradle`/`build.gradle.kts` contenente
  "spring" → `./gradlew bootRun` se `gradlew` esiste, altrimenti `gradle bootRun`.
  Java non-Spring: nessun rilevamento (una lib non è un backend avviabile).
- **PHP**: `artisan` → `php artisan serve` con porta 8000 (default Laravel). Altrimenti
  `composer.json` + `index.php` → `php -S localhost:8080` con porta 8080.
- **docker-compose (servizi)**: parsing line-based dei compose file già enumerati da
  `scanComposeInfra`: nomi dei servizi top-level, prima porta host da `ports:`. Ogni
  servizio diventa `docker compose [-f <file>] up <nome>` nella root. ESCLUSI i servizi
  infra (nome o image contenente nats/redis/postgres/mongo/rabbitmq): quelli restano
  appannaggio della spia infrastruttura. `-f` solo per file non-default (default:
  docker-compose.yml/.yaml, compose.yml/.yaml).

Precedenza per directory invariata: package.json > go.mod > Cargo.toml > Python > Java >
PHP. La readiness resta: porta da `.env` se trovata (o porta nota PHP), altrimenti
processAlive (log marker resta solo NestJS).

## 2. Prefill da `.env.example`

`EnvFileWriter.exampleContent(in:)`: primo file esistente tra `.env.example`,
`.env.sample`, `.env.template`, `.env.dist` (≤ 1 MB, UTF-8 o Latin-1) → contenuto.
`EnvCreateSheet` lo carica nell'editor all'apertura (solo se l'editor è vuoto) con nota
"Precompilato da <nome>: sostituisci i valori". Sola lettura del backend: vincolo
non-invasivo intatto.

## 3. Opt-out badge .env per servizio

- `StoredService.envBadgeDisabled: Bool?` (nil = false, additivo: file vecchi decodificano).
- `ServiceConfig.envBadgeDisabled: Bool = false` (default su tutti gli init esistenti).
- Toggle nel `ServiceFormSheet`: "Questo backend non usa un file .env".
- Badge card e icona sidebar: mostrati solo se `!envBadgeDisabled`.
- `ProjectTemplate.TemplateService.envBadgeDisabled: Bool?` additivo — le app vecchie
  ignorano la chiave sconosciuta (nessun bump di versione template necessario).

## 4. Readiness "Health check HTTP"

- `StoredReadiness.Kind.httpHealth` + campo additivo `path: String?`.
- `ReadinessProbe.httpHealth(port: UInt16, path: String)`.
- `ServiceController.healthOK` (aggiornato dal poller come `portOpen`); `status` usa
  `healthOK` come segnale ready per questo probe. Derive invariata → "external" funziona
  anche qui (health OK senza processo nostro = processo esterno).
- Poll in `AppModel`: GET `http://127.0.0.1:<port><path>` con timeout corto fuori dal
  MainActor; 2xx = pronto. Redirect NON seguiti (un 3xx verso una pagina di login non è
  "pronto").
- Form: picker prontezza passa a menu (4 opzioni non stanno più in un segmented), campi
  porta + path (default `/health`).
- **Versioning al minimo richiesto**: `services.json` e template restano versione 1 se
  nessun servizio usa `httpHealth`; se almeno uno lo usa, scrivono versione 2. Le app
  vecchie (currentVersion 1) incontrano la 2 e scattano i percorsi già esistenti:
  `.futureversion` per lo store, errore chiaro per il template. Downgrade mai distruttivo.

## Test

Estensioni di ProjectScannerTests (per stack + compose), EnvFileWriterTests
(exampleContent), ServiceStoreTests (round-trip envBadgeDisabled e httpHealth, versione
minima richiesta), ProjectTemplateTests (idem), ServiceControllerTests (status con
healthOK), AppModelTests (probe HTTP contro listener locale di test).

## Fuori scope

- Auto-restart su crash (escluso dall'utente).
- Stop dei container Docker (`docker compose down`) — limitazione documentata, invariata.
- Parser YAML completo per compose (line-based sufficiente per i layout convenzionali).
