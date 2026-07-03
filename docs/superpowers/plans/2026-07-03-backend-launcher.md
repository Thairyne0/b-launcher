# Backend Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native macOS SwiftUI app (Liquid Glass style) that starts/stops the 6 Skillera backends (`npm run start:dev`), shows live status per backend, and an optional inline terminal (live logs) per backend.

**Architecture:** Swift Package (SPM) executable + Makefile that assembles a `.app` bundle — no `.xcodeproj`. Each backend is spawned via `posix_spawn` in its **own process group** (`/bin/zsh -l -c "exec npm run start:dev"`, cwd = service dir), stdout+stderr piped into a ring-buffer `LogStore`. Status is derived from process liveness + TCP port polling. UI: one window, 6 glass cards with status dot / start / stop / restart / expandable terminal, toolbar with Start-all / Stop-all + passive NATS indicator.

**Tech Stack:** Swift 6.2 toolchain (Xcode 26.5), language mode v5 (avoid strict-concurrency churn in a dev tool), SwiftUI + Observation (`@Observable`), Darwin (`posix_spawn`, `killpg`, sockets), Swift Testing (`import Testing`) for unit tests. Target: macOS 26 (Liquid Glass APIs: `glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`).

**Spec:** `docs/superpowers/specs/2026-07-03-backend-launcher-design.md`

**Working directory for all commands:** `/Users/retr0/Documents/Backend Launcher`

**Hard constraint:** NEVER modify anything under `/Users/retr0/Documents/skilllocale/SkillLocale`. The launcher only reads it as `cwd` for spawned processes.

**Verified environment facts (do not re-derive):**
- `npm`/`node` live in `/opt/homebrew/bin`, resolved by `/bin/zsh -l -c 'which npm'` (Homebrew shellenv in zprofile). No nvm. Interactive shell NOT needed.
- Xcode 26.5 installed, macOS 26.5.1.
- Backend ports: gateway 4000, id 4001, atlas 4003, hr 4006, certet 4010, bill 4012. NATS 4222 (infra containers always running in Docker, not managed by the launcher).

---

## File Structure

```
Backend Launcher/
  Package.swift
  Makefile
  .gitignore
  scripts/make-app.sh                      # assembles dist/Backend Launcher.app
  Sources/BackendLauncher/
    BackendLauncherApp.swift               # @main, AppDelegate (quit confirm)
    Models/
      ServiceConfig.swift                  # static config: 6 services, project root, NATS port
      ServiceStatus.swift                  # status enum + pure derive() function
    Managers/
      SpawnedProcess.swift                 # posix_spawn in own process group, pipe, exit monitor, killpg escalation
      LogStore.swift                       # @Observable ring buffer + ANSI strip + search
      PortCheck.swift                      # non-blocking TCP connect check
      ServiceController.swift              # @Observable per-service glue: start/stop/restart + status
      AppModel.swift                       # all controllers, port polling loop, startAll/stopAll, quit shutdown
    Views/
      ContentView.swift                    # NavigationStack, toolbar, card list
      ServiceCardView.swift                # glass card: dot, name, port, uptime, controls, chevron
      TerminalView.swift                   # monospace log view, autoscroll, search, clear
      StatusBadge.swift                    # StatusDot + status label/color mapping + NATS indicator
  Tests/BackendLauncherTests/
    ServiceStatusTests.swift
    LogStoreTests.swift
    PortCheckTests.swift
    SpawnedProcessTests.swift
    ServiceControllerTests.swift
    AppModelTests.swift
    TestSupport.swift                      # waitUntil helper, TCP listener helper
```

Responsibilities are one-per-file; Managers have no SwiftUI imports; Views contain no process/socket logic.

---

### Task 1: Scaffold — SPM package, Makefile, app bundle script, minimal app

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/BackendLauncher/BackendLauncherApp.swift`
- Create: `Makefile`
- Create: `scripts/make-app.sh`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "BackendLauncher",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "BackendLauncher",
            path: "Sources/BackendLauncher",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BackendLauncherTests",
            dependencies: ["BackendLauncher"],
            path: "Tests/BackendLauncherTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Write `.gitignore`**

```
.build/
dist/
.DS_Store
*.xcodeproj
.swiftpm/
```

- [ ] **Step 3: Write minimal `Sources/BackendLauncher/BackendLauncherApp.swift`**

```swift
import SwiftUI

@main
struct BackendLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Backend Launcher")
                .frame(minWidth: 520, minHeight: 600)
        }
        .defaultSize(width: 560, height: 720)
    }
}
```

- [ ] **Step 4: Write `Makefile`**

```makefile
.PHONY: build test app run dev clean

build:
	swift build

test:
	swift test

app:
	./scripts/make-app.sh

run: app
	open "dist/Backend Launcher.app"

dev:
	swift run

clean:
	rm -rf .build dist
```

- [ ] **Step 5: Write `scripts/make-app.sh` and `chmod +x` it**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/Backend Launcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BackendLauncher "$APP/Contents/MacOS/BackendLauncher"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>BackendLauncher</string>
    <key>CFBundleIdentifier</key>
    <string>it.generazioneai.backend-launcher</string>
    <key>CFBundleName</key>
    <string>Backend Launcher</string>
    <key>CFBundleDisplayName</key>
    <string>Backend Launcher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "OK: $APP"
```

Run: `chmod +x scripts/make-app.sh`

- [ ] **Step 6: Verify it builds**

Run: `swift build`
Expected: `Build complete!` (first run downloads nothing — no dependencies)

- [ ] **Step 7: Commit**

```bash
git add Package.swift .gitignore Sources Makefile scripts
git commit -m "feat: scaffold SPM app, Makefile, app-bundle script"
```

---

### Task 2: ServiceConfig + ServiceStatus (pure logic, TDD)

**Files:**
- Create: `Sources/BackendLauncher/Models/ServiceConfig.swift`
- Create: `Sources/BackendLauncher/Models/ServiceStatus.swift`
- Test: `Tests/BackendLauncherTests/ServiceStatusTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BackendLauncherTests/ServiceStatusTests.swift`:

