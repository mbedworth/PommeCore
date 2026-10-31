# Testing

## Why this document exists

On 2026-10-30 a tester with a phone in their hand found four defects in a build
that had passed every automated gate the project had:

| Defect | What it did | Why nothing caught it |
|---|---|---|
| `.failed` drew a checkmark | A channel message sent with Bluetooth off displayed a confident tick | The model was right; a view's status switch ended in `default:`. No test looked at a view, and there were three copies of the switch |
| Two gates for one send | The status was decided by a `canSend` prediction, then the write's own answer was thrown away | `sendCommand`'s `Bool` return was added and never consulted. The doc comment claimed the fix; the code kept both halves |
| Muted channel still buzzed | The notification was suppressed, the haptic was not — once per message, so a reconnect buzzed for the whole backlog | The gate lived inline in the notification path. The haptic path had no checks at all, and nothing compared the two |
| Radio Terminal absent on iOS | The headline feature of the release was compiled out of the platform it was built for | It compiled clean for both platforms, 151 package tests passed, and `meshctl smoke` passed — from the Mac |

The common thread is not carelessness. It is that **every gate the project had
pointed at the package**, where the protocol lives, and nothing pointed at the
app, where all four of these lived. `MeshCoreKit` had 151 tests. `Shared/` had
none, because there was nowhere to put them: the Xcode project had five native
targets and not one test target.

Two of the four are now unit-tested, one is caught by a mechanical check, and
one is caught by the test target *existing* — see below.

---

## Running the tests

```bash
./scripts/test_all.sh            # package tests + app tests + rule checks
```

It prints the number of tests that ran, and **fails when that number is zero.**
That is not belt-and-braces: `xcodebuild`'s exit status says nothing about
whether any test executed, and with `-quiet` it prints nothing either. The first
version of this gate reported "All gates passed" against a scheme whose test
action was not configured at all — exit 0, no test output, nothing run. The
count is read back out of the result bundle with
`xcresulttool get test-results summary`, because that is the only answer that
cannot be vacuous. The gate also fails on any warning in app sources, so the
zero-warning release requirement is enforced here rather than during an archive.

Individually:

