# Photos Tools

An iOS app with a set of tools for looking after your photo library:

- **Backup** copies your whole library — full-quality originals, Live Photo videos, RAW files and
  edited versions — to an S3 or S3-compatible bucket.
- **USB drive backup** copies the same files to a drive plugged into the phone.
- **Sync to phone** keeps a smaller copy of every picture on the drive and in the bucket in your
  Photos library, so a library much larger than the phone still fits on it.
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

Use keys limited to the backup folder. The app reads as well as writes: it lists the bucket so it
never overwrites a different picture with the same name, and downloads pictures to sync to the
phone. For AWS, create an IAM user with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET/photos/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::YOUR-BUCKET",
      "Condition": {"StringLike": {"s3:prefix": "photos/*"}}
    }
  ]
}
```

Turning on bucket versioning (or Object Lock) protects the backup if the keys ever leak.

## Library layout

The bucket and the drive have the same layout, with the bucket's under its folder:

```
<year>/IMG_1234.HEIC
      /IMG_1234.MOV          (Live Photo video)
      /IMG_1234-edited.jpg   (edited version)
      /IMG_1234 (1).HEIC     (a different photo with the same name)
undated/...                  (no date known)
.photos-tools/handled-paths.jsonl
```

To fill the bucket from an existing drive, run this once from a computer (it's much too much to
send through the phone):

```sh
aws s3 sync /Volumes/YOUR-DRIVE/pictures s3://YOUR-BUCKET/photos/ \
  --exclude '._*' --exclude '*/._*' --exclude '*.csv' --exclude '.photos-tools/*'
```

## How backup works

- `Packages/S3Kit` — AWS SigV4 signing with no dependencies (`swift test` checks it against AWS's
  published examples).
- `BackupEngine` finds photos not yet backed up, exports each original file (downloading it from
  iCloud if necessary) to a staging folder, and hands it to a background `URLSession` with a 7-day
  presigned PUT URL, so iOS can finish the upload even after the app is suspended.
- `BackupStore` (SQLite) records which files have uploaded. Failed files are retried on the next run.
- A photo's paths are chosen once (`BackupPaths`) and used for both the bucket and the drive. A file
  already at a path is compared by SHA-256: if it's the same photo the path is adopted, otherwise the
  photo gets the next free name. Uploads of originals also send `If-None-Match: *`, so the bucket
  refuses to overwrite anything even if the listing was out of date.
- Photos modified since their last backup are checked again. An edited version is re-uploaded
  when its contents have changed (compared by SHA-256).
- Backups run when the app opens and, through `BGProcessingTask`, whenever iOS grants
  background time (charging or not).

## USB drive

Photos can also be copied to a USB drive (or any folder in Files). Plug in the drive, open
Settings → *USB drive* → **Choose folder on drive…**, and pick your pictures folder. It gets the
same layout as the bucket, without the folder prefix.

- iOS doesn't tell apps when a drive is plugged in and won't launch an app for one, so the app
  checks for the drive every few seconds **while it's open**. Plug the drive in, open Photos Tools,
  and copying starts on its own.
- Once started, the copy keeps going after you leave the app (`BGContinuedProcessingTask`, with
  progress shown by the system) until it finishes or you stop it.
- If the drive happens to be plugged in when iOS runs a background backup, it's copied to then too.
- Files are written under a temporary name and renamed when complete, so a partly written file never
  has the real name. Originals already on the drive are skipped; edited versions are rewritten when
  a photo changes.

## Sync to phone

Settings → *Sync to phone* → **Set up sync…** shows how many pictures would be added and how much
room they'd take, and starts when you confirm. After that it runs by itself after each backup.

- Pictures become 2048-pixel HEICs, about 290 KB each. Ones that are already small, and GIFs, are kept
  as they are. Videos stay in storage.
- Copies go in your Photos library, with their original date and location, and in a **Drive Library**
  album. Pictures with no date get January 1 of their folder's year. Those in `undated/` get
  January 1, 2000, and also go in an **Undated** album.
- The drive is read when it's connected, since it's faster and free. Otherwise pictures are downloaded
  from the bucket, on Wi-Fi unless *Use cellular data* is on, which your provider may charge for.
- If iCloud Photos is on, the copies upload to iCloud too and count against your storage.
- It stops when the phone has less than 10 GB free, and picks up where it left off after any
  interruption.
- It only adds. A picture removed or changed in storage is left alone on the phone.

Copies are kept apart from your real photos: they're never backed up, and Duplicates and Trip albums
ignore them. Photos taken on the phone stay at full resolution.

**What's been dealt with.** A path that's been backed up or imported is never imported again, so
photos you delete stay gone, here and in storage. That's recorded in two places outside the app, so
reinstalling doesn't produce duplicates or bring deleted photos back:

- The file name of each copy has a tag, a hash of its path: `IMG_1234.ptk-9f3a2c1b7d04.HEIC`. This
  identifies copies with no database, drive or network. You can see it in the photo's info.
- `.photos-tools/handled-paths.jsonl` on the drive and in the bucket lists every path dealt with,
  including deleted photos. Don't delete it from both.

Sync needs full photo access, because with limited access it can't see all of its copies.

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
