//
//  LCTweaksView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let lcDisabledTweaksKey = "disabledItems"

final class LCTweakMoveContext: ObservableObject {
    @Published var draggingItemURL: URL?
    @Published var pendingMoveItemURL: URL?

    func beginDrag(_ url: URL) {
        draggingItemURL = url
    }

    func clearDrag() {
        draggingItemURL = nil
    }

    func beginMove(_ url: URL) {
        pendingMoveItemURL = url
    }

    func clearMove() {
        pendingMoveItemURL = nil
    }
}

private struct LCPackageMetadata: Codable {
    let packageID: String
    let version: String
    let architecture: String?
    let name: String?
    let depends: String?
    let sourceFilename: String
    let importedAt: String
    let loadableArtifacts: [String]
    let routesDetected: [String]
    let needsSigning: Bool
}

private struct LCControlInfo {
    let packageID: String
    let version: String
    let architecture: String?
    let name: String?
    let depends: String?
}

struct LCTweakItem : Hashable {
    let fileUrl: URL
    let isFolder: Bool
    let isFramework: Bool
    let isTweak: Bool
    let isPackage: Bool
    let needsSigning: Bool

    var supportsDisableToggle: Bool {
        // TweakLoader.dylib is the injector itself — disabling it would be
        // nonsensical (it's what makes tweak loading, including reading this
        // very disabled-list, work at all), so it never gets the toggle.
        (isFramework || isTweak) && fileUrl.lastPathComponent != "TweakLoader.dylib"
    }
}

struct LCTweakCopyMode {
    let onClose: () -> Void
    let onCopyHere: (URL) -> Void
}

struct LCTweakHelpView: View {
    @Binding var isPresent: Bool

