//
//  Android_BrowserApp.swift
//  Android Browser
//
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

@main
struct ADBExplorerApp: App {
    @StateObject private var model = ADBModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 540)
                .onAppear {
                    model.refreshDevices()
                    // Delay list to after devices populate
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.listDirectory() }
                }
                .alert(item: Binding(get: {
                    model.errorMessage.map { IdentifiableError(message: $0) }
                }, set: { _ in model.errorMessage = nil })) { identifiable in
                    Alert(title: Text("Error"), message: Text(identifiable.message), dismissButton: .default(Text("OK")))
                }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

// Put this near your views
private struct RowDoubleClickModifier: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())            // expand hit area
            .onTapGesture(count: 2, perform: action)
    }
}
private extension View {
    func rowDoubleClick(_ action: @escaping () -> Void) -> some View {
        modifier(RowDoubleClickModifier(action: action))
    }
}

struct IdentifiableError: Identifiable {
    let id = UUID()
    let message: String
}

struct ContentView: View {
    @EnvironmentObject var model: ADBModel
    @State private var selection = Set<ADBEntry.ID>()
    @State private var isDropping: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                deviceSidebar
                    .frame(width: 280)
                    .background(.quaternary.opacity(0.05))
                Divider()
                filePane
            }
            Divider()
            statusBar
        }
    }

    private var header: some View {
        HStack {
            Button(action: { model.goUp() }) {
                Label("Up", systemImage: "chevron.up")
            }.disabled(model.cwd == "/")
            breadcrumb
            Spacer()
            Button(action: { model.refreshDevices() }) {
                Label("Devices", systemImage: "arrow.clockwise")
            }
            Button(action: { model.listDirectory() }) {
                Label("Refresh", systemImage: "gobackward")
            }
            Button(action: pullSelected) {
                Label("Pull", systemImage: "square.and.arrow.down")
            }.disabled(currentSelection().isEmpty)
        }
        .padding(8)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("Path:")
                    .foregroundStyle(.secondary)
                let comps = model.cwd.split(separator: "/").map(String.init)
                Button(action: {
                    model.cwd = "/"
                    model.listDirectory()
                }) {
                    Text("/")
                }
                ForEach(0..<comps.count, id: \.self) { i in
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                    Button(action: {
                        let prefix = "/" + comps[..<(i+1)].joined(separator: "/")
                        model.cwd = prefix
                        model.listDirectory()
                    }) { Text(comps[i]) }
                }
            }.padding(.horizontal, 4)
        }
    }

    private var deviceSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Devices")
                    .font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            Picker("Device", selection: Binding(get: {
                model.selectedDevice?.id ?? ""
            }, set: { newValue in
                model.selectedDevice = model.devices.first(where: { $0.id == newValue })
                model.listDirectory()
            })) {
                ForEach(model.devices) { dev in
                    Text(dev.description).tag(dev.id)
                }
            }
            .labelsHidden()

            Divider().padding(.vertical, 4)

            Text("Current Directory")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.cwd)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Text("Tips")
                    .font(.subheadline).bold()
                Text("• Double-click folders to open.")
                Text("• Drag files out to Finder to pull.")
                Text("• Drop files here to push to current directory.")
                Text("• Edit ADB path in Settings.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.trailing, 8)
        }
        .padding(10)
    }
    
    

    private var filePane: some View {
        Table(model.entries, selection: $selection) {
            TableColumn("Name") { item in
                HStack {
                    Image(systemName: item.isDir ? "folder" : "doc")
                    Text(item.name)
                }
                .onTapGesture(count: 2) { model.enter(item) }
                .onDrag { provideDrag(for: item) }
            }
            TableColumn("Size") { item in
                Text(item.isDir ? "—" : byteCount(item.size))
                    .foregroundStyle(.secondary)
            }.width(100)
            TableColumn("Modified") { item in
                Text(item.modified ?? "—").foregroundStyle(.secondary)
            }.width(200)
            TableColumn("Path") { item in
                Text(item.path).foregroundStyle(.secondary)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropping) { providers in
            handleDrop(providers: providers)
        }
        .overlay(alignment: .center) {
            if model.entries.isEmpty && !model.isBusy {
                ContentUnavailableView("Empty directory", systemImage: "tray", description: Text("Drop files here to push from Mac to device."))
            }
        }
        .padding(4)
    }

    private func byteCount(_ size: Int64?) -> String {
        guard let s = size, s >= 0 else { return "—" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: s)
    }

    private func currentSelection() -> [ADBEntry] {
        model.entries.filter { selection.contains($0.id) }
    }

    private func pullSelected() {
        let items = currentSelection()
        guard !items.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a destination folder for pulled files."
        if panel.runModal() == .OK, let dest = panel.url {
            Task {
                model.isBusy = true
                defer { model.isBusy = false }
                do {
                    try await model.pull(entries: items, to: dest) { step in
                        model.status = step
                    }
                    model.status = "Pull complete."
                } catch {
                    model.errorMessage = "Pull failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func provideDrag(for entry: ADBEntry) -> NSItemProvider {
        let item = NSItemProvider()

        // Use a generic UTI; Finder cares about the returned file URL, not this hint.
        let typeIdentifier = UTType.item.identifier

        item.registerFileRepresentation(forTypeIdentifier: typeIdentifier,
                                        fileOptions: [],     // not open-in-place; we hand back a temp file
                                        visibility: .all) { completion in
            // Prepare a temp location
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ADBDrag-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                completion(nil, false, error)
                return nil
            }

            // Perform the pull asynchronously, then provide the file URL
            Task {
                do {
                    try await model.pull(entries: [entry], to: tempDir)
                    let fileURL = tempDir.appendingPathComponent(entry.name)
                    completion(fileURL, true, nil)     // move=true lets the system clean up if needed
                } catch {
                    completion(nil, false, error)
                }
            }

            // We don’t have byte-level progress here; return nil.
            return nil
        }

        return item
    }


    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let urls = providers.compactMap { provider -> URL? in
            let sema = DispatchSemaphore(value: 0)
            var found: URL?
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, _) in
                    defer { sema.signal() }
                    if let data = item as? Data, let str = String(data: data, encoding: .utf8), let url = URL(string: str) {
                        found = url
                    } else if let url = item as? URL {
                        found = url
                    }
                }
                sema.wait()
            }
            return found
        }
        if urls.isEmpty { return false }

        Task {
            model.isBusy = true
            defer { model.isBusy = false }
            do {
                try await model.push(localURLs: urls, to: model.cwd) { step in
                    model.status = step
                }
                model.status = "Push complete."
                model.listDirectory()
            } catch {
                model.errorMessage = "Push failed: \(error.localizedDescription)"
            }
        }
        return true
    }

    private var statusBar: some View {
        HStack {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.status)
                .foregroundStyle(.secondary)
            Spacer()
            Text(model.selectedDevice?.description ?? "No device")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(6)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: ADBModel
    @State private var tempPath: String = ""

    var body: some View {
        Form {
            Section(header: Text("ADB")) {
                HStack {
                    TextField("ADB path", text: Binding(get: {
                        tempPath.isEmpty ? model.adbPath : tempPath
                    }, set: { tempPath = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.title = "Locate adb"
                        if panel.runModal() == .OK, let url = panel.url {
                            tempPath = url.path
                        }
                    }
                    Button("Use Default") {
                        tempPath = "/opt/homebrew/bin/adb"
                    }
                }
                HStack {
                    Button("Test") { testADB() }
                    Spacer()
                    Button("Save") {
                        if !tempPath.isEmpty { model.adbPath = tempPath }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .onAppear { tempPath = model.adbPath }
    }

    private func testADB() {
        Task {
            do {
                let (out, err, code) = await testProcess(launchPath: tempPath)
                if code == 0 {
                    showAlert(title: "ADB OK", message: out.isEmpty ? "adb ran successfully." : out)
                } else {
                    showAlert(title: "ADB Error", message: err.isEmpty ? out : err)
                }
            }
        }
    }

    private func testProcess(launchPath: String) async -> (String, String, Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let task = Process()
                task.launchPath = launchPath
                task.arguments = ["version"]
                let outPipe = Pipe(), errPipe = Pipe()
                task.standardOutput = outPipe; task.standardError = errPipe
                do { try task.run() } catch {
                    cont.resume(returning: ("", error.localizedDescription, 127)); return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                cont.resume(returning: (String(data: outData, encoding: .utf8) ?? "",
                                        String(data: errData, encoding: .utf8) ?? "",
                                        task.terminationStatus))
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
