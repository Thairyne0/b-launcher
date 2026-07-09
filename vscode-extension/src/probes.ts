import * as http from "http";
import * as net from "net";
import { StoredReadiness } from "./store";

export type DisplayStatus = "stopped" | "starting" | "running" | "external";

/** Porta TCP aperta su 127.0.0.1? (probe non bloccante con timeout). */
export function checkPort(port: number, timeoutMs = 500): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let done = false;
    const finish = (open: boolean) => {
      if (done) return;
      done = true;
      socket.destroy();
      resolve(open);
    };
    socket.setTimeout(timeoutMs);
    socket.once("connect", () => finish(true));
    socket.once("timeout", () => finish(false));
    socket.once("error", () => finish(false));
    socket.connect(port, "127.0.0.1");
  });
}

/** GET http://127.0.0.1:port+path → 2xx = pronto, con latenza. Redirect non seguiti. */
export function checkHttp(
  port: number,
  path: string,
  timeoutMs = 1500,
): Promise<{ ok: boolean; latencyMs?: number }> {
  return new Promise((resolve) => {
    const normalizedPath = path.startsWith("/") ? path : `/${path}`;
    const start = Date.now();
    let done = false;
    const finish = (result: { ok: boolean; latencyMs?: number }) => {
      if (done) return;
      done = true;
      resolve(result);
    };
    const req = http.get(
      { host: "127.0.0.1", port, path: normalizedPath, timeout: timeoutMs },
      (res) => {
        const status = res.statusCode ?? 0;
        res.resume(); // scarta il body
        finish({ ok: status >= 200 && status < 300, latencyMs: Date.now() - start });
      },
    );
    req.once("timeout", () => { req.destroy(); finish({ ok: false }); });
    req.once("error", () => finish({ ok: false }));
  });
}

/**
 * Deriva lo stato visuale (puro, testabile) dai segnali:
 *  - `alive`: un terminale del servizio è vivo (lo abbiamo avviato noi);
 *  - `portOpen`/`httpOk`: esito dei probe (undefined = non applicabile/non ancora fatto).
 *
 * Regole coerenti con l'app nativa: readiness a porta/http → "starting" finché il probe
 * non passa; se NON nostro ma la porta è aperta → "external". processAlive/logMarker →
 * "running" appena vivo (l'output del terminale non è leggibile in VSCode per il marker).
 */
export function deriveStatus(
  alive: boolean,
  readiness: StoredReadiness,
  portOpen: boolean | undefined,
  httpOk: boolean | undefined,
): DisplayStatus {
  switch (readiness.kind) {
    case "processAlive":
    case "logMarker":
      return alive ? "running" : "stopped";
    case "port":
      if (alive) return portOpen ? "running" : "starting";
      return portOpen ? "external" : "stopped";
    case "httpHealth":
      if (alive) return httpOk ? "running" : "starting";
      return portOpen ? "external" : "stopped";
  }
}
