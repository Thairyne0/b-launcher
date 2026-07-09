import * as vscode from "vscode";
import { StoredReadiness } from "./store";
import { checkHttp, checkPort, deriveStatus, DisplayStatus } from "./probes";

/** Snapshot di un servizio per il calcolo dello stato: chiave, readiness, se è vivo (nostro). */
export interface ServiceSnapshot {
  key: string;
  readiness: StoredReadiness;
  alive: boolean;
}

/**
 * Calcola periodicamente lo stato visuale (stopped/starting/running/external) di ogni
 * servizio via probe porta/http, e lo espone all'albero. Emette un evento quando qualche
 * stato cambia, così l'albero si ridisegna solo quando serve.
 */
export class StatusTracker {
  private statuses = new Map<string, DisplayStatus>();
  private readonly changeEmitter = new vscode.EventEmitter<void>();
  readonly onDidChange = this.changeEmitter.event;
  private timer: NodeJS.Timeout | undefined;

  constructor(private readonly getSnapshots: () => ServiceSnapshot[]) {}

  status(key: string): DisplayStatus {
    return this.statuses.get(key) ?? "stopped";
  }

  start(intervalMs = 2000): void {
    if (this.timer) return;
    void this.pollOnce();
    this.timer = setInterval(() => void this.pollOnce(), intervalMs);
  }

  /** Un giro di probe: aggiorna la mappa e notifica se qualcosa è cambiato. */
  async pollOnce(): Promise<void> {
    const snapshots = this.getSnapshots();
    const next = new Map<string, DisplayStatus>();
    await Promise.all(
      snapshots.map(async (snap) => {
        next.set(snap.key, await this.computeStatus(snap));
      }),
    );
    if (!sameStatuses(this.statuses, next)) {
      this.statuses = next;
      this.changeEmitter.fire();
    }
  }

  private async computeStatus(snap: ServiceSnapshot): Promise<DisplayStatus> {
    const { readiness, alive } = snap;
    if (readiness.kind === "processAlive" || readiness.kind === "logMarker") {
      return deriveStatus(alive, readiness, undefined, undefined);
    }
    const port = readiness.port;
    if (port === undefined) return alive ? "running" : "stopped";
    if (readiness.kind === "port") {
      return deriveStatus(alive, readiness, await checkPort(port), undefined);
    }
    // httpHealth: se è nostro serve il 2xx; se non è nostro basta la porta per "external".
    const httpOk = alive ? (await checkHttp(port, readiness.path ?? "/health")).ok : undefined;
    const portOpen = alive ? undefined : await checkPort(port);
    return deriveStatus(alive, readiness, portOpen, httpOk);
  }

  dispose(): void {
    if (this.timer) clearInterval(this.timer);
    this.changeEmitter.dispose();
  }
}

function sameStatuses(a: Map<string, DisplayStatus>, b: Map<string, DisplayStatus>): boolean {
  if (a.size !== b.size) return false;
  for (const [key, value] of a) {
    if (b.get(key) !== value) return false;
  }
  return true;
}
