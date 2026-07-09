import * as vscode from "vscode";
import {
  loadStore,
  readinessCaption,
  StoredProject,
  StoredService,
} from "./store";

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

  constructor(private readonly storePath?: string) {}

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
        item.contextValue = "project";
        const count = node.project.services.length;
        item.description = count === 1 ? "1 backend" : `${count} backend`;
        return item;
      }
      case "service": {
        const item = new vscode.TreeItem(
          node.service.name,
          vscode.TreeItemCollapsibleState.None,
        );
        item.iconPath = new vscode.ThemeIcon("server-process");
        item.contextValue = "service";
        item.description = readinessCaption(node.service.readiness);
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
