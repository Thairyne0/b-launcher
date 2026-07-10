import * as fs from "fs";
import * as os from "os";
import * as path from "path";

/**
 * Tipi che rispecchiano lo schema di `services.json` dell'app nativa (Swift). Solo i campi
 * che servono all'estensione; i campi sconosciuti nel file vengono ignorati (forward-compat
 * con schemi futuri). Tutto opzionale dove lo schema è additivo tra v1 e v2.
 */
export interface StoredReadiness {
  kind: "port" | "logMarker" | "processAlive" | "httpHealth";
  port?: number;
  marker?: string;
  path?: string;
}

export interface StoredServiceTask {
  name: string;
  command: string;
}

export interface StoredService {
  name: string;
  directory: string;
  command: string;
  readiness: StoredReadiness;
  appURL?: string;
  isMainApp?: boolean;
  commandVariants?: string[];
  startAfter?: string[];
  tasks?: StoredServiceTask[];
}

export interface StoredInfraCheck {
  label: string;
  port: number;
}

export interface StoredProject {
  name: string;
  services: StoredService[];
  infraCheck?: StoredInfraCheck;
  accentColorHex?: string;
}

export type LoadResult =
  | { ok: true; version: number; projects: StoredProject[] }
  | { ok: false; reason: "missing" | "invalid"; message: string };

/** Path di default su macOS, identico a quello scritto dall'app nativa. */
export function defaultStorePath(): string {
  return path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "BackendLauncher",
    "services.json",
  );
}

/**
 * Parsing puro (testabile senza filesystem): valida la forma minima (version numero,
 * projects array) e normalizza i servizi. Contenuto malformato → `invalid`.
 */
export function parseStore(raw: string): LoadResult {
  let root: unknown;
  try {
    root = JSON.parse(raw);
  } catch {
    return { ok: false, reason: "invalid", message: "services.json non è JSON valido." };
  }
  if (typeof root !== "object" || root === null) {
    return { ok: false, reason: "invalid", message: "services.json ha una forma inattesa." };
  }
  const obj = root as Record<string, unknown>;
  const version = typeof obj.version === "number" ? obj.version : 1;
  const rawProjects = Array.isArray(obj.projects) ? obj.projects : [];
  const projects: StoredProject[] = rawProjects
    .map(normalizeProject)
    .filter((p): p is StoredProject => p !== null);
  return { ok: true, version, projects };
}

/** Legge e parse il file. File assente → `missing` (caso normale: app nativa mai avviata). */
export function loadStore(filePath: string = defaultStorePath()): LoadResult {
  let raw: string;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch (e) {
    const err = e as NodeJS.ErrnoException;
    if (err.code === "ENOENT") {
      return { ok: false, reason: "missing", message: "services.json non trovato." };
    }
    return { ok: false, reason: "invalid", message: `Impossibile leggere services.json: ${err.message}` };
  }
  return parseStore(raw);
}

function normalizeProject(value: unknown): StoredProject | null {
  if (typeof value !== "object" || value === null) return null;
  const obj = value as Record<string, unknown>;
  if (typeof obj.name !== "string") return null;
  const rawServices = Array.isArray(obj.services) ? obj.services : [];
  const services = rawServices
    .map(normalizeService)
    .filter((s): s is StoredService => s !== null);
  const project: StoredProject = { name: obj.name, services };
  if (isInfraCheck(obj.infraCheck)) project.infraCheck = obj.infraCheck;
  if (typeof obj.accentColorHex === "string") project.accentColorHex = obj.accentColorHex;
  return project;
}

function normalizeService(value: unknown): StoredService | null {
  if (typeof value !== "object" || value === null) return null;
  const obj = value as Record<string, unknown>;
  if (typeof obj.name !== "string" || typeof obj.directory !== "string") return null;
  const command = typeof obj.command === "string" ? obj.command : "";
  const readiness = normalizeReadiness(obj.readiness);
  const service: StoredService = { name: obj.name, directory: obj.directory, command, readiness };
  if (typeof obj.appURL === "string") service.appURL = obj.appURL;
  if (obj.isMainApp === true) service.isMainApp = true;
  if (Array.isArray(obj.commandVariants)) {
    service.commandVariants = obj.commandVariants.filter((v): v is string => typeof v === "string");
  }
  if (Array.isArray(obj.startAfter)) {
    service.startAfter = obj.startAfter.filter((v): v is string => typeof v === "string");
  }
  if (Array.isArray(obj.tasks)) {
    service.tasks = obj.tasks
      .filter((t): t is { name: string; command: string } =>
        typeof t === "object" && t !== null
        && typeof (t as { name?: unknown }).name === "string"
        && typeof (t as { command?: unknown }).command === "string")
      .map((t) => ({ name: t.name, command: t.command }));
  }
  return service;
}

function normalizeReadiness(value: unknown): StoredReadiness {
  const fallback: StoredReadiness = { kind: "processAlive" };
  if (typeof value !== "object" || value === null) return fallback;
  const obj = value as Record<string, unknown>;
  const kind = obj.kind;
  if (kind !== "port" && kind !== "logMarker" && kind !== "processAlive" && kind !== "httpHealth") {
    return fallback;
  }
  const readiness: StoredReadiness = { kind };
  if (typeof obj.port === "number") readiness.port = obj.port;
  if (typeof obj.marker === "string") readiness.marker = obj.marker;
  if (typeof obj.path === "string") readiness.path = obj.path;
  return readiness;
}

function isInfraCheck(value: unknown): value is StoredInfraCheck {
  if (typeof value !== "object" || value === null) return false;
  const obj = value as Record<string, unknown>;
  return typeof obj.label === "string" && typeof obj.port === "number";
}

/** Riepilogo leggibile della readiness, coerente col linguaggio dell'app nativa. */
export function readinessCaption(readiness: StoredReadiness): string {
  switch (readiness.kind) {
    case "port":
      return `porta ${readiness.port ?? "?"}`;
    case "logMarker":
      return "via log";
    case "httpHealth":
      return `health :${readiness.port ?? "?"}${readiness.path ?? "/health"}`;
    case "processAlive":
      return "sempre pronto";
  }
}
