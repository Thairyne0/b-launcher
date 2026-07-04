# Badge ".env mancante" + creazione guidata del file .env

**Data:** 2026-07-04 · **Stato:** approvato (direzione validata in sessione con l'utente)

## Problema

Quando si clona un backend in locale il file `.env` non c'è (è gitignorato): il servizio
non parte finché il dev non lo crea a mano, tipicamente incollando il contenuto ricevuto
da un collega. Il launcher oggi non segnala la mancanza né aiuta a rimediare.

## Soluzione

1. **Badge**: sulla card del servizio compare un badge cliccabile ".env mancante" quando
   la working directory esiste ma non contiene `.env`.
2. **Sheet**: il click apre uno sheet dove l'utente incolla il contenuto (TextEditor) o
   importa un file esistente (NSOpenPanel, il contenuto viene caricato nell'editor per
   revisione). Il launcher mostra quante variabili `KEY=` rileva e lo stato `.gitignore`.
3. **Creazione**: il launcher crea `workingDirectory/.env` con il contenuto fornito.
   Toast di conferma, il badge sparisce al re-render.

## Rilevamento

Render-time, stesso pattern di `directoryIsMissing` in `ServiceCardView`: una `stat` per
redraw, nessuno stato in `AppModel`, la UI si riallinea da sola. Condizione badge:
`directory esiste && .env assente`.

## Sicurezza (vincolante)

1. **Check `.gitignore`**: prima di scrivere, `git -C <dir> check-ignore -q .env`.
   - exit 0 → coperto: ok.
   - exit 1 → NON coperto: warning esplicito (rischio commit dei segreti) e bottone
     "Crea" disabilitato finché l'utente non conferma con un toggle dedicato.
   - repo assente (exit 128) → nessun rischio VCS: ok, nota informativa.
   - git non disponibile/errore → warning + stesso toggle di conferma.
   - Il launcher NON modifica mai il `.gitignore` del backend (vincolo non-invasivo).
2. **Mai sovrascrivere**: creazione atomica `open(O_CREAT|O_EXCL|O_NOFOLLOW, 0600)`.
   Se il file esiste (anche come symlink) la syscall fallisce con EEXIST: nessun
   check-then-write, nessuna race.
3. **Permessi 0600**: leggibile solo dall'utente.
4. **Nessuna persistenza del contenuto**: il testo incollato vive solo nello stato dello
   sheet e nel file finale. Mai in log, `services.json`, UserDefaults, toast o error message.
5. **Nome e percorso fissi**: sempre `.env` dentro `workingDirectory` del servizio;
   l'utente non sceglie né nome né destinazione (zero path traversal).

## Vincolo non-invasivo

Eccezione registrata in memoria (2026-07-04): la creazione di `.env` è ammessa perché
locale, gitignorata (verificata), su azione esplicita dell'utente, mai in sovrascrittura.
Il repo del team resta intatto.

## Componenti

- `Managers/EnvFileWriter.swift` — logica pura/testabile:
  - `envFileExists(in:) -> Bool`
  - `gitIgnoreStatus(for:) -> GitIgnoreStatus` (`.ignored | .notIgnored | .noRepo | .unknown`)
  - `createEnvFile(in:content:) throws` (errori tipizzati: `alreadyExists`,
    `directoryMissing`, `writeFailed(errno)`)
  - `envKeyCount(_:) -> Int` (righe `KEY=` valide, ignora commenti/vuote, `export` ammesso)
- `Views/EnvCreateSheet.swift` — sheet incolla/importa/crea, copy in italiano.
- `Views/ServiceCardView.swift` — badge cliccabile sotto la riga di stato + presentazione sheet.

## Gestione errori

- `.env` compare tra apertura sheet e "Crea" → EEXIST → messaggio "esiste già" e chiusura
  (il badge sparisce da solo).
- Directory sparita nel frattempo → messaggio, nessuna creazione di directory intermedie.
- File importato illeggibile/non-UTF8/troppo grande (>1 MB) → messaggio, editor invariato.

## Test

`EnvFileWriterTests`: creazione con contenuto esatto e permessi 0600; EEXIST su file
esistente (contenuto originale intatto); EEXIST su symlink preesistente; directory
mancante; `gitIgnoreStatus` su repo con/senza `.gitignore` e su cartella non-repo;
`envKeyCount` (commenti, vuote, export, righe malformate).

## Fuori scope

- Modifica del `.gitignore` del backend (violerebbe il vincolo non-invasivo).
- Validazione semantica del contenuto (il launcher scrive byte, non interpreta).
- Badge in FocusView/Sidebar (solo card dashboard, la "voce" principale del servizio).
- Rilevare se il backend *richiede* davvero un `.env` (heuristics su package.json): il
  badge è informativo, costo di un falso positivo trascurabile.
