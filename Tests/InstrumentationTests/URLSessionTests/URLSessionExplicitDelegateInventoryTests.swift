/*
 * Copyright The OpenTelemetry Authors
 * SPDX-License-Identifier: Apache-2.0
 */

import ObjectiveC
@testable import OpenTelemetryApi
@testable import OpenTelemetrySdk
import SharedTestUtils
@testable import URLSessionInstrumentation
import XCTest

/// Covers `URLSessionInstrumentationConfiguration.delegateClassesToInstrument` when the host
/// application supplies an explicit inventory instead of letting the instrumentation autodetect.
///
/// Autodetect is `objc_getClassList()` plus a `class_copyMethodList` walk over every ObjC class
/// in the process, so applications that cannot afford it at launch pass an inventory. Doing that
/// used to silently stop ending spans for `data(for:)` / `upload(for:from:)` / `bytes(for:)` on a
/// delegate-less session: the instrumentation attaches its own `AsyncTaskDelegate` to those tasks,
/// Foundation delivers `didFinishCollecting` (not `didCompleteWithError`) to an attached task
/// delegate, and the only thing that ever gave `AsyncTaskDelegate` a `didFinishCollecting` was the
/// all-class sweep finding the instrumentation's own private class. `AsyncTaskDelegate` now
/// implements the callback itself, so the async path no longer depends on the sweep.
///
/// A process can host only one `URLSessionInstrumentation`: `injectInNSURLClasses()` chains a new
/// swizzle onto the previous implementation, so a second instance double-processes every task.
/// This suite therefore owns the single instrumentation for its own tests and uses its own tracer
/// and span recorder rather than the global provider.
class URLSessionExplicitDelegateInventoryTests: XCTestCase {
  // MARK: - Recording

  /// Counts what the instrumentation reported per request, which is how a duplicated completion
  /// becomes visible: ending an already-ended span exports nothing a second time, but the
  /// configuration callbacks fire once per completion the instrumentation handles.
  final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var responses = 0
    private var errors = 0

    var responseCount: Int { lock.withLock { responses } }
    var errorCount: Int { lock.withLock { errors } }
    var completionCount: Int { lock.withLock { responses + errors } }

