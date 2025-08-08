//
//  ContentView.swift
//  Android Browser
//
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - Models

struct ADBDevice: Identifiable, Hashable {
    let id: String       // serial
    let description: String
}

struct ADBEntry: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64?
    let modified: String?
}

// MARK: - ADB Runner

@MainActor
final class ADBModel: ObservableObject {
    @AppStorage("adbPath") var adbPath: String = "/opt/homebrew/bin/adb"

    @Published var devices: [ADBDevice] = []
    @Published var selectedDevice: ADBDevice?
    @Published var cwd: String = "/storage/emulated/0"
    @Published var entries: [ADBEntry] = []
    @Published var isBusy: Bool = false
    @Published var status: String = "Idle"
    @Published var errorMessage: String?

    // MARK: Device management

    func refreshDevices() {
        Task {
            isBusy = true
            defer { isBusy = false }
            do {
                let out = try await runADB(["devices", "-l"])
                let lines = out.split(separator: "\n").dropFirst()
                var ds: [ADBDevice] = []
                for line in lines {
                    let parts = line.split(separator: " ")
                    guard let serial = parts.first, parts.contains(where: { $0 == "device" }) else { continue }
                    // Build a friendly description
                    let desc = line.replacingOccurrences(of: "\t", with: " ")
                    ds.append(.init(id: String(serial), description: desc))
                }
                await MainActor.run {
                    devices = ds
                    if selectedDevice == nil { selectedDevice = ds.first }
                }
            } catch {
                self.errorMessage = "Failed to list devices: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Directory listing

    func listDirectory() {
        guard let dev = selectedDevice else { return }
        let path = cwd
        Task {
            isBusy = true
            status = "Listing \(path)…"
            defer { isBusy = false; status = "Idle" }
            do {
                let outLL = try await runADB(["-s", dev.id, "shell", "ls", "-ll", escapeRemote(path)])
                if let parsed = parseToyboxLLWithTZ(out: outLL, base: path), !parsed.isEmpty {
                    await MainActor.run { self.entries = parsed.sorted(by: sortDirsFirst) }
                    return
                }
                // Fallback: -l (no separate TZ token on some ROMs)
                let outL = try await runADB(["-s", dev.id, "shell", "ls", "-l", escapeRemote(path)])
                let parsedL = parseToyboxLsLong(out: outL, base: path)
                if !parsedL.isEmpty {
                    await MainActor.run { self.entries = parsedL.sorted(by: sortDirsFirst) }
                    return
                }
                // Minimal fallback: names only
                let out1p = try await runADB(["-s", dev.id, "shell", "ls", "-1p", escapeRemote(path)])
                let names = out1p.split(separator: "\n").map(String.init)
                let minimal = names.compactMap { line -> ADBEntry? in
                    let isDir = line.hasSuffix("/")
                    let name = isDir ? String(line.dropLast()) : line
                    guard !name.isEmpty, name != "total" else { return nil }
                    let full = path == "/" ? "/\(name)" : "\(path)/\(name)"
                    return ADBEntry(name: name, path: full, isDir: isDir, size: nil, modified: nil)
                }
                await MainActor.run { self.entries = minimal.sorted(by: sortDirsFirst) }
            } catch {
                self.errorMessage = "Failed to list \(path): \(error.localizedDescription)"
            }

        }
    }

    private func sortDirsFirst(a: ADBEntry, b: ADBEntry) -> Bool {
        if a.isDir != b.isDir { return a.isDir && !b.isDir }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }
    
    /// Parse Toybox `ls -ll` where the timezone is its own token, e.g.
    /// drwxrws--- 2 u0_a317 media_rw 3452 2025-06-18 21:15:08.027999994 +0900 Alarms
    private func parseToyboxLLWithTZ(out: String, base: String) -> [ADBEntry]? {
        var result: [ADBEntry] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }

            // Tokenize by whitespace (Toybox prints multiple spaces between cols).
            let t = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Need at least: perms, links, owner, group, size, date, time, tz, name
            guard t.count >= 9 else { continue }

            let perms = t[0]
            let isDir = perms.first == "d"

            // Validate date/time/TZ positions
            let dateTok = t[5]
            let timeTok = t[6]
            let tzTok   = t[7]

            // Quick/cheap sanity checks
            guard dateTok.count == 10, dateTok[dateTok.index(dateTok.startIndex, offsetBy: 4)] == "-",
                  tzTok.first == "+" || tzTok.first == "-", tzTok.count == 5 else {
                // Not the expected pattern; bail so caller can try other parsers.
                continue
            }

            // Size (t[4]) may fail to parse; that's fine.
            let size = Int64(t[4])

            // Name is everything after tz token; may include spaces or " -> target"
            let namePart = t.dropFirst(8).joined(separator: " ")
            if namePart.isEmpty { continue }
            let cleanName = namePart.components(separatedBy: " -> ").first!.trimmingCharacters(in: .whitespaces)

            // Build modified string
            let modified = "\(dateTok) \(timeTok) \(tzTok)"

            let fullPath = base == "/" ? "/\(cleanName)" : "\(base)/\(cleanName)"
            result.append(ADBEntry(name: cleanName, path: fullPath, isDir: isDir, size: size, modified: modified))
        }
        return result
    }

    
    private func parseToyboxLsLong(out: String, base: String) -> [ADBEntry] {
        var result: [ADBEntry] = []
        let reDate = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)

        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }

            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let perms = tokens.first, !perms.isEmpty else { continue }
            let isDir = perms.first == "d"

