import * as vscode from "vscode";
import { StoredProject, StoredService } from "./store";

export type RunState = "stopped" | "running";

/** Chiave stabile di un servizio: "Progetto/nome" (come l'id namespaced dell'app nativa). */
export function serviceKey(projectName: string, serviceName: string): string {
  return `${projectName}/${serviceName}`;
}

/**
 * Avvia/ferma i servizi in TERMINALI VSCode veri (PTY: colori + input nativi gratis).
 * Fase 2: "running" = terminale del servizio vivo. La readiness (porta/http) arriva in
 * Fase 3. Emette un evento a ogni cambio così l'albero si ridisegna.
 */
export class ServiceRunner {
  private readonly terminals = new Map<string, vscode.Terminal>();
  private readonly startedAtMs = new Map<string, number>();
  private readonly changeEmitter = new vscode.EventEmitter<void>();
  readonly onDidChange = this.changeEmitter.event;
  /** Emesso quando un terminale si chiude da solo (processo morto): per le notifiche. */
  private readonly closedEmitter = new vscode.EventEmitter<string>();
  readonly onDidServiceClose = this.closedEmitter.event;

  constructor(context: vscode.ExtensionContext) {
    // Se l'utente (o il processo) chiude il terminale, il servizio è fermo.
    context.subscriptions.push(
      vscode.window.onDidCloseTerminal((closed) => {
        for (const [key, terminal] of this.terminals) {
          if (terminal === closed) {
            this.terminals.delete(key);
            this.startedAtMs.delete(key);
            this.changeEmitter.fire();
            this.closedEmitter.fire(key);
            break;
          }
        }
      }),
    );
  }

  state(key: string): RunState {
    return this.terminals.has(key) ? "running" : "stopped";
  }

  /** Millisecondi dall'avvio del servizio (per l'uptime), o undefined se fermo. */
  uptimeMs(key: string): number | undefined {
    const started = this.startedAtMs.get(key);
    return started === undefined ? undefined : Date.now() - started;
  }

  /** Epoch ms d'avvio del servizio (il webview calcola l'uptime live), o undefined. */
  startedAt(key: string): number | undefined {
    return this.startedAtMs.get(key);
  }

  /**
   * Avvia il servizio (o `commandOverride`) in un terminale dedicato. `location` permette
   * di aprirlo nell'area editor a una colonna specifica (per la dashboard "tutti i
   * terminali del progetto affiancati").
   */
  start(
    project: StoredProject,
    service: StoredService,
    commandOverride?: string,
    location?: vscode.TerminalOptions["location"],
  ): void {
    const key = serviceKey(project.name, service.name);
    const existing = this.terminals.get(key);
    if (existing) {
      existing.show();
      return; // già in esecuzione: porta solo il terminale in primo piano
    }
    const terminal = vscode.window.createTerminal({
      name: `${service.name} · ${project.name}`,
      cwd: service.directory,
      iconPath: new vscode.ThemeIcon("server-process"),
      location,
    });
    terminal.show();
    terminal.sendText(commandOverride ?? service.command, true);
    this.terminals.set(key, terminal);
    this.startedAtMs.set(key, Date.now());
    this.changeEmitter.fire();
  }

  /**
   * Apre TUTTI i terminali dei servizi del progetto affiancati nell'area editor (una
   * colonna per servizio) — la "finestra" con tutto lo stack sott'occhio. I servizi non
   * ancora avviati partono in colonna; quelli già vivi vengono solo rivelati.
   */
  openProjectDashboard(project: StoredProject): void {
    const columns = [
      vscode.ViewColumn.One, vscode.ViewColumn.Two, vscode.ViewColumn.Three,
      vscode.ViewColumn.Four, vscode.ViewColumn.Five, vscode.ViewColumn.Six,
      vscode.ViewColumn.Seven, vscode.ViewColumn.Eight, vscode.ViewColumn.Nine,
    ];
    project.services.forEach((service, index) => {
      const key = serviceKey(project.name, service.name);
      if (this.terminals.has(key)) {
        this.terminals.get(key)!.show();
      } else {
        const viewColumn = columns[Math.min(index, columns.length - 1)];
        this.start(project, service, undefined, { viewColumn });
      }
    });
  }

  /** Ferma il servizio: chiude il terminale (SIGKILL alla shell e ai figli). */
  stop(key: string): void {
    const terminal = this.terminals.get(key);
    if (!terminal) return;
    this.terminals.delete(key);
    this.startedAtMs.delete(key);
    terminal.dispose();
    this.changeEmitter.fire();
  }

  restart(project: StoredProject, service: StoredService): void {
    const key = serviceKey(project.name, service.name);
    if (this.terminals.has(key)) {
      this.stop(key);
      // Piccolo respiro perché il terminale si chiuda prima di riaprirlo.
      setTimeout(() => this.start(project, service), 300);
    } else {
      this.start(project, service);
    }
  }

  /** Porta in primo piano il terminale del servizio, se vivo. */
  reveal(key: string): void {
    this.terminals.get(key)?.show();
  }

  /** Invia testo allo stdin del terminale del servizio (dalla dashboard). */
  sendText(key: string, text: string): void {
    this.terminals.get(key)?.sendText(text, true);
  }

  dispose(): void {
    // Svuota PRIMA la mappa: così onDidCloseTerminal non scambia lo shutdown per crash.
    const terminals = [...this.terminals.values()];
    this.terminals.clear();
    this.startedAtMs.clear();
    for (const terminal of terminals) terminal.dispose();
    this.changeEmitter.dispose();
    this.closedEmitter.dispose();
  }
}
