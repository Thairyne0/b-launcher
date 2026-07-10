# Backend Launcher

Launcher macOS nativo (SwiftUI, Liquid Glass) per avviare, fermare e monitorare i
backend di sviluppo di **qualsiasi progetto**, con supporto a **più progetti**
contemporaneamente. Non più legato a un unico set di servizi hardcoded: progetti e
backend si definiscono dalla UI e vivono su disco.

## Requisiti

- macOS 26 (Tahoe)
- Xcode 26 per compilare
- I comandi dei backend girano tramite `zsh` come login shell (`zsh -l`) con
  sourcing di `~/.zshrc` se presente: PATH come nel tuo terminale (Homebrew,
  nvm, pyenv…)

## Installazione (per il team)

```bash
git clone git@github.com:Thairyne0/b-launcher.git
cd b-launcher
make install
```

`make install` compila l'app e la copia in `/Applications`, poi la apre. La build
è locale → nessun problema di Gatekeeper/quarantena. Al primo avvio la schermata
di benvenuto spiega come configurare i tuoi progetti (wizard, import template, o
generazione automatica con Claude Code).

Per aggiornare: **`make update`** nel clone — chiude l'app, fa `git pull
--ff-only`, ricompila e reinstalla. In alternativa l'app stessa ti avvisa: al
lancio controlla il clone da cui è stata buildata e mostra un toast se ci sono
commit nuovi; da Impostazioni (⌘,) → Aggiornamenti puoi controllare a mano e
lanciare "Aggiorna e riavvia…" (apre Terminale ed esegue `make update`).

## Uso (sviluppo)

```bash
make run     # builda dist/Backend Launcher.app e la apre
make install # builda e installa in /Applications
make dev     # build + run veloce senza bundle (swift run)
make test    # unit test
make app     # builda solo il bundle .app
make clean   # rimuove .build e dist
```

## Concetti

- **Progetti → servizi**: un progetto raggruppa uno o più backend (servizi). Ogni
  servizio ha una working directory, un comando di avvio e una regola di
  "prontezza" (readiness).
- **Sidebar**: click sul nome del progetto seleziona la griglia filtrata su quel
  progetto; il chevron a fianco espande/comprime il dropdown coi singoli servizi
  (le due azioni sono indipendenti, non si "rubano" il tap a vicenda).
- **Viste**: griglia (tutti i servizi o quelli di un progetto), **Focus**
  (terminali grandi affiancati per un sottoinsieme di servizi scelto dall'utente,
  con chip di selezione), e vista a singolo servizio (deep-link da notifica di
  crash o da scorciatoia).

## Wizard progetti e backend

Il menu **"＋ Aggiungi progetto"** in fondo alla sidebar propone quattro vie:

- **Nuovo progetto** (⌘N): crea un progetto vuoto (nome univoco, non
  case-sensitive), poi aggiungi i backend a mano.
- **Scansiona cartella…** (⌘⇧N): analizza una cartella esistente (monorepo o
  singolo repo) e propone i backend riconosciuti — vedi "Scanner progetti"
  sotto.
- **Importa progetto…** (⌘⇧I): importa un template `.blauncher.json` esportato
  da un collega — vedi "Import/export progetti".
- **Genera con Claude Code…** (⌘⇧G): copia negli appunti un prompt pronto per
  far generare il template a Claude Code.

Puoi anche **trascinare** una cartella o un file `.blauncher.json` sulla
finestra principale: una cartella avvia la stessa scansione di "Scansiona
cartella…", un file `.json` precarica l'import.

- **+ Aggiungi backend**: cartella di lavoro, comando di avvio, e tipo di
  readiness:
  - **Porta TCP**: pronto quando la porta indicata risulta aperta;
  - **Marker nei log**: pronto quando una stringa specifica compare nell'output;
  - **Sempre pronto (processo vivo)**: pronto non appena il processo parte;
  - **Health check HTTP**: pronto quando `GET http://127.0.0.1:porta+path`
    (es. `/health`) risponde 2xx — più preciso della sola porta per backend che
    aprono il socket prima di essere davvero operativi. I redirect non contano
    come pronto.
  - Se il comando contiene "docker", un avviso ricorda che il launcher non
    ferma i container (vedi "Limitazione Docker" sotto).
  - Toggle "questo backend non usa un file .env" per nascondere il badge
    ".env mancante" sugli stack che configurano altrove (Go a flag, Java con
    application.properties, ecc.).
- **Modifica…** / **Elimina** su un servizio: tasto destro sulla riga in sidebar
  (modifica disabilitata mentre il servizio è in esecuzione). Stesso schema per i
  progetti (**Elimina progetto** da tasto destro sulla riga progetto).
