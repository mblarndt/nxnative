// A window around scripts/build_ipa_from_nsp.py: pick the base game, update, DLCs, prod.keys and output folder one by one, choose iPhone (IPA) or Mac (app), press Start, watch the progress. No terminal.
// Built into "NxNative Builder.app" by scripts/build_builder_app.sh, which records the Python and the repository the app runs (Info.plist: NXPython, NXRepo).
// The files are not copied: they are linked into <output>/NxNative-Work/<game name>/, the "NSP folder" the script expects, and the script's intermediate files go beside the links.
// A Mac build ends with scripts/make_mac_app.py, which turns the build into <output>/<game name>.app.
import SwiftUI
import AppKit

struct Event: Decodable {   // one line of `build_ipa_from_nsp.py --progress json`
    var ev: String
    var k: Int?, n: Int?, name: String?, step: String?, note: String?, msg: String?
    var frac: Double?, eta: Double?, elapsed: Double?
}

struct Failure: LocalizedError { var errorDescription: String? }

final class Lines: @unchecked Sendable {   // splits a byte stream into lines; only the pipe's own queue feeds it
    private var buf = Data()
    func feed(_ d: Data) -> [String] {
        buf.append(d)
        var out: [String] = []
        while let i = buf.firstIndex(of: 10) { out.append(String(decoding: buf[..<i], as: UTF8.self)); buf.removeSubrange(...i) }
        return out
    }
}

enum Platform: String { case ios, mac }

@MainActor final class Job: ObservableObject {
    @Published var rom: URL?
    @Published var update: URL?
    @Published var dlcs: [URL] = []
    @Published var keys = UserDefaults.standard.string(forKey: "keys").map { URL(fileURLWithPath: $0) } { didSet { UserDefaults.standard.set(keys?.path, forKey: "keys") } }
    @Published var out = UserDefaults.standard.string(forKey: "out").map { URL(fileURLWithPath: $0) } { didSet { UserDefaults.standard.set(out?.path, forKey: "out") } }
    @Published var platform = Platform(rawValue: UserDefaults.standard.string(forKey: "platform") ?? "") ?? .ios { didSet { UserDefaults.standard.set(platform.rawValue, forKey: "platform") } }
    @Published var running = false
    @Published var overall = 0.0
    @Published var status = ""
    @Published var detail = ""
    @Published var error = ""
    @Published var result: URL?
    @Published var log: [String] = []
    private var process: Process?, activity: NSObjectProtocol?
    private var python = "", repo = "", runCommand = "", lastError = "", making = false
    private var k = 1, n = 1, stageName = "", stepName = "", frac = 0.0
    static let extensions = ["nsp", "xci", "nsz", "xcz"]

    var ready: Bool { rom != nil && keys != nil && out != nil && !running }

