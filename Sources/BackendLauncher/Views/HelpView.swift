import SwiftUI

/// Un singolo blocco di contenuto dentro una sezione di aiuto: o un paragrafo di testo libero,
/// o un elenco puntato. Tenuto come dato (non stringhe pre-formattate) così il layout
/// (spaziatura, indentazione bullet) resta responsabilità della vista, non del contenuto.
enum HelpContentBlock {
    case paragraph(String)
    case bullets([String])
    /// Sotto-titolo dentro una sezione (es. "Stati e colori" dentro "Concetti chiave").
    case subheading(String)
}

/// Una sezione dell'aiuto: titolo mostrato nella lista a sinistra + corpo dettagliato a destra.
struct HelpSection: Identifiable {
    let id: String
    let title: String
    let symbolName: String
    let blocks: [HelpContentBlock]
}

/// Contenuto statico (italiano) della guida in-app. Dati puri, separati dal layout in
/// `HelpView`, per rendere semplice aggiungere/aggiornare sezioni in futuro.
enum HelpContent {
    static let sections: [HelpSection] = [
        HelpSection(
            id: "cosa",
            title: "Che cos'è",
            symbolName: "questionmark.circle",
            blocks: [
                .paragraph("Backend Launcher è un launcher nativo macOS per avviare e fermare i backend di sviluppo di qualsiasi progetto, senza dover ricordare comandi o tenere aperti terminali sparsi."),
                .paragraph("Puoi gestire più progetti insieme, ciascuno con i propri backend, e vedere lo stato di tutti a colpo d'occhio."),
                .bullets([
                    "Nessuna dipendenza esterna da installare.",
                    "Non modifica MAI i file dei tuoi progetti: solo lettura delle cartelle e gestione dei processi che avvia."
                ])
            ]
        ),
        HelpSection(
            id: "concetti",
            title: "Concetti chiave",
            symbolName: "square.stack.3d.up",
            blocks: [
                .subheading("Progetto"),
                .paragraph("Un gruppo di backend correlati, con profili di avvio, un'eventuale spia infrastruttura e un colore identificativo."),
                .subheading("Servizio (Backend)"),
                .paragraph("Una cartella + un comando da eseguire + un criterio di prontezza."),
                .subheading("Prontezza"),
                .bullets([
                    "Porta TCP — diventa verde quando la porta risponde.",
                    "Marker nei log — diventa verde quando compare un testo specifico nei log (default \"successfully started\").",
                    "Sempre pronto — diventa verde non appena il processo parte."
                ]),
                .subheading("Stati e colori"),
                .bullets([
                    "⚪️ fermo",
                    "🟡 avvio",
                    "🟢 in esecuzione",
                    "🟠 arresto",
                    "🔴 crash (exit code)",
                    "🔵 esterno — la porta è occupata da un processo non avviato dal launcher: l'avvio resta disabilitato."
                ])
            ]
        ),
        HelpSection(
            id: "primi-passi",
            title: "Primi passi",
            symbolName: "flag.checkered",
            blocks: [
                .paragraph("Il menu \"＋ Aggiungi progetto\" in fondo alla sidebar ha quattro voci:"),
                .bullets([
                    "Nuovo progetto — crea un progetto vuoto, poi aggiungi i backend a mano (cartella, comando, criterio di prontezza).",
                    "Scansiona cartella… — analizza una cartella esistente (monorepo o singolo repo) e propone i backend riconosciuti, già pronti da rivedere e creare.",
                    "Importa progetto… — legge un template .blauncher.json esportato da un collega.",
                    "Genera con Claude Code… — copia un prompt pronto per far generare il template a Claude Code."
                ]),
                .paragraph("Puoi anche trascinare una cartella o un file .blauncher.json sulla finestra: una cartella avvia la stessa scansione di \"Scansiona cartella…\", un file .json precarica l'import."),
                .bullets([
                    "Avvia un backend con ▶︎ sulla card, oppure con \"Avvia progetto\" dal menu contestuale del progetto.",
                    "Leggi i log con il chevron sulla card o con doppio click sulla card stessa."
                ])
            ]
        ),
        HelpSection(
            id: "navigazione",
            title: "Navigazione",
            symbolName: "sidebar.left",
            blocks: [
                .subheading("Sidebar"),
                .bullets([
                    "Click sul nome del progetto → griglia del progetto.",
                    "Chevron → mostra/nasconde l'elenco dei backend.",
                    "Contatore n/m → numero di servizi attivi sul totale."
                ]),
                .subheading("Viste"),
                .bullets([
                    "Griglia — tutti i servizi.",
                    "Focus — terminali affiancati, selezionabili tramite chip.",
                    "Vista singolo servizio — click sul servizio in sidebar."
                ]),
                .subheading("Card servizio"),
                .bullets([
                    "Pill con uptime e utilizzo CPU/RAM.",
                    "Badge errori cliccabile.",
                    "Sottotitolo con l'ultima riga di log."
                ])
            ]
        ),
        HelpSection(
            id: "terminali",
            title: "Terminali",
            symbolName: "terminal",
            blocks: [
                .bullets([
                    "Colori per livello: rosso per gli errori, giallo per i warning, grigio per il debug.",
                    "Filtro Tutti / Warn+ / Errori.",
                    "Ricerca con contatore dei risultati e frecce per scorrerli.",
                    "Modalità Filtra (nasconde il resto) vs Evidenzia (mantiene il contesto).",
                    "Selezione nativa multi-riga: trascina e usa ⌘C per copiare.",
                    "Tasto destro: Copia riga, Copia blocco errore, oppure il bottone per copiare tutto il visibile.",
                    "Pulisci per svuotare il terminale.",
                    "Autoscroll intelligente: non ti interrompe se stai scorrendo verso l'alto per rileggere."
                ]),
                .paragraph("I log vengono salvati anche su file in ~/Library/Logs/BackendLauncher (rotazione a 5 MB). Tasto destro sul servizio → \"Apri log nel Finder\" per trovarli.")
            ]
        ),
        HelpSection(
            id: "gestione-progetti",
            title: "Gestione progetti",
            symbolName: "folder.badge.gearshape",
            blocks: [
                .paragraph("Tasto destro su un progetto in sidebar offre, in quest'ordine:"),
                .bullets([
                    "Avvia / Ferma / Riavvia progetto",
                    "Pulisci terminali",
                    "Impostazioni progetto… (nome, colore, spia infrastruttura, profili di avvio)",
                    "Cambia cartella radice… (sistema tutti i percorsi in un colpo — utile quando passi a un nuovo Mac)",
                    "Esporta progetto…",
                    "Elimina progetto"
                ]),
                .paragraph("Se le cartelle dei backend non esistono su questo Mac, un banner \"cartelle mancanti\" te lo segnala, con la possibilità di ripuntare la cartella o eliminare il progetto direttamente da lì."),
                .paragraph("Per modificare un servizio, usa il tasto destro sul rigo: va prima fermato. Se modifichi un servizio mentre è in esecuzione, le modifiche restano \"in sospeso\" (icona arancione) e si applicano solo quando lo fermi."),
                .subheading("Sincronizza (template del team)"),
                .paragraph("Se il progetto è stato importato da un template .blauncher.json e quel file cambia su disco (tipicamente dopo un git pull che porta una revisione aggiornata da un collega), un banner \"Il template del progetto è cambiato\" appare sopra la griglia del progetto. \"Sincronizza\" rilegge il file e sostituisce backend, profili e spia infrastruttura, preservando nome e colore del progetto. I backend in esecuzione non vengono fermati: le loro modifiche restano in sospeso e si applicano al prossimo riavvio, come per una modifica manuale.")
            ]
        ),
        HelpSection(
            id: "template",
            title: "Template (condivisione col team)",
            symbolName: "square.and.arrow.up.on.square",
            blocks: [
                .paragraph("\"Esporta progetto\" genera un file .blauncher.json con i percorsi resi relativi a una cartella radice scelta da te."),
                .paragraph("Il collega importa il file, indica dove si trova il progetto sul suo Mac ed eventualmente rinomina il progetto: da lì è pronto all'uso."),
                .bullets([
                    "I percorsi con \"..\" vengono rifiutati per sicurezza.",
                    "I template creati da versioni future dell'app vengono rifiutati con un messaggio chiaro."
                ])
            ]
        ),
        HelpSection(
            id: "scorciatoie",
            title: "Scorciatoie",
            symbolName: "keyboard",
            blocks: [
                .bullets([
                    "⌘K — palette comandi (naviga e agisci senza mouse)",
                    "⌘E — espandi/comprimi tutti i terminali",
                    "⌘1…⌘9 — terminale del singolo servizio",
                    "⌘⇧A — avvia tutti",
                    "⌘⇧S — ferma tutti (con conferma)",
                    "⌘⇧R — riavvia tutti",
                    "⌘N — nuovo progetto",
                    "⌘⇧N — scansiona cartella…",
                    "⌘⇧I — importa progetto…",
                    "⌘⇧G — genera con Claude Code…",
                    "⌘0 — apri il launcher dalla menu bar (dal menu dell'icona nella barra dei menu)",
                    "⌘= / ⌘− — aumenta/riduci la dimensione del testo del terminale",
                    "⌘, — impostazioni",
                    "⌘? — questo aiuto",
                    "Esc / Invio nei dialoghi — Annulla / Conferma"
                ])
            ]
        ),
        HelpSection(
            id: "menubar",
            title: "Menu bar e notifiche",
            symbolName: "menubar.rectangle",
            blocks: [
                .paragraph("Un'icona nella barra dei menu mostra lo stato aggregato di tutti i backend: piena quando sono tutti attivi, mezza quando solo alcuni lo sono, punto esclamativo in caso di crash. Da lì è disponibile anche un menu rapido con le azioni principali."),
                .bullets([
                    "Chiudere la finestra NON chiude l'app.",
                    "⌘Q chiude l'app, con conferma se ci sono backend attivi.",
                    "Una notifica di crash, se cliccata, apre il servizio con il filtro errori.",
                    "Il badge rosso nel Dock indica il numero di crash."
                ])
            ]
        ),
        HelpSection(
            id: "impostazioni-app",
            title: "Impostazioni app",
            symbolName: "gearshape",
            blocks: [
                .paragraph("Apribili con ⌘,:"),
                .bullets([
                    "Intervallo di aggiornamento dello stato (default 2 s).",
                    "Attesa prima del kill forzato (default 5 s).",
                    "Righe massime per terminale (default 5000 — vale per i nuovi avvii).",
                    "Dimensione testo terminale (anche da ⌘= / ⌘−).",
                    "Aspetto: Sistema / Chiaro / Scuro.",
                    "Notifiche di crash on/off."
                ])
            ]
        ),
        HelpSection(
            id: "file-troubleshooting",
            title: "File e risoluzione problemi",
            symbolName: "wrench.and.screwdriver",
            blocks: [
                .paragraph("La configurazione è salvata in ~/Library/Application Support/BackendLauncher/services.json, un JSON leggibile. In caso di problemi vengono creati backup con estensione .corrupt o .futureversion."),
                .paragraph("I log si trovano in ~/Library/Logs/BackendLauncher."),
                .subheading("Problemi comuni"),
                .bullets([
                    "Servizio \"esterno\" — la porta è occupata da un processo esterno: chiudi l'altro processo.",
                    "\"Cartella mancante\" — il percorso non esiste su questo Mac: usa \"Cambia cartella radice\" o \"Modifica\".",
                    "Spia infrastruttura rossa — il broker/DB del progetto è giù: i backend partono ma non comunicano.",
                    "Avvio lento oltre 90 secondi — controlla i log per capire cosa sta succedendo."
                ]),
                .subheading("Limitazione Docker"),
                .paragraph("Se il comando di un backend usa Docker (es. \"docker compose up\"), il launcher ferma solo il comando: i container restano attivi. Prevedi uno stop manuale (\"docker compose down\") — il form di modifica del backend te lo ricorda quando rileva \"docker\" nel comando."),
                .subheading("Comandi ed ambiente"),
                .bullets([
                    "Comandi composti supportati — sequenze con \"&&\", \";\", \"|\" e simili girano come su un terminale normale.",
                    "nvm / pyenv supportati — il comando gira in una login shell zsh che sorge anche ~/.zshrc, quindi vede lo stesso PATH del tuo terminale (Homebrew, nvm, pyenv, conda…).",
                    "Output dei servizi Python — PYTHONUNBUFFERED viene impostato automaticamente (se non già presente), così i log di un processo Python compaiono in tempo reale invece di restare bufferizzati."
                ]),
                .paragraph("Durante una scansione cartella, se due backend risultano sulla stessa porta il secondo viene automaticamente declassato a un criterio di prontezza diverso (marker nei log o sempre pronto) invece di lasciare un conflitto di porta — rivedibile dopo con \"Modifica…\".")
            ]
        )
    ]
}

