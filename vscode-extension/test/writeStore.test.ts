import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { appendProject } from "../src/writeStore";
import { StoredProject } from "../src/store";

describe("appendProject", () => {
  let dir: string;
  let storePath: string;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "blauncher-write-"));
    storePath = path.join(dir, "services.json");
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const project: StoredProject = {
    name: "Nuovo",
    services: [{ name: "web", directory: "/x", command: "npm run dev", readiness: { kind: "port", port: 5173 } }],
  };

  it("crea il file se manca", () => {
    const result = appendProject(storePath, project);
    expect(result.ok).toBe(true);
    const written = JSON.parse(fs.readFileSync(storePath, "utf8"));
    expect(written.version).toBe(1);
    expect(written.projects).toHaveLength(1);
    expect(written.projects[0].name).toBe("Nuovo");
  });

  it("preserva progetti e campi sconosciuti esistenti", () => {
    fs.writeFileSync(storePath, JSON.stringify({
      version: 2,
      projects: [{ name: "Esistente", services: [], campoIgnoto: 42 }],
    }));
    const result = appendProject(storePath, project);
    expect(result.ok).toBe(true);
    const written = JSON.parse(fs.readFileSync(storePath, "utf8"));
    expect(written.version).toBe(2);
    expect(written.projects).toHaveLength(2);
    expect(written.projects[0].campoIgnoto).toBe(42); // campo ignoto non perso
    expect(written.projects[1].name).toBe("Nuovo");
  });

  it("nome duplicato → errore, file invariato", () => {
    fs.writeFileSync(storePath, JSON.stringify({ version: 1, projects: [{ name: "Nuovo", services: [] }] }));
    const before = fs.readFileSync(storePath, "utf8");
    const result = appendProject(storePath, project);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.reason).toBe("duplicate");
    expect(fs.readFileSync(storePath, "utf8")).toBe(before);
  });
});
