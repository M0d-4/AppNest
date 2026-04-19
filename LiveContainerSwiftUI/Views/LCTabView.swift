//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI

/// Finds and enables/disables the UITabBar in the view hierarchy
private struct TabBarInteractionBlocker: UIViewRepresentable {
    var isBlocked: Bool

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let window = windowScene.windows.first(where: { $0.isKeyWindow }) else { return }
            // Walk both VC and view hierarchies to cover all iOS versions
            if let rootVC = window.rootViewController {
                Self.blockInVC(!isBlocked, vc: rootVC)
            }
            Self.blockTabViews(!isBlocked, in: window)
        }
    }

    // VC hierarchy — covers UITabBarController on iPhone/standard iPad
    private static func blockInVC(_ enabled: Bool, vc: UIViewController) {
        if let tbc = vc as? UITabBarController {
            tbc.tabBar.isUserInteractionEnabled = enabled
        }
        for child in vc.children { blockInVC(enabled, vc: child) }
        if let pvc = vc.presentedViewController { blockInVC(enabled, vc: pvc) }
    }

    // UIView hierarchy — covers iPadOS 26 new Tab bar (private UIKit class, not UITabBar subclass)
    // We match by class name containing "TabBar" to future-proof across private API renames.
    private static func blockTabViews(_ enabled: Bool, in view: UIView) {
        let className = NSStringFromClass(type(of: view))
        // Match UITabBar AND any private SwiftUI/UIKit tab bar container
        if view is UITabBar || className.contains("TabBar") || className.contains("UITabSidebar") {
            view.isUserInteractionEnabled = enabled
        }
        for sub in view.subviews { blockTabViews(enabled, in: sub) }
    }
}

struct LCTabView: View {
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @State var previousSelectedTab : LCTabIdentifier = .apps
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)

    
    var body: some View {
        ZStack(alignment: .bottom) {
        Group {
            let appListView = LCAppListView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames)
            let sourcesView = LCSourcesView()
            if #available(iOS 19.0, *), SharedModel.isLiquidGlassSearchEnabled {
                TabView(selection: Binding(
                    get: { sharedModel.selectedTab },
                    set: { if !sharedModel.isMultiSelectMode { sharedModel.selectedTab = $0 } }
                )) {
                    if DataManager.shared.model.multiLCStatus != 2 {
                        Tab("lc.tabView.sources".loc, systemImage: "books.vertical", value: LCTabIdentifier.sources) {
                            sourcesView
                        }
                    }
                    Tab("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill", value: LCTabIdentifier.apps) {
                        appListView
                    }
                    if DataManager.shared.model.multiLCStatus != 2 {
                        Tab("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver", value: LCTabIdentifier.tweaks) {
                            LCTweaksView(tweakFolders: $tweakFolderNames)
                        }
                    }
                    Tab("lc.tabView.updates".loc, systemImage: "arrow.down.circle", value: LCTabIdentifier.updates) {
                        LCUpdatesView()
                    }
                    Tab("lc.tabView.settings".loc, systemImage: "gearshape.fill", value: LCTabIdentifier.settings) {
                        LCSettingsView(appDataFolderNames: $appDataFolderNames)
                    }
                    Tab("Search".loc, systemImage: "magnifyingglass", value: LCTabIdentifier.search, role: .search) {
                        if previousSelectedTab == .sources {
                            sourcesView
                                .searchable(text: sourcesView.$searchContext.query)
                        } else {
                            appListView
                                .searchable(text: appListView.$searchContext.query)
                        }

                    }
                }
            } else {
                TabView(selection: Binding(
                    get: { sharedModel.selectedTab },
                    set: { if !sharedModel.isMultiSelectMode { sharedModel.selectedTab = $0 } }
                )) {
                    if DataManager.shared.model.multiLCStatus != 2 {
                        sourcesView
                            .tabItem {
                                Label("lc.tabView.sources".loc, systemImage: "books.vertical")
                            }
                            .tag(LCTabIdentifier.sources)
                    }
                    appListView
                        .tabItem {
                            Label("lc.tabView.apps".loc, systemImage: "square.stack.3d.up.fill")
                        }
                        .tag(LCTabIdentifier.apps)
                    if DataManager.shared.model.multiLCStatus != 2 {
                        LCTweaksView(tweakFolders: $tweakFolderNames)
                            .tabItem{
                                Label("lc.tabView.tweaks".loc, systemImage: "wrench.and.screwdriver")
                            }
                            .tag(LCTabIdentifier.tweaks)
                    }
                    LCUpdatesView()
                        .tabItem {
                            Label("lc.tabView.updates".loc, systemImage: "arrow.down.circle")
                        }
                        .tag(LCTabIdentifier.updates)
                    
                    LCSettingsView(appDataFolderNames: $appDataFolderNames)
                        .tabItem {
                            Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                        }
                        .tag(LCTabIdentifier.settings)
                }
            }
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
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("lc.common.copy".loc, action: {
                            copyError()
                        })
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onChange(of: sharedModel.selectedTab) { newValue in
            if newValue != LCTabIdentifier.search && newValue != LCTabIdentifier.updates {
                previousSelectedTab = newValue
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
        .apply {
            if #available(iOS 16.0, *) {
                $0.toolbar(sharedModel.isMultiSelectMode ? .hidden : .visible, for: .tabBar)
            } else {
                $0
            }
        }
        .onChange(of: sharedModel.isMultiSelectMode) { hiding in
            // Fallback for iOS < 16 and for any tab bar variant not caught by the toolbar modifier
            if let tabBar = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .compactMap({ $0.rootViewController })
                .flatMap({ Self.allTabBars(in: $0) })
                .first {
                UIView.animate(withDuration: 0.25) {
                    tabBar.alpha = hiding ? 0 : 1
                }
            }
        }

        // UIKit-level blocker as a belt-and-suspenders fallback
        TabBarInteractionBlocker(isBlocked: sharedModel.isMultiSelectMode)
            .frame(width: 0, height: 0)
        } // end ZStack
    }
    
    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            // Check if it's a known custom scheme (with or without host)
            if let scheme = url.scheme?.lowercased(),
               !["livecontainer", "livecontainer2", "livecontainer3", "sidestore", "file", "http", "https"].contains(scheme) {
                
                let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
                if let app = allApps.first(where: { ($0.appInfo.customUrlSchemes as? [String] ?? []).contains(scheme) }) {
                    UserDefaults.standard.set(url.absoluteString, forKey: "launchAppUrlScheme")
                    UserDefaults.standard.set(app.appInfo.relativeBundlePath, forKey: "selected")
                    if let container = app.appInfo.dataUUID {
                        UserDefaults.standard.set(container, forKey: "selectedContainer")
                    }
                    LCSharedUtils.launchToGuestApp()
                    return
                }
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }

            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "livecontainer-relaunch":
                // Guest app pressed the exit button (non-multitask mode). LC is now
                // in the foreground with `selected` already cleared by LCBootstrap.
                // Just land on the apps tab — no deep-link processing needed.
                sharedModel.selectedTab = .apps
                return
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)

        sharedModel.deepLink = url
    }
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    private static func allTabBars(in vc: UIViewController) -> [UIView] {
        var result: [UIView] = []
        if let tbc = vc as? UITabBarController {
            result.append(tbc.tabBar)
        }
        for child in vc.children { result += allTabBars(in: child) }
        if let pvc = vc.presentedViewController { result += allTabBars(in: pvc) }
        return result
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryLiveContainerTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkBundleId() {
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}
