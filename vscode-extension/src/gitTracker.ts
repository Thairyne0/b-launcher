import * as vscode from "vscode";
import { currentBranch, majorityBranch } from "./gitBranch";

/** Servizio da tracciare: chiave + directory + nome progetto (per il calcolo maggioranza). */
export interface GitTarget {
  key: string;
  directory: string;
  projectName: string;
}

/**
 * Rileva periodicamente il branch git di ogni servizio (poll lento: cambia di rado) e
 * segnala il "mismatch" rispetto al branch a maggioranza del progetto — utile per non
 * avviare backend su un worktree/branch sbagliato.
 */
export class GitBranchTracker {
  private branches = new Map<string, string>();
  private mismatches = new Set<string>();
  private readonly changeEmitter = new vscode.EventEmitter<void>();
  readonly onDidChange = this.changeEmitter.event;
  private timer: NodeJS.Timeout | undefined;

  constructor(private readonly getTargets: () => GitTarget[]) {}

  branch(key: string): string | undefined { return this.branches.get(key); }
  isMismatch(key: string): boolean { return this.mismatches.has(key); }

  start(intervalMs = 15000): void {
    if (this.timer) return;
    void this.pollOnce();
    this.timer = setInterval(() => void this.pollOnce(), intervalMs);
  }

  async pollOnce(): Promise<void> {
    const targets = this.getTargets();
    const nextBranches = new Map<string, string>();
    await Promise.all(
      targets.map(async (t) => {
        const branch = await currentBranch(t.directory);
        if (branch) nextBranches.set(t.key, branch);
      }),
    );
    // Mismatch: per progetto, chi differisce dal branch a maggioranza.
    const nextMismatch = new Set<string>();
    const byProject = new Map<string, GitTarget[]>();
    for (const t of targets) {
      (byProject.get(t.projectName) ?? byProject.set(t.projectName, []).get(t.projectName)!).push(t);
    }
    for (const group of byProject.values()) {
      const known = group.map((t) => nextBranches.get(t.key)).filter((b): b is string => !!b);
      const majority = majorityBranch(known);
      if (!majority) continue;
      for (const t of group) {
        const b = nextBranches.get(t.key);
        if (b && b !== majority) nextMismatch.add(t.key);
      }
    }
    if (!sameMap(this.branches, nextBranches) || !sameSet(this.mismatches, nextMismatch)) {
      this.branches = nextBranches;
      this.mismatches = nextMismatch;
      this.changeEmitter.fire();
    }
  }

  dispose(): void {
    if (this.timer) clearInterval(this.timer);
    this.changeEmitter.dispose();
  }
}

function sameMap(a: Map<string, string>, b: Map<string, string>): boolean {
  if (a.size !== b.size) return false;
  for (const [k, v] of a) if (b.get(k) !== v) return false;
  return true;
}
function sameSet(a: Set<string>, b: Set<string>): boolean {
  if (a.size !== b.size) return false;
  for (const k of a) if (!b.has(k)) return false;
  return true;
}
