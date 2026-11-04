# Photos Tools

An iOS app with a set of tools for looking after your photo library:

- **Backup** copies your whole library — full-quality originals, Live Photo videos, RAW files and
  edited versions — to an S3 or S3-compatible bucket.
- **USB drive backup** copies the same files to a drive plugged into the phone.
- **Duplicates** finds near-identical shots, picks the best of each group, and lets you delete
  the rest.
- **Trip albums** finds trips and makes an album of the best photos from each place you visited.

More tools will be added over time.

## Running it

1. Open `IOSPhotosTools.xcodeproj` in Xcode.
2. Under *Signing & Capabilities*, pick your team (change the bundle ID if it clashes).
3. Run it on your phone, tap the gear, and enter the endpoint, region, bucket and keys.
   Tap **Test connection**.

## Credentials

Use keys that can only write to the backup bucket. For AWS, create an IAM user with:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::YOUR-BUCKET/photos/*"
  }]
}
```

Turning on bucket versioning (or Object Lock) protects the backup if the keys ever leak.

## Bucket layout

```
<folder>/<year>/<month>/<asset-uuid>/IMG_1234.HEIC
                                    /IMG_1234.MOV          (Live Photo video)
                                    /FullSizeRender.jpg    (edited version)
```

## How backup works

- `Packages/S3Kit` — AWS SigV4 signing with no dependencies (`swift test` checks it against AWS's
  published examples).
- `BackupEngine` finds photos not yet backed up, exports each original file (downloading it from
  iCloud if necessary) to a staging folder, and hands it to a background `URLSession` with a 7-day
  presigned PUT URL, so iOS can finish the upload even after the app is suspended.
- `BackupStore` (SQLite) records which files have uploaded. Failed files are retried on the next run.
- Photos modified since their last backup are checked again. An edited version is re-uploaded
  when its contents have changed (compared by SHA-256).
- Backups run when the app opens and, through `BGProcessingTask`, whenever iOS grants
  background time (charging or not).

## USB drive

Photos can also be copied to a USB drive (or any folder in Files). Plug in the drive, open
Settings → *USB drive* → **Choose folder on drive…**, and pick a folder. The drive gets the same
layout as the bucket, without the folder prefix.

- iOS doesn't tell apps when a drive is plugged in and won't launch an app for one, so the app
  checks for the drive every few seconds **while it's open**. Plug the drive in, open Photos Tools,
  and copying starts on its own.
- Once started, the copy keeps going after you leave the app (`BGContinuedProcessingTask`, with
  progress shown by the system) until it finishes or you stop it.
- If the drive happens to be plugged in when iOS runs a background backup, it's copied to then too.
- Files are written under a temporary name and renamed when complete, so a partly written file never
  has the real name. Originals already on the drive are skipped; edited versions are rewritten when
  a photo changes.


## Duplicates

The Duplicates screen scans either recent photos (since the last full scan, or the last 30 days)
or the whole library, and groups photos that look like the same shot.

- Each photo gets a Vision feature print, an aesthetics score, a face-quality score, a sharpness
  measure and a difference hash. Results are cached in `AnalysisStore`, so later scans only
  analyze new or changed photos.
- Only photos taken close together in time are compared, so a burst or a few retakes form a group
  but similar scenes from different days don't. Exact copies (same hash and size) are grouped no
  matter when they were taken.
- The **Match** slider runs from near-identical to loosely similar.
- In each group the best photo is kept: favourites first, then a blend of aesthetics, face quality
  and sharpness. The rest are marked for deletion. Tap a photo to change that. Photos you choose to
  keep are never suggested again.
- Deleting goes through the system's confirmation, and deleted photos go to Recently Deleted.

## Trip albums

Trips are found automatically and each one gets an album in a **Trips** folder in Photos, with no
setup. This happens when the app opens and whenever iOS gives it background time.

- **Usual places.** Photos are grouped into cells about 10 km across. A cell with photos on at least
  8 days spread over at least 3 months is somewhere you live or work rather than visit.
- **Trips.** A trip is a run of photos taken away from your usual places. It ends when a photo is
  taken at a usual place again or when no photos are taken for 2 days, and needs at least 12
  geotagged photos. A trip that may still be going on doesn't get an album yet.
- **Places within a trip.** Moving more than about 750 m or a 90-minute gap starts a new place. Going
  back to a place joins the earlier visit. Photos without a location join a place if they were taken
  within 10 minutes of a geotagged photo there.
- **Picks.** Retakes are collapsed with the duplicate finder, and screenshots, receipts and poor shots
  are skipped. Each place gets 1–3 photos depending on how many different shots were taken there.
  The app aims for one of people (a face or a person large in the frame) and one of the place itself,
  then adds more only if they look clearly different. Favourites come first.
- **Changing an album.** Open *Trip albums*, pick a trip, and remove photos or tap *Choose photos*
  for a place. Changes go straight to the album. Changes made in Photos count too: adding or removing
  photos, or renaming the album. Your changes are kept when the trip is checked again. If you delete
  an album it isn't made again unless you tap *Create album*.
- Turn it off under Settings → *Trip albums*.
- The trip logic is in `Packages/TripKit` (`swift test` runs its tests).

## Known backup limitations

- Each file is sent in a single PUT, so files over 5 GB fail (no multipart upload).
- Re-editing a photo overwrites its `FullSizeRender` in the bucket. Turn on bucket versioning to
  keep earlier edits. (The original is never overwritten.)
- Deleting a photo on the phone doesn't delete it from the bucket (on purpose).
- Hidden photos are included; to exclude them, set `includeHiddenAssets` in `PhotoLibrary.swift`.