    var body: some View {
        NavigationView {
            Form {
                Section("lc.tabView.tweaks".loc) {
                    Text("lc.tweakView.helpText1".loc)
                    Text("lc.tweakView.helpText2".loc)
                    Text("lc.tweakView.helpText3".loc)
                    Text("lc.tweakView.helpText4".loc)
                    Text("lc.tweakView.helpText5".loc)
                    Text("lc.tweakView.helpText6".loc)
                }
            }
            .navigationTitle("lc.tweakView.helpTitle".loc)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.common.done".loc) {
                        isPresent = false
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct LCTweakFolderView : View {
    @State var baseUrl : URL
    @State var tweakItems : [LCTweakItem]
    private var isRoot : Bool
    private let copyMode: LCTweakCopyMode?
    @Binding var tweakFolders : [String]
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    
    @StateObject private var newFolderInput = InputHelper()
    
    @StateObject private var renameFileInput = InputHelper()
    
    @State private var choosingTweak = false
    @StateObject private var installUrlInput = InputHelper()
    @ObservedObject var downloadHelper = DownloadHelper()
    
    @State private var isTweakSigning = false
    @State private var isInstallingFromURL = false
    @State private var helpPresent = false
    @State private var disabledTweaks: Set<String>
    @State private var isolatedManagementPresent = false
    
    @EnvironmentObject private var moveContext: LCTweakMoveContext

    private var isCopyMode: Bool {
        copyMode != nil
    }

    init(baseUrl: URL, isRoot: Bool = false, tweakFolders: Binding<[String]>, copyMode: LCTweakCopyMode? = nil) {
        _baseUrl = State(initialValue: baseUrl)
        self.isRoot = isRoot
        self.copyMode = copyMode
        _tweakFolders = tweakFolders
        _tweakItems = State(initialValue: LCTweakFolderView.loadTweakItems(baseUrl))
        _disabledTweaks = State(initialValue: LCTweakFolderView.loadDisabledTweaks(baseUrl))
    }
    
    var body: some View {
        List {
            if moveContext.pendingMoveItemURL != nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("lc.tweakView.moveMode %@".localizeWithFormat(moveContext.pendingMoveItemURL?.lastPathComponent ?? ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("lc.tweakView.moveHere".loc) {
                                movePendingItemHere()
                            }
                            .buttonStyle(.borderedProminent)
                            Button("lc.common.cancel".loc) {
                                moveContext.clearMove()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            Section {
                if isCopyMode {
                    ForEach(tweakItems, id:\.self) { tweakItem in
                        rowView(for: tweakItem)
                    }
                } else {
                    ForEach(tweakItems, id:\.self) { tweakItem in
                        rowView(for: tweakItem)
                            .contentShape(Rectangle())
                            .highPriorityGesture(TapGesture(count: 2).onEnded {
                                toggleTweakDisabled(tweakItem)
                            })
                            .onDrag {
                                moveContext.beginDrag(tweakItem.fileUrl)
                                return NSItemProvider(object: tweakItem.fileUrl.path as NSString)
                            }
                            .onDrop(of: [.text], isTargeted: nil) { _ in
                                dropDraggedItem(into: tweakItem)
                            }
                        .contextMenu {
                            Button {
                                Task { await renameTweakItem(tweakItem: tweakItem)}
                            } label: {
                                Label("lc.common.rename".loc, systemImage: "pencil")
                            }

                            if tweakItem.supportsDisableToggle {
                                Button {
                                    toggleTweakDisabled(tweakItem)
                                } label: {
                                    if isTweakDisabled(tweakItem) {
                                        Label("lc.tweakView.enable".loc, systemImage: "checkmark.circle")
                                    } else {
                                        Label("lc.tweakView.disable".loc, systemImage: "nosign")
                                    }
                                }
                            }

                            if tweakItem.isFolder && tweakItem.isPackage && tweakItem.needsSigning {
                                Button {
                                    Task { await signPackage(tweakItem: tweakItem) }
                                } label: {
                                    Label("lc.tweakView.signPackage".loc, systemImage: "signature")
                                }
                            }

                            Button {
                                moveContext.beginMove(tweakItem.fileUrl)
                            } label: {
                                Label("lc.common.move".loc, systemImage: "folder")
                            }
                            
                            Button(role: .destructive) {
                                deleteTweakItem(tweakItem: tweakItem)
                            } label: {
                                Label("lc.common.delete".loc, systemImage: "trash")
                            }
                        }

                    }.onDelete { indexSet in
                        deleteTweakItem(indexSet: indexSet)
                    }
                }
            } footer: {
                if isRoot {
                    Text("lc.tweakView.globalFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                } else {
                    Text("lc.tweakView.appFolderDesc".loc)
                        .foregroundStyle(.gray)
                        .font(.system(size: 12))
                }
            }
        }
        .onAppear {
            reloadTweakItems()
            disabledTweaks = Self.loadDisabledTweaks(baseUrl)
            syncRootTweakFoldersIfNeeded()
        }
        .navigationTitle(isRoot ? "lc.tabView.tweaks".loc : baseUrl.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isCopyMode {
                    if isRoot, let copyMode {
                        Button("lc.common.close".loc) {
                            copyMode.onClose()
                        }
                    } else {
                        EmptyView()
                    }
                } else {
                    Button("lc.tweakView.helpButton".loc, systemImage: "questionmark") {
                        helpPresent = true
                    }
                }
            }
            if isRoot && !isCopyMode {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Isolated Tweaks", systemImage: "folder.badge.gearshape") {
                        isolatedManagementPresent = true
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let copyMode {
                    Button("Copy Here") {
                        copyMode.onCopyHere(baseUrl)
                    }
                } else if !isTweakSigning && LCSharedUtils.certificatePassword() != nil {
                    Button {
                        Task { await signAllTweaks() }
                    } label: {
                        Label("sign".loc, systemImage: "signature")
                    }
                } else {
                    EmptyView()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !isCopyMode {
                    if !isTweakSigning && !isInstallingFromURL {
                        Menu {
                            Button {
                                if choosingTweak {
                                    choosingTweak = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                                        choosingTweak = true
                                    })
                                } else {
                                    choosingTweak = true
                                }
                            } label: {
                                Label("lc.tweakView.importTweak".loc, systemImage: "square.and.arrow.down")
                            }

                            Button {
                                Task { await startInstallFromUrl() }
                            } label: {
                                Label("lc.appList.installFromUrl".loc, systemImage: "link.badge.plus")
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
                } else {
                    EmptyView()
                }
            }
        }
        .sheet(isPresented: $helpPresent) {
            LCTweakHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $isolatedManagementPresent) {
            LCTweakManagementRootView()
        }
        .alert("lc.common.error".loc, isPresented: $errorShow) {
            Button("lc.common.ok".loc, action: {
            })
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
            actionCancel: {_ in
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
            actionCancel: {_ in
                renameFileInput.close(result: "")
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .betterFileImporter(isPresented: $choosingTweak, types: [.dylib, .lcFramework, .zipArchive, .deb], multiple: true, callback: { fileUrls in
            Task { await importSelectedTweaks(fileUrls) }
        }, onDismiss: {
            choosingTweak = false
        })
        .downloadAlert(helper: downloadHelper)
    }

    @ViewBuilder
    private func rowView(for tweakItem: LCTweakItem) -> some View {
        HStack {
            if tweakItem.isFolder || tweakItem.isFramework {
                // hidden NavigationLink so the row still navigates without the toggle triggering it
                ZStack(alignment: .leading) {
                    NavigationLink {
                        LCTweakFolderView(baseUrl: tweakItem.fileUrl, isRoot: false, tweakFolders: $tweakFolders, copyMode: copyMode)
                            .environmentObject(moveContext)
                    } label: {
                        EmptyView()
                    }
                    .opacity(0)
                    tweakItemLabel(tweakItem)
                }
            } else {
                tweakItemLabel(tweakItem)
            }
            Spacer()
            if tweakItem.supportsDisableToggle {
                Toggle("", isOn: Binding(
                    get: { !isTweakDisabled(tweakItem) },
                    set: { _ in toggleTweakDisabled(tweakItem) }
                ))
                .labelsHidden()
            }
        }
        .contentShape(Rectangle())
    }

    private func tweakItemLabel(_ tweakItem: LCTweakItem) -> some View {
        Label {
            Text(tweakItem.fileUrl.lastPathComponent)
                .lineLimit(1)
        } icon: {
            Image(systemName: iconName(for: tweakItem))
                .frame(width: 20, height: 20)
        }
        .opacity(tweakItem.supportsDisableToggle && isTweakDisabled(tweakItem) ? 0.4 : 1)
    }

    private func iconName(for tweakItem: LCTweakItem) -> String {
        if tweakItem.isFramework {
            return "shippingbox.fill"
        }
        if tweakItem.isFolder {
            return "folder.fill"
        }
        if tweakItem.isTweak {
            return "building.columns.fill"
        }
        return "document.fill"
    }

    private func isTweakDisabled(_ tweakItem: LCTweakItem) -> Bool {
        disabledTweaks.contains(tweakItem.fileUrl.lastPathComponent)
    }

    private func dropDraggedItem(into tweakItem: LCTweakItem) -> Bool {
        guard tweakItem.isFolder || tweakItem.isFramework else {
            return false
        }
        guard let dragURL = moveContext.draggingItemURL else {
            return false
        }
        moveContext.clearDrag()
        moveTweakItem(from: dragURL, toFolder: tweakItem.fileUrl)
        return true
    }
    
    func deleteTweakItem(indexSet: IndexSet) {
        var indexToRemove : [Int] = []
        let fm = FileManager()
        do {
            for i in indexSet {
                let tweakItem = tweakItems[i]
                try fm.removeItem(at: tweakItem.fileUrl)
                if tweakItem.supportsDisableToggle {
                    disabledTweaks.remove(tweakItem.fileUrl.lastPathComponent)
                }
                indexToRemove.append(i)
            }
            try persistDisabledTweaks()
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        if isRoot {
            for iToRemove in indexToRemove {
                tweakFolders.removeAll(where: { s in
                    return s == tweakItems[iToRemove].fileUrl.lastPathComponent
                })
            }
        }

        tweakItems.remove(atOffsets: IndexSet(indexToRemove))
    }
    
    func deleteTweakItem(tweakItem: LCTweakItem) {
        var indexToRemove : Int?
        let fm = FileManager()
        do {

            try fm.removeItem(at: tweakItem.fileUrl)
            indexToRemove = tweakItems.firstIndex(where: { s in
                return s == tweakItem
            })
            if tweakItem.supportsDisableToggle {
                disabledTweaks.remove(tweakItem.fileUrl.lastPathComponent)
                try persistDisabledTweaks()
            }
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        
        guard let indexToRemove = indexToRemove else {
            return
        }
        tweakItems.remove(at: indexToRemove)
        if isRoot {
            tweakFolders.removeAll(where: { s in
                return s == tweakItem.fileUrl.lastPathComponent
            })
        }
    }
    
    func renameTweakItem(tweakItem: LCTweakItem) async {
        guard let newName = await renameFileInput.open(initVal: tweakItem.fileUrl.lastPathComponent), newName != "" else {
            return
        }
        
        let indexToRename = tweakItems.firstIndex(where: { s in
            return s == tweakItem
        })
        guard let indexToRename = indexToRename else {
            return
        }
        let newUrl = self.baseUrl.appendingPathComponent(newName)
        
        let fm = FileManager()
        do {
            try fm.moveItem(at: tweakItem.fileUrl, to: newUrl)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        if tweakItem.supportsDisableToggle, disabledTweaks.contains(tweakItem.fileUrl.lastPathComponent) {
            disabledTweaks.remove(tweakItem.fileUrl.lastPathComponent)
            disabledTweaks.insert(newUrl.lastPathComponent)
            do {
                try persistDisabledTweaks()
            } catch {
                errorShow = true
                errorInfo = error.localizedDescription
                return
            }
        }
        tweakItems.remove(at: indexToRename)
        let newTweakItem = LCTweakItem(
            fileUrl: newUrl,
            isFolder: tweakItem.isFolder,
            isFramework: tweakItem.isFramework,
            isTweak: tweakItem.isTweak,
            isPackage: tweakItem.isPackage,
            needsSigning: tweakItem.needsSigning
        )
        tweakItems.insert(newTweakItem, at: indexToRename)

        if isRoot {
            let indexToRename2 = tweakFolders.firstIndex(of: tweakItem.fileUrl.lastPathComponent)
            guard let indexToRename2 = indexToRename2 else {
                return
            }
            tweakFolders.remove(at: indexToRename2)
            tweakFolders.insert(newName, at: indexToRename2)
            
        }
    }
    
    func signAllTweaks() async {
        do {
            defer {
                isTweakSigning = false
            }
            
            try await LCUtils.signTweaks(tweakFolderUrl: self.baseUrl, force: true) { p in
                isTweakSigning = true
            }

        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }

    func signPackage(tweakItem: LCTweakItem) async {
        let fm = FileManager()
        guard fm.fileExists(atPath: tweakItem.fileUrl.path) else {
            errorInfo = "lc.tweakView.packageNotFound %@".localizeWithFormat(tweakItem.fileUrl.lastPathComponent)
            errorShow = true
            return
        }
        guard LCSharedUtils.certificatePassword() != nil else {
            errorInfo = "lc.tweakView.noCertificateError".loc
            errorShow = true
            return
        }
        do {
            isTweakSigning = true
            try await LCUtils.signTweaks(tweakFolderUrl: tweakItem.fileUrl, force: false) { _ in }
            isTweakSigning = false

            // update metadata
            let metaURL = tweakItem.fileUrl.appendingPathComponent(".lc-package.json")
            if let data = try? Data(contentsOf: metaURL),
               var dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String:Any] {
                dict["needsSigning"] = false
                if let newData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                    try newData.write(to: metaURL, options: .atomic)
                }
            }

            if let idx = tweakItems.firstIndex(where: { $0.fileUrl.path == tweakItem.fileUrl.path }) {
                tweakItems[idx] = LCTweakItem(
                    fileUrl: tweakItems[idx].fileUrl,
                    isFolder: tweakItems[idx].isFolder,
                    isFramework: tweakItems[idx].isFramework,
                    isTweak: tweakItems[idx].isTweak,
                    isPackage: tweakItems[idx].isPackage,
                    needsSigning: false
                )
            }
        } catch {
            isTweakSigning = false
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func createNewFolder() async {
        guard let newName = await renameFileInput.open(), newName != "" else {
            return
        }
        let fm = FileManager()
        let dest = baseUrl.appendingPathComponent(newName)
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            return
        }
        tweakItems.append(LCTweakItem(fileUrl: dest, isFolder: true, isFramework: false, isTweak: false, isPackage: false, needsSigning: false))
        if isRoot {
            tweakFolders.append(newName)
        }
    }

    func importSelectedTweaks(_ urls: [URL]) async {
        do {
            let fm = FileManager.default
            for fileUrl in urls {
                if !fileUrl.isFileURL {
                    throw "lc.tweakView.notFileError %@".localizeWithFormat(fileUrl.lastPathComponent)
                }

                var didStartAccess = false
                if !fm.isReadableFile(atPath: fileUrl.path) {
                    didStartAccess = fileUrl.startAccessingSecurityScopedResource()
                    if !didStartAccess {
                        throw "lc.appList.ipaAccessError".loc
                    }
                }
                defer {
                    if didStartAccess {
                        fileUrl.stopAccessingSecurityScopedResource()
                    }
                }

                try await installDownloadedTweakArtifact(fileUrl)
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func startInstallTweak(_ urls: [URL]) async {
        do {
            let fm = FileManager()
            var installErrors: [String] = []
            for fileUrl in urls {
                if !fileUrl.isFileURL {
                    installErrors.append("lc.tweakView.notFileError %@".localizeWithFormat(fileUrl.lastPathComponent))
                    continue
                }
                let toPath = self.baseUrl.appendingPathComponent(fileUrl.lastPathComponent)
                try fm.moveItem(at: fileUrl, to: toPath)

                let isFramework = toPath.lastPathComponent.hasSuffix(".framework")
                let isTweak = toPath.lastPathComponent.hasSuffix(".dylib")
                if isTweak {
                    LCParseMachO((toPath.path as NSString).utf8String, false) { path, header, _, _ in
                        LCPatchAddRPath(path, header);
                    }
                }
                self.tweakItems.append(LCTweakItem(fileUrl: toPath, isFolder: isFramework, isFramework: isFramework, isTweak: isTweak, isPackage: false, needsSigning: false))
            }
            if !installErrors.isEmpty {
                throw installErrors.joined(separator: "\n")
            }
            reloadTweakItems()
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true            
            return
        }
    }

    private func toggleTweakDisabled(_ tweakItem: LCTweakItem) {
        guard tweakItem.supportsDisableToggle else {
            return
        }
        let name = tweakItem.fileUrl.lastPathComponent
        let wasDisabled = disabledTweaks.contains(name)
        if disabledTweaks.contains(name) {
            disabledTweaks.remove(name)
        } else {
            disabledTweaks.insert(name)
        }
        do {
            try persistDisabledTweaks()
            triggerToggleHaptic(enabled: wasDisabled)
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    private func triggerToggleHaptic(enabled: Bool) {
        if enabled {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        } else {
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.prepare()
            generator.impactOccurred(intensity: 1.0)
        }
    }

    private func movePendingItemHere() {
        guard let pendingURL = moveContext.pendingMoveItemURL else {
            return
        }
        moveTweakItem(from: pendingURL, toFolder: baseUrl)
        moveContext.clearMove()
    }

    private func moveTweakItem(from sourceURL: URL, toFolder destinationFolderURL: URL) {
        let sourceFolderURL = sourceURL.deletingLastPathComponent()
        if sourceFolderURL == destinationFolderURL {
            return
        }
        if sourceURL == destinationFolderURL {
            errorShow = true
            errorInfo = "lc.tweakView.error.cannotMoveIntoSelf".loc
            return
        }
        if destinationFolderURL.path.hasPrefix(sourceURL.path + "/") {
            errorShow = true
            errorInfo = "lc.tweakView.error.cannotMoveIntoSelf".loc
            return
        }
        let destinationURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            errorShow = true
            errorInfo = "lc.tweakView.error.destinationExists %@".localizeWithFormat(sourceURL.lastPathComponent)
            return
        }
        do {
            try fm.moveItem(at: sourceURL, to: destinationURL)
            try Self.removeDisabledFlag(name: sourceURL.lastPathComponent, in: sourceFolderURL)
            if sourceFolderURL == baseUrl {
                disabledTweaks.remove(sourceURL.lastPathComponent)
            }
            reloadTweakItems()
            syncRootTweakFoldersIfNeeded()
        } catch {
            errorShow = true
            errorInfo = error.localizedDescription
        }
    }

    private func reloadTweakItems() {
        tweakItems = Self.loadTweakItems(baseUrl)
    }

    private static func loadTweakItems(_ folderURL: URL) -> [LCTweakItem] {
        var items: [LCTweakItem] = []
        let fm = FileManager.default
        do {
            let files = try fm.contentsOfDirectory(atPath: folderURL.path)
            for fileName in files {
                if fileName == "TweakInfo.plist" {
                    continue
                }
                let fileUrl = folderURL.appendingPathComponent(fileName)
                var isDirectory: ObjCBool = false
                fm.fileExists(atPath: fileUrl.path, isDirectory: &isDirectory)
                let isFramework = isDirectory.boolValue && fileUrl.lastPathComponent.hasSuffix(".framework")
                let isTweak = !isDirectory.boolValue && fileUrl.lastPathComponent.hasSuffix(".dylib")
                items.append(LCTweakItem(fileUrl: fileUrl, isFolder: isDirectory.boolValue, isFramework: isFramework, isTweak: isTweak))
            }
        } catch {
            NSLog("[LC] failed to load tweaks \(error.localizedDescription)")
        }
        return items.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder {
                return lhs.isFolder && !rhs.isFolder
            }
            return lhs.fileUrl.lastPathComponent.localizedCaseInsensitiveCompare(rhs.fileUrl.lastPathComponent) == .orderedAscending
        }
    }

    private static func loadDisabledTweaks(_ folderURL: URL) -> Set<String> {
        let infoPath = folderURL.appendingPathComponent("TweakInfo.plist").path
        guard let info = NSDictionary(contentsOfFile: infoPath),
              let disabled = info[lcDisabledTweaksKey] as? [String] else {
            return []
        }
        return Set(disabled)
    }

    private func persistDisabledTweaks() throws {
        let infoPath = baseUrl.appendingPathComponent("TweakInfo.plist").path
        let info = NSMutableDictionary(contentsOfFile: infoPath) ?? NSMutableDictionary()
        if disabledTweaks.isEmpty {
            info.removeObject(forKey: lcDisabledTweaksKey)
        } else {
            info[lcDisabledTweaksKey] = disabledTweaks.sorted()
        }
        if !info.write(toFile: infoPath, atomically: true) {
            throw "lc.tweakView.error.updateSettings".loc
        }
    }

    private static func removeDisabledFlag(name: String, in folderURL: URL) throws {
        let infoPath = folderURL.appendingPathComponent("TweakInfo.plist").path
        let info = NSMutableDictionary(contentsOfFile: infoPath) ?? NSMutableDictionary()
        guard var disabled = info[lcDisabledTweaksKey] as? [String] else {
            return
        }
        disabled.removeAll { $0 == name }
        if disabled.isEmpty {
            info.removeObject(forKey: lcDisabledTweaksKey)
        } else {
            info[lcDisabledTweaksKey] = disabled
        }
        if !info.write(toFile: infoPath, atomically: true) {
            throw "lc.tweakView.error.updateSettings".loc
        }
    }

    private func syncRootTweakFoldersIfNeeded() {
        guard isRoot else {
            return
        }
        let fm = FileManager.default
        do {
            let dirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            tweakFolders = dirs.filter { name in
                if name == "TweakInfo.plist" || name == "TweakLoader.dylib" {
                    return false
                }
                let url = LCPath.tweakPath.appendingPathComponent(name)
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }.sorted()
        } catch {
            NSLog("[LC] failed to sync tweak folders \(error.localizedDescription)")
        }
    }

    nonisolated func decompress(_ path: String, _ destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }

    private func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }

    private func installFromUrl(urlStr: String) async {
        if isInstallingFromURL {
            return
        }
        guard let installURL = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }

        isInstallingFromURL = true
        defer {
            isInstallingFromURL = false
        }

        if installURL.isFileURL {
            let fm = FileManager.default
            var didStartAccess = false
            if !fm.isReadableFile(atPath: installURL.path) {
                didStartAccess = installURL.startAccessingSecurityScopedResource()
                if !didStartAccess {
                    errorInfo = "lc.appList.ipaAccessError".loc
                    errorShow = true
                    return
                }
            }
            defer {
                if didStartAccess {
                    installURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try await installDownloadedTweakArtifact(installURL)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }

        do {
            let fm = FileManager.default
            let filename = installURL.lastPathComponent.isEmpty ? "download_\(UUID().uuidString)" : installURL.lastPathComponent
            let destinationURL = fm.temporaryDirectory.appendingPathComponent(filename)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }

            try await downloadHelper.download(url: installURL, to: destinationURL)
            if downloadHelper.cancelled {
                return
            }

            try await installDownloadedTweakArtifact(destinationURL)
            try? fm.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    private func installDownloadedTweakArtifact(_ artifactURL: URL) async throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: artifactURL.path, isDirectory: &isDir) else {
            throw "lc.tweakView.error.downloadedNotFound".loc
        }

        if isDir.boolValue {
            if artifactURL.lastPathComponent.hasSuffix(".framework") {
                await startInstallTweak([artifactURL])
                return
            }
            let candidates = try collectTweakCandidates(in: artifactURL)
            if candidates.isEmpty {
                throw "lc.tweakView.error.noTweakInFolder".loc
            }
            await startInstallTweak(candidates)
            return
        }

        if artifactURL.lastPathComponent.hasSuffix(".dylib") {
            await startInstallTweak([artifactURL])
            return
        }

        if isDebPackageURL(artifactURL) {
            try await installDebPackage(artifactURL)
            return
        }

        // Try to treat remote artifact as archive package containing .dylib or .framework
        let extractionDir = fm.temporaryDirectory.appendingPathComponent("LCTweakExtract_\(UUID().uuidString)")
        try fm.createDirectory(at: extractionDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: extractionDir)
        }

        let extractionProgress = Progress.discreteProgress(totalUnitCount: 100)
        guard await decompress(artifactURL.path, extractionDir.path, extractionProgress) == 0 else {
            throw "lc.tweakView.error.unsupportedPackage".loc
        }

        let candidates = try collectTweakCandidates(in: extractionDir)
        if candidates.isEmpty {
            throw "lc.tweakView.error.noTweakInPackage".loc
        }
        await startInstallTweak(candidates)
    }

    private func isDebPackageURL(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("deb") == .orderedSame
    }

    private func collectTweakCandidates(in rootURL: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var candidates: [URL] = []
        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) {
                continue
            }
            if isDir.boolValue {
                if fileURL.lastPathComponent.hasSuffix(".framework") {
                    candidates.append(fileURL)
                    enumerator.skipDescendants()
                }
                continue
            }
            if fileURL.lastPathComponent.hasSuffix(".dylib") {
                candidates.append(fileURL)
            }
        }
        return candidates.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // Extracts a .deb into a named package folder (<packageID>_<version>), records
    // control-file metadata (package ID, version, architecture, depends) and a
    // needsSigning flag in .lc-package.json, links associated .bundle resources, and
    // attempts to sign immediately if a certificate is available. This is the entry
    // point TweakLoader.m's package-metadata-aware loader (loadTweaksUsingPackageMetadata)
    // expects, so .deb installs from here are recognized natively as packages.
    private func installDebPackage(from fileUrl: URL, fm: FileManager) async throws {
        let extractionRoot = fm.temporaryDirectory.appendingPathComponent("lc-deb-\(UUID().uuidString)", isDirectory: true)
        let debExtractDir = extractionRoot.appendingPathComponent("deb", isDirectory: true)
        let controlExtractDir = extractionRoot.appendingPathComponent("control", isDirectory: true)
        defer {
            try? fm.removeItem(at: extractionRoot)
        }

        try fm.createDirectory(at: extractionRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: debExtractDir, withIntermediateDirectories: true)

        let debDestination = extractionRoot.appendingPathComponent(fileUrl.lastPathComponent)
        if fm.fileExists(atPath: debDestination.path) {
            try fm.removeItem(at: debDestination)
        }
        try fm.moveItem(at: fileUrl, to: debDestination)

        guard extract(debDestination.path, debExtractDir.path, Progress()) == 0 else {
            throw "Failed to extract \(fileUrl.lastPathComponent)"
        }

        guard let dataTarURL = findArchivePart(in: debExtractDir, prefix: "data.tar") else {
            throw "Invalid deb package: missing data.tar payload in \(fileUrl.lastPathComponent)"
        }

        let controlInfo = try loadControlInfo(from: debExtractDir, controlExtractDir: controlExtractDir, fileName: fileUrl.lastPathComponent, fm: fm)
        let packageFolderName = uniquePackageFolderName(baseName: "\(controlInfo.packageID)_\(controlInfo.version)", in: baseUrl, fm: fm)
        let packageFolder = baseUrl.appendingPathComponent(packageFolderName, isDirectory: true)
        try fm.createDirectory(at: packageFolder, withIntermediateDirectories: false)

        guard extract(dataTarURL.path, packageFolder.path, Progress()) == 0 else {
            try? fm.removeItem(at: packageFolder)
            throw "Failed to extract data payload from \(fileUrl.lastPathComponent)"
        }

        let loadableArtifacts = discoverLoadableArtifacts(in: packageFolder, fm: fm)
        linkAssociatedBundleResources(in: packageFolder, loadableArtifacts: loadableArtifacts, fm: fm)
        for relPath in loadableArtifacts {
            if relPath.hasSuffix(".framework") {
                let bundleURL = packageFolder.appendingPathComponent(relPath)
                if let executableURL = Bundle(url: bundleURL)?.executableURL {
                    patchRPathIfNeeded(binaryURL: executableURL)
                }
            } else {
                patchRPathIfNeeded(binaryURL: packageFolder.appendingPathComponent(relPath))
            }
        }

        var signingSucceeded = false
        if LCSharedUtils.certificatePassword() != nil {
            do {
                try await LCUtils.signTweaks(tweakFolderUrl: packageFolder, force: false) { _ in }
                signingSucceeded = true
            } catch {
                NSLog("[LC] Signing package %@ failed: %@", fileUrl.lastPathComponent, error.localizedDescription)
            }
        }
        let needsSigningFlag = (LCSharedUtils.certificatePassword() == nil) || !signingSucceeded
        let metadata = LCPackageMetadata(
            packageID: controlInfo.packageID,
            version: controlInfo.version,
            architecture: controlInfo.architecture,
            name: controlInfo.name,
            depends: controlInfo.depends,
            sourceFilename: fileUrl.lastPathComponent,
            importedAt: ISO8601DateFormatter().string(from: Date()),
            loadableArtifacts: loadableArtifacts,
            routesDetected: Array(Set(loadableArtifacts.map(routeForArtifactPath))).sorted(),
            needsSigning: needsSigningFlag
        )
        try writePackageMetadata(metadata, to: packageFolder)
        updateTweakItem(for: packageFolder)
    }

    private func loadControlInfo(from debExtractDir: URL, controlExtractDir: URL, fileName: String, fm: FileManager) throws -> LCControlInfo {
        guard let controlTarURL = findArchivePart(in: debExtractDir, prefix: "control.tar") else {
            let fallbackID = sanitizePackageName((fileName as NSString).deletingPathExtension)
            return LCControlInfo(packageID: fallbackID, version: "0", architecture: nil, name: nil, depends: nil)
        }
        try fm.createDirectory(at: controlExtractDir, withIntermediateDirectories: true)
        guard extract(controlTarURL.path, controlExtractDir.path, Progress()) == 0 else {
            throw "Failed to extract control metadata from \(fileName)"
        }

        guard let controlFile = findControlFile(in: controlExtractDir, fm: fm),
              let text = try? String(contentsOf: controlFile, encoding: .utf8) else {
            let fallbackID = sanitizePackageName((fileName as NSString).deletingPathExtension)
            return LCControlInfo(packageID: fallbackID, version: "0", architecture: nil, name: nil, depends: nil)
        }

        let fields = parseDebControlFields(text)
        let packageID = sanitizePackageName(fields["Package"] ?? (fileName as NSString).deletingPathExtension)
        let version = sanitizePackageName(fields["Version"] ?? "0")
        return LCControlInfo(
            packageID: packageID.isEmpty ? "unknown-package" : packageID,
            version: version.isEmpty ? "0" : version,
            architecture: fields["Architecture"],
            name: fields["Name"],
            depends: fields["Depends"]
        )
    }

    private func discoverLoadableArtifacts(in packageFolder: URL, fm: FileManager) -> [String] {
        guard let enumerator = fm.enumerator(at: packageFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        let basePath = packageFolder.standardizedFileURL.path
        var artifacts: Set<String> = []
        while let item = enumerator.nextObject() as? URL {
            let itemPath = item.standardizedFileURL.path
            guard itemPath.hasPrefix(basePath + "/") else {
                continue
            }
            let relPath = String(itemPath.dropFirst(basePath.count + 1))
            var isDirectory = ObjCBool(false)
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                if item.lastPathComponent.hasSuffix(".framework") {
                    let rel = String(itemPath.dropFirst(basePath.count + 1))
                    artifacts.insert(rel)
                    enumerator.skipDescendants()
                }
                continue
            }
            guard relPath.hasSuffix(".dylib"), shouldTreatAsLoadableDylib(binaryURL: item, relativePath: relPath, packageFolder: packageFolder) else {
                continue
            }
            artifacts.insert(relPath)
        }
        return Array(artifacts).sorted()
    }

    private func shouldTreatAsLoadableDylib(binaryURL: URL, relativePath: String, packageFolder: URL) -> Bool {
        let parentPath = binaryURL.deletingLastPathComponent()
        let base = binaryURL.deletingPathExtension().lastPathComponent
        let filterURL = parentPath.appendingPathComponent("\(base).plist")
        if FileManager.default.fileExists(atPath: filterURL.path) {
            return true
        }
        if relativePath.contains("/DynamicLibraries/") || relativePath.hasPrefix("DynamicLibraries/") {
            return true
        }
        if relativePath.contains("/Applications/"), relativePath.contains(".app/Frameworks/") {
            return true
        }
        return parentPath.path == packageFolder.path
    }

    private func routeForArtifactPath(_ relPath: String) -> String {
        if relPath.contains("/DynamicLibraries/") || relPath.hasPrefix("DynamicLibraries/") {
            return "mobile-substrate-package"
        }
        if relPath.contains("/Applications/"), relPath.contains(".app/Frameworks/") {
            return "prebundled-app-package"
        }
        return "standalone-binary"
    }

    private func linkAssociatedBundleResources(in packageFolder: URL, loadableArtifacts: [String], fm: FileManager) {
        guard let enumerator = fm.enumerator(at: packageFolder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        var bundleDirs: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            var isDirectory = ObjCBool(false)
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue {
                continue
            }
            if item.lastPathComponent.hasSuffix(".bundle") {
                bundleDirs.append(item)
                enumerator.skipDescendants()
            }
        }
        guard !bundleDirs.isEmpty else {
            return
        }

        var dylibParentDirs: Set<String> = []
        for relPath in loadableArtifacts where relPath.hasSuffix(".dylib") {
            let parent = (relPath as NSString).deletingLastPathComponent
            dylibParentDirs.insert(parent.isEmpty ? "." : parent)
        }

        let appSupportSource = packageFolder.appendingPathComponent("Library/Application Support", isDirectory: true)
        let hasAppSupportSource = fm.fileExists(atPath: appSupportSource.path)

        for dirRel in dylibParentDirs {
            let targetDir = dirRel == "." ? packageFolder : packageFolder.appendingPathComponent(dirRel, isDirectory: true)
            for bundleDir in bundleDirs {
                if bundleDir.deletingLastPathComponent().path == targetDir.path {
                    continue
                }
                let linkURL = targetDir.appendingPathComponent(bundleDir.lastPathComponent)
                if fm.fileExists(atPath: linkURL.path) {
                    continue
                }
                do {
                    try fm.createSymbolicLink(at: linkURL, withDestinationURL: bundleDir)
                } catch {
                    NSLog("[LC] Failed to link bundle %@ -> %@: %@", linkURL.path, bundleDir.path, error.localizedDescription)
                }
            }

            if hasAppSupportSource {
                let libraryDir = targetDir.appendingPathComponent("Library", isDirectory: true)
                let appSupportLink = libraryDir.appendingPathComponent("Application Support", isDirectory: true)
                do {
                    if !fm.fileExists(atPath: libraryDir.path) {
                        try fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)
                    }
                    if !fm.fileExists(atPath: appSupportLink.path) {
                        try fm.createSymbolicLink(at: appSupportLink, withDestinationURL: appSupportSource)
                    }
                } catch {
                    NSLog("[LC] Failed to link Application Support for %@: %@", targetDir.path, error.localizedDescription)
                }
            }
        }
    }

    private func writePackageMetadata(_ metadata: LCPackageMetadata, to packageFolder: URL) throws {
        let metadataURL = packageFolder.appendingPathComponent(".lc-package.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func patchRPathIfNeeded(binaryURL: URL) {
        LCParseMachO((binaryURL.path as NSString).utf8String, false) { path, header, _, _ in
            LCPatchAddRPath(path, header)
        }
    }

    private func updateTweakItem(for path: URL) {
        let fm = FileManager.default
        var isFolder = ObjCBool(false)
        fm.fileExists(atPath: path.path, isDirectory: &isFolder)
        let fileName = path.lastPathComponent
        var isPackage = false
        var needsSigning = false
        if isFolder.boolValue {
            let metaURL = path.appendingPathComponent(".lc-package.json")
            if fm.fileExists(atPath: metaURL.path) {
                isPackage = true
                if let data = try? Data(contentsOf: metaURL),
                   let dict = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let signingNeeded = dict["needsSigning"] as? Bool {
                    needsSigning = signingNeeded
                }
            }
        }
        let item = LCTweakItem(
            fileUrl: path,
            isFolder: isFolder.boolValue,
            isFramework: isFolder.boolValue && fileName.hasSuffix(".framework"),
            isTweak: !isFolder.boolValue && fileName.hasSuffix(".dylib"),
            isPackage: isPackage,
            needsSigning: needsSigning
        )
        if let idx = tweakItems.firstIndex(where: { $0.fileUrl.path == path.path }) {
            tweakItems[idx] = item
        } else {
            tweakItems.append(item)
        }
    }

    private func findArchivePart(in folder: URL, prefix: String) -> URL? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return nil
        }
        return files.first(where: { $0.lastPathComponent.hasPrefix(prefix) })
    }

    private func findControlFile(in folder: URL, fm: FileManager) -> URL? {
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        while let item = enumerator.nextObject() as? URL {
            var isDirectory = ObjCBool(false)
            fm.fileExists(atPath: item.path, isDirectory: &isDirectory)
            if !isDirectory.boolValue && item.lastPathComponent == "control" {
                return item
            }
        }
        return nil
    }

    private func parseDebControlFields(_ text: String) -> [String: String] {
        var parsed: [String: String] = [:]
        var currentKey: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let str = String(line)
            if str.hasPrefix(" "), let currentKey {
                parsed[currentKey, default: ""] += "\n" + str.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let idx = str.firstIndex(of: ":") else {
                continue
            }
            let key = String(str[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(str[str.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            parsed[key] = value
            currentKey = key
        }
        return parsed
    }

    private func sanitizePackageName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars)
    }

    private func uniquePackageFolderName(baseName: String, in root: URL, fm: FileManager) -> String {
        var candidate = baseName
        var index = 1
        while fm.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            candidate = "\(baseName)-\(index)"
            index += 1
        }
        return candidate
    }
}

struct LCTweaksView: View {
    @StateObject private var moveContext = LCTweakMoveContext()
    
    var body: some View {
        NavigationView {
            LCTweakFolderView(baseUrl: LCPath.tweakPath, isRoot: true)
        }
        .environmentObject(moveContext)
        .navigationViewStyle(StackNavigationViewStyle())

    }
}

struct LCTweaksCopyDestinationView: View {
    @Binding var tweakFolders: [String]
    let onClose: () -> Void
    let onCopyHere: (URL) -> Void
    @StateObject private var moveContext = LCTweakMoveContext()
    
    var body: some View {
        NavigationView {
            LCTweakFolderView(
                baseUrl: LCPath.tweakPath,
                isRoot: true,
                tweakFolders: $tweakFolders,
                copyMode: LCTweakCopyMode(onClose: onClose, onCopyHere: onCopyHere)
            )
        }
        .environmentObject(moveContext)
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
