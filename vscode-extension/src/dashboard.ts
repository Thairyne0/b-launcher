import * as vscode from "vscode";
import { DisplayStatus } from "./probes";

/** Vista di un servizio per la dashboard (già calcolata dal chiamante). */
export interface ServiceView {
  name: string;
  status: DisplayStatus;
  readiness: string;
  alive: boolean;
  hasUrl: boolean;
}

export interface DashboardController {
  getServices(projectName: string): ServiceView[];
  onDidChange: vscode.Event<void>;
  start(projectName: string, serviceName: string): void;
  stop(projectName: string, serviceName: string): void;
  restart(projectName: string, serviceName: string): void;
  openTerminal(projectName: string, serviceName: string): void;
  openBrowser(projectName: string, serviceName: string): void;
  sendInput(projectName: string, serviceName: string, text: string): void;
  startAll(projectName: string): void;
  stopAll(projectName: string): void;
  startStack(projectName: string): void;
}

interface InboundMessage {
  type: string;
  service?: string;
  text?: string;
}

/**
 * Dashboard "mission control" di un progetto in un pannello webview: una card per servizio
 * (stato, readiness, controlli, input comando). I terminali PTY veri restano a un click
 * ("Terminale"). Themed con le variabili colore di VSCode → nativa e leggibile ovunque.
 */
export class DashboardPanel {
  private static current: DashboardPanel | undefined;

  static show(controller: DashboardController, projectName: string): void {
    if (DashboardPanel.current) {
      DashboardPanel.current.projectName = projectName;
      DashboardPanel.current.panel.title = `Dashboard · ${projectName}`;
      DashboardPanel.current.panel.reveal(vscode.ViewColumn.Active);
      DashboardPanel.current.render();
      return;
    }
    const panel = vscode.window.createWebviewPanel(
      "backendLauncherDashboard",
      `Dashboard · ${projectName}`,
      vscode.ViewColumn.Active,
      { enableScripts: true, retainContextWhenHidden: true },
    );
    DashboardPanel.current = new DashboardPanel(panel, controller, projectName);
  }

  private constructor(
    private readonly panel: vscode.WebviewPanel,
    private readonly controller: DashboardController,
    private projectName: string,
  ) {
    this.panel.webview.html = this.buildHtml();
    this.render();

    const changeSub = controller.onDidChange(() => this.render());
    this.panel.webview.onDidReceiveMessage((msg: InboundMessage) => this.handle(msg));
    this.panel.onDidDispose(() => {
      changeSub.dispose();
      DashboardPanel.current = undefined;
    });
  }

  private handle(msg: InboundMessage): void {
    const p = this.projectName;
    const s = msg.service ?? "";
    switch (msg.type) {
      case "start": this.controller.start(p, s); break;
      case "stop": this.controller.stop(p, s); break;
      case "restart": this.controller.restart(p, s); break;
      case "terminal": this.controller.openTerminal(p, s); break;
      case "browser": this.controller.openBrowser(p, s); break;
      case "send": if (msg.text) this.controller.sendInput(p, s, msg.text); break;
      case "startAll": this.controller.startAll(p); break;
      case "stopAll": this.controller.stopAll(p); break;
      case "startStack": this.controller.startStack(p); break;
    }
  }

  private render(): void {
    this.panel.webview.postMessage({
      type: "state",
      project: this.projectName,
      services: this.controller.getServices(this.projectName),
    });
  }

  private buildHtml(): string {
    const nonce = makeNonce();
    const csp = `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';`;
    return /* html */ `<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta http-equiv="Content-Security-Policy" content="${csp}">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<style>${STYLE}</style>
</head>
<body>
  <header class="topbar">
    <div class="title"><span class="dot-brand"></span><span id="projectName">—</span></div>
    <div class="actions">
      <button class="btn primary" data-global="startStack">Avvia stack</button>
      <button class="btn" data-global="startAll">Avvia tutti</button>
      <button class="btn danger" data-global="stopAll">Ferma tutti</button>
    </div>
  </header>
  <main id="grid" class="grid"></main>
  <script nonce="${nonce}">${SCRIPT}</script>
</body>
</html>`;
  }

  dispose(): void {
    this.panel.dispose();
  }
}

