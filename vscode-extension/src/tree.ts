import * as vscode from "vscode";
import {
  loadStore,
  readinessCaption,
  StoredProject,
  StoredService,
} from "./store";
import { ServiceRunner, serviceKey } from "./runner";
import { DisplayStatus } from "./probes";
import { StatusTracker } from "./status";

function statusColor(status: DisplayStatus): vscode.ThemeColor {
  switch (status) {
    case "running": return new vscode.ThemeColor("charts.green");
    case "starting": return new vscode.ThemeColor("charts.yellow");
    case "external": return new vscode.ThemeColor("charts.blue");
    case "stopped": return new vscode.ThemeColor("disabledForeground");
  }
}

function statusLabel(status: DisplayStatus): string {
  switch (status) {
    case "running": return "in esecuzione";
    case "starting": return "avvio…";
    case "external": return "esterno";
    case "stopped": return "fermo";
  }
}

/** Nodo dell'albero: un progetto, un servizio, o una riga-messaggio (stato vuoto/errore). */
export type Node =
  | { kind: "project"; project: StoredProject; detected?: boolean }
  | { kind: "service"; project: StoredProject; service: StoredService; detected?: boolean }
  | { kind: "message"; text: string };

/**
 * Fornisce l'albero progetti→servizi leggendo `services.json` (via `loadStore`).
 * Fase 1: sola lettura. La ricarica è pilotata da `refresh()` (comando + fs.watch).
 */
export class ServicesTreeProvider implements vscode.TreeDataProvider<Node> {
  private readonly emitter = new vscode.EventEmitter<Node | undefined>();
  readonly onDidChangeTreeData = this.emitter.event;

  /** Progetti "rilevati" nel workspace VSCode (scan effimero, non salvati nel services.json). */
  private detectedProjects: StoredProject[] = [];

  constructor(
    private readonly runner: ServiceRunner,
    private readonly status: StatusTracker,
    private readonly storePath?: string,
  ) {}

  refresh(): void {
    this.emitter.fire(undefined);
  }

  /** Imposta i progetti rilevati dallo scan del workspace (mostrati sotto quelli configurati). */
  setDetected(projects: StoredProject[]): void {
    this.detectedProjects = projects;
    this.refresh();
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
        const running = node.project.services.filter((s) => {
          const st = this.status.status(serviceKey(node.project.name, s.name));
          return st === "running" || st === "starting";
        }).length;
        if (node.detected) {
          item.iconPath = new vscode.ThemeIcon("search");
          item.contextValue = running > 0 ? "detected.running" : "detected.stopped";
          item.description = `rilevati · ${running}/${node.project.services.length}`;
          item.tooltip = "Backend rilevati in questa cartella (non salvati). \"Salva progetto\" per tenerli.";
        } else {
          item.iconPath = new vscode.ThemeIcon("folder");
          item.contextValue = running > 0 ? "project.running" : "project.stopped";
          item.description = `${running}/${node.project.services.length}`;
        }
        return item;
      }
      case "service": {
        const key = serviceKey(node.project.name, node.service.name);
        const st = this.status.status(key);
        const alive = this.runner.state(key) === "running";
        const item = new vscode.TreeItem(
          node.service.name,
          vscode.TreeItemCollapsibleState.None,
        );
        item.iconPath = new vscode.ThemeIcon("circle-filled", statusColor(st));
        // contextValue pilota i menu: "running/stopped" (terminale nostro) + ".url" se
        // il servizio ha un appURL (mostra "Apri nel browser").
        const urlSuffix = node.service.appURL ? ".url" : "";
        item.contextValue = (alive ? "service.running" : "service.stopped") + urlSuffix;
        item.description = `${readinessCaption(node.service.readiness)} · ${statusLabel(st)}`;
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
        detected: node.detected,
      }));
    }
    if (node) return []; // i servizi non hanno figli

    // radice: progetti configurati (da services.json) + progetti rilevati nel workspace.
    const nodes: Node[] = [];
    const result = loadStore(this.storePath);
    if (result.ok) {
      for (const project of result.projects) {
        nodes.push({ kind: "project", project });
      }
    }
    for (const project of this.detectedProjects) {
      nodes.push({ kind: "project", project, detected: true });
    }

    // Vuoto → nessun nodo: lascia spazio alla viewsWelcome (bottoni azione) del manifest.
    return nodes;
  }
}
