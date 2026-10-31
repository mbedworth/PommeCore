//
//  ChannelSendStatusTests.swift
//  PommeCoreTests
//
//  Critical Rule 6, at the point where the claim is made.
//
//  A channel message composed with Bluetooth off used to display "Sent". Three
//  separate things had to be true for that, and this file pins the one that is
//  store logic:
//
//    1. `sendCommand` returned `Void`, so a dropped frame was indistinguishable
//       from a written one. It returns `Bool` now.
//    2. The caller asked a *separate* `canSend` predicate first and then threw
//       the return value away, so the status was decided by a prediction made a
//       moment earlier rather than by the write. There is one answer now, and it
//       is the write's.
//    3. The view drew a checkmark for `.failed` — see `MessageStatusPhraseTests`
//       and `check_status_switch_exhaustive`.
//
//  The store is driven directly with a stub `sendCommand`, which is the whole
//  point of the return value: "did the frame leave" becomes something a test can
//  answer without a radio.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
import MeshCoreKit
@testable import PommeCore

@MainActor
final class ChannelSendStatusTests: XCTestCase {

    private let channelIndex: UInt8 = 0
    private var channelKey: Data { Data([channelIndex]) }

    /// Counts the writes. A reference type rather than a captured `var` so the
    /// stub keeps working unchanged if the target ever moves to Swift 6's
    /// concurrency checking.
    private final class WriteLog {
        var frames: [(Data, String)] = []
        var count: Int { frames.count }
    }

    private func makeStore(writeSucceeds: Bool?) -> (MessageStoreManager, WriteLog) {
        let store = MessageStoreManager()
        let log = WriteLog()
        if let writeSucceeds {
            store.sendCommand = { data, label in
                log.frames.append((data, label))
                return writeSucceeds
            }
        }
        return (store, log)
    }

    private func status(in store: MessageStoreManager) -> DeliveryStatus? {
        store.messagesByContact[channelKey]?.last?.status
    }

    // MARK: - The bug

    /// Bluetooth off. The frame is not written, so the message is not sent —
    /// and above all is never recorded as `.sent`.
    func testFrameNotWrittenMarksTheMessageFailed() {
        let (store, _) = makeStore(writeSucceeds: false)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(status(in: store), .failed)
    }

    /// The same case, stated as the claim the rule forbids. Kept separate
    /// because this is the assertion that would have caught the shipped bug,
    /// and it should fail loudly rather than as part of a matrix.
    func testFrameNotWrittenNeverClaimsSent() {
        let (store, _) = makeStore(writeSucceeds: false)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertNotEqual(status(in: store), .sent)
        XCTAssertNotEqual(status(in: store), .delivered)
        XCTAssertNotEqual(status(in: store), .repeated)
    }

    /// No transport wired at all. `?? false` is the deliberate default: an
    /// unwired store has written nothing, and the optimistic `?? true` it
    /// replaced reported exactly the success this rule exists to forbid.
    func testNoTransportWiredMarksTheMessageFailed() {
        let (store, _) = makeStore(writeSucceeds: nil)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(status(in: store), .failed)
    }

    // MARK: - The honest success case

    /// A written frame means in flight, not delivered. `.sending` until the
    /// radio answers `PACKET_OK` — the radio decides, not the app.
    func testWrittenFrameStaysSendingUntilTheRadioAnswers() {
        let (store, _) = makeStore(writeSucceeds: true)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(status(in: store), .sending,
                       "A written frame is in flight. Only the radio's response makes it sent.")
    }

    // MARK: - The message is stored either way

    /// Store before send (Critical Rule 5). The response can arrive before the
    /// message is persisted, so a failed write must still leave the message
    /// visible — marked failed, with the text intact so it can be retried or
    /// copied rather than silently lost.
    func testTheMessageIsKeptEvenWhenTheWriteFails() {
        let (store, _) = makeStore(writeSucceeds: false)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(store.messagesByContact[channelKey]?.count, 1)
        XCTAssertEqual(store.messagesByContact[channelKey]?.last?.text, "radio check")
    }

