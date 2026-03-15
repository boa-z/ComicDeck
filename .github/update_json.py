import json
import os
import re
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def prepare_description(text: str) -> str:
    text = re.sub("<[^<]+?>", "", text)
    text = re.sub(r"#{1,6}\s?", "", text)
    text = re.sub(r"\*{2}", "", text)
    text = re.sub(r"(?<=\r|\n)-", "•", text)
    text = re.sub(r"`", "\"", text)
    text = re.sub(r"\r\n\r\n", "\r \n", text)
    return text.strip()


def fetch_release_by_tag(repo_url: str, tag: str) -> dict:
    api_url = f"https://api.github.com/repos/{repo_url}/releases/tags/{tag}"
    headers = {
        "Accept": "application/vnd.github+json",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = Request(api_url, headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except (HTTPError, URLError) as exc:
        raise RuntimeError(f"Failed to fetch nightly release metadata: {exc}") from exc


def extract_metadata_from_release(release: dict) -> tuple[str, str, str]:
    body = release.get("body") or ""
    version_match = re.search(r"^Version:\s*(.+)$", body, re.MULTILINE)
    commit_match = re.search(r"^Commit:\s*([0-9a-f]{7,40})$", body, re.MULTILINE)
    message_match = re.search(r"^Message:\s*(.+)$", body, re.MULTILINE)

    version_label = (
        version_match.group(1).strip()
        if version_match
        else os.environ.get("VERSION_LABEL", "0.0.1+1")
    )
    commit = (
        commit_match.group(1).strip()[:7]
        if commit_match
        else os.environ.get("GITHUB_SHA", "")[:7]
    )
    headline = (
        message_match.group(1).strip()
        if message_match
        else os.environ.get("COMMIT_MSG", "Automatic nightly build").strip()
    )
    return version_label, commit, headline


def build_version_description(release: dict, commit: str, headline: str) -> str:
    workflow_link_match = re.search(r"^Workflow:\s*(https?://\S+)$", release.get("body") or "", re.MULTILINE)
    workflow_link = workflow_link_match.group(1).strip() if workflow_link_match else ""

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


def update_json_file(repo_url: str, json_file: str) -> None:
    with open(json_file, "r", encoding="utf-8") as file:
        data = json.load(file)

    data.setdefault("name", "ComicDeck")
    data.setdefault("identifier", "boa.ComicDeck")
    data.setdefault("website", f"https://github.com/{repo_url}")
    data.setdefault("subtitle", "ComicDeck official AltStore source.")
    data.setdefault(
        "description",
        "This is the official AltStore source for ComicDeck.\n\nRead comics from installed sources, manage offline downloads, and keep your library in sync.",
    )
    data.setdefault("tintColor", "#2F6FED")
    data.setdefault(
        "iconURL",
        "https://raw.githubusercontent.com/boa-z/ComicDeck/main/ComicDeck/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png",
    )
    data.setdefault("news", [])

    app = data["apps"][0]
    app.setdefault("beta", False)
    app.setdefault("developerName", "boa")
    app.setdefault("subtitle", "SwiftUI comic reader with source browsing, offline downloads, and tracking.")
    app.setdefault(
        "localizedDescription",
        "Read comics from installed sources, manage offline downloads, and keep your library in sync.",
    )
    app.setdefault("category", "entertainment")
    app.setdefault("tintColor", "#2F6FED")
    app.setdefault(
        "iconURL",
        "https://raw.githubusercontent.com/boa-z/ComicDeck/main/ComicDeck/Assets.xcassets/AppIcon.appiconset/icon-ios-1024x1024.png",
    )
    app.setdefault("screenshotURLs", [])
    app.setdefault("appPermissions", {"entitlements": [], "privacy": {}})
    release = fetch_release_by_tag(repo_url, "nightly")

    ipa_asset = next((asset for asset in release.get("assets", []) if asset["name"].endswith(".ipa")), None)
    if ipa_asset is None:
        raise RuntimeError("No IPA asset found in nightly release.")

    version_label, commit, headline = extract_metadata_from_release(release)
    version_date = release.get("published_at") or datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    description = build_version_description(release, commit, headline)

    version_entry = {
        "version": version_label,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": ipa_asset["browser_download_url"],
        "size": ipa_asset["size"],
    }
    if commit:
        version_entry["commit"] = commit
    if headline:
        version_entry["headline"] = headline

    app["versions"] = [version_entry]
    app.update(
        {
            "version": version_label,
            "versionDate": version_date,
            "versionDescription": description,
            "downloadURL": ipa_asset["browser_download_url"],
            "size": ipa_asset["size"],
        }
    )
    if commit:
        app["commit"] = commit
    if headline:
        app["headline"] = headline

    nightly_channel = next(
        (channel for channel in app.get("releaseChannels", []) if channel["track"] == "nightly"),
        None,
    )
    if nightly_channel is None:
        nightly_channel = {"track": "nightly", "releases": []}
        app.setdefault("releaseChannels", []).append(nightly_channel)
    nightly_channel["releases"] = [version_entry]

    with open(json_file, "w", encoding="utf-8") as file:
        json.dump(data, file, indent=2, ensure_ascii=False)
        file.write("\n")

    print("JSON file updated successfully.")


def main() -> None:
    update_json_file("boa-z/ComicDeck", "./.github/apps.json")


if __name__ == "__main__":
    main()
