# Guida al testing — Backend Launcher

Grazie per provare il launcher! Serve ~30 minuti. Segna ogni problema con lo
schema in fondo. Non serve essere gentili: più rompi, meglio è.

## Installazione (5 min)

1. `git clone git@github.com:Thairyne0/b-launcher.git && cd b-launcher && make install`
2. L'app si apre da sola → leggi la schermata di benvenuto
3. **Verifica**: icona nel Dock, icona nella barra menu in alto a destra

Al primo avvio troverai un progetto "Skillera" con percorsi che sul tuo Mac non
esistono: è il progetto di esempio migrato. Il banner arancione ti offre due
uscite — provale entrambe nei test sotto.

## Scenari da testare

### 1. Onboarding (il tuo primo quarto d'ora, il più prezioso)
- [ ] Il benvenuto è chiaro? Sapevi cosa fare dopo averlo chiuso?
- [ ] Progetto Skillera rotto: hai capito da solo come sistemarlo o eliminarlo?
- [ ] "Cambia cartella radice…" puntando alla tua copia di SkillLocale: i 6 backend si sistemano tutti?

### 2. Il tuo progetto reale
- [ ] "＋ Aggiungi progetto → Scansiona cartella…" sulla tua repo: trova i backend giusti? Porte giuste?
- [ ] Trascina una cartella sulla finestra: parte la scansione?
- [ ] "Genera con Claude Code…": incolla il prompt in Claude Code dentro una repo, fatti generare il template, importalo (prova anche il link `blauncher://` che ti stampa)

### 3. Vita quotidiana
- [ ] Avvia tutti / singolo backend: pallini giallo→verde credibili?
- [ ] Terminale: cerca un errore, filtra "Errori", copia un blocco errore col tasto destro, incollalo da qualche parte
- [ ] ⌘K: salta a un backend digitando 3 lettere
- [ ] Ferma tutto ed esci (Cmd-Q): controlla con `ps aux | grep node` che non resti nulla di orfano

### 4. Cattiverie (dove ci aspettiamo i bug)
- [ ] Backend con comando composto (`export FOO=1 && npm run dev`)
- [ ] Backend Python (Flask/FastAPI): i log scorrono? diventa verde?
- [ ] Node via **nvm**: parte?
- [ ] Spegni la rete / il broker del progetto: la spia infra diventa rossa?
- [ ] Ammazza un backend da fuori (`kill -9 <pid del node>`): arriva la notifica? il click ti porta al punto giusto?
- [ ] Avvia un backend da terminale FUORI dal launcher: la card diventa blu "esterno"?

### 5. Impostazioni & tema
- [ ] ⌘, → cambia Aspetto (Chiaro/Scuro): tutto leggibile in entrambi?
- [ ] ⌘= / ⌘− nel terminale

## Come segnalare

Per ogni problema, un messaggio così:

```
COSA: (una riga: cosa non va)
DOVE: (vista/azione — es. "import template", "card gateway")
PASSI: (come riprodurlo)
ATTESO vs VISTO:
LOG: (se c'entra un backend: tasto destro sul backend → Apri log nel Finder, allega)
```

Screenshot benvenuti. Anche le impressioni "mi aspettavo che…" valgono oro.
