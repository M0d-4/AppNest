//
//  LCTweakManagementView.swift
//  LiveContainerSwiftUI
//
//  Fork-only tweak management workflow. Keep this separate from the upstream
//  LCTweakFolderView so upstream tweak-screen changes remain easy to merge.

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private extension Notification.Name {
    static let lcTweakManagementDidChange = Notification.Name("LC.TweakManagementDidChange")
}

private enum LCTweakTransferOperation {
    case copy
    case move
}

private struct LCTweakTransferRequest: Identifiable {
    let id = UUID()
    let sourceURL: URL
    let operation: LCTweakTransferOperation
}

private struct LCTweakDestinationMode {
    let onClose: () -> Void
    let onSelect: (URL) -> Void
}

private final class LCTweakManagementContext: ObservableObject {
    @Published var draggingItemURL: URL?

    func beginDrag(_ url: URL) {
        draggingItemURL = url
    }

    func clearDrag() {
        draggingItemURL = nil
    }
}

private struct LCManagedTweakItem: Hashable {
    let fileURL: URL
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool
    let isEnabled: Bool

    var displayName: String {
        let name = fileURL.lastPathComponent
        return isEnabled ? name : String(name.dropLast(Self.disabledSuffix.count))
    }

    static let disabledSuffix = ".disabled"
}

private struct LCManagedTweakFolderView: View {
    @State private var baseURL: URL
    @State private var tweakItems: [LCManagedTweakItem]
    private let isRoot: Bool
    private let destinationMode: LCTweakDestinationMode?

    @EnvironmentObject private var sharedModel: SharedModel
    @EnvironmentObject private var managementContext: LCTweakManagementContext

    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var choosingTweak = false
    @State private var isTweakSigning = false
    @State private var transferRequest: LCTweakTransferRequest?

    @StateObject private var newFolderInput = InputHelper()
    @StateObject private var renameFileInput = InputHelper()

    init(baseURL: URL, isRoot: Bool, destinationMode: LCTweakDestinationMode? = nil) {
        _baseURL = State(initialValue: baseURL)
        _tweakItems = State(initialValue: Self.loadTweakItems(baseURL))
        self.isRoot = isRoot
        self.destinationMode = destinationMode
    }

    private var isDestinationMode: Bool {
        destinationMode != nil
    }

