#ifndef NOTE_ANNOTATION_H
#define NOTE_ANNOTATION_H

#include <cstdint>
#include <string>
#include <vector>

#include "TechCounts.h"

struct NoteAnnotation {
  float beat = 0.0f;
  std::vector<int8_t> whereTheFeetAre;
  std::vector<TechCountsCategory> tech;

  static void FromString(
      const std::string& input, std::vector<NoteAnnotation>& out);
  static std::string ToString(const std::vector<NoteAnnotation>& annotations);
};

struct NoteAnnotationCache {
  mutable std::string compressed;
  mutable std::vector<NoteAnnotation> decompressed;

  const std::string& GetCompressed() const;
  const std::vector<NoteAnnotation>& GetNoteAnnotations() const;
  void Compress() const;
};

#endif