```swift
import Testing
@testable import BackendLauncher

@Suite struct ServiceStatusTests {
    @Test func stoppedWhenNothing() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: false, lastExitCode: nil) == .stopped)
    }

    @Test func startingWhenAliveButPortClosed() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: false,
                                     stopRequested: false, lastExitCode: nil) == .starting)
    }

    @Test func runningWhenAliveAndPortOpen() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: true,
                                     stopRequested: false, lastExitCode: nil) == .running)
    }

    @Test func stoppingWhenAliveAndStopRequested() {
        #expect(ServiceStatus.derive(processAlive: true, portOpen: true,
                                     stopRequested: true, lastExitCode: nil) == .stopping)
    }

    @Test func crashedWhenDiedWithoutStopRequest() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: false, lastExitCode: 3) == .crashed(exitCode: 3))
    }

    @Test func stoppedAfterUserStop() {
        // user asked to stop, process exited: NOT a crash
        #expect(ServiceStatus.derive(processAlive: false, portOpen: false,
                                     stopRequested: true, lastExitCode: 0) == .stopped)
    }

    @Test func externalWhenPortOpenButNoProcess() {
        #expect(ServiceStatus.derive(processAlive: false, portOpen: true,
                                     stopRequested: false, lastExitCode: nil) == .external)
    }

    @Test func sixServicesConfigured() {
        #expect(ServiceConfig.all.count == 6)
        #expect(ServiceConfig.all.map(\.name) == ["gateway", "id", "atlas", "hr", "certet", "bill"])
        #expect(ServiceConfig.all.map(\.port) == [4000, 4001, 4003, 4006, 4010, 4012])
        for c in ServiceConfig.all {
            #expect(c.command == "npm run start:dev")
            #expect(c.workingDirectory.path.hasPrefix(ServiceConfig.projectRoot.path))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -20`
Expected: compile error — `ServiceStatus` / `ServiceConfig` not defined.

- [ ] **Step 3: Write `Sources/BackendLauncher/Models/ServiceStatus.swift`**

```swift
import Foundation

/// Stato di un backend, derivato da fatti osservabili — nessuna macchina a stati nascosta.
enum ServiceStatus: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case crashed(exitCode: Int32)
    case external   // porta aperta ma il processo non è nostro

    static func derive(processAlive: Bool, portOpen: Bool,
                       stopRequested: Bool, lastExitCode: Int32?) -> ServiceStatus {
        if processAlive {
            if stopRequested { return .stopping }
            return portOpen ? .running : .starting
        }
        if let code = lastExitCode {
            return stopRequested ? .stopped : .crashed(exitCode: code)
        }
        return portOpen ? .external : .stopped
    }
}
```

- [ ] **Step 4: Write `Sources/BackendLauncher/Models/ServiceConfig.swift`**

```swift
import Foundation

/// Configurazione statica dei backend Skillera.
/// Per aggiungere/togliere un servizio o cambiare il path del progetto si edita SOLO questo file.
struct ServiceConfig: Identifiable, Hashable {
    let name: String          // nome breve (pm2-style)
    let directory: String     // sottodirectory dentro projectRoot
    let port: UInt16          // porta HTTP osservata per lo status
    var command: String = "npm run start:dev"

    var id: String { name }
    var displayName: String { "skill\(name)" }
    var workingDirectory: URL { ServiceConfig.projectRoot.appendingPathComponent(directory) }

    static let projectRoot = URL(fileURLWithPath: "/Users/retr0/Documents/skilllocale/SkillLocale")
    static let natsPort: UInt16 = 4222

    static let all: [ServiceConfig] = [
        ServiceConfig(name: "gateway", directory: "SKILLGATEWAY-BE", port: 4000),
        ServiceConfig(name: "id",      directory: "SKILLID-BE",      port: 4001),
        ServiceConfig(name: "atlas",   directory: "SKILLATLAS-BE",   port: 4003),
        ServiceConfig(name: "hr",      directory: "SKILLHR-BE",      port: 4006),
        ServiceConfig(name: "certet",  directory: "SKILLCERTET-BE",  port: 4010),
        ServiceConfig(name: "bill",    directory: "SKILLBILL-BE",    port: 4012),
    ]
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BackendLauncher/Models Tests
git commit -m "feat: service config and status derivation"
```

---

### Task 3: LogStore — ring buffer, line assembly, ANSI strip, search (TDD)

**Files:**
- Create: `Sources/BackendLauncher/Managers/LogStore.swift`
- Test: `Tests/BackendLauncherTests/LogStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BackendLauncherTests/LogStoreTests.swift`:

```swift
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct LogStoreTests {
    @Test func splitsChunksIntoLines() {
        let store = LogStore()
        store.ingest("hello\nwor")
        store.ingest("ld\n")
        #expect(store.lines.map(\.text) == ["hello", "world"])
    }

    @Test func flushPartialEmitsTrailingText() {
        let store = LogStore()
        store.ingest("no newline")
        #expect(store.lines.isEmpty)
        store.flushPartial()
        #expect(store.lines.map(\.text) == ["no newline"])
    }

    @Test func stripsANSIEscapes() {
        let store = LogStore()
        store.ingest("\u{1B}[32m[Nest] ready\u{1B}[0m\n")
        #expect(store.lines.map(\.text) == ["[Nest] ready"])
    }

    @Test func capsAtMaxLines() {
        let store = LogStore(maxLines: 3)
        store.ingest("1\n2\n3\n4\n5\n")
        #expect(store.lines.map(\.text) == ["3", "4", "5"])
    }

    @Test func idsKeepGrowingAfterCap() {
        let store = LogStore(maxLines: 2)
        store.ingest("a\nb\nc\n")
        #expect(store.lines.map(\.id) == [1, 2])
    }

    @Test func searchFiltersCaseInsensitive() {
        let store = LogStore()
        store.ingest("Nest started\nerror: boom\nlistening on 4000\n")
        store.searchText = "ERROR"
        #expect(store.visibleLines.map(\.text) == ["error: boom"])
        store.searchText = ""
        #expect(store.visibleLines.count == 3)
    }

    @Test func clearEmptiesLines() {
        let store = LogStore()
        store.ingest("x\n")
        store.clear()
        #expect(store.lines.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -10`
