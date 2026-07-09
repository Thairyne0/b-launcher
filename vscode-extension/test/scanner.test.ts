import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { scanDirectory } from "../src/scanner";

describe("scanDirectory", () => {
  let root: string;

  beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), "blauncher-scan-"));
  });
  afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
  });

  const write = (rel: string, content: string) => {
    const full = path.join(root, rel);
    fs.mkdirSync(path.dirname(full), { recursive: true });
    fs.writeFileSync(full, content);
  };

  it("rileva un backend Node/Nest con porta dal .env", () => {
    write("gateway/package.json", JSON.stringify({
      scripts: { "start:dev": "nest start --watch" },
      dependencies: { "@nestjs/core": "^10.0.0" },
    }));
    write("gateway/.env", "PORT=4000\n");

    const services = scanDirectory(root);
    expect(services).toHaveLength(1);
    expect(services[0].name).toBe("gateway");
    expect(services[0].command).toBe("npm run start:dev");
    expect(services[0].readiness).toEqual({ kind: "port", port: 4000 });
    expect(services[0].directory).toBe(path.join(root, "gateway"));
  });

  it("Nest senza porta → marker; pnpm/yarn cambiano il comando", () => {
    write("api/package.json", JSON.stringify({
      scripts: { start: "nest start" },
      dependencies: { "@nestjs/core": "^10" },
    }));
    write("api/pnpm-lock.yaml", "");
    const services = scanDirectory(root);
    expect(services[0].command).toBe("pnpm run start");
    expect(services[0].readiness).toEqual({ kind: "logMarker", marker: "successfully started" });
  });

  it("rileva Flutter, Go, Python FastAPI", () => {
    write("mobile/pubspec.yaml", "name: app\n");
    write("svc-go/go.mod", "module x\n");
    write("api-py/requirements.txt", "fastapi\nuvicorn\n");

    const services = scanDirectory(root);
    const byName = Object.fromEntries(services.map((s) => [s.name, s]));
    expect(byName["mobile"].command).toBe("flutter run");
    expect(byName["svc-go"].command).toBe("go run .");
    expect(byName["api-py"].command).toBe("uvicorn main:app --reload");
  });

  it("docker-compose: servizi top-level, esclusa l'infrastruttura", () => {
    write("docker-compose.yml", [
      "services:",
      "  app:",
      "    build: .",
      "    ports:",
      '      - "8080:80"',
      "  nats:",
      "    image: nats:2",
    ].join("\n"));

    const services = scanDirectory(root);
    const app = services.find((s) => s.name === "app");
    expect(app?.command).toBe("docker compose up app");
    expect(app?.readiness).toEqual({ kind: "port", port: 8080 });
    expect(services.find((s) => s.name === "nats")).toBeUndefined();
  });

  it("porta duplicata: il secondo servizio perde la readiness a porta", () => {
    write("alpha/package.json", JSON.stringify({ scripts: { start: "node ." } }));
    write("alpha/.env", "PORT=5000\n");
    write("beta/package.json", JSON.stringify({ scripts: { start: "node ." } }));
    write("beta/.env", "PORT=5000\n");

    const services = scanDirectory(root);
    const ports = services.filter((s) => s.readiness.kind === "port");
    expect(ports).toHaveLength(1);
  });

  it("cartella senza backend → nessun rilevamento", () => {
    write("readme.md", "niente qui");
    expect(scanDirectory(root)).toHaveLength(0);
  });
});
