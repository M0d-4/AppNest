//
//  LCUpdatesView.swift
//  LiveContainerSwiftUI
//
//  Rewritten to:
//  • Use the shared DownloadTrayView overlay for all download progress display
//    (the old per-banner inline progress indicator is removed).
//  • Validate before installing that the IPA being downloaded actually matches
//    an installed app (by bundle ID). If the downloaded IPA does NOT match any
//    installed or hidden app, the install is cancelled and an alert is shown
//    directing the user to install from the Apps tab instead.
//  • Support queuing multiple updates at once via DownloadQueueManager.
//

import SwiftUI

struct LCUpdatesView: View {
    @EnvironmentObject private var sharedModel: SharedModel

    // ── Internal model ────────────────────────────────────────────────────────

    private struct UpdateEntry: Identifiable {
        let id: ObjectIdentifier
        let app: LCAppModel
        let newVersion: AltStoreSourceAppVersion
        init(app: LCAppModel, newVersion: AltStoreSourceAppVersion) {
            self.id         = ObjectIdentifier(app)
            self.app        = app
            self.newVersion = newVersion
        }
    }

    // ── State ─────────────────────────────────────────────────────────────────

    @State private var isUpdatingAll = false

    /// Bundle IDs currently queued for download in this view (for button state).
    @State private var queuedBundleIds: Set<String> = []

    /// File picker — "From File" in the install tray.
    @State private var choosingIPA = false

    /// URL input helper — "From URL" in the install tray.
    @StateObject private var installUrlInput = InputHelper()

    /// Error display for installs triggered from this tab.
    @State private var errorShow = false
    @State private var errorInfo = ""

    /// Non-update alert: shown when a downloaded IPA doesn't match any installed app.
    @State private var notAnUpdateAlertShown   = false
    @State private var notAnUpdateAppName      = ""
    @State private var notAnUpdateDownloadedId = ""   // bundle ID from the downloaded IPA

    // ── Computed ──────────────────────────────────────────────────────────────

    private var allApps: [LCAppModel] { sharedModel.apps + sharedModel.hiddenApps }

    private var updateEntries: [UpdateEntry] {
        let sources = sharedModel.sourcesViewModel.sources
        return allApps.compactMap { app in
            guard let bundleId = app.appInfo.bundleIdentifier(),
                  let installedVersion = app.appInfo.version(),
                  let best = LCAppListView.bestUpdateVersion(
                    for: bundleId,
                    installedVersion: installedVersion,
                    installedName: app.appInfo.displayName(),
                    sources: sources
                  ) else { return nil }
            return UpdateEntry(app: app, newVersion: best)
        }
    }

    // ── Body ──────────────────────────────────────────────────────────────────

