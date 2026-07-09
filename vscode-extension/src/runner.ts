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
  private readonly changeEmitter = new vscode.EventEmitter<void>();
  readonly onDidChange = this.changeEmitter.event;

  constructor(context: vscode.ExtensionContext) {
    // Se l'utente (o il processo) chiude il terminale, il servizio è fermo.
    context.subscriptions.push(
      vscode.window.onDidCloseTerminal((closed) => {
        for (const [key, terminal] of this.terminals) {
          if (terminal === closed) {
            this.terminals.delete(key);
            this.changeEmitter.fire();
            break;
          }
        }
      }),
    );
  }

  state(key: string): RunState {
    return this.terminals.has(key) ? "running" : "stopped";
  }

  /** Avvia il servizio (o `commandOverride`, es. una variante) in un terminale dedicato. */
  start(project: StoredProject, service: StoredService, commandOverride?: string): void {
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
    });
    terminal.show();
    terminal.sendText(commandOverride ?? service.command, true);
    this.terminals.set(key, terminal);
    this.changeEmitter.fire();
  }

  /** Ferma il servizio: chiude il terminale (SIGKILL alla shell e ai figli). */
  stop(key: string): void {
    const terminal = this.terminals.get(key);
    if (!terminal) return;
    this.terminals.delete(key);
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

  dispose(): void {
    for (const terminal of this.terminals.values()) terminal.dispose();
    this.terminals.clear();
    this.changeEmitter.dispose();
  }
}
