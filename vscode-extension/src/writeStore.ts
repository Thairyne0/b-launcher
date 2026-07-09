import * as fs from "fs";
import * as path from "path";
import { StoredProject } from "./store";

export type AppendResult =
  | { ok: true }
  | { ok: false; reason: "duplicate" | "io"; message: string };

/**
 * Aggiunge un progetto al `services.json` PRESERVANDO i campi sconosciuti degli altri
 * progetti (rilegge il JSON grezzo, non la forma normalizzata): l'estensione non deve
 * mai perdere dati scritti dall'app nativa. Nome duplicato → errore. File assente →
 * creato con `version: 1`.
 */
export function appendProject(storePath: string, project: StoredProject): AppendResult {
  let root: { version?: number; projects?: unknown[] } = { version: 1, projects: [] };
  if (fs.existsSync(storePath)) {
    try {
      root = JSON.parse(fs.readFileSync(storePath, "utf8"));
    } catch (e) {
      return { ok: false, reason: "io", message: `services.json illeggibile: ${(e as Error).message}` };
    }
  }
  const projects = Array.isArray(root.projects) ? root.projects : [];
  const nameExists = projects.some(
    (p) => typeof p === "object" && p !== null && (p as { name?: unknown }).name === project.name,
  );
  if (nameExists) {
    return { ok: false, reason: "duplicate", message: `Esiste già un progetto "${project.name}".` };
  }
  const next = {
    ...root,
    version: typeof root.version === "number" ? root.version : 1,
    projects: [...projects, project],
  };
  try {
    fs.mkdirSync(path.dirname(storePath), { recursive: true });
    fs.writeFileSync(storePath, JSON.stringify(next, null, 2), "utf8");
  } catch (e) {
    return { ok: false, reason: "io", message: `Impossibile scrivere services.json: ${(e as Error).message}` };
  }
  return { ok: true };
}
