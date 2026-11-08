# Restructuring plan

Revision 2, after three adversarial reviews (data safety, iOS platform, sequencing). What each review
changed is logged at the end.

The cleanup review (`/simplify`, 2026-11-07) found structural problems that recent fixes worked around
rather than solved. This plan takes them on in an order where each step ships on its own, leaves the
app working, and can be checked on the phone before the next one starts.

## Ground rules

- **Never overwrite a different picture, never lose track of one.** Every step keeps the existing
  guarantees: names are checked against storage before use, an upload to a taken name is refused where
  the service allows it, a path once handled is never imported, and a photo only counts as backed up
  once its files are confirmed in place.
- **One step, one branch, small commits.** Each step merges to `main` only after its tests pass and its
  checks have been run. Checks run on the simulator (see "Test setup"). The few marked **(phone)** need
  platform behaviour the simulator doesn't have, and run on "just passing through".
- **Testable logic goes in the packages.** Anything that isn't PhotoKit, BackgroundTasks, URLSession or
  UIKit glue moves into SyncKit (or S3Kit), where it can have tests. The app target has none, and
  SyncKit doesn't depend on S3Kit, so logic that needs to be tested takes identity strings rather than
  `S3Client`.
- **Migrations run once, in `BackupStore`'s `user_version` steps, inside one transaction that bumps the
  version only on success.** Never as checks repeated on every pass.
- **Before any schema migration, copy `backup.sqlite` from the simulator's app container** (and off the
  phone, with the user's OK, before installing there). Restoring it is the rollback. No step promises
  that an older build can read a migrated database.
- **No behaviour change unless the step says so.**

## Order

```
0  Logging and signposts
F  Fix existing data-safety bugs (F1–F5)
S  Same name and size means the same file
1  Shared SQLite wrapper
2  Handled-paths writes: less often, one writer
3  Pass runner and status
4  Destinations, without a schema change
5  Upload events
6  One library snapshot per activation
7  Run coordinator, which owns the continued task
8  Real progress for the continued task
9  Reuse comparison exports
10a Backup counts off the main thread
10b Cleanup and Trips off the main thread
```

0 and F come first because the later checks depend on 0, and F's bugs exist today. S comes right after
because it's small and removes most of the reading on a first pass to a drive or a restore. 2 comes before 5
because 5 adds writes at settle time. 9 comes after 7 because the two engines only share an export once
the coordinator runs them together.

---

## Test setup

**Simulator.** An iPhone 17 simulator (Xcode 26.2) with the app built and installed by script, so a
check can be repeated from a clean state.
- **Photos:** a library added with `xcrun simctl addmedia`. Keep a small fixture set (a few hundred
  photos and videos, including Live Photos, edited photos, screenshots, bursts and duplicate names),
  plus a generated large set (tens of thousands of images) for the timing and main-thread checks.
- **Access:** `xcrun simctl privacy <udid> grant photos org.barelyenough.ios-photos-tools` (`build-install.sh`
  runs it). It writes the row in the simulator's TCC database, but on this simulator (iOS 26) the app
  still sees "not determined" and shows the system prompt. Tried: `photos`, `photos-add`, `all`, reset
  first, granting while the app isn't running, after a reboot, and on a fresh install. None changed it.
  So the first launch needs a tap on "Allow Full Access" in the Simulator window (the choice is then kept
  until the app is uninstalled). Until that is tapped, passes end with "Photo access needed".
- **Bucket:** Moto (a mock of S3) in Docker on the Mac, which the simulator reaches at
  `http://127.0.0.1:9000`. There is no `mc`: `scripts/sim/s3.sh up` starts it as container `pt-s3` and
  makes the versioned buckets `pt-a` and `pt-b`. `s3.sh ls|versions BUCKET`, `put BUCKET KEY FILE` and
  `rm BUCKET KEY` look at and change objects from outside the app. Moto keeps versions and supports
  `If-None-Match`, which covers the conditional-write cases. Its data goes when it stops. A second
  Moto on another port, `S3_PORT=9001 scripts/sim/s3.sh up` (container `pt-s3-9001`), stands in for
  "the same bucket name on another service". Point the app at it with `S3_PORT=9001 scripts/sim/launch.sh`.
- **Drive:** the folder `Documents/TestDrive` in the app's container, set as the drive at launch by the
  debug-only `PT_TEST_DRIVE` (see `IOSPhotosTools/TestHooks.swift`), not through a folder picker.
  `scripts/sim/photos.sh drive` copies the fixture library into it, so the drive already holds the
  photos, which sets up the "drive new to the app" case. Uninstalling the app deletes it.
