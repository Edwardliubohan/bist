# bist on iPhone

The iPhone app uses the same task rules and note store as the Mac app. Tasks, subtasks, tags, completion history and the scratchpad work offline. Agent sessions and agent commands remain on the Mac.

## Open the app

Install full Xcode with the iOS platform and simulator runtime. The command-line tools alone cannot build or run an iPhone app.

Open `iOS/Bist.xcodeproj`, choose the **Bist iPhone** scheme and an iPhone simulator, then run. This local scheme needs no CloudKit container. To run on your own iPhone, select your signing team in the target and choose your connected phone.

**Bist Mac** builds the existing Mac panel from the same checkout. It uses the existing Mac data location and remains separate from the phone’s app sandbox. The existing `build.sh` workflow still produces a local Mac build.

## Enable iCloud sync

The local schemes intentionally save only on the device. A signed Cloud build on each device is required for iCloud sync.

1. Enroll in the Apple Developer Program and register an iPhone app ID, a Mac app ID and one CloudKit container under the same team. Enable iCloud and push notifications for both app IDs and attach the same container to both.
2. Copy `iOS/Configuration/Local.xcconfig.example` to `iOS/Configuration/Local.xcconfig`. Fill in your registered team, bundle IDs and container. The local configuration is ignored by Git. Keep the installed Mac bundle ID consistent with the app you intend to update.
3. Choose **Bist iPhone Cloud** or **Bist Mac Cloud**. These schemes use CloudDebug when running and CloudRelease when archiving. Xcode must generate provisioning profiles containing the CloudKit and push notification entitlements. Both builds must use the same container and CloudKit environment.
4. Sign in to the same iCloud account on both devices. Open Settings in each app and turn on **Sync with iCloud**. Use **Sync now** to request a refresh. Pending changes and errors remain visible there.

Running uses the CloudKit Development environment. Archives use Production. Engine cursors, record versions and account binding stay separate for the two environments. Switching environments requires enabling sync again, and queues the local records for that environment. Before distributing a CloudRelease build, deploy the tested schema through CloudKit Console and verify both apps against Production. The `BistRecord` type needs optional `payload` (Bytes) and `payloadAsset` (Asset) fields, including the asset field even when your development notes were small. TestFlight and App Store distribution need the normal Apple signing and review steps. The repository does not create accounts, register identifiers or deploy a schema for you.

The app saves locally before exchanging records with iCloud. Background sync is opportunistic. Open the app or choose **Sync now** when checking a change. If iCloud is unavailable, local editing continues and pending changes remain on the device. Recovered note versions are available in Settings. If the iCloud zone was removed, sync pauses. **Restore local data to iCloud** asks for confirmation, saves a private local backup, clears stale server state and uploads the retained local records. A missing established zone never counts as permission to upload again.

## Phone controls

- Add a task in the capture field. Its list selector chooses Short term or Longer term.
- Tap the circle to complete or reopen a task. Open its title for details, tags, a parent and subtasks. Text drafts survive navigation and relaunch. Saving a draft preserves unrelated changes received while it was open and asks for review when the same text field changed elsewhere.
- Tap a disclosure arrow to collapse subtasks. Long-press a task for move up, move down and move to another list. Change Parent in details to nest it.
- Swipe a task to delete it. A confirmation distinguishes deleting only the task from deleting its subtree. Undo is available above the list during the current launch.
- Past tasks contains completions at least 24 hours old. Agent results never check your own completion box.
- Note saves while typing. Settings contains tag management, sync status and recovered note versions.

The phone uses system navigation, text styles, Dynamic Type, VoiceOver labels and system light or dark appearance. It has no remote agent dispatch controls.

## Verification

Run `iOS/test-phone.sh` for Xcode build graph validation and the phone draft and hierarchy regressions on macOS. It checks that a newer remote field survives an unrelated edit, competing text edits remain visible after draft persistence, and parent choices exclude descendants.

Regenerate the checked-in project after adding shared Swift source files.

```sh
python3 iOS/generate-project.py
```

With full Xcode selected, build the local phone app without signing.

```sh
xcodebuild -project iOS/Bist.xcodeproj -scheme 'Bist iPhone' \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`iOS/test-simulator.sh` chooses an available iPhone simulator and runs the local scheme’s XCUITest journeys. The tests capture, edit and complete a task, relaunch to check task and note persistence, and check that the local build keeps iCloud disabled. Every test uses its own temporary app data and preferences. Native screenshots stay attached to `build/iphone-ui.*/BistPhoneUITests.xcresult`. The Apple builds workflow runs these journeys and retains that result bundle as an artifact.

This environment had command-line tools without full Xcode when the phone app was added. Project and plist validation, portable SwiftUI typechecking on macOS, and the draft and hierarchy regressions are available here. The iOS SDK build and simulator journeys must pass on the Xcode CI runner. Manual touch and VoiceOver checks, provisioning and a real Mac to iPhone CloudKit round trip still need full Xcode and signed devices.

The device acceptance pass should cover offline edits on both devices, relaunch before reconnecting, concurrent title and completion edits, deletion against a stale offline edit, conflicting note recovery, and sign-out or account switching without moving one account’s tasks into another account.