```bash
python3 scripts/check_rules.py                                   # mechanical rule checks
swift test --package-path Packages/MeshCoreKit                   # 151 protocol tests
xcodebuild test -scheme PommeCore -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Prefer `test_all.sh`: it resolves whichever iPhone simulator this machine has
rather than naming one. A pinned name rots into "destination not found" at the
next Xcode upgrade — the command in `CLAUDE.md` named `iPhone 16`, and Xcode 27
ships 17-series devices only.

---

## One-time setup (Xcode GUI)

The test target has to be created through Xcode. `project.pbxproj` is fragile
and a test target touches six sections of it; the GUI writes all of them
correctly in about a minute, and a hand-edit mid-release is a bad trade.

1. **File → New → Target…** → iOS → **Unit Testing Bundle**
2. Product Name: `PommeCoreTests`
   Target to be Tested: **PommeCore** (the iOS app)
   Language: Swift
3. Delete the stub `PommeCoreTests.swift` Xcode generates (Move to Trash).
4. Drag the `Tests/PommeCoreTests` folder from Finder into the project
   navigator. In the dialog: **uncheck** "Copy items if needed", choose
   "Create groups", and tick **only** the `PommeCoreTests` target.
5. Select the `PommeCoreTests` target → General → set **Minimum Deployments**
   to **iOS 18.0**.
6. Build Phases → Link Binary With Libraries → **+** → add `MeshCoreKit`.
7. Product → Scheme → Edit Scheme → Test → confirm `PommeCoreTests` is listed.

### If the app tests fail to launch

```
Simulator device failed to launch com.mbedworth.meshcore.
… Busy ("Application failed preflight checks")
```

The simulator was not ready. Left to itself `xcodebuild` boots the device and
then installs and launches the host app while SpringBoard is still starting; it
fails reproducibly when the app stage follows the package tests, and not at all
when the device happens to be warm from a previous run. `test_all.sh` boots the
device and blocks on `simctl bootstatus -b` before testing, and targets it by
UDID rather than by name.

**Do not "fix" this by rerunning until it goes green.** It was diagnosed as
transient state and declared fixed once, wrongly, because an uninstall happened
to be followed by a warm-device pass. A gate that fails for reasons unrelated to
the code trains you to rerun it, which is how a real failure gets waved through.
If it recurs, `xcrun simctl shutdown all` and run the gate — a cold device is
the condition that reproduces it.

### Step 5 is not optional

The widget extension shipped at an `IPHONEOS_DEPLOYMENT_TARGET` of **26.4**
from the moment it was created until it was caught five months later, which
made widgets invisible to every user below iOS 26.4 in every released build
that contained them. Xcode fills a new target's floor in from the SDK, not from
the project, so a fresh test target arrives wrong in exactly the same way. It
produces no warning and no build failure.

After step 5, confirm the floor audit still shows one value per platform:

```bash
grep -oE "(IPHONEOS|MACOSX|WATCHOS)_DEPLOYMENT_TARGET = [0-9.]+" PommeCore.xcodeproj/project.pbxproj | sort | uniq -c
```

`check_rules.py` audits this too, and will fail the build if the new target
drifts.

---

## What each suite covers

### `MessageStatusPhraseTests`

Critical Rule 6 — a status is a claim about reality — applied to the words
VoiceOver speaks. `DeliveryStatus` is `CaseIterable` specifically so these tests
walk every case: add a status and the suite fails the same day, rather than the
new case reaching a view that quietly draws it as something else.

The strongest assertion here is language-independent. `testEveryStatusReadsDifferently`
compares the phrases to *each other*, not to English literals, so it holds in
all twelve languages — two statuses that read alike are indistinguishable to
anyone using VoiceOver, which is the audible form of the checkmark bug.

**The icon is not tested here.** A SwiftUI view's rendered symbol is not
reachable without a view-inspection dependency, and adding one to test a
nine-line switch is the wrong trade. `check_status_switch_exhaustive` in
`check_rules.py` covers it instead, by forbidding `default:` — which is what
makes the icon and the phrase unable to disagree.

### `ChannelSendStatusTests`

The same rule at the point where the claim is made. The store is driven directly
with a stub `sendCommand`, which is the entire reason the return value exists:
"did the frame leave" becomes something a test can answer without a radio.

Note `testWrittenFrameStaysSendingUntilTheRadioAnswers`. A written frame is in
flight, not delivered — only `PACKET_OK` makes it `.sent`. That distinction is
the rule, and it is easy to "fix" in the wrong direction.

### `NotificationGateTests`

The App Store reviewer's complaint, and the half of it that survived the first
fix. `alertIsAllowed(for:)` is the single gate every alerting path asks; these
tests are the reason it can stay single, because they pin the behaviour the
notification path and the haptic path have to share.

`testMentionsOnlyFailsClosedWithNoDeviceName` is the one worth reading. With no
device name there is no way to recognise a mention, and "mentions only" is a
request not to be interrupted otherwise — so the unknown case must be silence.
Fail-closed is a decision, not an accident, and a test is how it stays one.

### `QuickReplyTests`

Strings that **leave the device**, which is a category Rule 18 does not cover.
`Text` resolves `^[…](inflect: true)` when it draws; `String(localized:)` hands
the markup back verbatim. A Quick Reply is transmitted, not drawn, so the markup
went out over the air and another operator's client displayed
`Copy, @[Z-max]! ^[3 hop](inflect: true) @ 21:44`.

Rule 18 pushes everything towards `LocalizedStringKey`, and that is right for
anything drawn. These tests exist because the same habit is the bug on the other
side of the boundary, and no other tool can tell the two apart.

### `CompanionCLIPlatformTests`

**This suite works by compiling.** It takes unapplied references to
`ConnectionManager.sendCompanionCLI` and `RemoteSessionManager.probeCompanionCLI`,
so a platform guard that hides either of them breaks the test build for the
platform that lost it. The assertions matter less than the fact that the file
builds at all.

This is the only one of the four defects that no assertion about a value could
have caught. Code that has been compiled away is not an error — it is absent,
and absence is what a platform guard is for. `check_cross_platform_symbols` in
`check_rules.py` is the second net, naming the symbols the iOS build needs.

---

## What is still not covered

Stated plainly, because an incomplete net described as complete is worse than
no net.

- **Views.** No snapshot or view-inspection tests. Anything about layout,
  colour, or what a view actually draws is still only checked by looking at it.
  `check_contrast.py` covers colour tokens; nothing covers arrangement.
- **macOS.** The test target is hosted by the iOS app. `#if os(macOS)` paths —
  USB serial, the inspector panels, sleep/wake — compile but are untested.
  A second test target hosted by the macOS app would cover them.
- **watchOS.** Nothing. `WatchReceiver`, `PhoneWatchRelay` and the watch stores
  have no tests, and the watch app is a paid companion.
- **Persistence across versions.** Critical Rule 12 says test with persisted
  data. The decoders have package tests; the *migration* paths — a store written
  by an older build, read by a newer one — are exercised only by installing over
  an existing app, which is why `docs/RELEASE_TESTING.md` insists on that and
  forbids deleting the app first.
- **The mesh.** Nothing here puts a frame on the air. `./scripts/meshctl.sh smoke`
  is the firmware gate and `docs/RELEASE_TESTING.md` is the hardware one. Both
  are still required before a release; none of this replaces either.
