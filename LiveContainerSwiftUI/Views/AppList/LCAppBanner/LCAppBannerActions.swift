//
//  LCAppBannerActions.swift
//  LiveContainerSwiftUI
//
//  Holds all business logic for a single app banner (run, uninstall, clone,
//  export, context menu, etc.) so it can be shared between the grid
//  (pure SwiftUI) and list (UIKit-backed) rendering modes without
//  duplicating ~900 lines of logic in two places.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppBinaryExportKind: String, Sendable {
    case dylib = "Dylib"
    case framework = "Framework"
}

struct AppBinaryExportItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let relativePath: String
    let kind: AppBinaryExportKind
}

struct AppExportShareItem: Identifiable {
    let id = UUID()
    let fileURL: URL
}

private let lcExportArtifactDirectoryName = "LCExports"

private func lcExportArtifactDirectoryURL(fileManager: FileManager = .default) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(lcExportArtifactDirectoryName, isDirectory: true)
}

private func lcEnsureExportArtifactDirectory(fileManager: FileManager = .default) throws -> URL {
    let directoryURL = lcExportArtifactDirectoryURL(fileManager: fileManager)
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        try fileManager.removeItem(at: directoryURL)
    }
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    return directoryURL
}

private func lcExportArtifactFileURL(fileName: String, fileManager: FileManager = .default) throws -> URL {
    let directoryURL = try lcEnsureExportArtifactDirectory(fileManager: fileManager)
    return directoryURL.appendingPathComponent(fileName)
}

private func lcListExportableBinaries(bundlePath: String) throws -> [AppBinaryExportItem] {
    let rootURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
    let fm = FileManager.default

    guard let enumerator = fm.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var items: [AppBinaryExportItem] = []
    var seenPaths = Set<String>()
    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"

    for case let itemURL as URL in enumerator {
        let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory = values.isDirectory ?? false

        if isDirectory && itemURL.pathExtension.lowercased() == "framework" {
            let relativePath = itemURL.path.hasPrefix(rootPrefix) ? String(itemURL.path.dropFirst(rootPrefix.count)) : itemURL.lastPathComponent
            if seenPaths.insert(relativePath).inserted {
                items.append(AppBinaryExportItem(id: "framework:\(relativePath)", url: itemURL, relativePath: relativePath, kind: .framework))
            }
            continue
        }

        if !isDirectory && itemURL.pathExtension.lowercased() == "dylib" {
            let relativePath = itemURL.path.hasPrefix(rootPrefix) ? String(itemURL.path.dropFirst(rootPrefix.count)) : itemURL.lastPathComponent
            if seenPaths.insert(relativePath).inserted {
                items.append(AppBinaryExportItem(id: "dylib:\(relativePath)", url: itemURL, relativePath: relativePath, kind: .dylib))
            }
        }
    }

    return items.sorted { lhs, rhs in
        if lhs.kind == rhs.kind {
            return lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
        }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }
}

@MainActor
final class LCAppBannerActions: ObservableObject {
    @Published var appInfo: LCAppInfo
    let model: LCAppModel
    let delegate: LCAppBannerDelegate
    let updateAction: (() -> Void)?

    @Binding var appDataFolders: [String]
    @Binding var tweakFolders: [String]

    // Alerts / sheets state — the owning SwiftUI wrapper (LCAppBanner) attaches
    // .alert/.sheet/.fileExporter modifiers bound to these.
    @Published var appRemovalAlertShow = false
    @Published var appFolderRemovalAlertShow = false
    private var appRemovalContinuation: CheckedContinuation<Bool, Never>?
    private var appFolderRemovalContinuation: CheckedContinuation<Bool, Never>?

    @Published var errorShow = false
    @Published var errorInfo = ""
    @Published var successShow = false
    @Published var successInfo = ""

    @Published var saveIconExporterShow = false
    @Published var saveIconFile: ImageDocument?

    @Published var showBinaryExportSheet = false
    @Published var binaryExportItems: [AppBinaryExportItem] = []
    @Published var selectedBinaryExportItemIDs: Set<String> = []
    @Published var isBinaryExportListLoading = false
    @Published var isExportingBinarySelection = false
    @Published var showCopyToTweaksSheet = false
    @Published var isCopyingSelectionToTweaks = false
    @Published var exportShareItem: AppExportShareItem?
    private var exportShareCleanupURLs: [URL] = []

