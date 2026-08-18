from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
from typing import Optional


MODULE_PATH = Path(__file__).resolve().parents[1] / "release_tool.py"
SPEC = importlib.util.spec_from_file_location("release_tool", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
release_tool = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_tool
SPEC.loader.exec_module(release_tool)


def project_text(version: str = "0.1.0", build: str = "1") -> str:
    return f"""// !$*UTF8*$!
Debug = {{
    MARKETING_VERSION = {version};
    CURRENT_PROJECT_VERSION = {build};
}};
Release = {{
    CURRENT_PROJECT_VERSION = {build};
    MARKETING_VERSION = {version};
}};
"""


def changelog_text(unreleased: Optional[str] = None) -> str:
    if unreleased is None:
        unreleased = (
            "### Added\n\n"
            "- Lazy native thumbnails in the Files grid for supported files."
        )
    return f"""# Changelog

## [Unreleased]

{unreleased}

## [0.1.0] - 2026-08-13

### Added

- Initial release.

[Unreleased]: https://github.com/aarikmudgal/CasaNative/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aarikmudgal/CasaNative/releases/tag/v0.1.0
"""


class VersionTests(unittest.TestCase):
    def test_canonical_version_and_bumps(self) -> None:
        version = release_tool.Version.parse("0.1.0")
        self.assertEqual(str(version.bump("major")), "1.0.0")
        self.assertEqual(str(version.bump("minor")), "0.2.0")
        self.assertEqual(str(version.bump("patch")), "0.1.1")
        self.assertEqual(version.tag, "v0.1.0")

    def test_rejects_noncanonical_versions(self) -> None:
        for value in ("v0.1.0", "01.1.0", "1.0", "1.0.0-beta"):
            with self.subTest(value=value), self.assertRaises(
                release_tool.ReleaseToolError
            ):
                release_tool.Version.parse(value)


class CommitPolicyTests(unittest.TestCase):
    def test_breaking_header_or_footer_is_major(self) -> None:
        self.assertEqual(release_tool.conventional_bump("feat(api)!: replace API"), "major")
        self.assertEqual(
            release_tool.conventional_bump(
                "fix: adjust behavior\n\nBREAKING CHANGE: old setup is unsupported"
            ),
            "major",
        )

    def test_feat_is_minor_and_other_user_changes_are_patch(self) -> None:
        self.assertEqual(release_tool.conventional_bump("feat(files): add grid"), "minor")
        self.assertEqual(release_tool.conventional_bump("fix: stop crash"), "patch")
        self.assertEqual(release_tool.conventional_bump("docs: clarify install"), "patch")

    def test_aggregate_ignores_only_release_commits(self) -> None:
        self.assertIsNone(release_tool.aggregate_bump([]))
        self.assertIsNone(
            release_tool.aggregate_bump(["chore(release): v0.2.0"])
        )
        self.assertEqual(
            release_tool.aggregate_bump(
                ["chore(release): v0.1.1", "fix: repair crash"]
            ),
            "patch",
        )
        self.assertEqual(
            release_tool.aggregate_bump(["fix: repair", "feat: add view"]),
            "minor",
        )


class ProjectMetadataTests(unittest.TestCase):
    def test_parses_and_updates_exactly_two_assignments(self) -> None:
        state = release_tool.parse_project(project_text())
        self.assertEqual(str(state.version), "0.1.0")
        self.assertEqual(state.build, 1)
        updated = release_tool.update_project(
            project_text(), release_tool.Version.parse("0.2.0"), 2
        )
        self.assertEqual(updated.count("MARKETING_VERSION = 0.2.0;"), 2)
        self.assertEqual(updated.count("CURRENT_PROJECT_VERSION = 2;"), 2)
        self.assertEqual(
            release_tool.parse_project(updated),
            release_tool.ProjectState(release_tool.Version.parse("0.2.0"), 2),
        )

    def test_rejects_missing_or_extra_assignments(self) -> None:
        one = project_text().replace("    MARKETING_VERSION = 0.1.0;\n", "", 1)
        three = project_text() + "MARKETING_VERSION = 0.1.0;\n"
        for malformed in (one, three):
            with self.subTest(), self.assertRaises(release_tool.ReleaseToolError):
                release_tool.parse_project(malformed)

    def test_rejects_disagreement_and_invalid_build(self) -> None:
        mismatch = project_text().replace(
            "MARKETING_VERSION = 0.1.0;",
            "MARKETING_VERSION = 0.1.1;",
            1,
        )
        with self.assertRaises(release_tool.ReleaseToolError):
            release_tool.parse_project(mismatch)
        with self.assertRaises(release_tool.ReleaseToolError):
            release_tool.parse_project(project_text(build="0"))


class ChangelogTests(unittest.TestCase):
    def test_moves_unreleased_and_updates_compare_links(self) -> None:
        updated, notes = release_tool.update_changelog(
            changelog_text(),
            release_tool.Version.parse("0.1.0"),
            release_tool.Version.parse("0.2.0"),
            dt.date(2026, 8, 18),
        )
        self.assertIn("## [Unreleased]\n\nNo unreleased changes yet.", updated)
        self.assertIn("## [0.2.0] - 2026-08-18", updated)
        self.assertIn(
            "[Unreleased]: https://github.com/aarikmudgal/CasaNative/compare/v0.2.0...HEAD",
            updated,
        )
        self.assertIn(
            "[0.2.0]: https://github.com/aarikmudgal/CasaNative/compare/v0.1.0...v0.2.0",
            updated,
        )
        self.assertIn("Lazy native thumbnails", notes)
        state = release_tool.validate_changelog(
            updated,
            release_tool.Version.parse("0.2.0"),
            expected_previous=release_tool.Version.parse("0.1.0"),
        )
        self.assertFalse(state.has_unreleased_entries)

    def test_rejects_empty_unreleased_for_new_release(self) -> None:
        with self.assertRaisesRegex(
            release_tool.ReleaseToolError, "release notes are empty"
        ):
            release_tool.update_changelog(
                changelog_text(release_tool.EMPTY_UNRELEASED),
                release_tool.Version.parse("0.1.0"),
                release_tool.Version.parse("0.1.1"),
                dt.date(2026, 8, 18),
            )

    def test_rejects_malformed_or_duplicate_links(self) -> None:
        malformed = changelog_text().replace("/compare/v0.1.0...HEAD", "/tree/main")
        duplicate = changelog_text() + (
            "[Unreleased]: https://github.com/aarikmudgal/CasaNative/"
            "compare/v0.1.0...HEAD\n"
        )
        for value in (malformed, duplicate):
            with self.subTest(), self.assertRaises(release_tool.ReleaseToolError):
                release_tool.parse_changelog(value)


class ReleasePlanTests(unittest.TestCase):
    def test_current_0_1_0_feat_plans_0_2_0_build_2(self) -> None:
        plan = release_tool.plan_release_texts(
            project_text(),
            changelog_text(),
            latest_version=release_tool.Version.parse("0.1.0"),
            commit_messages=(
                "chore(deps): bump actions/checkout",
                "feat(files): add grid thumbnails",
            ),
        )
        self.assertTrue(plan.needed)
        self.assertEqual(plan.bump, "minor")
        self.assertEqual(str(plan.version), "0.2.0")
        self.assertEqual(plan.build, 2)
        self.assertIn("Lazy native thumbnails", plan.release_notes)
        self.assertNotIn("Bump actions", plan.release_notes)

    def test_empty_unreleased_synthesizes_stable_changed_notes(self) -> None:
        commits = (
            "chore(deps): bump actions/checkout from 6 to 7",
            "chore(release): v0.1.1",
            "docs(readme): clarify unsigned install",
        )
        empty = changelog_text(release_tool.EMPTY_UNRELEASED)
        plan = release_tool.plan_release_texts(
            project_text(),
            empty,
            latest_version=release_tool.Version.parse("0.1.0"),
            commit_messages=commits,
        )
        self.assertEqual(plan.bump, "patch")
        self.assertEqual(
            plan.release_notes,
            "### Changed\n\n"
            "- Bump actions\\/checkout from 6 to 7.\n"
            "- Clarify unsigned install.",
        )
        prepared = release_tool.prepare_release_texts(
            project_text(),
            empty,
            plan=plan,
            release_date=dt.date(2026, 8, 18),
        )
        self.assertIn(
            "## [Unreleased]\n\nNo unreleased changes yet.\n\n"
            "## [0.1.1] - 2026-08-18\n\n"
            "### Changed\n\n"
            "- Bump actions\\/checkout from 6 to 7.\n"
            "- Clarify unsigned install.",
            prepared.changelog_text,
        )

    def test_synthesized_subjects_strip_only_conventional_prefix_safely(self) -> None:
        notes = release_tool.synthesized_release_notes(
            (
                "fix(ui)!:\t### injected\x07 heading\nignored body",
                "Merge branch: preserve #this subject\u202e",
                "fix:",
                "chore(release): v9.9.9",
            )
        )
        self.assertEqual(
            notes,
            "### Changed\n\n"
            "- \\#\\#\\# Injected heading.\n"
            "- Merge branch\\: preserve \\#this subject.\n"
            "- Repository update.",
        )
        self.assertNotRegex(notes.removeprefix("### Changed\n\n"), r"(?m)^#")
        self.assertFalse(
            any(character != "\n" and (ord(character) < 32 or ord(character) == 127)
                for character in notes)
        )
        self.assertNotIn("\u202e", notes)

    def test_synthesized_subject_neutralizes_markdown_and_mentions(self) -> None:
        notes = release_tool.synthesized_release_notes(
            (
                r"docs: show <img src=x> [link](https://example.com) "
                r"![image](asset) @user `code` C:\temp *bold* _italic_ #42",
            )
        )
        self.assertIn(r"\<img src\=x\>", notes)
        self.assertIn(r"\[link\]\(https\:\/\/example\.com\)", notes)
        self.assertIn(r"\!\[image\]\(asset\)", notes)
        self.assertIn(r"\@user", notes)
        self.assertIn(r"\`code\`", notes)
        self.assertIn(r"C\:\\temp", notes)
        self.assertIn(r"\*bold\*", notes)
        self.assertIn(r"\_italic\_", notes)
        self.assertIn(r"\#42", notes)
        self.assertNotRegex(notes, r"(?<!\\)<img")
        self.assertNotRegex(notes, r"(?<!\\)@user")

    def test_no_commits_or_only_release_commits_is_noop(self) -> None:
        for commits in ((), ("chore(release): v0.1.0",)):
            with self.subTest(commits=commits):
                plan = release_tool.plan_release_texts(
                    project_text(),
                    changelog_text(),
                    latest_version=release_tool.Version.parse("0.1.0"),
                    commit_messages=commits,
                )
                self.assertFalse(plan.needed)
                self.assertEqual(plan.status, "no_release")
                self.assertEqual(str(plan.version), "0.1.0")

    def test_prepare_is_idempotent(self) -> None:
        commits = ("feat(files): add grid thumbnails",)
        first_plan = release_tool.plan_release_texts(
            project_text(),
            changelog_text(),
            latest_version=release_tool.Version.parse("0.1.0"),
            commit_messages=commits,
        )
        first = release_tool.prepare_release_texts(
            project_text(),
            changelog_text(),
            plan=first_plan,
            release_date=dt.date(2026, 8, 18),
        )
        self.assertTrue(first.changed)
        second_plan = release_tool.plan_release_texts(
            first.project_text,
            first.changelog_text,
            latest_version=release_tool.Version.parse("0.1.0"),
            commit_messages=commits,
        )
        second = release_tool.prepare_release_texts(
            first.project_text,
            first.changelog_text,
            plan=second_plan,
            release_date=dt.date(2026, 8, 18),
        )
        self.assertFalse(second.changed)
        self.assertEqual(second.status, "already_prepared")
        self.assertEqual(second.project_text, first.project_text)
        self.assertEqual(second.changelog_text, first.changelog_text)

    def test_rejects_unexpected_project_version(self) -> None:
        with self.assertRaisesRegex(release_tool.ReleaseToolError, "neither latest tag"):
            release_tool.plan_release_texts(
                project_text(version="0.9.0"),
                changelog_text(),
                latest_version=release_tool.Version.parse("0.1.0"),
                commit_messages=("fix: repair",),
            )


class GitAndOutputTests(unittest.TestCase):
    def test_detects_highest_reachable_semver_and_post_tag_messages(self) -> None:
        outputs = {
            ("tag", "--merged", "HEAD", "--list", "v*"): "v0.1.0\nv0.2.0\nvbad\n",
            ("tag", "--points-at", "HEAD", "--list", "v*"): "",
            (
                "log",
                "--reverse",
                "--format=%B%x00",
                "v0.2.0..HEAD",
            ): "fix: one\0feat: two\0",
        }

        def fake_git(_repo: Path, arguments: list[str]) -> str:
            return outputs[tuple(arguments)]

        with mock.patch.object(release_tool, "_run_git", side_effect=fake_git):
            state = release_tool.detect_git_state(Path("/repo"))
        self.assertEqual(state.latest_tag, "v0.2.0")
        self.assertEqual(state.commit_messages, ("fix: one", "feat: two"))

    def test_github_outputs_include_required_machine_values(self) -> None:
        payload = {
            "needed": True,
            "version": "0.2.0",
            "tag": "v0.2.0",
            "previous_tag": "v0.1.0",
            "build": 2,
            "release_notes": "line one\nline two",
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "outputs"
            release_tool.write_github_outputs(path, payload)
            output = path.read_text(encoding="utf-8")
        self.assertIn("needed=true\n", output)
        self.assertIn("version=0.2.0\n", output)
        self.assertIn("previous_tag=v0.1.0\n", output)
        self.assertIn("build=2\n", output)
        self.assertIn("release_notes<<CASANATIVE_", output)
        json_line = next(line for line in output.splitlines() if line.startswith("json="))
        self.assertEqual(json.loads(json_line.removeprefix("json="))["tag"], "v0.2.0")

    def test_atomic_write_many_replaces_all_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first"
            second = Path(directory) / "second"
            first.write_text("old one", encoding="utf-8")
            second.write_text("old two", encoding="utf-8")
            release_tool.atomic_write_many({first: "new one", second: "new two"})
            self.assertEqual(first.read_text(encoding="utf-8"), "new one")
            self.assertEqual(second.read_text(encoding="utf-8"), "new two")


if __name__ == "__main__":
    unittest.main()
