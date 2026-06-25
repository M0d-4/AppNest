//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

protocol LCAppBannerDelegate {
    func removeApp(app: LCAppModel)
    func installMdm(data: Data)
    func openNavigationView(view: AnyView)
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle?
}

private enum AppBinaryExportKind: String, Sendable {
    case dylib = "Dylib"
    case framework = "Framework"
}

private struct AppBinaryExportItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let relativePath: String
    let kind: AppBinaryExportKind
}

private struct AppExportShareItem: Identifiable {
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

struct LCAppBanner : View {
    @State var appInfo: LCAppInfo
    var delegate: LCAppBannerDelegate
    var interfaceStyle: LCAppListInterfaceStyle
    var onContextMenuVisibilityChanged: ((Bool) -> Void)?
    
    @ObservedObject var model : LCAppModel
    
    @Binding var appDataFolders: [String]
    @Binding var tweakFolders: [String]
    
    @StateObject private var appRemovalAlert = YesNoHelper()
    @StateObject private var appFolderRemovalAlert = YesNoHelper()
    
    @State private var saveIconExporterShow = false
    @State private var saveIconFile : ImageDocument?
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""

    @State private var showBinaryExportSheet = false
    @State private var binaryExportItems: [AppBinaryExportItem] = []
    @State private var selectedBinaryExportItemIDs: Set<String> = []
    @State private var isBinaryExportListLoading = false
    @State private var isExportingBinarySelection = false
    @State private var showCopyToTweaksSheet = false
    @State private var isCopyingSelectionToTweaks = false
    @State private var exportShareItem: AppExportShareItem?
    @State private var exportShareCleanupURLs: [URL] = []
    let updateAction: (() -> Void)?
    
