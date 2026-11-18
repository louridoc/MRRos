@testable import AlignmentKit
import Foundation
import Testing

struct AlignmentStoreTests {
    private func freshStore() -> AlignmentStore {
        AlignmentStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignmentStoreTests-\(UUID().uuidString)", isDirectory: true))
    }

    /// ISO-8601 drops sub-second precision; use a whole-second date so round-trips compare equal.
    private let date = Date(timeIntervalSince1970: 1_794_960_000)

    @Test func emptyStoreHasNothingToRestore() throws {
        let store = freshStore()
        #expect(store.info() == nil)
        #expect(try store.load() == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let store = freshStore()
        let map = Data([1, 2, 3, 4])
        let info = SavedAlignmentInfo(robotName: "crx30ia", savedAt: date)
        try store.save(worldMap: map, info: info)
        #expect(store.info() == info)
        let loaded = try #require(try store.load())
        #expect(loaded.worldMap == map)
        #expect(loaded.info == info)
    }

    @Test func savingAgainReplacesTheSlot() throws {
        let store = freshStore()
        try store.save(worldMap: Data([1]), info: SavedAlignmentInfo(robotName: "ur30", savedAt: date))
        let newer = SavedAlignmentInfo(robotName: "crx20ial", savedAt: date.addingTimeInterval(60))
        try store.save(worldMap: Data([9, 9]), info: newer)
        let loaded = try #require(try store.load())
        #expect(loaded.worldMap == Data([9, 9]))
        #expect(loaded.info == newer)
    }

    @Test func clearRemovesEverythingAndIsIdempotent() throws {
        let store = freshStore()
        try store.save(worldMap: Data([1]), info: SavedAlignmentInfo(robotName: nil, savedAt: date))
        try store.clear()
        #expect(store.info() == nil)
        try store.clear()
    }

    @Test func metadataWithoutAMapIsCorrupt() throws {
        let store = freshStore()
        try store.save(worldMap: Data([1]), info: SavedAlignmentInfo(robotName: "ur20", savedAt: date))
        try FileManager.default
            .removeItem(at: store.directory.appendingPathComponent("worldmap.arexperience"))
        #expect(throws: AlignmentStoreError.self) { _ = try store.load() }
    }

    @Test func unreadableMetadataMeansNothingSaved() throws {
        let store = freshStore()
        try store.save(worldMap: Data([1]), info: SavedAlignmentInfo(robotName: "ur20", savedAt: date))
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("alignment.json"))
        #expect(store.info() == nil)
        #expect(try store.load() == nil)
    }
}
