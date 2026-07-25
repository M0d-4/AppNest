//
//  LCAppInfo.swift
//  AppNestSwiftUI
//
//  Created by s s on 2024/12/5.
//

import Foundation

class LCContainer : ObservableObject, Hashable {
    @Published var folderName : String
    @Published var name : String
    @Published var isShared : Bool
    
    @Published var storageBookMark: Data?
    @Published var resolvedContainerURL: URL?
    @Published var bookmarkResolved = false
    var bookmarkResolveContinuation: UnsafeContinuation<(), Never>? = nil
    
    @Published var isolateAppGroup : Bool

    @Published var spoofIdentifierForVendor : Bool {
        didSet {
            if spoofIdentifierForVendor && spoofedIdentifier == nil {
                spoofedIdentifier = UUID().uuidString
            }
        }
    }
    public var spoofedIdentifier: String?
    @Published var strictTestMode: Bool
    @Published var strictAutoWipeOnExit: Bool
    @Published var blockDeviceInfoReads: Bool
    @Published var spoofProfileEnabled: Bool
    @Published var spoofDeviceName: String
    @Published var spoofDeviceModel: String
    @Published var spoofSystemName: String
    @Published var spoofSystemVersion: String
    @Published var spoofLocaleIdentifier: String
    @Published var spoofTimeZoneIdentifier: String
    @Published var spoofBatteryLevel: Double
    @Published var spoofBatteryState: Int
    @Published var spoofLowPowerModeEnabled: Bool
    @Published var spoofSubscriberIdentifier: String
    @Published var spoofSubscriberCarrierTokenBase64: String
    @Published var spoofSubscriberSIMInsertedEnabled: Bool
    @Published var spoofSubscriberSIMInserted: Bool
    @Published var spoofRadioAccessTechnology: String
    @Published var spoofHardwareModel: String
    private var infoDict : [String:Any]?
    
