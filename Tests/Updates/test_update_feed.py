"""Integration checks against the pinned, real Sparkle tools; no production keys or network."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


class UpdateFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = Path(os.environ["SPARKLE_BIN"]).resolve()
        if not (cls.tools / "generate_appcast").is_file():
            raise RuntimeError("SPARKLE_BIN must point to the pinned Sparkle tools")
        cls.temporary = tempfile.TemporaryDirectory(prefix="MyClip-update-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.fixture = Path(cls.temporary.name)
        cls.crypto = cls.fixture / "crypto"
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/Updates/FixtureCrypto.swift"),
                        "-o", str(cls.crypto)], check=True, capture_output=True)
        subprocess.run([cls.crypto, "generate", cls.fixture], check=True)
        cls.architecture = subprocess.check_output(["uname", "-m"], text=True).strip()
        app = cls.fixture / "MyClip.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        source = cls.fixture / "main.swift"
        source.write_text("import Darwin\nexit(0)\n")
        subprocess.run(["swiftc", "-target", cls.architecture + "-apple-macosx13.0", str(source),
                        "-o", str(app / "Contents/MacOS/MyClip")], check=True, capture_output=True)
        cls.info = {
            "CFBundleIdentifier": "cc.vibevibe.myclip.update-fixture",
            "CFBundleExecutable": "MyClip", "CFBundleName": "MyClip",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "999",
            "CFBundleShortVersionString": "1.2.3", "LSMinimumSystemVersion": "13.0",
            "SUPublicEDKey": (cls.fixture / "public-key").read_text(),
            "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
        }
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(cls.info))
        cls.archive_name = f"MyClip-1.2.3-{cls.architecture}.dmg"
        cls.archive = cls.fixture / cls.archive_name
        subprocess.run(["hdiutil", "create", "-volname", "MyClip Update Fixture", "-srcfolder", str(app),
                        "-format", "UDZO", str(cls.archive)], check=True, capture_output=True)

    def setUp(self):
        self.working = tempfile.TemporaryDirectory(prefix="MyClip-update-check-")
        self.addCleanup(self.working.cleanup)
        self.root = Path(self.working.name)
        for directory in ["Scripts", "MyClip/Supporting", "docs/releases", "dist"]:
            (self.root / directory).mkdir(parents=True)
        shutil.copy(ROOT / "Scripts/generate_update_feed.sh", self.root / "Scripts")
        (self.root / "MyClip/Supporting/Info.plist").write_bytes(plistlib.dumps(self.info))
        (self.root / "docs/releases/v1.2.3.md").write_text("# Fixture release\n\nA signed update.\n")
        shutil.copy(self.archive, self.root / "dist" / self.archive_name)
        self.environment = dict(os.environ, SPARKLE_BIN=str(self.tools), MYCLIP_ARCH=self.architecture,
                                MYCLIP_SPARKLE_PRIVATE_KEY=(self.fixture / "private-key").read_text())

    def generate(self):
        return subprocess.run(["bash", str(self.root / "Scripts/generate_update_feed.sh")],
                              env=self.environment, text=True, capture_output=True)

    @property
    def feed(self):
        return self.root / "dist" / f"appcast-{self.architecture}.xml"

    def verify_feed(self):
        return subprocess.run([str(self.tools / "sign_update"), "--ed-key-file", str(self.fixture / "private-key"),
                               "--verify", str(self.feed)], capture_output=True)

    def test_real_archive_and_feed_signatures_metadata_and_embedded_notes(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.verify_feed().returncode, 0)
        item = ET.parse(self.feed).find("channel/item")
        self.assertEqual(item.findtext(SPARKLE + "version"), "999")
        self.assertEqual(item.findtext(SPARKLE + "shortVersionString"), "1.2.3")
        self.assertTrue(item.findtext(SPARKLE + "minimumSystemVersion").startswith("13."))
        self.assertIn("A signed update.", item.findtext("description"))
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         "https://github.com/section9-lab/MyClip/releases/download/v1.2.3/" + self.archive_name)
        self.assertEqual(int(enclosure.get("length")), self.archive.stat().st_size)
        signature = enclosure.get(SPARKLE + "edSignature")
        self.assertTrue(signature)
        self.assertEqual(subprocess.run([self.crypto, "verify", self.fixture / "public-key", signature, self.archive]).returncode, 0)
        with (self.root / "dist" / self.archive_name).open("ab") as archive:
            archive.write(b"tampered")
        self.assertNotEqual(subprocess.run([self.crypto, "verify", self.fixture / "public-key", signature,
                                            self.root / "dist" / self.archive_name]).returncode, 0)

    def test_tampered_feed_fails_signature_verification(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.feed.write_text(self.feed.read_text().replace("A signed update.", "Tampered release notes."))
        self.assertNotEqual(self.verify_feed().returncode, 0)

    def test_private_key_must_match_the_key_embedded_in_the_app(self):
        subprocess.run([self.crypto, "generate", self.root], check=True)
        self.environment["MYCLIP_SPARKLE_PRIVATE_KEY"] = (self.root / "private-key").read_text()
        result = self.generate()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.feed.exists())

    def test_missing_key_never_publishes_a_feed(self):
        self.environment.pop("MYCLIP_SPARKLE_PRIVATE_KEY")
        self.assertNotEqual(self.generate().returncode, 0)
        self.assertFalse(self.feed.exists())

    def test_universal_or_unknown_architecture_is_rejected(self):
        for architecture in ["universal", "i386", ""]:
            with self.subTest(architecture=architecture):
                self.environment["MYCLIP_ARCH"] = architecture
                self.assertNotEqual(self.generate().returncode, 0)
                self.assertFalse(list((self.root / "dist").glob("*.xml")))

    def test_native_updater_starts_without_network_and_persists_user_settings(self):
        framework = self.tools.parent / "Sparkle.framework"
        if not framework.is_dir():
            framework = next((self.tools.parent / "Sparkle.xcframework").glob("*/Sparkle.framework"))
        app = self.root / "UpdaterLifecycle.app"
        executable = app / "Contents/MacOS/UpdaterLifecycle"
        executable.parent.mkdir(parents=True)
        info = dict(self.info, CFBundleIdentifier="cc.vibevibe.myclip.update-test." + self.root.name,
                    CFBundleExecutable="UpdaterLifecycle", SUEnableAutomaticChecks=False,
                    SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        compile_result = subprocess.run([
            "swiftc", "-swift-version", "6", "-parse-as-library", "-F", str(framework.parent),
            "-Xlinker", "-rpath", "-Xlinker", str(framework.parent),
            str(ROOT / "MyClip/App/Updates/AppUpdater.swift"),
            str(ROOT / "Tests/Updates/UpdaterLifecycleChecks.swift"), "-o", str(executable)
        ], capture_output=True, text=True)
        self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
        result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
