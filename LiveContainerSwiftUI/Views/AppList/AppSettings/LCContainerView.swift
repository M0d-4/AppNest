//
//  LCContainerView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/12/6.
//

import SwiftUI

protocol LCContainerViewDelegate {
    func unbindContainer(container: LCContainer)
    func setDefaultContainer(container: LCContainer)
    func saveContainer(container: LCContainer)
    
    func getSettingsBundle() -> Bundle?
    func getContainerURL(container: LCContainer) -> URL
    func getBundleId() -> String
    func isTweakLoaderInjectionDisabled() -> Bool
}

struct LCContainerView : View {
    @ObservedObject var container : LCContainer
    let delegate : LCContainerViewDelegate
    @Binding var uiDefaultDataFolder : String?
    @State var settingsBundle : Bundle? = nil
    
    @StateObject private var removeContainerAlert = YesNoHelper()
    @StateObject private var deleteDataAlert = YesNoHelper()
    @StateObject private var removeKeychainAlert = YesNoHelper()
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sharedModel : SharedModel
    @State private var typingContainerName : String = ""
    @State private var typingIDFV: String = ""
    @State private var typingSpoofDeviceName: String = ""
    @State private var typingSpoofDeviceModel: String = ""
    @State private var typingSpoofSystemName: String = ""
    @State private var typingSpoofSystemVersion: String = ""
    @State private var typingSpoofLocaleIdentifier: String = ""
    @State private var typingSpoofTimeZoneIdentifier: String = ""
    @State private var typingSpoofBatteryLevel: String = ""
    @State private var spoofBatteryStateSelection: Int = 2
    @State private var spoofLowPowerModeEnabled: Bool = false
    @State private var typingSpoofSubscriberIdentifier: String = ""
    @State private var typingSpoofSubscriberCarrierTokenBase64: String = ""
    @State private var spoofSubscriberSIMInsertedEnabled: Bool = false
    @State private var spoofSubscriberSIMInserted: Bool = false
    @State private var typingSpoofRadioAccessTechnology: String = "CTRadioAccessTechnologyLTE"
    @State private var typingSpoofHardwareModel: String = ""
    @State private var inUse = false
    @State private var runningLC : String? = nil
    
    @State private var errorShow = false
    @State private var errorInfo = ""
    @State private var successShow = false
    @State private var successInfo = ""

    private var tweakLoaderDependentControlsEnabled: Bool {
        !delegate.isTweakLoaderInjectionDisabled()
    }
    
    init(container: LCContainer, uiDefaultDataFolder : Binding<String?>, delegate: LCContainerViewDelegate) {
        self._container = ObservedObject(initialValue: container)
        self.delegate = delegate
        self._typingContainerName = State(initialValue: container.name)
        self._typingSpoofDeviceName = State(initialValue: container.spoofDeviceName)
        self._typingSpoofDeviceModel = State(initialValue: container.spoofDeviceModel)
        self._typingSpoofSystemName = State(initialValue: container.spoofSystemName)
        self._typingSpoofSystemVersion = State(initialValue: container.spoofSystemVersion)
        self._typingSpoofLocaleIdentifier = State(initialValue: container.spoofLocaleIdentifier)
        self._typingSpoofTimeZoneIdentifier = State(initialValue: container.spoofTimeZoneIdentifier)
        self._typingSpoofBatteryLevel = State(initialValue: String(format: "%.2f", container.spoofBatteryLevel))
        self._spoofBatteryStateSelection = State(initialValue: container.spoofBatteryState)
        self._spoofLowPowerModeEnabled = State(initialValue: container.spoofLowPowerModeEnabled)
        self._typingSpoofSubscriberIdentifier = State(initialValue: container.spoofSubscriberIdentifier)
        self._typingSpoofSubscriberCarrierTokenBase64 = State(initialValue: container.spoofSubscriberCarrierTokenBase64)
        self._spoofSubscriberSIMInsertedEnabled = State(initialValue: container.spoofSubscriberSIMInsertedEnabled)
        self._spoofSubscriberSIMInserted = State(initialValue: container.spoofSubscriberSIMInserted)
        self._typingSpoofRadioAccessTechnology = State(initialValue: container.spoofRadioAccessTechnology.isEmpty ? "CTRadioAccessTechnologyLTE" : container.spoofRadioAccessTechnology)
        self._typingSpoofHardwareModel = State(initialValue: container.spoofHardwareModel)
        self._uiDefaultDataFolder = Binding(projectedValue: uiDefaultDataFolder)
    }
    
