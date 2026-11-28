#include "ISHRawDeflate.h"

#include <limits.h>
#include <zlib.h>

int dsbot_inflate_raw_deflate(
    const uint8_t *input,
    size_t input_length,
    uint8_t *output,
    size_t output_capacity
) {
    if (input_length > UINT_MAX || output_capacity > UINT_MAX) return Z_MEM_ERROR;
    if ((input_length != 0 && input == NULL) || (output_capacity != 0 && output == NULL)) {
        return Z_STREAM_ERROR;
    }

    z_stream stream = {0};
    int status = inflateInit2(&stream, -MAX_WBITS);
    if (status != Z_OK) return status;

    uint8_t empty_output = 0;
    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_length;
    stream.next_out = output_capacity ? output : &empty_output;
    stream.avail_out = (uInt)(output_capacity ? output_capacity : 1);

    status = inflate(&stream, Z_FINISH);
    size_t output_length = stream.total_out;
    uInt remaining_input = stream.avail_in;
    int end_status = inflateEnd(&stream);
    if (status != Z_STREAM_END) return status == Z_OK ? Z_BUF_ERROR : status;
    if (end_status != Z_OK) return end_status;
    if (output_length != output_capacity || remaining_input != 0) return Z_DATA_ERROR;
    return Z_OK;
}

uint32_t dsbot_zip_crc32(const uint8_t *input, size_t input_length) {
    uLong checksum = crc32(0L, Z_NULL, 0);
    while (input_length > 0) {
        uInt chunk = input_length > UINT_MAX ? UINT_MAX : (uInt)input_length;
        checksum = crc32(checksum, input, chunk);
        input += chunk;
        input_length -= chunk;
    }
    return (uint32_t)checksum;
}
