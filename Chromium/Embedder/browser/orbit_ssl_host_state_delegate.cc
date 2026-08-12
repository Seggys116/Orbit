// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_ssl_host_state_delegate.h"

#include "base/containers/span.h"
#include "base/functional/callback.h"
#include "base/strings/string_number_conversions.h"
#include "net/cert/x509_certificate.h"
#include "url/gurl.h"

namespace orbit {

namespace {

std::string ChainFingerprint(const net::X509Certificate& cert) {
  return base::HexEncode(cert.CalculateChainFingerprint256());
}

}  // namespace

OrbitSSLHostStateDelegate::OrbitSSLHostStateDelegate() = default;

OrbitSSLHostStateDelegate::~OrbitSSLHostStateDelegate() = default;

void OrbitSSLHostStateDelegate::AllowCert(
    const std::string& host,
    const net::X509Certificate& cert,
    net::Error error,
    content::StoragePartition* storage_partition) {
  if (host.empty()) {
    return;
  }
  allowed_certs_[storage_partition][host].insert(
      CertException(ChainFingerprint(cert), error));
}

void OrbitSSLHostStateDelegate::Clear(
    base::RepeatingCallback<bool(const std::string&)> host_filter) {
  if (host_filter.is_null()) {
    allowed_certs_.clear();
    http_allowed_hosts_.clear();
    insecure_content_by_host_.clear();
    return;
  }
  for (auto& partition : allowed_certs_) {
    std::erase_if(partition.second, [&host_filter](const auto& entry) {
      return host_filter.Run(entry.first);
    });
  }
  for (auto& partition : http_allowed_hosts_) {
    std::erase_if(partition.second, [&host_filter](const std::string& host) {
      return host_filter.Run(host);
    });
  }
  std::erase_if(insecure_content_by_host_, [&host_filter](const auto& entry) {
    return host_filter.Run(entry.first);
  });
}

content::SSLHostStateDelegate::CertJudgment
OrbitSSLHostStateDelegate::QueryPolicy(
    const std::string& host,
    const net::X509Certificate& cert,
    net::Error error,
    content::StoragePartition* storage_partition) {
  auto partition_it = allowed_certs_.find(storage_partition);
  if (partition_it == allowed_certs_.end()) {
    return DENIED;
  }
  auto host_it = partition_it->second.find(host);
  if (host_it == partition_it->second.end()) {
    return DENIED;
  }
  return host_it->second.contains(CertException(ChainFingerprint(cert), error))
             ? ALLOWED
             : DENIED;
}

void OrbitSSLHostStateDelegate::HostRanInsecureContent(
    const std::string& host,
    InsecureContentType content_type) {
  insecure_content_by_host_[host] |= 1 << static_cast<int>(content_type);
}

bool OrbitSSLHostStateDelegate::DidHostRunInsecureContent(
    const std::string& host,
    InsecureContentType content_type) {
  auto it = insecure_content_by_host_.find(host);
  return it != insecure_content_by_host_.end() &&
         (it->second & (1 << static_cast<int>(content_type))) != 0;
}

void OrbitSSLHostStateDelegate::AllowHttpForHost(
    const std::string& host,
    content::StoragePartition* storage_partition) {
  if (host.empty()) {
    return;
  }
  http_allowed_hosts_[storage_partition].insert(host);
}

bool OrbitSSLHostStateDelegate::IsHttpAllowedForHost(
    const std::string& host,
    content::StoragePartition* storage_partition) {
  auto it = http_allowed_hosts_.find(storage_partition);
  return it != http_allowed_hosts_.end() && it->second.contains(host);
}

void OrbitSSLHostStateDelegate::RevokeUserAllowExceptions(
    const std::string& host) {
  for (auto& partition : allowed_certs_) {
    partition.second.erase(host);
  }
  for (auto& partition : http_allowed_hosts_) {
    partition.second.erase(host);
  }
}

// Orbit ships no HTTPS-First Mode, so there is no per-host enforcement state
// to record and nothing is ever enforced -- exactly what content:: saw before
// this delegate existed at all.
void OrbitSSLHostStateDelegate::SetHttpsEnforcementForHost(
    const std::string& host,
    bool enforce,
    content::StoragePartition* storage_partition) {}

bool OrbitSSLHostStateDelegate::IsHttpsEnforcedForUrl(
    const GURL& url,
    content::StoragePartition* storage_partition) {
  return false;
}

bool OrbitSSLHostStateDelegate::HasAllowException(
    const std::string& host,
    content::StoragePartition* storage_partition) {
  auto certs_it = allowed_certs_.find(storage_partition);
  if (certs_it != allowed_certs_.end()) {
    auto host_it = certs_it->second.find(host);
    if (host_it != certs_it->second.end() && !host_it->second.empty()) {
      return true;
    }
  }
  auto http_it = http_allowed_hosts_.find(storage_partition);
  return http_it != http_allowed_hosts_.end() && http_it->second.contains(host);
}

bool OrbitSSLHostStateDelegate::HasAllowExceptionForAnyHost(
    content::StoragePartition* storage_partition) {
  auto certs_it = allowed_certs_.find(storage_partition);
  if (certs_it != allowed_certs_.end()) {
    for (const auto& [host, exceptions] : certs_it->second) {
      if (!exceptions.empty()) {
        return true;
      }
    }
  }
  auto http_it = http_allowed_hosts_.find(storage_partition);
  return http_it != http_allowed_hosts_.end() && !http_it->second.empty();
}

}  // namespace orbit
