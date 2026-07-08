#include "NoteAnnotation.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

#include "RageLog.h"
#include "StepParityDatastructs.h"
#include "mbedtls/base64.h"

namespace {
constexpr size_t kSerializedFootCount = StepParity::NUM_Foot;
constexpr size_t kSerializedAnnotationSize = sizeof(float) +
                                             kSerializedFootCount +
                                             sizeof(uint16_t);
static_assert(NUM_TechCountsCategory <= 16, "tech mask is serialized as u16");

void MakeUrlSafe(std::string& value) {
  for (char& c : value) {
    if (c == '+') {
      c = '-';
    } else if (c == '/') {
      c = '_';
    }
  }
}

void MakeStandardBase64(std::string& value) {
  for (char& c : value) {
    if (c == '-') {
      c = '+';
    } else if (c == '_') {
      c = '/';
    }
  }
}

bool Base64Encode(const std::vector<uint8_t>& input, std::string& output) {
  size_t outLen = 0;
  int result = mbedtls_base64_encode(
      nullptr, 0, &outLen, input.data(), input.size());
  if (result != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL && result != 0) {
    LOG->Warn("NoteAnnotation base64 size query failed: %d", result);
    return false;
  }

  output.assign(outLen, '\0');
  result = mbedtls_base64_encode(
      reinterpret_cast<unsigned char*>(output.data()), output.size(), &outLen,
      input.data(), input.size());
  if (result != 0) {
    LOG->Warn("NoteAnnotation base64 encode failed: %d", result);
    output.clear();
    return false;
  }

  output.resize(outLen);
  return true;
}

bool Base64Decode(const std::string& input, std::vector<uint8_t>& output) {
  size_t outLen = 0;
  int result = mbedtls_base64_decode(
      nullptr, 0, &outLen,
      reinterpret_cast<const unsigned char*>(input.data()), input.size());
  if (result != MBEDTLS_ERR_BASE64_BUFFER_TOO_SMALL && result != 0) {
    LOG->Warn("NoteAnnotation base64 size query failed: %d", result);
    return false;
  }

  output.assign(outLen, 0);
  result = mbedtls_base64_decode(
      output.data(), output.size(), &outLen,
      reinterpret_cast<const unsigned char*>(input.data()), input.size());
  if (result != 0) {
    LOG->Warn("NoteAnnotation base64 decode failed: %d", result);
    output.clear();
    return false;
  }

  output.resize(outLen);
  return true;
}

void SerializeAnnotation(
    const NoteAnnotation& annotation, std::vector<uint8_t>& output) {
  const size_t offset = output.size();
  output.resize(offset + kSerializedAnnotationSize, 0);
  size_t cursor = offset;

  float beat = std::isfinite(annotation.beat) ? annotation.beat : 0.0f;
  std::memcpy(&output[cursor], &beat, sizeof(float));
  cursor += sizeof(float);

  for (size_t foot = 0; foot < kSerializedFootCount; ++foot) {
    int value = StepParity::INVALID_COLUMN;
    if (foot < annotation.whereTheFeetAre.size()) {
      value = annotation.whereTheFeetAre[foot];
    }
    value = std::clamp(
        value, static_cast<int>(std::numeric_limits<int8_t>::min()),
        static_cast<int>(std::numeric_limits<int8_t>::max()));
    output[cursor++] = static_cast<uint8_t>(static_cast<int8_t>(value));
  }

  uint16_t techMask = 0;
  for (TechCountsCategory category : annotation.tech) {
    if (category >= 0 && category < NUM_TechCountsCategory) {
      techMask |= static_cast<uint16_t>(1u << category);
    }
  }
  output[cursor++] = static_cast<uint8_t>(techMask & 0xff);
  output[cursor++] = static_cast<uint8_t>((techMask >> 8) & 0xff);
}

NoteAnnotation DeserializeAnnotation(const uint8_t* input) {
  NoteAnnotation annotation;
  size_t cursor = 0;

  std::memcpy(&annotation.beat, &input[cursor], sizeof(float));
  if (!std::isfinite(annotation.beat)) {
    annotation.beat = 0.0f;
  }
  cursor += sizeof(float);

  annotation.whereTheFeetAre.resize(kSerializedFootCount);
  for (size_t foot = 0; foot < kSerializedFootCount; ++foot) {
    annotation.whereTheFeetAre[foot] =
        static_cast<int8_t>(input[cursor++]);
  }

  const uint16_t techMask =
      static_cast<uint16_t>(input[cursor]) |
      static_cast<uint16_t>(input[cursor + 1] << 8);
  for (int category = 0; category < NUM_TechCountsCategory; ++category) {
    if ((techMask & static_cast<uint16_t>(1u << category)) != 0) {
      annotation.tech.push_back(static_cast<TechCountsCategory>(category));
    }
  }

  return annotation;
}
}  // namespace

void NoteAnnotation::FromString(
    const std::string& input, std::vector<NoteAnnotation>& out) {
  out.clear();
  if (input.empty()) {
    return;
  }

  std::string base64 = input;
  MakeStandardBase64(base64);

  std::vector<uint8_t> raw;
  if (!Base64Decode(base64, raw)) {
    return;
  }
  if (raw.size() % kSerializedAnnotationSize != 0) {
    LOG->Warn(
        "Ignoring malformed NoteAnnotations payload: size=%zu unit=%zu",
        raw.size(), kSerializedAnnotationSize);
    return;
  }

  const size_t count = raw.size() / kSerializedAnnotationSize;
  out.reserve(count);
  for (size_t i = 0; i < count; ++i) {
    out.push_back(
        DeserializeAnnotation(&raw[i * kSerializedAnnotationSize]));
  }
}

std::string NoteAnnotation::ToString(
    const std::vector<NoteAnnotation>& annotations) {
  if (annotations.empty()) {
    return "";
  }

  std::vector<uint8_t> raw;
  raw.reserve(annotations.size() * kSerializedAnnotationSize);
  for (const NoteAnnotation& annotation : annotations) {
    SerializeAnnotation(annotation, raw);
  }

  std::string encoded;
  if (!Base64Encode(raw, encoded)) {
    return "";
  }
  MakeUrlSafe(encoded);
  return encoded;
}

const std::string& NoteAnnotationCache::GetCompressed() const {
  if (compressed.empty() && !decompressed.empty()) {
    Compress();
  }
  return compressed;
}

const std::vector<NoteAnnotation>& NoteAnnotationCache::GetNoteAnnotations()
    const {
  if (decompressed.empty() && !compressed.empty()) {
    NoteAnnotation::FromString(compressed, decompressed);
  }
  return decompressed;
}

void NoteAnnotationCache::Compress() const {
  compressed = NoteAnnotation::ToString(decompressed);
  decompressed.clear();
}