    func recordResponse() { lock.withLock { responses += 1 } }
    func recordError() { lock.withLock { errors += 1 } }
    func reset() { lock.withLock { responses = 0; errors = 0 } }
  }

  final class RecordingSpanExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SpanData] = []

    var spans: [SpanData] { lock.withLock { recorded } }
    var clientSpans: [SpanData] { spans.filter { $0.kind == .client } }
    func reset() { lock.withLock { recorded.removeAll() } }

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
      lock.withLock { recorded.append(contentsOf: spans) }
      return .success
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
  }

  /// Stands in for a third-party SDK that owns its session and expects the task callbacks on it.
  final class OwnedSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let didComplete = XCTestExpectation(description: "session delegate received didCompleteWithError")
    private let lock = NSLock()
    private var received: [String] = []

    var callbacks: [String] { lock.withLock { received } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      lock.withLock { received.append("didCompleteWithError") }
      didComplete.fulfill()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
      lock.withLock { received.append("didFinishCollecting") }
    }
  }

  /// A loader that accepts the request and never answers, so a cancellation test does not race
  /// a real response.
  final class NeverCompletingURLProtocol: URLProtocol {
    static let host = "never-completing.invalid"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
  }

  // MARK: - Fixtures

  static let serverPort = 33434
  static let server = HttpTestServer(url: URL(string: "http://localhost:\(serverPort)"),
                                     config: HttpTestServerConfig())
  static let recorder = CompletionRecorder()
  static let exporter = RecordingSpanExporter()

  /// A delegate class the inventory does not name. It is created at runtime, after any other
  /// suite in this process could have run, so the assertion that it was left alone cannot be
  /// satisfied — or contaminated — by an earlier bootstrap.
  nonisolated(unsafe) static var uninventoriedDelegateClass: AnyClass!
  nonisolated(unsafe) static var instrumentation: URLSessionInstrumentation!

  static var didFinishCollectingSelector: Selector {
    #selector(URLSessionTaskDelegate.urlSession(_:task:didFinishCollecting:))
  }

  static var didCompleteWithErrorSelector: Selector {
    #selector(URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:))
  }

  /// Builds an ObjC class implementing only `didCompleteWithError`, which is one of the selectors
  /// the autodetecting sweep looks for.
  static func makeRuntimeDelegateClass(named name: String) -> AnyClass {
    guard let cls = objc_allocateClassPair(NSObject.self, name, 0) else {
      fatalError("could not allocate \(name)")
    }
    let block: @convention(block) (Any, URLSession, URLSessionTask, Error?) -> Void = { _, _, _, _ in }
    class_addMethod(cls, didCompleteWithErrorSelector,
                    imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self)), "v@:@@@")
    objc_registerClassPair(cls)
    return cls
  }

  override class func setUp() {
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .default).async {
      do {
        try server.start(semaphore: semaphore)
      } catch {
        XCTFail("test server did not start: \(error)")
      }
    }
    semaphore.wait()

    uninventoriedDelegateClass = makeRuntimeDelegateClass(named: "OTelUninventoriedDelegateSentinel")

    let provider = TracerProviderSdk(spanProcessors: [SimpleSpanProcessor(spanExporter: exporter)])
    instrumentation = URLSessionInstrumentation(
      configuration: URLSessionInstrumentationConfiguration(
        // Only this suite's own destinations. A process can host one instrumentation, but its
        // swizzles chain onto whatever a sibling suite installed, so an unscoped instance here
        // would start spans for that suite's requests too.
        shouldInstrument: { request in
          request.url?.port == serverPort || request.url?.host == NeverCompletingURLProtocol.host
        },
        receivedResponse: { _, _, _ in recorder.recordResponse() },
        receivedError: { _, _, _, _ in recorder.recordError() },
        delegateClassesToInstrument: [],
        tracer: provider.get(instrumentationName: "URLSessionExplicitDelegateInventoryTests",
                             instrumentationVersion: "1.0.0")
      )
    )
  }

  override class func tearDown() {
    server.stop()
  }

  override func setUp() {
    super.setUp()
    Self.recorder.reset()
    Self.exporter.reset()
  }

  override func tearDown() {
    // A request whose delegate class is not in the inventory legitimately leaves a running span
    // behind; clear it so one test cannot read another's leak.
    URLSessionLogger.runningSpansQueue.sync { URLSessionLogger.runningSpans.removeAll() }
    super.tearDown()
  }

  // MARK: - Helpers

  private func delegatelessSession() -> URLSession {
    URLSession(configuration: .ephemeral)
  }

  private func url(_ path: String, host: String = "localhost") -> URL {
    URL(string: "http://\(host):\(Self.serverPort)\(path)")!
  }

  private func runningSpanCount() -> Int {
    URLSessionLogger.runningSpansQueue.sync { URLSessionLogger.runningSpans.count }
  }

  /// One exported client span, one reported completion, nothing left running.
  private func assertExactlyOneCompletedSpan(_ message: String,
                                             file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Self.exporter.clientSpans.count, 1,
                   "\(message): expected exactly one exported client span", file: file, line: line)
    XCTAssertEqual(Self.recorder.completionCount, 1,
                   "\(message): expected exactly one reported completion", file: file, line: line)
    XCTAssertEqual(runningSpanCount(), 0,
                   "\(message): expected no span left running", file: file, line: line)
  }

  // MARK: - The inventory replaces the sweep

  func testExplicitEmptyDelegateInventorySkipsTheAllClassScan() {
    let sentinel: AnyClass = Self.uninventoriedDelegateClass

    XCTAssertNotNil(class_getInstanceMethod(sentinel, Self.didCompleteWithErrorSelector),
                    "the sentinel must carry a selector the sweep looks for, or it proves nothing")
    XCTAssertNil(class_getInstanceMethod(sentinel, Self.didFinishCollectingSelector),
                 """
                 An explicit delegateClassesToInstrument must not walk every ObjC class. \
                 The sweep adds didFinishCollecting to any class it finds; this one was never named.
                 """)
  }

  func testAsyncTaskDelegateImplementsDidFinishCollectingWithoutTheScan() {
    XCTAssertNotNil(
      class_getInstanceMethod(AsyncTaskDelegate.self, Self.didFinishCollectingSelector),
      """
      AsyncTaskDelegate is what the instrumentation attaches to delegate-less async tasks, and \
      Foundation delivers didFinishCollecting rather than didCompleteWithError to it. It must \
      implement the callback itself; relying on the all-class sweep to add one makes every \
      explicit inventory leak a span per async request.
      """
    )
  }

  // MARK: - Delegate-less async requests

  func testAsyncDataTaskEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    let (_, response) = try await session.data(for: URLRequest(url: url("/success")))

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    assertExactlyOneCompletedSpan("async data(for:)")
  }

  func testAsyncUploadTaskEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    var request = URLRequest(url: url("/success"))
    request.httpMethod = "POST"
    let (_, response) = try await session.upload(for: request, from: Data("payload".utf8))

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    assertExactlyOneCompletedSpan("async upload(for:from:)")
  }

  func testAsyncBytesTaskEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    let (bytes, response) = try await session.bytes(for: URLRequest(url: url("/success")))
    for try await _ in bytes {}

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    assertExactlyOneCompletedSpan("async bytes(for:)")
  }

  func testAsyncDataTaskWithErrorStatusEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    let (_, response) = try await session.data(for: URLRequest(url: url("/forbidden")))

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    assertExactlyOneCompletedSpan("async data(for:) returning 403")
    XCTAssertEqual(Self.exporter.clientSpans.first?.attributes[LegacyHTTPAttributes.statusCode.rawValue],
                   .int(403))
  }

  func testAsyncDataTaskWithTransportFailureEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    do {
      _ = try await session.data(for: URLRequest(url: url("/error")))
      XCTFail("the server closes this connection without a response")
    } catch {
      // expected
    }

    XCTAssertEqual(Self.recorder.errorCount, 1, "a transport failure is one reported completion")
    assertExactlyOneCompletedSpan("async data(for:) that fails in transport")
  }

  func testCancelledAsyncDataTaskEndsExactlyOneSpan() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NeverCompletingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let request = URLRequest(url: URL(string: "http://\(NeverCompletingURLProtocol.host)/hangs")!)
    let inFlight = Task { try await session.data(for: request) }

    // The span exists as soon as the task resumed; cancelling before that would race the swizzle.
    try await waitUntil("the request span started") { self.runningSpanCount() == 1 }
    inFlight.cancel()
    do {
      _ = try await inFlight.value
      XCTFail("a cancelled request must not return a response")
    } catch {
      // expected
    }

    try await waitUntil("the cancellation was reported") { Self.recorder.completionCount == 1 }
    assertExactlyOneCompletedSpan("cancelled async data(for:)")
  }

  /// The instrumentation has no notion of "our" hosts; a host this suite never configured must be
  /// completed by the same path.
  func testAsyncDataTaskToAnUnrelatedHostEndsExactlyOneSpan() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    let (_, response) = try await session.data(for: URLRequest(url: url("/success", host: "127.0.0.1")))

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    assertExactlyOneCompletedSpan("async data(for:) to an unrelated host")
    XCTAssertEqual(Self.exporter.clientSpans.first?.attributes[LegacyHTTPAttributes.netPeerName.rawValue],
                   .string("127.0.0.1"))
  }

  func testRepeatedAsyncDataTasksEndOneSpanEach() async throws {
    let session = delegatelessSession()
    defer { session.invalidateAndCancel() }

    for _ in 0 ..< 3 {
      _ = try await session.data(for: URLRequest(url: url("/success")))
    }

    XCTAssertEqual(Self.exporter.clientSpans.count, 3, "one span per request, never two")
    XCTAssertEqual(Self.recorder.completionCount, 3, "one completion per request, never two")
    XCTAssertEqual(Set(Self.exporter.clientSpans.map(\.spanId)).count, 3, "each request is its own span")
    XCTAssertEqual(runningSpanCount(), 0)
  }

  // MARK: - A session that owns a delegate

  /// The instrumentation only attaches its own task delegate when the task has none *and* the
  /// owning session has none, so a session owned by another SDK keeps its callbacks.
  func testSessionDelegateStillReceivesItsCallbacks() async throws {
    let delegate = OwnedSessionDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    session.dataTask(with: URLRequest(url: url("/success"))).resume()

    await fulfillment(of: [delegate.didComplete], timeout: 10)
    XCTAssertTrue(delegate.callbacks.contains("didCompleteWithError"),
                  "attaching a task delegate here would silently take this callback away")
  }

  /// The async form of the same session: the instrumentation must not attach to a task whose
  /// session already has a delegate, so the request itself is unaffected. The session delegate is
  /// discovered and instrumented when the task resumes, even though it was not in the startup
  /// inventory, so it must still end exactly one span.
  func testAsyncRequestOnADelegateOwningSessionIsUnaffected() async throws {
    let delegate = OwnedSessionDelegate()
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let (_, response) = try await session.data(for: URLRequest(url: url("/success")))

    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    assertExactlyOneCompletedSpan("async request on a session with its own delegate")
  }

  // MARK: -

  private func waitUntil(_ description: String,
                         timeout: TimeInterval = 5,
                         _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { XCTFail("timed out waiting until \(description)"); return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
  }
}