    var body: some View {
        Form {
            if !(container.storageBookMark != nil && container.resolvedContainerURL == nil) {
                
                Section {
                    HStack {
                        Text("lc.container.containerName".loc)
                        Spacer()
                        TextField("lc.container.containerName".loc, text: $typingContainerName)
                            .multilineTextAlignment(.trailing)
                            .onSubmit {
                                container.name = typingContainerName
                                saveContainer()
                            }
                    }
                    HStack {
                        Text("lc.container.containerFolderName".loc)
                        Spacer()
                        Text(container.folderName)
                            .foregroundStyle(.gray)
                    }
                    Toggle(isOn: $container.isolateAppGroup) {
                        Text("lc.container.isolateAppGroup".loc)
                    }
                    .disabled(container.strictTestMode)
                    .onChange(of: container.isolateAppGroup) { newValue in
                        saveContainer()
                    }
                    
                    if let settingsBundle {
                        NavigationLink {
                            AppPreferenceView(bundleId: delegate.getBundleId(), settingsBundle: settingsBundle, containerURL: delegate.getContainerURL(container: container))
                        } label: {
                            Text("lc.container.preferences".loc)
                        }
                    }
                    if container.folderName == uiDefaultDataFolder {
                        Text("lc.container.alreadyDefaultContainer".loc)
                            .foregroundStyle(.gray)
                    } else {
                        Button {
                            setAsDefault()
                        } label: {
                            Text("lc.container.setDefaultContainer".loc)
                        }
                    }
                } footer: {
                    Text("lc.container.defaultContainerDesc".loc)
                }

                Section {
                    Toggle("Strict Test Mode", isOn: $container.strictTestMode)
                        .disabled(!tweakLoaderDependentControlsEnabled)
                        .onChange(of: container.strictTestMode) { _ in
                            saveStrictModeSettings()
                        }

                    if container.strictTestMode {
                        Toggle("Auto-Wipe Container on App Exit", isOn: $container.strictAutoWipeOnExit)
                            .disabled(!tweakLoaderDependentControlsEnabled)
                            .onChange(of: container.strictAutoWipeOnExit) { _ in
                                saveContainer()
                            }
                    }
                } header: {
                    Text("Strict Test Mode")
                } footer: {
                    if tweakLoaderDependentControlsEnabled {
                        Text("Aggressive isolation for app testing: forces app-group isolation, blocks common external URL/network paths, and can auto-wipe this container on exit.")
                    } else {
                        Text("Strict Test Mode requires TweakLoader injection. Disable Don't Inject TweakLoader in App Settings to use this.")
                    }
                }
                                
                Section {
                    Toggle(isOn: $container.spoofIdentifierForVendor) {
                        Text("lc.container.spoofIdentifierForVendor".loc)
                    }
                    .onChange(of: container.spoofIdentifierForVendor) { newValue in
                        saveContainer()
                    }
                    
                    if container.spoofIdentifierForVendor {
                        HStack {
                            Text("UUID")
                            TextField("lc.common.auto".loc, text: $typingIDFV)
                                .multilineTextAlignment(.trailing)
                                .onSubmit {
                                    saveIDFV()
                                }
                        }
                    }
                }

                Section {
                    if inUse {
                        Text("lc.container.inUse".loc)
                            .foregroundStyle(.gray)
                        
                    } else {
                        if !container.isShared || container.storageBookMark != nil {
                            Button {
                                openDataFolder()
                            } label: {
                                Text("lc.appBanner.openDataFolder".loc)
                            }
                            Button {
                                unbindContainer()
                            } label: {
                                Text("lc.container.unbind".loc)
                            }
                        }
                        Button(role:.destructive) {
                            Task { await deleteData() }
                        } label: {
                            Text("lc.container.deleteData".loc)
                        }
                        
                        Button(role:.destructive) {
                            Task { await cleanUpKeychain() }
                        } label: {
                            Text("lc.settings.cleanKeychain".loc)
                        }
                        
                        if(container.storageBookMark == nil) {
                            Button(role:.destructive) {
                                Task { await removeContainer() }
                            } label: {
                                Text("lc.container.removeContainer".loc)
                            }
                        }
                        
                    }
                }
            } else {
                Section {
                    if container.bookmarkResolved {
                        Text("lc.container.externalStorageUnavailable".loc)
                    } else {
                        Text("lc.container.bookmarkResolveInProgress".loc)
                    }

                }
                
                Section {
                    Button(role:.destructive) {
                        Task { await removeContainer() }
                    } label: {
                        Text("lc.container.removeContainer".loc)
                    }
                }
            }
        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("lc.common.error".loc, isPresented: $errorShow){
        } message: {
            Text(errorInfo)
        }
        .alert("lc.common.success".loc, isPresented: $successShow){
        } message: {
            Text(successInfo)
        }
        
        .alert("lc.container.removeContainer".loc, isPresented: $removeContainerAlert.show) {
            Button(role: .destructive) {
                removeContainerAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeContainerAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeContainerDesc".loc)
        }
        
        .alert("lc.container.deleteData".loc, isPresented: $deleteDataAlert.show) {
            Button(role: .destructive) {
                deleteDataAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                deleteDataAlert.close(result: false)
            }
        } message: {
            Text("lc.container.deleteDataDesc".loc)
        }
        
        .alert("lc.settings.cleanKeychain".loc, isPresented: $removeKeychainAlert.show) {
            Button(role: .destructive) {
                removeKeychainAlert.close(result: true)
            } label: {
                Text("lc.common.delete".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                removeKeychainAlert.close(result: false)
            }
        } message: {
            Text("lc.container.removeKeychainDesc".loc)
        }
        .onAppear() {
            container.reloadInfoPlist()
            if container.strictTestMode {
                container.isolateAppGroup = true
                container.blockDeviceInfoReads = true
            }
            if let spoofedIDFV = container.spoofedIdentifier {
                typingIDFV = spoofedIDFV
            }
            typingSpoofDeviceName = container.spoofDeviceName
            typingSpoofDeviceModel = container.spoofDeviceModel
            typingSpoofSystemName = container.spoofSystemName
            typingSpoofSystemVersion = container.spoofSystemVersion
            typingSpoofLocaleIdentifier = container.spoofLocaleIdentifier
            typingSpoofTimeZoneIdentifier = container.spoofTimeZoneIdentifier
            typingSpoofBatteryLevel = String(format: "%.2f", container.spoofBatteryLevel)
            spoofBatteryStateSelection = container.spoofBatteryState
            spoofLowPowerModeEnabled = container.spoofLowPowerModeEnabled
            typingSpoofSubscriberIdentifier = container.spoofSubscriberIdentifier
            typingSpoofSubscriberCarrierTokenBase64 = container.spoofSubscriberCarrierTokenBase64
            spoofSubscriberSIMInsertedEnabled = container.spoofSubscriberSIMInsertedEnabled
            spoofSubscriberSIMInserted = container.spoofSubscriberSIMInserted
            typingSpoofRadioAccessTechnology = container.spoofRadioAccessTechnology.isEmpty ? "CTRadioAccessTechnologyLTE" : container.spoofRadioAccessTechnology
            typingSpoofHardwareModel = container.spoofHardwareModel
            settingsBundle = delegate.getSettingsBundle()
            runningLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName)
            inUse = runningLC != nil
        }
        
    }
        
    func saveIDFV() {
        guard let newIDFV = UUID(uuidString: typingIDFV) else {
            errorInfo = "lc.container.invalidIDFV".loc
            errorShow = true
            return
        }
        container.spoofedIdentifier = newIDFV.uuidString
        delegate.saveContainer(container: container)
    }

    func saveContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        
        delegate.saveContainer(container: container)
    }

    func saveStrictModeSettings() {
        if container.strictTestMode {
            container.isolateAppGroup = true
            container.blockDeviceInfoReads = true
        }
        saveContainer()
    }
    
    func openDataFolder() {
        let url = URL(string:"shareddocuments://\(LCPath.dataPath.path)/\(container.folderName)")
        UIApplication.shared.open(url!)
    }
    
    func setAsDefault() {
        delegate.setDefaultContainer(container: container)
    }
    
    func removeContainer() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeContainerAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            try fm.removeItem(at: container.containerURL)
            LCUtils.removeAppKeychain(dataUUID: container.folderName)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
        
        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    func unbindContainer() {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        
        dismiss()
        delegate.unbindContainer(container: container)
    }
    
    func cleanUpKeychain() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await removeKeychainAlert.open(), ans else {
            return
        }
        
        LCUtils.removeAppKeychain(dataUUID: container.folderName)
    }
    
    func deleteData() async {
        if let usingLC = LCSharedUtils.getContainerUsingLCScheme(withFolderName: container.folderName) {
            errorInfo = "lc.container.inUseBy %@".localizeWithFormat(usingLC)
            errorShow = true
            return
        }
        guard let ans = await deleteDataAlert.open(), ans else {
            return
        }
        do {
            let fm = FileManager.default
            for file in try fm.contentsOfDirectory(at: container.containerURL, includingPropertiesForKeys: nil) {
                if file.lastPathComponent == "LCContainerInfo.plist" {
                    continue
                }
                try fm.removeItem(at: file)
            }
            LCUtils.removeAppKeychain(dataUUID: container.folderName)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }
}