    var body: some View {
        List {
            Section {
                ForEach(tweakItems, id: \.self) { tweakItem in
                    row(for: tweakItem)
                }
                .onDelete(perform: deleteTweakItems)
            } footer: {
                Text(isRoot ? "lc.tweakView.globalFolderDesc".loc : "lc.tweakView.appFolderDesc".loc)
                    .foregroundStyle(.gray)
                    .font(.system(size: 12))
            }
        }
        .onAppear {
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lcTweakManagementDidChange)) { _ in
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
        }
        .navigationTitle(isRoot ? "lc.tabView.tweaks".loc : baseURL.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if let destinationMode, isRoot {
                    Button("lc.common.close".loc, action: destinationMode.onClose)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if let destinationMode {
                    Button("Select Here") {
                        destinationMode.onSelect(baseURL)
                    }
                } else if !isTweakSigning && LCSharedUtils.certificatePassword() != nil {
                    Button {
                        Task { await signAllTweaks() }
                    } label: {
                        Label("sign".loc, systemImage: "signature")
                    }
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if !isDestinationMode {
                    if !isTweakSigning {
                        Menu {
                            Button {
                                choosingTweak = true
                            } label: {
                                Label("lc.tweakView.importTweak".loc, systemImage: "square.and.arrow.down")
                            }

                            Button {
                                Task { await createNewFolder() }
                            } label: {
                                Label("lc.tweakView.newFolder".loc, systemImage: "folder.badge.plus")
                            }
                        } label: {
                            Label("add", systemImage: "plus")
                        }
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
            }
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc) {}
        } message: {
            Text(errorInfo)
        }
        .textFieldAlert(
            isPresented: $newFolderInput.show,
            title: "lc.common.enterNewFolderName".loc,
            text: $newFolderInput.initVal,
            placeholder: "",
            action: { newText in
                newFolderInput.close(result: newText)
            },
            actionCancel: { _ in
                newFolderInput.close(result: "")
            }
        )
        .textFieldAlert(
            isPresented: $renameFileInput.show,
            title: "lc.common.enterNewName".loc,
            text: $renameFileInput.initVal,
            placeholder: "",
            action: { newText in
                renameFileInput.close(result: newText)
            },
            actionCancel: { _ in
                renameFileInput.close(result: "")
            }
        )
        .betterFileImporter(
            isPresented: $choosingTweak,
            types: [.dylib, .lcFramework],
            multiple: true,
            callback: { urls in
                Task { await installTweaks(urls) }
            },
            onDismiss: {
                choosingTweak = false
            }
        )
        .sheet(item: $transferRequest) { request in
            LCTweakDestinationView(
                onClose: {
                    transferRequest = nil
                },
                onSelect: { destinationURL in
                    performTransfer(request: request, destinationURL: destinationURL)
                }
            )
        }
    }

    @ViewBuilder
    private func row(for tweakItem: LCManagedTweakItem) -> some View {
        HStack {
            Group {
                if tweakItem.isFolder && !tweakItem.isFramework {
                    ZStack {
                        NavigationLink {
                            LCManagedTweakFolderView(
                                baseURL: tweakItem.fileURL,
                                isRoot: false,
                                destinationMode: destinationMode
                            )
                            .environmentObject(managementContext)
                        } label: {
                            EmptyView()
                        }
                        .opacity(0)

                        HStack {
                            Label(tweakItem.displayName, systemImage: "folder.fill")
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                } else if tweakItem.isFramework {
                    Label(tweakItem.displayName, systemImage: "shippingbox.fill")
                    Spacer()
                } else if tweakItem.isTweak {
                    Label(tweakItem.displayName, systemImage: "building.columns.fill")
                    Spacer()
                } else {
                    Label(tweakItem.displayName, systemImage: "document.fill")
                    Spacer()
                }
            }
            .opacity(tweakItem.isEnabled ? 1 : 0.4)

            if !isDestinationMode && tweakItem.displayName != "TweakLoader.dylib" {
                Toggle("", isOn: Binding(
                    get: { tweakItem.isEnabled },
                    set: { setTweakEnabled(tweakItem, enabled: $0) }
                ))
                .labelsHidden()
            }
        }
        .onDrag {
            managementContext.beginDrag(tweakItem.fileURL)
            return NSItemProvider(object: tweakItem.fileURL.path as NSString)
        }
        .onDrop(of: [.text], isTargeted: nil) { _ in
            dropDraggedItem(into: tweakItem)
        }
        .contextMenu {
            if !isDestinationMode {
                Button {
                    transferRequest = LCTweakTransferRequest(sourceURL: tweakItem.fileURL, operation: .copy)
                } label: {
                    Label("Copy to...", systemImage: "doc.on.doc")
                }

                Button {
                    transferRequest = LCTweakTransferRequest(sourceURL: tweakItem.fileURL, operation: .move)
                } label: {
                    Label("lc.common.move".loc, systemImage: "folder")
                }
            }

            Button {
                Task { await renameTweakItem(tweakItem) }
            } label: {
                Label("lc.common.rename".loc, systemImage: "pencil")
            }

            Button(role: .destructive) {
                deleteTweakItem(tweakItem)
            } label: {
                Label("lc.common.delete".loc, systemImage: "trash")
            }
        }
    }

    private func dropDraggedItem(into tweakItem: LCManagedTweakItem) -> Bool {
        guard tweakItem.isFolder || tweakItem.isFramework,
              let sourceURL = managementContext.draggingItemURL else {
            return false
        }
        managementContext.clearDrag()
        moveTweakItem(from: sourceURL, toFolder: tweakItem.fileURL)
        return true
    }

    private func performTransfer(request: LCTweakTransferRequest, destinationURL: URL) {
        transferRequest = nil

        if request.operation == .move {
            moveTweakItem(from: request.sourceURL, toFolder: destinationURL)
        } else {
            copyTweakItem(from: request.sourceURL, toFolder: destinationURL)
        }
    }

    private func setTweakEnabled(_ tweakItem: LCManagedTweakItem, enabled: Bool) {
        guard tweakItem.isEnabled != enabled else {
            return
        }

        let newName = enabled ? tweakItem.displayName : tweakItem.displayName + LCManagedTweakItem.disabledSuffix
        let newURL = baseURL.appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: tweakItem.fileURL, to: newURL)
            reloadTweakItems()
            postChange()
        } catch {
            show(error)
        }
    }

    private func deleteTweakItems(at offsets: IndexSet) {
        do {
            for index in offsets {
                try FileManager.default.removeItem(at: tweakItems[index].fileURL)
            }
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
            postChange()
        } catch {
            show(error)
        }
    }

    private func deleteTweakItem(_ tweakItem: LCManagedTweakItem) {
        do {
            try FileManager.default.removeItem(at: tweakItem.fileURL)
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
            postChange()
        } catch {
            show(error)
        }
    }

    private func renameTweakItem(_ tweakItem: LCManagedTweakItem) async {
        guard let newName = await renameFileInput.open(initVal: tweakItem.displayName), !newName.isEmpty else {
            return
        }

        let newFileName = tweakItem.isEnabled ? newName : newName + LCManagedTweakItem.disabledSuffix
        let newURL = baseURL.appendingPathComponent(newFileName)
        do {
            try FileManager.default.moveItem(at: tweakItem.fileURL, to: newURL)
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
            postChange()
        } catch {
            show(error)
        }
    }

    private func createNewFolder() async {
        guard let name = await newFolderInput.open(), !name.isEmpty else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: baseURL.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: false
            )
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
            postChange()
        } catch {
            show(error)
        }
    }

    private func installTweaks(_ urls: [URL]) async {
        do {
            let fm = FileManager.default
            for url in urls {
                guard url.isFileURL else {
                    throw "lc.tweakView.notFileError %@".localizeWithFormat(url.lastPathComponent)
                }
                let destinationURL = baseURL.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: destinationURL)
                if destinationURL.pathExtension.lowercased() == "dylib" {
                    LCParseMachO((destinationURL.path as NSString).utf8String, false) { path, header, _, _ in
                        LCPatchAddRPath(path, header)
                    }
                }
            }
            reloadTweakItems()
            postChange()
        } catch {
            show(error)
        }
    }

    private func signAllTweaks() async {
        do {
            try await LCUtils.signTweaks(tweakFolderUrl: baseURL, force: true) { _ in
                isTweakSigning = true
            }
        } catch {
            show(error)
        }
        isTweakSigning = false
    }

    private func moveTweakItem(from sourceURL: URL, toFolder destinationFolderURL: URL) {
        let sourceFolderURL = sourceURL.deletingLastPathComponent()
        guard sourceFolderURL != destinationFolderURL else {
            return
        }
        guard sourceURL != destinationFolderURL,
              !destinationFolderURL.path.hasPrefix(sourceURL.path + "/") else {
            show("lc.tweakView.error.cannotMoveIntoSelf".loc)
            return
        }

        let destinationURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            show("lc.tweakView.error.destinationExists %@".localizeWithFormat(sourceURL.lastPathComponent))
            return
        }

        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            postChange()
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
        } catch {
            show(error)
        }
    }

    private func copyTweakItem(from sourceURL: URL, toFolder destinationFolderURL: URL) {
        guard sourceURL != destinationFolderURL,
              !destinationFolderURL.path.hasPrefix(sourceURL.path + "/") else {
            show("lc.tweakView.error.cannotMoveIntoSelf".loc)
            return
        }

        let proposedURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        let destinationURL = nextAvailableCopyURL(for: proposedURL)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            postChange()
            reloadTweakItems()
        } catch {
            show(error)
        }
    }

    private func nextAvailableCopyURL(for proposedURL: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: proposedURL.path) else {
            return proposedURL
        }

        let ext = proposedURL.pathExtension
        let base = proposedURL.deletingPathExtension().lastPathComponent
        let parent = proposedURL.deletingLastPathComponent()
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            let candidate = parent.appendingPathComponent(name, isDirectory: ext.lowercased() == "framework")
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func reloadTweakItems() {
        tweakItems = Self.loadTweakItems(baseURL)
    }

    private static func loadTweakItems(_ folderURL: URL) -> [LCManagedTweakItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folderURL.path) else {
            return []
        }

        return names.compactMap { name in
            guard name != "TweakInfo.plist" else {
                return nil
            }
            let fileURL = folderURL.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                return nil
            }
            let isEnabled = !name.hasSuffix(LCManagedTweakItem.disabledSuffix)
            let baseName = isEnabled ? name : String(name.dropLast(LCManagedTweakItem.disabledSuffix.count))
            return LCManagedTweakItem(
                fileURL: fileURL,
                isFolder: isDirectory.boolValue,
                isFramework: isDirectory.boolValue && baseName.hasSuffix(".framework"),
                isTweak: !isDirectory.boolValue && baseName.hasSuffix(".dylib"),
                isEnabled: isEnabled
            )
        }
        .sorted {
            if $0.isFolder != $1.isFolder {
                return $0.isFolder && !$1.isFolder
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func syncRootTweakFoldersIfNeeded() {
        guard isRoot else {
            return
        }
        let folders = Self.loadTweakItems(LCPath.tweakPath)
            .filter { $0.isFolder && !$0.isFramework && $0.displayName != "TweakLoader.dylib" }
            .map(\.displayName)
        if sharedModel.tweakFolderNames != folders {
            sharedModel.tweakFolderNames = folders
        }
    }

    private func postChange() {
        NotificationCenter.default.post(name: .lcTweakManagementDidChange, object: nil)
    }

    private func show(_ error: Error) {
        show(error.localizedDescription)
    }

    private func show(_ message: String) {
        errorInfo = message
        errorShow = true
    }
}

private struct LCTweakDestinationView: View {
    let onClose: () -> Void
    let onSelect: (URL) -> Void
    @StateObject private var managementContext = LCTweakManagementContext()

    var body: some View {
        NavigationView {
            LCManagedTweakFolderView(
                baseURL: LCPath.tweakPath,
                isRoot: true,
                destinationMode: LCTweakDestinationMode(onClose: onClose, onSelect: onSelect)
            )
            .environmentObject(managementContext)
        }
        .navigationViewStyle(.stack)
    }
}

// Renamed from LCTweaksCopyDestinationView to avoid colliding with the
// existing LCTweaksCopyDestinationView in LCTweaksView.swift, which the
// current app-export/binary-export-to-tweaks flow (LCAppBannerActions)
// already depends on.
struct LCTweakManagementCopyDestinationView: View {
    let onClose: () -> Void
    let onCopyHere: (URL) -> Void

    var body: some View {
        LCTweakDestinationView(onClose: onClose, onSelect: onCopyHere)
    }
}

struct LCTweakManagementRootView: View {
    @StateObject private var managementContext = LCTweakManagementContext()

    var body: some View {
        LCManagedTweakFolderView(baseURL: LCPath.tweakPath, isRoot: true)
            .environmentObject(managementContext)
    }
}
