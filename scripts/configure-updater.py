#!/usr/bin/env python3
"""Configure public updater metadata only. Never reads signing keys."""
import os
import plistlib
import sys
from urllib.parse import urlsplit

PUBLIC_KEY = "ATH06nujvadK3M79ihD6vc8A8b0nCsEzCf+VBP9a2TU="

def configure(path, test=False):
    with open(path, "rb") as stream:
        info = plistlib.load(stream)
    feed = os.environ.get("BOUNDAS_TEST_FEED_URL" if test else "BOUNDAS_UPDATE_FEED_URL", "")
    if feed:
        url = urlsplit(feed)
        loopback = url.hostname in ("localhost", "127.0.0.1", "::1")
        if not url.hostname or url.username or url.password or url.fragment or not (
            url.scheme == "https" and (test or not loopback)
            or test and url.scheme == "http" and loopback
        ):
            raise ValueError("Invalid update feed: production requires HTTPS; HTTP is test-loopback only")
    info.pop("SUFeedURL", None)
    info.pop("BoundasGateTestFeedURL", None)
    info["SUPublicEDKey"] = PUBLIC_KEY
    info["SUVerifyUpdateBeforeExtraction"] = True
    info["SUEnableAutomaticChecks"] = bool(feed)
    info["SUAutomaticallyUpdate"] = False
    if feed:
        info["BoundasGateTestFeedURL" if test else "SUFeedURL"] = feed
        if test and url.scheme == "http":
            info.setdefault("NSAppTransportSecurity", {})["NSAllowsLocalNetworking"] = True
    with open(path, "wb") as stream:
        plistlib.dump(info, stream)

if __name__ == "__main__":
    configure(sys.argv[1], "--test" in sys.argv[2:])
