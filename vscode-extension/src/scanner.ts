import * as fs from "fs";
import * as path from "path";
import { StoredReadiness, StoredService } from "./store";

/**
 * Rilevamento deterministico dei backend in una cartella (porta la logica di
 * `ProjectScanner` dell'app nativa in TypeScript). Nessuna rete, nessuna AI: solo
 * convenzioni. Ritorna servizi nella stessa forma di `StoredService`, così l'albero e
 * il runner li trattano come quelli configurati.
 */

const EXCLUDED_DIRS = new Set(["node_modules", ".git", "dist", "build", "vendor", "target"]);
const NPM_SCRIPT_PRIORITY = ["start:dev", "dev", "serve", "start"];
const ENV_PORT_KEYS = ["APP_PORT", "PORT", "SERVER_PORT"];
const INFRA_NEEDLES = ["nats", "redis", "postgres", "mongo", "rabbitmq"];
const NEST_MARKER = "successfully started";

const processAlive: StoredReadiness = { kind: "processAlive" };

export function scanDirectory(root: string): StoredService[] {
  const candidates: string[] = [root];
  let entries: fs.Dirent[] = [];
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return [];
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    if (entry.name.startsWith(".") || EXCLUDED_DIRS.has(entry.name)) continue;
    candidates.push(path.join(root, entry.name));
  }

  const detected: StoredService[] = [];
  for (const dir of candidates) {
    const service = scanServiceDir(dir, root);
    if (service) detected.push(service);
  }
  detected.push(...scanComposeServices(root));

  detected.sort((a, b) => a.name.localeCompare(b.name));
  return downgradeDuplicatePorts(detected);
}

function scanServiceDir(dir: string, root: string): StoredService | null {
  const name = (dir === root ? path.basename(root) : path.basename(dir)).toLowerCase();
  const has = (file: string) => fs.existsSync(path.join(dir, file));
  const read = (file: string): string | null => {
    try { return fs.readFileSync(path.join(dir, file), "utf8"); } catch { return null; }
  };

  // Node / NestJS
  const pkgRaw = read("package.json");
  if (pkgRaw) {
    const node = scanNode(dir, name, pkgRaw);
    if (node) return node;
  }
  if (has("go.mod")) return svc(name, "go run .", readiness(dir, false), dir);
  if (has("Cargo.toml")) return svc(name, "cargo run", readiness(dir, false), dir);
  if (has("pubspec.yaml")) return svc(name, "flutter run", processAlive, dir);

  // Python
  if (has("manage.py")) return svc(name, "python manage.py runserver", readiness(dir, false), dir);
  for (const manifest of ["pyproject.toml", "requirements.txt"]) {
    const text = read(manifest);
    if (!text) continue;
    const lower = text.toLowerCase();
    if (lower.includes("fastapi")) return svc(name, "uvicorn main:app --reload", readiness(dir, false), dir);
    if (lower.includes("flask")) return svc(name, "flask run", readiness(dir, false), dir);
    if (has("main.py")) return svc(name, "python main.py", readiness(dir, false), dir);
  }

  // Java / Spring
  const pom = read("pom.xml");
  if (pom && pom.toLowerCase().includes("spring-boot")) {
    return svc(name, has("mvnw") ? "./mvnw spring-boot:run" : "mvn spring-boot:run", readiness(dir, false), dir);
  }
  for (const gradleFile of ["build.gradle", "build.gradle.kts"]) {
    const gradle = read(gradleFile);
    if (gradle && (gradle.toLowerCase().includes("springframework") || gradle.toLowerCase().includes("spring-boot"))) {
      return svc(name, has("gradlew") ? "./gradlew bootRun" : "gradle bootRun", readiness(dir, false), dir);
    }
  }

  // PHP
  if (has("artisan")) return svc(name, "php artisan serve", { kind: "port", port: 8000 }, dir);
  if (has("composer.json") && has("index.php")) return svc(name, "php -S localhost:8080", { kind: "port", port: 8080 }, dir);

  return null;
}

function scanNode(dir: string, name: string, pkgRaw: string): StoredService | null {
  let pkg: Record<string, unknown>;
  try { pkg = JSON.parse(pkgRaw); } catch { return null; }
  const scripts = (pkg.scripts ?? {}) as Record<string, unknown>;
  const script = NPM_SCRIPT_PRIORITY.find((s) => typeof scripts[s] === "string");
  if (!script) return null;
  const has = (file: string) => fs.existsSync(path.join(dir, file));
  const command = has("pnpm-lock.yaml") ? `pnpm run ${script}`
    : has("yarn.lock") ? `yarn ${script}`
    : `npm run ${script}`;
  const deps = (pkg.dependencies ?? {}) as Record<string, unknown>;
  const isNest = deps["@nestjs/core"] !== undefined;
  return svc(name, command, readiness(dir, isNest), dir);
}

