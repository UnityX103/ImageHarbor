import AppKit
import SwiftUI
import Sparkle

@MainActor final class UpdateCoordinator: NSObject, ObservableObject, SPUUpdaterDelegate {
    private weak var model: HarborModel?
    private var controller: SPUStandardUpdaterController?

    func connect(to model: HarborModel) {
        guard controller == nil else { return }
        self.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        do { try controller.updater.start() }
        catch { model.message = "更新服务启动失败：\(error.localizedDescription)" }
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard let model else { return false }
        model.prepareForUpdate(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        model?.updateInstalling = false
        model?.pendingUpdateInstallation = nil
    }
}