- **Scanner progetti**: `Scansiona cartella…` riconosce i backend di un monorepo
  (o repo singolo) e propone nome, comando e readiness già compilati, con la
  possibilità di includere/escludere ogni backend e la spia infrastruttura
  suggerita (da `docker-compose.yml`) prima di creare il progetto. Stack
  riconosciuti: Node/NestJS (`package.json`, npm/yarn/pnpm), Go (`go.mod`),
  Rust (`Cargo.toml`), Python (Django via `manage.py`, FastAPI via uvicorn,
  Flask, `main.py` generico), Java Spring Boot (`pom.xml`/`build.gradle`, con
  preferenza per `mvnw`/`gradlew`), PHP (Laravel via `artisan`, server built-in
  con `index.php`) e i servizi di un `docker-compose.yml` (esclusa
  l'infrastruttura tipo nats/redis/postgres, che resta alla spia infra). Se due backend risultano sulla stessa porta, il secondo
  viene automaticamente declassato a un altro criterio di prontezza invece di
  lasciare un conflitto — rivedibile dopo con "Modifica…".

## Import/export progetti (template)

- **Esporta progetto…**: salva un file `.blauncher.json` con le cartelle dei
  backend rese **relative a una root** scelta all'export (di norma l'antenato
  comune delle directory dei servizi), così il template non contiene path
  assoluti legati alla macchina di chi esporta. Servizi fuori dalla root scelta
  vengono preservati come path assoluto (prefisso `abs:`), esplicitamente.
- **Importa progetto…**: si sceglie il file, poi la cartella del progetto **sul
  Mac di destinazione**; i path relativi vengono ricalcolati (rebase) su quella
  root, con eventuale rinomina in caso di conflitto col nome di un progetto già
  esistente.
- **Nota di sicurezza**: un path relativo che contiene una componente `..` viene
  **rifiutato** in import — un template non può risolvere directory al di fuori
  della root scelta dall'utente.
- **Deep link `blauncher://import`**: `open "blauncher://import?file=<percorso
  assoluto .blauncher.json>&root=<percorso assoluto repo>"` (parametro `root`
  opzionale) apre direttamente `Importa progetto…` precompilato — è il comando
  "un click" che il prompt di generazione con Claude Code suggerisce di
  stampare a fine analisi. Se l'app è già in esecuzione, riusa la stessa
  finestra invece di aprirne una nuova.
- **Sincronizza (template del team)**: se un progetto è stato importato da un
  file `.blauncher.json` tracciato e quel file cambia su disco (es. dopo un
  `git pull` che porta una revisione aggiornata da un collega), un banner
  "Il template del progetto è cambiato" appare sopra la griglia del progetto.
  "Sincronizza" rilegge il file e sostituisce backend/profili/spia
  infrastruttura, preservando nome e colore del progetto; i backend in
  esecuzione non vengono fermati — le loro modifiche si applicano al prossimo
  riavvio.

## Terminali

Ogni servizio ha un pannello di log (terminale) con:

- **Terminale interattivo**: sotto il terminale di un servizio in esecuzione una
  barra di input manda righe allo **stdin** del processo (↑/↓ storico comandi);
  ciò che invii compare come «❯ …» nei log. Funziona coi programmi che leggono
  righe da stdin (prompt, alcuni dev-server); NestJS & co. lo ignorano. Terminale
  reale con tasti raw / hot-reload (PTY) previsto per una versione futura.
- **Colori ANSI veri**: il launcher chiede ai logger di emettere i colori anche
  su pipe (`FORCE_COLOR`/`CLICOLOR_FORCE`) e renderizza gli escape SGR (16
  colori + bold) — i log NestJS/npm/uvicorn appaiono colorati come in un
  terminale vero. Copia e ricerca lavorano sul testo pulito.
- **Colori per livello**: normale, debug, warning, errore, classificati riga per
  riga dall'output.
- **Filtro**: Tutti / Warn+ / Errori (segmented control).
- **Ricerca** con contatore posizione/totale (es. "2/7") e frecce match
  precedente/successivo.
- **Modalità Evidenzia**: alternativa al filtro classico — tiene tutte le righe
  visibili ed evidenzia solo i match, invece di nascondere le righe che non
  corrispondono.
- **Selezione nativa multi-riga** (NSTextView) con menu contestuale: **Copia
  riga**, **Copia blocco errore** (la riga di errore più le righe di stack trace
  successive), oltre al pulsante **Copia log visibile** in toolbar.
