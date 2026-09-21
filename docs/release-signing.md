# Release signing

MyClip needs a stable Apple code-signing identity to retain Screen Recording and Accessibility grants across updates. Ad-hoc signatures identify each binary by its code hash. They can leave System Settings showing an enabled grant that no longer matches the installed application.

`Scripts/package_dmg.sh` rejects ad-hoc signing and verifies the packaged app against an Apple certificate requirement. CI stops before building if no signing identity is configured; it never silently falls back to an ad-hoc Release.

## GitHub Actions setup

Configure these repository Actions secrets before pushing the next version tag:

| Secret | Value |
| --- | --- |
| `APPLE_SIGNING_CERTIFICATE_P12` | Base64-encoded `.p12` containing the signing certificate and its private key |
| `APPLE_SIGNING_CERTIFICATE_PASSWORD` | Export password for that `.p12` |
| `APPLE_SIGNING_IDENTITY` | Exact certificate name or SHA-1 fingerprint accepted by `codesign` |

Use a **Developer ID Application** certificate for public distribution. An existing **Apple Development** identity is suitable for local development and testing. Keep the bundle identifier and signing identity consistent across updates. Certificates and private keys must not be committed to the repository. Uploading signing material to GitHub requires the certificate owner's authorization.

The workflow imports the certificate into a temporary keychain on each architecture's runner and deletes the keychain and `.p12` after the job. It then packages both architectures and publishes only after all checks succeed. Signing does not itself notarize the application; notarization needs separate Apple credentials and configuration.

Local packaging uses the identity configured in the Xcode project, or an explicit override:

```sh
CODE_SIGN_IDENTITY_OVERRIDE='Developer ID Application: Your Name (TEAMID)' \
  MYCLIP_ARCH=arm64 bash Scripts/package_dmg.sh
```

## Recovering a grant after a signing change

First install a build signed with the previous trusted identity when that identity is available. If an intentional signing transition is necessary, remove only MyClip from the affected permission list, add `/Applications/MyClip.app` again, authorize it, and restart MyClip. Do not reset permissions for unrelated applications or bypass the OS permission checks.

References: [Apple's explanation of ad-hoc signing and ScreenCaptureKit permissions](https://developer.apple.com/forums/thread/819406), [TN3127: Code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
