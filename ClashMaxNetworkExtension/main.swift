import Dispatch
import NetworkExtension
import os

private let log = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "main")

autoreleasepool {
  log.debug("Network Extension first light")
  NEProvider.startSystemExtensionMode()
}

dispatchMain()
