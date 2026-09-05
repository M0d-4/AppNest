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
    
    init() {
        let fm = FileManager()
        var tempAppDataFolderNames : [String] = []
        var tempTweakFolderNames : [String] = []
        
        var tempApps: [LCAppModel] = []
        var tempArm32EmuApps: [LCAppModel] = []
        var tempHiddenApps: [LCAppModel] = []

        // Cleanup stale export temp artifacts from previous runs/interrupted shares.
        cleanupStaleExportArtifacts(fileManager: fm)

        // Pick up 32-bit translation-layer apps embedded in installed tweak packages
        // (e.g. LiveExec32's .deb) before scanning LCPath.bundlePath below, so they're
        // included in this pass instead of requiring a second relaunch.
        linkEmbedded32BitEmulatorAppsFromTweaks(fileManager: fm)

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
                let model = LCAppModel(appInfo: newApp)
                if newApp.isHidden {
                    tempHiddenApps.append(model)
                } else {
                    tempApps.append(LCAppModel(appInfo: newApp))
                }
                if newApp.is32bitEmulator {
                    tempArm32EmuApps.append(model)
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
                    let model = LCAppModel(appInfo: newApp)
                    if newApp.isHidden {
                        tempHiddenApps.append(model)
                    } else {
                        tempApps.append(LCAppModel(appInfo: newApp))
                    }
                    if newApp.is32bitEmulator {
                        tempArm32EmuApps.append(model)
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
                let folderName = tweakDir.hasSuffix(".disabled") ? String(tweakDir.dropLast(".disabled".count)) : tweakDir
                tempTweakFolderNames.append(folderName)
            }
        } catch {
            NSLog("[LC] error:\(error)")
        }
        
        DataManager.shared.model.apps = tempApps
        DataManager.shared.model.arm32EmuApps = tempArm32EmuApps
        DataManager.shared.model.hiddenApps = tempHiddenApps
        DataManager.shared.model.appDataFolderNames = tempAppDataFolderNames
        DataManager.shared.model.tweakFolderNames = tempTweakFolderNames
        DataManager.shared.model.syncSharedGuestURLIndex()
    }
    
    var body: some Scene {
        WindowGroup(id: "Main") {
            LCTabView()
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

// LiveExec32 and similar 32-bit translation-layer tweaks are distributed as a
// .deb whose payload embeds a full guest .app (flagged via LC32BitTranslationLayer
// in its own Info.plist, the same key AppNest uses for ipa-embedded translation
// layers) rather than as an importable .ipa. Packages installed through the
// tweaks section land under LCPath.tweakPath, which the "load apps" scan never
// looks inside, so such an app would be usable as an injectable tweak but
// invisible in the "default 32-bit emulator" picker (sharedModel.arm32EmuApps).
// This symlinks any embedded translation-layer .app into LCPath.bundlePath —
// idempotently, so repeat launches are a no-op — and marks it hidden so it
// shows up as an emulator choice without cluttering the main app grid.
private func linkEmbedded32BitEmulatorAppsFromTweaks(fileManager fm: FileManager) {
    try? fm.createDirectory(at: LCPath.tweakPath, withIntermediateDirectories: true)
    try? fm.createDirectory(at: LCPath.bundlePath, withIntermediateDirectories: true)

    guard let packageDirs = try? fm.contentsOfDirectory(at: LCPath.tweakPath, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return
    }
    let existingBundleLinks = (try? fm.contentsOfDirectory(at: LCPath.bundlePath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
    var linkedDestinations = Set(existingBundleLinks.compactMap { try? fm.destinationOfSymbolicLink(atPath: $0.path) })

    for packageDir in packageDirs {
        // Only deb-imported packages carry .lc-package.json; plain dylib/framework
        // tweaks dropped in manually can never embed a guest .app, so skip them.
        guard fm.fileExists(atPath: packageDir.appendingPathComponent(".lc-package.json").path) else {
            continue
        }
        guard let enumerator = fm.enumerator(at: packageDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            continue
        }
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension == "app" else { continue }
            enumerator.skipDescendants()

            guard let infoPlist = NSDictionary(contentsOf: item.appendingPathComponent("Info.plist")),
                  (infoPlist["LC32BitTranslationLayer"] as? Bool) == true else {
                continue
            }
            if linkedDestinations.contains(item.path) {
                continue
            }

            let baseName = item.deletingPathExtension().lastPathComponent
            var candidateName = "\(baseName).app"
            var index = 1
            while fm.fileExists(atPath: LCPath.bundlePath.appendingPathComponent(candidateName).path) {
                candidateName = "\(baseName)-\(index).app"
                index += 1
            }
            let linkURL = LCPath.bundlePath.appendingPathComponent(candidateName)

            do {
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: item)
            } catch {
                NSLog("[LC] Failed to link 32-bit emulator app %@: %@", item.lastPathComponent, error.localizedDescription)
                continue
            }
            linkedDestinations.insert(item.path)

            guard let emulatorAppInfo = LCAppInfo(bundlePath: linkURL.path) else { continue }
            emulatorAppInfo.relativeBundlePath = candidateName
            emulatorAppInfo.isShared = false
            emulatorAppInfo.isHidden = true
            emulatorAppInfo.save()
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
