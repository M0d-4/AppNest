//
//  LiveContainerSwiftUIApp.swift
//  LiveContainer
//
//  Created by s s on 2025/5/16.
//
import SwiftUI

@main
struct LiveContainerSwiftUIApp : SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    @State var appDataFolderNames: [String]
    @State var tweakFolderNames: [String]
    
    init() {
        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []

        
        // Cleanup stale export temp artifacts from previous runs/interrupted shares.
        cleanupStaleExportArtifacts(fileManager: fm)

        do {
            // load apps
            try fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)
            let appDirs = try fm.contentsOfDirectory(atPath: LCPath.bundlePath.path)
            for appDir in appDirs {
                if !appDir.hasSuffix(".app") {
                    continue
                }
                let newApp = LCAppInfo(bundlePath: "\(LCPath.bundlePath.path)/\(appDir)")!
                newApp.relativeBundlePath = appDir
                newApp.isShared = false
                if newApp.isHidden {
                    tempHiddenApps.append(LCAppModel(appInfo: newApp))
                } else {
                    tempApps.append(LCAppModel(appInfo: newApp))
                }
            }
            if LCPath.lcGroupDocPath != LCPath.docPath {
                try fm.createDirectory(at: LCPath.lcGroupBundlePath, withIntermediateDirectories: true)
                let appDirsShared = try fm.contentsOfDirectory(atPath: LCPath.lcGroupBundlePath.path)
                for appDir in appDirsShared {
                    if !appDir.hasSuffix(".app") {
                        continue
                    }
                    let newApp = LCAppInfo(bundlePath: "\(LCPath.lcGroupBundlePath.path)/\(appDir)")!
                    newApp.relativeBundlePath = appDir
                    newApp.isShared = true
                    if newApp.isHidden {
                        tempHiddenApps.append(LCAppModel(appInfo: newApp))
                    } else {
                        tempApps.append(LCAppModel(appInfo: newApp))
                    }
                }
            }
            // load document folders
            try fm.createDirectory(at: LCPath.dataPath, withIntermediateDirectories: true)
            let dataDirs = try fm.contentsOfDirectory(atPath: LCPath.dataPath.path)
            for dataDir in dataDirs {
                let dataDirUrl = LCPath.dataPath.appendingPathComponent(dataDir)
                if !dataDirUrl.hasDirectoryPath {
                    continue
                }
                tempAppDataFolderNames.append(dataDir)
            }
            
            // load tweak folders
            try fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
            let tweakDirs = try fm.contentsOfDirectory(atPath: LCPath.tweakPath.path)
            for tweakDir in tweakDirs {
                let tweakDirUrl = LCPath.tweakPath.appendingPathComponent(tweakDir)
                if !tweakDirUrl.hasDirectoryPath {
                    continue
                }
                tempTweakFolderNames.append(tweakDir)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }
        
        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        DataManager.shared.model.syncSharedGuestURLIndex()
        
        _appDataFolderNames = State(initialValue: tempAppDataFolderNames)
        _tweakFolderNames = State(initialValue: tempTweakFolderNames)
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView(appDataFolderNames: $appDataFolderNames, tweakFolderNames: $tweakFolderNames)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environmentObject(DataManager.shared.model)
                .environmentObject(LCAppSortManager.shared)
        }
        
        if UIApplication.shared.supportsMultipleScenes, #available(iOS 16.1, *) {
            WindowGroup(id: "appView", for: String.self) { $id in
                if let id {
                    MultitaskAppWindow(id: id)
                }
            }

        }
    }
    
}

private func cleanupStaleExportArtifacts(fileManager: FileManager) {
    let exportDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent("LCExports", isDirectory: true)
    if fileManager.fileExists(atPath: exportDirectoryURL.path) {
        try? fileManager.removeItem(at: exportDirectoryURL)
    }

    // Legacy staging folders used during export creation.
    let legacyPrefixes = ["LCAppExport-", "LCDataExport-", "LCBinaryExport-"]
    let tempRoot = fileManager.temporaryDirectory
    guard let tempItems = try? fileManager.contentsOfDirectory(
        at: tempRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return
    }

    for itemURL in tempItems {
        let name = itemURL.lastPathComponent
        if legacyPrefixes.contains(where: { name.hasPrefix($0) }) {
            try? fileManager.removeItem(at: itemURL)
        }
    }
}