- **Autoscroll intelligente**, disattivabile, e conteggio errori con badge che
  porta direttamente al filtro Errori.

## Stati di un servizio

Derivati da fatti osservabili, nessuna macchina a stati nascosta:

- ⚪️ fermo · 🟡 avvio… · 🟢 in esecuzione · 🟠 arresto…
- 🔴 crash (con exit code) · 🔵 attivo fuori dal launcher (porta occupata da un
  processo esterno: avvio disabilitato). La card mostra anche **chi** occupa la
  porta (comando + pid, via `lsof`), così sai cosa fermare.

Oltre allo stato: badge conteggio errori sulla card, metriche **CPU% / RAM (MB)**
del process group mentre è in esecuzione, **branch git** della cartella (arancio
se diverso dagli altri backend del progetto — worktree dimenticato), **latenza**
del health check per i servizi con probe HTTP, rilevazione **crash loop** (≥3
crash in 2 minuti → label rossa; uno stop manuale azzera il conteggio), e
indicatore **"cartella mancante"** se la working directory non esiste più su
disco (avvio disabilitato finché non torna disponibile).

- **Pannello Errori**: voce "Errori" in sidebar (badge col totale) con le righe
  di errore di tutti i backend in un'unica lista ordinata per tempo — per il
  debugging a cascata; click su una riga → terminale del servizio. Gli errori
  identici dello stesso backend (stesso messaggio dal marker ERROR/FATAL in
  poi, così pid/timestamp nel testo non contano) sono raggruppati in una riga
  con "×N" e il timestamp dell'occorrenza più recente.
- **Ordine di avvio**: per ogni backend puoi dichiarare "parte dopo" altri
  backend del progetto; l'avvio di progetto/profili procede a ondate,
  attendendo che l'ondata precedente sia verde (timeout 90 s a ondata, poi si
  procede comunque; cicli → avvio piatto con avviso nei log).
- **File env alternativo**: per backend puoi scegliere un file (es.
  `.env.staging`) le cui variabili vengono iniettate nell'ambiente del processo
  all'avvio, vincendo su quelle del `.env` — il `.env` su disco non viene mai
  toccato.
- **Spia infrastruttura per progetto**: ogni progetto ha la sua (l'indicatore
  in toolbar segue il progetto selezionato) e il warning d'avvio usa la spia
  del progetto giusto.

## Full-stack e frontend (v2)

Il frontend è un servizio come gli altri: Next/Vite (`npm run dev`), Flutter
(`flutter run`, riconosciuto dallo scanner via `pubspec.yaml`), Expo, Electron —
qualsiasi comando.

- **App principale + "Avvia stack"**: marca il frontend come "app principale"
  nel form; sulla pagina del progetto il bottone prominente diventa **Avvia
  stack**: backend a ondate (rispettando "parte dopo"), app per ultima a stack
  pronto, poi browser sull'URL app (se web) e notifica "Stack pronto". App
  native (Flutter/Electron): l'app compare da sé sul device/finestra.
- **URL app**: campo opzionale per servizio → bottone "apri nel browser" sulla
  card (vale anche per la doc API di un backend).
- **Varianti di comando**: comandi alternativi one-shot per servizio
  (es. `flutter run -d iphone` / `-d chrome`, o uno script di debug) nel menu
  contestuale della card, "Avvia con…" — il comando di default resta invariato.
- **Task (comandi one-shot)**: per servizio puoi definire comandi ausiliari
  (es. `npx prisma generate`, migrazioni, seed) come "Nome = comando" nel form;
  compaiono nel menu "Esegui" della card e girano nella cartella del backend
  (output nel suo terminale), senza avviarlo. Disponibili anche nell'estensione
  VSCode (girano in un terminale dedicato).
- Nota Flutter: il terminale del launcher è una pipe senza stdin → niente hot
  reload interattivo da qui; il ciclo di sviluppo resta nell'IDE. Il valore è
  lo stack: un click e tutti i backend sono su e verdi.

- **Badge ".env mancante"**: se la cartella del servizio esiste ma non contiene
  `.env` (tipico backend appena clonato), la card mostra un badge cliccabile —
  e la sidebar un'icona 🔑 accanto al backend — che apre uno sheet: incolli il
  contenuto ricevuto da un collega (o lo importi da file) e il launcher crea
  `working directory/.env` per te. Se il backend ha un `.env.example` (o
  `.env.sample`/`.env.template`/`.env.dist`), l'editor parte precompilato da
  quello. Il badge si può disattivare per singolo backend dal form di modifica. Sicurezza: verifica
  che `.env` sia coperto dal `.gitignore` (altrimenti avvisa e chiede conferma
  esplicita), non sovrascrive mai un file esistente (creazione atomica), permessi
  `0600`, e il contenuto incollato non finisce mai nei log o nelle impostazioni
  del launcher.