    @Published var mainColor: Color
    @Published var icon: UIImage

    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    init(model: LCAppModel, delegate: LCAppBannerDelegate, appDataFolders: Binding<[String]>, tweakFolders: Binding<[String]>, updateAction: (() -> Void)? = nil) {
        self.model = model
        self.appInfo = model.appInfo
        self.delegate = delegate
        self.updateAction = updateAction
        _appDataFolders = appDataFolders
        _tweakFolders = tweakFolders
        self.icon = model.appInfo.iconIsDarkIcon(LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon"))
        self.mainColor = Color.clear
        self.mainColor = extractMainHueColor()
    }

    func refreshIconIfNeeded() {
        icon = appInfo.iconIsDarkIcon(darkModeIcon)
        mainColor = extractMainHueColor()
    }

    var locationDisplayText: String {
        if !model.uiSpoofLocationName.isEmpty && model.uiSpoofLocationName != "Unknown Location" {
            return model.uiSpoofLocationName
        } else {
            return String(format: "%.4f, %.4f", model.uiSpoofLatitude, model.uiSpoofLongitude)
        }
    }

    // MARK: - Context Menu

    func makeContextMenu() -> UIMenu {
        var menuChildren: [UIMenuElement] = []

        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { container in
                UIAction(title: container.name,
                         state: container == model.uiSelectedContainer ? .on : .off) { [weak self] _ in
                    self?.model.uiSelectedContainer = container
                }
            }
            let containerMenu = UIMenu(title: "Containers", options: .displayInline, children: containerActions)
            menuChildren.append(containerMenu)
        }

        var sectionChildren: [UIMenuElement] = []

        if !model.uiIsShared, model.uiSelectedContainer != nil {
            let openFolder = UIAction(title: "lc.appBanner.openDataFolder".loc,
                                      image: UIImage(systemName: "folder")) { [weak self] _ in
                self?.openDataFolder()
            }
            sectionChildren.append(openFolder)
        }

        if #available(iOS 16.0, *) {
            let runTitle = model.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc
            let runImage = model.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus"

            let multitaskAction = UIAction(title: runTitle, image: UIImage(systemName: runImage)) { [weak self] _ in
                Task { await self?.runApp(multitask: !(self?.model.shouldLaunchInMultitaskMode ?? false)) }
            }
            sectionChildren.append(multitaskAction)
        }

