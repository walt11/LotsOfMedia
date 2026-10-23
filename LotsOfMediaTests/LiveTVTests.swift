import XCTest
@testable import LotsOfMedia

/// Live TV parsing, using payloads shaped like a real PMS 1.41 + HDHomeRun setup.
final class LiveTVTests: XCTestCase {
    func testGridProgramWithSeveralAiringsBecomesOneAiringEach() throws {
        let json = #"""
        {"MediaContainer":{"size":1,"Metadata":[{
          "ratingKey":"plex%3A%2F%2Fepisode%2F6a98","key":"/tv.plex.providers.epg.cloud:2/metadata/plex%3A%2F%2Fepisode%2F6a98",
          "guid":"plex://episode/6a98","grandparentGuid":"plex://show/64de","type":"episode","title":"Bite out of Crime",
          "grandparentTitle":"Rizzoli & Isles","index":17,"parentIndex":5,"contentRating":"TV-14",
          "Genre":[{"tag":"Crime drama"}],
          "Media":[
            {"beginsAt":1791230400,"endsAt":1791234000,"channelIdentifier":"lineup-5.3","channelVcn":"5.3","premiere":"1","videoResolution":"720"},
            {"beginsAt":1791316800,"endsAt":1791320400,"channelIdentifier":"lineup-5.3","channelVcn":"5.3"}
          ]}]}}
        """#
        let airings = try JSONDecoder().decode(LiveAiringList.self, from: Data(json.utf8)).airings
        XCTAssertEqual(airings.count, 2)
        XCTAssertNotEqual(airings[0].id, airings[1].id)
        XCTAssertEqual(airings[0].showTitle, "Rizzoli & Isles")
        XCTAssertEqual(airings[0].episodeLine, "S5E17 · Bite out of Crime")
        XCTAssertTrue(airings[0].isPremiere)
        XCTAssertFalse(airings[1].isPremiere)
        XCTAssertEqual(airings[0].grandparentGuid, "plex://show/64de")
        XCTAssertEqual(airings[0].genres, ["Crime drama"])
        XCTAssertEqual(airings[0].endsAt.timeIntervalSince(airings[0].beginsAt), 3600)
    }

    func testEpisodeNamedLikeItsShowHasNoRepeatedTitle() throws {
        let json = #"""
        {"MediaContainer":{"Metadata":[{"ratingKey":"x","type":"episode","title":"Jeopardy!","grandparentTitle":"Jeopardy!",
          "index":16,"parentIndex":43,"Media":[{"beginsAt":100,"endsAt":1900,"channelIdentifier":"c"}]}]}}
        """#
        let a = try XCTUnwrap(JSONDecoder().decode(LiveAiringList.self, from: Data(json.utf8)).airings.first)
        XCTAssertEqual(a.episodeLine, "S43E16")
    }

    func testAiringProgressAndOnAir() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"x","type":"movie","title":"Heat","year":1995,"Media":[{"beginsAt":1000,"endsAt":2000,"channelIdentifier":"c"}]}]}}"#
        let a = try XCTUnwrap(JSONDecoder().decode(LiveAiringList.self, from: Data(json.utf8)).airings.first)
        XCTAssertTrue(a.isOnAir(at: Date(timeIntervalSince1970: 1500)))
        XCTAssertFalse(a.isOnAir(at: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(a.progress(at: Date(timeIntervalSince1970: 1250)), 0.25, accuracy: 0.001)
        XCTAssertEqual(a.episodeLine, "1995")
    }

    func testTuneResponseGivesLiveSession() throws {
        let json = #"""
        {"MediaContainer":{"size":1,"MediaSubscription":[{"key":"819","type":4,"MediaGrabOperation":[{
          "id":"op","Metadata":{"key":"/livetv/sessions/e3b36983","ratingKey":"10750","type":"episode","title":"Let's Make a Deal",
            "Media":[{"beginsAt":1791229394,"endsAt":1791229694,"channelIdentifier":"lineup-5.1"}]}}]}]}}
        """#
        let session = try LiveSession.parseTune(Data(json.utf8))
        XCTAssertEqual(session.path, "/livetv/sessions/e3b36983")
        XCTAssertEqual(session.ratingKey, "10750")
        XCTAssertEqual(session.airing?.title, "Let's Make a Deal")
    }

    func testTuneWithoutGrabMeansNoTuner() {
        let busy = #"{"MediaContainer":{"size":1,"MediaSubscription":[{"key":"828","type":4}]}}"#
        XCTAssertThrowsError(try LiveSession.parseTune(Data(busy.utf8)))
        let message = #"{"MediaContainer":{"size":0,"message":"Could not tune channel. Please check your tuner or antenna.","status":-1}}"#
        XCTAssertThrowsError(try LiveSession.parseTune(Data(message.utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("antenna"))
        }
    }

    func testRecordingTemplateSettingsAndChoices() throws {
        let json = #"""
        {"type":2,"title":"All Episodes","parameters":"hints%5Bguid%5D=plex%3A%2F%2Fshow%2F64de&params%5BlibraryType%5D=2",
         "targetLibrarySectionID":2,
         "Setting":[
           {"id":"onlyNewAirings","value":"1","enumValues":"0:New and Repeat Airings|1:New Airings Only"},
           {"id":"startTimeslot","value":"-1","enumValues":"-1:Any|1791230400:03%3A00 PM"},
           {"id":"recordPartials","value":"true"}]}
        """#
        let option = try JSONDecoder().decode(RecordingOption.self, from: Data(json.utf8))
        XCTAssertTrue(option.isSeries)
        XCTAssertEqual(option.targetLibrarySectionID, "2")
        XCTAssertEqual(option.setting("onlyNewAirings")?.choices.map(\.label), ["New and Repeat Airings", "New Airings Only"])
        XCTAssertEqual(option.setting("startTimeslot")?.choices.last?.label, "03:00 PM")
        XCTAssertEqual(option.setting("recordPartials")?.value, "true")
        XCTAssertTrue(option.setting("recordPartials")?.choices.isEmpty ?? false)
    }

    func testSeriesRuleKeepsShowGuidAndUpcoming() throws {
        let json = #"""
        {"key":"830","type":2,"title":"All Episodes","airingsType":"New Airings Only",
         "Directory":{"title":"Jeopardy!","guid":"plex://show/5fc6","thumb":"https://example/thumb.jpg"},
         "Setting":[{"id":"onlyNewAirings","value":"1"},{"id":"autoDeletionItemPolicyUnwatchedLibrary","value":"5"}],
         "MediaGrabOperation":[{"id":"g1","mediaSubscriptionID":830,"status":"inprogress",
            "Metadata":{"ratingKey":"x","type":"episode","title":"Jeopardy!","grandparentTitle":"Jeopardy!","grandparentGuid":"plex://show/5fc6",
              "Media":[{"beginsAt":1791232200,"endsAt":1791234000,"channelIdentifier":"lineup-4.1"}]}}]}
        """#
        let rule = try JSONDecoder().decode(LiveSubscription.self, from: Data(json.utf8))
        XCTAssertTrue(rule.isSeries)
        XCTAssertEqual(rule.itemTitle, "Jeopardy!")
        // The show guid must match the guide's grandparentGuid so airings show as "series recording".
        XCTAssertEqual(rule.guid, rule.upcoming.first?.airing?.grandparentGuid)
        XCTAssertEqual(rule.settings["autoDeletionItemPolicyUnwatchedLibrary"], "5")
        XCTAssertEqual(rule.upcoming.first?.isRecording, true)
        XCTAssertEqual(rule.upcoming.first?.subscriptionID, "830")
    }

    func testGuideStartsOnTheHalfHour() {
        let date = Date(timeIntervalSince1970: 1791231437)   // 3:37:17 PM CDT
        let slot = LiveTVStore.slot(containing: date)
        XCTAssertEqual(slot.timeIntervalSince1970, 1791230400)   // 3:30 PM
        XCTAssertEqual(LiveTVStore.slot(containing: slot), slot)
    }

    func testChannelsSortNumerically() throws {
        let json = #"[{"id":"a","vcn":"16.1","title":"TBN"},{"id":"b","vcn":"9.2","title":"MeTV"},{"id":"c","vcn":"9.10","title":"X"},{"id":"d","vcn":"4.1","title":"FOX"}]"#
        let channels = try JSONDecoder().decode([LiveChannel].self, from: Data(json.utf8))
            .sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
        XCTAssertEqual(channels.map(\.number), ["4.1", "9.2", "9.10", "16.1"])
    }
}

final class RecordingTrackingRegressionTests: XCTestCase {
    func testRefreshingOneServerCannotFinishAnotherServersRecording() {
        let a = LiveTVStore.scopedKey(serverID: "A", id: "1")
        let b = LiveTVStore.scopedKey(serverID: "B", id: "1")
        let entries = [a: LiveTVStore.Tracked(title: "A", endsAt: .distantPast, failed: false, serverID: "A"),
                       b: LiveTVStore.Tracked(title: "B", endsAt: .distantPast, failed: false, serverID: "B")]
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(LiveTVStore.missingRecordings(entries, current: [], serverID: "A"), [a])
        XCTAssertTrue(LiveTVStore.missingRecordings(entries, current: [a], serverID: "A").isEmpty)
    }
}

final class RecordingConflictTests: XCTestCase {
    private func airing(_ channel: String, _ start: Int, _ end: Int) throws -> LiveAiring {
        let json = """
        {"ratingKey":"\(channel)","title":"Program","Media":[{"beginsAt":\(start),"endsAt":\(end),"channelIdentifier":"\(channel)"}]}
        """
        return try JSONDecoder().decode(LiveAiring.self, from: Data(json.utf8))
    }

    func testAdjacentRecordingsDoNotConflict() throws {
        let target = try airing("a", 100, 200)
        XCTAssertFalse(RecordingConflict.hasConflict(target, scheduled: [try airing("b", 0, 100), try airing("b", 200, 300)], tuners: 1))
    }

    func testOnlySimultaneousRecordingsConsumeTuners() throws {
        let target = try airing("a", 100, 300)
        let first = try airing("b", 100, 200)
        let second = try airing("c", 200, 300)
        XCTAssertFalse(RecordingConflict.hasConflict(target, scheduled: [first, second], tuners: 2))
        XCTAssertTrue(RecordingConflict.hasConflict(target, scheduled: [first, try airing("c", 150, 250)], tuners: 2))
    }

    func testDuplicatesAndExistingTargetDoNotConsumeExtraTuners() throws {
        let target = try airing("a", 100, 300)
        let other = try airing("b", 100, 300)
        XCTAssertFalse(RecordingConflict.hasConflict(target, scheduled: [target, other, other], tuners: 2))
        XCTAssertTrue(RecordingConflict.hasConflict(target, scheduled: [other], tuners: 1))
        XCTAssertFalse(RecordingConflict.hasConflict(target, scheduled: [other], tuners: 0))
    }
}
