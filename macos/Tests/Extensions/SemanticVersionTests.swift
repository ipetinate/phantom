import Foundation
@testable import Ghostty
import Testing

struct SemanticVersionTests {
    @Test func parsesMajorMinorPatch() throws {
        let version = try #require(SemanticVersion("1.20.3"))
        #expect(version.major == 1)
        #expect(version.minor == 20)
        #expect(version.patch == 3)
        #expect(version.description == "1.20.3")
    }

    @Test(arguments: [
        "", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.2.x", "1..3", ".1.2", "1.2.3 ",
        " 1.2.3", "1.2.-3", "1,2,3", "1.2.3\n", "٣.1.2", "1.2.9999999999",
    ])
    func rejectsAnythingButThreeIntegers(_ text: String) {
        #expect(SemanticVersion(text) == nil)
        #expect(!SemanticVersion.isValid(text))
    }

    @Test func comparesNumericallyNotLexically() throws {
        let older = try #require(SemanticVersion("1.9.9"))
        let newer = try #require(SemanticVersion("1.10.0"))
        #expect(older < newer)
        #expect(!(newer < older))
        #expect("1.9.9" > "1.10.0")
    }

    @Test func ordersByMajorThenMinorThenPatch() throws {
        let versions = try ["2.0.0", "1.0.10", "1.0.2", "0.16.0", "1.1.0"].map {
            try #require(SemanticVersion($0))
        }
        let ordered = versions.sorted().map(\.description)
        #expect(ordered == ["0.16.0", "1.0.2", "1.0.10", "1.1.0", "2.0.0"])
    }

    @Test func equalVersionsAreNeitherOlderNorNewer() throws {
        let one = try #require(SemanticVersion("1.0.0"))
        let two = try #require(SemanticVersion("1.0.0"))
        #expect(one == two)
        #expect(!(one < two))
        #expect(!(two < one))
    }

    @Test func leadingZerosReadAsTheSameNumber() throws {
        let padded = try #require(SemanticVersion("01.002.0"))
        #expect(padded == SemanticVersion(major: 1, minor: 2, patch: 0))
    }
}
