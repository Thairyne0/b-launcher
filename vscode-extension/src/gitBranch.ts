import { execFile } from "child_process";
import * as fs from "fs";

/** Branch git corrente di una directory (badge sui servizi). Async: spawna `git`. */
export function currentBranch(dir: string): Promise<string | undefined> {
  return new Promise((resolve) => {
    if (!fs.existsSync(dir)) {
      resolve(undefined);
      return;
    }
    execFile(
      "git",
      ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"],
      { timeout: 3000 },
      (err, stdout) => {
        if (err) {
          resolve(undefined);
          return;
        }
        const branch = stdout.trim();
        resolve(branch === "" || branch === "HEAD" ? undefined : branch);
      },
    );
  });
}

/** Branch a maggioranza ASSOLUTA (> metà) tra quelli passati; pareggio/vuoto → undefined. */
export function majorityBranch(branches: string[]): string | undefined {
  if (branches.length === 0) return undefined;
  const counts = new Map<string, number>();
  for (const b of branches) counts.set(b, (counts.get(b) ?? 0) + 1);
  let best: string | undefined;
  let bestCount = 0;
  for (const [branch, count] of counts) {
    if (count > bestCount) { best = branch; bestCount = count; }
  }
  return best !== undefined && bestCount * 2 > branches.length ? best : undefined;
}
