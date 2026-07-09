import * as vscode from "vscode";

/**
 * Fase 0 — scaffold. Registra la view della sidebar con un TreeDataProvider
 * segnaposto e il comando "Aggiorna". Le fasi successive sostituiranno il
 * provider con l'albero reale letto da services.json.
 */
export function activate(context: vscode.ExtensionContext): void {
  const provider = new PlaceholderProvider();
  context.subscriptions.push(
    vscode.window.registerTreeDataProvider("backendLauncherServices", provider),
    vscode.commands.registerCommand("backendLauncher.refresh", () => provider.refresh()),
  );
}

export function deactivate(): void {
  // niente da smontare in fase 0
}

/** Provider segnaposto: una riga informativa, finché la Fase 1 non legge services.json. */
class PlaceholderProvider implements vscode.TreeDataProvider<string> {
  private readonly emitter = new vscode.EventEmitter<void>();
  readonly onDidChangeTreeData = this.emitter.event;

  refresh(): void {
    this.emitter.fire();
  }

  getTreeItem(element: string): vscode.TreeItem {
    const item = new vscode.TreeItem(element);
    item.iconPath = new vscode.ThemeIcon("server-process");
    return item;
  }

  getChildren(): string[] {
    return ["Scaffold attivo — la lettura di services.json arriva in Fase 1"];
  }
}