            // Find the date token index (YYYY-MM-DD)
            guard let dateIdx = tokens.firstIndex(where: { t in
                reDate.firstMatch(in: t, range: NSRange(location: 0, length: t.utf16.count)) != nil
            }) else {
                // Fallback: list-style we don't recognize; skip
                continue
            }

            // Time token comes right after date (can be HH:MM, HH:MM:SS, or HH:MM:SS.nnnnnnnnn)
            let timeIdx = dateIdx + 1
            guard tokens.indices.contains(timeIdx) else { continue }
            let modified = tokens[dateIdx] + " " + tokens[timeIdx]

            // Size is the last integer-like token before the date (scan backwards a few)
            var size: Int64?
            var scan = dateIdx - 1
            var scans = 0
            while scan > 0 && scans < 6 {
                if let v = Int64(tokens[scan]) { size = v; break }
                scans += 1; scan -= 1
            }

            // Name: everything after the time token
            let namePart = tokens.dropFirst(timeIdx + 1).joined(separator: " ")
            if namePart.isEmpty { continue }

            // Trim symlink target "name -> target"
            let name = namePart.components(separatedBy: " -> ").first!.trimmingCharacters(in: .whitespaces)

            let fullPath = base == "/" ? "/\(name)" : "\(base)/\(name)"
            result.append(ADBEntry(name: name, path: fullPath, isDir: isDir, size: size, modified: modified))
        }
        return result
    }


    // Parse busybox/toybox ls -l output (simplified, robust to differences)
    private func parseLsLong(out: String, base: String) -> [ADBEntry] {
        var result: [ADBEntry] = []
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("total ") { continue }

            // expected-ish: "drwxr-xr-x  2 u0_a123 u0_a123     4096 2025-01-01T12:34:56 Folder Name"
            // or:           "-rw-r--r--  1 u0...      12345 2025-... File Name"
            // Toybox may put date before size; be defensive by splitting and scanning.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = parts.first else { continue }
            let isDir = first.first == "d"

            // Strategy: find ISO timestamp token (YYYY-..T..). Everything after that is the name; size is the integer token just before date or just after perms+owners.
            var modified: String?
            var size: Int64?
            var name: String?

            let tokens = parts.map(String.init)
            if let dateIdx = tokens.firstIndex(where: { $0.contains("T") && $0.count >= 10 && $0.contains("-") }) {
                modified = tokens[dateIdx]
                // find a numeric size nearby (look backward a few tokens)
                for back in (max(0, dateIdx-3))..<dateIdx {
                    if let s = Int64(tokens[back]) { size = s }
                }
                // name is remainder of original line after the date token
                let afterDate = tokens[(dateIdx+1)...].joined(separator: " ")
                name = afterDate.isEmpty ? "(unknown)" : afterDate
            } else {
                // fallback: name at end, size unknown
                name = tokens.last ?? "(unknown)"
            }

            guard let finalName = name else { continue }
            // handle symlinks "foo -> bar" by trimming after " -> "
            let cleanName = finalName.components(separatedBy: " -> ").first!.trimmingCharacters(in: .whitespaces)
            let fullPath = base == "/" ? "/\(cleanName)" : "\(base)/\(cleanName)"
            result.append(ADBEntry(name: cleanName, path: fullPath, isDir: isDir, size: size, modified: modified))
        }
        return result
    }

    // MARK: Navigation

    func enter(_ entry: ADBEntry) {
        guard entry.isDir else { return }
        cwd = entry.path
        listDirectory()
    }

    func goUp() {
        guard cwd != "/" else { return }
        let parent = (cwd as NSString).deletingLastPathComponent
        cwd = parent.isEmpty ? "/" : parent
        listDirectory()
    }

    // MARK: Copy (pull / push)

    func pull(entries: [ADBEntry], to destinationDir: URL, progress: ((String)->Void)? = nil) async throws {
        guard let dev = selectedDevice else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "No device selected"]) }
        for e in entries {
            progress?("Pulling \(e.name)…")
            _ = try await runADB(["-s", dev.id, "pull", escapeRemote(e.path), destinationDir.appendingPathComponent(e.name).path])
        }
    }

    func push(localURLs: [URL], to remoteDir: String, progress: ((String)->Void)? = nil) async throws {
        guard let dev = selectedDevice else { throw NSError(domain: "ADB", code: 1, userInfo: [NSLocalizedDescriptionKey: "No device selected"]) }
        for url in localURLs {
            progress?("Pushing \(url.lastPathComponent)…")
            _ = try await runADB(["-s", dev.id, "push", url.path, escapeRemote(remoteDir)])
        }
    }

    // MARK: Core runner

    private func runADB(_ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let (out, err, code) = self.runProcess(launchPath: self.adbPath, args: args)
                    if code == 0 {
                        cont.resume(returning: out)
                    } else {
                        let message = err.isEmpty ? out : err
                        cont.resume(throwing: NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: message]))
                    }
                }
            }
        }
    }

    private func runProcess(launchPath: String, args: [String]) -> (String, String, Int32) {
        let task = Process()
        task.launchPath = launchPath
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do { try task.run() } catch {
            return ("", "Failed to run \(launchPath): \(error.localizedDescription)", 127)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "",
                task.terminationStatus)
    }

    private func escapeRemote(_ path: String) -> String {
        // adb doesn't process shell quotes uniformly across platforms; keep paths simple
        return path
    }
}


// MARK: - File Promise (Drag from device → Finder)

final class PullFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let model: ADBModel
    let entry: ADBEntry

    init(model: ADBModel, entry: ADBEntry) {
        self.model = model
        self.entry = entry
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        return entry.name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let dest = url.appendingPathComponent(entry.name)
        Task {
            do {
                try await model.pull(entries: [entry], to: url) { _ in }
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        OperationQueue.main
    }
}

