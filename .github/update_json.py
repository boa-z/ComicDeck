import json
import re
import os
from datetime import datetime

def prepare_description(text):
    text = re.sub('<[^<]+?>', '', text) # Remove HTML tags
    text = re.sub(r'#{1,6}\s?', '', text) # Remove markdown header tags
    text = re.sub(r'\*{2}', '', text) # Remove all occurrences of two consecutive asterisks
    text = re.sub(r'(?<=\r|\n)-', '•', text) # Only replace - with • if it is preceded by \r or \n
    text = re.sub(r'`', '\"', text) # Replace ` with \"
    text = re.sub(r'\r\n\r\n', '\r \n', text) # Replace \r\n\r\n with \r \n (avoid incorrect display of the description regarding paragraphs)
    return text

def get_latest_nightly_build(repo_url):
    # Since we are using actions, we need to get the latest run
    # For now, we will assume the environment variables are passed to this script
    return {
        "tag_name": "nightly",
        "published_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "body": os.environ.get("COMMIT_MSG", "Automatic nightly build"),
        "assets": [
            {
                "name": "ComicDeck.ipa",
                "browser_download_url": os.environ.get("IPA_URL", ""),
                "size": int(os.environ.get("IPA_SIZE", 0))
            }
        ]
    }

def update_json_file(repo_url, json_file):
    try:
        with open(json_file, "r") as file:
            data = json.load(file)
    except json.JSONDecodeError as e:
        print(f"Error reading JSON file: {e}")
        raise

    app = data["apps"][0]

    ipa_filename = os.environ.get("IPA_FILENAME", "")
    version_match = re.match(r"^ComicDeck-(?P<version>[^-]+)-(?P<commit>[0-9a-f]{7})-unsigned\.ipa$", ipa_filename)
    if not version_match:
        raise RuntimeError(f"Unable to parse version from IPA filename: {ipa_filename}")
    version_label = version_match.group("version")
    commit = version_match.group("commit")

    nightly_data = get_latest_nightly_build(repo_url)
    version_date = nightly_data["published_at"]
    description = prepare_description(nightly_data["body"])

    download_url = nightly_data["assets"][0]["browser_download_url"]
    size = nightly_data["assets"][0]["size"]

    version_entry = {
        "version": version_label,
        "date": version_date,
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": size,
        "commit": commit
    }

    # Update nightly channel
    nightly_channel = None
    for channel in app.get('releaseChannels', []):
        if channel['track'] == 'nightly':
            nightly_channel = channel
            break
    if nightly_channel is None:
        nightly_channel = {"track": "nightly", "releases": []}
        app.setdefault("releaseChannels", []).append(nightly_channel)
    nightly_channel['releases'] = [version_entry]

    try:
        with open(json_file, "w") as file:
            json.dump(data, file, indent=2)
        print("JSON file updated successfully.")
    except IOError as e:
        print(f"Error writing to JSON file: {e}")
        raise

def main():
    repo_url = "boa-z/ComicDeck"
    json_file = "./.github/apps.json"

    try:
        update_json_file(repo_url, json_file)
    except Exception as e:
        print(f"An error occurred: {e}")
        raise

if __name__ == "__main__":
    main()
