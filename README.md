# Backend Launcher

Launcher macOS nativo (SwiftUI, Liquid Glass) per avviare, fermare e monitorare i
backend di sviluppo di **qualsiasi progetto**, con supporto a **più progetti**
contemporaneamente. Non più legato a un unico set di servizi hardcoded: progetti e
backend si definiscono dalla UI e vivono su disco.

## Requisiti

- macOS 26 (Tahoe)
- Xcode 26 per compilare
- I comandi dei backend girano tramite `zsh` come login shell (`zsh -l`), così
  risolvono lo stesso `PATH` di un terminale interattivo (es. `npm` installato via
  Homebrew)

## Uso

```bash
make run     # builda dist/Backend Launcher.app e la apre
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

- **+ Nuovo progetto**: crea un progetto vuoto (nome univoco, non case-sensitive).
- **+ Aggiungi backend**: cartella di lavoro, comando di avvio, e tipo di
  readiness:
  - **Porta TCP**: pronto quando la porta indicata risulta aperta;
  - **Marker nei log**: pronto quando una stringa specifica compare nell'output;
  - **Sempre pronto (processo vivo)**: pronto non appena il processo parte.
- **Modifica…** / **Elimina** su un servizio: tasto destro sulla riga in sidebar
  (modifica disabilitata mentre il servizio è in esecuzione). Stesso schema per i
  progetti (**Elimina progetto** da tasto destro sulla riga progetto).

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

## Extra

- **Menu bar**: icona con stato aggregato di tutti i servizi (pieno/mezzo
  pieno/vuoto/errore), più un elenco testuale per servizio e azioni rapide
  Avvia/Ferma tutti senza aprire la finestra principale.
- **Notifiche di crash**: notifica locale macOS al crash di un backend; il tap
  attiva l'app e apre direttamente il servizio interessato (deep-link).
- **Scorciatoie da tastiera**: ⌘E (espandi/comprimi tutti i terminali), ⌘1–⌘9
  (apri/chiudi il terminale dei primi 9 servizi), ⌘⇧A (avvia tutti), ⌘⇧S (ferma
  tutti, con conferma).
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
