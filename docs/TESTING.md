# Guida al testing — Backend Launcher

Grazie per provare il launcher! Serve ~30 minuti. Segna ogni problema con lo
schema in fondo. Non serve essere gentili: più rompi, meglio è.

## Installazione (5 min)

1. `git clone git@github.com:Thairyne0/b-launcher.git && cd b-launcher && make install`
2. L'app si apre da sola → leggi la schermata di benvenuto
3. **Verifica**: icona nel Dock, icona nella barra menu in alto a destra

Per aggiornare nei giorni successivi: `make update` nel clone (oppure, quando
l'app ti mostra il toast "aggiornamenti disponibili": ⌘, → Aggiornamenti →
"Aggiorna e riavvia…").

Al primo avvio l'app è vuota: nessun progetto preconfigurato. La schermata di
benvenuto ti indirizza su "＋ Aggiungi progetto" — il percorso più rapido è
"Scansiona cartella…" sulla tua copia locale della repo.

## Scenari da testare

### 1. Onboarding (il tuo primo quarto d'ora, il più prezioso)
- [ ] Il benvenuto è chiaro? Sapevi cosa fare dopo averlo chiuso?
- [ ] Partendo da app vuota, sei arrivato da solo a un progetto funzionante (scansione o wizard)?
- [ ] Se un backend clonato non ha `.env`: badge ".env mancante" sulla card — incolla il contenuto (o parti dal precompilato `.env.example`) e verifica che il file venga creato e il backend parta.

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
- [ ] Conferme di sicurezza: "Avvia tutti"/"Ferma tutti"/"Ferma progetto" chiedono conferma; disattivale da ⌘, e verifica che agiscano subito

### 6. Novità recenti
- [ ] Sulla pagina di un progetto: "Avvia progetto" (bottone blu) avvia solo quel progetto, "Avvia tutti" tutto
- [ ] Backend con readiness "Health check HTTP" (porta + /health): diventa verde solo quando l'endpoint risponde 2xx?
- [ ] Scanner su repo Python/Spring/Laravel o con docker-compose: propone comandi sensati?
- [ ] Backend che non usa .env: toggle nel form → badge sparito?

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
