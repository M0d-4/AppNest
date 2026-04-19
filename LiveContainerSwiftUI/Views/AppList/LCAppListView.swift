//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers
import Intents

enum AppLaunchMode: Int {
    case native = 0
    case realIPhone = 1
}

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    //⭐️⭐️⭐️Switch mode
    @AppStorage("LCNativeFullscreen") var isNative = true
    @AppStorage("LCRealiPhoneMode") var isiPhone = false
    @Binding var appDataFolderNames: [String]
    @Binding var tweakFolderNames: [String]
    
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @State var installprogressVisible = false
    @State var installProgressPercentage : Float = 0.0
    @State var installObserver : NSKeyValueObservation?
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    @State var safariViewOpened = false
    @State var safariViewURL = URL(string: "https://google.com")!
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    @State private var helpPresent = false
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("LCLaunchInMultitaskMode") var launchInMultitaskMode = false
    
    @State private var isViewAppeared = false
    
    @ObservedObject var searchContext = SearchContext()
    private var downloadHelper: DownloadHelper { sharedModel.downloadHelper }

    
    // Used to force NavigationView redraw on pop and prevent toolbar animation glitch
    @State private var navRefreshID = UUID()

    // Multi-select deletion
    @State private var isMultiSelectMode = false
    @State private var selectedAppsForDeletion: Set<LCAppModel> = []
    @State private var deleteAppData = false
    @State private var isDeleting = false
    @StateObject private var multiDeleteConfirmAlert = YesNoHelper()

 //⭐️⭐️⭐️Switch mode
   var currentLaunchMode: AppLaunchMode {
    if UserDefaults.standard.bool(forKey: "LCNativeFullscreen") {
        return .native
    }
    if LCUtils.appGroupUserDefault.bool(forKey: "LCRealIPhoneMode") {
        return .realIPhone
    }

    return .native 
}












 //⭐️⭐️⭐️Switch mode
