import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


class PackageDMGTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "Scripts").mkdir()
        shutil.copy(Path(__file__).with_name("package_dmg.sh"), self.root / "Scripts")
        supporting = self.root / "MyClip/Supporting"
        supporting.mkdir(parents=True)
        (supporting / "Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "1.2.3"}))
        tools = self.root / "tools"
        tools.mkdir()
        fake = tools / "fake"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["PACKAGE_TEST_ROOT"])
if command == "xcodebuild":
    (root / "build-arguments.json").write_text(json.dumps(args))
    derived = args[args.index("-derivedDataPath") + 1]
    executable = pathlib.Path(derived) / "Build/Products/Release/MyClip.app/Contents/MacOS/MyClip"
    executable.parent.mkdir(parents=True, exist_ok=True)
    archs = next((a.split("=", 1)[1] for a in args if a.startswith("ARCHS=")), "arm64 x86_64")
    executable.write_text(os.environ.get("PACKAGE_TEST_ACTUAL_ARCHS", archs))
elif command == "lipo":
    print(pathlib.Path(args[-1]).read_text())
elif command == "hdiutil":
    stage = pathlib.Path(args[args.index("-srcfolder") + 1])
    assert (stage / "MyClip.app/Contents/MacOS/MyClip").is_file()
    assert (stage / "Applications").is_symlink()
    pathlib.Path(args[-1]).write_text("test disk image")
elif command == "codesign":
    assert pathlib.Path(args[-1]).is_dir()
    (root / "signing-arguments.json").write_text(json.dumps(args))
    if os.environ.get("PACKAGE_TEST_SIGNATURE_MISMATCH") == "true":
        raise SystemExit(1)
else:
    raise SystemExit("Unexpected tool: " + command)
''')
        fake.chmod(0o755)
        for name in ["xcodebuild", "lipo", "hdiutil", "codesign"]:
            (tools / name).symlink_to(fake)
        self.environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                                PACKAGE_TEST_ROOT=str(self.root), CI="true")
        for key in ["MYCLIP_ARCH", "DERIVED_DATA_PATH", "CONFIGURATION", "CODE_SIGN_IDENTITY_OVERRIDE", "DMG_PATH_OUTPUT", "MYCLIP_SIGNING_CERTIFICATE_SHA1"]:
            self.environment.pop(key, None)
        self.environment["CODE_SIGN_IDENTITY_OVERRIDE"] = "Developer ID Application: MyClip Test"
        self.environment["MYCLIP_SIGNING_CERTIFICATE_SHA1"] = "A" * 40

    def package(self, arch=None, actual_archs=None):
        if arch:
            self.environment["MYCLIP_ARCH"] = arch
        if actual_archs:
            self.environment["PACKAGE_TEST_ACTUAL_ARCHS"] = actual_archs
        return subprocess.run(["bash", str(self.root / "Scripts/package_dmg.sh")],
                              env=self.environment, capture_output=True, text=True)

    def test_architecture_specific_packages_build_and_verify_the_requested_architecture(self):
        for arch in ["arm64", "x86_64"]:
            with self.subTest(arch=arch):
                output = self.root / f"{arch}-output.txt"
                self.environment["DMG_PATH_OUTPUT"] = str(output)
                result = self.package(arch)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output.read_text().strip(), f"dist/MyClip-1.2.3-{arch}.dmg")
                self.assertTrue((self.root / output.read_text().strip()).is_file())
                arguments = json.loads((self.root / "build-arguments.json").read_text())
                self.assertIn(f"ARCHS={arch}", arguments)
                self.assertIn("ONLY_ACTIVE_ARCH=NO", arguments)
                self.assertIn("CODE_SIGN_IDENTITY=Developer ID Application: MyClip Test", arguments)
                self.assertIn("DEVELOPMENT_TEAM=", arguments)

    def test_community_certificate_is_pinned_instead_of_requiring_an_apple_certificate(self):
        self.environment["CODE_SIGN_IDENTITY_OVERRIDE"] = "MyClip Community Signing"
        result = self.package("arm64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        arguments = json.loads((self.root / "signing-arguments.json").read_text())
        self.assertIn('-R=certificate leaf = H"' + "A" * 40 + '"', arguments)

    def test_ci_without_a_pinned_certificate_stops_before_building(self):
        self.environment.pop("MYCLIP_SIGNING_CERTIFICATE_SHA1")
        result = self.package("arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-arguments.json").exists())

    def test_unexpected_signing_certificate_prevents_packaging(self):
        self.environment["PACKAGE_TEST_SIGNATURE_MISMATCH"] = "true"
        result = self.package("arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(self.root.glob("dist/*.dmg")))

    def test_ci_without_a_signing_identity_cannot_publish_an_unstable_package(self):
        self.environment.pop("CODE_SIGN_IDENTITY_OVERRIDE")
        result = self.package("arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-arguments.json").exists())

    def test_ad_hoc_identity_is_rejected_before_building(self):
        self.environment["CODE_SIGN_IDENTITY_OVERRIDE"] = "-"
        result = self.package("arm64")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-arguments.json").exists())

    def test_incorrect_binary_architecture_prevents_packaging(self):
        result = self.package("arm64", "x86_64")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(list(self.root.glob("dist/*.dmg")))

    def test_unsupported_architecture_fails_before_building(self):
        result = self.package("i386")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "build-arguments.json").exists())

    def test_default_universal_package_keeps_the_existing_filename(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.root / "dist/MyClip-1.2.3.dmg").is_file())
        arguments = json.loads((self.root / "build-arguments.json").read_text())
        self.assertIn("ARCHS=arm64 x86_64", arguments)


if __name__ == "__main__":
    unittest.main()