        let subMenuActions = [
            UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { [weak self] _ in
                self?.copyLaunchUrl()
            },
            UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                Task { await self?.saveIcon() }
            },
            UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { [weak self] _ in
                Task { await self?.openSafariViewToCreateAppClip() }
            }
        ]
        let addToHomeMenu = UIMenu(title: "lc.appBanner.addToHomeScreen".loc,
                                   image: UIImage(systemName: "plus.app"),
                                   children: subMenuActions)
        sectionChildren.append(addToHomeMenu)

        let dataExportDisabled: UIMenuElement.Attributes = model.uiSelectedContainer == nil ? [.disabled] : []
        let exportMenu = UIMenu(
            title: "Export",
            image: UIImage(systemName: "square.and.arrow.up"),
            children: [
                UIAction(title: "Export IPA", image: UIImage(systemName: "shippingbox")) { [weak self] _ in
                    Task { await self?.exportIPA(includeData: false) }
                },
                UIAction(title: "Export Data", image: UIImage(systemName: "folder.fill"), attributes: dataExportDisabled) { [weak self] _ in
                    Task { await self?.exportData() }
                },
                UIAction(title: "Export IPA + Data", image: UIImage(systemName: "square.and.arrow.up.on.square"), attributes: dataExportDisabled) { [weak self] _ in
                    Task { await self?.exportIPA(includeData: true) }
                },
                UIAction(title: "Export Dylibs & Frameworks", image: UIImage(systemName: "list.bullet.rectangle")) { [weak self] _ in
                    self?.openDylibAndFrameworkExportSelection()
                }
            ]
        )
        sectionChildren.append(exportMenu)

        let cloneAction = UIAction(title: "Clone App", image: UIImage(systemName: "square.on.square")) { [weak self] _ in
            Task { await self?.cloneApp() }
        }
        sectionChildren.append(cloneAction)

        let settingsAction = UIAction(title: "lc.tabView.settings".loc, image: UIImage(systemName: "gear")) { [weak self] _ in
            self?.openSettings()
        }
        sectionChildren.append(settingsAction)

        if !model.uiIsShared {
            let uninstallAction = UIAction(title: "lc.appBanner.uninstall".loc,
                                           image: UIImage(systemName: "trash"),
                                           attributes: .destructive) { [weak self] _ in
                Task { await self?.uninstall() }
            }
            sectionChildren.append(uninstallAction)
        }

        let mainSection = UIMenu(title: appInfo.relativeBundlePath ?? "", options: .displayInline, children: sectionChildren)
        menuChildren.append(mainSection)

        return UIMenu(title: "", children: menuChildren)
    }

    // MARK: - Core actions

    func runApp(multitask: Bool? = nil) async {
        if appInfo.isLocked && !DataManager.shared.model.isHiddenAppUnlocked {
            do {
                if !(try await LCUtils.authenticateUser()) {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }

        do {
            try await model.runApp(multitask: multitask)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func openSettings() {
        delegate.openNavigationView(view: AnyView(LCAppSettingsView(model: model, appDataFolders: $appDataFolders, tweakFolders: $tweakFolders)))
    }

    func openDataFolder() {
        guard let folderName = model.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// Presents the uninstall confirmation, then (if there's app data) the
    /// delete-data confirmation, via the SwiftUI alerts bound to
    /// appRemovalAlertShow / appFolderRemovalAlertShow. Call
    /// resolveAppRemovalAlert / resolveAppFolderRemovalAlert from the
    /// alert buttons to unblock these continuations.
    private func presentAppRemovalAlert() async -> Bool {
        await withCheckedContinuation { continuation in
            appRemovalContinuation = continuation
            appRemovalAlertShow = true
        }
    }

    private func presentAppFolderRemovalAlert() async -> Bool {
        await withCheckedContinuation { continuation in
            appFolderRemovalContinuation = continuation
            appFolderRemovalAlertShow = true
        }
    }

    func resolveAppRemovalAlert(_ result: Bool) {
        appRemovalAlertShow = false
        appRemovalContinuation?.resume(returning: result)
        appRemovalContinuation = nil
    }

    func resolveAppFolderRemovalAlert(_ result: Bool) {
        appFolderRemovalAlertShow = false
        appFolderRemovalContinuation?.resume(returning: result)
        appFolderRemovalContinuation = nil
    }

    func uninstall() async {
        do {
            let confirmed = await presentAppRemovalAlert()
            if !confirmed {
                return
            }

            var doRemoveAppFolder = false
            let containers = appInfo.containers
            if !containers.isEmpty {
                doRemoveAppFolder = await presentAppFolderRemovalAlert()
            }

            let fm = FileManager()
            guard let bundlePath = appInfo.bundlePath() else {
                throw "Unable to read app bundle path."
            }
            try fm.removeItem(atPath: bundlePath)
            delegate.removeApp(app: model)
            if doRemoveAppFolder {
                for container in containers {
                    let dataUUID = container.folderName
                    let dataFolderPath = container.containerURL
                    if fm.fileExists(atPath: dataFolderPath.path) {
                        try fm.removeItem(at: dataFolderPath)
                    }
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)

                    DispatchQueue.main.async { [weak self] in
                        self?.appDataFolders.removeAll(where: { $0 == dataUUID })
                    }
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func cloneApp() async {
        do {
            let clonedAppModel = try await createClonedAppModel()
            DispatchQueue.main.async {
                DataManager.shared.model.apps.append(clonedAppModel)
            }
            successInfo = "Cloned app created."
            successShow = true
        } catch {
            errorInfo = "\(error)"
            errorShow = true
        }
    }

    func createClonedAppModel() async throws -> LCAppModel {
        let fm = FileManager.default
        guard let sourceBundlePath = appInfo.bundlePath() else {
            throw "Unable to read app bundle path."
        }

        let sourceBundleURL = URL(fileURLWithPath: sourceBundlePath, isDirectory: true)
        let targetRootURL = model.uiIsShared ? LCPath.lcGroupBundlePath : LCPath.bundlePath
        try fm.createDirectory(at: targetRootURL, withIntermediateDirectories: true)

        let cloneRelativeBundlePath = makeCloneRelativeBundlePath(targetRootURL: targetRootURL, fileManager: fm)
        let destinationBundleURL = targetRootURL.appendingPathComponent(cloneRelativeBundlePath, isDirectory: true)

        do {
            try fm.copyItem(at: sourceBundleURL, to: destinationBundleURL)
        } catch {
            throw "Failed to copy app bundle: \(error.localizedDescription)"
        }

        do {
            try resetClonedAppInfo(at: destinationBundleURL, fileManager: fm)
            guard let clonedAppInfo = LCAppInfo(bundlePath: destinationBundleURL.path) else {
                throw "Failed to initialize cloned app."
            }
            clonedAppInfo.relativeBundlePath = cloneRelativeBundlePath
            clonedAppInfo.isShared = model.uiIsShared
            clonedAppInfo.spoofSDKVersion = true
            clonedAppInfo.installationDate = Date.now
            try await signClonedAppIfNeeded(clonedAppInfo)
            return LCAppModel(appInfo: clonedAppInfo, delegate: model.delegate)
        } catch {
            try? fm.removeItem(at: destinationBundleURL)
            throw error
        }
    }

    private func makeCloneRelativeBundlePath(targetRootURL: URL, fileManager: FileManager) -> String {
        let bundleIdStem = (appInfo.bundleIdentifier() ?? appInfo.displayName() ?? "ClonedApp").sanitizeNonACSII()
        let stem = bundleIdStem.isEmpty ? "ClonedApp" : bundleIdStem
        let timestamp = Int(Date().timeIntervalSince1970)

        var candidate = "\(stem)_\(timestamp).app"
        var index = 2
        while fileManager.fileExists(atPath: targetRootURL.appendingPathComponent(candidate).path) {
            candidate = "\(stem)_\(timestamp)_\(index).app"
            index += 1
        }
        return candidate
    }

    private func resetClonedAppInfo(at clonedBundleURL: URL, fileManager: FileManager) throws {
        let lcAppInfoPath = clonedBundleURL.appendingPathComponent("LCAppInfo.plist")
        if fileManager.fileExists(atPath: lcAppInfoPath.path) {
            try fileManager.removeItem(at: lcAppInfoPath)
        }

        let iconCacheFiles = [
            "LCAppIconLight.png",
            "LCAppIconDark.png",
            "zsign_cache.json",
            "LiveContainer.tmp"
        ]
        for fileName in iconCacheFiles {
            let fileURL = clonedBundleURL.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func signClonedAppIfNeeded(_ clonedAppInfo: LCAppInfo) async throws {
        var signError: String?
        var signSuccess = false
        await withUnsafeContinuation { continuation in
            clonedAppInfo.patchExecAndSignIfNeed(completionHandler: { success, error in
                signSuccess = success
                signError = error
                continuation.resume()
            }, progressHandler: { _ in
            }, forceSign: false)
        }
        if let signError, !signSuccess {
            throw signError.loc
        }
    }

    func copyLaunchUrl() {
        guard let relativeBundlePath = appInfo.relativeBundlePath else {
            return
        }
        if let fn = model.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(fn)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    func openSafariViewToCreateAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle(hasCustomIcon: model.uiCustomIconName != nil) else {
            return
        }

        do {
            guard let profile = appInfo.generateWebClipConfig(withContainerId: model.uiSelectedContainer?.folderName, iconStyle: style) else {
                throw CocoaError(.propertyListWriteInvalid)
            }
            let data = try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
        }
    }

    func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle(hasCustomIcon: model.uiCustomIconName != nil) else {
            return
        }
        guard let img = appInfo.generateLiveContainerWrappedIcon(with: style) else {
            errorInfo = "Failed to generate icon."
            errorShow = true
            return
        }
        self.saveIconFile = ImageDocument(uiImage: img)
        self.saveIconExporterShow = true
    }

    func exportIPA(includeData: Bool) async {
        do {
            let exportURL = try await createExportIPA(includeData: includeData)
            await MainActor.run {
                presentShareSheet(for: exportURL)
            }
        } catch {
            errorInfo = "\(error)"
            errorShow = true
        }
    }

    func exportData() async {
        do {
            let exportURL = try await createDataArchive()
            await MainActor.run {
                presentShareSheet(for: exportURL)
            }
        } catch {
            errorInfo = "\(error)"
            errorShow = true
        }
    }

    func openDylibAndFrameworkExportSelection() {
        guard let bundlePath = appInfo.bundlePath() else {
            errorInfo = "Unable to read app bundle path."
            errorShow = true
            return
        }

        showBinaryExportSheet = true
        isBinaryExportListLoading = true
        binaryExportItems = []
        selectedBinaryExportItemIDs.removeAll()

        Task {
            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try lcListExportableBinaries(bundlePath: bundlePath)
                }.value
                await MainActor.run {
                    binaryExportItems = items
                    selectedBinaryExportItemIDs = Set(items.map(\.id))
                    isBinaryExportListLoading = false
                }
            } catch {
                await MainActor.run {
                    isBinaryExportListLoading = false
                    errorInfo = "\(error)"
                    errorShow = true
                    showBinaryExportSheet = false
                }
            }
        }
    }

    func toggleBinarySelection(for item: AppBinaryExportItem) {
        if selectedBinaryExportItemIDs.contains(item.id) {
            selectedBinaryExportItemIDs.remove(item.id)
        } else {
            selectedBinaryExportItemIDs.insert(item.id)
        }
    }

    func exportSelectedDylibsAndFrameworks() async {
        if isExportingBinarySelection {
            return
        }

        isExportingBinarySelection = true
        defer { isExportingBinarySelection = false }

        do {
            let selectedItems = binaryExportItems.filter { selectedBinaryExportItemIDs.contains($0.id) }
            if selectedItems.isEmpty {
                throw "Select at least one item to export."
            }
            let archiveURL = try await createSelectedBinaryArchive(selectedItems: selectedItems)
            showBinaryExportSheet = false
            try await Task.sleep(nanoseconds: 200_000_000)
            await MainActor.run {
                presentShareSheet(for: archiveURL)
            }
        } catch {
            errorInfo = "\(error)"
            errorShow = true
        }
    }

    func openCopyToTweaksSelection() {
        let selectedItems = binaryExportItems.filter { selectedBinaryExportItemIDs.contains($0.id) }
        if selectedItems.isEmpty {
            errorInfo = "Select at least one item first."
            errorShow = true
            return
        }
        showBinaryExportSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.showCopyToTweaksSheet = true
        }
    }

    func copySelectedToTweaks(destinationFolderURL: URL) async {
        if isCopyingSelectionToTweaks {
            return
        }

        isCopyingSelectionToTweaks = true
        defer { isCopyingSelectionToTweaks = false }

        do {
            let copiedCount = try copySelectedBinaryItems(to: destinationFolderURL)
            showCopyToTweaksSheet = false
            if copiedCount == 0 {
                errorInfo = "No item was copied."
                errorShow = true
                return
            }
            successInfo = "Copied \(copiedCount) item(s) to \(destinationFolderURL.lastPathComponent)."
            successShow = true
        } catch {
            errorInfo = "\(error)"
            errorShow = true
        }
    }

    private func copySelectedBinaryItems(to destinationFolderURL: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationFolderURL, withIntermediateDirectories: true)

        let selectedItems = binaryExportItems.filter { selectedBinaryExportItemIDs.contains($0.id) }
        if selectedItems.isEmpty {
            return 0
        }

        var copiedCount = 0
        for item in selectedItems {
            let proposedURL = destinationFolderURL.appendingPathComponent(item.url.lastPathComponent, isDirectory: item.kind == .framework)
            let destinationURL = nextAvailableCopyURL(for: proposedURL)
            try fm.copyItem(at: item.url, to: destinationURL)
            copiedCount += 1
        }

        return copiedCount
    }

    private func nextAvailableCopyURL(for proposedURL: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: proposedURL.path) {
            return proposedURL
        }

        let pathExtension = proposedURL.pathExtension
        let baseName = proposedURL.deletingPathExtension().lastPathComponent
        let parentURL = proposedURL.deletingLastPathComponent()

        var index = 2
        while true {
            let candidateName: String
            if pathExtension.isEmpty {
                candidateName = "\(baseName)-\(index)"
            } else {
                candidateName = "\(baseName)-\(index).\(pathExtension)"
            }

            let candidateURL = parentURL.appendingPathComponent(candidateName, isDirectory: pathExtension == "framework")
            if !fm.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
        }
    }

    private func createExportIPA(includeData: Bool) async throws -> URL {
        guard let bundlePath = appInfo.bundlePath() else {
            throw "Unable to read app bundle path."
        }

        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCAppExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let payloadDir = stagingRoot.appendingPathComponent("Payload", isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        let sourceAppURL = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let destinationAppURL = payloadDir.appendingPathComponent(sourceAppURL.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: sourceAppURL, to: destinationAppURL)

        if includeData {
            guard let container = model.uiSelectedContainer else {
                throw "Select a container before exporting app data."
            }
            let dataURL = container.containerURL
            let needsSecurityAccess = container.storageBookMark != nil
            if needsSecurityAccess && !dataURL.startAccessingSecurityScopedResource() {
                throw "Unable to access selected external container."
            }
            defer {
                if needsSecurityAccess {
                    dataURL.stopAccessingSecurityScopedResource()
                }
            }
            guard fm.fileExists(atPath: dataURL.path) else {
                throw "Selected container data does not exist."
            }
            let destinationDataURL = destinationAppURL.appendingPathComponent("LCUserData", isDirectory: true)
            try copyContainerDataForExport(from: dataURL, to: destinationDataURL)
        }

        let appName = sanitizedFileStem(appInfo.displayName() ?? "App")
        let fileName = includeData ? "\(appName)-with-data.ipa" : "\(appName).ipa"
        let exportURL = try lcExportArtifactFileURL(fileName: fileName, fileManager: fm)
        try? fm.removeItem(at: exportURL)

        try await zipDirectory(sourceURL: stagingRoot, destinationURL: exportURL)
        return exportURL
    }

    private func createDataArchive() async throws -> URL {
        guard let container = model.uiSelectedContainer else {
            throw "Select a container before exporting data."
        }

        let containerURL = container.containerURL
        let needsSecurityAccess = container.storageBookMark != nil
        if needsSecurityAccess && !containerURL.startAccessingSecurityScopedResource() {
            throw "Unable to access selected external container."
        }
        defer {
            if needsSecurityAccess {
                containerURL.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: containerURL.path) else {
            throw "Selected container data does not exist."
        }
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: containerURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw "Selected container path is not a directory."
        }

        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCDataExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        let appName = sanitizedFileStem(appInfo.displayName() ?? "App")
        let containerName = sanitizedFileStem(container.name)
        let stagedContainerURL = stagingRoot.appendingPathComponent("\(appName)-\(containerName)-data", isDirectory: true)
        try copyContainerDataForExport(from: containerURL, to: stagedContainerURL)

        let exportURL = try lcExportArtifactFileURL(fileName: "\(appName)-\(containerName)-data.zip", fileManager: fm)
        try? fm.removeItem(at: exportURL)

        try await zipDirectory(sourceURL: stagedContainerURL, destinationURL: exportURL)
        return exportURL
    }

    private func createSelectedBinaryArchive(selectedItems: [AppBinaryExportItem]) async throws -> URL {
        guard appInfo.bundlePath() != nil else {
            throw "Unable to read app bundle path."
        }

        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent("LCBinaryExport-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let appName = sanitizedFileStem(appInfo.displayName() ?? "App")
        let contentRoot = stagingRoot.appendingPathComponent("\(appName)-dylibs-frameworks", isDirectory: true)
        try fm.createDirectory(at: contentRoot, withIntermediateDirectories: true)

        for item in selectedItems {
            let destinationURL = contentRoot.appendingPathComponent(item.relativePath, isDirectory: item.kind == .framework)
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destinationURL)
            try fm.copyItem(at: item.url, to: destinationURL)
        }

        let archiveURL = try lcExportArtifactFileURL(fileName: "\(appName)-dylibs-frameworks.zip", fileManager: fm)
        try? fm.removeItem(at: archiveURL)
        try await zipDirectory(sourceURL: contentRoot, destinationURL: archiveURL)
        return archiveURL
    }

    private func zipDirectory(sourceURL: URL, destinationURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?

            coordinator.coordinate(readingItemAt: sourceURL, options: [.forUploading], error: &coordinationError) { zippedURL in
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: zippedURL, to: destinationURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            if let coordinationError {
                continuation.resume(throwing: coordinationError)
            }
        }
    }

    @MainActor
    private func presentShareSheet(for fileURL: URL) {
        if !exportShareCleanupURLs.contains(fileURL) {
            exportShareCleanupURLs.append(fileURL)
        }
        exportShareItem = AppExportShareItem(fileURL: fileURL)
    }

    func cleanupSharedExportFileIfNeeded() {
        if exportShareCleanupURLs.isEmpty {
            return
        }
        let fileURLs = exportShareCleanupURLs
        exportShareCleanupURLs.removeAll()
        let fm = FileManager.default
        for fileURL in fileURLs {
            if fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    private func sanitizedFileStem(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Export" : cleaned
    }

    private func copyContainerDataForExport(from sourceContainerURL: URL, to destinationContainerURL: URL) throws {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceContainerURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw "Selected container path is not a directory."
        }

        try copyDirectoryForExport(from: sourceContainerURL, to: destinationContainerURL)
    }

    private func copyDirectoryForExport(from sourceDirectoryURL: URL, to destinationDirectoryURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        let items = try fm.contentsOfDirectory(
            at: sourceDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey],
            options: []
        )

        for itemURL in items {
            let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceTypeKey])
            if shouldSkipDataExportItem(values: values) {
                continue
            }

            let destinationItemURL = destinationDirectoryURL.appendingPathComponent(itemURL.lastPathComponent, isDirectory: values.isDirectory ?? false)
            if values.isDirectory == true {
                try copyDirectoryForExport(from: itemURL, to: destinationItemURL)
                continue
            }

            do {
                try fm.copyItem(at: itemURL, to: destinationItemURL)
            } catch {
                if shouldIgnoreDataExportCopyError(error, resourceValues: values) {
                    continue
                }
                throw error
            }
        }
    }

    private func shouldSkipDataExportItem(values: URLResourceValues) -> Bool {
        if values.isSymbolicLink == true {
            return true
        }
        if let resourceType = values.fileResourceType {
            switch resourceType {
            case .socket, .characterSpecial, .blockSpecial, .namedPipe, .unknown:
                return true
            default:
                break
            }
        }
        return false
    }

    private func shouldIgnoreDataExportCopyError(_ error: Error, resourceValues: URLResourceValues) -> Bool {
        if shouldSkipDataExportItem(values: resourceValues) {
            return true
        }
        let nsError = error as NSError
        if !isNoSuchFileError(nsError) {
            if nsError.domain == NSPOSIXErrorDomain {
                switch nsError.code {
                case Int(POSIXErrorCode.EINVAL.rawValue),
                     Int(POSIXErrorCode.EPERM.rawValue),
                     Int(POSIXErrorCode.ENOTSUP.rawValue),
                     Int(POSIXErrorCode.EOPNOTSUPP.rawValue):
                    return true
                default:
                    break
                }
            }
            return false
        }
        if resourceValues.isSymbolicLink == true {
            return true
        }
        if let resourceType = resourceValues.fileResourceType {
            return resourceType == .socket || resourceType == .namedPipe
        }
        return false
    }

    private func isNoSuchFileError(_ nsError: NSError) -> Bool {
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == ENOENT
        }
        return false
    }

    func extractMainHueColor() -> Color {
        if !darkModeIcon, let cachedColor = appInfo.cachedColor {
            return Color(uiColor: cachedColor)
        } else if darkModeIcon, let cachedColor = appInfo.cachedColorDark {
            return Color(uiColor: cachedColor)
        }

        guard let cgImage = appInfo.iconIsDarkIcon(darkModeIcon).cgImage else { return Color.clear }

        let width = 1
        let height = 1
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixelData = [UInt8](repeating: 0, count: 4)

        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            return Color.clear
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let red = CGFloat(pixelData[0]) / 255.0
        let green = CGFloat(pixelData[1]) / 255.0
        let blue = CGFloat(pixelData[2]) / 255.0

        let averageColor = UIColor(red: red, green: green, blue: blue, alpha: 1.0)

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        averageColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        if brightness < 0.1 && saturation < 0.1 {
            return Color.red
        }

        if brightness < 0.3 {
            brightness = 0.3
        }

        let ans = Color(hue: hue, saturation: saturation, brightness: brightness)
        if darkModeIcon {
            appInfo.cachedColorDark = UIColor(ans)
        } else {
            appInfo.cachedColor = UIColor(ans)
        }

        return ans
    }

    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
}
