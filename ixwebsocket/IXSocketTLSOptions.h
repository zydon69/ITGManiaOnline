/*
 *  IXSocketTLSOptions.h
 *  Author: Matt DeBoer
 *  Copyright (c) 2019 Machine Zone, Inc. All rights reserved.
 */

#pragma once

#include <string>

namespace ix
{
    struct SocketTLSOptions
    {
    public:
        // check validity of the object
        bool isValid() const;

        // the certificate presented to peers
        std::string certFile;

        // the key used for signing/encryption
        std::string keyFile;

        // the ca certificate (or certificate bundle) file containing
        // certificates to be trusted by peers; use 'SYSTEM' to
        // leverage the system defaults, use 'NONE' to disable peer verification
        std::string caFile = "SYSTEM";

        // list of ciphers (rsa, etc...)
        std::string ciphers = "DEFAULT";

        // whether tls is enabled, used for server code
        bool tls = false;

        // whether to skip validating the peer's hostname against the certificate presented
        bool disable_hostname_validation = false;

        // Optional comma-separated host=sha256_spki_hex pins. When a TLS client
        // connects to a matching host, the peer certificate public key must hash
        // to one of the configured SHA-256 SPKI pins.
        std::string publicKeySha256Pins;

        bool hasCertAndKey() const;

        bool isUsingSystemDefaults() const;

        bool isUsingInMemoryCAs() const;

        bool isPeerVerifyDisabled() const;

        bool isUsingDefaultCiphers() const;

        const std::string& getErrorMsg() const;

        std::string getDescription() const;

    private:
        mutable std::string _errMsg;
        mutable bool _validated = false;
    };
} // namespace ix
