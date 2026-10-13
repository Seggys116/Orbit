#!/bin/bash
# Orbit renders with system WebKit. This script used to copy Orbit Framework.framework
# into the app bundle. It stays so an old build phase does not embed Chromium.

echo "embed-chromium-framework: Orbit uses system WebKit; no Chromium framework is embedded."
exit 0
