import SwiftUI

struct CheckForUpdatesButton: View {
  @ObservedObject var updateController: AppUpdateController

  var body: some View {
    Button("Check for Updates...") {
      updateController.checkForUpdates()
    }
    .disabled(!updateController.canCheckForUpdates)
    .help(updateController.statusMessage)
  }
}