    /// the game's name for the output file and the work folder: the base file's name without its [title ID] and (version) tags
    static func name(_ rom: URL) -> String {
        let s = rom.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"\s*[\[(][^\])]*[\])]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[/:"$`\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "Game" : s
    }

    func start() {
        guard let rom, let keys, let out, let py = Bundle.main.object(forInfoDictionaryKey: "NXPython") as? String, let rp = Bundle.main.object(forInfoDictionaryKey: "NXRepo") as? String else {
            return fail("This app was not made by scripts/build_builder_app.sh.")
        }
        python = py; repo = rp
        let name = Job.name(rom), mac = platform == .mac
        let target = out.appendingPathComponent(name + (mac ? ".app" : ".ipa"))
        do {
            let nsp = try link(into: out.appendingPathComponent("NxNative-Work/\(name)"), [rom] + [update].compactMap { $0 } + dlcs)
            running = true; error = ""; lastError = ""; runCommand = ""; making = false; result = nil; log = []; overall = 0; k = 1; n = 1; frac = 0; status = "Starting …"; detail = ""
            try launch([repo + "/scripts/build_ipa_from_nsp.py", nsp.path, "-k", keys.path, "--progress", "json"] + (mac ? ["--platform", "mac"] : ["-o", target.path])) { self.finish($0, target, name) }
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Building the game")
        } catch { fail(error.localizedDescription) }
    }

    func cancel() { process?.interrupt() }   // SIGINT: the script stops its tools and exits with 130; the next run reuses what was finished

    private func launch(_ args: [String], then: @escaping @MainActor (Int32) -> Void) throws {
        let p = Process(), o = Pipe(), e = Pipe()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = args
        p.standardOutput = o; p.standardError = e
        p.terminationHandler = { p in
            let code = p.terminationReason == .uncaughtSignal ? 130 : p.terminationStatus   // a Python killed by the interrupt
            Task { @MainActor in try? await Task.sleep(nanoseconds: 300_000_000); then(code) }   // let the last lines arrive
        }
        try p.run()
        process = p
        read(o) { self.handle($0) }
        read(e) { self.log.append($0); self.lastError = $0 }
    }

    /// calls `on` for each line as it arrives (FileHandle.bytes.lines holds a pipe's lines back until its buffer is full)
    private func read(_ pipe: Pipe, _ on: @escaping @MainActor (String) -> Void) {
        let lines = Lines()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { return h.readabilityHandler = nil }   // end of output
            let ls = lines.feed(d)
            DispatchQueue.main.async { MainActor.assumeIsolated { ls.forEach(on) } }
        }
    }

    private func fail(_ m: String) { error = m; running = false }

    /// <dir> holds exactly the chosen files (as links, named by what the script globs for); the folders beside them (<id>_build/) are kept for the next run
    private func link(into dir: URL, _ files: [URL]) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) where (try? old.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { try fm.removeItem(at: old) }
        var used = Set<String>()
        for f in files {
            let ext = f.pathExtension.lowercased()
            guard Job.extensions.contains(ext) else { throw Failure(errorDescription: "\(f.lastPathComponent) is not an NSP / XCI / NSZ / XCZ file.") }
            var name = f.deletingPathExtension().lastPathComponent + "." + ext
            if used.contains(name) { name = "\(used.count)-" + name }   // two DLC folders may hold the same file name
            used.insert(name)
            try fm.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: f)
        }
        return dir
    }

    private func handle(_ line: String) {
        guard let e = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { return log.append(line) }
        switch e.ev {
        case "stage": k = e.k ?? k; n = max(e.n ?? n, 1); stageName = e.name ?? ""; stepName = e.step ?? ""; frac = 0; detail = ""
        case "step": stepName = e.step ?? ""; frac = 0; detail = ""
        case "progress":
            stepName = e.step ?? stepName; frac = e.frac ?? frac
            detail = [e.note ?? "", e.frac.map { "\(Int($0 * 100)) %" } ?? "", e.eta.map { "about \(Self.clock($0)) left" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case "stage_end": frac = 1
        case "say":
            log.append(e.msg ?? "")
            if let m = e.msg, m.hasPrefix("[RED]") { error = String(m.dropFirst(6)) }
            if let m = e.msg, m.hasPrefix("cd ") { runCommand = m }   // a Mac build's last line: the command that runs the game
        default: break
        }
        status = "[\(k)/\(n)] \(stageName)" + (stepName.isEmpty ? "" : " · \(stepName)")
        overall = min((Double(k - 1) + frac) / Double(n + (platform == .mac ? 1 : 0)), 1)   // a Mac build has the app as one more stage
    }

    private func finish(_ code: Int32, _ target: URL, _ name: String) {
        if code == 0, platform == .mac, !making {
            guard !runCommand.isEmpty else { return endRun(1, "The build did not print the command that runs the game.") }
            making = true; status = "[\(n + 1)/\(n + 1)] Mac app"; detail = "copying the game into \(target.lastPathComponent)"; overall = Double(n) / Double(n + 1)
            do { try launch([repo + "/scripts/make_mac_app.py", target.path, name, runCommand]) { self.finish($0, target, name) } } catch { fail(error.localizedDescription) }
            return
        }
        endRun(code, nil, target)
    }

    private func endRun(_ code: Int32, _ message: String? = nil, _ target: URL? = nil) {
        running = false; process = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        if code == 0 { overall = 1; status = "Done"; detail = ""; result = target }
        else if code == 130 { status = "Cancelled"; error = "" }
        else { status = "Failed"; if let message { error = message } else if error.isEmpty { error = lastError.isEmpty ? "The build stopped (exit code \(code)); see the log." : lastError } }
    }

    static func clock(_ s: Double) -> String { let s = Int(s); return s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : s >= 60 ? "\(s / 60) min" : "\(s) s" }
}

func pick(directory: Bool = false, multiple: Bool = false) -> [URL] {
    let p = NSOpenPanel()
    p.canChooseFiles = !directory; p.canChooseDirectories = directory; p.canCreateDirectories = directory; p.allowsMultipleSelection = multiple
    return p.runModal() == .OK ? p.urls : []
}

struct PathRow: View {
    let label: String, url: URL?, directory: Bool
    var optional = false
    let set: (URL?) -> Void
    var body: some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Text(url?.path ?? "not chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose …") { if let u = pick(directory: directory).first { set(u) } }
            Button { set(nil) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).opacity(optional && url != nil ? 1 : 0).disabled(!optional || url == nil)
        }
    }
}

struct ContentView: View {
    @ObservedObject var job: Job
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                HStack {
                    Text("Build for").frame(width: 90, alignment: .leading)
                    Picker("", selection: $job.platform) { Text("iPhone (IPA)").tag(Platform.ios); Text("Mac (app)").tag(Platform.mac) }.pickerStyle(.segmented).labelsHidden()
                }
                PathRow(label: "Base game", url: job.rom, directory: false) { job.rom = $0 }
                PathRow(label: "Update", url: job.update, directory: false, optional: true) { job.update = $0 }
                HStack(alignment: .top) {
                    Text("DLCs").frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(job.dlcs, id: \.self) { d in
                            HStack {
                                Text(d.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                                Button { job.dlcs.removeAll { $0 == d } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                            }
                        }
                        if job.dlcs.isEmpty { Text("none").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Add …") { job.dlcs += pick(multiple: true).filter { !job.dlcs.contains($0) } }
                    Image(systemName: "xmark.circle").opacity(0)
                }
                PathRow(label: "prod.keys", url: job.keys, directory: false) { job.keys = $0 }
                PathRow(label: "Output folder", url: job.out, directory: true) { job.out = $0 }
            }.disabled(job.running)
            Divider()
            HStack {
                if job.running { Button("Cancel") { job.cancel() } } else { Button("Start") { job.start() }.keyboardShortcut(.defaultAction).disabled(!job.ready) }
                if let r = job.result { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([r]) } }
            }
            ProgressView(value: job.overall)
            Text(job.status).font(.headline)
            Text(job.detail).foregroundStyle(.secondary)
            if !job.error.isEmpty { Text(job.error).foregroundStyle(.red).textSelection(.enabled) }
            DisclosureGroup("Log") {
                ScrollView { Text(job.log.suffix(300).joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160)
            }
        }.padding(16).frame(width: 640)
    }
}

@MainActor let job = Job()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { MainActor.assumeIsolated { job.cancel() } }
}

@main struct NxNativeBuilder: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { WindowGroup("NxNative Builder") { ContentView(job: job) }.windowResizability(.contentSize) }
}
