import * as fs from "fs";
import * as path from "path";
import * as vscode from "vscode";
import { defaultStorePath, loadStore, readinessCaption, StoredProject, StoredService } from "./store";
import { ServiceRunner, serviceKey } from "./runner";
import { scanDirectory } from "./scanner";
import { ServiceSnapshot, StatusTracker } from "./status";
import { Node, ServicesTreeProvider } from "./tree";
import { appendProject } from "./writeStore";
import { DashboardController, DashboardPanel, ServiceView } from "./dashboard";
import { GitBranchTracker, GitTarget } from "./gitTracker";

/**
 * Estensione completa: lettura services.json + scan workspace + avvio in terminali VSCode
 * veri + readiness reale + azioni progetto/globali + dashboard terminali + status bar.
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

  // Poller branch git (lento) su tutti i servizi noti.
  const gitTracker = new GitBranchTracker((): GitTarget[] => {
    const targets: GitTarget[] = [];
    const push = (project: StoredProject) => {
      for (const service of project.services) {
        if (service.directory) {
          targets.push({
            key: serviceKey(project.name, service.name),
            directory: service.directory,
            projectName: project.name,
          });
        }
      }
    };
    const result = loadStore(storePath);
    if (result.ok) result.projects.forEach(push);
    detectedProjects.forEach(push);
    return targets;
  });

  const provider = new ServicesTreeProvider(runner, tracker, gitTracker, storePath);
  // `setDetected` aggiorna sia l'albero sia lo snapshot per i probe.
  const setDetected = (projects: StoredProject[]) => {
    detectedProjects = projects;
    provider.setDetected(projects);
  };

  // Evento UI unificato: stato/branch/run cambiano → albero + dashboard.
  const uiChange = new vscode.EventEmitter<void>();
  context.subscriptions.push(uiChange);
  const onUi = () => { provider.refresh(); uiChange.fire(); };
  context.subscriptions.push(runner.onDidChange(() => { void tracker.pollOnce(); onUi(); }));
  context.subscriptions.push(tracker.onDidChange(onUi));
  context.subscriptions.push({ dispose: () => runner.dispose() });
  context.subscriptions.push({ dispose: () => tracker.dispose() });
  context.subscriptions.push(gitTracker.onDidChange(onUi));
  context.subscriptions.push({ dispose: () => gitTracker.dispose() });
  tracker.start();
  gitTracker.start();

  // Helper condivisi: risoluzione progetto/servizio dallo store+rilevati.
  const findProject = (name: string): StoredProject | undefined => {
    const result = loadStore(storePath);
    return (result.ok ? result.projects.find((p) => p.name === name) : undefined)
      ?? detectedProjects.find((p) => p.name === name);
  };
  const findService = (projectName: string, serviceName: string) => {
    const project = findProject(projectName);
    const service = project?.services.find((s) => s.name === serviceName);
    return project && service ? { project, service } : undefined;
  };

  // Controller della dashboard webview: espone stato + azioni al pannello.
  const dashboardController: DashboardController = {
    onDidChange: uiChange.event,
    getAccent: (projectName) => findProject(projectName)?.accentColorHex,
    getServices(projectName): ServiceView[] {
      const project = findProject(projectName);
      if (!project) return [];
      return project.services.map((service) => {
        const key = serviceKey(projectName, service.name);
        return {
          name: service.name,
          status: tracker.status(key),
          readiness: readinessCaption(service.readiness),
          alive: runner.state(key) === "running",
          hasUrl: !!service.appURL,
          latencyMs: tracker.latencyMs(key),
          startedAtMs: runner.startedAt(key),
          branch: gitTracker.branch(key),
          mismatch: gitTracker.isMismatch(key),
        };
      });
    },
    start: (pn, sn) => { const f = findService(pn, sn); if (f) runner.start(f.project, f.service); },
    stop: (pn, sn) => runner.stop(serviceKey(pn, sn)),
    restart: (pn, sn) => { const f = findService(pn, sn); if (f) runner.restart(f.project, f.service); },
    openTerminal: (pn, sn) => runner.reveal(serviceKey(pn, sn)),
    openBrowser: (pn, sn) => { const f = findService(pn, sn); if (f?.service.appURL) openUrl(f.service.appURL); },
    sendInput: (pn, sn, text) => runner.sendText(serviceKey(pn, sn), text),
    startAll: (pn) => { const p = findProject(pn); if (p) p.services.forEach((s) => runner.start(p, s)); },
    stopAll: (pn) => { const p = findProject(pn); if (p) p.services.forEach((s) => runner.stop(serviceKey(pn, s.name))); },
    startStack: (pn) => vscode.commands.executeCommand("backendLauncher.startStack", { kind: "project", project: findProject(pn) }),
  };

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

    vscode.commands.registerCommand("backendLauncher.restartProject", (node?: Node) => {
      withProject(node, storePath, (project) => {
        for (const service of project.services) {
          if (runner.state(serviceKey(project.name, service.name)) === "running") {
            runner.restart(project, service);
          }
        }
      });
    }),

    // Dashboard: pannello "mission control" del progetto (card per servizio, controlli).
    vscode.commands.registerCommand("backendLauncher.openProjectDashboard", (node?: Node) => {
      withProject(node, storePath, (project) => DashboardPanel.show(dashboardController, project.name));
    }),
    // Alternativa: i terminali PTY veri del progetto affiancati nell'area editor.
    vscode.commands.registerCommand("backendLauncher.openProjectTerminals", (node?: Node) => {
      withProject(node, storePath, (project) => runner.openProjectDashboard(project));
    }),

    // "Avvia stack": backend prima, app principale per ultima, poi apri l'URL dell'app.
    vscode.commands.registerCommand("backendLauncher.startStack", (node?: Node) => {
      withProject(node, storePath, (project) => {
        const main = project.services.find((s) => s.isMainApp);
        const backends = project.services.filter((s) => !s.isMainApp);
        for (const service of backends) runner.start(project, service);
        if (main) {
          runner.start(project, main);
          if (main.appURL) openUrl(main.appURL);
        }
        vscode.window.showInformationMessage(`Stack ${project.name} avviato.`);
      });
    }),

    vscode.commands.registerCommand("backendLauncher.openAppUrl", (node?: Node) => {
      if (node?.kind === "service" && node.service.appURL) openUrl(node.service.appURL);
    }),

    // Azioni globali con conferma per quelle di massa.
    vscode.commands.registerCommand("backendLauncher.startAll", () => {
      forAllProjects(storePath, detectedProjects, (project) => {
        for (const service of project.services) runner.start(project, service);
      });
    }),
    vscode.commands.registerCommand("backendLauncher.stopAll", async () => {
      const ok = await confirm("Fermare tutti i backend?", "Ferma tutti");
      if (!ok) return;
      forAllProjects(storePath, detectedProjects, (project) => {
        for (const service of project.services) {
          runner.stop(serviceKey(project.name, service.name));
        }
      });
    }),

    // Salva un progetto rilevato nel services.json (lo vedrà anche l'app nativa).
    vscode.commands.registerCommand("backendLauncher.saveDetectedProject", async (node?: Node) => {
      if (node?.kind !== "project" || !node.detected) return;
      const name = await vscode.window.showInputBox({
        prompt: "Nome del progetto da salvare",
        value: node.project.name,
      });
      if (!name) return;
      const result = appendProject(storePath, { ...node.project, name });
      if (result.ok) {
        vscode.window.showInformationMessage(`Progetto "${name}" salvato in services.json.`);
        detectedProjects = detectedProjects.filter((p) => p !== node.project);
        provider.setDetected(detectedProjects);
        provider.refresh();
      } else {
        vscode.window.showErrorMessage(result.message);
      }
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

    // Apre il file di config principale del servizio (package.json, pubspec.yaml, …).
    vscode.commands.registerCommand("backendLauncher.openServiceFiles", (node?: Node) => {
      if (node?.kind !== "service") return;
      openServiceFiles(node.service.directory);
    }),

    // Esegue un task one-shot del servizio (es. npx prisma generate) in un terminale.
    vscode.commands.registerCommand("backendLauncher.runTask", async (node?: Node) => {
      if (node?.kind !== "service") return;
      const fresh = findService(node.project.name, node.service.name)?.service ?? node.service;
      const tasks = fresh.tasks ?? [];
      if (tasks.length === 0) {
        vscode.window.showInformationMessage(`Nessun task per "${fresh.name}" — aggiungili nell'app nativa.`);
        return;
      }
      const pick = await vscode.window.showQuickPick(
        tasks.map((t) => ({ label: t.name, description: t.command, task: t })),
        { placeHolder: "Esegui quale task?" },
      );
      if (pick) runner.runTask(fresh, node.project.name, pick.task);
    }),

    // Quick pick globale "Avvia…": scegli un servizio da avviare, senza aprire l'albero.
    vscode.commands.registerCommand("backendLauncher.quickStart", async () => {
      const items: Array<vscode.QuickPickItem & { pn: string; sn: string }> = [];
      forAllProjects(storePath, detectedProjects, (project) => {
        for (const service of project.services) {
          const key = serviceKey(project.name, service.name);
          items.push({
            label: `$(server-process) ${service.name}`,
            description: project.name,
            detail: `${readinessCaption(service.readiness)} · ${tracker.status(key)}`,
            pn: project.name,
            sn: service.name,
          });
        }
      });
      if (items.length === 0) { vscode.window.showInformationMessage("Nessun backend configurato."); return; }
      const pick = await vscode.window.showQuickPick(items, { placeHolder: "Avvia quale backend?" });
      if (pick) { const f = findService(pick.pn, pick.sn); if (f) runner.start(f.project, f.service); }
    }),
  );

  // Notifica quando un servizio si ferma da solo (processo morto / terminale chiuso).
  context.subscriptions.push(runner.onDidServiceClose(async (key) => {
    const name = key.split("/").pop() ?? key;
    const choice = await vscode.window.showWarningMessage(`Backend "${name}" si è fermato.`, "Riavvia");
    if (choice === "Riavvia") {
      const [pn, sn] = splitKey(key);
      const f = findService(pn, sn);
      if (f) runner.start(f.project, f.service);
    }
  }));

  // Status bar: stato aggregato, click → apre la view.
  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusItem.command = "backendLauncherServices.focus";
  const updateStatusBar = () => {
    const snaps = tracker; // usa la mappa interna via status()
    const all = collectServiceKeys(storePath, detectedProjects);
    const running = all.filter((k) => {
      const s = snaps.status(k);
      return s === "running" || s === "starting";
    }).length;
    statusItem.text = `$(server-process) ${running}/${all.length}`;
    statusItem.tooltip = "Backend Launcher — clic per aprire";
    if (all.length > 0) statusItem.show(); else statusItem.hide();
  };
  context.subscriptions.push(statusItem);
  context.subscriptions.push(tracker.onDidChange(updateStatusBar));
  updateStatusBar();

  // Scan automatico all'avvio: se il workspace aperto non è già coperto dai progetti
  // configurati, mostra i backend rilevati (effimeri, avviabili subito).
  const auto = scanWorkspace();
  if (auto.length > 0 && !workspaceAlreadyConfigured(storePath)) {
    setDetected(auto);
  }

  watchStore(storePath, () => provider.refresh(), context);
}

function openUrl(url: string): void {
  vscode.env.openExternal(vscode.Uri.parse(url));
}

/** "Progetto/nome" → [progetto, nome] (il nome può contenere "/"? no: gli id non lo fanno). */
function splitKey(key: string): [string, string] {
  const idx = key.indexOf("/");
  return idx < 0 ? [key, ""] : [key.slice(0, idx), key.slice(idx + 1)];
}

