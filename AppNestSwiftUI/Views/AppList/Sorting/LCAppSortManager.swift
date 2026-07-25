//
//  LCAppSortManager.swift
//  AppNest
//
//  Created by boa-z on 2025/6/22.
//

import Foundation
import SwiftUI
import Combine

enum AppSortType: String, CaseIterable {
    case defaultOrder = "default"
    case alphabetical = "alphabetical"
    case reverseAlphabetical = "reverse_alphabetical"
    case lastLaunched = "last_launched"
    case installationDate = "installationDate"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .defaultOrder:
            return "lc.common.default".loc
        case .alphabetical:
            return "lc.appList.sort.alphabetical".loc
        case .reverseAlphabetical:
            return "lc.appList.sort.reverseAlphabetical".loc
        case .lastLaunched:
            return "lc.appList.sort.lastLaunched".loc
        case .installationDate:
            return "lc.appList.sort.installationDate".loc
        case .custom:
            return "lc.appList.sort.custom".loc
        }
    }
    
    var systemImage: String {
        switch self {
        case .defaultOrder:
            return "ellipsis"
        case .alphabetical:
            return "chevron.down"
        case .reverseAlphabetical:
            return "chevron.up"
        case .lastLaunched:
            return "clock"
        case .installationDate:
            if #available(iOS 18.0, *) {
                return "square.and.arrow.down.badge.clock"
            } else {
                return "square.and.arrow.down"
            }
        case .custom:
            return "list.bullet"
        }
    }
}

/// Manages the state and logic for sorting the list of applications.
class LCAppSortManager: ObservableObject {
    
    static var shared: LCAppSortManager = LCAppSortManager()
    
