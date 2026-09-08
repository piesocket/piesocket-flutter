
## Who can publish

You need a pub.dev account listed as an uploader on `piesocket_channels`
(the `piesocket` / Pie.host publisher). First publish from a new machine
opens a browser for Google OAuth and caches the token under
`~/Library/Application Support/dart/pub-credentials.json`.

## 1. Pre-flight

- [ ] `pubspec.yaml` `version:` is the version you intend to ship (`7.0.0`).
- [ ] `CHANGELOG.md` has a top entry whose heading matches that version
      exactly — pub.dev rejects a publish whose version has no changelog
      section.
- [ ] `README.md` reflects any new/changed API (`sendBinary`, screen share).
- [ ] Working tree is clean except for the release commit you're about to
      make. `pubspec.lock` is gitignored (libraries don't commit it).

## 2. Verify locally

```sh
cd sdks/piesocket-flutter
flutter pub get
flutter analyze
flutter test
flutter pub publish --dry-run
```

`--dry-run` runs pub.dev's validation (package layout, `pubspec` metadata,
file size, license) and lists exactly the files that will be uploaded.
Resolve every warning before continuing — pub.dev scores packages on a clean
`analyze`, dartdoc coverage, and an up-to-date SDK constraint.

## 3. Publish

```sh
flutter pub publish
```

Review the file list one more time, type `y`. The version is now live and
**immutable** — you cannot re-upload `7.0.0`; a fix means `7.0.1`.

## 4. Tag and push

```sh
# from sdks/piesocket-flutter (its own git repo: github.com/piesocket/piesocket-flutter)
git add pubspec.yaml CHANGELOG.md README.md lib test
git commit -m "v7.0.0 - binary send + PieRTC screen-share renegotiation"
git tag v7.0.0
git push origin main --tags
```

Then, in the parent `piesocket-server` repo, commit the bumped submodule
pointer.

## 5. Post-publish: cut the demo over to the published package

`demos/flutter-demo` builds against the in-repo SDK via a
`dependency_overrides` block. Once `7.0.0` is on pub.dev:

1. In `demos/flutter-demo/pubspec.yaml`, delete the
   `dependency_overrides:` block (and its `── Local SDK ──` comment header).
   The dependency constraint is already `piesocket_channels: ^7.0.0`.
2. `cd demos/flutter-demo && flutter pub get` — confirm it resolves
   `piesocket_channels 7.0.0` from pub.dev.
3. Smoke-test the demo, then commit.

## 6. Cutting a later release

For a routine follow-up (e.g. `7.0.1`, `7.1.0`):

1. Bump `pubspec.yaml` `version:`.
2. Add a matching `CHANGELOG.md` section at the top.
3. Run section 2, then section 3, then section 4 with the new version/tag.

Follow semver: additive API → minor, bug-fix only → patch, any breaking
change → major.
