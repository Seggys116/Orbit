// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// In-memory only: remembers which cert errors the user clicked through, keyed by
// (host, chain fingerprint, net error, StoragePartition); without it every judgment is DENIED.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_SSL_HOST_STATE_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_SSL_HOST_STATE_DELEGATE_H_

#include <map>
#include <set>
#include <string>
#include <utility>

#include "content/public/browser/ssl_host_state_delegate.h"

namespace orbit {

class OrbitSSLHostStateDelegate : public content::SSLHostStateDelegate {
 public:
  OrbitSSLHostStateDelegate();
  OrbitSSLHostStateDelegate(const OrbitSSLHostStateDelegate&) = delete;
  OrbitSSLHostStateDelegate& operator=(const OrbitSSLHostStateDelegate&) =
      delete;
  ~OrbitSSLHostStateDelegate() override;

  // content::SSLHostStateDelegate:
  void AllowCert(const std::string& host,
                 const net::X509Certificate& cert,
                 net::Error error,
                 content::StoragePartition* storage_partition) override;
  void Clear(
      base::RepeatingCallback<bool(const std::string&)> host_filter) override;
  CertJudgment QueryPolicy(
      const std::string& host,
      const net::X509Certificate& cert,
      net::Error error,
      content::StoragePartition* storage_partition) override;
  void HostRanInsecureContent(const std::string& host,
                              InsecureContentType content_type) override;
  bool DidHostRunInsecureContent(const std::string& host,
                                 InsecureContentType content_type) override;
  void AllowHttpForHost(const std::string& host,
                        content::StoragePartition* storage_partition) override;
  bool IsHttpAllowedForHost(
      const std::string& host,
      content::StoragePartition* storage_partition) override;
  void RevokeUserAllowExceptions(const std::string& host) override;
  void SetHttpsEnforcementForHost(
      const std::string& host,
      bool enforce,
      content::StoragePartition* storage_partition) override;
  bool IsHttpsEnforcedForUrl(
      const GURL& url,
      content::StoragePartition* storage_partition) override;
  bool HasAllowException(const std::string& host,
                         content::StoragePartition* storage_partition) override;
  bool HasAllowExceptionForAnyHost(
      content::StoragePartition* storage_partition) override;

 private:
  // Hex-encoded X509Certificate::CalculateChainFingerprint256 paired with the
  // net error it was allowed for.
  using CertException = std::pair<std::string, int>;

  // StoragePartition is held only as an identity value and never dereferenced,
  // so a partition destroyed while an entry still names it cannot dangle --
  // which is also why this is a void* rather than a raw_ptr member.
  using PartitionKey = const void*;

  std::map<PartitionKey, std::map<std::string, std::set<CertException>>>
      allowed_certs_;
  std::map<PartitionKey, std::set<std::string>> http_allowed_hosts_;
  std::map<std::string, int> insecure_content_by_host_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_SSL_HOST_STATE_DELEGATE_H_