    @AppStorage("LCAppSortType", store: LCUtils.appGroupUserDefault) var appSortType: AppSortType = .defaultOrder {
        didSet {
            self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            if DataManager.shared.model.isHiddenAppUnlocked {
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
        }
    }

    @Published var customSortOrder: [String] {
        didSet {
            LCUtils.appGroupUserDefault.set(customSortOrder, forKey: "LCCustomSortOrder")
        }
    }
    
    @Published var sortedApps : [LCAppModel] = []
    @Published var sortedHiddenApps : [LCAppModel] = []
    
    private var cancellables = Set<AnyCancellable>()
    // MARK: - Initialization
    
    init() {
        self.customSortOrder = LCUtils.appGroupUserDefault.array(forKey: "LCCustomSortOrder") as? [String] ?? []
        
        DataManager.shared.model.$apps
            .sink { newValue in
                self.sortedApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            .store(in: &cancellables)
        
        DataManager.shared.model.$hiddenApps
            .sink { newValue in
                self.sortedHiddenApps = self.getSortedApps(newValue, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            .store(in: &cancellables)
        
        $customSortOrder
            .sink { newValue in
                if self.appSortType == .custom {
                    self.sortedApps = self.getSortedApps(DataManager.shared.model.apps, sortType: self.appSortType, customSortOrder: newValue)
                    if DataManager.shared.model.isHiddenAppUnlocked {
                        self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: newValue)
                    }
                }
            }
            .store(in: &cancellables)
        DataManager.shared.model.$isHiddenAppUnlocked
            .sink { newValue in
                if(!newValue) {
                    return
                }
                self.sortedHiddenApps = self.getSortedApps(DataManager.shared.model.hiddenApps, sortType: self.appSortType, customSortOrder: self.customSortOrder)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Internal Logic
    
    func getUniqueIdentifier(for app: LCAppModel) -> String? {
        guard let bundleId = app.appInfo.bundleIdentifier(),
              let relativePath = app.appInfo.relativeBundlePath else {
            return nil
        }
        return "\(bundleId):\(relativePath)"
    }
    
    func matches(uniqueId: String, app: LCAppModel) -> Bool {
        guard let appUniqueId = getUniqueIdentifier(for: app) else {
            return false
        }
        return uniqueId == appUniqueId
    }
    
    func getSortedApps(_ appList: [LCAppModel], sortType: AppSortType, customSortOrder: [String]) -> [LCAppModel] {
        switch sortType {
        case .defaultOrder:
            return appList
        case .alphabetical:
            return appList.sorted { $0.appInfo.displayName() < $1.appInfo.displayName() }
            
        case .reverseAlphabetical:
            return appList.sorted { $0.appInfo.displayName() > $1.appInfo.displayName() }
            
        case .lastLaunched:
            let appsWithLaunchDate = appList.compactMap { app -> (LCAppModel, Date)? in
                guard let launchDate = app.appInfo.lastLaunched else { return nil }
                return (app, launchDate)
            }
            .sorted { $0.1 > $1.1 } // Sort by date, newest first
            .map { $0.0 } // Extract just the app models

            let appsWithoutLaunchDate = appList.filter { app in
                return app.appInfo.lastLaunched == nil
            }
            
            return appsWithLaunchDate + appsWithoutLaunchDate
            
        case .installationDate:
            let appsWithinstallationDate = appList.compactMap { app -> (LCAppModel, Date)? in
                guard let installationDate = app.appInfo.installationDate else { return nil }
                return (app, installationDate)
            }
            .sorted { $0.1 > $1.1 } // Sort by date, newest first
            .map { $0.0 } // Extract just the app models

            let appsWithoutInstallationDate = appList.filter { app in
                return app.appInfo.installationDate == nil
            }
            
            return appsWithinstallationDate + appsWithoutInstallationDate
        case .custom:
            return sortByCustomOrder(appList, customSortOrder: customSortOrder)
        }
    }
    
    func moveCustomSortApp(_ draggingApp: LCAppModel, before targetApp: LCAppModel, visibleApps: [LCAppModel], hiddenApps: [LCAppModel]) {
        moveCustomSortApp(draggingApp, targetApp: targetApp, visibleApps: visibleApps, hiddenApps: hiddenApps) { apps, sourceIndex, targetApp in
            let movingApp = apps.remove(at: sourceIndex)
            guard let destinationIndex = apps.firstIndex(of: targetApp) else {
                return
            }
            apps.insert(movingApp, at: destinationIndex)
        }
    }
    
    func moveCustomSortApp(_ draggingApp: LCAppModel, after targetApp: LCAppModel, visibleApps: [LCAppModel], hiddenApps: [LCAppModel]) {
        moveCustomSortApp(draggingApp, targetApp: targetApp, visibleApps: visibleApps, hiddenApps: hiddenApps) { apps, sourceIndex, targetApp in
            let movingApp = apps.remove(at: sourceIndex)
            guard let destinationIndex = apps.firstIndex(of: targetApp) else {
                return
            }
            apps.insert(movingApp, at: destinationIndex + 1)
        }
    }
    
    func moveCustomSortApp(_ draggingApp: LCAppModel, toDestinationIndex destinationIndex: Int, in apps: [LCAppModel], visibleApps: [LCAppModel], hiddenApps: [LCAppModel]) {
        guard let sourceIndex = apps.firstIndex(of: draggingApp),
              destinationIndex != sourceIndex,
              destinationIndex != sourceIndex + 1 else {
            return
        }
        
        if destinationIndex >= apps.count {
            guard let targetApp = apps.last else {
                return
            }
            moveCustomSortApp(draggingApp, after: targetApp, visibleApps: visibleApps, hiddenApps: hiddenApps)
            return
        }
        
        moveCustomSortApp(draggingApp, before: apps[destinationIndex], visibleApps: visibleApps, hiddenApps: hiddenApps)
    }
    
    private func moveCustomSortApp(_ draggingApp: LCAppModel, targetApp: LCAppModel, visibleApps: [LCAppModel], hiddenApps: [LCAppModel], move: (inout [LCAppModel], Int, LCAppModel) -> Void) {
        var visibleSortedApps = getSortedApps(visibleApps, sortType: appSortType, customSortOrder: customSortOrder)
        var hiddenSortedApps = getSortedApps(hiddenApps, sortType: appSortType, customSortOrder: customSortOrder)
        
        if let sourceIndex = visibleSortedApps.firstIndex(of: draggingApp),
           visibleSortedApps.contains(targetApp) {
            move(&visibleSortedApps, sourceIndex, targetApp)
        } else if let sourceIndex = hiddenSortedApps.firstIndex(of: draggingApp),
                  hiddenSortedApps.contains(targetApp) {
            move(&hiddenSortedApps, sourceIndex, targetApp)
        } else {
            return
        }
        
        customSortOrder = (visibleSortedApps + hiddenSortedApps)
            .compactMap { getUniqueIdentifier(for: $0) }
        appSortType = .custom
    }
    
    private func sortByCustomOrder(_ appList: [LCAppModel], customSortOrder: [String]) -> [LCAppModel] {
        if customSortOrder.isEmpty {
            return appList.sorted { $0.appInfo.displayName() < $1.appInfo.displayName() }
        }
        
        var sortedApps: [LCAppModel] = []
        var remainingApps = appList
        
        for uniqueId in customSortOrder {
            if let index = remainingApps.firstIndex(where: { matches(uniqueId: uniqueId, app: $0) }) {
                sortedApps.append(remainingApps.remove(at: index))
            }
        }
        
        remainingApps.sort { $0.appInfo.displayName() < $1.appInfo.displayName() }
        sortedApps.append(contentsOf: remainingApps)
        
        return sortedApps
    }
    
}
