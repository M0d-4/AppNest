//
//  LCAppBannerViewController.swift
//  LiveContainerSwiftUI
//

import Combine
import Foundation
import SwiftUI
import UIKit

final class LCAppBannerViewController: UIViewController {
    var actions: LCAppBannerActions {
        didSet {
            observeModel()
            refresh()
        }
    }
    private var cancellables: Set<AnyCancellable> = []
    private let bannerView = LCAppBannerRootView()
    private var contextMenuInteraction: UIContextMenuInteraction?

    init(actions: LCAppBannerActions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func loadView() {
        view = bannerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        bannerView.runControl.addTarget(self, action: #selector(handleRunTap), for: .touchUpInside)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        bannerView.addGestureRecognizer(doubleTap)

        let interaction = UIContextMenuInteraction(delegate: self)
        bannerView.addInteraction(interaction)
        contextMenuInteraction = interaction

        observeModel()
        refresh()
    }

    private func observeModel() {
        cancellables.removeAll()
        actions.model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
        actions.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    func refresh() {
        guard isViewLoaded else { return }
        bannerView.update(
            model: actions.model,
            appInfo: actions.appInfo,
            dynamicColors: actions.dynamicColors,
            darkModeIcon: actions.darkModeIcon,
            traitCollection: traitCollection
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            refresh()
        }
    }

    @objc private func handleRunTap() {
        if #available(iOS 16.0, *) {
            if let currentDataFolder = actions.model.uiSelectedContainer?.folderName,
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
        }
        Task { await actions.runApp() }
    }

    @objc private func handleDoubleTap() {
        actions.openSettings()
    }
}

extension LCAppBannerViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.actions.makeContextMenu()
        }
    }
}