Expected: compile error — `LogStore` not defined.

- [ ] **Step 3: Write `Sources/BackendLauncher/Managers/LogStore.swift`**

```swift
import Foundation
import Observation

struct LogLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Ring buffer di righe di log per un servizio. Tutte le mutazioni su MainActor.
@MainActor
@Observable
final class LogStore {
    private(set) var lines: [LogLine] = []
    var searchText: String = ""

    private var nextID = 0
    private var partial = ""
    private let maxLines: Int

    // \u{1B}\[ ... lettera finale — copre colori e cursor codes CSI
    private static let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    init(maxLines: Int = 5000) {
        self.maxLines = maxLines
    }

    var visibleLines: [LogLine] {
        guard !searchText.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    func ingest(_ chunk: String) {
        var buffer = partial + Self.stripANSI(chunk)
        var incoming: [LogLine] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let text = String(buffer[..<nl])
            buffer = String(buffer[buffer.index(after: nl)...])
            incoming.append(LogLine(id: nextID, text: text))
            nextID += 1
        }
        partial = buffer
        guard !incoming.isEmpty else { return }
        lines.append(contentsOf: incoming)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// Da chiamare su EOF del processo: emette l'eventuale riga finale senza newline.
    func flushPartial() {
        guard !partial.isEmpty else { return }
        let text = partial
        partial = ""
        ingest(text + "\n")
    }

    func clear() {
        lines.removeAll()
        partial = ""
    }

    private static func stripANSI(_ s: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return ansiPattern.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/BackendLauncher/Managers/LogStore.swift Tests/BackendLauncherTests/LogStoreTests.swift
git commit -m "feat: log store with ring buffer, ANSI strip, search"
```

---

### Task 4: PortCheck — non-blocking TCP probe (TDD)

**Files:**
- Create: `Sources/BackendLauncher/Managers/PortCheck.swift`
- Create: `Tests/BackendLauncherTests/TestSupport.swift`
- Test: `Tests/BackendLauncherTests/PortCheckTests.swift`

- [ ] **Step 1: Write test support — local TCP listener**

`Tests/BackendLauncherTests/TestSupport.swift`:

```swift
import Darwin
import Foundation

/// Listener TCP su 127.0.0.1, porta assegnata dal kernel. Chiudere con `close(fd)`.
func makeTCPListener() -> (fd: Int32, port: UInt16) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bindResult == 0, "bind() failed")
    precondition(listen(fd, 8) == 0, "listen() failed")

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &bound) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            _ = getsockname(fd, $0, &len)
        }
    }
    return (fd, UInt16(bigEndian: bound.sin_port))
}

/// Polling asincrono di una condizione con timeout. Ritorna true se soddisfatta in tempo.
func waitUntil(timeout: TimeInterval = 10, interval: TimeInterval = 0.05,
               _ condition: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return condition()
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/BackendLauncherTests/PortCheckTests.swift`:

```swift
import Darwin
import Testing
@testable import BackendLauncher

@Suite struct PortCheckTests {
    @Test func detectsOpenPort() {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        #expect(PortCheck.isOpen(listener.port) == true)
    }

    @Test func detectsClosedPort() {
        // apri e chiudi subito: la porta risulta libera
        let listener = makeTCPListener()
        let port = listener.port
        close(listener.fd)
        #expect(PortCheck.isOpen(port) == false)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter PortCheckTests 2>&1 | tail -10`
Expected: compile error — `PortCheck` not defined.

- [ ] **Step 4: Write `Sources/BackendLauncher/Managers/PortCheck.swift`**

