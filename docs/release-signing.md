# Release signing

MyClip uses a persistent, project-only **self-signed community certificate** for GitHub Releases. This requires no paid Apple Developer Program membership and does not export a maintainer's personal Apple certificate. It provides a consistent signing identity across builds, but does **not** establish an Apple-verified publisher identity or notarize the app.

Ad-hoc signatures identify each binary by its code hash. Changing that identity can leave System Settings showing enabled Screen Recording or Accessibility grants that no longer match the app. A stable certificate and bundle identifier let different builds satisfy the same designated requirement. Existing installations signed with another identity still need a one-time permission transition; this is not a guarantee that macOS will never ask for authorization again.

`Scripts/package_dmg.sh` rejects explicit ad-hoc signing. CI requires a certificate and its pinned SHA-1 fingerprint, then verifies the built app against that fingerprint before creating a DMG. The SHA-1 value identifies the certificate in Apple's code-signing requirement syntax; downloaded files use SHA-256 checksums.

## GitHub Actions setup

Run **Initialize Community Signing** once from the repository's Actions page before pushing a release tag. The workflow uses the existing `RELEASE_PAT` secret, which must be authorized to write repository Actions secrets and variables. It generates a project-only certificate and private key on an ephemeral runner, checks that two different signed binaries satisfy the same designated requirement, and saves:

| Repository setting | Value |
| --- | --- |
| Secret `MYCLIP_SIGNING_CERTIFICATE_P12` | Base64-encoded certificate and private key |
| Secret `MYCLIP_SIGNING_CERTIFICATE_PASSWORD` | Random password protecting the `.p12` |
| Variable `MYCLIP_SIGNING_CERTIFICATE_SHA1` | Public certificate fingerprint pinned by both architecture builds |

Initialization refuses to run if any of these settings already exists, preventing accidental identity rotation. A partially configured run must be investigated before retrying. Private keys and passwords must never be committed, logged, or published as artifacts.

The release workflow imports the identity into a temporary keychain and trusts it for code signing **only on the disposable build runner**. It removes the trust entry, keychain, and temporary signing files after packaging. Both architecture jobs must succeed before publication. Releases include both DMGs, the public `MyClip-signing-certificate.pem`, and `SHA256SUMS`; the private key stays in Actions secrets. Users do not need to install or trust the public certificate.

## Installing a community build

Download the correct architecture's DMG from this repository's Release page and verify its SHA-256 checksum. Because the app is not notarized, macOS may require **System Settings → Privacy & Security → Open Anyway** after the first opening attempt. Do not disable Gatekeeper or system integrity protections. Developer ID signing and notarization would require Apple Developer Program membership and a separate release configuration.

Local packaging continues to use the Apple signing identity configured in the Xcode project. A deliberate override can use `CODE_SIGN_IDENTITY_OVERRIDE`; a community identity also needs `MYCLIP_SIGNING_CERTIFICATE_SHA1` so validation checks the intended certificate rather than an Apple trust anchor.

## Recovering a grant after a signing change

The first community-signed update changes identity from older Apple Development or ad-hoc builds. If MyClip still reports missing permission after enabling it and restarting, remove only MyClip from the affected permission list, add `/Applications/MyClip.app` again, authorize it, and restart MyClip. Do not reset permissions for unrelated applications or bypass the OS permission checks. Settings → About MyClip → **Reopen Setup Guide** opens onboarding without resetting saved data or the selected Agent.

References: [TN2206: Signing identities and trust](https://developer.apple.com/library/archive/technotes/tn2206/), [TN3127: Code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Apple Developer membership comparison](https://developer.apple.com/support/compare-memberships/).
