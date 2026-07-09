import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { defaultStorePath } from "./store";
import { ServicesTreeProvider } from "./tree";

/**
 * Fase 1 — legge `services.json` e mostra progetti/servizi nell'albero (sola lettura),
 * con refresh manuale (comando) e automatico (fs.watch sul file).
 */
export function activate(context: vscode.ExtensionContext): void {
  const storePath = defaultStorePath();
  const provider = new ServicesTreeProvider(storePath);

  context.subscriptions.push(
    vscode.window.registerTreeDataProvider("backendLauncherServices", provider),
    vscode.commands.registerCommand("backendLauncher.refresh", () => provider.refresh()),
  );

  watchStore(storePath, () => provider.refresh(), context);
}

export function deactivate(): void {
  // i watcher sono in context.subscriptions
}

/**
 * Osserva `services.json` per ricaricare l'albero quando l'app nativa lo riscrive.
 * L'app scrive in modo ATOMICO (write su temp + rename): un `fs.watch` sul file stesso
 * smetterebbe di funzionare dopo il primo rename. Si osserva quindi la DIRECTORY e si
 * filtra sul nome del file. Se la directory non esiste ancora (app mai avviata), si
 * riprova a intervalli finché non compare.
 */
function watchStore(
  storePath: string,
  onChange: () => void,
  context: vscode.ExtensionContext,
): void {
  const dir = path.dirname(storePath);
  const fileName = path.basename(storePath);

  const startDirWatch = (): fs.FSWatcher | null => {
    try {
      const watcher = fs.watch(dir, (_event, changed) => {
        if (!changed || changed === fileName) onChange();
      });
      context.subscriptions.push({ dispose: () => watcher.close() });
      return watcher;
    } catch {
      return null;
    }
  };

  if (startDirWatch()) return;

  // Directory assente: poll finché non compare, poi aggancia il watcher e ricarica.
  const timer = setInterval(() => {
    if (fs.existsSync(dir) && startDirWatch()) {
      clearInterval(timer);
      onChange();
    }
  }, 3000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}
