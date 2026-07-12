/*
 *  IXProgressCallback.h
 *  Author: Benjamin Sergeant
 *  Copyright (c) 2019 Machine Zone, Inc. All rights reserved.
 */

#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace ix
{
    using OnProgressCallback = std::function<bool(int64_t current, int64_t total)>;
    using OnChunkCallback = std::function<void(const std::string&)>;
}
