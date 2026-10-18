# Photo Backup

An iOS app that copies your whole photo library — full-quality originals, Live Photo videos,
RAW files and edited versions — to an S3 or S3-compatible bucket.

## Running it

1. Open `PezraPhotos.xcodeproj` in Xcode.
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

## How it works

- `Packages/S3Kit` — AWS SigV4 signing with no dependencies (`swift test` checks it against AWS's
  published examples).
- `BackupEngine` finds photos not yet backed up, exports each original file (downloading it from
  iCloud if necessary) to a staging folder, and hands it to a background `URLSession` with a 7-day
  presigned PUT URL, so iOS can finish the upload even after the app is suspended.
- `BackupStore` (SQLite) records which files have uploaded. Failed files are retried on the next run.
- Backups run when the app opens and, through `BGProcessingTask`, whenever iOS grants
  background time (charging or not).

## Known limitations

- Each file is sent in a single PUT, so files over 5 GB fail (no multipart upload).
- If you edit a photo after it's been backed up, the new edit isn't uploaded.
- Deleting a photo on the phone doesn't delete it from the bucket (on purpose).
- Hidden photos are included; to exclude them, set `includeHiddenAssets` in `PhotoLibrary.swift`.
