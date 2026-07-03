import Foundation

/// Genera il prompt da incollare in Claude Code dentro la repo di un progetto:
/// istruisce l'AI ad analizzare i backend e scrivere il template .blauncher.json
/// importabile dal launcher. Puro e testabile.
enum ClaudeCodePrompt {
    static func make() -> String {
        """
        Analizza questa repository e genera un file template per "Backend Launcher" (launcher macOS di backend di sviluppo).

        COSA FARE
        1. Individua tutti i backend/servizi avviabili in locale in questa repo: cartelle con package.json (script dev/start:dev), docker-compose, Makefile, o equivalenti in altri linguaggi.
        2. Per ogni servizio determina:
           - name: nome breve, minuscolo, senza spazi (es. "gateway")
           - relativeDirectory: percorso della cartella del servizio RELATIVO alla root della repo (es. "SKILLGATEWAY-BE"); usa "" se è la root stessa
           - command: comando di avvio da terminale nella cartella (es. "npm run start:dev")
           - readiness: come capire che è pronto —
             · porta HTTP che apre → {"kind":"port","port":4000,"marker":null}
             · nessuna porta ma un log riconoscibile → {"kind":"logMarker","port":null,"marker":"testo che compare nei log"}
             · nessuno dei due → {"kind":"processAlive","port":null,"marker":null}
             Cerca le porte in .env, config, codice di bootstrap; per i marker usa la riga di log di avvio (es. "successfully started").
        3. Se esiste un'infrastruttura condivisa (broker, db) con una porta locale nota, imposta infraCheck (etichetta + porta), altrimenti null.
        4. Facoltativo: profili utili in "profiles" (sottoinsiemi di servizi avviati insieme), es. un profilo "Minimo".
        5. Scrivi il file nella ROOT della repo col nome: <nomeprogetto>.blauncher.json

        FORMATO ESATTO (JSON, chiavi esattamente così):
        {
          "templateVersion": 1,
          "name": "NomeProgetto",
          "services": [
            {
              "name": "gateway",
              "relativeDirectory": "PERCORSO-RELATIVO",
              "command": "npm run start:dev",
              "readiness": {"kind": "port", "port": 4000, "marker": null}
            }
          ],
          "profiles": [
            {"name": "Tutti", "serviceNames": ["gateway"]}
          ],
          "infraCheck": {"label": "NATS", "port": 4222}
        }

        VINCOLI
        - "kind" ∈ {"port","logMarker","processAlive"}; port è un intero 1-65535 o null; marker stringa o null.
        - I percorsi relativi NON devono contenere "..".
        - Non modificare nessun altro file della repo: crea SOLO il template.
        - Verifica che il JSON sia valido prima di consegnare.

        Quando hai finito dimmi il percorso del file: lo importerò da Backend Launcher con "Importa progetto…" indicando la root di questa repo.
        """
    }
}