```swift
import Darwin
import Foundation

/// Probe TCP non bloccante su 127.0.0.1. Nessuna dipendenza, testabile.
enum PortCheck {
    static func isOpen(_ port: UInt16, timeoutMs: Int32 = 500) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return false }

        var soError: Int32 = -1
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        return soError == 0
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter PortCheckTests 2>&1 | tail -5`
Expected: 2 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/BackendLauncher/Managers/PortCheck.swift Tests/BackendLauncherTests/PortCheckTests.swift Tests/BackendLauncherTests/TestSupport.swift
git commit -m "feat: non-blocking TCP port probe"
```

---

### Task 5: SpawnedProcess — process group, pipes, exit monitoring, kill escalation (TDD)

The core piece. A child spawned via `posix_spawn` with `POSIX_SPAWN_SETPGROUP` (pgroup 0 → the child leads its own process group, pgid == pid). `terminate()` sends `killpg(SIGTERM)` and escalates to `SIGKILL` after a grace period. This kills npm + node + the NestJS watcher in one shot — no orphans.

**Files:**
- Create: `Sources/BackendLauncher/Managers/SpawnedProcess.swift`
- Test: `Tests/BackendLauncherTests/SpawnedProcessTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BackendLauncherTests/SpawnedProcessTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@Suite struct SpawnedProcessTests {
    /// Colleziona output e exit code su una queue dedicata (il main loop non gira nei test).
    final class Recorder: @unchecked Sendable {
        let queue = DispatchQueue(label: "test.recorder")
        var output = ""
        var exitCode: Int32?
        func chunk(_ s: String) { output += s }
        func exited(_ code: Int32) { exitCode = code }
    }

    @Test func capturesOutputAndExitCode() async throws {
        let rec = Recorder()
        _ = try SpawnedProcess(
            shellCommand: "echo hello-launcher; exit 3",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let done = await waitUntil { rec.queue.sync { rec.exitCode != nil } }
        #expect(done)
        rec.queue.sync {
            #expect(rec.output.contains("hello-launcher"))
            #expect(rec.exitCode == 3)
        }
    }

    @Test func terminateKillsWholeProcessGroup() async throws {
        let rec = Recorder()
        // zsh (leader) + sleep in background: il PID del figlio viene stampato
        let proc = try SpawnedProcess(
            shellCommand: "sleep 300 & echo CHILD:$!; wait",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let gotChild = await waitUntil { rec.queue.sync { rec.output.contains("CHILD:") } }
        #expect(gotChild)
        let childPID: pid_t = rec.queue.sync {
            let line = rec.output.split(separator: "\n").first { $0.hasPrefix("CHILD:") }!
            return pid_t(line.dropFirst("CHILD:".count))!
        }
        #expect(kill(childPID, 0) == 0)  // il nipote è vivo

        proc.terminate(gracePeriod: 1)

        let exited = await waitUntil { rec.queue.sync { rec.exitCode != nil } }
        #expect(exited)
        // anche il nipote deve essere morto (ucciso via process group)
        let grandchildDead = await waitUntil { kill(childPID, 0) != 0 }
        #expect(grandchildDead)
    }

    @Test func sigkillEscalationWhenSigtermIgnored() async throws {
        let rec = Recorder()
        // trap ignora SIGTERM: deve arrivare il SIGKILL dopo la grace period
        let proc = try SpawnedProcess(
            shellCommand: "trap '' TERM; echo READY; sleep 300",
            cwd: "/tmp",
            callbackQueue: rec.queue,
            onChunk: { rec.chunk($0) },
            onExit: { rec.exited($0) }
        )
        let ready = await waitUntil { rec.queue.sync { rec.output.contains("READY") } }
        #expect(ready)
        proc.terminate(gracePeriod: 0.5)
        let exited = await waitUntil(timeout: 15) { rec.queue.sync { rec.exitCode != nil } }
        #expect(exited)
        rec.queue.sync {
            #expect(rec.exitCode == 128 + SIGKILL)  // 137
        }
    }

    @Test func spawnFailsForMissingCwd() {
        #expect(throws: (any Error).self) {
            _ = try SpawnedProcess(
                shellCommand: "true",
                cwd: "/nonexistent/path/xyz",
                callbackQueue: DispatchQueue(label: "t"),
                onChunk: { _ in },
                onExit: { _ in }
            )
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SpawnedProcessTests 2>&1 | tail -10`
Expected: compile error — `SpawnedProcess` not defined.

- [ ] **Step 3: Write `Sources/BackendLauncher/Managers/SpawnedProcess.swift`**

```swift
import Darwin
import Foundation

/// Processo figlio in un process group dedicato, stdout+stderr su pipe.
///
/// - Lancio: `/bin/zsh -l -c <command>` (login shell: risolve npm da Homebrew;
///   `exec` nel comando evita un livello di shell in più).
/// - Stop: `killpg(SIGTERM)` → grace period → `killpg(SIGKILL)`.
///   Uccide npm + node + watcher NestJS in blocco.
/// - I callback arrivano su `callbackQueue` (default: main).
final class SpawnedProcess {
    enum SpawnError: Error, LocalizedError {
        case pipeFailed(Int32)
        case spawnFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .pipeFailed(let e): return "pipe() fallita: errno \(e)"
            case .spawnFailed(let e): return "posix_spawn fallita: errno \(e) (\(String(cString: strerror(e))))"
            }
        }
    }

    let pid: pid_t
    private let readHandle: FileHandle
    private let exitSource: DispatchSourceProcess
    private let callbackQueue: DispatchQueue
    private let stateLock = NSLock()
    private var _alive = true

    var isAlive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _alive
    }

    init(shellCommand: String, cwd: String,
         callbackQueue: DispatchQueue = .main,
         onChunk: @escaping (String) -> Void,
         onExit: @escaping (Int32) -> Void) throws {
        self.callbackQueue = callbackQueue

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw SpawnError.pipeFailed(errno) }
        let readFD = fds[0], writeFD = fds[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 1)
        posix_spawn_file_actions_adddup2(&fileActions, writeFD, 2)
        posix_spawn_file_actions_addclose(&fileActions, readFD)
        posix_spawn_file_actions_addclose(&fileActions, writeFD)
        posix_spawn_file_actions_addchdir_np(&fileActions, cwd)

        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        defer { posix_spawnattr_destroy(&attrs) }
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attrs, 0)  // il figlio guida il proprio group (pgid == pid)

        let argv = ["/bin/zsh", "-l", "-c", shellCommand]
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { cArgv.forEach { free($0) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, "/bin/zsh", &fileActions, &attrs, &cArgv, environ)
        close(writeFD)  // lato scrittura resta solo nel figlio
        guard rc == 0 else {
            close(readFD)
            throw SpawnError.spawnFailed(rc)
        }
        pid = childPID

        readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {  // EOF
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                callbackQueue.async { onChunk(text) }
            }
        }

        exitSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit,
                                                      queue: callbackQueue)
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)  // reap: niente zombie
            self?.markDead()
            onExit(Self.decodeExitStatus(status))
            self?.exitSource.cancel()
        }
        exitSource.resume()
    }

    /// SIGTERM al process group; SIGKILL se dopo `gracePeriod` è ancora vivo.
    func terminate(gracePeriod: TimeInterval = 5) {
        killpg(pid, SIGTERM)
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod) { [weak self] in
            guard let self, self.isAlive else { return }
            killpg(pid, SIGKILL)
        }
    }

    private func markDead() {
        stateLock.lock(); _alive = false; stateLock.unlock()
    }

    /// wait(2) status → exit code convenzionale (segnale N → 128+N).
    static func decodeExitStatus(_ status: Int32) -> Int32 {
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }  // uscita normale
        return 128 + low                              // terminato da segnale
    }
}
```

**Cwd note:** `posix_spawn_file_actions_addchdir_np` fails the whole spawn with a nonzero `rc` when `cwd` doesn't exist — that's what makes `spawnFailsForMissingCwd` pass.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SpawnedProcessTests 2>&1 | tail -8`
Expected: 4 tests PASS. (`terminateKillsWholeProcessGroup` and `sigkillEscalationWhenSigtermIgnored` take a few seconds — fine.)

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: everything PASSes.

