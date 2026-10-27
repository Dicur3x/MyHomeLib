"""Reproduce public IBK interoperability tables without running vendor code.

The input is the original published runtime binary, read only as bytes. This
builder never reads registration files, profiles, books, or private keys.
"""
import argparse
import array
from fractions import Fraction
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys


def rounded(value):
    if not value: return Fraction(0)
    sign = -1 if value < 0 else 1
    value = abs(value)
    numerator, denominator = value.numerator, value.denominator
    exponent = numerator.bit_length() - denominator.bit_length()
    below = numerator < denominator << exponent if exponent >= 0 else numerator << -exponent < denominator
    if below: exponent -= 1
    shift = 63 - exponent
    a, b = (numerator << shift, denominator) if shift >= 0 else (numerator, denominator << -shift)
    result, remainder = divmod(a, b)
    if 2 * remainder > b or (2 * remainder == b and result & 1): result += 1
    return sign * (Fraction(result, 1 << shift) if shift >= 0 else Fraction(result << -shift))


def extended(raw):
    mantissa = int.from_bytes(raw[:8], 'little')
    flags = int.from_bytes(raw[8:], 'little')
    exponent = (flags & 32767) - 16383 - 63
    value = Fraction(mantissa << exponent) if exponent >= 0 else Fraction(mantissa, 1 << -exponent)
    return -value if flags & 32768 else value


def sequence(seed):
    current = extended(bytes.fromhex(seed))
    divisor = extended(bytes.fromhex('f2d24d62105839b4f83f'))
    delta = extended(bytes.fromhex('fdce61841177ccabe43f'))
    for _ in range(65535):
        while True:
            current = rounded(rounded(current / divisor) + divisor)
            current = rounded(current - current.numerator // current.denominator)
            divisor = rounded(divisor + delta)
            if current >= Fraction(1, 2): break
        yield rounded(rounded(current * 2) - 1)


def table(values):
    forward = array.array('H', ((index + 1) & 65535 for index in range(65536)))
    inverse = array.array('H', ((index - 1) & 65535 for index in range(65536)))
    for index, value in enumerate(values):
        other = index + int(float(value * (65536 - index)))
        next_a, prev_a, next_b, prev_b = forward[index], inverse[index], forward[other], inverse[other]
        if other == next_a:
            inverse[index], forward[index] = other, next_b
            inverse[next_b] = index
            inverse[other], forward[other] = prev_a, index
            forward[prev_a] = other
        elif other == prev_a:
            inverse[index], forward[index] = prev_b, other
            forward[prev_b] = index
            inverse[other], forward[other] = index, next_a
            inverse[next_a] = other
        else:
            forward[index], inverse[index] = next_b, prev_b
            inverse[next_b], forward[prev_b] = index, index
            forward[other], inverse[other] = next_a, prev_a
            inverse[next_a], forward[prev_a] = other, other
    if not all(inverse[forward[index]] == index for index in range(65536)):
        raise ValueError('invalid generated permutation')
    return forward, inverse


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--output', type=Path)
    options = parser.parse_args()
    root = Path(__file__).resolve().parent
    parameters = json.loads((root / 'ibk_parameters.json').read_text(encoding='utf-8'))
    runtime = options.runtime.read_bytes()
    if len(runtime) != parameters['table_generation_reference_bytes'] or hashlib.sha256(runtime).hexdigest() != parameters['table_generation_reference_sha256']:
        raise ValueError('The runtime does not match the supported published build.')
    spec = importlib.util.spec_from_file_location('ibk_table_primitives', root / 'ibk_crypto.py')
    crypto = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(crypto)
    core, _ = table(sequence('71d2c976c4086192fe3f'))
    checksum, _ = table(sequence('c9485122c78831e7fc3f'))
    brand = b'ICE Book Reader Professional\0'
    words = crypto.transform((brand * (262144 // len(brand) + 1))[:262144], core)
    _, directory_inverse = table(Fraction(value, 1 << 32) for (value,) in struct.iter_unpack('<I', words[:-4]))
    fingerprint = crypto.checksum(runtime, core, 262144)
    _, runtime_inverse = table(Fraction(value, 1 << 32) for (value,) in struct.iter_unpack('<I', fingerprint[:-4]))
    result = bytearray(b'MHLIBK1\0')
    for values in (core, directory_inverse, checksum, runtime_inverse):
        packed = array.array('H', values)
        if sys.byteorder != 'little': packed.byteswap()
        result.extend(packed.tobytes())
    digest = hashlib.sha256(result).hexdigest()
    if digest != parameters['tables_sha256']:
        raise ValueError('The independently generated format tables do not match the verified vectors.')
    if options.check:
        if bytes(result) != (root / 'ibk_tables.bin').read_bytes():
            raise ValueError('The stored tables differ from the generated tables.')
    elif options.output:
        with options.output.open('xb') as handle: handle.write(result)
    else:
        parser.error('Choose --check or a new --output path.')
    print(json.dumps({'bytes': len(result), 'sha256': digest, 'vendor_code_executed': False, 'registration_files_read': False}))


if __name__ == '__main__':
    main()