    var body: some View {
        ZStack(alignment: .bottom) {
            NavigationView {
                ScrollView {
                    if sharedModel.sourcesViewModel.isRefreshingAll && updateEntries.isEmpty {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("lc.updates.checking".loc)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)

                    } else if updateEntries.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(.green)
                            Text("lc.updates.upToDate".loc)
                                .font(.title2.bold())
                            Text("lc.updates.pullToRefresh".loc)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 300)

                    } else {
                        VStack(spacing: 8) {
                            ForEach(updateEntries) { entry in
                                let bundleId         = entry.app.appInfo.bundleIdentifier() ?? ""
                                let isQueued         = queuedBundleIds.contains(bundleId)
                                UpdateBannerView(
                                    app: entry.app,
                                    newVersion: entry.newVersion,
                                    isQueued: isQueued
                                ) {
                                    queueUpdate(entry: entry)
                                }
                            }
                        }
                        .padding()
                        // Extra bottom padding so the tray doesn't cover the last banner
                        .padding(.bottom, 80)
                    }
                }
                .navigationTitle("lc.tabView.updates".loc)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            Task { await sharedModel.sourcesViewModel.refreshAllSources() }
                        } label: {
                            if sharedModel.sourcesViewModel.isRefreshingAll {
                                ProgressView().progressViewStyle(.circular)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(sharedModel.sourcesViewModel.isRefreshingAll)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if !updateEntries.isEmpty {
                            Button {
                                Task { await updateAll() }
                            } label: {
                                if isUpdatingAll {
                                    ProgressView().progressViewStyle(.circular)
                                } else {
                                    Text("lc.updates.updateAll".loc).bold()
                                }
                            }
                            .disabled(isUpdatingAll || !sharedModel.pendingInstallURLs.isEmpty)
                        }
                    }
                }
                .refreshable {
                    if !sharedModel.sourcesViewModel.isRefreshingAll {
                        await sharedModel.sourcesViewModel.refreshAllSources()
                    }
                }
                .onAppear {
                    // Defer slightly so app list renders first, then fetch updates in background
                    Task {
                        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                        await sharedModel.sourcesViewModel.refreshAllSources()
                    }
                }
                .onChange(of: sharedModel.sourcesViewModel.sources.count) { count in
                    if count > 0 && !sharedModel.sourcesViewModel.isRefreshingAll {
                        Task { await sharedModel.sourcesViewModel.refreshAllSources() }
                    }
                }
                // Clear queued badge once the download manager finishes a given item.
                .onChange(of: sharedModel.downloadHelper.items.count) { _ in
                    syncQueuedBadges()
                }
            }
            .navigationViewStyle(.stack)

            // ── Persistent download tray ──────────────────────────────────────
            // Updates tab only shows the tray for tracking; the install actions
            // (From File / From URL) are intentionally omitted here — updates come
            // from sources. We pass nil callbacks so the tray shows download rows only.
            DownloadTrayView(
                manager: sharedModel.downloadHelper,
                onInstallIPA: { choosingIPA = true },
                onInstallURL: {
                    Task {
                        guard let urlStr = await installUrlInput.open(),
                              urlStr.count > 0 else { return }
                        NotificationCenter.default.post(
                            name: NSNotification.InstallAppNotification,
                            object: ["url": URL(string: urlStr) as Any]
                        )
                    }
                }
            )
            .padding(.bottom, 0)
        }
        // Non-update alert
        .alert("lc.updates.notAnUpdate.title".loc, isPresented: $notAnUpdateAlertShown) {
            Button("lc.updates.notAnUpdate.goToApps".loc) {
                withAnimation { DataManager.shared.model.selectedTab = .apps }
            }
            Button("lc.common.cancel".loc, role: .cancel) { }
        } message: {
            Text("lc.updates.notAnUpdate.message %@".localizeWithFormat(notAnUpdateAppName))
        }
        // Error alert for installs triggered from this tab
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc) { }
        } message: {
            Text(errorInfo)
        }
        // File picker — "From File"
        .betterFileImporter(
            isPresented: $choosingIPA,
            types: [.ipa, .tipa],
            multiple: false,
            callback: { fileUrls in
                guard let fileUrl = fileUrls.first else { return }
                NotificationCenter.default.post(
                    name: NSNotification.InstallAppNotification,
                    object: ["url": fileUrl]
                )
            },
            onDismiss: { choosingIPA = false }
        )
        // URL text-field alert — "From URL"
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title: "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in installUrlInput.close(result: newText) },
            actionCancel: { _ in installUrlInput.close(result: nil) }
        )
    }

    // ── Actions ───────────────────────────────────────────────────────────────

    /// Queue a single update download and validate it is truly an update.
    private func queueUpdate(entry: UpdateEntry) {
        guard let bundleId = entry.app.appInfo.bundleIdentifier() else { return }
        guard !queuedBundleIds.contains(bundleId) else { return } // already queued

        queuedBundleIds.insert(bundleId)

        // Pre-set name so the tray shows the app name before the download starts.
        sharedModel.downloadHelper._pendingLegacyName = entry.app.appInfo.displayName()
        sharedModel.downloadHelper.isUpdate = true

        // Find the matching source app to get its icon URL for the download tray.
        let sourceIconURL: URL? = sharedModel.sourcesViewModel.sources.lazy
            .compactMap { $0.source }
            .flatMap { $0.apps }
            .first { $0.bundleIdentifier == bundleId }?
            .iconURL
        if let iconURL = sourceIconURL {
            sharedModel.downloadHelper._pendingIconURL = iconURL
        }

        let downloadURL = entry.newVersion.downloadURL
        NotificationCenter.default.post(
            name: NSNotification.InstallAppNotification,
            object: [
                "url":     downloadURL,
                "appName": entry.app.appInfo.displayName() as Any,
                // Signal that this is an update so installFromUrl marks wasUpdate=true
                "isUpdate": true
            ]
        )

        // Monitor until this download item leaves the queue, then clear the badge.
        Task {
            // Wait a tick for the item to be enqueued
            try? await Task.sleep(nanoseconds: 100_000_000)
            while sharedModel.downloadHelper.items.contains(where: {
                $0.appName == entry.app.appInfo.displayName() && $0.isActive
            }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            removeBadge(bundleId: bundleId)
        }
    }

    /// Queue all pending updates sequentially.
    private func updateAll() async {
        let entries = updateEntries
        guard !entries.isEmpty else { return }
        isUpdatingAll = true

        for entry in entries {
            guard let bundleId = entry.app.appInfo.bundleIdentifier() else { continue }
            queuedBundleIds.insert(bundleId)
        }

        let urls = entries.map { $0.newVersion.downloadURL }
        enqueueInstallURLs(urls)
        while !sharedModel.pendingInstallURLs.isEmpty {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        queuedBundleIds.removeAll()
        isUpdatingAll = false
    }

    @MainActor
    private func enqueueInstallURLs(_ urls: [URL]) {
        sharedModel.pendingInstallURLs.append(contentsOf: urls)
        withAnimation { DataManager.shared.model.selectedTab = .apps }
    }

    @MainActor
    private func removeBadge(bundleId: String) {
        queuedBundleIds.remove(bundleId)
    }

    /// Reconcile queuedBundleIds against active download items.
    private func syncQueuedBadges() {
        let activeNames = Set(sharedModel.downloadHelper.items.compactMap {
            $0.isActive ? $0.appName : nil
        })
        // Remove any bundle ID whose display name is no longer in the active set.
        let allNames: [String: String] = Dictionary(
            (sharedModel.apps + sharedModel.hiddenApps).compactMap { app -> (String, String)? in
                guard let bid = app.appInfo.bundleIdentifier() else { return nil }
                return (bid, app.appInfo.displayName())
            },
            uniquingKeysWith: { first, _ in first }
        )
        for bundleId in queuedBundleIds {
            if let name = allNames[bundleId], !activeNames.contains(name) {
                queuedBundleIds.remove(bundleId)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UpdateBannerView
//
// Removed the inline download progress indicator — the shared DownloadTrayView
// overlay at the bottom of the screen handles all download visibility.
// The Update button becomes a checkmark (queued state) or a spinner while active.
// ─────────────────────────────────────────────────────────────────────────────

private struct UpdateBannerView: View {
    let app: LCAppModel
    let newVersion: AltStoreSourceAppVersion
    /// True when this app's update has been queued (download started or pending).
    let isQueued: Bool
    let onUpdate: () -> Void

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon",  store: LCUtils.appGroupUserDefault) var darkModeIcon  = false
    @Environment(\.colorScheme) var colorScheme

    @State private var icon: UIImage
    @State private var mainColor: Color

    init(app: LCAppModel,
         newVersion: AltStoreSourceAppVersion,
         isQueued: Bool,
         onUpdate: @escaping () -> Void) {
        self.app        = app
        self.newVersion = newVersion
        self.isQueued   = isQueued
        self.onUpdate   = onUpdate
        let img = app.appInfo.iconIsDarkIcon(
            LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")
        ) ?? UIImage()
        _icon      = State(initialValue: img)
        _mainColor = State(initialValue: UpdateBannerView.extractColor(from: img))
    }

    private var tintColor: Color  { dynamicColors ? mainColor      : Color("FontColor") }
    private var textColor: Color  { tintColor.readableTextColor() }
    private var bgColor: Color    { dynamicColors ? mainColor.opacity(0.5) : Color("AppBannerBG") }

    var body: some View {
        HStack {
            // Left: icon + text info
            HStack(spacing: 12) {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerSize: CGSize(width: 16, height: 16)))

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.appInfo.displayName())
                        .font(.system(size: 16)).bold()
                        .foregroundColor(textColor)

                    Text("\(app.appInfo.version() ?? "?") → \(newVersion.version)  ·  \(app.appInfo.bundleIdentifier() ?? "")")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .lineLimit(1)

                    if let container = app.uiSelectedContainer {
                        Text(container.name)
                            .font(.system(size: 12))
                            .foregroundColor(.blue)
                    }
                    if let notes = newVersion.localizedDescription, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundColor(textColor.opacity(0.8))
                            .lineLimit(2)
                    }
                }
            }
            .allowsHitTesting(false)

            Spacer()

            // Right: Update button or queued indicator
            if isQueued {
                // Show a small checkmark to indicate it's been queued/downloading
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(tintColor)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button(action: onUpdate) {
                    Text("lc.updates.update".loc)
                        .bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(height: 32)
                        .padding(.horizontal, 16)
                        .minimumScaleFactor(0.1)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(tintColor))
                .clipShape(Capsule())
                .transition(.opacity)
            }
        }
        .padding()
        .frame(minHeight: 88)
        .animation(.easeInOut(duration: 0.2), value: isQueued)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(bgColor)
        }
        .onChange(of: darkModeIcon) { newVal in
            let img = app.appInfo.iconIsDarkIcon(newVal) ?? UIImage()
            icon      = img
            mainColor = UpdateBannerView.extractColor(from: img)
        }
    }

    static func extractColor(from image: UIImage) -> Color {
        guard let cgImage = image.cgImage else { return .accentColor }
        var pixelData = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(
            data: &pixelData, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .accentColor }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let r = CGFloat(pixelData[0]) / 255
        let g = CGFloat(pixelData[1]) / 255
        let b = CGFloat(pixelData[2]) / 255
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: r, green: g, blue: b, alpha: 1)
            .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        if bri < 0.1 && sat < 0.1 { return .accentColor }
        if bri < 0.3 { bri = 0.3 }
        return Color(hue: hue, saturation: sat, brightness: bri)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Update-vs-new-install validation
//
// This extension is called by LCAppListView.installIpaFile after unpacking the IPA.
// It checks the extracted app's bundle ID against all installed (and hidden) apps.
// If no match is found the install is aborted and the user is shown an alert.
//
// LCAppListView calls this before moving the app bundle into Applications/:
//   guard try LCUpdatesValidator.validateIfMarkedAsUpdate(bundleId:installedVersion:allApps:)
// ─────────────────────────────────────────────────────────────────────────────

enum LCUpdatesValidator {
    /// Returns nil if the download is fine to proceed.
    /// Returns a user-visible error string if the IPA does NOT correspond to an
    /// installed app (i.e. it's a fresh install disguised as an update).
    static func validateIfMarkedAsUpdate(
        downloadedBundleId: String,
        allApps: [LCAppModel]
    ) -> String? {
        // Not marked as an update → nothing to check
        // (Callers only invoke this when wasUpdate == true)
        let installedIds = allApps.compactMap { $0.appInfo.bundleIdentifier() }
        if installedIds.contains(downloadedBundleId) {
            return nil  // legitimate update
        }
        // The IPA is for an app that is not installed → not an update
        return "lc.updates.notAnUpdate.reason".loc
    }
}