- [ ] **Step 6: Commit**

```bash
git add Sources/BackendLauncher/Managers/SpawnedProcess.swift Tests/BackendLauncherTests/SpawnedProcessTests.swift
git commit -m "feat: process spawning with dedicated process group and kill escalation"
```

---

### Task 6: ServiceController — per-service glue (TDD)

**Files:**
- Create: `Sources/BackendLauncher/Managers/ServiceController.swift`
- Test: `Tests/BackendLauncherTests/ServiceControllerTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BackendLauncherTests/ServiceControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import BackendLauncher

/// Config fittizia: comandi brevi al posto di npm. cwd=/tmp esiste sempre.
private func fakeConfig(command: String) -> ServiceConfig {
    ServiceConfig(name: "fake", directory: "", port: 1, command: command)
}

@MainActor
@Suite struct ServiceControllerTests {
    @Test func crashSetsCrashedStatusWithExitCode() async {
        let c = ServiceController(config: fakeConfig(command: "exit 7"), cwd: "/tmp")
        c.start()
        let crashed = await waitUntil { c.status == .crashed(exitCode: 7) }
        #expect(crashed)
    }

    @Test func userStopEndsInStoppedNotCrashed() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        let alive = await waitUntil { c.status == .starting }
        #expect(alive)
        c.stop()
        let stopped = await waitUntil { c.status == .stopped }
        #expect(stopped)
    }

    @Test func restartSpawnsNewProcess() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.processID != nil }
        let firstPID = c.processID
        c.restart()
        let restarted = await waitUntil { c.processID != nil && c.processID != firstPID }
        #expect(restarted)
        c.stop()
        _ = await waitUntil { c.status == .stopped }
    }

    @Test func startWhilePortExternallyOpenIsRefused() async {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        var config = fakeConfig(command: "sleep 60")
        config = ServiceConfig(name: "fake", directory: "", port: listener.port, command: "sleep 60")
        let c = ServiceController(config: config, cwd: "/tmp")
        c.portOpen = true
        #expect(c.status == .external)
        c.start()  // deve rifiutare: niente processo
        #expect(c.processID == nil)
    }

    @Test func runningWhenAliveAndPortMarkedOpen() async {
        let c = ServiceController(config: fakeConfig(command: "sleep 60"), cwd: "/tmp")
        c.start()
        _ = await waitUntil { c.status == .starting }
        c.portOpen = true
        #expect(c.status == .running)
        c.stop()
        _ = await waitUntil { c.processID == nil }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ServiceControllerTests 2>&1 | tail -10`
Expected: compile error — `ServiceController` not defined.

- [ ] **Step 3: Write `Sources/BackendLauncher/Managers/ServiceController.swift`**

```swift
import Foundation
import Observation

/// Stato + azioni di un singolo backend. Vive su MainActor; i callback di
/// SpawnedProcess arrivano sulla main queue.
@MainActor
@Observable
final class ServiceController: Identifiable {
    let config: ServiceConfig
    let logs = LogStore()

    private(set) var processAlive = false
    private(set) var startedAt: Date?
    var portOpen = false  // aggiornato dal poller di AppModel

    private var process: SpawnedProcess?
    private var stopRequested = false
    private var lastExitCode: Int32?
    private var pendingRestart = false
    private let cwdOverride: String?

    /// `cwd` iniettabile solo per i test; in produzione usa config.workingDirectory.
    init(config: ServiceConfig, cwd: String? = nil) {
        self.config = config
        self.cwdOverride = cwd
    }

    nonisolated var id: String { config.id }

    var processID: pid_t? { processAlive ? process?.pid : nil }

    var status: ServiceStatus {
        ServiceStatus.derive(processAlive: processAlive, portOpen: portOpen,
                             stopRequested: stopRequested, lastExitCode: lastExitCode)
    }

    func start() {
        guard !processAlive else { return }
        guard status != .external else {
            logs.ingest("[launcher] porta \(config.port) già occupata da un processo esterno — avvio rifiutato\n")
            return
        }
        stopRequested = false
        lastExitCode = nil
        logs.ingest("[launcher] ── avvio \(config.displayName) (\(config.command)) ──\n")
        do {
            let cwd = cwdOverride ?? config.workingDirectory.path
            process = try SpawnedProcess(
                shellCommand: "exec \(config.command)",
                cwd: cwd,
                onChunk: { [weak self] chunk in self?.logs.ingest(chunk) },
                onExit: { [weak self] code in self?.handleExit(code) }
            )
            processAlive = true
            startedAt = Date()
        } catch {
            logs.ingest("[launcher] errore avvio: \(error.localizedDescription)\n")
            lastExitCode = -1
        }
    }

    func stop() {
        guard processAlive, let process else { return }
        stopRequested = true
        logs.ingest("[launcher] ── stop richiesto ──\n")
        process.terminate()
    }

    func restart() {
        if processAlive {
            pendingRestart = true
            stop()
        } else {
            start()
        }
    }

    private func handleExit(_ code: Int32) {
        processAlive = false
        process = nil
        startedAt = nil
        lastExitCode = code
        logs.flushPartial()
        logs.ingest("[launcher] ── processo terminato (exit \(code)) ──\n")
        if pendingRestart {
            pendingRestart = false
            start()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ServiceControllerTests 2>&1 | tail -8`
Expected: 5 tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: everything PASSes.

- [ ] **Step 6: Commit**

```bash
git add Sources/BackendLauncher/Managers/ServiceController.swift Tests/BackendLauncherTests/ServiceControllerTests.swift
git commit -m "feat: per-service controller with start/stop/restart and status"
```

---

