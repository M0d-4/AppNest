//
//  LCDownloadView.swift
//  LiveContainerSwiftUI
//
//  Multi-download queue + persistent tray that also hosts the "install IPA" action,
//  replacing the old toolbar button entirely.
//

import SwiftUI
import Combine
import UniformTypeIdentifiers

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DownloadItem
// ─────────────────────────────────────────────────────────────────────────────

public struct DownloadItem: Identifiable {
    public let id: UUID
    public let url: URL
    public let destinationURL: URL
    public var appName: String
    public var iconURL: URL?
    public var isUpdate: Bool

    public var progress: Float        = 0
    public var downloadedBytes: Int64 = 0
    public var totalBytes: Int64      = 0
    public var isActive: Bool         = false
    public var isCancelled: Bool      = false

    public init(id: UUID = UUID(),
                url: URL,
                destinationURL: URL,
                appName: String,
                iconURL: URL? = nil,
                isUpdate: Bool = false) {
        self.id             = id
        self.url            = url
        self.destinationURL = destinationURL
        self.appName        = appName
        self.iconURL        = iconURL
        self.isUpdate       = isUpdate
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DownloadQueueManager
//
// Deliberately has NO @MainActor on the class or its stored properties so that
// SharedModel (nonisolated init) can instantiate it freely. All @Published
// mutations are dispatched to the main queue manually, matching the pattern
// of the original single-item DownloadHelper.
// ─────────────────────────────────────────────────────────────────────────────

// @unchecked Sendable: all @Published mutations are dispatched to DispatchQueue.main,
// so cross-actor captures are safe. This suppresses Swift 6 Sendable errors on the
// DispatchQueue.main.async { [weak self] } captures inside the class.
public final class DownloadQueueManager: ObservableObject, @unchecked Sendable {

    @Published public private(set) var items: [DownloadItem] = []

    // Computed properties — safe to call from any context because they only
    // read @Published state which is always mutated on the main queue.
    public var isDownloading: Bool { items.contains { $0.isActive && !$0.isCancelled } }
    public var isEmpty: Bool       { items.isEmpty }

    // Legacy shim properties for existing call-sites
    public var downloadProgress: Float  { _firstActive?.progress       ?? 0 }
    public var downloadedSize: Int64    { _firstActive?.downloadedBytes ?? 0 }
    public var totalSize: Int64         { _firstActive?.totalBytes      ?? 0 }
    public var cancelled: Bool          { _firstActive?.isCancelled     ?? false }

    public var appName: String {
        get { _firstActive?.appName ?? "" }
        set { _pendingLegacyName = newValue }
    }
    public var isUpdate: Bool {
        get { _firstActive?.isUpdate ?? false }
        set { /* set per-item at enqueue time */ }
    }

    // Written/read exclusively on the main thread by SwiftUI views —
    // no actor annotation needed; callers are always @MainActor views.
    public var _pendingLegacyName: String = ""
    public var _pendingIconURL: URL? = nil

    private var _tasks: [UUID: URLSessionDownloadTask] = [:]
    private var _continuations: [UUID: UnsafeContinuation<(), Never>] = [:]

    private var _firstActive: DownloadItem? {
        items.first { $0.isActive && !$0.isCancelled }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    @discardableResult
    public func enqueue(item: DownloadItem) -> UUID {
        var m = item
        if m.appName.isEmpty && !_pendingLegacyName.isEmpty {
            m.appName = _pendingLegacyName
        }
        if m.iconURL == nil, let pending = _pendingIconURL {
            m.iconURL = pending
        }
        _pendingLegacyName = ""
        _pendingIconURL = nil
        DispatchQueue.main.async { self.items.append(m) }
        Task { await _start(id: m.id) }
        return m.id
    }

    public func cancel(id: UUID) {
        _tasks[id]?.cancel()
        _tasks.removeValue(forKey: id)
        _continuations.removeValue(forKey: id)?.resume()
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[idx].isCancelled = true
            self.items[idx].isActive    = false
            self._removeFinished(id: id)
        }
    }

    public func cancelAll() {
        for item in items where item.isActive { cancel(id: item.id) }
    }

    public func cancel() {
        if let first = _firstActive { cancel(id: first.id) }
    }

    public func download(url: URL, to destinationURL: URL) async throws {
        var name = _pendingLegacyName
        if name.isEmpty {
            let raw = url.lastPathComponent
            name = raw.hasSuffix(".ipa")  ? String(raw.dropLast(4))
                 : raw.hasSuffix(".tipa") ? String(raw.dropLast(5))
                 : raw
        }
        _pendingLegacyName = ""
        let item   = DownloadItem(url: url, destinationURL: destinationURL, appName: name)
        let itemID = enqueue(item: item)
        while items.contains(where: { $0.id == itemID && $0.isActive }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // ── Private ───────────────────────────────────────────────────────────────

    private func _start(id: UUID) async {
        // Mark active on main queue first
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                if let idx = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[idx].isActive = true
                }
                ready.resume()
            }
        }

        guard let itemIdx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[itemIdx]

        await withUnsafeContinuation { (c: UnsafeContinuation<(), Never>) in
            _continuations[id] = c

            let delegate = _DownloadDelegate(
                onProgress: { prog, dl, total in
                    DispatchQueue.main.async {
                        guard let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                        self.items[i].progress        = prog
                        self.items[i].downloadedBytes = dl
                        self.items[i].totalBytes      = total
                    }
                },
                onComplete: { tempURL, _ in
                    DispatchQueue.main.async {
                        guard let i2 = self.items.firstIndex(where: { $0.id == id }) else {
                            self._continuations.removeValue(forKey: id)?.resume()
                            return
                        }
                        self.items[i2].isActive = false
                        if let tempURL {
                            try? FileManager.default.moveItem(at: tempURL,
                                                             to: self.items[i2].destinationURL)
                        }
                        self._tasks.removeValue(forKey: id)
                        self._continuations.removeValue(forKey: id)?.resume()
                        self._removeFinished(id: id)
                    }
                }
            )
            let session = URLSession(configuration: .default, delegate: delegate,
                                     delegateQueue: .main)
            let task = session.downloadTask(with: item.url)
            _tasks[id] = task
            task.resume()
        }
    }

    private func _removeFinished(id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.items.removeAll { $0.id == id }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - URLSession delegate
// ─────────────────────────────────────────────────────────────────────────────

private final class _DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Float, Int64, Int64) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Float, Int64, Int64) -> Void,
         onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Float(totalBytesWritten) / Float(totalBytesExpectedToWrite),
                   totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse {
            (200...299).contains(http.statusCode)
                ? onComplete(location, nil)
                : onComplete(location, NSError(domain: "", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
        } else {
            onComplete(nil, NSError(domain: "", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error { onComplete(nil, error) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DownloadTrayView
// ─────────────────────────────────────────────────────────────────────────────

public struct DownloadTrayView: View {
    @ObservedObject var manager: DownloadQueueManager

    var onInstallIPA: (() -> Void)?
    var onInstallURL: (() -> Void)?

    @State private var isExpanded = false

    public init(manager: DownloadQueueManager,
                onInstallIPA: (() -> Void)? = nil,
                onInstallURL: (() -> Void)? = nil) {
        self.manager      = manager
        self.onInstallIPA = onInstallIPA
        self.onInstallURL = onInstallURL
    }

    public var body: some View {
        VStack {
            Spacer()
            Group {
                if isExpanded {
                    expandedCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    collapsedPill
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: manager.items.count)
        .zIndex(9999)
    }

    // ── Collapsed pill ────────────────────────────────────────────────────────

    private var collapsedPill: some View {
        Button { withAnimation(.spring(response: 0.3)) { isExpanded = true } } label: {
            HStack(spacing: 8) {
                if manager.isDownloading {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 2)
                            .frame(width: 20, height: 20)
                        Circle()
                            .trim(from: 0, to: CGFloat(manager.downloadProgress))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .frame(width: 20, height: 20)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.12), value: manager.downloadProgress)
                    }
                    let count = manager.items.count
                    Text(count == 1
                         ? (manager.items.first?.appName.isEmpty == false
                            ? manager.items.first!.appName : "Downloading…")
                         : "\(count) downloads")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                    Text("Install")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
            )
        }
        .buttonStyle(.plain)
    }

    // ── Expanded card ─────────────────────────────────────────────────────────

    private var expandedCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text(manager.isDownloading
                     ? (manager.items.count == 1 ? "Downloading" : "\(manager.items.count) Downloads")
                     : "Install App")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button { withAnimation(.spring(response: 0.3)) { isExpanded = false } } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if !manager.items.isEmpty {
                Divider().padding(.horizontal, 8)
                ForEach(manager.items) { item in
                    DownloadItemRow(item: item) { manager.cancel(id: item.id) }
                    if item.id != manager.items.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }

            Divider().padding(.horizontal, 8).padding(.top, 4)

            HStack(spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.3)) { isExpanded = false }
                    onInstallIPA?()
                } label: {
                    Label("From File", systemImage: "doc.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)

                Divider().frame(height: 28)

                Button {
                    withAnimation(.spring(response: 0.3)) { isExpanded = false }
                    onInstallURL?()
                } label: {
                    Label("From URL", systemImage: "link.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: UIColor.systemBackground))
                .shadow(color: .black.opacity(0.14), radius: 14, x: 0, y: 4)
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - DownloadItemRow
// ─────────────────────────────────────────────────────────────────────────────

private struct DownloadItemRow: View {
    let item: DownloadItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let iconURL = item.iconURL {
                    CachedAsyncImage(url: iconURL)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "app.dashed")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.appName.isEmpty ? "Downloading…" : item.appName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 4)
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: geo.size.width * CGFloat(item.progress), height: 4)
                            .animation(.linear(duration: 0.1), value: item.progress)
                    }
                }
                .frame(height: 4)

                Text(item.totalBytes > 0
                     ? "\(_fmt(item.downloadedBytes)) / \(_fmt(item.totalBytes))"
                     : "\(_fmt(item.downloadedBytes))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func _fmt(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle   = .file
        return f.string(fromByteCount: bytes)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - CachedAsyncImage
// ─────────────────────────────────────────────────────────────────────────────

struct CachedAsyncImage: View {
    let url: URL
    @State private var uiImage: UIImage? = nil
    private static let cache = NSCache<NSURL, UIImage>()

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                Color.secondary.opacity(0.15).onAppear { load() }
            }
        }
    }

    private func load() {
        if let cached = Self.cache.object(forKey: url as NSURL) { uiImage = cached; return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let img = UIImage(data: data) else { return }
            Self.cache.setObject(img, forKey: url as NSURL)
            DispatchQueue.main.async { uiImage = img }
        }.resume()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Legacy shim
// ─────────────────────────────────────────────────────────────────────────────

public typealias DownloadHelper = DownloadQueueManager

public struct DownloadAlertModifier: ViewModifier {
    @ObservedObject var helper: DownloadQueueManager
    public func body(content: Content) -> some View { content }
}

extension View {
    public func downloadAlert(helper: DownloadQueueManager) -> some View {
        self.modifier(DownloadAlertModifier(helper: helper))
    }
}
