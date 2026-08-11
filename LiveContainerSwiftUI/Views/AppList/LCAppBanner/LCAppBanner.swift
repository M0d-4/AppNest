//
//  LCAppBanner.swift
//  LiveContainerSwiftUI
//
//  Public entry point. Renders either the pure-SwiftUI grid icon or the
//  UIKit-backed list banner (LCAppBannerViewController), and owns the
//  sheets/alerts driven by LCAppBannerActions.
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

struct LCAppBanner: View {
    @ObservedObject var model: LCAppModel
    @StateObject private var actions: LCAppBannerActions
    var interfaceStyle: LCAppListInterfaceStyle

    @AppStorage("LCAppGridShowLabels", store: LCUtils.appGroupUserDefault) var appGridShowLabels = false
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @EnvironmentObject var sharedModel: SharedModel

    var updateAction: (() -> Void)?
    var onContextMenuVisibilityChanged: ((Bool) -> Void)?

    init(appModel: LCAppModel, delegate: LCAppBannerDelegate, appDataFolders: Binding<[String]>, tweakFolders: Binding<[String]>, updateAction: (() -> Void)? = nil, interfaceStyle: LCAppListInterfaceStyle = .list, onContextMenuVisibilityChanged: ((Bool) -> Void)? = nil) {
        self.model = appModel
        _actions = StateObject(wrappedValue: LCAppBannerActions(model: appModel, delegate: delegate, appDataFolders: appDataFolders, tweakFolders: tweakFolders, updateAction: updateAction))
        self.interfaceStyle = interfaceStyle
        self.updateAction = updateAction
        self.onContextMenuVisibilityChanged = onContextMenuVisibilityChanged
    }

    var body: some View {
        Group {
            if interfaceStyle == .grid {
                gridIcon
            } else {
                LCAppBannerRepresentable(actions: actions)
                    .frame(height: LCAppBannerRootView.bannerHeight)
            }
        }
        .onChange(of: darkModeIcon) { newVal in
            actions.darkModeIcon = newVal
            actions.refreshIconIfNeeded()
        }
        // MARK: - Alerts / sheets (shared between grid and list modes)
        .alert("lc.appBanner.confirmUninstallTitle".loc, isPresented: $actions.appRemovalAlertShow) {
            Button(role: .destructive) {
                actions.resolveAppRemovalAlert(true)
            } label: {
                Text("lc.appBanner.uninstall".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                actions.resolveAppRemovalAlert(false)
            }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(actions.appInfo.displayName() ?? ""))
        }
        .alert("lc.appBanner.deleteDataTitle".loc, isPresented: $actions.appFolderRemovalAlertShow) {
            Button(role: .destructive) {
                actions.resolveAppFolderRemovalAlert(true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.no".loc, role: .cancel) {
                actions.resolveAppFolderRemovalAlert(false)
            }
        } message: {
            Text("lc.appBanner.deleteDataMsg %@".localizeWithFormat(actions.appInfo.displayName() ?? ""))
        }
        .alert("lc.common.error".loc, isPresented: $actions.errorShow) {
            Button("lc.common.ok".loc, action: {})
            Button("lc.common.copy".loc, action: {
                actions.copyError()
            })
        } message: {
            Text(actions.errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $actions.successShow) {
            Button("lc.common.ok".loc, action: {})
        } message: {
            Text(actions.successInfo)
        }
        .fileExporter(isPresented: $actions.saveIconExporterShow, document: actions.saveIconFile, contentType: .image, defaultFilename: "\(actions.appInfo.displayName() ?? "App") Icon.png") { _ in }
        .sheet(isPresented: $actions.showBinaryExportSheet) {
            LCAppBannerBinaryExportSheet(actions: actions)
        }
        .sheet(isPresented: $actions.showCopyToTweaksSheet) {
            LCTweaksCopyDestinationView(
                tweakFolders: actions.$tweakFolders,
                onClose: {
                    actions.showCopyToTweaksSheet = false
                },
                onCopyHere: { destinationURL in
                    Task { await actions.copySelectedToTweaks(destinationFolderURL: destinationURL) }
                }
            )
        }
        .sheet(item: $actions.exportShareItem, onDismiss: {
            actions.cleanupSharedExportFileIfNeeded()
        }) { item in
            ActivityViewController(activityItems: [item.fileURL])
        }
    }

    // MARK: - Grid mode (pure SwiftUI, unchanged from the previous implementation)

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
                Task { await actions.runApp() }
            } else {
                Task { await actions.runApp() }
            }
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    IconImageView(icon: actions.icon)
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
        .betterContextMenu(menuProvider: actions.makeContextMenu, onMenuVisibilityChanged: onContextMenuVisibilityChanged)
    }
}

private struct LCAppBannerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var actions: LCAppBannerActions

    func makeUIViewController(context: Context) -> LCAppBannerViewController {
        LCAppBannerViewController(actions: actions)
    }

    func updateUIViewController(_ uiViewController: LCAppBannerViewController, context: Context) {
        uiViewController.actions = actions
    }
}

private struct LCAppBannerBinaryExportSheet: View {
    @ObservedObject var actions: LCAppBannerActions

    var body: some View {
        NavigationView {
            List {
                if actions.isBinaryExportListLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Loading binaries...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } else if actions.binaryExportItems.isEmpty {
                    Text("No .dylib or .framework was found in this app bundle.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(actions.binaryExportItems) { item in
                        Button {
                            actions.toggleBinarySelection(for: item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: actions.selectedBinaryExportItemIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(actions.selectedBinaryExportItemIDs.contains(item.id) ? Color.accentColor : Color.secondary)
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
                        actions.showBinaryExportSheet = false
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !actions.isBinaryExportListLoading && !actions.binaryExportItems.isEmpty {
                        Button(actions.selectedBinaryExportItemIDs.count == actions.binaryExportItems.count ? "Unselect All" : "Select All") {
                            if actions.selectedBinaryExportItemIDs.count == actions.binaryExportItems.count {
                                actions.selectedBinaryExportItemIDs.removeAll()
                            } else {
                                actions.selectedBinaryExportItemIDs = Set(actions.binaryExportItems.map(\.id))
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if actions.isExportingBinarySelection {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Button("Export") {
                            Task { await actions.exportSelectedDylibsAndFrameworks() }
                        }
                        .disabled(actions.isBinaryExportListLoading || actions.selectedBinaryExportItemIDs.isEmpty)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if actions.isCopyingSelectionToTweaks {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Button("Copy to Tweaks") {
                            actions.openCopyToTweaksSelection()
                        }
                        .disabled(actions.isBinaryExportListLoading || actions.selectedBinaryExportItemIDs.isEmpty)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
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
