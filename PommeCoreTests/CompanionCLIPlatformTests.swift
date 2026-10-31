//
//  CompanionCLIPlatformTests.swift
//  PommeCoreTests
//
//  The fourth defect hardware found, and the only one of the four that no
//  assertion about a value could ever have caught.
//
//  Firmware 1.18.0's `CMD_RUN_CLI_COMMAND` is the first CLI path that does not
//  need USB, which is what brings the Radio Terminal to iPhone and iPad —
//  `USBSerialManager` is macOS-only and always will be, there being no CDC ACM
//  API on iOS. But `sendCompanionCLI` was written below the `#if os(macOS)`
//  that guards the USB transport, purely because the other CLI functions live
//  there, and the closure calling it was wired inside the same guard in
//  `PommeCoreViewModel`. Both compiled out of the iOS build. The probe never
//  ran on iPhone, support was never detected, the Radio Terminal row never
//  appeared — and the release notes announced the feature.
//
//  Every other gate passed: it compiled for both platforms with zero warnings,
//  151 package tests passed, and `meshctl smoke` proved the firmware answers —
//  from the Mac. Nothing in the toolchain asks "is this symbol reachable on
//  iOS", because a symbol that has been compiled away is not missing, it is
//  absent, and absence is exactly what a platform guard is for.
//
//  **This file is the net, and it works by compiling.** Referencing the symbols
//  unconditionally means a guard that hides them from a platform breaks the test
//  build for that platform. The assertions below matter less than the fact that
//  the file builds at all.
//
//  Copyright © 2026 Michael P. Bedworth and contributors. All rights reserved.
//

import XCTest
import MeshCoreKit
@testable import PommeCore

@MainActor
final class CompanionCLIPlatformTests: XCTestCase {

    /// An unapplied reference to the method. If `sendCompanionCLI` is ever moved
    /// back inside a platform guard, this line stops compiling on the platform
    /// that lost it — which is the failure the shipped build did not have.
    func testTheCompanionCLIEntryPointExistsOnThisPlatform() {
        let entryPoint: (ConnectionManager) -> (String) -> Void = ConnectionManager.sendCompanionCLI
        XCTAssertNotNil(entryPoint)
    }

    /// The store side, likewise. `RemoteSessionManager` is cross-platform and
    /// its companion-CLI surface must be too.
    func testTheCompanionCLISessionSurfaceExistsOnThisPlatform() {
        let session = RemoteSessionManager()
        session.sendCompanionCLI = { _ in }
        XCTAssertNotNil(session.sendCompanionCLI)

        let probe: (RemoteSessionManager) -> (String) -> Void = RemoteSessionManager.probeCompanionCLI
        XCTAssertNotNil(probe)
    }

    /// The symptom, pinned. With no closure wired the probe does nothing and
    /// support stays unknown — which is exactly what an iPhone saw, and why the
    /// Radio Terminal row never appeared rather than appearing and failing.
    ///
    /// Unknown is the correct state here, not `false`: the radio was never
    /// asked. A probe that recorded "unsupported" because the app forgot to
    /// wire itself up would be making a claim about the firmware.
    func testAnUnwiredProbeLeavesSupportUnknown() {
        let session = RemoteSessionManager()

        session.probeCompanionCLI(radioName: "MPB-Base")

        XCTAssertNil(session.companionCLISupported,
                     "Nothing was asked, so nothing is known")
    }

    /// A radio that predates 1.18.0 answers `ERR_CODE_UNSUPPORTED_CMD`, and
    /// that is a real answer: support is `false`, not unknown.
    func testAnUnsupportedErrorIsRecordedAsUnsupported() {
        let session = RemoteSessionManager()
        session.sendCompanionCLI = { _ in }

        XCTAssertTrue(session.handleCompanionCLIUnsupported(),
                      "It should claim the error so the generic handling stands down")
        XCTAssertEqual(session.companionCLISupported, false)
    }

    /// And it must only claim the error when a companion CLI command was
    /// actually outstanding, or support is still unknown — otherwise it
    /// swallows error frames belonging to something else entirely.
    ///
    /// The second call is the interesting one: by then support has been settled
    /// and nothing is in flight, so this error cannot be about the CLI.
    func testAnErrorIsNotClaimedOnceSupportIsSettled() {
        let session = RemoteSessionManager()
        session.sendCompanionCLI = { _ in }

        XCTAssertTrue(session.handleCompanionCLIUnsupported())
        XCTAssertFalse(session.handleCompanionCLIUnsupported(),
                       "No CLI command was in flight — this error belongs to another command")
    }

    /// The frame builder's floor, from the app's side of the boundary. The
    /// firmware rejects a command shorter than two bytes, so the app must not
    /// send one — a `nil` frame here is the guard, not an error to report.
    func testTooShortACommandProducesNoFrame() {
        XCTAssertNil(MeshCoreProtocol.buildRunCLICommand("v"))
        XCTAssertNotNil(MeshCoreProtocol.buildRunCLICommand("ver"))
    }
}