- **Scripts** (`scripts/sim`): `env.sh` (shared settings), `build-install.sh [--clean]`,
  `launch.sh [bucket]` (sets the bucket, the drive, and automatic backup on for both; `NO_DRIVE=1`,
  `EXTRA=` for other settings), `logs.sh [categories]`, `db.sh [sql | --copy DIR]`,
  `photos.sh make [N] | add | drive`, `s3.sh`. `PT_TEST_SETTINGS` takes JSON for the settings.
- **Logs:** `xcrun simctl spawn booted log stream --predicate 'subsystem == "org.barelyenough.ios-photos-tools"'`,
  filtered by step 0's categories.
- **Database:** `backup.sqlite` from `xcrun simctl get_app_container booted org.barelyenough.ios-photos-tools data`,
  inspected with `sqlite3` on the Mac.
- **Upgrades:** install the build from `main` before the step, run it, then install the step's build
  over it, so migrations run against real data.

**(phone) checks.** The simulator can't:
- show or run continued background tasks and background processing tasks. Confirmed in step 0: the
  continued task request fails with `BGTaskSchedulerErrorDomain Code=1` (unavailable) and is logged
  as "Couldn't continue drive backup in the background". The processing task is only submitted when the
  app goes to the background, which the scripts don't do, so its submit wasn't observed; expect the same
  error;
- unplug a USB drive, or show USB speeds;
- download originals from iCloud;
- use cellular data;
- relaunch the app reliably for background upload events.

Checks that need any of these are marked **(phone)**. They run once the step's simulator checks pass.

---

## Step 0. Logging and signposts

**Why.** Several checks below are "it listed once" or "it read the photo once". Nothing logs those today.

**Change.** `os.Logger` categories (`listing`, `export`, `hash`, `handled-paths`, `pass`, `upload`,
`continued-task`) and signposts around drive and bucket listing, export, hashing, handled-paths writes,
passes and settling. No behaviour change.

**Check.** The simulator's log stream shows each event. Write the setup scripts from "Test setup":
build and install, add the fixture photos, grant access, start Moto with buckets `pt-a` and `pt-b`, and fill the
drive folder. Confirm what the simulator does with `BGTaskScheduler.submit` and
`BGContinuedProcessingTaskRequest`, and adjust the **(phone)** list.

**(phone)** Write down the lldb command for simulating the background task, with this app's ID:
`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"org.barelyenough.ios-photos-tools.backup"]`

---

## Step F. Fix existing data-safety bugs

The data safety review found these in today's code. Each is a small, separate fix with tests, made
before any restructuring.

**F1. Switching buckets keeps the old bucket's "done" state.** `resources.state` and `assets` aren't
tied to a bucket. After switching from A to B without "Forget backup history":
- `stage` treats an edited photo as the app's own file in B (`isOwn` from `previous?.state == .done`)
  and uploads the edit without `If-None-Match`, overwriting whatever B has at that path;
- originals are `markDone`d against B's listing with no comparison;
- coverage reports B as backed up.

Fix: when `prepareS3` sees the bucket identity change (anything other than the older form of the same
bucket), forget the bucket history the way "Forget backup history" does, including the `superseded`
handling. Switching to a new bucket then backs everything up to it, which is what it should have done.

Test: switch A → B, edit a photo; its upload must be compared first and sent with `mustNotExist`.

**F2. "Forget backup history" races a pass that's staging.** If `reset()` runs between `register` and
`markUploading`, the upload starts with no resource row. Its completion still sets the `on_bucket` flag
through `handled_paths.resource_id`, and the next pass treats whatever is at that path as the app's own.

Fix: `reset` stops the bucket pass and waits for it first. `done()` sets the own-file flag only if the
resource row exists and still holds that path.

Test: reset between register and markUploading; completion must not set the flag.

**F3. The bucket and drive passes race on a photo's paths.** Background runs already run both engines
at once (`async let` in `BackgroundTasks.handle`). If the drive pass retires a photo's paths while the
bucket pass is between `assign` and `markUploading`, the upload goes to the old path. `markUploading`
then clears `superseded`, and on completion the own-file flag lands on the new path, which was never
uploaded.

Fix: bind each mark to the path it was done for. `markUploading`, `markDone`, `markOnDrive` and
`markDriveAssetComplete` take the path and refuse when the resource no longer holds it. `markUploading`
keeps `superseded` set when the path has changed.

