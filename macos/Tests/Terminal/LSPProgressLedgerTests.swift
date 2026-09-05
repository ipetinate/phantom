import Foundation
@testable import Ghostty
import Testing

struct LSPProgressLedgerTests {
    private let begin = Date(timeIntervalSince1970: 1_700_000_000)

    private func progress(_ token: String, _ value: LSPValue) -> LSPNotification {
        LSPNotification(method: "$/progress", params: ["token": .string(token), "value": value])
    }

    private func loadingWorkspace(_ token: String = "t1") -> LSPNotification {
        progress(token, ["kind": "begin", "title": "Loading workspace", "percentage": 0])
    }

    @Test func aBeginOpensOneEntry() {
        var ledger = LSPProgressLedger()
        ledger.apply(loadingWorkspace(), now: begin)

        #expect(ledger.active.count == 1)
        #expect(ledger.current == LSPWorkDoneProgress(
            token: "t1",
            title: "Loading workspace",
            message: nil,
            percentage: 0,
            updatedAt: begin
        ))
    }

    @Test func theCreateRequestIsNotProgress() {
        var ledger = LSPProgressLedger()
        ledger.apply(
            LSPNotification(method: "window/workDoneProgress/create", params: ["token": "t1"]),
            now: begin
        )

        #expect(ledger.active.isEmpty)
    }

    @Test func aReportOfNothingOverNothingCountsAsDone() {
        var ledger = LSPProgressLedger()
        ledger.apply(loadingWorkspace(), now: begin)
        ledger.apply(progress("t1", ["kind": "report", "message": "0/0"]), now: begin + 1)

        #expect(ledger.active.isEmpty)
        #expect(LSPProgressLedger.reportsNothingToDo("0 / 0"))
        #expect(!LSPProgressLedger.reportsNothingToDo("0/12"))
        #expect(!LSPProgressLedger.reportsNothingToDo(nil))
    }

    @Test func aReportWithWorkLeftStays() {
        var ledger = LSPProgressLedger()
        ledger.apply(loadingWorkspace("t1"), now: begin)
        ledger.apply(progress("t1", ["kind": "report", "message": "0/0"]), now: begin + 1)
        ledger.apply(loadingWorkspace("t2"), now: begin + 2)
        ledger.apply(
            progress("t2", ["kind": "report", "message": "3/12", "percentage": 25]),
            now: begin + 3
        )

        #expect(ledger.active.count == 1)
        #expect(ledger.current?.token == "t2")
        #expect(ledger.current?.title == "Loading workspace")
        #expect(ledger.current?.message == "3/12")
        #expect(ledger.current?.percentage == 25)
        #expect(ledger.current?.updatedAt == begin + 3)
    }

    @Test func aReportKeepsWhatItDoesNotRestate() {
        var ledger = LSPProgressLedger()
        ledger.apply(
            progress("t1", ["kind": "begin", "title": "Indexing", "message": "1/9", "percentage": 10]),
            now: begin
        )
        ledger.apply(progress("t1", ["kind": "report", "percentage": 40]), now: begin + 1)

        #expect(ledger.current?.message == "1/9")
        #expect(ledger.current?.percentage == 40)
    }

    @Test func pruningDropsWhatWentQuiet() {
        var ledger = LSPProgressLedger()
        ledger.apply(loadingWorkspace("t1"), now: begin)
        ledger.apply(loadingWorkspace("t2"), now: begin + 30)

        ledger.prune(now: begin + 61)
        #expect(ledger.active.keys.sorted() == ["t2"])

        ledger.prune(now: begin + 30 + LSPProgressLedger.staleAfter)
        #expect(ledger.active.isEmpty)
    }

    @Test func anEndForAnUnknownTokenChangesNothing() {
        var ledger = LSPProgressLedger()
        ledger.apply(loadingWorkspace("t1"), now: begin)
        ledger.apply(progress("t9", ["kind": "end"]), now: begin + 1)

        #expect(ledger.active.count == 1)

        ledger.apply(progress("t1", ["kind": "end"]), now: begin + 2)
        #expect(ledger.active.isEmpty)
    }

    @Test func aReportBeforeItsBeginIsIgnored() {
        var ledger = LSPProgressLedger()
        ledger.apply(progress("t1", ["kind": "report", "message": "3/12"]), now: begin)

        #expect(ledger.active.isEmpty)
        #expect(ledger == LSPProgressLedger())
    }

    @Test func aNumericTokenIsATokenToo() {
        var ledger = LSPProgressLedger()
        ledger.apply(
            LSPNotification(
                method: "$/progress",
                params: ["token": 7, "value": ["kind": "begin", "title": "Indexing"]]
            ),
            now: begin
        )

        #expect(ledger.current?.token == "7")
    }

    @Test func theClientAsksForWorkDoneProgress() {
        #expect(LSPCenter.clientCapabilities["window"]?["workDoneProgress"] == .bool(true))
    }
}
