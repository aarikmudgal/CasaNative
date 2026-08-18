#!/usr/bin/env python3
"""Prepare and validate deterministic Casa Native releases."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
from pathlib import Path
import re
import stat
import string
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from typing import Iterable, Mapping, Optional, Sequence


PROJECT_RELATIVE_PATH = Path("CasaNative.xcodeproj/project.pbxproj")
CHANGELOG_RELATIVE_PATH = Path("CHANGELOG.md")
EMPTY_UNRELEASED = "No unreleased changes yet."

SEMVER_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
SEMVER_RE = re.compile(rf"^{SEMVER_PATTERN}$")
TAG_RE = re.compile(rf"^v(?P<version>{SEMVER_PATTERN})$")
MARKDOWN_PUNCTUATION_RE = re.compile(f"([{re.escape(string.punctuation)}])")
MARKETING_RE = re.compile(
    r"^(?P<prefix>[ \t]*MARKETING_VERSION[ \t]*=[ \t]*)"
    r"(?P<value>[^;\r\n]+)(?P<suffix>;[ \t]*)$",
    re.MULTILINE,
)
BUILD_RE = re.compile(
    r"^(?P<prefix>[ \t]*CURRENT_PROJECT_VERSION[ \t]*=[ \t]*)"
    r"(?P<value>[^;\r\n]+)(?P<suffix>;[ \t]*)$",
    re.MULTILINE,
)
UNRELEASED_HEADER_RE = re.compile(r"^## \[Unreleased\][ \t]*$", re.MULTILINE)
RELEASE_HEADER_RE = re.compile(
    rf"^## \[(?P<version>{SEMVER_PATTERN})\] - "
    r"(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})[ \t]*$",
    re.MULTILINE,
)
UNRELEASED_LINK_RE = re.compile(
    r"^\[Unreleased\]: (?P<url>\S+)[ \t]*$", re.MULTILINE
)


class ReleaseToolError(ValueError):
    """Raised when repository release metadata violates an invariant."""


@dataclasses.dataclass(frozen=True, order=True)
class Version:
    major: int
    minor: int
    patch: int

    @classmethod
    def parse(cls, value: str, *, label: str = "version") -> "Version":
        if not SEMVER_RE.fullmatch(value):
            raise ReleaseToolError(
                f"{label} must be canonical X.Y.Z without prefixes or leading zeroes: {value!r}"
            )
        major, minor, patch = (int(component) for component in value.split("."))
        return cls(major, minor, patch)

    @classmethod
    def from_tag(cls, tag: str) -> "Version":
        match = TAG_RE.fullmatch(tag)
        if match is None:
            raise ReleaseToolError(f"release tag must be canonical vX.Y.Z: {tag!r}")
        return cls.parse(match.group("version"), label="release tag version")

    def bump(self, kind: str) -> "Version":
        if kind == "major":
            return Version(self.major + 1, 0, 0)
        if kind == "minor":
            return Version(self.major, self.minor + 1, 0)
        if kind == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        raise ReleaseToolError(f"unsupported version bump: {kind!r}")

    @property
    def tag(self) -> str:
        return f"v{self}"

    def __str__(self) -> str:
        return f"{self.major}.{self.minor}.{self.patch}"


@dataclasses.dataclass(frozen=True)
class ProjectState:
    version: Version
    build: int


@dataclasses.dataclass(frozen=True)
class ChangelogState:
    unreleased_body: str
    top_version: Version
    top_date: dt.date
    compare_prefix: str
    unreleased_base: Version
    top_link: str

    @property
    def has_unreleased_entries(self) -> bool:
        body = self.unreleased_body.strip()
        return bool(body) and body != EMPTY_UNRELEASED


@dataclasses.dataclass(frozen=True)
class GitState:
    latest_tag: str
    latest_version: Version
    commit_messages: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class ReleasePlan:
    needed: bool
    previous_version: Version
    version: Version
    build: int
    bump: str
    release_notes: str
    status: str


@dataclasses.dataclass(frozen=True)
class PreparedRelease:
    project_text: str
    changelog_text: str
    previous_version: Version
    version: Version
    build: int
    bump: str
    release_notes: str
    changed: bool
    status: str


def conventional_bump(commit_message: str) -> str:
    """Return major/minor/patch using Conventional Commit release semantics."""

    message = commit_message.strip()
    if not message:
        raise ReleaseToolError("commit message is empty")
    header = message.splitlines()[0].strip()
    breaking_header = re.match(
        r"^[A-Za-z0-9][A-Za-z0-9_-]*(?:\([^\r\n()]+\))?!:", header
    )
    breaking_footer = re.search(
        r"(?mi)^BREAKING(?: |-)CHANGE:[ \t]*\S", message
    )
    if breaking_header is not None or breaking_footer is not None:
        return "major"
    if re.match(r"^feat(?:\([^\r\n()]+\))?:", header, re.IGNORECASE):
        return "minor"
    return "patch"


def is_release_commit(commit_message: str) -> bool:
    message = commit_message.strip()
    if not message:
        raise ReleaseToolError("commit message is empty")
    return re.match(
        r"^chore\(release\):(?:[ \t]|$)",
        _first_line(message).strip(),
        re.IGNORECASE,
    ) is not None


def aggregate_bump(commit_messages: Iterable[str]) -> Optional[str]:
    bumps = [
        conventional_bump(message)
        for message in commit_messages
        if not is_release_commit(message)
    ]
    if not bumps:
        return None
    if "major" in bumps:
        return "major"
    if "minor" in bumps:
        return "minor"
    return "patch"


def _first_line(message: str) -> str:
    return message.split("\n", 1)[0].split("\r", 1)[0]


def readable_commit_subject(commit_message: str) -> str:
    subject = _first_line(commit_message)
    subject = "".join(
        " " if unicodedata.category(character).startswith("C") else character
        for character in subject
    )
    subject = re.sub(
        r"^[a-z][a-z0-9_-]*(?:\([A-Za-z0-9._/-]+\))?!?:[ \t]*",
        "",
        subject,
    )
    subject = " ".join(subject.split()) or "Repository update"
    subject = MARKDOWN_PUNCTUATION_RE.sub(r"\\\1", subject)
    for index, character in enumerate(subject):
        if character.isalpha():
            subject = subject[:index] + character.upper() + subject[index + 1 :]
            break
    if not subject.endswith((".", "!", "?")):
        subject += "."
    return subject


def synthesized_release_notes(commit_messages: Iterable[str]) -> str:
    subjects = [
        readable_commit_subject(message)
        for message in commit_messages
        if not is_release_commit(message)
    ]
    if not subjects:
        raise ReleaseToolError("cannot synthesize release notes without user changes")
    return "### Changed\n\n" + "\n".join(f"- {subject}" for subject in subjects)


def _single_consistent_value(
    pattern: re.Pattern[str], text: str, *, expected_count: int, label: str
) -> str:
    matches = list(pattern.finditer(text))
    if len(matches) != expected_count:
        raise ReleaseToolError(
            f"expected exactly {expected_count} {label} assignments; found {len(matches)}"
        )
    values = [match.group("value").strip() for match in matches]
    if len(set(values)) != 1:
        raise ReleaseToolError(f"{label} assignments disagree: {values}")
    return values[0]


def parse_project(text: str) -> ProjectState:
    version_text = _single_consistent_value(
        MARKETING_RE,
        text,
        expected_count=2,
        label="MARKETING_VERSION",
    )
    build_text = _single_consistent_value(
        BUILD_RE,
        text,
        expected_count=2,
        label="CURRENT_PROJECT_VERSION",
    )
    version = Version.parse(version_text, label="MARKETING_VERSION")
    if not re.fullmatch(r"[1-9][0-9]*", build_text):
        raise ReleaseToolError(
            "CURRENT_PROJECT_VERSION must be the same positive integer in both configurations"
        )
    return ProjectState(version=version, build=int(build_text))


def update_project(text: str, version: Version, build: int) -> str:
    parse_project(text)
    if build < 1:
        raise ReleaseToolError("build number must be positive")

    def replace_version(match: re.Match[str]) -> str:
        return f"{match.group('prefix')}{version}{match.group('suffix')}"

    def replace_build(match: re.Match[str]) -> str:
        return f"{match.group('prefix')}{build}{match.group('suffix')}"

    updated, version_count = MARKETING_RE.subn(replace_version, text)
    updated, build_count = BUILD_RE.subn(replace_build, updated)
    if version_count != 2 or build_count != 2:
        raise ReleaseToolError("project version replacement count changed unexpectedly")
    if parse_project(updated) != ProjectState(version=version, build=build):
        raise ReleaseToolError("updated project does not contain the requested version")
    return updated


def _one_match(pattern: re.Pattern[str], text: str, *, label: str) -> re.Match[str]:
    matches = list(pattern.finditer(text))
    if len(matches) != 1:
        raise ReleaseToolError(f"expected exactly one {label}; found {len(matches)}")
    return matches[0]


def _release_link_pattern(version: Version) -> re.Pattern[str]:
    return re.compile(
        rf"^\[{re.escape(str(version))}\]: (?P<url>\S+)[ \t]*$", re.MULTILINE
    )


def parse_changelog(text: str) -> ChangelogState:
    unreleased = _one_match(
        UNRELEASED_HEADER_RE, text, label="[Unreleased] section"
    )
    release_headers = [
        match for match in RELEASE_HEADER_RE.finditer(text) if match.start() > unreleased.end()
    ]
    if not release_headers:
        raise ReleaseToolError("changelog has no dated X.Y.Z release section")
    top_release = release_headers[0]
    body = text[unreleased.end() : top_release.start()].strip()
    top_version = Version.parse(top_release.group("version"), label="top changelog version")
    try:
        top_date = dt.date.fromisoformat(top_release.group("date"))
    except ValueError as error:
        raise ReleaseToolError(f"invalid top changelog date: {error}") from error

    unreleased_link = _one_match(
        UNRELEASED_LINK_RE, text, label="[Unreleased] comparison link"
    )
    compare_match = re.fullmatch(
        rf"(?P<prefix>.+/compare/)v(?P<base>{SEMVER_PATTERN})\.\.\.HEAD",
        unreleased_link.group("url"),
    )
    if compare_match is None:
        raise ReleaseToolError(
            "[Unreleased] link must end with /compare/vX.Y.Z...HEAD"
        )
    unreleased_base = Version.parse(
        compare_match.group("base"), label="[Unreleased] comparison base"
    )
    top_link_match = _one_match(
        _release_link_pattern(top_version),
        text,
        label=f"[{top_version}] release link",
    )
    top_link = top_link_match.group("url")
    if not (
        top_link.endswith(f"/releases/tag/{top_version.tag}")
        or top_link.endswith(f"...{top_version.tag}")
    ):
        raise ReleaseToolError(
            f"[{top_version}] link does not target {top_version.tag}: {top_link!r}"
        )
    return ChangelogState(
        unreleased_body=body,
        top_version=top_version,
        top_date=top_date,
        compare_prefix=compare_match.group("prefix"),
        unreleased_base=unreleased_base,
        top_link=top_link,
    )


def validate_changelog(
    text: str,
    expected_version: Version,
    *,
    expected_previous: Optional[Version] = None,
) -> ChangelogState:
    state = parse_changelog(text)
    if state.top_version != expected_version:
        raise ReleaseToolError(
            f"top changelog version {state.top_version} does not match {expected_version}"
        )
    if state.unreleased_base != expected_version:
        raise ReleaseToolError(
            f"[Unreleased] comparison starts at {state.unreleased_base}, expected {expected_version}"
        )
    if expected_previous is not None:
        expected_link = (
            f"{state.compare_prefix}{expected_previous.tag}...{expected_version.tag}"
        )
        if state.top_link != expected_link:
            raise ReleaseToolError(
                f"[{expected_version}] link is {state.top_link!r}, expected {expected_link!r}"
            )
    return state


def update_changelog(
    text: str,
    previous_version: Version,
    version: Version,
    release_date: dt.date,
    fallback_notes: str = "",
) -> tuple[str, str]:
    state = validate_changelog(text, previous_version)
    release_notes = (
        state.unreleased_body.strip()
        if state.has_unreleased_entries
        else fallback_notes.strip()
    )
    if not release_notes:
        raise ReleaseToolError("release notes are empty")

    unreleased = _one_match(
        UNRELEASED_HEADER_RE, text, label="[Unreleased] section"
    )
    top_release = next(
        match for match in RELEASE_HEADER_RE.finditer(text) if match.start() > unreleased.end()
    )
    middle = (
        f"\n\n{EMPTY_UNRELEASED}\n\n"
        f"## [{version}] - {release_date.isoformat()}\n\n"
        f"{release_notes}\n\n"
    )
    updated = text[: unreleased.end()] + middle + text[top_release.start() :]

    unreleased_link = _one_match(
        UNRELEASED_LINK_RE, updated, label="[Unreleased] comparison link"
    )
    new_unreleased_link = (
        f"[Unreleased]: {state.compare_prefix}{version.tag}...HEAD"
    )
    updated = (
        updated[: unreleased_link.start()]
        + new_unreleased_link
        + updated[unreleased_link.end() :]
    )

    previous_link = _one_match(
        _release_link_pattern(previous_version),
        updated,
        label=f"[{previous_version}] release link",
    )
    new_version_link = (
        f"[{version}]: {state.compare_prefix}"
        f"{previous_version.tag}...{version.tag}\n"
    )
    updated = (
        updated[: previous_link.start()]
        + new_version_link
        + updated[previous_link.start() :]
    )
    validate_changelog(updated, version, expected_previous=previous_version)
    return updated, release_notes


def _top_release_notes(text: str) -> str:
    unreleased = _one_match(
        UNRELEASED_HEADER_RE, text, label="[Unreleased] section"
    )
    releases = [
        match for match in RELEASE_HEADER_RE.finditer(text) if match.start() > unreleased.end()
    ]
    if not releases:
        raise ReleaseToolError("changelog has no dated release section")
    start = releases[0].end()
    end = releases[1].start() if len(releases) > 1 else len(text)
    notes = text[start:end]
    notes = re.split(r"(?m)^\[Unreleased\]:", notes, maxsplit=1)[0].strip()
    return notes


def plan_release_texts(
    project_text: str,
    changelog_text: str,
    *,
    latest_version: Version,
    commit_messages: Iterable[str],
) -> ReleasePlan:
    project = parse_project(project_text)
    messages = tuple(commit_messages)
    bump = aggregate_bump(messages)
    if bump is None:
        if project.version != latest_version:
            raise ReleaseToolError(
                f"project version {project.version} does not match latest tag {latest_version}"
            )
        validate_changelog(changelog_text, latest_version)
        return ReleasePlan(
            needed=False,
            previous_version=latest_version,
            version=latest_version,
            build=project.build,
            bump="",
            release_notes="",
            status="no_release",
        )

    version = latest_version.bump(bump)
    if project.version == latest_version:
        changelog = validate_changelog(changelog_text, latest_version)
        notes = (
            changelog.unreleased_body.strip()
            if changelog.has_unreleased_entries
            else synthesized_release_notes(messages)
        )
        return ReleasePlan(
            needed=True,
            previous_version=latest_version,
            version=version,
            build=project.build + 1,
            bump=bump,
            release_notes=notes,
            status="planned",
        )

    if project.version == version:
        changelog = validate_changelog(
            changelog_text, version, expected_previous=latest_version
        )
        if changelog.has_unreleased_entries:
            raise ReleaseToolError(
                "project is already prepared but [Unreleased] contains new entries"
            )
        return ReleasePlan(
            needed=True,
            previous_version=latest_version,
            version=version,
            build=project.build,
            bump=bump,
            release_notes=_top_release_notes(changelog_text),
            status="already_prepared",
        )

    raise ReleaseToolError(
        f"project version {project.version} is neither latest tag {latest_version} "
        f"nor deterministic next version {version}"
    )


def prepare_release_texts(
    project_text: str,
    changelog_text: str,
    *,
    plan: ReleasePlan,
    release_date: dt.date,
) -> PreparedRelease:
    if not plan.needed:
        return PreparedRelease(
            project_text=project_text,
            changelog_text=changelog_text,
            previous_version=plan.previous_version,
            version=plan.version,
            build=plan.build,
            bump=plan.bump,
            release_notes=plan.release_notes,
            changed=False,
            status="no_release",
        )
    project = parse_project(project_text)
    if project.version == plan.version:
        if project.build != plan.build:
            raise ReleaseToolError(
                f"prepared build {project.build} does not match planned build {plan.build}"
            )
        changelog = validate_changelog(
            changelog_text,
            plan.version,
            expected_previous=plan.previous_version,
        )
        if changelog.has_unreleased_entries:
            raise ReleaseToolError(
                "project is already prepared but [Unreleased] contains new entries"
            )
        return PreparedRelease(
            project_text=project_text,
            changelog_text=changelog_text,
            previous_version=plan.previous_version,
            version=plan.version,
            build=plan.build,
            bump=plan.bump,
            release_notes=_top_release_notes(changelog_text),
            changed=False,
            status="already_prepared",
        )
    if project.version != plan.previous_version or plan.build != project.build + 1:
        raise ReleaseToolError("planned version/build do not follow the current project state")
    new_project = update_project(project_text, plan.version, plan.build)
    new_changelog, notes = update_changelog(
        changelog_text,
        plan.previous_version,
        plan.version,
        release_date,
        fallback_notes=plan.release_notes,
    )
    return PreparedRelease(
        project_text=new_project,
        changelog_text=new_changelog,
        previous_version=plan.previous_version,
        version=plan.version,
        build=plan.build,
        bump=plan.bump,
        release_notes=notes,
        changed=True,
        status="prepared",
    )


def _run_git(repo: Path, arguments: Sequence[str]) -> str:
    command = ["git", "-C", str(repo), *arguments]
    try:
        result = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except FileNotFoundError as error:
        raise ReleaseToolError("git is required but was not found") from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or "unknown git error"
        raise ReleaseToolError(f"git command failed: {detail}") from error
    return result.stdout


def detect_git_state(repo: Path) -> GitState:
    tags = []
    for line in _run_git(repo, ["tag", "--merged", "HEAD", "--list", "v*"]).splitlines():
        tag = line.strip()
        match = TAG_RE.fullmatch(tag)
        if match is not None:
            tags.append((Version.from_tag(tag), tag))
    if not tags:
        raise ReleaseToolError("no reachable canonical vX.Y.Z tag was found")
    latest_version, latest_tag = max(tags)
    raw_messages = _run_git(
        repo,
        ["log", "--reverse", "--format=%B%x00", f"{latest_tag}..HEAD"],
    )
    commit_messages = tuple(
        message.strip() for message in raw_messages.split("\0") if message.strip()
    )
    return GitState(
        latest_tag=latest_tag,
        latest_version=latest_version,
        commit_messages=commit_messages,
    )


def _prepare_temp(path: Path, content: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, mode)
        return temporary_path
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def atomic_write_many(changes: Mapping[Path, str]) -> None:
    """Stage every file before replacing each destination atomically."""

    originals = {path: path.read_text(encoding="utf-8") for path in changes}
    temporary = {path: _prepare_temp(path, content) for path, content in changes.items()}
    replaced: list[Path] = []
    try:
        for path, temporary_path in temporary.items():
            os.replace(temporary_path, path)
            replaced.append(path)
        for parent in {path.parent for path in changes}:
            try:
                descriptor = os.open(parent, os.O_RDONLY)
            except OSError:
                continue
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    except BaseException:
        for path in reversed(replaced):
            rollback = _prepare_temp(path, originals[path])
            os.replace(rollback, path)
        raise
    finally:
        for temporary_path in temporary.values():
            temporary_path.unlink(missing_ok=True)


def _read_repository(repo: Path) -> tuple[Path, str, Path, str]:
    project_path = repo / PROJECT_RELATIVE_PATH
    changelog_path = repo / CHANGELOG_RELATIVE_PATH
    try:
        project_text = project_path.read_text(encoding="utf-8")
        changelog_text = changelog_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise ReleaseToolError(f"cannot read release metadata: {error}") from error
    return project_path, project_text, changelog_path, changelog_text


def _result_payload(
    *,
    status: str,
    needed: bool,
    changed: bool,
    latest_tag: str,
    previous_version: Version,
    version: Version,
    build: int,
    bump: str,
    release_notes: str,
) -> dict[str, object]:
    return {
        "status": status,
        "needed": needed,
        "changed": changed,
        "latest_tag": latest_tag,
        "previous_version": str(previous_version),
        "previous_tag": previous_version.tag,
        "version": str(version),
        "tag": version.tag,
        "build": build,
        "bump": bump,
        "release_notes": release_notes,
    }


def _github_value(value: object) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    return str(value)


def write_github_outputs(path: Path, payload: Mapping[str, object]) -> None:
    output = dict(payload)
    output["json"] = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    try:
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            for key, value in output.items():
                rendered = _github_value(value)
                if "\n" in rendered or "\r" in rendered:
                    delimiter = f"CASANATIVE_{uuid.uuid4().hex}"
                    while delimiter in rendered:
                        delimiter = f"CASANATIVE_{uuid.uuid4().hex}"
                    handle.write(f"{key}<<{delimiter}\n{rendered}\n{delimiter}\n")
                else:
                    handle.write(f"{key}={rendered}\n")
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as error:
        raise ReleaseToolError(f"cannot write GitHub outputs: {error}") from error


def _emit(payload: Mapping[str, object], github_output: Optional[str]) -> None:
    if github_output:
        write_github_outputs(Path(github_output), payload)
    print(json.dumps(payload, sort_keys=True))


def command_check(args: argparse.Namespace) -> dict[str, object]:
    repo = Path(args.repo).resolve()
    git_state = detect_git_state(repo)
    _, project_text, _, changelog_text = _read_repository(repo)
    project = parse_project(project_text)
    expected = (
        Version.from_tag(args.expected_tag)
        if args.expected_tag is not None
        else git_state.latest_version
    )
    validate_changelog(changelog_text, expected)
    if project.version != expected:
        raise ReleaseToolError(
            f"project version {project.version} does not match expected {expected}"
        )
    status = "checked" if expected == git_state.latest_version else "checked_pending_tag"
    return _result_payload(
        status=status,
        needed=expected != git_state.latest_version,
        changed=False,
        latest_tag=git_state.latest_tag,
        previous_version=git_state.latest_version,
        version=project.version,
        build=project.build,
        bump="",
        release_notes=parse_changelog(changelog_text).unreleased_body,
    )


def command_plan(args: argparse.Namespace) -> dict[str, object]:
    repo = Path(args.repo).resolve()
    git_state = detect_git_state(repo)
    _, project_text, _, changelog_text = _read_repository(repo)
    plan = plan_release_texts(
        project_text,
        changelog_text,
        latest_version=git_state.latest_version,
        commit_messages=git_state.commit_messages,
    )
    return _result_payload(
        status=plan.status,
        needed=plan.needed,
        changed=False,
        latest_tag=git_state.latest_tag,
        previous_version=plan.previous_version,
        version=plan.version,
        build=plan.build,
        bump=plan.bump,
        release_notes=plan.release_notes,
    )


def command_prepare(args: argparse.Namespace) -> dict[str, object]:
    repo = Path(args.repo).resolve()
    git_state = detect_git_state(repo)
    project_path, project_text, changelog_path, changelog_text = _read_repository(repo)
    plan = plan_release_texts(
        project_text,
        changelog_text,
        latest_version=git_state.latest_version,
        commit_messages=git_state.commit_messages,
    )
    requested_version = Version.parse(args.version, label="--version")
    if args.build < 1:
        raise ReleaseToolError("--build must be a positive integer")
    if not plan.needed:
        return _result_payload(
            status=plan.status,
            needed=False,
            changed=False,
            latest_tag=git_state.latest_tag,
            previous_version=plan.previous_version,
            version=plan.version,
            build=plan.build,
            bump=plan.bump,
            release_notes=plan.release_notes,
        )
    if requested_version != plan.version or args.build != plan.build:
        raise ReleaseToolError(
            f"requested {requested_version} build {args.build} does not match "
            f"plan {plan.version} build {plan.build}"
        )
    try:
        release_date = dt.date.fromisoformat(args.date)
    except ValueError as error:
        raise ReleaseToolError(f"invalid release date: {error}") from error
    prepared = prepare_release_texts(
        project_text,
        changelog_text,
        plan=plan,
        release_date=release_date,
    )
    if prepared.changed:
        atomic_write_many(
            {
                project_path: prepared.project_text,
                changelog_path: prepared.changelog_text,
            }
        )
    return _result_payload(
        status=prepared.status,
        needed=True,
        changed=prepared.changed,
        latest_tag=git_state.latest_tag,
        previous_version=prepared.previous_version,
        version=prepared.version,
        build=prepared.build,
        bump=prepared.bump,
        release_notes=prepared.release_notes,
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument(
            "--repo", default=".", help="repository root (default: current directory)"
        )
        subparser.add_argument(
            "--github-output",
            default=os.environ.get("GITHUB_OUTPUT"),
            help="append step outputs to this GitHub Actions output file",
        )
        subparser.add_argument(
            "--json",
            action="store_true",
            help="emit the machine-readable JSON result (JSON is the default output)",
        )

    check = subparsers.add_parser("check", help="validate version and changelog invariants")
    add_common(check)
    check.add_argument(
        "--expected-tag",
        help="validate a prepared version before its tag exists (canonical vX.Y.Z)",
    )
    check.set_defaults(handler=command_check)

    plan = subparsers.add_parser(
        "plan", help="plan the next version from all commits after the latest release tag"
    )
    add_common(plan)
    plan.set_defaults(handler=command_plan)

    prepare = subparsers.add_parser(
        "prepare", help="prepare the deterministic next version and changelog section"
    )
    add_common(prepare)
    prepare.add_argument("--version", required=True, help="planned canonical X.Y.Z version")
    prepare.add_argument("--build", required=True, type=int, help="planned positive build number")
    prepare.add_argument("--date", required=True, help="release date in YYYY-MM-DD")
    prepare.set_defaults(handler=command_prepare)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        payload = args.handler(args)
        _emit(payload, args.github_output)
        return 0
    except ReleaseToolError as error:
        print(f"release_tool: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
