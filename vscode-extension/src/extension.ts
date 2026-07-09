import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { defaultStorePath, loadStore, StoredProject, StoredService } from "./store";
import { ServiceRunner, serviceKey } from "./runner";
import { scanDirectory } from "./scanner";
import { ServiceSnapshot, StatusTracker } from "./status";
import { Node, ServicesTreeProvider } from "./tree";

/**
 * Fase 2 — avvia/ferma/riavvia i servizi in terminali VSCode veri, con icone sui nodi
 * e comandi (inline + menu contestuale + palette). Sopra la lettura di Fase 1.
 */
export function activate(context: vscode.ExtensionContext): void {
  const storePath = defaultStorePath();
  const runner = new ServiceRunner(context);
  let detectedProjects: StoredProject[] = [];

  // Snapshot di tutti i servizi (configurati + rilevati) per i probe di readiness.
  const tracker = new StatusTracker((): ServiceSnapshot[] => {
    const snapshots: ServiceSnapshot[] = [];
    const push = (project: StoredProject) => {
      for (const service of project.services) {
        const key = serviceKey(project.name, service.name);
        snapshots.push({ key, readiness: service.readiness, alive: runner.state(key) === "running" });
      }
    };
    const result = loadStore(storePath);
    if (result.ok) result.projects.forEach(push);
    detectedProjects.forEach(push);
    return snapshots;
  });

  const provider = new ServicesTreeProvider(runner, tracker, storePath);
  // `setDetected` aggiorna sia l'albero sia lo snapshot per i probe.
  const setDetected = (projects: StoredProject[]) => {
    detectedProjects = projects;
    provider.setDetected(projects);
  };

  // Stato terminali o probe cambiano → ridisegna l'albero.
  context.subscriptions.push(runner.onDidChange(() => { void tracker.pollOnce(); provider.refresh(); }));
  context.subscriptions.push(tracker.onDidChange(() => provider.refresh()));
  context.subscriptions.push({ dispose: () => runner.dispose() });
  context.subscriptions.push({ dispose: () => tracker.dispose() });
  tracker.start();

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

    vscode.commands.registerCommand("backendLauncher.scanWorkspace", () => {
      const detected = scanWorkspace();
      setDetected(detected);
      const total = detected.reduce((n, p) => n + p.services.length, 0);
      vscode.window.showInformationMessage(
        total > 0
          ? `Rilevati ${total} backend nel workspace.`
          : "Nessun backend rilevato nelle cartelle aperte.",
      );
    }),
  );

  // Scan automatico all'avvio: se il workspace aperto non è già coperto dai progetti
  // configurati, mostra i backend rilevati (effimeri, avviabili subito).
  const auto = scanWorkspace();
  if (auto.length > 0 && !workspaceAlreadyConfigured(storePath)) {
    setDetected(auto);
  }

  watchStore(storePath, () => provider.refresh(), context);
}

/** Scandisce ogni cartella aperta nel workspace VSCode; una per progetto "rilevato". */
function scanWorkspace(): StoredProject[] {
  const folders = vscode.workspace.workspaceFolders ?? [];
  const projects: StoredProject[] = [];
  for (const folder of folders) {
    const services = scanDirectory(folder.uri.fsPath);
    if (services.length > 0) {
      projects.push({ name: folder.name, services });
    }
  }
  return projects;
}

/** Vero se almeno un servizio configurato vive dentro una cartella del workspace: in tal
 *  caso l'utente ha già configurato questo progetto nell'app nativa, niente scan automatico. */
function workspaceAlreadyConfigured(storePath: string): boolean {
  const result = loadStore(storePath);
  if (!result.ok) return false;
  const folders = (vscode.workspace.workspaceFolders ?? []).map((f) => f.uri.fsPath);
  if (folders.length === 0) return false;
  return result.projects.some((p) =>
    p.services.some((s) => folders.some((f) => s.directory.startsWith(f))),
  );
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
