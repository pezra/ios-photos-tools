# Photos Tools

An iOS app for looking after your photo library.

- **Backup** copies full-quality originals, Live Photo videos, RAW files and edited versions to an S3 or S3-compatible bucket.
- **USB drive backup** copies the same files to a drive plugged into the phone.
- **Sync to phone** keeps a smaller copy of every picture in storage in your Photos library, so a library much larger than the phone still fits on it.
- **Duplicates** finds near-identical shots and lets you delete all but the best of each.
- **Trip albums** makes an album of the best photos from each place you visited.

## Installation

1. Open `IOSPhotosTools.xcodeproj` in Xcode.
2. Under *Signing & Capabilities*, pick your team (change the bundle ID if it clashes).
3. Run it on your phone, tap the gear, and enter the endpoint, region, bucket and keys. Tap **Test connection**.

Apps signed with a free Apple account stop opening after 7 days. `scripts/renew-phone-app.sh` rebuilds the latest commit on `main` and reinstalls it, keeping the app's data, once less than 3 days are left. To run it every few hours while you're logged in to the Mac:

```sh
cp scripts/org.barelyenough.ios-photos-tools.renew.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/org.barelyenough.ios-photos-tools.renew.plist
```

The first run installs right away, so get what you want on the phone onto `main` first. The Mac has to be signed in to Xcode and able to reach the phone by USB or Wi-Fi. If the app is within a day of expiring and can't be renewed, you get a notification. The log is `~/Library/Logs/ios-photos-tools-renewal.log`. For a different phone, change the device ID at the top of the script.

## Credentials

Use keys limited to the backup folder. They need read access as well as write, because the app lists the bucket before naming a file and downloads pictures to sync them. For AWS, create an IAM user with:

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

On Backblaze B2, use an application key limited to the bucket with `listFiles`, `readFiles` and `writeFiles`.

Turn on bucket versioning (file versions on B2). It keeps earlier edits and protects the backup if the keys ever leak. On B2 it matters more, because B2 can't refuse an upload to a name that's already taken.

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

To fill the bucket from an existing drive, run this once from a computer (it's far too much to send through the phone). For B2, add `--endpoint-url https://s3.YOUR-REGION.backblazeb2.com`.

```sh
aws s3 sync /Volumes/YOUR-DRIVE/pictures s3://YOUR-BUCKET/photos/ \
  --exclude '._*' --exclude '*/._*' --exclude '*.csv' --exclude '.photos-tools/*'
```

## Backup

Backups run when the app opens and whenever iOS grants background time. Files already queued keep uploading after you leave the app, but new ones are only queued while the app is running. Failed files are retried on the next run.

A photo isn't written over a different one with the same name. If a file is already at the path it's compared with the photo: the same photo is left alone, and a different one sends the photo to the next free name. An edited version is replaced when you edit the photo again.

Deleting a photo on the phone doesn't delete it from storage (on purpose). Hidden photos are backed up too. To change that, set `includeHiddenAssets` in `PhotoLibrary.swift`. Files over 5 GB fail, since each is sent in a single PUT.

## USB drive

Plug in the drive, open Settings → *USB drive* → **Choose folder on drive…**, and pick your pictures folder.

iOS won't launch an app when a drive is plugged in, so copying only starts while Photos Tools is open (or if the drive happens to be connected when iOS runs a background backup). Once started, it keeps going after you leave the app, with progress shown by the system, until it finishes or you stop it.

## Sync to phone

Settings → *Sync to phone* → **Set up sync…** shows how many pictures would be added and how much room they'd take, and starts when you confirm. After that it runs after each backup. It needs full photo access.

- Pictures become 2048-pixel HEICs. Ones that are already small, and GIFs, are kept as they are. Videos stay in storage.
- Copies go in your Photos library, with their original date and location, and in a **Drive Library** album. Pictures with no date get January 1 of their folder's year. Those in `undated/` get January 1, 2000, and also go in an **Undated** album.
- Pictures are read from the drive when it's connected. Otherwise they're downloaded from the bucket, on Wi-Fi unless *Use cellular data* is on, which your provider may charge for.
- If iCloud Photos is on, the copies upload to iCloud too and count against your storage.
- It stops when the phone has less than 10 GB free, and picks up where it left off after any interruption.
- It only adds. A picture removed or changed in storage is left alone on the phone.

Copies are never backed up, and Duplicates and Trip albums ignore them. Photos taken on the phone stay at full resolution.

A path that's been backed up or imported is never imported again, so photos you delete stay gone, even after reinstalling the app. Two things outside the app keep track of that:

- The file name of each copy has a tag, which you can see in the photo's info: `IMG_1234.ptk-9f3a2c1b7d04.HEIC`.
- `.photos-tools/handled-paths.jsonl`, on the drive and in the bucket, lists every path dealt with. Don't delete it from both.

## Duplicates

Scan recent photos or the whole library. Only photos taken close together are compared, so a burst or a few retakes form a group but similar scenes from different days don't. Exact copies are grouped no matter when they were taken. The **Match** slider runs from near-identical to loosely similar.

Favourites are kept first, then the best looking shot, and the rest are marked for deletion. Tap a photo to change that. Photos you choose to keep are never suggested again. Deleting goes through the system's confirmation, and deleted photos go to Recently Deleted.

## Trip albums

Each trip gets an album in a **Trips** folder in Photos, with no setup. Turn it off under Settings → *Trip albums*.

A trip is a run of at least 12 geotagged photos taken away from your usual places, which are the ones you photograph repeatedly over several months. It ends when you take a photo at a usual place or take none for 2 days. A trip that may still be going on doesn't get an album yet.

Each place in a trip gets 1–3 photos, with favourites first. Retakes, screenshots, receipts and poor shots are skipped.

To change an album, open *Trip albums*, pick a trip, and remove photos or tap *Choose photos* for a place. Changes made in Photos count too. Your changes are kept when the trip is checked again. If you delete an album it isn't made again unless you tap *Create album*.