    @AppStorage("dynamicColors", store: LCUtils.appGroupUserDefault) var dynamicColors = true
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @AppStorage("LCAppGridShowLabels", store: LCUtils.appGroupUserDefault) var appGridShowLabels = false
    @State private var mainColor : Color
    @State private var icon: UIImage
    
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var sharedModel : SharedModel
    
    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, appDataFolders: Binding<[String]>, tweakFolders: Binding<[String]>, updateAction: (() -> Void)? = nil, interfaceStyle: LCAppListInterfaceStyle = .list, onContextMenuVisibilityChanged: ((Bool) -> Void)? = nil) {
        _appInfo = State(initialValue: appModel.appInfo)
        _appDataFolders = appDataFolders
        _tweakFolders = tweakFolders
        self.delegate = delegate
        self.updateAction = updateAction
        self.interfaceStyle = interfaceStyle
        self.onContextMenuVisibilityChanged = onContextMenuVisibilityChanged
        
        _model = ObservedObject(wrappedValue: appModel)
        _mainColor = State(initialValue: Color.clear)
        _icon = State(initialValue: appModel.appInfo.iconIsDarkIcon(LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")))
        _mainColor = State(initialValue: extractMainHueColor())

    }
    @State private var mainHueColor: CGFloat? = nil
    
    @ViewBuilder
    var body: some View {
        if interfaceStyle == .grid {
            gridIcon
        } else {
            banner
        }
    }
    
    var banner: some View {

        HStack {
            HStack {
                IconImageView(icon: icon)
                    .frame(width: 60, height: 60)

                VStack (alignment: .leading, content: {
                    let color = (dynamicColors ? mainColor : Color("FontColor"))
                    // note: keep this so the color updates when toggling dark mode
                    let textColor = colorScheme == .dark ? color.readableTextColor() : color.readableTextColor()
                    HStack {
                        Text(model.displayName).font(.system(size: 16)).bold()
                        if model.uiIsShared {
                            Image(systemName: "arrowshape.turn.up.left.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .frame(width: 16, height:16)
                                .background(
                                    Capsule().fill(Color("BadgeColor"))
                                )
                        }
                        if model.uiIsJITNeeded {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .frame(width: 16, height:16)
                                .background(
                                    Capsule().fill(Color("JITBadgeColor"))
                                )
                        }
#if is32BitSupported
                        if model.uiIs32bit {
                            Text("32")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .frame(width: 16, height:16)
                                .background(
                                    Capsule().fill(Color("32BitBadgeColor"))
                                )
                        }
#endif
                        if model.uiIsLocked && !model.uiIsHidden {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.white)
                                .frame(width: 16, height:16)
                                .background(
                                    Capsule().fill(Color("BadgeColor"))
                                )
                        }
                        if model.uiSpoofCamera {
                            Image(systemName: "camera.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.red)
                                    // .frame(width: 16, height: 16)
                            // Image(systemName: "camera.fill")
                            //     .font(.system(size: 10, weight: .bold))
                            //     .foregroundColor(.red)
                            //     .frame(width: 16, height:16)
                            //     .background(
                            //         Capsule().fill(Color.red)
                            //     )
                        }
                        if model.uiDeviceSpoofingEnabled {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 16))
                                .foregroundColor(.red)
                        }
                    }
                    
                    HStack {
                        Text("\(appInfo.version() ?? "") - \(appInfo.bundleIdentifier()!)")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    
                    // Container name
                    if let selectedContainer = model.uiSelectedContainer {
                        HStack {
                            Text(selectedContainer.name)
                                .font(.system(size: 12))
                                .foregroundColor(.blue)
                            Spacer()
                        }
                        
                        // GPS Location display
                        if model.uiSpoofGPS {
                            HStack {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.red)
                                
                                Text(locationDisplayText)
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                                appContentView
                                
                                Spacer()
                            }
                        }
                    }
                })
            }
            .allowsHitTesting(false)
            Spacer()
            do {
                ZStack {
                    if !model.isSigningInProgress {
                        Text("lc.appBanner.run".loc).bold().foregroundColor(.white)
                            .lineLimit(1)
                            .frame(height:32)
                            .minimumScaleFactor(0.1)
                    } else {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
                .buttonStyle(BasicButtonStyle())
                .padding()
                .frame(idealWidth: 70)
                .frame(height: 32)
                .fixedSize()
                .background(GeometryReader { g in
                    if !model.isSigningInProgress {
                        Capsule().fill(dynamicColors ? mainColor : Color("FontColor"))
                    } else {
                        let w = g.size.width
                        let h = g.size.height
                        Capsule()
                            .fill(dynamicColors ? mainColor : Color("FontColor")).opacity(0.2)
                        Circle()
                            .fill(dynamicColors ? mainColor : Color("FontColor"))
                            .frame(width: w * 2, height: w * 2)
                            .offset(x: (model.signProgress - 2) * w, y: h/2-w)
                    }
                })
                .clipShape(Capsule())
                .contentShape(Capsule())
                .onTapGesture {
                    if #available(iOS 16.0, *) {
                        if let currentDataFolder = model.uiSelectedContainer?.folderName,
                           MultitaskManager.isUsing(container: currentDataFolder) {
                            var found = false
                            if #available(iOS 16.1, *) {
                                found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
                            }
                            if !found {
                                found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
                            }
                            if found {
                                return
                            }
                        }
                        
                        Task{ await runApp() }
                    } else {
                        Task{ await runApp() }
                    }
                }
                .disabled(model.isAppRunning)
            }

        }
        .padding()
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width:22, height: 22)).fill(dynamicColors ? mainColor.opacity(0.5) : Color("AppBannerBG"))
                .onTapGesture(count: 2) {
                    openSettings()
                }
        }



        .fileExporter(
            isPresented: $saveIconExporterShow,
            document: saveIconFile,
            contentType: .image,
            defaultFilename: "\(appInfo.displayName()!) Icon.png",
            onCompletion: { result in
            
        })
        .betterContextMenu(menuProvider: makeContextMenu, onMenuVisibilityChanged: onContextMenuVisibilityChanged)
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $appRemovalAlert.show) {
            Button(role: .destructive) {
                appRemovalAlert.close(result: true)
            } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                appRemovalAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(appInfo.displayName()!))
        }
        .alert("lc.appBanner.deleteDataTitle".loc, isPresented: $appFolderRemovalAlert.show) {
            Button(role: .destructive) {
                appFolderRemovalAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.no".loc, role: .cancel) {
                appFolderRemovalAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.deleteDataMsg %@".localizeWithFormat(appInfo.displayName()!))
        }
        
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
            Button("lc.common.ok".loc, action: {
            })
        } message: {
            Text(successInfo)
        }
        .sheet(isPresented: $showBinaryExportSheet) {
            NavigationView {
                List {
                    if isBinaryExportListLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Loading binaries...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    } else if binaryExportItems.isEmpty {
                        Text("No .dylib or .framework was found in this app bundle.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(binaryExportItems) { item in
                            Button {
                                toggleBinarySelection(for: item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selectedBinaryExportItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedBinaryExportItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.relativePath)
                                            .font(.system(.body, design: .monospaced))
                                        Text(item.kind.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationTitle("Export Dylibs & Frameworks")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showBinaryExportSheet = false
                        }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !isBinaryExportListLoading && !binaryExportItems.isEmpty {
                            Button(selectedBinaryExportItemIDs.count == binaryExportItems.count ? "Unselect All" : "Select All") {
                                if selectedBinaryExportItemIDs.count == binaryExportItems.count {
                                    selectedBinaryExportItemIDs.removeAll()
                                } else {
                                    selectedBinaryExportItemIDs = Set(binaryExportItems.map(\.id))
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isExportingBinarySelection {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Button("Export") {
                                Task { await exportSelectedDylibsAndFrameworks() }
                            }
                            .disabled(isBinaryExportListLoading || selectedBinaryExportItemIDs.isEmpty)
                        }
                    }
                    ToolbarItem(placement: .bottomBar) {
                        if isCopyingSelectionToTweaks {
                            ProgressView()
                                .progressViewStyle(.circular)
                        } else {
                            Button("Copy to Tweaks") {
                                openCopyToTweaksSelection()
                            }
                            .disabled(isBinaryExportListLoading || selectedBinaryExportItemIDs.isEmpty)
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
        }
        .sheet(isPresented: $showCopyToTweaksSheet) {
            LCTweaksCopyDestinationView(
                tweakFolders: $tweakFolders,
                onClose: {
                    showCopyToTweaksSheet = false
                },
                onCopyHere: { destinationURL in
                    Task { await copySelectedToTweaks(destinationFolderURL: destinationURL) }
                }
            )
        }
        .sheet(item: $exportShareItem, onDismiss: {
            cleanupSharedExportFileIfNeeded()
        }) { item in
            ActivityViewController(activityItems: [item.fileURL])
        }
        .onChange(of: darkModeIcon) { newVal in
            icon = appInfo.iconIsDarkIcon(newVal)
            mainColor = extractMainHueColor()
        }
    }

    // MARK: - Computed Properties

    private var currentColor: Color {
        dynamicColors ? mainColor : Color("FontColor")
    }

    private var currentTextColor: Color {
        let color = currentColor
        return colorScheme == .dark ? color.readableTextColor() : color.readableTextColor()
    }

    @ViewBuilder
    private var appContentView: some View {
        // App name and badges
        appNameRow(textColor: currentTextColor)

        // Version and bundle ID
        Text("\(appInfo.version() ?? "?") - \(appInfo.bundleIdentifier() ?? "?")")
            .font(.system(size: 12))
            .foregroundColor(currentTextColor)

        // Remark if exists
        if !model.uiRemark.isEmpty {
            Text(model.uiRemark)
                .font(.system(size: 10))
                .foregroundColor(currentTextColor.opacity(0.8))
                .lineLimit(1)
        }

        // Container name
        Text(model.uiSelectedContainer?.name ?? "lc.appBanner.noDataFolder".loc)
            .font(.system(size: 8))
            .foregroundColor(currentTextColor)

        // Storage size
        Text("Uses \(appInfo.bundleSize()) of storage")
            .font(.system(size: 8))
            .foregroundColor(currentTextColor.opacity(0.7))
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func appNameRow(textColor: Color) -> some View {
        HStack {
            Text(appInfo.displayName()).font(.system(size: 16)).bold()
            if model.uiIsShared {
                badgeView(systemName: "arrowshape.turn.up.left.fill", color: "BadgeColor")
            }
            if model.uiIsJITNeeded {
                badgeView(systemName: "bolt.fill", color: "JITBadgeColor")
            }
#if is32BitSupported
            if model.uiIs32bit {
                Text("32")
                    .font(.system(size: 8))
                    .foregroundColor(.white)
                    .frame(width: 16, height:16)
                    .background(Capsule().fill(Color("32BitBadgeColor")))
            }
#endif
            if model.uiIsLocked && !model.uiIsHidden {
                badgeView(systemName: "lock.fill", color: "BadgeColor")
            }
        }
    }

    private func badgeView(systemName: String, color: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 8))
            .foregroundColor(.white)
            .frame(width: 16, height:16)
            .background(Capsule().fill(Color(color)))
    }

    var gridIcon: some View {
        Button {
            if #available(iOS 16.0, *) {
                if let currentDataFolder = model.uiSelectedContainer?.folderName,
                   MultitaskManager.isUsing(container: currentDataFolder) {
                    var found = false
                    if #available(iOS 16.1, *) {
                        found = MultitaskWindowManager.openExistingAppWindow(dataUUID: currentDataFolder)
                    }
                    if !found {
                        found = MultitaskDockManager.shared.bringMultitaskViewToFront(uuid: currentDataFolder)
                    }
                    if found {
                        return
                    }
                }
                Task { await runApp() }
            } else {
                Task { await runApp() }
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    IconImageView(icon: icon)
                        .frame(width: appGridShowLabels ? 72 : 84, height: appGridShowLabels ? 72 : 84)
                        .opacity(model.isSigningInProgress ? 0.35 : 1)
                    if model.isSigningInProgress {
                        ProgressView().progressViewStyle(.circular)
                    }
                }
                if appGridShowLabels {
                    Text(model.displayName)
                        .font(.system(size: 13))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.primary)
                        .frame(width: 90, height: 34, alignment: .top)
                }
            }
            .frame(width: appGridShowLabels ? 90 : 92, height: appGridShowLabels ? 112 : 92, alignment: .top)
        }
        .buttonStyle(.plain)
        .disabled(model.isAppRunning)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .betterContextMenu(menuProvider: makeContextMenu, onMenuVisibilityChanged: onContextMenuVisibilityChanged)
        .onChange(of: darkModeIcon) { newVal in
            icon = appInfo.iconIsDarkIcon(newVal)
            mainColor = extractMainHueColor()
        }
    }

    func makeContextMenu() -> UIMenu {
        var menuChildren: [UIMenuElement] = []

        // 1. Containers Picker (Equivalent to a Menu with single selection)
        if model.uiContainers.count > 1 {
            let containerActions = model.uiContainers.map { container in
                UIAction(title: container.name,
                         state: container == model.uiSelectedContainer ? .on : .off) { _ in
                    model.uiSelectedContainer = container
                }
            }
            let containerMenu = UIMenu(title: "Containers", options: .displayInline, children: containerActions)
            menuChildren.append(containerMenu)
        }

        // 2. Main Section
        var sectionChildren: [UIMenuElement] = []

        // Open Data Folder
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            let openFolder = UIAction(title: "lc.appBanner.openDataFolder".loc,
                                      image: UIImage(systemName: "folder")) { _ in
                openDataFolder()
            }
            sectionChildren.append(openFolder)
        }

        // Multitask Toggle
        if #available(iOS 16.0, *) {
            let runTitle = model.shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc
            let runImage = model.shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus"

            let multitaskAction = UIAction(title: runTitle, image: UIImage(systemName: runImage)) { _ in
                Task { await runApp(multitask: !model.shouldLaunchInMultitaskMode) }
            }
            sectionChildren.append(multitaskAction)
        }

        // Submenu: Add to Home Screen
        let subMenuActions = [
            UIAction(title: "lc.appBanner.copyLaunchUrl".loc, image: UIImage(systemName: "link")) { _ in
                copyLaunchUrl()
            },
            UIAction(title: "lc.appBanner.saveAppIcon".loc, image: UIImage(systemName: "square.and.arrow.down")) { _ in
                Task { await saveIcon() }
            },
            UIAction(title: "lc.appBanner.createAppClip".loc, image: UIImage(systemName: "appclip")) { _ in
                Task { await openSafariViewToCreateAppClip() }
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
                UIAction(
                    title: "Export IPA",
                    image: UIImage(systemName: "shippingbox")
                ) { _ in
                    Task { await exportIPA(includeData: false) }
                },
                UIAction(
                    title: "Export Data",
                    image: UIImage(systemName: "folder.fill"),
                    attributes: dataExportDisabled
                ) { _ in
                    Task { await exportData() }
                },
                UIAction(
                    title: "Export IPA + Data",
                    image: UIImage(systemName: "square.and.arrow.up.on.square"),
                    attributes: dataExportDisabled
                ) { _ in
                    Task { await exportIPA(includeData: true) }
                },
                UIAction(
                    title: "Export Dylibs & Frameworks",
                    image: UIImage(systemName: "list.bullet.rectangle")
                ) { _ in
                    openDylibAndFrameworkExportSelection()
                }
            ]
        )

    sectionChildren.append(exportMenu)

        let cloneAction = UIAction(
            title: "Clone App",
            image: UIImage(systemName: "square.on.square")
        ) { _ in
            Task { await cloneApp() }
        }
        sectionChildren.append(cloneAction)

        // Settings
        let settingsAction = UIAction(title: "lc.tabView.settings".loc, image: UIImage(systemName: "gear")) { _ in
            openSettings()
        }
        sectionChildren.append(settingsAction)

        // Destructive Uninstall
        if !model.uiIsShared {
            let uninstallAction = UIAction(title: "lc.appBanner.uninstall".loc,
                                           image: UIImage(systemName: "trash"),
                                           attributes: .destructive) { _ in
                Task { await uninstall() }
            }
            sectionChildren.append(uninstallAction)
        }

        // Wrap the section in an inline menu to mimic SwiftUI Section behavior
        let mainSection = UIMenu(title: appInfo.relativeBundlePath, options: .displayInline, children: sectionChildren)
        menuChildren.append(mainSection)

        return UIMenu(title: "", children: menuChildren)
    }

    // MARK: - Functions
    
    func runApp(multitask: Bool? = nil) async {
        if appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
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
        let url = URL(string:"shareddocuments://\(LCPath.dataPath.path)/\(model.uiSelectedContainer!.folderName)")
        UIApplication.shared.open(url!)
    }
    

    
    func uninstall() async {
        do {
            if let result = await appRemovalAlert.open(), !result {
                return
            }
            
            var doRemoveAppFolder = false
            let containers = appInfo.containers
            if !containers.isEmpty {
                if let result = await appFolderRemovalAlert.open() {
                    doRemoveAppFolder = result
                }
                
            }
            
            let fm = FileManager()
            try fm.removeItem(atPath: self.appInfo.bundlePath()!)
            self.delegate.removeApp(app: self.model)
            if doRemoveAppFolder {
                for container in containers {
                    let dataUUID = container.folderName
                    let dataFolderPath = container.containerURL
                    if fm.fileExists(atPath: dataFolderPath.path) {
                        try fm.removeItem(at: dataFolderPath)
                    }
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    
                    DispatchQueue.main.async {
                        self.appDataFolders.removeAll(where: { f in
                            return f == dataUUID
                        })
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
                sharedModel.apps.append(clonedAppModel)
            }
            successInfo = "Cloned app created."
            successShow = true
        } catch {
            errorInfo = error.localizedDescription
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

    func makeCloneRelativeBundlePath(targetRootURL: URL, fileManager: FileManager) -> String {
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

    func resetClonedAppInfo(at clonedBundleURL: URL, fileManager: FileManager) throws {
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

    func signClonedAppIfNeeded(_ clonedAppInfo: LCAppInfo) async throws {
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
        if let fn = model.uiSelectedContainer?.folderName {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(appInfo.relativeBundlePath!)&container-folder-name=\(fn)"
        } else {
            UIPasteboard.general.string = "livecontainer://livecontainer-launch?bundle-name=\(appInfo.relativeBundlePath!)"
        }
        
    }
    
    func openSafariViewToCreateAppClip() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }
        
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: appInfo.generateWebClipConfig(withContainerId: model.uiSelectedContainer?.folderName, iconStyle: style)!, format: .xml, options: 0)
            delegate.installMdm(data: data)
        } catch  {
            errorShow = true
            errorInfo = error.localizedDescription
        }

    }
    
    func saveIcon() async {
        guard let style = await delegate.promptForGeneratedIconStyle() else {
            return
        }
        
        let img = appInfo.generateLiveContainerWrappedIcon(with: style)!
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
            errorInfo = error.localizedDescription
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
            errorInfo = error.localizedDescription
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
                    errorInfo = error.localizedDescription
                    errorShow = true
                    showBinaryExportSheet = false
                }
            }
        }
    }

    private func toggleBinarySelection(for item: AppBinaryExportItem) {
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
            errorInfo = error.localizedDescription
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            showCopyToTweaksSheet = true
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
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func copySelectedBinaryItems(to destinationFolderURL: URL) throws -> Int {
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

    func nextAvailableCopyURL(for proposedURL: URL) -> URL {
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

    func createExportIPA(includeData: Bool) async throws -> URL {
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

    func createDataArchive() async throws -> URL {
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

    func zipDirectory(sourceURL: URL, destinationURL: URL) async throws {
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
    func presentShareSheet(for fileURL: URL) {
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

    func sanitizedFileStem(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Export" : cleaned
    }

    func copyContainerDataForExport(from sourceContainerURL: URL, to destinationContainerURL: URL) throws {
        let fm = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceContainerURL.path, isDirectory: &sourceIsDirectory), sourceIsDirectory.boolValue else {
            throw "Selected container path is not a directory."
        }

        try copyDirectoryForExport(from: sourceContainerURL, to: destinationContainerURL)
    }

    func copyDirectoryForExport(from sourceDirectoryURL: URL, to destinationDirectoryURL: URL) throws {
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

    func shouldSkipDataExportItem(values: URLResourceValues) -> Bool {
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

    func shouldIgnoreDataExportCopyError(_ error: Error, resourceValues: URLResourceValues) -> Bool {
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

    func isNoSuchFileError(_ nsError: NSError) -> Bool {
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



    private var locationDisplayText: String {
        if !model.uiSpoofLocationName.isEmpty && model.uiSpoofLocationName != "Unknown Location" {
            return model.uiSpoofLocationName
        } else {
            return String(format: "%.4f, %.4f", model.uiSpoofLatitude, model.uiSpoofLongitude)
        }
    }

}


struct LCAppSkeletonBanner: View {
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 60)
            
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 100, height: 16)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 150, height: 12)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 8)
            }
            
            Spacer()
            
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 70, height: 32)
        }
        .padding()
        .frame(height: 88)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color.gray.opacity(0.1)))
    }
    
}

struct LCAppSkeletonIcon: View {
    var showLabels: Bool
    
    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: showLabels ? 19 : 22)
                .fill(Color.gray.opacity(0.3))
                .frame(width: showLabels ? 72 : 84, height: showLabels ? 72 : 84)
            if showLabels {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 78, height: 12)
            }
        }
        .frame(width: showLabels ? 90 : 92, height: showLabels ? 112 : 92, alignment: .top)
    }
}