/// Finestra di aiuto in-app (⌘? / menu Aiuto): elenco sezioni a sinistra, contenuto dettagliato
/// e selezionabile a destra. Dati statici in `HelpContent`, separati dal layout per rendere
/// semplice aggiungere nuove sezioni in futuro.
struct HelpView: View {
    @State private var selectedSectionID: String? = HelpContent.sections.first?.id

    private var selectedSection: HelpSection? {
        HelpContent.sections.first { $0.id == selectedSectionID } ?? HelpContent.sections.first
    }

    var body: some View {
        NavigationSplitView {
            List(HelpContent.sections, selection: $selectedSectionID) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            ScrollView {
                if let section = selectedSection {
                    HelpSectionDetail(section: section)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// Corpo dettagliato di una sezione: titolo + blocchi (paragrafi, sotto-titoli, elenchi),
/// centrato con una larghezza massima leggibile.
private struct HelpSectionDetail: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(section.title)
                .font(.title2.bold())
                .padding(.bottom, 4)

            ForEach(Array(section.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: HelpContentBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .lineSpacing(3)
        case .subheading(let text):
            Text(text)
                .font(.headline)
                .padding(.top, 4)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(item)
                            .font(.body)
                            .lineSpacing(3)
                    }
                }
            }
        }
    }
}