Test: retire between assign and markUploading; nothing is marked, and the asset doesn't complete.

**F4. Concurrent handled-paths writers can leave the file behind.** The pass, the sync and (after step
5) the settle job each write the file. Two writers can land their PUTs out of order. The older content
wins, while meta records the newer version as written, so `isDue` says nothing is due. After a
reinstall, photos deleted since then could be imported again.

Fix: one serialized writer per destination (an actor). Record the version that was actually encoded.

Test: two overlapping writes; the recorded version matches the content written last.

**F5. An empty `library` table deletes pending work.** `forgetResourcesOfMissingAssets` deletes every
pending or failed row whose asset isn't in `library`, which is a TEMP table and empty in a new process.
Today it's always filled first, but nothing enforces that.

Fix: refuse to run unless the library was loaded in this process (`libraryLoaded`).

Test: calling it before `setLibraryAssets` deletes nothing.

**Check (all of F).** A normal backup to bucket A and a drive pass behave as before. Switching the
settings from bucket A to B starts a full backup to B, and an edited photo whose name is already in B
isn't overwritten (look at B's object versions). Tapping "Forget backup history" while a pass is staging
leaves no path marked as the app's own without a finished upload (check `handled_paths` in the
database).

---

## Step S. Same name and size means the same file

**Decided (user, 2026-11-07).** A file in storage with the same name and exact byte size as a photo's
file is that file. This applies to both the drive and the bucket.

**Problem.** When something is already at a photo's path and the app hasn't recorded it as its own (a
drive new to the app, a reinstall, a restore to a new phone), the app:
- reads the whole original out of Photos, downloading it from iCloud if need be;
- compares the sizes;
- if they match, reads the copy in storage too (the whole drive file, or a download from the bucket)
  and compares the hashes.

For a library already on the drive that's like copying the library twice, and long videos are also what
can stall the continued task.

**Change.**
- `PhotoLibrary.fileSize(of:)` reads a resource's size from `PHAssetResource`'s undocumented `fileSize`
  property, guarded with `responds(to:)` so a missing property returns nil instead of crashing.
- The comparison is written once, in `BackupPaths`, and used by `resolve` (naming), `BackupEngine.stage`
  (the bucket) and `DriveBackupEngine.copy` (the drive):
  - same size as the copy in storage → the same file, and nothing is read;
  - a different size → a different picture, which goes to the next free name as now;
  - the photo's size can't be read → today's full comparison (export and hash).
- The size in storage comes from the listing for the bucket, and from the listing or a `stat` of the
  file for the drive.
- **Edited versions are still compared in full.** An edit keeps its name when re-edited, so the name
  says nothing about its content. The app's own older edit is replaced, as now.
- The bucket's `If-None-Match` guard on uploads to a name that's taken stays as it is.

**Tests.** The decision moves into SyncKit as a function of (is edit, photo's size, sizes in storage):
same size, different size, unknown photo size, an edit with the same size, several copies (drive and
bucket) of which one differs.

**Check.** Fill the drive folder with the fixture library, forget the drive's history and run the drive
pass. Photos isn't read for any of the photos already there (step 0's `export` log). Then put a
different file of a different size at one photo's name on the drive: that photo goes to the next free
name. Do the same against bucket A, after deleting the app and reinstalling it.

**(phone)** The first pass over the real drive takes minutes rather than hours.

