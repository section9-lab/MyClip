# In-app updates

MyClip uses [Sparkle 2](https://sparkle-project.org/documentation/) (pinned to 2.10.1) for native macOS update checks, downloads, signature validation, installation and relaunch. The app menu and Settings → About MyClip both have **Check for Updates…**. Settings can disable the daily automatic check. Downloading and installing an update requires confirmation; silent automatic installation and system profiling are disabled.

Sparkle displays progress, cancellation, network errors, an up-to-date message and the new release's notes. It replaces the running app bundle and uses the normal application termination path, which stops capture and the Agent. It does not replace the library, preferences or Memory files in Application Support. macOS may request administrator authorization if the app's location requires it.

## Feeds and signing

The updater delegate selects `https://github.com/section9-lab/MyClip/releases/latest/download/appcast-arm64.xml` or `appcast-x86_64.xml` using the running binary's architecture. These are assets on the latest stable GitHub Release, so updating the product website cannot overwrite the update feed. The delegate provides the feed URL rather than a fixed `SUFeedURL` because a universal local build can run on either architecture.

Both the update archive and appcast use Ed25519 signatures. `SUPublicEDKey` is committed in `MyClip/Supporting/Info.plist`; its private key is stored in repository secret **`MYCLIP_SPARKLE_PRIVATE_KEY`** and the maintainer's login Keychain under account **`cc.vibevibe.myclip`**. `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require verification before showing release notes or extracting an update. Keep the signing key and the existing community code-signing identity stable across releases. Never commit or publish private keys.

The first release with Sparkle must be installed manually. Older MyClip versions have no updater and cannot acquire this feature themselves. Before that first release is published, the latest Release does not yet contain appcast assets.

## Publishing

1. Increase **both** `CFBundleShortVersionString` and the monotonically increasing **`CFBundleVersion`**. Sparkle compares build numbers, not just the display version.
2. Add `docs/releases/v<version>.md`, commit the source and push the matching version tag as usual.
3. `Release DMG` builds both architectures with the existing community certificate. `Scripts/generate_update_feed.sh` independently derives the signing key's public identity with CryptoKit and matches it against the committed `SUPublicEDKey` before invoking Sparkle; Sparkle tools can otherwise only warn about mismatches. It then uses the pinned tools from SwiftPM to sign the DMG and generate each feed, including version, minimum OS, hardware requirements and embedded release notes from the built app.
4. After both builds and signatures pass, CI uploads the DMGs, both appcasts, certificate and checksums to a draft, then publishes it as the latest release. Already published release assets cannot be overwritten. A retry can finish an existing draft.

To initialize the key for another repository or recover it from a backup, use Sparkle's official `generate_keys --account cc.vibevibe.myclip` tool. Export with `-x` into a temporary file with mode `0600`, set the Actions secret using `gh secret set MYCLIP_SPARKLE_PRIVATE_KEY < <temporary-file>`, then delete the exported file. Match the tool's public key to the committed plist. Do not generate a replacement key for an already released app.

## Verification

`Check native app` builds and tests Apple Silicon and Intel without publishing or using production signing secrets. It exercises the updater's disabled/test lifecycle and generates real signed fixture appcasts using temporary test keys, checking tampering and key mismatch failures. Run locally with Xcode installed:

```sh
bash Scripts/test.sh app
bash Scripts/test.sh updates
```

An isolated local installation smoke check on 2026-10-29 also exercised the actual Sparkle installer: a temporary app downloaded a signed feed and archive, replaced build 1 with build 2, relaunched, and preserved an adjacent data fixture. The installed `/Applications/MyClip.app` was not used or modified. Repeat this exercise when changing installation or relaunch behavior; feed signature tests alone do not cover replacing a running app.
