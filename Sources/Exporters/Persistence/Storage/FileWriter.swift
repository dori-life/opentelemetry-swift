/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import Foundation

protocol FileWriter: Sendable {
  func write(data: Data)

  func writeSync(data: Data) throws

  func flush()
}

final class OrchestratedFileWriter: FileWriter {
  /// Orchestrator producing reference to writable file.
  private let orchestrator: FilesOrchestrator
  /// Queue used to synchronize files access (read / write) and perform decoding on background thread.
  let queue = DispatchQueue(label: "com.otel.persistence.filewriter", target: .global(qos: .userInteractive))

  init(orchestrator: FilesOrchestrator) {
    self.orchestrator = orchestrator
  }

  // MARK: - Writing data

  func write(data: Data) {
    queue.async { [weak self] in
      try? self?.synchronizedWrite(data: data)
    }
  }

  func writeSync(data: Data) throws {
    try queue.sync {
      try synchronizedWrite(data: data, syncOnEnd: true)
    }
  }

  private func synchronizedWrite(data: Data, syncOnEnd: Bool = false) throws {
    let file = try orchestrator.getWritableFile(writeSize: UInt64(data.count))
    try file.append(data: data, synchronized: syncOnEnd)
  }

  func flush() {
    queue.sync(flags: .barrier) {}
  }
}
