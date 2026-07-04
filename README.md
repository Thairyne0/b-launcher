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
generazione automatica con Claude Code). Per aggiornare: `git pull && make install`.

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
  - **Sempre pronto (processo vivo)**: pronto non appena il processo parte.
  - Se il comando contiene "docker", un avviso ricorda che il launcher non
    ferma i container (vedi "Limitazione Docker" sotto).
- **Modifica…** / **Elimina** su un servizio: tasto destro sulla riga in sidebar
  (modifica disabilitata mentre il servizio è in esecuzione). Stesso schema per i
  progetti (**Elimina progetto** da tasto destro sulla riga progetto).
- **Scanner progetti**: `Scansiona cartella…` riconosce i backend Node/NestJS di
  un monorepo (o repo singolo) leggendo `package.json` e propone nome, comando e
  readiness già compilati, con la possibilità di includere/escludere ogni
  backend e la spia infrastruttura suggerita (da `docker-compose.yml`) prima di
  creare il progetto. Se due backend risultano sulla stessa porta, il secondo
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
  processo esterno: avvio disabilitato)

Oltre allo stato: badge conteggio errori sulla card, metriche **CPU% / RAM (MB)**
del process group mentre è in esecuzione, e indicatore **"cartella mancante"**
se la working directory non esiste più su disco (avvio disabilitato finché non
torna disponibile).

- **Badge ".env mancante"**: se la cartella del servizio esiste ma non contiene
  `.env` (tipico backend appena clonato), la card mostra un badge cliccabile che
  apre uno sheet: incolli il contenuto ricevuto da un collega (o lo importi da
  file) e il launcher crea `working directory/.env` per te. Sicurezza: verifica
  che `.env` sia coperto dal `.gitignore` (altrimenti avvisa e chiede conferma
  esplicita), non sovrascrive mai un file esistente (creazione atomica), permessi
  `0600`, e il contenuto incollato non finisce mai nei log o nelle impostazioni
  del launcher.

## Extra

- **Menu bar**: icona con stato aggregato di tutti i servizi (pieno/mezzo
  pieno/vuoto/errore), più un elenco testuale per servizio e azioni rapide
  Avvia/Ferma tutti senza aprire la finestra principale.
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
- **Conferma quit / ferma-tutti**: chiudere l'app o premere "Ferma tutti" con
  backend attivi chiede conferma; lo stop è pulito su tutto il process group
  (SIGTERM → attesa → SIGKILL), niente processi orfani. Chiudere la finestra non
  termina l'app finché la menu bar extra resta attiva.
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
`version` nello schema. Al primo avvio senza file su disco, l'app migra
automaticamente la vecchia configurazione hardcoded v1 (i sei backend Skillera)
in un progetto. Un file scritto da una versione futura dell'app viene preservato
as-is (rinominato `.futureversion`) invece di essere sovrascritto.

## Rollback

Checkpoint pre-riscrittura disponibile come tag git `checkpoint-launcher-v1` e
come archivio in `checkpoints/` (zip dell'app v1 buildata).
