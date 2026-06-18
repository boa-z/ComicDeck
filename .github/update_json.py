import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


REPO_URL = "boa-z/ComicDeck"
SOURCE_JSON = Path(".github/apps.json")
NIGHTLY_TAG = "nightly"
NIGHTLY_IPA_NAME = "ComicDeck.ipa"


def prepare_description(text: str) -> str:
    text = re.sub("<[^<]+?>", "", text)
    text = re.sub(r"#{1,6}\s?", "", text)
    text = re.sub(r"\*{2}", "", text)
    text = re.sub(r"(?<=\r|\n)-", "•", text)
    text = re.sub(r"`", "\"", text)
    text = re.sub(r"\r\n\r\n", "\r \n", text)
    return text.strip()


def github_request(api_url: str) -> dict:
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = Request(api_url, headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except (HTTPError, URLError) as exc:
        raise RuntimeError(f"Failed to fetch GitHub metadata from {api_url}: {exc}") from exc


def fetch_release_by_tag(repo_url: str, tag: str) -> dict:
    return github_request(f"https://api.github.com/repos/{repo_url}/releases/tags/{tag}")


def default_source() -> dict:
    return {
        "name": "ComicDeck",
        "identifier": "boa.ComicDeck",
        "website": f"https://github.com/{REPO_URL}",
        "subtitle": "ComicDeck official AltStore source.",
        "description": (
            "This is the official AltStore source for ComicDeck.\n\n"
            "Read comics from installed sources, manage offline downloads, and keep your library in sync."
        ),
        "tintColor": "#2F6FED",
        "iconURL": (
            "https://raw.githubusercontent.com/boa-z/ComicDeck/main/"
            "ComicDeck/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png"
        ),
        "apps": [
            {
                "beta": False,
                "name": "ComicDeck",
                "bundleIdentifier": "boa.ComicDeck",
                "developerName": "boa",
                "subtitle": "SwiftUI comic reader with source browsing, offline downloads, and tracking.",
                "localizedDescription": (
                    "Read comics from installed sources, manage offline downloads, and keep your library in sync."
                ),
                "category": "entertainment",
                "tintColor": "#2F6FED",
                "iconURL": (
                    "https://raw.githubusercontent.com/boa-z/ComicDeck/main/"
                    "ComicDeck/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png"
                ),
                "screenshotURLs": [],
                "appPermissions": {"entitlements": [], "privacy": {}},
                "versions": [],
                "releaseChannels": [
                    {"track": "stable", "releases": []},
                    {"track": "nightly", "releases": []},
                ],
            }
        ],
        "news": [],
    }


def load_source(json_file: Path) -> dict:
    if not json_file.exists():
        return default_source()

    with json_file.open("r", encoding="utf-8") as file:
        data = json.load(file)

    defaults = default_source()
    for key, value in defaults.items():
        data.setdefault(key, value)

    if not data.get("apps"):
        data["apps"] = defaults["apps"]

    app = data["apps"][0]
    for key, value in defaults["apps"][0].items():
        app.setdefault(key, value)

    existing_tracks = {channel.get("track") for channel in app.get("releaseChannels", [])}
    for channel in defaults["apps"][0]["releaseChannels"]:
        if channel["track"] not in existing_tracks:
            app.setdefault("releaseChannels", []).append(channel)

    return data


def version_from_release_body(release: dict) -> str:
    body = release.get("body") or ""
    match = re.search(r"^Version:\s*(.+)$", body, re.MULTILINE)
    if match:
        return match.group(1).strip()
    return os.environ.get("VERSION_LABEL", "0.0.1+1")


def commit_from_release_body(release: dict) -> str:
    body = release.get("body") or ""
    match = re.search(r"^Commit:\s*([0-9a-f]{7,40})$", body, re.MULTILINE)
    if match:
        return match.group(1).strip()[:7]
    return os.environ.get("COMMIT_SHA", os.environ.get("GITHUB_SHA", ""))[:7]


def headline_from_release_body(release: dict) -> str:
    body = release.get("body") or ""
    match = re.search(r"^Message:\s*(.+)$", body, re.MULTILINE)
    if match:
        return match.group(1).strip()
    return os.environ.get("COMMIT_MSG", "Automatic nightly build").strip()


def workflow_from_release_body(release: dict) -> str:
    body = release.get("body") or ""
    match = re.search(r"^Workflow:\s*(https?://\S+)$", body, re.MULTILINE)
    return match.group(1).strip() if match else os.environ.get("NIGHTLY_LINK", "").strip()


def build_version_description(commit: str, headline: str, workflow_link: str) -> str:
    lines = []
    if commit:
        lines.append(f"Commit: {commit}")
    if headline:
        lines.append(f"Message: {headline}")
    if workflow_link:
        lines.append(f"Workflow: {workflow_link}")
    if not lines:
        lines.append("Automatic nightly build")
    return prepare_description("\n".join(lines))


def release_download_url(repo_url: str, asset_name: str) -> str:
    return f"https://github.com/{repo_url}/releases/download/{NIGHTLY_TAG}/{asset_name}"


def local_nightly_metadata(repo_url: str) -> dict:
    ipa_path = Path(os.environ.get("LOCAL_IPA_PATH", NIGHTLY_IPA_NAME))
    if not ipa_path.exists():
        raise RuntimeError(f"Local IPA not found at {ipa_path}")

    commit = os.environ.get("COMMIT_SHA", os.environ.get("GITHUB_SHA", ""))[:7]
    headline = os.environ.get("COMMIT_MSG", "Automatic nightly build").strip()
    workflow_link = os.environ.get("NIGHTLY_LINK", "").strip()
    version_date = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    return {
        "version": os.environ.get("VERSION_LABEL", "0.0.1+1"),
        "date": version_date,
        "description": build_version_description(commit, headline, workflow_link),
        "downloadURL": release_download_url(repo_url, NIGHTLY_IPA_NAME),
        "size": ipa_path.stat().st_size,
        "commit": commit,
        "headline": headline,
    }


def release_nightly_metadata(repo_url: str) -> dict:
    release = fetch_release_by_tag(repo_url, NIGHTLY_TAG)
    ipa_asset = next(
        (asset for asset in release.get("assets", []) if asset.get("name") == NIGHTLY_IPA_NAME),
        None,
    )
    if ipa_asset is None:
        raise RuntimeError(f"No {NIGHTLY_IPA_NAME} asset found in {NIGHTLY_TAG} release.")

    commit = commit_from_release_body(release)
    headline = headline_from_release_body(release)
    workflow_link = workflow_from_release_body(release)

    version_date = ipa_asset.get("updated_at") or ipa_asset.get("created_at") or release.get("published_at")

    return {
        "version": version_from_release_body(release),
        "date": version_date or datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "description": build_version_description(commit, headline, workflow_link),
        "downloadURL": ipa_asset["browser_download_url"],
        "size": ipa_asset["size"],
        "commit": commit,
        "headline": headline,
    }


def apply_nightly_metadata(data: dict, metadata: dict) -> dict:
    app = data["apps"][0]
    version_entry = {
        "version": metadata["version"],
        "date": metadata["date"],
        "localizedDescription": metadata["description"],
        "downloadURL": metadata["downloadURL"],
        "size": metadata["size"],
    }
    if metadata.get("commit"):
        version_entry["commit"] = metadata["commit"]
    if metadata.get("headline"):
        version_entry["headline"] = metadata["headline"]

    app["versions"] = [version_entry]
    app.update(
        {
            "version": metadata["version"],
            "versionDate": metadata["date"],
            "versionDescription": metadata["description"],
            "downloadURL": metadata["downloadURL"],
            "size": metadata["size"],
        }
    )

    for key in ("commit", "headline"):
        if metadata.get(key):
            app[key] = metadata[key]
        else:
            app.pop(key, None)

    nightly_channel = next(
        (channel for channel in app.get("releaseChannels", []) if channel.get("track") == "nightly"),
        None,
    )
    if nightly_channel is None:
        nightly_channel = {"track": "nightly", "releases": []}
        app.setdefault("releaseChannels", []).append(nightly_channel)
    nightly_channel["releases"] = [version_entry]

    return data


def update_json_file(repo_url: str, json_file: Path, metadata: dict) -> None:
    data = load_source(json_file)
    data = apply_nightly_metadata(data, metadata)

    with json_file.open("w", encoding="utf-8") as file:
        json.dump(data, file, indent=2, ensure_ascii=False)
        file.write("\n")

    print("JSON file updated successfully.")


def main() -> None:
    mode = os.environ.get("ALTSTORE_MODE", "nightly-release")
    metadata = local_nightly_metadata(REPO_URL) if mode == "nightly-local" else release_nightly_metadata(REPO_URL)
    update_json_file(REPO_URL, SOURCE_JSON, metadata)


if __name__ == "__main__":
    main()
