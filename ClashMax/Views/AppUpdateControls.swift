import SwiftUI

struct CheckForUpdatesButton: View {
  @ObservedObject var updateController: AppUpdateController

  var body: some View {
    Button("Check App Updates...") {
      updateController.checkForUpdates()
    }
    .disabled(!updateController.canCheckForUpdates)
    .help(updateController.statusMessage)
  }
}

struct CheckResourceUpdatesButton: View {
  @ObservedObject var updateController: ResourceUpdateController

  var body: some View {
    Button("Check Resource Updates...") {
      updateController.checkForUpdates()
    }
    .help(updateController.statusMessage)
  }
}