function readiness(dir: string, isNest: boolean): StoredReadiness {
  const port = portFromEnv(dir);
  if (port !== undefined) return { kind: "port", port };
  if (isNest) return { kind: "logMarker", marker: NEST_MARKER };
  return processAlive;
}

function portFromEnv(dir: string): number | undefined {
  let contents: string;
  try { contents = fs.readFileSync(path.join(dir, ".env"), "utf8"); } catch { return undefined; }
  const values = new Map<string, string>();
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    values.set(line.slice(0, eq).trim(), normalizeEnvValue(line.slice(eq + 1).trim()));
  }
  for (const key of ENV_PORT_KEYS) {
    const raw = values.get(key);
    const port = raw !== undefined ? Number.parseInt(raw, 10) : NaN;
    if (Number.isInteger(port) && port > 0 && port < 65536) return port;
  }
  return undefined;
}

function normalizeEnvValue(raw: string): string {
  const quote = raw[0];
  if (quote === '"' || quote === "'") {
    const close = raw.indexOf(quote, 1);
    if (close > 0) return raw.slice(1, close);
  }
  const comment = raw.indexOf(" #");
  return comment >= 0 ? raw.slice(0, comment).trim() : raw;
}

// docker-compose: servizi top-level, esclusa l'infrastruttura, porta host dalla sintassi breve.
function scanComposeServices(root: string): StoredService[] {
  const fileName = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    .find((f) => fs.existsSync(path.join(root, f)));
  if (!fileName) return [];
  let text: string;
  try { text = fs.readFileSync(path.join(root, fileName), "utf8"); } catch { return []; }

  const services: StoredService[] = [];
  let inServices = false;
  let current: string | null = null;
  let isInfra = false;
  let hostPort: number | undefined;
  let inPorts = false;

  const flush = () => {
    if (current && !isInfra) {
      const r: StoredReadiness = hostPort !== undefined ? { kind: "port", port: hostPort } : processAlive;
      services.push(svc(current, `docker compose up ${current}`, r, root));
    }
    current = null; isInfra = false; hostPort = undefined; inPorts = false;
  };

  for (const rawLine of text.split(/\r?\n/)) {
    const trimmed = rawLine.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const indent = rawLine.length - rawLine.trimStart().length;
    if (indent === 0) { flush(); inServices = trimmed === "services:"; continue; }
    if (!inServices) continue;
    if (indent === 2 && trimmed.endsWith(":") && !trimmed.includes(" ")) {
      flush();
      current = trimmed.slice(0, -1).toLowerCase();
      isInfra = INFRA_NEEDLES.some((n) => current!.includes(n));
      continue;
    }
    if (!current) continue;
    if (trimmed.startsWith("image:")) {
      const image = trimmed.slice("image:".length).trim().toLowerCase();
      if (INFRA_NEEDLES.some((n) => image.includes(n))) isInfra = true;
    } else if (trimmed === "ports:") {
      inPorts = true;
    } else if (inPorts && trimmed.startsWith("-")) {
      if (hostPort === undefined) hostPort = composeHostPort(trimmed);
    } else if (!trimmed.startsWith("-")) {
      inPorts = false;
    }
  }
  flush();
  return services;
}

function composeHostPort(entry: string): number | undefined {
  const value = entry.replace(/^-/, "").trim().replace(/^["']|["']$/g, "");
  const parts = value.split(":");
  if (parts.length < 2) return undefined;
  const port = Number.parseInt(parts[parts.length - 2], 10);
  return Number.isInteger(port) ? port : undefined;
}

/** Due servizi sulla stessa porta: il secondo (per ordine) perde la readiness a porta. */
function downgradeDuplicatePorts(services: StoredService[]): StoredService[] {
  const seen = new Set<number>();
  return services.map((service) => {
    const port = service.readiness.kind === "port" ? service.readiness.port : undefined;
    if (port === undefined) return service;
    if (seen.has(port)) return { ...service, readiness: processAlive };
    seen.add(port);
    return service;
  });
}

function svc(name: string, command: string, readinessValue: StoredReadiness, directory = ""): StoredService {
  return { name, directory, command, readiness: readinessValue };
}
