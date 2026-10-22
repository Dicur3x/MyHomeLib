/* GPL-3.0-only. Bounded C ABI adapted from calibre's LZX memory-file glue.
 * calibre lzxmodule.c: Marshall T. Vandegrift, 2008. See ../SOURCE.json.
 * Decoder: libmspack LGPL-2.1; DES: Richard Outerbridge, public domain.
 * No Python C API, disk access, process creation or network access.
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "mspack.h"
#include "lzxd.h"
#include "d3des.h"
#define LIMIT (64 * 1024 * 1024)
#define EXPORT __declspec(dllexport)

typedef struct { unsigned char *buffer; int length, position; } memory_file;
static void *mem_alloc(struct mspack_system *system, size_t bytes) {
    if (bytes > LIMIT) return NULL;
    return malloc(bytes);
}
static void mem_free(void *pointer) { free(pointer); }
static void mem_copy(void *source, void *target, size_t bytes) { memcpy(target, source, bytes); }
static int mem_read(struct mspack_file *file, void *buffer, int bytes) {
    memory_file *memory = (memory_file *)file;
    if (bytes < 0 || memory->position > memory->length) return -1;
    if (bytes > memory->length - memory->position) bytes = memory->length - memory->position;
    memcpy(buffer, memory->buffer + memory->position, bytes);
    memory->position += bytes;
    return bytes;
}
static int mem_write(struct mspack_file *file, void *buffer, int bytes) {
    memory_file *memory = (memory_file *)file;
    if (bytes < 0 || bytes > memory->length - memory->position) return -1;
    memcpy(memory->buffer + memory->position, buffer, bytes);
    memory->position += bytes;
    return bytes;
}
static struct mspack_system memory_system = {
    NULL, NULL, mem_read, mem_write, NULL, NULL, NULL, mem_alloc, mem_free, mem_copy, NULL
};

EXPORT int hl_lzx(void *input, int input_size, void *output, int output_size, int window) {
    struct lzxd_stream *stream;
    memory_file source, target;
    int error;
    if (!input || !output || input_size <= 0 || input_size > LIMIT ||
        output_size <= 0 || output_size > LIMIT || window < 15 || window > 21) return -10;
    source.buffer = input; source.length = input_size; source.position = 0;
    target.buffer = output; target.length = output_size; target.position = 0;
    stream = lzxd_init(&memory_system, (struct mspack_file *)&source,
        (struct mspack_file *)&target, window, 0x7fff, 4096, output_size);
    if (!stream) return -11;
    error = lzxd_decompress(stream, output_size);
    lzxd_free(stream);
    if (!error && target.position != output_size) return -12;
    return error;
}

EXPORT int hl_des(void *key, void *input, void *output, int length, int mode) {
    int at;
    if (!key || !input || !output || length < 0 || length > LIMIT ||
        length % 8 || (mode != 0 && mode != 1)) return -10;
    deskey((unsigned char *)key, (short)mode);
    for (at = 0; at < length; at += 8)
        des((unsigned char *)input + at, (unsigned char *)output + at);
    return 0;
}

/* PC1 format decoding, adapted from DeDRM's GPLv3 Pukall_Cipher.
 * Copyright 2008 The Dark Reverser, 2008-2020 Apprentice Harper et al.
 * Only container-supplied/default keys are used by the read-only adapter.
 */
EXPORT int hl_pc1(void *key, void *input, void *output, int length, int decrypt) {
    unsigned int words[8], sum1=0, sum2=0, temporary, byte_xor, key_xor, current;
    unsigned char *source=input, *target=output, *bytes=key;
    int at, j;
    if (!key || !input || !output || length<0 || length>LIMIT || (decrypt!=0 && decrypt!=1)) return -10;
    for (j=0;j<8;j++) words[j]=((unsigned int)bytes[j*2]<<8)|bytes[j*2+1];
    for (at=0;at<length;at++) {
        temporary=0;byte_xor=0;
        for (j=0;j<8;j++) {
            temporary^=words[j];
            sum2=(sum2+j)*20021+sum1;
            sum1=(temporary*346)&0xffff;
            sum2=(sum2+sum1)&0xffff;
            temporary=(temporary*20021+1)&0xffff;
            byte_xor^=temporary^sum2;
        }
        current=source[at];key_xor=current*257;
        current=(current^(byte_xor>>8)^byte_xor)&0xff;
        if (decrypt) key_xor=current*257;
        for (j=0;j<8;j++) words[j]^=key_xor;
        target[at]=(unsigned char)current;
    }
    return 0;
}
