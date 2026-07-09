import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { defaultStorePath, loadStore, StoredProject, StoredService } from "./store";
import { ServiceRunner, serviceKey } from "./runner";
import { Node, ServicesTreeProvider } from "./tree";

/**
 * Fase 2 — avvia/ferma/riavvia i servizi in terminali VSCode veri, con icone sui nodi
 * e comandi (inline + menu contestuale + palette). Sopra la lettura di Fase 1.
 */
export function activate(context: vscode.ExtensionContext): void {
  const storePath = defaultStorePath();
  const runner = new ServiceRunner(context);
  const provider = new ServicesTreeProvider(runner, storePath);

  // Lo stato dei terminali cambia → ridisegna l'albero (pallini, contatori).
  context.subscriptions.push(runner.onDidChange(() => provider.refresh()));
  context.subscriptions.push({ dispose: () => runner.dispose() });

  context.subscriptions.push(
    vscode.window.registerTreeDataProvider("backendLauncherServices", provider),
    vscode.commands.registerCommand("backendLauncher.refresh", () => provider.refresh()),

    vscode.commands.registerCommand("backendLauncher.startService", (node?: Node) => {
      withService(node, storePath, (project, service) => runner.start(project, service));
    }),
    vscode.commands.registerCommand("backendLauncher.stopService", (node?: Node) => {
      withService(node, storePath, (project, service) =>
        runner.stop(serviceKey(project.name, service.name)));
    }),
    vscode.commands.registerCommand("backendLauncher.restartService", (node?: Node) => {
      withService(node, storePath, (project, service) => runner.restart(project, service));
    }),
    vscode.commands.registerCommand("backendLauncher.startServiceWith", (node?: Node) => {
      withService(node, storePath, async (project, service) => {
        const variants = service.commandVariants ?? [];
        const choices = [service.command, ...variants];
        const pick = await vscode.window.showQuickPick(choices, {
          placeHolder: "Avvia con quale comando?",
        });
        if (pick) runner.start(project, service, pick);
      });
    }),
    vscode.commands.registerCommand("backendLauncher.revealTerminal", (node?: Node) => {
      withService(node, storePath, (project, service) =>
        runner.reveal(serviceKey(project.name, service.name)));
    }),

    vscode.commands.registerCommand("backendLauncher.startProject", (node?: Node) => {
      withProject(node, storePath, (project) => {
        for (const service of project.services) runner.start(project, service);
      });
    }),
    vscode.commands.registerCommand("backendLauncher.stopProject", (node?: Node) => {
      withProject(node, storePath, (project) => {
        for (const service of project.services) {
          runner.stop(serviceKey(project.name, service.name));
        }
      });
    }),
  );

  watchStore(storePath, () => provider.refresh(), context);
}

export function deactivate(): void {
  // watcher e runner sono in context.subscriptions
}

/** Risolve il servizio da un nodo dell'albero (o dallo store se il nodo è stantio). */
function withService(
  node: Node | undefined,
  storePath: string,
  action: (project: StoredProject, service: StoredService) => void,
): void {
  if (node?.kind !== "service") return;
  // Rilegge dallo store così un comando lanciato su un nodo vecchio usa la config fresca.
  const fresh = resolveService(storePath, node.project.name, node.service.name);
  if (fresh) action(fresh.project, fresh.service);
  else action(node.project, node.service);
}

function withProject(
  node: Node | undefined,
  storePath: string,
  action: (project: StoredProject) => void,
): void {
  if (node?.kind !== "project") return;
  const result = loadStore(storePath);
  const fresh = result.ok
    ? result.projects.find((p) => p.name === node.project.name)
    : undefined;
  action(fresh ?? node.project);
}

function resolveService(
  storePath: string,
  projectName: string,
  serviceName: string,
): { project: StoredProject; service: StoredService } | undefined {
  const result = loadStore(storePath);
  if (!result.ok) return undefined;
  const project = result.projects.find((p) => p.name === projectName);
  const service = project?.services.find((s) => s.name === serviceName);
  return project && service ? { project, service } : undefined;
}

/**
 * Osserva `services.json` per ricaricare l'albero quando l'app nativa lo riscrive.
 * L'app scrive ATOMICO (temp + rename): `fs.watch` sul file smetterebbe dopo il primo
 * rename, quindi si osserva la DIRECTORY filtrando il nome. Se la cartella non esiste
 * ancora (app mai avviata), si riprova a intervalli finché non compare.
 */
function watchStore(
  storePath: string,
  onChange: () => void,
  context: vscode.ExtensionContext,
): void {
  const dir = path.dirname(storePath);
  const fileName = path.basename(storePath);

  const startDirWatch = (): boolean => {
    try {
      const watcher = fs.watch(dir, (_event, changed) => {
        if (!changed || changed === fileName) onChange();
      });
      context.subscriptions.push({ dispose: () => watcher.close() });
      return true;
    } catch {
      return false;
    }
  };

  if (startDirWatch()) return;

  const timer = setInterval(() => {
    if (fs.existsSync(dir) && startDirWatch()) {
      clearInterval(timer);
      onChange();
    }
  }, 3000);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}
