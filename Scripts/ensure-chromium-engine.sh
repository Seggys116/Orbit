#!/bin/bash
# Orbit renders with system WebKit. This script used to fetch a Chromium engine.
# It stays so an old build phase is a no-op instead of a failed download.

echo "ensure-chromium-engine: Orbit uses system WebKit; no Chromium engine is installed."
exit 0