    /// The write is attempted exactly once. A guard that evaluated
    /// `sendCommand?(...)` in a condition and again in the body would transmit
    /// twice, which on a shared channel is airtime spent for nothing.
    func testTheFrameIsWrittenExactlyOnce() {
        let (store, log) = makeStore(writeSucceeds: true)

        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.frames.first?.1, "SEND_CHANNEL_TXT")
    }

    /// Whitespace-only input is not a message and must not reach a transport.
    func testBlankTextIsNotSent() {
        let (store, log) = makeStore(writeSucceeds: true)

        store.sendChannelMessage("   \n  ", channelIndex: channelIndex)

        XCTAssertEqual(log.count, 0)
        XCTAssertNil(store.messagesByContact[channelKey])
    }

    // MARK: - Retry must be as honest as a first attempt

    private func failedMessage(in store: MessageStoreManager) -> Message? {
        store.messagesByContact[channelKey]?.last
    }

    /// Tapping Retry with the radio still away showed a stopwatch that could
    /// never resolve: the retry path set `.sending`, called the transport,
    /// discarded the result, and — unlike a first attempt — armed no pending
    /// send and no timeout. Nothing in the app would ever take that status back.
    /// Found on hardware 2026-10-31.
    func testRetryWithNoTransportGoesBackToFailed() {
        let (store, _) = makeStore(writeSucceeds: false)
        store.sendChannelMessage("radio check", channelIndex: channelIndex)
        guard let failed = failedMessage(in: store) else { return XCTFail("No message stored") }
        XCTAssertEqual(failed.status, .failed, "Precondition")

        store.retryMessage(failed)

        XCTAssertEqual(status(in: store), .failed,
                       "A retry that was not written must not sit at .sending forever")
        XCTAssertNotEqual(status(in: store), .sending)
    }

    /// And a retry that *is* written behaves like a first attempt: in flight,
    /// waiting on the radio, not claimed as sent.
    func testRetryThatIsWrittenStaysSending() {
        let (store, log) = makeStore(writeSucceeds: false)
        store.sendChannelMessage("radio check", channelIndex: channelIndex)
        guard let failed = failedMessage(in: store) else { return XCTFail("No message stored") }

        // The radio comes back.
        store.sendCommand = { _, _ in true }
        store.retryMessage(failed)

        XCTAssertEqual(status(in: store), .sending)
        XCTAssertEqual(log.count, 1, "The failed first attempt was the only write through the old stub")
    }

    /// Retry only applies to a failed message. Re-entering it on something in
    /// flight would arm a second pending send for the same text.
    func testRetryIgnoresAMessageThatIsNotFailed() {
        let (store, log) = makeStore(writeSucceeds: true)
        store.sendChannelMessage("radio check", channelIndex: channelIndex)
        guard let inFlight = failedMessage(in: store) else { return XCTFail("No message stored") }
        XCTAssertEqual(inFlight.status, .sending, "Precondition")

        store.retryMessage(inFlight)

        XCTAssertEqual(log.count, 1, "No second frame for a message already in flight")
    }

    // MARK: - Repeated is a stronger claim than either outcome

    /// `.repeated` means a repeater echoed the frame — direct evidence it was
    /// on the air. Nothing may downgrade it, which is why `markChannelMessage`
    /// refuses to overwrite it.
    func testRepeatedIsNotOverwrittenByALaterFailure() {
        let (store, _) = makeStore(writeSucceeds: true)
        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        guard var messages = store.messagesByContact[channelKey], !messages.isEmpty else {
            return XCTFail("No message was stored")
        }
        messages[0].status = .repeated
        store.messagesByContact[channelKey] = messages

        // A second send of the same text, this time with no transport, must not
        // reach back and relabel the first.
        store.sendChannelMessage("radio check", channelIndex: channelIndex)

        XCTAssertEqual(store.messagesByContact[channelKey]?.first?.status, .repeated)
    }
}
