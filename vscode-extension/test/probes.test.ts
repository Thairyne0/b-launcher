import { describe, it, expect, afterEach } from "vitest";
import * as http from "http";
import * as net from "net";
import { checkPort, checkHttp, deriveStatus } from "../src/probes";

describe("checkPort", () => {
  let server: net.Server | undefined;
  afterEach(() => server?.close());

  it("true su porta in ascolto, false su porta chiusa", async () => {
    server = net.createServer();
    const port: number = await new Promise((resolve) => {
      server!.listen(0, "127.0.0.1", () => resolve((server!.address() as net.AddressInfo).port));
    });
    expect(await checkPort(port)).toBe(true);
    expect(await checkPort(1, 200)).toBe(false);
  });
});

describe("checkHttp", () => {
  let server: http.Server | undefined;
  afterEach(() => server?.close());

  it("2xx → ok con latenza; 500 → non ok", async () => {
    server = http.createServer((req, res) => {
      res.statusCode = req.url === "/health" ? 200 : 500;
      res.end();
    });
    const port: number = await new Promise((resolve) => {
      server!.listen(0, "127.0.0.1", () => resolve((server!.address() as net.AddressInfo).port));
    });
    const good = await checkHttp(port, "/health");
    expect(good.ok).toBe(true);
    expect(good.latencyMs).toBeGreaterThanOrEqual(0);
    const bad = await checkHttp(port, "/altro");
    expect(bad.ok).toBe(false);
  });

  it("porta chiusa → non ok, niente latenza", async () => {
    const result = await checkHttp(1, "/health", 300);
    expect(result.ok).toBe(false);
    expect(result.latencyMs).toBeUndefined();
  });
});

describe("deriveStatus", () => {
  it("processAlive/logMarker: running se vivo, altrimenti stopped", () => {
    expect(deriveStatus(true, { kind: "processAlive" }, undefined, undefined)).toBe("running");
    expect(deriveStatus(false, { kind: "processAlive" }, undefined, undefined)).toBe("stopped");
    expect(deriveStatus(true, { kind: "logMarker", marker: "x" }, undefined, undefined)).toBe("running");
  });

  it("port: vivo+porta aperta=running, vivo+chiusa=starting", () => {
    const r = { kind: "port" as const, port: 4000 };
    expect(deriveStatus(true, r, true, undefined)).toBe("running");
    expect(deriveStatus(true, r, false, undefined)).toBe("starting");
  });

  it("port: non nostro ma porta aperta = external; chiusa = stopped", () => {
    const r = { kind: "port" as const, port: 4000 };
    expect(deriveStatus(false, r, true, undefined)).toBe("external");
    expect(deriveStatus(false, r, false, undefined)).toBe("stopped");
  });

  it("httpHealth: vivo+2xx=running, vivo+no=starting, esterno via porta", () => {
    const r = { kind: "httpHealth" as const, port: 9000, path: "/health" };
    expect(deriveStatus(true, r, undefined, true)).toBe("running");
    expect(deriveStatus(true, r, undefined, false)).toBe("starting");
    expect(deriveStatus(false, r, true, false)).toBe("external");
    expect(deriveStatus(false, r, false, false)).toBe("stopped");
  });
});