function makeNonce(): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  let out = "";
  for (let i = 0; i < 24; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

const STYLE = /* css */ `
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 0;
  font-family: var(--vscode-font-family);
  font-size: var(--vscode-font-size);
  color: var(--vscode-foreground);
  background: var(--vscode-editor-background);
}
.topbar {
  position: sticky; top: 0; z-index: 5;
  display: flex; align-items: center; justify-content: space-between;
  gap: 16px; padding: 14px 20px;
  background: var(--vscode-editor-background);
  border-bottom: 1px solid var(--vscode-panel-border);
}
.title { display: flex; align-items: center; gap: 10px; font-size: 1.25em; font-weight: 600; }
.dot-brand { width: 10px; height: 10px; border-radius: 3px; background: var(--vscode-textLink-foreground); }
.actions { display: flex; gap: 8px; }
.grid {
  display: grid; gap: 16px; padding: 20px;
  grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
}
.card {
  display: flex; flex-direction: column; gap: 12px;
  padding: 16px; border-radius: 12px;
  background: var(--vscode-editorWidget-background, rgba(127,127,127,0.06));
  border: 1px solid var(--vscode-panel-border);
  transition: border-color .15s ease, transform .15s ease;
}
.card:hover { border-color: var(--vscode-focusBorder); }
.card-head { display: flex; align-items: center; gap: 10px; }
.dot { width: 12px; height: 12px; border-radius: 50%; flex: 0 0 auto; box-shadow: 0 0 0 3px transparent; }
.dot.running { background: #3fb950; box-shadow: 0 0 8px 1px rgba(63,185,80,.5); }
.dot.starting { background: #d6a52a; }
.dot.external { background: #4a8cff; }
.dot.stopped { background: var(--vscode-disabledForeground); }
.name { font-weight: 600; font-size: 1.05em; }
.meta { margin-left: auto; font-size: .82em; opacity: .75; }
.status-line { font-size: .85em; opacity: .85; }
.controls { display: flex; gap: 6px; flex-wrap: wrap; }
.btn {
  font: inherit; font-size: .85em; cursor: pointer;
  padding: 5px 12px; border-radius: 7px;
  border: 1px solid var(--vscode-button-border, transparent);
  background: var(--vscode-button-secondaryBackground, rgba(127,127,127,.15));
  color: var(--vscode-button-secondaryForeground, var(--vscode-foreground));
}
.btn:hover { background: var(--vscode-button-secondaryHoverBackground, rgba(127,127,127,.28)); }
.btn.primary { background: var(--vscode-button-background); color: var(--vscode-button-foreground); border-color: transparent; }
.btn.primary:hover { background: var(--vscode-button-hoverBackground); }
.btn.danger { background: transparent; color: #f07171; border-color: rgba(240,113,113,.4); }
.btn.danger:hover { background: rgba(240,113,113,.12); }
.btn:disabled { opacity: .4; cursor: default; }
.cmd { display: flex; gap: 6px; }
.cmd input {
  flex: 1; font: inherit; font-size: .85em;
  padding: 5px 10px; border-radius: 7px;
  color: var(--vscode-input-foreground);
  background: var(--vscode-input-background);
  border: 1px solid var(--vscode-input-border, var(--vscode-panel-border));
}
.cmd input::placeholder { color: var(--vscode-input-placeholderForeground); }
.empty { grid-column: 1/-1; text-align: center; opacity: .6; padding: 60px 20px; }
`;

const SCRIPT = /* js */ `
const vscode = acquireVsCodeApi();
const grid = document.getElementById('grid');
const projectName = document.getElementById('projectName');

document.querySelectorAll('[data-global]').forEach((b) => {
  b.addEventListener('click', () => vscode.postMessage({ type: b.dataset.global }));
});

const LABEL = { running: 'in esecuzione', starting: 'avvio…', external: 'esterno', stopped: 'fermo' };

window.addEventListener('message', (e) => {
  const msg = e.data;
  if (msg.type !== 'state') return;
  projectName.textContent = msg.project;
  render(msg.services);
});

function render(services) {
  grid.innerHTML = '';
  if (!services.length) {
    const d = document.createElement('div');
    d.className = 'empty';
    d.textContent = 'Nessun servizio in questo progetto.';
    grid.appendChild(d);
    return;
  }
  for (const s of services) grid.appendChild(card(s));
}

function card(s) {
  const el = document.createElement('div');
  el.className = 'card';

  const head = document.createElement('div');
  head.className = 'card-head';
  head.innerHTML =
    '<span class="dot ' + s.status + '"></span>' +
    '<span class="name"></span>' +
    '<span class="meta"></span>';
  head.querySelector('.name').textContent = s.name;
  head.querySelector('.meta').textContent = LABEL[s.status] || s.status;
  el.appendChild(head);

  const status = document.createElement('div');
  status.className = 'status-line';
  status.textContent = s.readiness;
  el.appendChild(status);

  const controls = document.createElement('div');
  controls.className = 'controls';
  if (s.alive) {
    controls.appendChild(btn('Ferma', 'stop', s.name, 'danger'));
    controls.appendChild(btn('Riavvia', 'restart', s.name));
    controls.appendChild(btn('Terminale', 'terminal', s.name));
  } else {
    controls.appendChild(btn('Avvia', 'start', s.name, 'primary'));
  }
  if (s.hasUrl) controls.appendChild(btn('Browser', 'browser', s.name));
  el.appendChild(controls);

  if (s.alive) {
    const cmd = document.createElement('div');
    cmd.className = 'cmd';
    const input = document.createElement('input');
    input.placeholder = 'Invia allo stdin…';
    input.addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' && input.value) {
        vscode.postMessage({ type: 'send', service: s.name, text: input.value });
        input.value = '';
      }
    });
    const send = btn('Invia', null, s.name);
    send.addEventListener('click', () => {
      if (input.value) { vscode.postMessage({ type: 'send', service: s.name, text: input.value }); input.value = ''; }
    });
    cmd.appendChild(input);
    cmd.appendChild(send);
    el.appendChild(cmd);
  }
  return el;
}

function btn(label, type, service, cls) {
  const b = document.createElement('button');
  b.className = 'btn' + (cls ? ' ' + cls : '');
  b.textContent = label;
  if (type) b.addEventListener('click', () => vscode.postMessage({ type, service }));
  return b;
}
`;
