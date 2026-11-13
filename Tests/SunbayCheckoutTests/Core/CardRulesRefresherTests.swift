import XCTest
@testable import SunbayCheckout

final class CardRulesRefresherTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func doc(_ version: String, schemaVersion: Int = 1) -> Data {
        Data(
            """
            {"schemaVersion":\(schemaVersion),"version":"\(version)","generic":{"groups":[4,4,4,4],\
            "minLength":12,"maxLength":19,"cvv":{"name":"CVC","sizes":[3,4]}},"brands":[]}
            """.utf8)
    }

    /// Scriptable service that records the ETags it was asked with.
    private final class ScriptedService: CardRulesService, @unchecked Sendable {
        var results: [Result<CardRulesFetchResult, Error>]
        private(set) var etags: [String?] = []
        var onCall: (() -> Void)?
        private let lock = NSLock()
        init(_ results: [Result<CardRulesFetchResult, Error>]) { self.results = results }
        func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult {
            lock.lock()
            etags.append(etag)
            let next = results.isEmpty ? .success(.notModified) : results.removeFirst()
            lock.unlock()
            onCall?()
            return try next.get()
        }
        var callCount: Int { lock.lock(); defer { lock.unlock() }; return etags.count }
    }

    // MARK: Gate

    func test_gate_firstClaimTrue_secondWithinIntervalFalse_afterIntervalTrue() {
        let gate = CardRulesRefreshGate(minInterval: 3600)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(gate.claim(now: t0))
        XCTAssertFalse(gate.claim(now: t0.addingTimeInterval(3599)))
        XCTAssertTrue(gate.claim(now: t0.addingTimeInterval(3600)))
    }

    // MARK: refresh

    func test_refresh_updated_validDocument_savesDocumentAndETag() async {
        let store = CardRulesStore(directory: directory)
        let service = ScriptedService([.success(.updated(doc("v2"), etag: "\"e2\""))])
        await CardRulesRefresher.refresh(service: service, store: store)
        XCTAssertEqual(store.load()?.version, "v2")
        XCTAssertEqual(store.etag(), "\"e2\"")
    }

    func test_refresh_invalidDocuments_keepPreviousCache() async {
        let store = CardRulesStore(directory: directory)
        store.save(data: doc("v1"), etag: "\"e1\"")
        let oversized = doc("big") + Data(String(repeating: " ", count: CardRuleSet.maxDocumentBytes).utf8)
        let bad: [Data] = [Data("garbage".utf8), doc("v9", schemaVersion: 2), oversized]
        for data in bad {
            let service = ScriptedService([.success(.updated(data, etag: "\"bad\""))])
            await CardRulesRefresher.refresh(service: service, store: store)
            XCTAssertEqual(store.load()?.version, "v1")
            XCTAssertEqual(store.etag(), "\"e1\"")
        }
    }

    func test_refresh_notModified_keepsCache() async {
        let store = CardRulesStore(directory: directory)
        store.save(data: doc("v1"), etag: "\"e1\"")
        await CardRulesRefresher.refresh(service: ScriptedService([.success(.notModified)]), store: store)
        XCTAssertEqual(store.load()?.version, "v1")
    }

    func test_refresh_serviceThrows_keepsCache() async {
        let store = CardRulesStore(directory: directory)
        store.save(data: doc("v1"), etag: "\"e1\"")
        await CardRulesRefresher.refresh(
            service: ScriptedService([.failure(URLError(.timedOut))]), store: store)
        XCTAssertEqual(store.load()?.version, "v1")
        XCTAssertEqual(store.etag(), "\"e1\"")
    }

    func test_refresh_sendsStoredETag() async {
        let store = CardRulesStore(directory: directory)
        let service = ScriptedService([.success(.updated(doc("v2"), etag: "\"e2\"")), .success(.notModified)])
        await CardRulesRefresher.refresh(service: service, store: store)
        await CardRulesRefresher.refresh(service: service, store: store)
        XCTAssertEqual(service.etags.count, 2)
        XCTAssertNil(service.etags[0])
        XCTAssertEqual(service.etags[1], "\"e2\"")
    }

    func test_refresh_updatedWithoutETag_removesStaleETag() async {
        let store = CardRulesStore(directory: directory)
        store.save(data: doc("v1"), etag: "\"e1\"")
        await CardRulesRefresher.refresh(
            service: ScriptedService([.success(.updated(doc("v2"), etag: nil))]), store: store)
        XCTAssertEqual(store.load()?.version, "v2")
        XCTAssertNil(store.etag())
    }

    // MARK: Store / provider

    func test_store_corruptCachedDocument_loadsNilAndNoETag() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("card-rules.json"))
        try "\"stale\"".write(to: directory.appendingPathComponent("card-rules.etag"), atomically: true, encoding: .utf8)
        let store = CardRulesStore(directory: directory)
        XCTAssertNil(store.load())
        XCTAssertNil(store.etag())
    }

    func test_activeRuleSet_prefersCache_thenFallsBackToBundledWhenCacheCorrupt() throws {
        let store = CardRulesStore(directory: directory)
        store.save(data: doc("cached"), etag: nil)
        XCTAssertEqual(CardRulesProvider.activeRuleSet(store: store).version, "cached")
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("card-rules.json"))
        XCTAssertEqual(CardRulesProvider.activeRuleSet(store: store).version, CardRulesProvider.bundled?.version)
    }

    func test_activeRuleSet_oldCachedDinersKeyStillYieldsDinersclub() throws {
        let store = CardRulesStore(directory: directory)
        let old = Data(
            """
            {"schemaVersion":1,"version":"old","generic":{"groups":[4,4,4,4],"minLength":12,"maxLength":19,\
            "cvv":{"name":"CVC","sizes":[3,4]}},"brands":[{"scheme":"diners","displayName":"Diners Club",\
            "patterns":[36],"lengths":[14],"groups":[4,6,4],"cvv":{"name":"CVV","sizes":[3]}}]}
            """.utf8)
        store.save(data: old, etag: nil)
        XCTAssertEqual(CardRulesProvider.activeRuleSet(store: store).detectScheme(digits: "36"), "dinersclub")
    }

    // MARK: refreshInBackground

    func test_refreshInBackground_twoCallsSameGate_oneFetch() async {
        let store = CardRulesStore(directory: directory)
        let gate = CardRulesRefreshGate()
        let fetched = expectation(description: "fetched")
        let service = ScriptedService([.success(.notModified)])
        service.onCall = { fetched.fulfill() }
        CardRulesRefresher.refreshInBackground(service: service, store: store, gate: gate)
        CardRulesRefresher.refreshInBackground(service: service, store: store, gate: gate)
        await fulfillment(of: [fetched], timeout: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.callCount, 1)
    }

    func test_refreshInBackground_failedCheckStillConsumesGate() async {
        let store = CardRulesStore(directory: directory)
        let gate = CardRulesRefreshGate()
        let fetched = expectation(description: "fetched")
        let service = ScriptedService([.failure(URLError(.timedOut))])
        service.onCall = { fetched.fulfill() }
        CardRulesRefresher.refreshInBackground(service: service, store: store, gate: gate)
        await fulfillment(of: [fetched], timeout: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        CardRulesRefresher.refreshInBackground(service: service, store: store, gate: gate)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(service.callCount, 1)
    }
}
