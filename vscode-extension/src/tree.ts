import * as vscode from "vscode";
import {
  loadStore,
  readinessCaption,
  StoredProject,
  StoredService,
} from "./store";
import { ServiceRunner, serviceKey } from "./runner";

/** Nodo dell'albero: un progetto, un servizio, o una riga-messaggio (stato vuoto/errore). */
export type Node =
  | { kind: "project"; project: StoredProject }
  | { kind: "service"; project: StoredProject; service: StoredService }
  | { kind: "message"; text: string };

/**
 * Fornisce l'albero progetti→servizi leggendo `services.json` (via `loadStore`).
 * Fase 1: sola lettura. La ricarica è pilotata da `refresh()` (comando + fs.watch).
 */
export class ServicesTreeProvider implements vscode.TreeDataProvider<Node> {
  private readonly emitter = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this.emitter.event;

  constructor(
    private readonly runner: ServiceRunner,
    private readonly storePath?: string,
  ) {}

  refresh(): void {
    this.emitter.fire(undefined);
  }

  getTreeItem(node: Node): vscode.TreeItem {
    switch (node.kind) {
      case "message": {
        const item = new vscode.TreeItem(node.text);
        item.iconPath = new vscode.ThemeIcon("info");
        return item;
      }
      case "project": {
        const item = new vscode.TreeItem(
          node.project.name,
          vscode.TreeItemCollapsibleState.Expanded,
        );
        item.iconPath = new vscode.ThemeIcon("folder");
        const running = node.project.services.filter(
          (s) => this.runner.state(serviceKey(node.project.name, s.name)) === "running",
        ).length;
        item.contextValue = running > 0 ? "project.running" : "project.stopped";
        item.description = `${running}/${node.project.services.length}`;
        return item;
      }
      case "service": {
        const key = serviceKey(node.project.name, node.service.name);
        const running = this.runner.state(key) === "running";
        const item = new vscode.TreeItem(
          node.service.name,
          vscode.TreeItemCollapsibleState.None,
        );
        item.iconPath = new vscode.ThemeIcon(
          "circle-filled",
          new vscode.ThemeColor(running ? "charts.green" : "disabledForeground"),
        );
        item.contextValue = running ? "service.running" : "service.stopped";
        item.description = readinessCaption(node.service.readiness)
          + (running ? " · in esecuzione" : "");
        item.tooltip = `${node.service.command}\n${node.service.directory}`;
        return item;
      }
    }
  }

  getChildren(node?: Node): Node[] {
    if (node?.kind === "project") {
      return node.project.services.map((service) => ({
        kind: "service" as const,
        project: node.project,
        service,
      }));
    }
    if (node) return []; // i servizi non hanno figli

    // radice: carica dallo store.
    const result = loadStore(this.storePath);
    if (!result.ok) {
      return [{
        kind: "message",
        text: result.reason === "missing"
          ? "services.json non trovato — apri e configura l'app Backend Launcher"
          : result.message,
      }];
    }
    if (result.projects.length === 0) {
      return [{ kind: "message", text: "Nessun progetto — creane uno nell'app Backend Launcher" }];
    }
    return result.projects.map((project) => ({ kind: "project" as const, project }));
  }
}