### Task 7: AppModel — controllers, port polling, startAll/stopAll, quit shutdown (TDD)

**Files:**
- Create: `Sources/BackendLauncher/Managers/AppModel.swift`
- Test: `Tests/BackendLauncherTests/AppModelTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/BackendLauncherTests/AppModelTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import BackendLauncher

@MainActor
@Suite struct AppModelTests {
    private var fakeConfigs: [ServiceConfig] {
        [
            ServiceConfig(name: "a", directory: "", port: 1, command: "sleep 60"),
            ServiceConfig(name: "b", directory: "", port: 2, command: "sleep 60"),
        ]
    }

    @Test func checkPortsSeesListener() async {
        let listener = makeTCPListener()
        defer { close(listener.fd) }
        let results = await AppModel.checkPorts([listener.port, 1])
        #expect(results[listener.port] == true)
        #expect(results[1] == false)
    }

    @Test func startAllAndStopAll() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.startAll()
        let allUp = await waitUntil { model.services.allSatisfy { $0.processAlive } }
        #expect(allUp)
        #expect(model.anyRunning)
        model.stopAll()
        let allDown = await waitUntil { model.services.allSatisfy { !$0.processAlive } }
        #expect(allDown)
        #expect(!model.anyRunning)
    }

    @Test func startAllSkipsAlreadyRunning() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.services[0].start()
        _ = await waitUntil { model.services[0].processAlive }
        let firstPID = model.services[0].processID
        model.startAll()
        _ = await waitUntil { model.services[1].processAlive }
        #expect(model.services[0].processID == firstPID)  // non riavviato
        model.stopAll()
        _ = await waitUntil { !model.anyRunning }
    }

    @Test func shutdownForQuitStopsEverything() async {
        let model = AppModel(configs: fakeConfigs, cwd: "/tmp", pollingEnabled: false)
        model.startAll()
        _ = await waitUntil { model.anyRunning }
        await model.shutdownForQuit()
        #expect(!model.anyRunning)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppModelTests 2>&1 | tail -10`
Expected: compile error — `AppModel` not defined.

- [ ] **Step 3: Write `Sources/BackendLauncher/Managers/AppModel.swift`**

```swift
import Foundation
import Observation

/// Radice dello stato dell'app: tutti i controller + spia NATS + azioni globali.
@MainActor
@Observable
final class AppModel {
    let services: [ServiceController]
    private(set) var natsUp = false
    var showNATSWarning = false

    private var pollTask: Task<Void, Never>?

    /// `cwd` e `pollingEnabled` iniettabili solo per i test.
    init(configs: [ServiceConfig] = ServiceConfig.all,
         cwd: String? = nil,
         pollingEnabled: Bool = true) {
        services = configs.map { ServiceController(config: $0, cwd: cwd) }
        if pollingEnabled { startPolling() }
    }

    var anyRunning: Bool { services.contains { $0.processAlive } }

    func startAll() {
        if !natsUp { showNATSWarning = true }  // avvisa ma procedi (spec)
        for service in services where !service.processAlive {
            service.start()
        }
    }

    func stopAll() {
        for service in services { service.stop() }
    }

    /// Stop di tutto con attesa (max ~6s: grace 5s di killpg + margine). Per il quit.
    func shutdownForQuit() async {
        stopAll()
        let deadline = Date().addingTimeInterval(6.5)
        while anyRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ports = [ServiceConfig.natsPort] + self.services.map(\.config.port)
                let results = await Self.checkPorts(ports)
                self.natsUp = results[ServiceConfig.natsPort] ?? false
                for service in self.services {
                    service.portOpen = results[service.config.port] ?? false
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Probe di più porte fuori dal MainActor.
    static func checkPorts(_ ports: [UInt16]) async -> [UInt16: Bool] {
        let unique = Array(Set(ports))
        return await Task.detached(priority: .utility) {
            var out: [UInt16: Bool] = [:]
            for port in unique { out[port] = PortCheck.isOpen(port) }
            return out
        }.value
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppModelTests 2>&1 | tail -8`
Expected: 4 tests PASS.

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: everything PASSes.

- [ ] **Step 6: Commit**

```bash
git add Sources/BackendLauncher/Managers/AppModel.swift Tests/BackendLauncherTests/AppModelTests.swift
git commit -m "feat: app model with port polling and global start/stop"
```

---

### Task 8: Views — StatusBadge, TerminalView, ServiceCardView

UI components. No unit tests (SwiftUI views) — verification is `swift build` + manual check in Task 9.

**Files:**
- Create: `Sources/BackendLauncher/Views/StatusBadge.swift`
- Create: `Sources/BackendLauncher/Views/TerminalView.swift`
- Create: `Sources/BackendLauncher/Views/ServiceCardView.swift`

- [ ] **Step 1: Write `Sources/BackendLauncher/Views/StatusBadge.swift`**

```swift
import SwiftUI

extension ServiceStatus {
    var label: String {
        switch self {
        case .stopped: return "fermo"
        case .starting: return "avvio…"
        case .running: return "in esecuzione"
        case .stopping: return "arresto…"
        case .crashed(let code): return "crash (exit \(code))"
        case .external: return "attivo fuori dal launcher"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .gray
        case .starting: return .yellow
        case .running: return .green
        case .stopping: return .orange
        case .crashed: return .red
        case .external: return .blue
        }
    }

    var isPulsing: Bool {
        switch self {
        case .starting, .stopping: return true
        default: return false
        }
    }
}

/// Pallino di stato, pulsante durante le transizioni.
struct StatusDot: View {
    let status: ServiceStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(status.color.gradient)
            .frame(width: 11, height: 11)
            .shadow(color: status.color.opacity(0.6), radius: pulse ? 6 : 2)
            .scaleEffect(pulse ? 1.15 : 1.0)
            .animation(status.isPulsing
                       ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                       : .default,
                       value: pulse)
            .onAppear { pulse = status.isPulsing }
            .onChange(of: status.isPulsing) { _, pulsing in pulse = pulsing }
    }
}

/// Spia NATS per la toolbar.
struct NATSIndicator: View {
    let up: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((up ? Color.green : Color.red).gradient)
                .frame(width: 9, height: 9)
            Text("NATS")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .help(up ? "NATS raggiungibile su localhost:4222"
                 : "NATS NON raggiungibile (localhost:4222) — i backend non comunicano")
    }
}
```