func setMode(_ mode: AppLaunchMode) {
    withAnimation(.easeInOut(duration: 0.2)) {
        switch mode {
        case .native:

            isNative = true
            isiPhone = false

            LCUtils.appGroupUserDefault.set(false, forKey: "LCRealIPhoneMode")
            UserDefaults.standard.set(true, forKey: "LCNativeFullscreen")
        case .realIPhone:

            isNative = false
            isiPhone = true

            LCUtils.appGroupUserDefault.set(true, forKey: "LCRealIPhoneMode")
            UserDefaults.standard.set(false, forKey: "LCNativeFullscreen")
        }
    }
    sharedModel.objectWillChange.send()
}



    
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }

    /// Compares two semantic version strings (e.g. "1.2.3").
    /// Returns true if `sourceVersion` is newer than `installedVersion`.
    static func isSourceVersionNewer(_ sourceVersion: String, than installedVersion: String) -> Bool {
        let sourceComponents = sourceVersion.split(separator: ".").compactMap { Int($0) }
        let installedComponents = installedVersion.split(separator: ".").compactMap { Int($0) }
        let maxLength = max(sourceComponents.count, installedComponents.count)
        for i in 0..<maxLength {
            let s = i < sourceComponents.count ? sourceComponents[i] : 0
            let installed = i < installedComponents.count ? installedComponents[i] : 0
            if s != installed { return s > installed }
        }
        return false
    }

    /// Searches all loaded sources and returns the newest available version
    /// for the given bundle ID that is newer than `installedVersion`.
    /// When the same app appears in multiple sources, the overall newest wins.
    static func bestUpdateVersion(
        for bundleId: String,
        installedVersion: String,
        installedName: String? = nil,
        sources: [AltStoreSourcesViewModel.SourceItem]
    ) -> AltStoreSourceAppVersion? {
        var best: AltStoreSourceAppVersion? = nil
        for item in sources {
            guard let source = item.source else { continue }
            guard let sourceApp = source.apps.first(where: { $0.bundleIdentifier == bundleId }) else { continue }
            // Name check: if the installed app name is known, require source name to match
            // (ignoring spaces) to avoid cross-fork updates (e.g. modded → different mod).
            if let installedName {
                let normalize: (String) -> String = { $0.filter { !$0.isWhitespace }.lowercased() }
                guard normalize(sourceApp.name) == normalize(installedName) else { continue }
            }
            // Prefer the versions array (sorted newest-first); fall back to latestVersion for legacy sources
            let candidates = sourceApp.versions.isEmpty
                ? [sourceApp.latestVersion].compactMap { $0 }
                : sourceApp.versions
            for candidate in candidates {
                guard isSourceVersionNewer(candidate.version, than: installedVersion) else { continue }
                if let current = best {
                    if isSourceVersionNewer(candidate.version, than: current.version) {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
                break // versions are sorted newest-first; first valid one is the best from this source
            }
        }
        return best
    }

    private func updateAction(for app: LCAppModel) -> (() -> Void)? {
        guard let bundleId = app.appInfo.bundleIdentifier(),
              let installedVersion = app.appInfo.version() else { return nil }
        guard let updateVersion = Self.bestUpdateVersion(
            for: bundleId,
            installedVersion: installedVersion,
            installedName: app.appInfo.displayName(),
            sources: sharedModel.sourcesViewModel.sources
        ) else { return nil }
        let downloadURL = updateVersion.downloadURL
        return {
            withAnimation {
                DataManager.shared.model.selectedTab = .apps
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: NSNotification.InstallAppNotification, object: ["url": downloadURL])
            }
        }
    }

    init(appDataFolderNames: Binding<[String]>, tweakFolderNames: Binding<[String]>) {
        _installOptions = State(initialValue: [])
        _appDataFolderNames = appDataFolderNames
        _tweakFolderNames = tweakFolderNames
    }
    
    var body: some View {
        ZStack(alignment: .bottom) {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: Binding(
                        get: { isNavigationActive && !isMultiSelectMode },
                        set: { isNavigationActive = $0 }
                    ),
                    label: { EmptyView() }
                )
                .hidden()
                .disabled(isMultiSelectMode)
                
                VStack(spacing: 8) {
                    ForEach(filteredApps, id: \.self) { app in
                        appRow(app: app, isHidden: false)
                    }
                }
                .padding()
                .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            VStack(spacing: 8) {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }
                                
                                ForEach(filteredHiddenApps, id: \.self) { app in
                                    appRow(app: app, isHidden: true)
                                }
                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        VStack(spacing: 8) {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            ForEach(filteredHiddenApps, id: \.self) { app in
                                if sharedModel.isHiddenAppUnlocked {
                                    appRow(app: app, isHidden: true)
                                } else {
                                    LCAppSkeletonBanner()
                                }
                            }
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                if !isMultiSelectMode {
                                    Task { await authenticateUser() }
                                }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                        .padding(.horizontal)
                        .foregroundStyle(.gray)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .navigationBarProgressBar(show:$installprogressVisible, progress: $installProgressPercentage)
            .coordinateSpace(name: "scroll")
            .onAppear {
                if !didAppear {
                    onAppear()
                }
            }
            
            .navigationTitle("lc.appList.myApps".loc)
            .toolbar {
                // ── Leading: install spinner during sign phase (install actions are in the tray) ──
                ToolbarItem(placement: .topBarLeading) {
                    if !isMultiSelectMode && installprogressVisible {
                        ProgressView().progressViewStyle(.circular).padding(.horizontal, 8)
                    }
                }
                // ── The download tray (persistent overlay at ZStack bottom) handles
                // ── all download progress display — no toolbar indicator needed here.
                ToolbarItem(placement: .topBarLeading) {
                    if !isMultiSelectMode {
                        if UserDefaults.sideStoreExist() {
                            Button {
                                LCUtils.openSideStore(delegate: self)
                            } label: {
                                Image("SideStoreBadge")
                                    .resizable()
                                    .renderingMode(.template)
                                    .foregroundColor({
                                        if SharedModel.isLiquidGlassEnabled {
                                            return Color.primary
                                        } else {
                                            return Color.accentColor
                                        }
                                    }())
                                    .frame(width: UIFont.preferredFont(forTextStyle: .body).lineHeight,
                                           height: UIFont.preferredFont(forTextStyle: .body).lineHeight)
                            }
                        } else {
                            Button("Help", systemImage: "questionmark") {
                                helpPresent = true
                            }
                        }
                    }
                }

                // ── Trailing: link button (hidden during multi-select) ──
                ToolbarItem(placement: .topBarTrailing) {
                    if !isMultiSelectMode {
                        Button("lc.appList.openLink".loc, systemImage: "link", action: {
                            Task { await onOpenWebViewTapped() }
                        })
                    }
                }

                // ── Trailing: delete-data toggle (only in multi-select) ──
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelectMode {
                        Button {
                            withAnimation { deleteAppData.toggle() }
                        } label: {
                            Image(systemName: deleteAppData ? "externaldrive.fill.badge.minus" : "externaldrive.badge.minus")
                                .foregroundColor(deleteAppData ? .red : .secondary)
                        }
                        .disabled(isDeleting)
                    }
                }

                // ── Trailing: trash button (only in multi-select) ──
                ToolbarItem(placement: .topBarTrailing) {
                    if isMultiSelectMode {
                        Button {
                            Task { await deleteSelectedApps() }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(selectedAppsForDeletion.isEmpty || isDeleting ? .secondary : .red)
                        }
                        .disabled(selectedAppsForDeletion.isEmpty || isDeleting)
                    }
                }

                // ── Trailing: select / cancel toggle ──
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation {
                            isMultiSelectMode.toggle()
                            if !isMultiSelectMode {
                                selectedAppsForDeletion.removeAll()
                                deleteAppData = false
                            }
                        }
                        sharedModel.isMultiSelectMode = isMultiSelectMode
                    } label: {
                        Image(systemName: isMultiSelectMode ? "xmark.circle.fill" : "checkmark.circle")
                            .foregroundColor(isMultiSelectMode ? .red : .green)
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .disabled(isDeleting)
                }

                // ── Trailing: sort menu (hidden during multi-select) ──
                ToolbarItem(placement: .topBarTrailing) {
                    if !isMultiSelectMode {
                        Menu {
                            Picker("Sort by", selection: $sharedAppSortManager.appSortType) {
                                ForEach(AppSortType.allCases, id: \.self) { sortType in
                                    Label(sortType.displayName, systemImage: sortType.systemImage)
                                        .tag(sortType)
                                }
                            }
                            .onChange(of: sharedAppSortManager.appSortType) { newValue in
                                if sharedAppSortManager.appSortType == .custom {
                                    customSortViewPresent = true
                                }
                            }
                            if sharedAppSortManager.appSortType == .custom {
                                Divider()
                                Button {
                                    customSortViewPresent = true
                                } label: {
                                    Label("lc.appList.sort.customManage".loc, systemImage: "slider.horizontal.3")
                                }
                            }
                        } label: {
                            Label("lc.appList.sort".loc, systemImage: "line.3.horizontal.decrease.circle")
                        }
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .id(navRefreshID)

        // ── Persistent download/install tray ───────────────────────────────────
        // Always visible at the bottom of the screen regardless of download state.
        // The "From File" and "From URL" actions inside the tray fully replace the
        // old toolbar + button. The tray also shows live per-download progress cards.
        if sharedModel.multiLCStatus != 2 {
            DownloadTrayView(
                manager: sharedModel.downloadHelper,
                onInstallIPA: { choosingIPA = true },
                onInstallURL: { Task { await startInstallFromUrl() } }
            )
            .padding(.bottom, isMultiSelectMode ? 48 : 0)
            .allowsHitTesting(!isMultiSelectMode)
        }

        } // end ZStack
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await startInstallApp(fileUrls[0]) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .alert("lc.appList.deleteSelectedConfirm".loc, isPresented: $multiDeleteConfirmAlert.show) {
            Button(role: .destructive) { multiDeleteConfirmAlert.close(result: true) } label: { Text("lc.common.delete".loc) }
            Button("lc.common.cancel".loc, role: .cancel) { multiDeleteConfirmAlert.close(result: false) }
        } message: {
            Text("lc.appList.deleteSelectedMessage %lld".localizeWithFormat(selectedAppsForDeletion.count))
        }

        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
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
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .fullScreenCover(isPresented: $safariViewOpened) {
            SafariView(url: $safariViewURL)
        }
        .sheet(isPresented: $helpPresent) {
            LCHelpView(isPresent: $helpPresent)
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                // Pre-set the display name so the tray shows it before the download begins.
                if let name = obj2["appName"] as? String, !name.isEmpty {
                    downloadHelper._pendingLegacyName = name
                }
                // Propagate the isUpdate flag sent by the Updates tab so that
                // installFromUrl → installIpaFile knows to auto-replace and skip
                // the install/replace dialog.
                if let isUpdate = obj2["isUpdate"] as? Bool, isUpdate {
                    downloadHelper.isUpdate = true
                }
                Task { await installFromUrl(urlStr: installUrl.absoluteString) }
            }
        }
        // Drain the bulk-install queue one URL at a time, waiting for each to complete.
        .onReceive(sharedModel.$pendingInstallURLs) { urls in
            guard !urls.isEmpty else { return }
            Task { await drainInstallQueue() }
        }
        .apply {
            if #available(iOS 19.0, *), SharedModel.isLiquidGlassSearchEnabled {
                $0
            } else {
                $0.searchable(text: $searchContext.query)
            }
        }

    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
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
            
            UserDefaults.standard.setValue(urlToOpen.url!.absoluteString, forKey: "launchAppUrlScheme")
            do {
                try await appToLaunch.runApp()
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    func startInstallApp(_ fileUrl:URL) async {
        do {
            self.installprogressVisible = true
            try await installIpaFile(fileUrl)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            self.installprogressVisible = false
        }
    }
    
    nonisolated func decompress(_ path: String, _ destination: String ,_ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }
    
    func installIpaFile(_ url:URL, wasUpdate: Bool = false) async throws {
        let fm = FileManager()
        
        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        self.installProgressPercentage = 0.0
        self.installObserver = installProgress.observe(\.fractionCompleted) { p, v in
            DispatchQueue.main.async {
                self.installProgressPercentage = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }
        
        // decompress
        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName : String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName = appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)
        
        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        // ── Update validation ─────────────────────────────────────────────────
        // If this install was triggered from the Updates tab (wasUpdate == true),
        // verify the extracted IPA's bundle ID matches an installed app. If it does
        // NOT match, the user is downloading a fresh app (not an update). We cancel
        // the install and surface an alert directing them to the Apps tab.
        if wasUpdate, let downloadedBundleId = newAppInfo.bundleIdentifier() {
            let allApps = sharedModel.apps + sharedModel.hiddenApps
            if let reason = LCUpdatesValidator.validateIfMarkedAsUpdate(
                downloadedBundleId: downloadedBundleId,
                allApps: allApps
            ) {
                // Clean up extracted payload
                try? fm.removeItem(at: payloadPath)
                self.installprogressVisible = false
                throw reason
            }
        }
        // ─────────────────────────────────────────────────────────────────────

        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace : LCAppModel? = nil
        // Folder exist! show alert for user to choose which bundle to replace
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }
            
            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        self.installprogressVisible = false
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    self.installprogressVisible = false
                    return
                }
            }
            
        }
        
        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"

            // When this is an update (triggered from the Updates tab), automatically
            // replace the first matching installed app without showing the dialog.
            // This mirrors how a normal app-store update works — the user already
            // confirmed the update by tapping "Update" on the Updates tab.
            if wasUpdate, let existingApp = sameBundleIdApp.first {
                let replaceOption = AppReplaceOption(
                    isReplace: true,
                    nameOfFolderToInstall: existingApp.appInfo.relativeBundlePath,
                    appToReplace: existingApp
                )
                if existingApp.uiIsShared {
                    outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(replaceOption.nameOfFolderToInstall)
                } else {
                    outputFolder = LCPath.bundlePath.appendingPathComponent(replaceOption.nameOfFolderToInstall)
                }
                appRelativePath = replaceOption.nameOfFolderToInstall
                appToReplace = existingApp
                try fm.removeItem(at: outputFolder)
            } else {
                self.installOptions = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
                
                for app in sameBundleIdApp {
                    self.installOptions.append(AppReplaceOption(isReplace: true, nameOfFolderToInstall: app.appInfo.relativeBundlePath, appToReplace: app))
                }

                guard let installOptionChosen = await installReplaceAlert.open() else {
                    // user cancelled
                    self.installprogressVisible = false
                    try fm.removeItem(at: payloadPath)
                    return
                }
                
                if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                    outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
                } else {
                    outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
                }
                appRelativePath = installOptionChosen.nameOfFolderToInstall
                appToReplace = installOptionChosen.appToReplace
                if installOptionChosen.isReplace {
                    try fm.removeItem(at: outputFolder)
                }
            }
        }

        // If updating an existing app: show progress on its banner, hide global bar.
        // If installing new: keep global bar visible (no app to attach progress to).
        if let appToReplace {
            DispatchQueue.main.async {
                appToReplace.isSigningInProgress = true
                appToReplace.signProgress = 0.0
                self.installprogressVisible = false
            }
            // Feed installProgress percentage into the app model's signProgress
            let observer = installProgress.observe(\.fractionCompleted) { p, _ in
                DispatchQueue.main.async {
                    appToReplace.signProgress = p.fractionCompleted
                }
            }
            _ = observer // retain
        }

        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath
        
        guard let finalNewApp else {
            errorInfo = "lc.appList.appInfoInitError".loc
            errorShow = true
            return
        }
        
        // patch and sign it
        var signError : String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })
        
        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                errorInfo = "\("lc.appList.signSuccessWithError".loc)\n\n\(signError)"
            } else {
                errorInfo = signError.loc
            }
            errorShow = true
        }
        
        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by default
            finalNewApp.spoofSDKVersion = true
            // Set TweakLoader defaults for new apps (disable by default for security)
            finalNewApp.dontInjectTweakLoader = true
            finalNewApp.dontLoadTweakLoader = true
        }
        finalNewApp.installationDate = Date.now
        
        DispatchQueue.main.async {
            if let appToReplace {
                // Clear per-app progress state before swapping the model out
                appToReplace.isSigningInProgress = false
                appToReplace.signProgress = 0.0

                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                if appToReplace.uiIsHidden {
                    sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                    sharedModel.hiddenApps.append(newAppModel)
                } else {
                    sharedModel.apps.removeAll { $0 == appToReplace }
                    sharedModel.apps.append(newAppModel)
                }
            } else {
                let newAppModel = LCAppModel(appInfo: finalNewApp, delegate: self)
                sharedModel.apps.append(newAppModel)
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }
            self.installprogressVisible = false
        }
    }
    
    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        if let url = URL(string:installUrlStr), url.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: installUrlStr)
            return
        }
        await installFromUrl(urlStr: installUrlStr)
    }
    
    func installFromPlist(urlStr: String) async {
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        var plistUrlStr = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                errorInfo = "lc.appList.plistInvalidError".loc
                errorShow = true
                return
            }
        }
        
        guard let plistUrl = URL(string: plistUrlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                errorInfo = "lc.appList.plistParseError".loc
                errorShow = true
                return
            }
            
            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }
            
            guard let ipaUrlStr else {
                errorInfo = "lc.appList.plistNoIpaError".loc
                errorShow = true
                return
            }
            
            await installFromUrl(urlStr: ipaUrlStr)
            
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
    
    func installFromUrl(urlStr: String) async {
        // ignore any install request if we are installing another app
        if self.installprogressVisible {
            return
        }
        
        if sharedModel.multiLCStatus == 2 {
            errorInfo = "lc.appList.manageInPrimaryTip".loc
            errorShow = true
            return
        }
        
        guard let installUrl = URL(string: urlStr) else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        
        // Don't set installprogressVisible yet — the download phase shows progress
        // via the persistent DownloadTrayView overlay. installprogressVisible (the nav bar
        // spinner + progress bar) only activates during the install/sign phase inside
        // installIpaFile. This way the tray is visible during download.
        defer {
            self.installprogressVisible = false
        }
        
        if installUrl.isFileURL {
            // install from local, we directly call local install method
            if !installUrl.lastPathComponent.hasSuffix(".ipa") && !installUrl.lastPathComponent.hasSuffix(".tipa") {
                errorInfo = "lc.appList.urlFileIsNotIpaError".loc
                errorShow = true
                return
            }
            
            let fm = FileManager.default
            if !fm.isReadableFile(atPath: installUrl.path) && !installUrl.startAccessingSecurityScopedResource() {
                errorInfo = "lc.appList.ipaAccessError".loc
                errorShow = true
                return
            }
            
            defer {
                installUrl.stopAccessingSecurityScopedResource()
            }
            
            do {
                try await installIpaFile(installUrl)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    let fileURL = inboxURL.appendingPathComponent(installUrl.lastPathComponent)
                    
                    shouldDelete = fm.fileExists(atPath: fileURL.path)
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            return
        }
        
        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // Build a display name for the tray.
            // If a caller pre-set _pendingLegacyName (e.g. sources view set appName,
            // updates view set displayName), consume it; otherwise derive from URL.
            let presetName = downloadHelper._pendingLegacyName
            let rawName    = installUrl.lastPathComponent
            let displayName = !presetName.isEmpty ? presetName
                : (rawName.hasSuffix(".ipa")  ? String(rawName.dropLast(4))
                :  rawName.hasSuffix(".tipa") ? String(rawName.dropLast(5))
                :  rawName)
            downloadHelper._pendingLegacyName = ""

            let wasUpdate = downloadHelper.isUpdate
            downloadHelper.isUpdate = false

            let item = DownloadItem(
                url: installUrl,
                destinationURL: destinationURL,
                appName: displayName,
                isUpdate: wasUpdate
            )
            let itemID = downloadHelper.enqueue(item: item)

            // Wait for this specific download to finish
            while downloadHelper.items.contains(where: { $0.id == itemID && $0.isActive }) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }

            // Bail silently if cancelled
            guard !(downloadHelper.items.first(where: { $0.id == itemID })?.isCancelled ?? false)
            else { return }

            // If this was an update, switch to apps tab so per-app sign progress is visible
            if wasUpdate {
                await MainActor.run {
                    withAnimation { DataManager.shared.model.selectedTab = .apps }
                }
            }

            // Download done — start install/sign phase (shows nav bar progress)
            self.installprogressVisible = true
            self.installProgressPercentage = 0.0
            try await installIpaFile(destinationURL, wasUpdate: wasUpdate)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }
        
        let targetDataUUID = container ?? appFound.appInfo.dataUUID ?? ""


        //⭐️⭐️⭐️switch mode
    if launchInMultitaskMode {
        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    } else if UserDefaults.standard.bool(forKey: "LCNativeFullscreen") ||
          LCUtils.appGroupUserDefault.bool(forKey: "LCRealIPhoneMode") { 


        
    }
}
    
    func authenticateUser() async {
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
    
    func jitLaunch(appName: String) async {
        await jitLaunch(withScript: "", appName: appName)
    }

    func jitLaunch(withScript script: String, appName: String) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {

            let _ = await LCUtils.askForJIT(withScript: script, appName: appName) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp()

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)


            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if let url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }

                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }

                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func installMdm(data: Data) {
        safariViewURL = URL(string:"data:application/x-apple-aspen-config;base64,\(data.base64EncodedString())")!
        safariViewOpened = true
    }
    
    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
        // Force NavigationView to re-render without animation, fixing toolbar glitch on pop.
        // With reduced motion the pop is instant, so we skip the delay entirely.
        let delay = UIAccessibility.isReduceMotionEnabled ? 0.0 : 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                navRefreshID = UUID()
            }
        }
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var bundleId : String? = nil
                var containerName : String? = nil
                var forceJIT: Bool? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "bundle-name", let bundleId1 = queryItem.value {
                        bundleId = bundleId1
                    } else if queryItem.name == "container-folder-name", let containerName1 = queryItem.value {
                        containerName = containerName1
                    } else if queryItem.name == "jit", let forceJIT1 = queryItem.value {
                        if forceJIT1 == "true" {
                            forceJIT = true
                        } else if forceJIT1 == "false" {
                            forceJIT = false
                        }
                    }
                }
                if let bundleId, bundleId != "ui"{
                    Task { await launchAppWithBundleId(bundleId: bundleId, container: containerName, forceJIT: forceJIT) }
                }
            }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
    @ViewBuilder
    func appRow(app: LCAppModel, isHidden: Bool) -> some View {
        ZStack(alignment: .leading) {
            LCAppBanner(appModel: app, delegate: self, appDataFolders: $appDataFolderNames, tweakFolders: $tweakFolderNames, updateAction: nil)
                .padding(.leading, isMultiSelectMode ? 36 : 0)
                .animation(.easeInOut(duration: 0.2), value: isMultiSelectMode)
                .allowsHitTesting(!isMultiSelectMode && !isDeleting)

            if isMultiSelectMode {
                let isSelected = selectedAppsForDeletion.contains(app)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .green : .secondary)
                    .font(.title2)
                    .padding(.leading, 6)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(height: 88)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isMultiSelectMode, !isDeleting else { return }
            withAnimation(.easeInOut(duration: 0.1)) {
                if selectedAppsForDeletion.contains(app) {
                    selectedAppsForDeletion.remove(app)
                } else {
                    selectedAppsForDeletion.insert(app)
                }
            }
        }
    }

    /// Installs URLs from sharedModel.pendingInstallURLs one at a time.
    /// Each URL is dequeued before starting so concurrent calls self-cancel.
    func drainInstallQueue() async {
        while true {
            // Atomically dequeue the next URL
            guard !sharedModel.pendingInstallURLs.isEmpty else { return }
            let url = sharedModel.pendingInstallURLs.removeFirst()
            // Wait for this install to fully complete before moving to the next
            await installFromUrl(urlStr: url.absoluteString)
        }
    }

    func deleteSelectedApps() async {
        guard !selectedAppsForDeletion.isEmpty else { return }
        guard let confirmed = await multiDeleteConfirmAlert.open(), confirmed else { return }
        
        // Snapshot the set so UI changes mid-loop don't affect iteration
        let appsToDelete = selectedAppsForDeletion
        let removeData = deleteAppData
        
        isDeleting = true
        
        let fm = FileManager()
        for app in appsToDelete {
            guard let bundlePath = app.appInfo.bundlePath() else { continue }
            do {
                try fm.removeItem(atPath: bundlePath)
                removeApp(app: app)
                if removeData {
                    for container in app.appInfo.containers {
                        // containerURL already accounts for isShared (private vs group path)
                        try? fm.removeItem(at: container.containerURL)

                        // App group isolation folders (both private and shared variants)
                        let privateAppGroup = LCPath.appGroupPath.appendingPathComponent(container.folderName)
                        try? fm.removeItem(at: privateAppGroup)

                        let sharedAppGroup = LCPath.lcGroupAppGroupPath.appendingPathComponent(container.folderName)
                        try? fm.removeItem(at: sharedAppGroup)

                        LCUtils.removeAppKeychain(dataUUID: container.folderName)
                        DispatchQueue.main.async {
                            self.appDataFolderNames.removeAll { $0 == container.folderName }
                        }
                    }
                    // Legacy: handle apps whose containerInfo was nil but dataUUID exists.
                    // Bootstrap stores these under both private and shared data paths.
                    if let legacyUUID = app.appInfo.dataUUID {
                        let privateLegacy = LCPath.dataPath.appendingPathComponent(legacyUUID)
                        try? fm.removeItem(at: privateLegacy)

                        let sharedLegacy = LCPath.lcGroupDataPath.appendingPathComponent(legacyUUID)
                        try? fm.removeItem(at: sharedLegacy)

                        DispatchQueue.main.async {
                            self.appDataFolderNames.removeAll { $0 == legacyUUID }
                        }
                    }
                }
            } catch {
                // continue deleting others even if one fails
            }
        }
        
        await MainActor.run {
            withAnimation {
                selectedAppsForDeletion.removeAll()
                isMultiSelectMode = false
                deleteAppData = false
                isDeleting = false
            }
            sharedModel.isMultiSelectMode = false
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
