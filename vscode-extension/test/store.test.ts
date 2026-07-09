import { describe, it, expect } from "vitest";
import { parseStore, readinessCaption } from "../src/store";

describe("parseStore", () => {
  it("legge progetti e servizi validi", () => {
    const raw = JSON.stringify({
      version: 2,
      projects: [
        {
          name: "Skillera",
          services: [
            { name: "gateway", directory: "/x/gw", command: "npm run start:dev",
              readiness: { kind: "port", port: 4000 } },
          ],
          infraCheck: { label: "NATS", port: 4222 },
        },
      ],
    });
    const result = parseStore(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.version).toBe(2);
    expect(result.projects).toHaveLength(1);
    expect(result.projects[0].name).toBe("Skillera");
    expect(result.projects[0].services[0].name).toBe("gateway");
    expect(result.projects[0].services[0].readiness.port).toBe(4000);
    expect(result.projects[0].infraCheck?.label).toBe("NATS");
  });

  it("tollera campi sconosciuti e schema v1 senza chiavi nuove", () => {
    const raw = JSON.stringify({
      version: 1,
      projects: [
        { name: "Legacy", services: [
          { name: "svc", directory: "/x", command: "true", readiness: { kind: "processAlive" },
            chiaveFutura: 123 },
        ] },
      ],
      extra: "ignorato",
    });
    const result = parseStore(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.projects[0].services[0].name).toBe("svc");
  });

  it("scarta servizi senza campi obbligatori ma tiene gli altri", () => {
    const raw = JSON.stringify({
      version: 1,
      projects: [{ name: "P", services: [
        { name: "buono", directory: "/x", command: "true", readiness: { kind: "processAlive" } },
        { directory: "/y" },
      ] }],
    });
    const result = parseStore(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.projects[0].services).toHaveLength(1);
    expect(result.projects[0].services[0].name).toBe("buono");
  });

  it("JSON non valido → invalid", () => {
    const result = parseStore("{ non json");
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("invalid");
  });

  it("readiness mancante → processAlive di default", () => {
    const raw = JSON.stringify({ version: 1, projects: [{ name: "P", services: [
      { name: "s", directory: "/x", command: "true" },
    ] }] });
    const result = parseStore(raw);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.projects[0].services[0].readiness.kind).toBe("processAlive");
  });
});

describe("readinessCaption", () => {
  it("porta / log / health / sempre pronto", () => {
    expect(readinessCaption({ kind: "port", port: 4000 })).toBe("porta 4000");
    expect(readinessCaption({ kind: "logMarker", marker: "x" })).toBe("via log");
    expect(readinessCaption({ kind: "httpHealth", port: 9000, path: "/status" })).toBe("health :9000/status");
    expect(readinessCaption({ kind: "processAlive" })).toBe("sempre pronto");
  });
});