/** Apre il primo file di config noto nella cartella del servizio; se nessuno, la rivela. */
function openServiceFiles(directory: string): void {
  const candidates = ["package.json", "pubspec.yaml", "go.mod", "Cargo.toml",
    "pyproject.toml", "requirements.txt", "pom.xml", "composer.json", "docker-compose.yml"];
  for (const file of candidates) {
    const full = path.join(directory, file);
    if (fs.existsSync(full)) {
      vscode.window.showTextDocument(vscode.Uri.file(full), { preview: false });
      return;
    }
  }
  vscode.commands.executeCommand("revealFileInOS", vscode.Uri.file(directory));
}

async function confirm(message: string, action: string): Promise<boolean> {
  const pick = await vscode.window.showWarningMessage(message, { modal: true }, action);
  return pick === action;
}

/** Itera tutti i progetti (configurati da store + rilevati). */
function forAllProjects(
  storePath: string,
  detected: StoredProject[],
  action: (project: StoredProject) => void,
): void {
  const result = loadStore(storePath);
  if (result.ok) result.projects.forEach(action);
  detected.forEach(action);
}

/** Chiavi di tutti i servizi noti, per lo stato aggregato nella status bar. */
function collectServiceKeys(storePath: string, detected: StoredProject[]): string[] {
  const keys: string[] = [];
  forAllProjects(storePath, detected, (project) => {
    for (const service of project.services) keys.push(serviceKey(project.name, service.name));
  });
  return keys;
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
