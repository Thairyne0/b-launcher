import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { currentBranch, majorityBranch } from "../src/gitBranch";

describe("currentBranch", () => {
  let dir: string;
  beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), "blauncher-git-")); });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const git = (...args: string[]) =>
    execFileSync("git", ["-C", dir, ...args], {
      env: { ...process.env, GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_SYSTEM: "/dev/null" },
      stdio: "ignore",
    });

  it("ritorna il branch di un repo", async () => {
    git("init", "-q", "-b", "feature/x");
    fs.writeFileSync(path.join(dir, "f.txt"), "x");
    git("-c", "user.name=t", "-c", "user.email=t@t", "add", ".");
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "primo");
    expect(await currentBranch(dir)).toBe("feature/x");
  });

  it("undefined fuori da un repo o directory assente", async () => {
    expect(await currentBranch(dir)).toBeUndefined();
    expect(await currentBranch(path.join(dir, "non-esiste"))).toBeUndefined();
  });
});

describe("majorityBranch", () => {
  it("maggioranza assoluta, pareggio → undefined", () => {
    expect(majorityBranch(["main", "main", "dev"])).toBe("main");
    expect(majorityBranch(["main"])).toBe("main");
    expect(majorityBranch(["main", "dev"])).toBeUndefined();
    expect(majorityBranch([])).toBeUndefined();
  });
});