**Risk.** Low, and accepted. Two different pictures with the same name and exactly the same size would
be taken as one, and the phone's photo wouldn't be copied. That needs a name clash (a camera counter
wrapping, another phone's names) and an exact byte match.

---

## Step 1. Shared SQLite wrapper

**Problem.** `AnalysisStore` repeats `BackupStore`'s SQLite plumbing almost line for line and has
drifted: `AnalysisStore.remove` uses a bare `BEGIN`/`COMMIT` with no rollback, and it has a nullable
`double()` helper that `BackupStore` inlines. Finding the Application Support folder is written four
times.

**Change.**
- Add `SQLiteDatabase` to SyncKit, with:
  - opening with WAL, and `synchronous` as a parameter (`BackupStore` stays at SQLite's default, FULL;
    `AnalysisStore` keeps NORMAL);
  - one lock, `execute`, `query`, the prepared-once `insert(_:rows:bind:)`;
  - `transaction` keeping `BackupStore`'s `inTransaction`/`statementFailed` behaviour and rollback;
  - column readers for text, nullable double and blob, and binding for `Data`.
- `BackupStore` and `AnalysisStore` each own one and keep their schema, queries and public APIs.
  `handledTransaction`'s version bump stays in `BackupStore`.
- The existing migrations move into transactions that bump `user_version` only on success.
- `AnalysisStore.remove` deletes in batches inside a real transaction.
- `AppDirectories.support` resolves to exactly today's path and is used in all four places. `Staging`
  keeps `isExcludedFromBackup`.

**Tests.** `SQLiteDatabaseTests`: rollback when a statement fails partway (the trigger technique from
`BackupStoreTests.openWithFailures`), nullable reads, blob round trip, `insert` stopping at the first
failure, a migration that fails leaves `user_version` unchanged. Every existing `BackupStoreTests` passes
unchanged.

**Check.** Upgrade from `main`'s build: the app opens with its databases intact, with the same backup
counts, the analysis cache (Duplicates doesn't re-analyze) and the same trips. The drive folder is still
chosen (a new empty database would forget it).

**Risk.** Low.

---

## Step 2. Handled-paths writes: less often, one writer

**Problem.** `writeInterval = 500` counts version bumps, which happen about twice per photo. Each write
builds the whole file (every row, sorted, JSON-encoded line by line), PUTs it to the bucket and
rewrites it on the drive. At 100,000 entries that's 10–15 MB. A first backup of 50,000 photos rewrites
it about 200 times, which is 2–3 GB of extra upload and drive writes.

**Change.**
- Write when at least 5 minutes have passed since the last write and something changed, plus the
  forced write at the end of a pass. The last-written time lives in meta, per destination (as
  `written-*` does today).
- Writes go through F4's per-destination writer.
- One reused `JSONEncoder`, building the data in one buffer.
- Not appended deltas: the file has to stay one readable file for a reinstall or another phone.

**Tests.** The due-check moves into SyncKit: the time limit, nothing changed, forced with no change,
forced with a change.

**Check.** During a first backup of the large set to bucket A, the file in the bucket updates every few
minutes, not every few hundred photos (step 0's `handled-paths` log and the object's versions). After
deleting and reinstalling the app, it's still merged, and a photo deleted before the reinstall isn't
imported again.

**Risk.** Low-medium. Up to 5 minutes of handled paths can be missing from the file after a crash. For
photos that still exist, the listing and the copies' tags cover that. For photos deleted in those 5
minutes, nothing does: they could be imported again after a reinstall. That window exists today too
(500 changes), just shorter on a busy pass and longer on a slow one.

---

## Step 3. Pass runner and status

**Problem.** The three engines implement the same pass lifecycle and the same status reporting, and
have drifted (`BackupEngine` didn't clear old errors until 82ddb77). `LibrarySyncEngine.run` sets
`progressHandler = nil` when any caller finishes, even one that passed none, which drops the drive
pass's handler.

**Change.**
- `PassRunner` in SyncKit: `start(_ body:)` returning whether it's new, `join()`, `run()` passing
  cancellation through (as ab63cd4 does by hand), `cancel()`, and an `onEnd` hook that runs on every
  exit path. Its API is designed now for step 7, which cancels parts of a run separately.
- `PassStatus`: the shared fields and the one error rule, as a struct each `@Observable` status class
  holds (composition, since `@Observable` classes don't subclass well). `lastFinished` is stored under
  a key given at init.
- The three engines use both. `TripsModel` and `CleanupModel` keep their few lines of main-actor
  single-flight: an actor-based runner would only add hops.
- The `progressHandler` bug: only the caller that set it clears it. Step 7 removes the handler.

**Tests.** `PassRunnerTests`: two starts make one pass; `join` waits; cancelling a `run()` caller
cancels the pass; a start after it ends makes a new one; `onEnd` runs on every exit; a second run
started while one is going joins it. `PassStatus` error rule.

**Check.** Pause and resume each row. Errors clear when a pass starts (`s3.sh down` to cause one, then
`s3.sh up`). Pausing the drive during its sync step stops the sync (temporary: step 7 changes this).

**Risk.** Medium-low.

---

## Step 4. Destinations, without a schema change

**Problem.** "Whose listing is this?" is answered in pieces: the `current-bucket` comparison and the
"older form" check in `prepareS3`, `hasListedS3` requiring the current bucket (15fdf42). The
`recheck-conditional-writes` flag is global while its answer is per bucket. Choosing a new drive folder
leaves `drive-listing-<old id>`, `merged-drive-<old id>` and `written-drive-<old id>` behind. The drive
and the bucket notice a change differently: the drive gets a new ID in `SettingsStore.setDrive`, the
bucket is noticed later in `prepareS3` because its settings are saved on every keystroke.

**Change.**
- A `Destination` value in SyncKit, `.drive(id)` or `.bucket(identity)`, whose string form names its
  meta keys.
- The recheck flag becomes per bucket, credited to the bucket the upload was sent to (F2/F3 store that
  on the resource row), not to the current settings.
- Changing the drive folder deletes the old folder's meta keys.
- One "destination changed" path for both, run when it's first used after settings change. For the
  bucket that's F1's history reset. For the drive it's what `setDrive` does now.

**Tests.** In SyncKit, over identity strings: the recheck flag applies to one bucket; a folder change
leaves no keys behind; the older identity form is accepted once.

**Check.** Change the drive folder and back: no stale keys in `meta`. Switching from bucket A to B and
back doesn't re-probe or re-merge A. A 501 from one bucket only makes that bucket be re-checked.

**Risk.** Low. Per-destination tables (`remote_files`, own-file flags, completion) were D1, dropped.

---

## Step 5. Upload events

**Problem.** `BackupEngine` polls `count(.uploading)` every second for an upload slot and every
2 seconds for the end of uploads, with a 2-minute stall limit (89c78ee) as a guess. The retry for
names the bucket refused (412) is a recursive `performPass(isRetry:)`.

**Change.**
- **The store is the only source of truth.** `UploadSession` sends a "something changed" signal after
  each store update, fanned out to any number of listeners (not one `AsyncStream`, which has a single
  consumer). Listeners re-read the store's counts after subscribing and after every wake-up, so a missed
  or stale signal can't hang them. A timeout stays as a backstop.
- **Upload slots.** In the foreground, waiting for a slot wakes on the signal instead of sleeping.
  Uploads created while the app is in the background are discretionary and rate-limited by iOS (the
  delay doubles with each background resume), so background runs stage up to a disk budget instead of
  8 in flight and don't wait for slots.
- **The pass ends once everything is staged.** The row shows "N uploading" from the counts.
- **Refused names.** On a 412, HEAD the key and add it to the listing, so the next pass compares it and
  can adopt this phone's own earlier upload (the case `UploadSession` promises). The resource is already
  back to pending (`retirePaths(forResource:)`), so a normal pass picks it up. The special retry pass
  goes away.
- **Settling** (the uploading count reaches zero) asks the step 2 writer for a write under its time
  rule, not a forced one.
- **Background relaunch for upload events.** The completion handler from
  `handleEventsForBackgroundURLSession` is called promptly. The handled-paths write is never done in
  that window: if one is due, the file is encoded to disk and queued as a background-session upload, or
  left for the next run.
- `uploadStallLimit`, the polling and `performPass(isRetry:)` go away.

**Tests.** A `SettleTracker` in SyncKit that reads the store's counts on each signal: settling, a reset
mid-flight (the `superseded` case), signals arriving before anyone listens, duplicate signals.

**Check.**
- Stop Moto (`s3.sh down`) mid-backup: the pass ends after staging and the row says "N uploading". Start it again (`s3.sh up`; its data is gone, so refill the bucket):
  they finish.
- A 412: after the pass's listing, put a different object at a photo's path with `s3.sh put`; the upload is
  refused and the photo gets the next name on the following pass. Repeat with the same bytes: it's
  adopted, not duplicated.

**(phone)**
- On cellular with cellular uploads off: the pass ends after staging and the row says "N uploading".
  Turning Wi-Fi on lets them finish without opening the app.
- Mid-upload, send the app to the background and stop it from Xcode (not by swiping it away, which
  cancels the transfers): when the uploads finish, iOS relaunches it and the counts update.

**Risk.** Medium. Background relaunch timing only shows on the device.

---

## Step 6. One library snapshot per activation

**Problem.** Coming to the foreground enumerates the whole library up to four times
(`BackupStatus.refresh`, both engines' `pendingAssets`, `TripsModel.fetchLibrary`). Each reloads
`importedAssetIDs()`, and each `setLibraryAssets` rewrites the `library` table.

**Change.**
- `LibrarySnapshot.current()`, single-flight, built off the main thread, holding what every user needs:
  own asset IDs (imported copies left out), modification and creation dates, media type, location,
  screenshot and burst flags for trips, and every burst shot for Cleanup.
- Users ask the provider. Step 7's coordinator calls the same provider.
- `setLibraryAssets` runs once per snapshot.
- The modification date recorded for a backup is read from the `PHAsset` that was exported, before
  exporting, never from the snapshot, so an edit made between snapshot and export isn't lost.
- `backupCandidates`' tag check stays the authority for imported copies, whatever the snapshot says.
- No persistent change tokens (D2, dropped).

**Tests.** The filtering (pending by completed and modified dates, imported left out, trips' rules)
moves into SyncKit over plain values.

**Check.** Opening the app enumerates the library once (step 0's log). A photo added with
`simctl addmedia` while the app is open is picked up on the next activation, and trips update.

**Risk.** Medium-low.

---

## Step 7. Run coordinator, which owns the continued task

**Problem.** Nothing owns "a run", so the engines start each other: `BackupEngine` ends by starting a
sync, the drive pass runs a sync inside itself, `BackgroundTasks.handle` runs both engines and then a
sync, and `LibrarySyncEngine.startFromUI` runs a whole drive backup just to get background time. One
background run can start sync three times, and the listings were repeated until the two 10-minute
freshness windows papered over it. The continued background task belongs to the drive engine, so the
sync only gets background time by borrowing a drive pass.

**Change.**
- **A `BackupRun` actor is the one entry point.** Every current caller goes through it:
  - app activation;
  - the background processing task;
  - the rows' start and pause buttons and "Sync now";
  - `DriveMonitor` noticing the drive;
  - the settings sheet's `onDismiss` (ContentView);
  - `requestPhotoAccess`;
  - `SettingsStore.setDrive`/`forgetDrive`.
- **It runs, in order:**
  1. the snapshot (step 6);
  2. preparing storage once: the drive listing, resumable as now, and the bucket listing;
  3. bucket staging and drive copying side by side, serialized per photo with a lock, so the two
     never work on the same photo's paths at once;
  4. the sync, using what step 2 prepared.
- **The engines become steps it calls.** They stop starting each other, and `startFromUI`'s drive pass
  goes.
- **Freshness.** "Prepared this run" replaces the windows in `StorageInventory`. Repeated foreground
  activations are throttled by one stated rule: no new run within 5 minutes of the last one finishing,
  unless the user taps a button. A bucket that can't refuse overwrites is always listed before staging,
  whatever the throttle.
- **Pausing a row cancels just that part** (`PassRunner`). Pausing the drive no longer stops a sync
  the user didn't start from it.
- **The continued task** (`ContinuedRunTask`, replacing `DriveBackgroundTask`):
  - It's requested only in direct response to a tap, synchronously in the button handler, before any
    preparation. If preparation finds nothing to do, the task completes with success at once.
  - Runs started by activation or the background task never request one. Activation runs use
    `beginBackgroundTask` to reach a safe stopping point when the app is left.
  - A tap during a run that has no task requests one and attaches it to that run. A tap during a run
    that has one joins it, so there is never a second task.
  - One task per run, registered per instance under the existing `org.barelyenough.ios-photos-tools.drive.*`
    wildcard. The prefix is renamed (and Info.plist updated) since it covers sync too.
  - It ends when the run's last step ends. It isn't held open waiting for uploads, which belong to the
    background session (step 5).
  - Expiry and user stops look the same, so it reports success and the row says "Stopped".
  - Progress keeps today's mechanism (listing steps and the heartbeat), moved into `ContinuedRunTask`.
    Step 8 replaces it.
- **The background processing task.** Its expiration handler cancels the run and calls
  `setTaskCompleted(success: false)` after a short bounded wait, not after the run ends. A run started
  by it that's still going when the user opens the app carries on, and a tap can attach a continued
  task to it.
- **Background runs.** "Drive not reachable" is a normal outcome (a locked phone may not see the
  drive). If the database can't be opened (for example before first unlock), the run is skipped
  instead of crashing (`BackupStore`'s `fatalError` goes).

**Tests.**
- A `RunPlan` value in SyncKit says which steps and preparations a run needs: no drive, no bucket, sync
  off, a bucket without conditional writes, a destination that just changed, and the throttle rule.
- Concurrency (a run started while another is going, attaching a task to a running run) is tested in
  `PassRunnerTests`.

**Check.**
- With the drive folder chosen: one drive listing, one bucket listing, then copying and staging, then
  sync (step 0's log).
- Pausing the drive row leaves bucket staging running.
- Opening the app twice within 5 minutes starts one run. Bucket B with conditional writes turned off
  (or a second Moto) is listed before staging even then.
- With the drive folder deleted from Files, a run treats the drive as not reachable and carries on.

**(phone)**
- A simulated background run lists the bucket once.
- Tapping "Sync now" with no drive gives a continued task, and the sync carries on after leaving the
  app.
- Plugging in the drive with the app open gives a continued task. Opening the app with nothing tapped
  or plugged in shows no system progress notification.

**Risk.** High. It changes when everything runs.

**Decided (user, 2026-11-07).** Plugging the drive in counts as the user's action, so `DriveMonitor`
noticing the drive while the app is open still requests a continued task, as it does today.

---

## Step 8. Real progress for the continued task

**Problem.** Progress is partly made up: the heartbeat in dc64835 nudges it every 5 seconds within a
step, and listing counts callbacks as steps.

**Change.**
- One parent `Progress` with a child per step, added with `addChild(_:withPendingUnitCount:)` and a
  fixed share, so the parent never goes backwards when a step learns its size. Each step reports in its
  own real units:
  - listing: files read;
  - copying to the drive: bytes, from `PhotoLibrary.stream`'s data handler;
  - iCloud downloads: `PHAssetResourceRequestOptions.progressHandler`'s fraction, mapped into the
    child's units;
  - hashing: bytes, from `Staging.sha256`'s chunks;
  - importing: pictures.
- `export` (`writeData`) has no data callback, so where progress matters during a step, use `stream` to
  a temporary file instead.
- The heartbeat stays, inside `ContinuedRunTask`, with its cap, as the guard for work with no signal.
  Developers report iOS advancing only on whole units, and the stall rule isn't documented, so it isn't
  removed.
- `showSyncProgress`, `listingSteps`, `progressHandler` and the `found + 1` arithmetic go away.

**Tests.** The aggregation (shares, fraction never going backwards, the heartbeat's cap) as a value
type in SyncKit.

**Check.** The progress aggregation's tests. On the simulator, the progress values (logged by step 0)
only go up through listing, copying and sync.

**(phone)** Start a drive backup and leave the app: the progress bar moves through listing, copying and
sync, with no "task failed" notifications. Pausing gives only "Paused".

**Risk.** Medium.

---

## Step 9. Reuse comparison exports

**Problem.** After step S, full comparisons are left only for edited versions and for photos whose size
can't be read. For those, `BackupPaths.resolve` exports the photo (downloading from iCloud if needed),
hashes one copy in storage (the drive's if it can, else the bucket's, falling back silently through
`try?`), then throws that away, and `stage` and `copy` export and compare again.

**Change.**
- What `assign` learned is recorded **per destination, for the bytes actually read**: "drive copy
  hashed, identical", "bucket copy size differs", and so on. "Identical" counts only for the destination
  whose bytes were read. Any other destination still compares, reusing the export's hash.
- The silent drive-to-bucket fallback in `sha256(ofExisting:)` goes: it says which copy it read.
- The export (file, size, SHA-256) is handed over instead of deleted. With the step 7 coordinator, the
  bucket and drive parts share one export per photo (they're serialized per photo already). Not
  identical → the bucket uploads it from `Staging`, and the drive copies it to its `.partial` file.
- `sha256(ofExisting:)` takes the open drive root and the existing client and session.
- Exports count against a disk budget covering both parts.

**Tests.** The "learned" value: the drive matches and the bucket has the same size but different
content → the bucket isn't marked done; can't compare; no export.

**Check.** Edit a few photos already in the drive folder and in bucket A, then forget the drive's history
and run: each edited photo is read from Photos once (step 0's `export` log).

**Risk.** Medium. With step S in place this matters much less. Re-check that it's still worth doing
before starting it.

---

## Step 10a. Backup counts off the main thread

**Problem.** `BackupStatus.refreshCounts()` runs on the main actor and waits on `BackupStore`'s lock,
which is held through long transactions. It's called for every staged photo and upload completion.

**Change.** Counts are fetched in a detached task and coalesced, like the coverage refresh beside them.
No second database connection: it couldn't see the TEMP `library` table that coverage joins.

**Check.** With the large set, scrolling and tapping stay smooth during a first backup to bucket A
(Instruments' hangs report on the simulator).

**(phone)** The same on the phone, whose speed is what matters.

**Risk.** Low.

## Step 10b. Cleanup and Trips off the main thread

**Problem.** `CleanupModel` fetches every image, loads every analysis (around 150 MB of feature prints
for 50,000 photos) and groups them on the main thread, even for a "recent" scan, and regroups the whole
library each time the slider is released. `DuplicateGrouper` computes feature-print distances twice.
`TripsModel.stored`'s `didSet` re-encodes and writes `trips.json` on the main thread for every field
change.

**Change.**
- First, move `DuplicateGrouper` into a package (TripKit has `FeaturePrint`) and write tests of its
  current results.
- Then: fetch, load and group detached; `.recent` loads only the analyses it needs
  (`AnalysisStore.analyses(ids)`); each distance is computed once.
- `TripStore` saves debounced, off the main thread.

**Tests.** The grouper's results before and after, and a counting closure showing each distance is
computed once.

**Check.** With the large set, Duplicates opens without a pause and the slider doesn't hang (Instruments'
hangs report).

**(phone)** The same on the phone.

**Risk.** Low-medium.

---

## Dropped

**Decided (user, 2026-11-07).** Not doing these:
- **D1, per-destination schema.** F1 makes switching buckets reset that bucket's history instead.
- **D2, persistent change tokens.** Step 6's single enumeration per activation is enough.
- **D3, finding imports from the album.** The full scan stays.

## Not in this plan

- Appended deltas for the handled-paths file.
- Bulk attribute reads in the drive listing, which conflict with the checkpointed, sorted listing.

---

## Review log

**Data safety.**
- Found bugs that exist today. These became step F:
  - the bucket "done" state carrying over to a new bucket (F1);
  - a reset racing staging (F2);
  - the engines racing on paths (F3);
  - handled-paths writers out of order (F4);
  - an empty TEMP library table (F5).
- Showed that "identical at this destination" isn't what `resolve` checks. Step 9 now records per
  destination and drops the silent fallback.
- Showed that the album-first rule can't be evaluated when the scan actually runs, and that a replace
  could shrink the record. D3 now requires union and a full scan when unsure.
- Showed that a kept listing must not be treated as fresh. Step 7 and D1 now always list a bucket that
  can't refuse overwrites.
- Showed 412 adoption needs the refused key in the listing. Step 5 now HEADs it.
- Corrected the plan's claims about the retry pass, the forced write, A → B → A, and what the
  handled-paths file can be rebuilt from.

**iOS platform.**
- The continued task must start from a tap, before any preparation. Step 7 now requests it in the
  button handler and never for activation runs, and it raised the `DriveMonitor` question.
- Background uploads are discretionary and rate-limited. Step 5 stages to a disk budget in the
  background instead of waiting for slots.
- The relaunch window is short and undocumented. Step 5 no longer writes the file there.
- PhotoKit reports iCloud download progress as a fraction, and `writeData` has no data callback.
  Growing totals make progress go backwards. Step 8 now uses child `Progress` objects with fixed shares
  and keeps the heartbeat.
- Swiping the app away cancels transfers and continued tasks. The step 5 check was rewritten.
- `library` is a TEMP table. Change tokens moved to D2 with a real table, and the read-only connection
  was dropped from step 10a.
- BGProcessingTask expiry must complete promptly. A locked phone may not see the drive. The database
  `fatalError` must go. All three are now in step 7.

**Sequencing.**
- Steps 8 and 9 couldn't ship separately. Ownership of the continued task moved into the coordinator
  (step 7), and step 8 is progress only.
- Handled-paths writes moved before upload events, because events add writes.
- The old step 3 was split: the meta-key fixes are step 4, and the schema change is D1.
- The old step 7 was split: the snapshot provider is step 6, and change tokens are D2.
- The old step 10 was split into 10a and 10b, with the grouper moved into a package and tested first.
- Step 1 keeps `BackupStore` at FULL synchronous.
- Step 3 leaves `TripsModel`/`CleanupModel` alone and uses composition for the status.
- Added step 0 so the phone checks can be observed.
- Completed step 7's list of entry points.
- Made the throttle a stated number.
- Moved concurrency tests out of `RunPlan`.

**Decisions after the reviews (user, 2026-11-07).**
- Plugging in the drive counts as the user's action for the continued task.
- D1–D3 dropped.
- Same name and size means the same file, for both the drive and the bucket (step S).
- Checks run on the simulator, with a local Moto for the bucket and `Documents/TestDrive` for the drive. Only
  what the simulator can't do runs on the phone.
