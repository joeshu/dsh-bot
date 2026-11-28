#ifndef DSBOT_ISH_RAW_DEFLATE_H
#define DSBOT_ISH_RAW_DEFLATE_H

#include <stddef.h>
#include <stdint.h>

/// Decode one ZIP method-8 raw DEFLATE stream into a caller-sized buffer.
/// Returns 0 only when the stream ends cleanly and fills exactly output_capacity.
int dsbot_inflate_raw_deflate(
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity
);

/// CRC-32 as stored in ZIP central-directory records.
uint32_t dsbot_zip_crc32(const uint8_t *input, size_t input_length);

#endif