    public var containerURL : URL {
        if let resolvedContainerURL {
            return resolvedContainerURL
        }
        
        if isShared {
            return LCPath.lcGroupDataPath.appendingPathComponent("\(folderName)")
        } else {
            return LCPath.dataPath.appendingPathComponent("\(folderName)")
        }
    }
    private var infoDictUrl : URL {
        return containerURL.appendingPathComponent("LCContainerInfo.plist")
    }
    public var keychainGroupId : Int {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return -1
            }
            return infoDict["keychainGroupId"] as? Int ?? -1
        }
    }
    
    public var appIdentifier : String? {
        get {
            if infoDict == nil {
                infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
            }
            guard let infoDict else {
                return nil
            }
            return infoDict["appIdentifier"] as? String ?? nil
        }
    }
    
    init(
        folderName: String,
        name: String,
        isShared : Bool,
        isolateAppGroup: Bool = false,
        spoofIdentifierForVendor: Bool = false,
        strictTestMode: Bool = false,
        strictAutoWipeOnExit: Bool = false,
        blockDeviceInfoReads: Bool = false,
        spoofProfileEnabled: Bool = false,
        spoofDeviceName: String = "",
        spoofDeviceModel: String = "",
        spoofSystemName: String = "",
        spoofSystemVersion: String = "",
        spoofLocaleIdentifier: String = "",
        spoofTimeZoneIdentifier: String = "",
        spoofBatteryLevel: Double = 0.8,
        spoofBatteryState: Int = 2,
        spoofLowPowerModeEnabled: Bool = false,
        spoofSubscriberIdentifier: String = "",
        spoofSubscriberCarrierTokenBase64: String = "",
        spoofSubscriberSIMInsertedEnabled: Bool = false,
        spoofSubscriberSIMInserted: Bool = false,
        spoofRadioAccessTechnology: String = "",
        spoofHardwareModel: String = "",
        bookmarkData: Data? = nil,
        resolvedContainerURL: URL? = nil
    ) {
        self.folderName = folderName
        self.name = name
        self.isShared = isShared
        self.isolateAppGroup = isolateAppGroup
        self.spoofIdentifierForVendor = spoofIdentifierForVendor
        self.strictTestMode = strictTestMode
        self.strictAutoWipeOnExit = strictAutoWipeOnExit
        self.blockDeviceInfoReads = blockDeviceInfoReads
        self.spoofProfileEnabled = spoofProfileEnabled
        self.spoofDeviceName = spoofDeviceName
        self.spoofDeviceModel = spoofDeviceModel
        self.spoofSystemName = spoofSystemName
        self.spoofSystemVersion = spoofSystemVersion
        self.spoofLocaleIdentifier = spoofLocaleIdentifier
        self.spoofTimeZoneIdentifier = spoofTimeZoneIdentifier
        self.spoofBatteryLevel = spoofBatteryLevel
        self.spoofBatteryState = spoofBatteryState
        self.spoofLowPowerModeEnabled = spoofLowPowerModeEnabled
        self.spoofSubscriberIdentifier = spoofSubscriberIdentifier
        self.spoofSubscriberCarrierTokenBase64 = spoofSubscriberCarrierTokenBase64
        self.spoofSubscriberSIMInsertedEnabled = spoofSubscriberSIMInsertedEnabled
        self.spoofSubscriberSIMInserted = spoofSubscriberSIMInserted
        self.spoofRadioAccessTechnology = spoofRadioAccessTechnology
        self.spoofHardwareModel = spoofHardwareModel
        self.storageBookMark = bookmarkData
        self.resolvedContainerURL = resolvedContainerURL
    }
    
    convenience init(infoDict : [String : Any], isShared : Bool) {
        let bookmarkData : Data? = infoDict["bookmarkData"] as? Data
        
        self.init(folderName: infoDict["folderName"] as? String ?? "ERROR",
                  name: infoDict["name"] as? String ?? "ERROR",
                  isShared: isShared,
                  isolateAppGroup: infoDict["isolateAppGroup"] as? Bool ?? true,
                  spoofIdentifierForVendor: infoDict["spoofIdentifierForVendor"] as? Bool ?? false,
                  strictTestMode: infoDict["strictTestMode"] as? Bool ?? false,
                  strictAutoWipeOnExit: infoDict["strictAutoWipeOnExit"] as? Bool ?? false,
                  blockDeviceInfoReads: infoDict["blockDeviceInfoReads"] as? Bool ?? false,
                  spoofProfileEnabled: infoDict["spoofProfileEnabled"] as? Bool ?? false,
                  spoofDeviceName: infoDict["spoofDeviceName"] as? String ?? "",
                  spoofDeviceModel: infoDict["spoofDeviceModel"] as? String ?? "",
                  spoofSystemName: infoDict["spoofSystemName"] as? String ?? "",
                  spoofSystemVersion: infoDict["spoofSystemVersion"] as? String ?? "",
                  spoofLocaleIdentifier: infoDict["spoofLocaleIdentifier"] as? String ?? "",
                  spoofTimeZoneIdentifier: infoDict["spoofTimeZoneIdentifier"] as? String ?? "",
                  spoofBatteryLevel: infoDict["spoofBatteryLevel"] as? Double ?? 0.8,
                  spoofBatteryState: infoDict["spoofBatteryState"] as? Int ?? 2,
                  spoofLowPowerModeEnabled: infoDict["spoofLowPowerModeEnabled"] as? Bool ?? false,
                  spoofSubscriberIdentifier: infoDict["spoofSubscriberIdentifier"] as? String ?? "",
                  spoofSubscriberCarrierTokenBase64: infoDict["spoofSubscriberCarrierTokenBase64"] as? String ?? "",
                  spoofSubscriberSIMInsertedEnabled: infoDict["spoofSubscriberSIMInsertedEnabled"] as? Bool ?? false,
                  spoofSubscriberSIMInserted: infoDict["spoofSubscriberSIMInserted"] as? Bool ?? false,
                  spoofRadioAccessTechnology: infoDict["spoofRadioAccessTechnology"] as? String ?? "",
                  spoofHardwareModel: infoDict["spoofHardwareModel"] as? String ?? "",
                  bookmarkData: bookmarkData,
                  resolvedContainerURL: nil
        )
        
        if let bookmarkData {

                do {
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)

                    self.resolvedContainerURL = url

                } catch {
                    print(error.localizedDescription)
                }

                self.bookmarkResolved = true
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistInfo = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoDictUrl), format: nil)
            if let plistInfo = plistInfo as? [String : Any] {
                isolateAppGroup = plistInfo["isolateAppGroup"] as? Bool ?? true
                spoofIdentifierForVendor = plistInfo["spoofIdentifierForVendor"] as? Bool ?? false
                spoofedIdentifier = plistInfo["spoofedIdentifierForVendor"] as? String
                strictTestMode = plistInfo["strictTestMode"] as? Bool ?? false
                strictAutoWipeOnExit = plistInfo["strictAutoWipeOnExit"] as? Bool ?? false
                blockDeviceInfoReads = plistInfo["blockDeviceInfoReads"] as? Bool ?? false
                spoofProfileEnabled = plistInfo["spoofProfileEnabled"] as? Bool ?? false
                spoofDeviceName = plistInfo["spoofDeviceName"] as? String ?? ""
                spoofDeviceModel = plistInfo["spoofDeviceModel"] as? String ?? ""
                spoofSystemName = plistInfo["spoofSystemName"] as? String ?? ""
                spoofSystemVersion = plistInfo["spoofSystemVersion"] as? String ?? ""
                spoofLocaleIdentifier = plistInfo["spoofLocaleIdentifier"] as? String ?? ""
                spoofTimeZoneIdentifier = plistInfo["spoofTimeZoneIdentifier"] as? String ?? ""
                spoofBatteryLevel = plistInfo["spoofBatteryLevel"] as? Double ?? 0.8
                spoofBatteryState = plistInfo["spoofBatteryState"] as? Int ?? 2
                spoofLowPowerModeEnabled = plistInfo["spoofLowPowerModeEnabled"] as? Bool ?? false
                spoofSubscriberIdentifier = plistInfo["spoofSubscriberIdentifier"] as? String ?? ""
                spoofSubscriberCarrierTokenBase64 = plistInfo["spoofSubscriberCarrierTokenBase64"] as? String ?? ""
                spoofSubscriberSIMInsertedEnabled = plistInfo["spoofSubscriberSIMInsertedEnabled"] as? Bool ?? false
                spoofSubscriberSIMInserted = plistInfo["spoofSubscriberSIMInserted"] as? Bool ?? false
                spoofRadioAccessTechnology = plistInfo["spoofRadioAccessTechnology"] as? String ?? ""
                spoofHardwareModel = plistInfo["spoofHardwareModel"] as? String ?? ""
            }
        } catch {
            
        }
    }
    
    func toDict() -> [String : Any] {
        var ans : [String: Any] = [
            "folderName" : folderName,
            "name" : name
        ]
        if let storageBookMark {
            ans["bookmarkData"] = storageBookMark
        }
        return ans
    }
    
    func makeLCContainerInfoPlist(appIdentifier : String, keychainGroupId : Int) {
        infoDict = [
            "appIdentifier" : appIdentifier,
            "name" : name,
            "keychainGroupId" : keychainGroupId,
            "isolateAppGroup" : isolateAppGroup,
            "spoofIdentifierForVendor": spoofIdentifierForVendor,
            "strictTestMode": strictTestMode,
            "strictAutoWipeOnExit": strictAutoWipeOnExit,
            "blockDeviceInfoReads": blockDeviceInfoReads,
            "spoofProfileEnabled": spoofProfileEnabled
        ]
        if let spoofedIdentifier {
            infoDict!["spoofedIdentifierForVendor"] = spoofedIdentifier
        }
        if !spoofDeviceName.isEmpty {
            infoDict!["spoofDeviceName"] = spoofDeviceName
        }
        if !spoofDeviceModel.isEmpty {
            infoDict!["spoofDeviceModel"] = spoofDeviceModel
        }
        if !spoofSystemName.isEmpty {
            infoDict!["spoofSystemName"] = spoofSystemName
        }
        if !spoofSystemVersion.isEmpty {
            infoDict!["spoofSystemVersion"] = spoofSystemVersion
        }
        if !spoofLocaleIdentifier.isEmpty {
            infoDict!["spoofLocaleIdentifier"] = spoofLocaleIdentifier
        }
        if !spoofTimeZoneIdentifier.isEmpty {
            infoDict!["spoofTimeZoneIdentifier"] = spoofTimeZoneIdentifier
        }
        infoDict!["spoofBatteryLevel"] = spoofBatteryLevel
        infoDict!["spoofBatteryState"] = spoofBatteryState
        infoDict!["spoofLowPowerModeEnabled"] = spoofLowPowerModeEnabled
        if !spoofSubscriberIdentifier.isEmpty {
            infoDict!["spoofSubscriberIdentifier"] = spoofSubscriberIdentifier
        }
        if !spoofSubscriberCarrierTokenBase64.isEmpty {
            infoDict!["spoofSubscriberCarrierTokenBase64"] = spoofSubscriberCarrierTokenBase64
        }
        infoDict!["spoofSubscriberSIMInsertedEnabled"] = spoofSubscriberSIMInsertedEnabled
        infoDict!["spoofSubscriberSIMInserted"] = spoofSubscriberSIMInserted
        if !spoofRadioAccessTechnology.isEmpty {
            infoDict!["spoofRadioAccessTechnology"] = spoofRadioAccessTechnology
        }
        if !spoofHardwareModel.isEmpty {
            infoDict!["spoofHardwareModel"] = spoofHardwareModel
        }
        
        do {
            let fm = FileManager.default
            if(!fm.fileExists(atPath: infoDictUrl.deletingLastPathComponent().path)) {
                try fm.createDirectory(at: infoDictUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            
            let plistData = try PropertyListSerialization.data(fromPropertyList: infoDict as Any, format: .binary, options: 0)
            try plistData.write(to: infoDictUrl)
        } catch {
            
        }
    }
    
    func reloadInfoPlist() {
        infoDict = NSDictionary(contentsOf: infoDictUrl) as? [String : Any]
    }

    func loadName() {
        reloadInfoPlist()
        guard let infoDict else {
            return
        }
        name = infoDict["name"] as? String ?? "ERROR"
        isolateAppGroup = infoDict["isolateAppGroup"] as? Bool ?? true
        spoofIdentifierForVendor = infoDict["spoofIdentifierForVendor"] as? Bool ?? false
        spoofedIdentifier = infoDict["spoofedIdentifierForVendor"] as? String
        strictTestMode = infoDict["strictTestMode"] as? Bool ?? false
        strictAutoWipeOnExit = infoDict["strictAutoWipeOnExit"] as? Bool ?? false
        blockDeviceInfoReads = infoDict["blockDeviceInfoReads"] as? Bool ?? false
        spoofProfileEnabled = infoDict["spoofProfileEnabled"] as? Bool ?? false
        spoofDeviceName = infoDict["spoofDeviceName"] as? String ?? ""
        spoofDeviceModel = infoDict["spoofDeviceModel"] as? String ?? ""
        spoofSystemName = infoDict["spoofSystemName"] as? String ?? ""
        spoofSystemVersion = infoDict["spoofSystemVersion"] as? String ?? ""
        spoofLocaleIdentifier = infoDict["spoofLocaleIdentifier"] as? String ?? ""
        spoofTimeZoneIdentifier = infoDict["spoofTimeZoneIdentifier"] as? String ?? ""
        spoofBatteryLevel = infoDict["spoofBatteryLevel"] as? Double ?? 0.8
        spoofBatteryState = infoDict["spoofBatteryState"] as? Int ?? 2
        spoofLowPowerModeEnabled = infoDict["spoofLowPowerModeEnabled"] as? Bool ?? false
        spoofSubscriberIdentifier = infoDict["spoofSubscriberIdentifier"] as? String ?? ""
        spoofSubscriberCarrierTokenBase64 = infoDict["spoofSubscriberCarrierTokenBase64"] as? String ?? ""
        spoofSubscriberSIMInsertedEnabled = infoDict["spoofSubscriberSIMInsertedEnabled"] as? Bool ?? false
        spoofSubscriberSIMInserted = infoDict["spoofSubscriberSIMInserted"] as? Bool ?? false
        spoofRadioAccessTechnology = infoDict["spoofRadioAccessTechnology"] as? String ?? ""
        spoofHardwareModel = infoDict["spoofHardwareModel"] as? String ?? ""
    }
    
    static func == (lhs: LCContainer, rhs: LCContainer) -> Bool {
        return lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension LCAppInfo {
    var containers : [LCContainer] {
        get {
            if self is BuiltInSideStoreAppInfo {
                let container = LCContainer(folderName: "", name: "SideStore", isShared: false)
                container.resolvedContainerURL = LCPath.docPath.appendingPathComponent("SideStore")
                return [container]
            }
            
            var upgrade = false
            // upgrade
            if let oldDataUUID = dataUUID, containerInfo == nil {
                containerInfo = [[
                    "folderName": oldDataUUID,
                    "name": oldDataUUID,
                    "isolateAppGroup": true,
                    "spoofIdentifierForVendor": false,
                ]]
                upgrade = true
            }
            let dictArr = containerInfo as? [[String : Any]] ?? []
            return dictArr.map{ dict in
                let ans = LCContainer(infoDict: dict, isShared: isShared)
                if upgrade {
                    ans.makeLCContainerInfoPlist(appIdentifier: bundleIdentifier()!, keychainGroupId: 0)
                }
                return ans
            }
        }
        set {
            containerInfo = newValue.map { container in
                return container.toDict()
            }
        }
    }
}
