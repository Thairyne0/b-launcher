# Terminale interattivo (stdin) — v2

**Data:** 2026-07-06 · **Stato:** approvato in sessione · **Branch:** v2

Poter scrivere nello stdin del processo di un servizio dal terminale del launcher.
Scelta: **pipe stdin** (non PTY) — additivo, log puliti, basso rischio prima di
stabilizzare main. Il PTY vero (isatty, tasti raw, hot-reload Flutter, TUI) resta a
v3, dove arriva anche gratis via i terminali PTY dell'estensione VSCode.

## SpawnedProcess

- Nuova pipe stdin: `pipe()` → `readFD` duplicato su fd 0 del figlio
  (`posix_spawn_file_actions_adddup2(readFD, 0)`), `writeFD` tenuto dal padre.
  Entrambi gli estremi non usati chiusi come per la pipe di output.
- `func sendInput(_ text: String)`: scrive i byte UTF-8 su `writeFD` (thread-safe via
  lock, best-effort; EPIPE ignorato se il figlio ha chiuso stdin). Il chiamante
  aggiunge `\n` se vuole "inviare una riga".
- `terminate`: chiude `writeFD` (EOF su stdin del figlio) oltre al kill del group.
- stdout/stderr invariati → nessun impatto sul log-viewer.

## ServiceController

- `func sendInput(_ line: String)`: inoltra `line + "\n"` a `process?.sendInput`, e
  inietta nei log una riga-eco `❯ <line>` (livello normale) — senza PTY non c'è eco
  naturale, così l'utente vede cosa ha mandato. No-op se il processo non è vivo.

## UI (TerminalView)

- Barra input in fondo al terminale espanso, visibile solo se `processAlive`:
  TextField monospace con hint "❯", invio = manda (svuota il campo).
- Storico comandi per servizio (in memoria sul controller): ↑/↓ scorrono i comandi
  inviati.
- Nota UI (help/testo): funziona coi programmi che leggono righe da stdin; molti
  backend (NestJS) lo ignorano.

## Test

- `SpawnedProcess`: comando `cat` → `sendInput("ciao")` → "ciao" ricompare su stdout
  (e2e via waitUntil).
- `ServiceController`: `sendInput` appende la riga-eco `❯ ...`; no-op se non vivo.
- Storico: invii successivi accumulano, ↑/↓ testati sulla logica pura del cursore.

## Fuori scope (→ v3)

PTY vero, tasti raw / SIGINT via terminale, hot-reload Flutter da qui, TUI,
emulatore xterm embedded.