- [ ] **Step 2: Write `Sources/BackendLauncher/Views/TerminalView.swift`**

```swift
import SwiftUI

/// Log live di un servizio: monospace, sfondo scuro, ricerca, autoscroll, pulisci.
struct TerminalView: View {
    @Bindable var logs: LogStore
    @State private var autoscroll = true

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Cerca nei log", text: $logs.searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: .capsule)

                Toggle("Autoscroll", isOn: $autoscroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button("Pulisci") { logs.clear() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logs.visibleLines) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(white: 0.88))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                    .textSelection(.enabled)
                }
                .background(Color.black.opacity(0.78), in: .rect(cornerRadius: 10))
                .onChange(of: logs.lines.last?.id) { _, newID in
                    guard autoscroll, logs.searchText.isEmpty, let newID else { return }
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Write `Sources/BackendLauncher/Views/ServiceCardView.swift`**

```swift
import SwiftUI

/// Card glass di un backend: stato, controlli, terminale espandibile.
struct ServiceCardView: View {
    var controller: ServiceController
    @State private var showTerminal = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatusDot(status: controller.status)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.config.displayName)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Text("porta \(String(controller.config.port))")
                        Text("·")
                        Text(controller.status.label)
                            .foregroundStyle(controller.status.color)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let startedAt = controller.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                controlButtons

                Button {
                    withAnimation(.snappy) { showTerminal.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showTerminal ? 180 : 0))
                }
                .buttonStyle(.borderless)
                .help(showTerminal ? "Nascondi terminale" : "Mostra terminale")
            }
            .padding(14)

            if showTerminal {
                TerminalView(logs: controller.logs)
                    .frame(height: 300)
                    .padding([.horizontal, .bottom], 14)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var controlButtons: some View {
        let status = controller.status
        HStack(spacing: 8) {
            Button {
                controller.start()
            } label: {
                Image(systemName: "play.fill")
            }
            .disabled(controller.processAlive || status == .external)
            .help("Avvia")

            Button {
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .disabled(!controller.processAlive || status == .stopping)
            .help("Ferma")

            Button {
                controller.restart()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(status == .external || status == .stopping)
            .help("Riavvia")
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }
}
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`
If `glassEffect` fails to compile (API availability), replace `.glassEffect(.regular, in: .rect(cornerRadius: 18))` with `.background(.regularMaterial, in: .rect(cornerRadius: 18))` **and report it** — do not silently keep going with other changes.

- [ ] **Step 5: Commit**

```bash
git add Sources/BackendLauncher/Views
git commit -m "feat: status badge, terminal view, service card"
```

---

### Task 9: ContentView + App wiring + quit confirmation

**Files:**
- Create: `Sources/BackendLauncher/Views/ContentView.swift`
- Modify: `Sources/BackendLauncher/BackendLauncherApp.swift` (replace entirely)

- [ ] **Step 1: Write `Sources/BackendLauncher/Views/ContentView.swift`**

```swift
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        ForEach(model.services) { controller in
                            ServiceCardView(controller: controller)
                        }
                    }
                    .padding(20)
                }
            }
            .background {
                LinearGradient(colors: [Color(hue: 0.61, saturation: 0.35, brightness: 0.28),
                                        Color(hue: 0.68, saturation: 0.30, brightness: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            }
            .navigationTitle("Skillera Backend")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    NATSIndicator(up: model.natsUp)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Avvia tutti", systemImage: "play.fill") { model.startAll() }
                        .disabled(model.services.allSatisfy { $0.processAlive })
                    Button("Ferma tutti", systemImage: "stop.fill") { model.stopAll() }
                        .disabled(!model.anyRunning)
                }
            }
            .alert("NATS non raggiungibile", isPresented: $model.showNATSWarning) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("La porta 4222 è chiusa: i backend partono ma non comunicano tra loro. Controlla i container Docker (skillera-nats).")
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
```

If `GlassEffectContainer` fails to compile, drop the wrapper (keep the inner `VStack`) **and report it** — same policy as Task 8 Step 4.

- [ ] **Step 2: Replace `Sources/BackendLauncher/BackendLauncherApp.swift`**

```swift
import AppKit
import SwiftUI

/// Delegate: attivazione app da binario nudo (swift run) + conferma quit con backend attivi.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.anyRunning else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Backend attivi"
        alert.informativeText = "Chiudendo il launcher tutti i backend verranno fermati. Continuare?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Ferma tutto ed esci")
        alert.addButton(withTitle: "Annulla")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

        Task { @MainActor in
            await model.shutdownForQuit()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct BackendLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 560, height: 720)
    }
}
```

- [ ] **Step 3: Build and run the full test suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build OK, all tests PASS.

- [ ] **Step 4: Manual smoke check (dev binary)**

Run: `swift run` (leave it running, check by eye, then Ctrl-C)
Expected:
- Window "Skillera Backend" with 6 glass cards (gateway, id, atlas, hr, certet, bill), all "fermo" (gray) — or "attivo fuori dal launcher" (blue) if something already listens on those ports.
- NATS indicator green (infra containers are always up).
- Chevron expands an empty terminal.

- [ ] **Step 5: Commit**

```bash
git add Sources/BackendLauncher
git commit -m "feat: main window, toolbar, quit confirmation"
```

---

### Task 10: App bundle — make app / make run

**Files:**
- No new files (uses Task 1's `scripts/make-app.sh`)

- [ ] **Step 1: Build the bundle**

Run: `make app`
Expected: `OK: dist/Backend Launcher.app`, codesign silent (ad-hoc).

- [ ] **Step 2: Verify bundle structure and signature**

Run: `codesign --verify --verbose "dist/Backend Launcher.app" && plutil -lint "dist/Backend Launcher.app/Contents/Info.plist"`
Expected: `valid on disk`, `satisfies its Designated Requirement`, plist `OK`.

- [ ] **Step 3: Launch the app**

Run: `open "dist/Backend Launcher.app"`
Expected: app appears in Dock as "Backend Launcher", window renders like `swift run`. Quit it (Cmd-Q).

- [ ] **Step 4: Commit (only if anything needed fixing)**

```bash
git add -A
git commit -m "fix: app bundle adjustments"
```

---

### Task 11: E2E with a real backend + README

**Files:**
- Create: `README.md`

- [ ] **Step 1: E2E — start one real backend from the launcher**

Launch: `open "dist/Backend Launcher.app"`, then click ▶︎ on **gateway**.
Verify, in order:
1. Dot goes yellow ("avvio…"), terminal (chevron) streams NestJS logs live.
2. Within ~10-30s dot goes green ("in esecuzione") — port 4000 open. Cross-check: `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4000` from a terminal returns an HTTP code (any code = listening).
3. `pgrep -lf "nest start"` shows the gateway processes.
4. Click ■: dot back to gray, and `pgrep -lf "nest start"` shows **nothing** (no orphans). Also check `pgrep -lf "npm run start:dev"` is empty.
5. Search in the terminal panel filters lines; "Pulisci" empties it.

- [ ] **Step 2: E2E — external detection**

In a terminal: `cd /Users/retr0/Documents/skilllocale/SkillLocale/SKILLGATEWAY-BE && npm run start:dev`, wait for port 4000 up.
Expected: launcher shows gateway **blue** ("attivo fuori dal launcher"), ▶︎ disabled.
Ctrl-C the manual process; within ~4s the card returns gray, ▶︎ enabled.

- [ ] **Step 3: E2E — quit confirmation**

Start gateway from the launcher, press Cmd-Q.
Expected: dialog "Backend attivi… Continuare?". Confirm → app closes, `pgrep -lf "nest start"` empty.

- [ ] **Step 4: Write `README.md`**

```markdown
# Backend Launcher

