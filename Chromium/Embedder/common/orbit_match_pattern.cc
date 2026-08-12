// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_match_pattern.h"

#include "base/strings/string_util.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// Anchored glob match: '*' matches any run of characters, including '/' --
// Chrome match patterns do not treat path separators specially.
bool WildcardMatch(std::string_view pattern, std::string_view text) {
  size_t p = 0, t = 0;
  size_t star_p = std::string_view::npos, star_t = 0;
  while (t < text.size()) {
    if (p < pattern.size() && (pattern[p] == text[t])) {
      ++p;
      ++t;
    } else if (p < pattern.size() && pattern[p] == '*') {
      star_p = p++;
      star_t = t;
    } else if (star_p != std::string_view::npos) {
      p = star_p + 1;
      t = ++star_t;
    } else {
      return false;
    }
  }
  while (p < pattern.size() && pattern[p] == '*') {
    ++p;
  }
  return p == pattern.size();
}

struct ParsedPattern {
  bool is_all_urls = false;
  bool scheme_is_any = false;
  std::string scheme;  // valid only if !scheme_is_any

  enum class HostMode { kAny, kSuffix, kExact } host_mode = HostMode::kAny;
  std::string host;  // valid for kSuffix/kExact

  bool has_path = false;
  std::string path_pattern;

  bool valid = false;
};

ParsedPattern Parse(const std::string& pattern) {
  ParsedPattern out;
  if (pattern == "<all_urls>") {
    out.is_all_urls = true;
    out.valid = true;
    return out;
  }

  size_t scheme_sep = pattern.find("://");
  if (scheme_sep == std::string::npos) {
    return out;
  }
  std::string scheme_part = pattern.substr(0, scheme_sep);
  std::string rest = pattern.substr(scheme_sep + 3);

  if (scheme_part == "*") {
    out.scheme_is_any = true;
  } else {
    out.scheme = base::ToLowerASCII(scheme_part);
  }

  std::string host_part;
  std::string path_part;
  size_t slash = rest.find('/');
  if (slash == std::string::npos) {
    host_part = rest;
    path_part = "/*";
  } else {
    host_part = rest.substr(0, slash);
    path_part = rest.substr(slash);
  }

  if (host_part.empty()) {
    return out;
  } else if (host_part == "*") {
    out.host_mode = ParsedPattern::HostMode::kAny;
  } else if (base::StartsWith(host_part, "*.")) {
    out.host_mode = ParsedPattern::HostMode::kSuffix;
    out.host = base::ToLowerASCII(host_part.substr(2));
  } else {
    out.host_mode = ParsedPattern::HostMode::kExact;
    out.host = base::ToLowerASCII(host_part);
  }

  out.has_path = true;
  out.path_pattern = path_part;
  out.valid = true;
  return out;
}

bool MatchesPath(const ParsedPattern& pattern, const GURL& url) {
  if (!pattern.has_path) {
    return true;
  }
  std::string path(url.path());
  if (path.empty()) {
    path = "/";
  }
  if (url.has_query() && !url.query().empty()) {
    path += "?";
    path += url.query();
  }
  return WildcardMatch(pattern.path_pattern, path);
}

bool Matches(const ParsedPattern& pattern, const GURL& url) {
  if (pattern.is_all_urls) {
    return true;
  }
  if (!pattern.valid || !url.is_valid()) {
    return false;
  }

  const std::string url_scheme = base::ToLowerASCII(url.scheme());
  if (pattern.scheme_is_any) {
    if (url_scheme != "http" && url_scheme != "https") {
      return false;
    }
  } else if (url_scheme != pattern.scheme) {
    return false;
  }

  if (!url.has_host() || url.host().empty()) {
    // file:// has no host; only host "*" patterns match it.
    if (pattern.host_mode == ParsedPattern::HostMode::kAny &&
        url_scheme == "file") {
      return MatchesPath(pattern, url);
    }
    return false;
  }

  const std::string url_host = base::ToLowerASCII(url.host());
  switch (pattern.host_mode) {
    case ParsedPattern::HostMode::kAny:
      break;
    case ParsedPattern::HostMode::kExact:
      if (url_host != pattern.host) {
        return false;
      }
      break;
    case ParsedPattern::HostMode::kSuffix:
      if (url_host != pattern.host &&
          !base::EndsWith(url_host, "." + pattern.host)) {
        return false;
      }
      break;
  }

  return MatchesPath(pattern, url);
}

}  // namespace

bool MatchPatternsMatch(const std::vector<std::string>& patterns,
                        const GURL& url) {
  for (const std::string& raw : patterns) {
    ParsedPattern parsed = Parse(raw);
    if (parsed.valid && Matches(parsed, url)) {
      return true;
    }
  }
  return false;
}

}  // namespace orbit
