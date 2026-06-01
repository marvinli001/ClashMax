import SwiftUI

struct CheckForUpdatesButton: View {
  @ObservedObject var updateController: AppUpdateController
  var fillsWidth = false

  var body: some View {
    Button {
      updateController.checkForUpdates()
    } label: {
      Label("Check Updates", systemImage: "sparkles")
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.78)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
    .disabled(!updateController.canCheckForUpdates)
    .help(updateController.statusMessage)
  }
}