App macOS nativa (SwiftUI, Liquid Glass) per avviare/fermare i backend Skillera
e vederne status e log, senza toccare il progetto SkillLocale.

## Requisiti

- macOS 26 (Tahoe), Xcode 26 (per compilare)
- `npm` in `/opt/homebrew/bin` (Homebrew) — risolto via `zsh -l`
- Progetto Skillera in `/Users/retr0/Documents/skilllocale/SkillLocale`
- Infra (NATS/Redis/Milvus) già attiva in Docker: il launcher NON la gestisce,
  mostra solo la spia NATS in toolbar

## Uso

```bash
make run     # builda dist/Backend Launcher.app e la apre
make dev     # build+run veloce senza bundle (swift run)
make test    # unit test
make app     # builda solo il bundle
make clean
```

## Servizi gestiti

gateway :4000 · id :4001 · atlas :4003 · hr :4006 · certet :4010 · bill :4012

Ogni backend parte con `npm run start:dev` nella sua directory, in un process
group dedicato: lo stop (SIGTERM → 5s → SIGKILL sul group) non lascia orfani.

## Configurazione

Tutto statico in `Sources/BackendLauncher/Models/ServiceConfig.swift`
(path progetto, servizi, porte). Edita quel file e `make run`.

## Stati

- ⚪️ fermo · 🟡 avvio… · 🟢 in esecuzione (porta aperta) · 🟠 arresto…
- 🔴 crash (exit code mostrato) · 🔵 attivo fuori dal launcher (start disabilitato)

## Chiusura

Cmd-Q con backend attivi → conferma → stop pulito di tutto (niente orfani).
```

- [ ] **Step 5: Final full suite + commit**

Run: `swift test 2>&1 | tail -3`
Expected: all PASS.

```bash
git add README.md
git commit -m "docs: README with usage and E2E-verified behavior"
```

---

## Self-Review (done at plan-writing time)

- **Spec coverage:** 6 services w/ correct ports (Task 2) · `npm run start:dev` via `zsh -l -c` (Tasks 5-6) · process-group kill w/ 5s escalation (Task 5) · status 5+1 states incl. external/crashed w/ exit code (Tasks 2, 6) · port polling 2s (Task 7) · NATS passive indicator + warning on startAll (Tasks 7, 9) · per-service expandable terminal w/ search/autoscroll/clear, ring buffer 5000 (Tasks 3, 8) · start/stop/restart per service + startAll/stopAll (Tasks 6-9) · quit confirmation w/ clean shutdown (Tasks 7, 9, 11) · Liquid Glass UI (Tasks 8-9) · SPM+Makefile+bundle (Tasks 1, 10) · README (Task 11) · uptime display (Task 8, `Text(_, style: .timer)`) · no writes into SkillLocale (cwd-only usage; header constraint).
- **Placeholder scan:** none — every code step carries full code.
- **Type consistency:** `ServiceStatus.derive(processAlive:portOpen:stopRequested:lastExitCode:)` used identically in Tasks 2/6 · `SpawnedProcess(shellCommand:cwd:callbackQueue:onChunk:onExit:)` matches Tasks 5/6 (Task 6 omits `callbackQueue` → default `.main`) · `LogStore.ingest/flushPartial/clear/visibleLines/searchText` match Tasks 3/6/8 · `ServiceController(config:cwd:)`, `.processID`, `.portOpen` match Tasks 6/7/8 · `AppModel(configs:cwd:pollingEnabled:)`, `.checkPorts`, `.shutdownForQuit` match Tasks 7/9.
- **Known risk, mitigated in-plan:** exact Liquid Glass API names (`glassEffect`, `GlassEffectContainer`) — fallback documented in Task 8 Step 4 / Task 9 Step 1 with mandatory reporting.
