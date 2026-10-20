#!/usr/bin/env python3
"""Release behavior tests: local Git repositories and stubbed packaging/GitHub only."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
REPO = SOURCE.parents[1]
SPEC = 'name: Fixture\nsettings:\n  base:\n    MARKETING_VERSION: "1.2.3"\n    OTHER_SETTING: original\n'


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="msc-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "source"
        self.app = self.repo / "apps/macos"
        self.app.mkdir(parents=True)
        shutil.copytree(SOURCE / "scripts/release", self.app / "scripts/release")
        (self.app / "project.yml").write_text(SPEC)
        (self.repo / ".gitignore").write_text("apps/macos/build/\n")
        (self.repo / "unrelated.txt").write_text("original\n")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("MSC_", "GIT_"))
        }
        self.env.update({
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
        })
        self.git("init", "--quiet", "--initial-branch=main")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "fixture")
        self.initial_sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.remote = self.base / "remote.git"
        self.git("init", "--quiet", "--bare", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "--quiet", "origin", "HEAD")

    def run_command(self, args, **kwargs):
        return subprocess.run(
            args, cwd=kwargs.pop("cwd", self.repo), env=self.env,
            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            timeout=60, **kwargs,
        )

    def git(self, *args):
        return self.run_command(["git", *args], check=True)

    def bump(self, *args):
        return self.run_command(["bash", str(self.app / "scripts/release/set-version.sh"), *args])

    def remote_sha(self):
        return self.git("--git-dir", str(self.remote), "rev-parse", "refs/heads/main").stdout.strip()

    def assert_no_bump(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial_sha)
        self.assertEqual(self.remote_sha(), self.initial_sha)


class VersionTests(ReleaseFixture):
    def test_argument_count_and_semver(self):
        for args in [(), ("v2.0.0", "extra")]:
            with self.subTest(args=args):
                self.assert_no_bump(self.bump(*args), "Usage:")
        for value in ["1.2", "-1.2.3", "1.2.3.4", "1.2.4-beta", "1.2.4+build", "01.2.4", "1.02.4", "1.2.04", "vv1.2.4", "1.2.4\n"]:
            with self.subTest(version=value):
                self.assert_no_bump(self.bump(value), "Not a version:")
        self.assertEqual((self.app / "project.yml").read_text(), SPEC)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_equal_and_lower_versions(self):
        for value, message in [("v1.2.3", "Already at"), ("1.2.2", "lower than"), ("0.9.9", "lower than")]:
            with self.subTest(version=value):
                self.assert_no_bump(self.bump(value), message)
        self.assertEqual((self.app / "project.yml").read_text(), SPEC)

    def test_unstaged_project_edit_is_rejected(self):
        self.check_dirty_project(staged=False)

    def test_staged_project_edit_is_rejected(self):
        self.check_dirty_project(staged=True)

    def check_dirty_project(self, staged):
        spec = self.app / "project.yml"
        spec.write_text(SPEC.replace("original", "user edit"))
        if staged:
            self.git("add", str(spec))
        before_index = self.git("diff", "--cached").stdout
        before_worktree = self.git("diff").stdout
        self.assert_no_bump(self.bump("v1.2.4"), "project.yml has uncommitted changes")
        self.assertEqual(spec.read_text(), SPEC.replace("original", "user edit"))
        self.assertEqual(self.git("diff", "--cached").stdout, before_index)
        self.assertEqual(self.git("diff").stdout, before_worktree)

    def test_clean_bump_rewrites_commits_and_pushes(self):
        self.assert_successful_bump(self.bump("1.10.0"), "1.10.0")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_version_commit_excludes_unrelated_edits(self):
        unrelated = self.repo / "unrelated.txt"
        unrelated.write_text("staged edit\n")
        self.git("add", "unrelated.txt")
        unrelated.write_text("staged edit\nunstaged edit\n")
        before_index = self.git("diff", "--cached").stdout
        before_worktree = self.git("diff").stdout
        self.assert_successful_bump(self.bump("v2.0.0"), "2.0.0")
        self.assertEqual(self.git("diff", "--cached").stdout, before_index)
        self.assertEqual(self.git("diff").stdout, before_worktree)

    def assert_successful_bump(self, result, version):
        self.assertEqual(result.returncode, 0, result.stdout)
        expected = SPEC.replace('"1.2.3"', '"' + version + '"')
        self.assertEqual((self.app / "project.yml").read_text(), expected)
        self.assertEqual(self.git("show", "HEAD:apps/macos/project.yml").stdout, expected)
        self.assertEqual(self.git("show", "--format=", "--name-only", "HEAD").stdout.strip(), "apps/macos/project.yml")
        self.assertEqual(self.git("log", "-1", "--format=%s").stdout.strip(), "chore(release): v" + version)
        self.assertEqual(self.git("rev-list", "--count", "HEAD").stdout.strip(), "2")
        self.assertEqual(self.remote_sha(), self.git("rev-parse", "HEAD").stdout.strip())
        self.assertIn("committed and pushed", result.stdout)

    def test_push_failure_retains_local_commit_and_reports_failure(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\necho 'fixture refuses push' >&2\nexit 1\n")
        hook.chmod(0o755)
        result = self.bump("v1.2.4")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("fixture refuses push", result.stdout)
        self.assertNotIn("committed and pushed", result.stdout)
        self.assertEqual((self.app / "project.yml").read_text(), SPEC.replace("1.2.3", "1.2.4"))
        self.assertEqual(self.git("log", "-1", "--format=%s").stdout.strip(), "chore(release): v1.2.4")
        self.assertEqual(self.remote_sha(), self.initial_sha)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_root_mise_wrapper_forwards_version(self):
        # Exercise the actual task definitions with mise, but no tools to install in this fixture.
        def task_block(path):
            text = path.read_text()
            return re.search(r'\[tasks\."release:version"\]\n.*?(?=\n\[|\Z)', text, re.S)[0]

        (self.repo / "mise.toml").write_text(
            'monorepo_root = true\n[monorepo]\nconfig_roots = ["apps/macos"]\n'
            + task_block(REPO / "mise.toml")
        )
        (self.app / "mise.toml").write_text(task_block(SOURCE / "mise.toml"))
        self.git("add", ".")
        self.git("commit", "--quiet", "--amend", "--no-edit")
        self.git("push", "--quiet", "--force", "origin", "HEAD")
        # Keep trust records, caches and the user's global mise configuration out of the test.
        self.env = {key: value for key, value in self.env.items() if not key.startswith("MISE_")}
        for kind in ["CONFIG", "SYSTEM_CONFIG", "DATA", "CACHE", "STATE"]:
            self.env["MISE_" + kind + "_DIR"] = str(self.base / ("mise-" + kind.lower()))
        self.env.update({
            "MISE_GLOBAL_CONFIG_FILE": str(self.base / "global.toml"),
            "MISE_TRUSTED_CONFIG_PATHS": str(self.repo),
            "MISE_ENV_CACHE": "0",
            "MISE_YES": "1",
        })
        result = self.run_command(["mise", "run", "release:version", "--", "v9.9.9"])
        self.assert_successful_bump(result, "9.9.9")


# Each external command is replaced by this dispatcher. Unexpected calls fail closed.
PACKAGING_STUB = r'''#!/usr/bin/python3
import json, os, pathlib, plistlib, sys
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["MSC_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
def argument(flag):
    return args[args.index(flag) + 1]
if name == "gh":
    if args[:2] == ["repo", "view"]:
        print(os.environ.get("MSC_TEST_VISIBILITY", "PUBLIC"))
    elif args[0] == "api" and "/commits/" in args[1]:
        sys.exit(int(os.environ.get("MSC_TEST_COMMIT_STATUS", "0")))
    elif args[0] == "api" and "/git/ref/tags/" in args[1]:
        sys.exit(int(os.environ.get("MSC_TEST_TAG_STATUS", "1")))
    elif args[:2] != ["release", "create"]:
        sys.exit("Unexpected gh arguments: " + repr(args))
elif name == "xcodebuild":
    if args[0] == "archive":
        tool = pathlib.Path(argument("-derivedDataPath")) / "SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
        tool.parent.mkdir(parents=True, exist_ok=True)
        tool.write_text(pathlib.Path(os.environ["MSC_TEST_STUB"]).read_text())
        tool.chmod(0o755)
    elif args[0] == "-exportArchive":
        contents = pathlib.Path(argument("-exportPath")) / "My Screen Cam.app/Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleShortVersionString": os.environ.get("MSC_VERSION", "1.2.3"), "CFBundleVersion": "7"}, f)
    else:
        sys.exit("Unexpected xcodebuild arguments")
elif name == "codesign":
    if args == ["-dvv", args[-1]]:
        print("Authority=Developer ID Application: Fixture")
elif name == "ditto":
    if "-k" in args:
        pathlib.Path(args[-1]).touch()
    else:
        pathlib.Path(args[-1]).mkdir(parents=True)
elif name == "hdiutil":
    pathlib.Path(args[args.index("-ov") + 1]).write_text("fixture DMG")
elif name == "curl":
    pathlib.Path(argument("-o")).write_text("<rss>previous feed</rss>")
elif name == "generate_appcast":
    pathlib.Path(argument("-o")).write_text("<rss>merged fixture feed</rss>")
elif name not in ["xcodegen", "xcrun", "spctl", "unregister-builds.sh"]:
    sys.exit("Unexpected command: " + name)
'''


class PublicationTests(ReleaseFixture):
    def setUp(self):
        super().setUp()
        self.bin = self.base / "bin"
        self.bin.mkdir()
        stub = self.bin / "stub"
        stub.write_text(PACKAGING_STUB)
        stub.chmod(0o755)
        for name in ["gh", "xcodegen", "xcodebuild", "codesign", "xcrun", "ditto", "hdiutil", "spctl", "curl"]:
            (self.bin / name).symlink_to(stub)
        dev = self.app / "scripts/dev"
        dev.mkdir()
        (dev / "unregister-builds.sh").write_text(PACKAGING_STUB)
        (dev / "unregister-builds.sh").chmod(0o755)
        self.git("add", ".")
        self.git("commit", "--quiet", "--amend", "--no-edit")
        self.initial_sha = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("push", "--quiet", "--force", "origin", "HEAD")
        self.log = self.base / "calls.jsonl"
        self.output = self.app / "build/release"
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "MSC_TEST_LOG": str(self.log),
            "MSC_TEST_STUB": str(stub),
        })

    def publish(self, *args):
        return self.run_command(["bash", str(self.app / "scripts/release/release.sh"), "--publish", *args])

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_preflight_failure(self, message):
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stdout)
        self.assertFalse(self.output.exists())
        self.assertTrue(all(call[0] == "gh" for call in self.calls()))
        self.assertFalse(any(call[:3] == ["gh", "release", "create"] for call in self.calls()))
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial_sha)
        self.assertEqual(self.remote_sha(), self.initial_sha)

    def test_head_must_be_available_on_github_before_building(self):
        self.env["MSC_TEST_COMMIT_STATUS"] = "1"
        self.assert_preflight_failure("Push " + self.initial_sha)
        self.assertIn(["gh", "api", "repos/arkaydeus/myscreencam/commits/" + self.initial_sha, "--silent"], self.calls())

    def test_hosting_only_override_is_rejected_with_policy_message(self):
        self.env.update({"MSC_RELEASES_REPO": "fixture/assets-only", "MSC_TEST_COMMIT_STATUS": "1"})
        self.assert_preflight_failure("hosting-only repositories are unsupported")
        self.assertIn(["gh", "api", "repos/fixture/assets-only/commits/" + self.initial_sha, "--silent"], self.calls())

    def test_private_repository_is_rejected(self):
        self.env["MSC_TEST_VISIBILITY"] = "PRIVATE"
        self.assert_preflight_failure("must exist and be public")

    def test_dirty_source_is_rejected(self):
        (self.repo / "unrelated.txt").write_text("dirty\n")
        self.assert_preflight_failure("Commit or stash your changes")

    def test_existing_tag_prevents_release_creation(self):
        self.env["MSC_TEST_TAG_STATUS"] = "0"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("already has a v1.2.3 tag", result.stdout)
        self.assertIn(["gh", "api", "repos/arkaydeus/myscreencam/git/ref/tags/v1.2.3", "--silent"], self.calls())
        self.assertFalse(any(call[:3] == ["gh", "release", "create"] for call in self.calls()))

    def test_publication_targets_built_sha_and_uploads_expected_assets(self):
        self.assert_publication("arkaydeus/myscreencam", "1.2.3")

    def test_source_repo_override_and_notes(self):
        self.env.update({"MSC_RELEASES_REPO": "fixture/source", "MSC_VERSION": "2.3.4"})
        notes = self.base / "release notes.md"
        notes.write_text("Fixture release notes\n")
        self.assert_publication("fixture/source", "2.3.4", notes)

    def assert_publication(self, repo, version, notes=None):
        result = self.publish(*(["--notes", str(notes)] if notes else []))
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        expected = ["gh", "release", "create", "v" + version, "--repo", repo, "--target", self.initial_sha,
                    "--title", "My Screen Cam " + version]
        expected += ["--notes-file", str(notes)] if notes else ["--notes", "My Screen Cam " + version + " (build 7)"]
        expected += [str(self.output / ("MyScreenCam-" + version + ".dmg")),
                     str(self.output / "MyScreenCam.dmg"), str(self.output / "appcast.xml")]
        self.assertEqual([call for call in calls if call[:3] == ["gh", "release", "create"]], [expected])
        for asset in expected[-3:]:
            self.assertTrue(Path(asset).is_file(), asset)
        self.assertEqual((self.output / "MyScreenCam.dmg").read_bytes(),
                         (self.output / ("MyScreenCam-" + version + ".dmg")).read_bytes())
        commit_check = ["gh", "api", "repos/" + repo + "/commits/" + self.initial_sha, "--silent"]
        self.assertLess(calls.index(commit_check), next(i for i, call in enumerate(calls) if call[0] == "xcodegen"))
        appcast = next(call for call in calls if call[0] == "generate_appcast")
        self.assertEqual(appcast[appcast.index("--download-url-prefix") + 1],
                         "https://github.com/" + repo + "/releases/download/v" + version + "/")
        self.assertIn("https://github.com/" + repo + "/releases/latest/download/appcast.xml",
                      next(call for call in calls if call[0] == "curl"))
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.initial_sha)
        self.assertEqual(self.remote_sha(), self.initial_sha)
        self.assertEqual(self.git("tag").stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
