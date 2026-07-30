//
//  LCDebugLogView.swift
//  LiveContainerSwiftUI
//
//  Lists and shows the on-device log files written by LCDebugLogInstall()
//  (see LCDebugLog.h) -- one file per process ("host", "guest",
//  "liveprocess") -- so NSLog output (including the existing
//  "[ForceLandscapeMode] ..." / "[AppNest] ..." diagnostic lines) can be
//  read and shared without a Mac or Console.app.
//

import SwiftUI
import UIKit

private let kLCDebugLogDirectoryName = "AppNestDebugLogs"

private struct LCDebugLogFile: Identifiable {
    let url: URL
    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var modifiedAt: Date?
    var sizeBytes: Int
}

private func lcDebugLogDirectoryURL() -> URL? {
    guard let base = LCSharedUtils.appGroupPath() else { return nil }
    return base.appendingPathComponent(kLCDebugLogDirectoryName, isDirectory: true)
}

private func lcListDebugLogFiles() -> [LCDebugLogFile] {
    guard let dir = lcDebugLogDirectoryURL() else { return [] }
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else {
        return []
    }
    return urls
        .filter { $0.pathExtension == "log" }
        .map { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return LCDebugLogFile(url: url, modifiedAt: values?.contentModificationDate, sizeBytes: values?.fileSize ?? 0)
        }
        .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
}

private func lcFormattedSize(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

// Thin wrapper so a plain file URL can be handed to the system share sheet
// (AirDrop / Files / Messages / Mail / etc.) -- this is the actual path to
// getting the log off the device without a cable or Console.app.
private struct LCActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct LCDebugLogDetailView: View {
    fileprivate let file: LCDebugLogFile
    @State private var text: String = ""
    @State private var showShareSheet = false

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(file.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            LCActivityView(activityItems: [file.url])
        }
        .onAppear {
            // Tail only, so a multi-megabyte log doesn't stall the UI --
            // the file itself is unaffected, and Share always sends the
            // whole thing.
            let maxBytes = 200 * 1024
            guard let handle = try? FileHandle(forReadingFrom: file.url) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            text = String(data: data, encoding: .utf8) ?? "(unable to decode log as UTF-8)"
        }
    }
}

struct LCDebugLogView: View {
    @State private var files: [LCDebugLogFile] = []

    var body: some View {
        List {
            if files.isEmpty {
                Text("No logs yet — run the app once, then pull to refresh.")
                    .foregroundColor(.secondary)
            }
            ForEach(files) { file in
                NavigationLink {
                    LCDebugLogDetailView(file: file)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                        HStack {
                            Text(lcFormattedSize(file.sizeBytes))
                            if let date = file.modifiedAt {
                                Text(date, style: .relative)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Debug Log")
        .onAppear {
            files = lcListDebugLogFiles()
        }
        .refreshable {
            files = lcListDebugLogFiles()
        }
    }
}
