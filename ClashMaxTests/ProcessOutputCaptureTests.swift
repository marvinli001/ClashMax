import Foundation
import Testing
@testable import ClashMax

struct ProcessOutputCaptureTests {
  @Test func capturesOutputLargerThanPipeBufferWithoutDeadlocking() throws {
    let output = try ProcessOutputCapture.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "/usr/bin/yes 1234567890 | /usr/bin/head -c 200000"]
    )

    #expect(output.terminationStatus == 0)
    #expect(output.text.count == 200_000)
  }
}
