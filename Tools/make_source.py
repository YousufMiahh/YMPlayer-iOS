#!/usr/bin/env python3
"""Writes source.json: a SideStore / AltStore source for YM Player.

Added once in SideStore (Sources → +), it lets SideStore see each new release and
update the app in place, like the Android app's updater. CI attaches it to every
release, so this link always points at the newest one:
https://github.com/YousufMiahh/YMPlayer-iOS/releases/latest/download/source.json
"""
import json, os, sys, datetime

repo = "YousufMiahh/YMPlayer-iOS"
run, ipa, notes_file = sys.argv[1], sys.argv[2], sys.argv[3]
version = f"1.0.{run}"
notes = open(notes_file).read().strip() if os.path.exists(notes_file) else ""

source = {
    "name": "YM Player",
    "identifier": "com.ymplayer.source",
    "subtitle": "Yousuf's IPTV player",
    "website": f"https://github.com/{repo}",
    "iconURL": f"https://raw.githubusercontent.com/{repo}/main/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
    "apps": [{
        "name": "YM Player",
        "bundleIdentifier": "com.ymplayer.ios",
        "developerName": "Yousuf Miah",
        "subtitle": "Live TV, films and series from your Xtream login",
        "localizedDescription": "YM Player for iPhone and iPad: Live TV, films and series, downloads, AirPlay and Chromecast, synced with the other YM Player apps.",
        "iconURL": f"https://raw.githubusercontent.com/{repo}/main/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        "tintColor": "0A84FF",
        "category": "entertainment",
        "versions": [{
            "version": version,
            "buildVersion": run,
            "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "localizedDescription": notes,
            "downloadURL": f"https://github.com/{repo}/releases/download/v{version}/YMPlayer.ipa",
            "size": os.path.getsize(ipa),
            "minOSVersion": "16.0",
        }],
        "appPermissions": {"entitlements": [], "privacy": {}},
    }],
    "news": [],
}
json.dump(source, open("source.json", "w"), indent=2)
print(f"source.json for {version}")