## Extra

- **Menu bar**: icona con stato aggregato di tutti i servizi (pieno/mezzo
  pieno/vuoto/errore). I servizi sono raggruppati per progetto in un submenu con
  Avvia/Ferma **di quel progetto**; più le azioni globali Avvia/Ferma/Riavvia
  tutti, tutto senza aprire la finestra principale.
- **Notifiche di crash**: notifica locale macOS al crash di un backend; il tap
  attiva l'app e apre direttamente il servizio interessato (deep-link).
- **Palette comandi (⌘K)**: cerca e lancia qualunque azione (vai a un servizio,
  avvia/ferma/riavvia, apri Aiuto, avvia un progetto…) senza staccare le mani
  dalla tastiera.
- **Scorciatoie da tastiera**: ⌘K (palette comandi), ⌘E (espandi/comprimi tutti
  i terminali), ⌘1–⌘9 (apri/chiudi il terminale dei primi 9 servizi), ⌘⇧A
  (avvia tutti), ⌘⇧S (ferma tutti, con conferma), ⌘⇧R (riavvia tutti), ⌘N
  (nuovo progetto), ⌘⇧N (scansiona cartella…), ⌘⇧I (importa progetto…), ⌘⇧G
  (genera con Claude Code…), ⌘0 (apri il launcher dal menu della barra dei
  menu), ⌘= / ⌘− (aumenta/riduci il testo del terminale).
- **Aspetto**: Sistema / Chiaro / Scuro, forzabile dalle Impostazioni (⌘,)
  indipendentemente dall'aspetto di sistema.
- **Profili di avvio**: sottoinsiemi di servizi avviabili con un click, definiti
  per progetto (menu "Profili" in toolbar, con submenu per progetto se ce n'è
  più di uno).
- **Log su file**: ogni servizio scrive anche su
  `~/Library/Logs/BackendLauncher/<nome>.log`, con rotazione a 5MB (il file
  corrente viene rinominato in `.old` e se ne ricomincia uno nuovo).
- **Conferme di sicurezza**: "Avvia tutti", "Ferma tutti" e "Ferma progetto"
  (toolbar) chiedono conferma prima di agire in massa; ogni popup è
  disattivabile singolarmente dalle Impostazioni (⌘,), sezione "Conferme di
  sicurezza". Anche chiudere l'app con backend attivi chiede conferma; lo stop è
  pulito su tutto il process group (SIGTERM → attesa → SIGKILL), niente processi
  orfani. Chiudere la finestra non termina l'app finché la menu bar extra resta
  attiva.
- **Avvio/stop per progetto dalla toolbar**: sulla pagina di un progetto il
  bottone prominente è "Avvia progetto" (solo i suoi backend), affiancato da
  "Avvia tutti"; stesso sdoppiamento per "Ferma progetto" / "Ferma tutti".
- **Limitazione Docker**: il launcher ferma solo il comando lanciato (es.
  `docker compose up`), non i container Docker che quel comando avvia — prevedi
  uno stop manuale (`docker compose down`). Il form di un backend mostra un
  avviso quando il comando contiene "docker".
- **Comandi ed ambiente**: comandi composti (`&&`, `;`, `|`, …) sono supportati
  come su un terminale normale; nvm/pyenv/conda funzionano perché la shell di
  lancio sorge anche `~/.zshrc` (vedi Requisiti); l'output dei servizi Python
  non resta bufferizzato (`PYTHONUNBUFFERED=1` impostato automaticamente se non
  già presente).

## Configurazione

Progetti e servizi sono persistiti in
`~/Library/Application Support/BackendLauncher/services.json`, con un campo
`version` nello schema. Al primo avvio senza file su disco l'app parte vuota:
zero progetti, si comincia dalla schermata di benvenuto e da "＋ Aggiungi
progetto" (wizard, scansione cartella, import template o Claude Code). Il file
dichiara la versione minima necessaria a leggerlo (resta v1 finché non usi
feature v2 come il health check HTTP o le dipendenze di avvio). Un file scritto da una versione futura
dell'app viene preservato as-is (rinominato `.futureversion`) invece di essere
sovrascritto.

## Rollback

Checkpoint pre-riscrittura disponibile come tag git `checkpoint-launcher-v1` e
come archivio in `checkpoints/` (zip dell'app v1 buildata).
