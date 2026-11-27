"""JPEG scan recovery and lossless TIFF/JPEG strip joining, MIT.

Only baseline, interleaved, identical-table strips without restart markers are
joined. Other TIFF layouts use the Windows image decoder. JPEG recovery checks
the entropy stream and retains verified data without recompressing it.
"""
from pathlib import Path
import re
import struct
from typing import NamedTuple


class Unsupported(Exception):
    pass


class _RecoveryInterrupted(Exception):
    pass


def jpeg_parts(data):
    if not data.startswith(b'\xff\xd8') or not data.endswith(b'\xff\xd9'):
        raise ValueError('Неполный JPEG внутри TIFF.')
    at=2; parts=[]
    while at<len(data)-2:
        if data[at]!=255:raise ValueError('Неверный маркер JPEG внутри TIFF.')
        while at<len(data) and data[at]==255:at+=1
        if at+3>len(data):raise ValueError('Обрезанный заголовок JPEG внутри TIFF.')
        marker=data[at];size=int.from_bytes(data[at+1:at+3],'big');at+=1
        if size<2 or at+size>len(data)-2:raise ValueError('Обрезанный сегмент JPEG внутри TIFF.')
        segment=b'\xff'+bytes([marker])+data[at:at+size];at+=size
        parts.append((marker,segment))
        if marker==0xda:
            scan=data[at:-2];pos=0
            while True:
                pos=scan.find(b'\xff',pos)
                if pos<0:break
                if pos+1>=len(scan):raise ValueError('Обрезанные данные JPEG внутри TIFF.')
                if scan[pos+1]!=0:raise Unsupported()
                pos+=2
            return parts,scan
        if marker not in {0xc0,0xc4,0xdb,0xdd,0xfe,*range(0xe0,0xf0)}:raise Unsupported()
    return parts,None


class JpegRecovery(NamedTuple):
    data: bytes
    rows: int
    original_rows: int
    preview_scans: int = 0


def _huffman_tables(segments):
    tables = {}
    for segment in segments:
        offset = 4
        while offset < len(segment):
            selector = segment[offset]
            counts = segment[offset+1:offset+17]
            offset += 17
            total = sum(counts)
            if selector not in (*range(4), *range(16, 20)) or not 1 <= total <= 256 or offset + total > len(segment):
                raise ValueError('Invalid JPEG Huffman table')
            code, symbols = 0, {}
            for width, count in enumerate(counts, 1):
                if count and code + count >= 1 << width:
                    raise ValueError('Invalid JPEG Huffman code')
                for value in segment[offset:offset+count]:
                    symbols[(1 << width) | code] = value
                    code += 1
                offset += count
                code <<= 1
            tables[selector] = symbols
    return tables


class _JpegScan:
    def __init__(self, data):
        self.data = data.replace(b'\xff\x00', b'\xff')
        self.position = 0

    def skip(self, count):
        self.position += count
        if self.position > len(self.data)*8:
            raise EOFError

    def bits(self, count):
        value = 0
        for _ in range(count):
            at, bit = divmod(self.position, 8)
            self.skip(1)
            value = value*2 + ((self.data[at] >> (7-bit)) & 1)
        return value

    def symbol(self, table):
        code = 1
        for _ in range(16):
            at, bit = divmod(self.position, 8)
            self.skip(1)
            code = code*2 + ((self.data[at] >> (7-bit)) & 1)
            if code in table:
                return table[code]
        raise ValueError('Invalid JPEG Huffman symbol')

    def block(self, dc, ac):
        magnitude = self.symbol(dc)
        if magnitude > 11:
            raise ValueError('Invalid JPEG DC magnitude')
        self.skip(magnitude)
        coefficient = 1
        while coefficient < 64:
            symbol = self.symbol(ac)
            if symbol == 0:
                return
            if symbol == 0xf0:
                coefficient += 16
            else:
                count = symbol & 15
                if not 1 <= count <= 10:
                    raise ValueError('Invalid JPEG AC magnitude')
                coefficient += (symbol >> 4) + 1
                self.skip(count)
            if coefficient > 64:
                raise ValueError('Invalid JPEG coefficient run')

    def has_only_padding(self):
        remaining = len(self.data)*8 - self.position
        return remaining == 0 or (0 < remaining < 8 and
               self.data[-1] & ((1 << remaining)-1) == (1 << remaining)-1)

    def prefix(self, position):
        size, remainder = divmod(position, 8)
        data = self.data[:size]
        if remainder:
            padding = (1 << (8-remainder))-1
            data += bytes([self.data[size] | padding])
        return data.replace(b'\xff', b'\xff\x00')


def _baseline_blocks(parts):
    frames = [segment for marker,segment in parts if marker == 0xc0]
    if len(frames) != 1:
        return None
    frame = frames[0]
    height, width, channels = struct.unpack_from('>HHB', frame, 5)
    if (frame[4] != 8 or not 0 < width*height <= 64_000_000 or channels not in (1,3) or
            len(frame) != 10+3*channels):
        return None
    sos = parts[-1][1]
    if len(sos) != 8+2*channels or sos[4] != channels or sos[-3:] != b'\x00\x3f\x00':
        return None
    quantizers = {}
    for marker, segment in parts:
        if marker == 0xdb:
            for offset in range(4,len(segment),65):
                selector = segment[offset]
                quantizer = segment[offset+1:offset+65]
                if selector > 3 or len(quantizer) != 64 or 0 in quantizer:
                    return None
                quantizers[selector] = quantizer
    components = {}
    for identity, sampling, quantizer in zip(frame[10::3],frame[11::3],frame[12::3]):
        horizontal, vertical = sampling >> 4, sampling & 15
        if (identity in components or quantizer not in quantizers or
                not 1 <= horizontal <= 4 or not 1 <= vertical <= 4):
            return None
        components[identity] = (horizontal, vertical)
    if set(sos[5:-3:2]) != components.keys():
        return None
    tables = _huffman_tables(segment for marker,segment in parts if marker == 0xc4)
    blocks = []
    for identity, table in zip(sos[5:-3:2],sos[6:-3:2]):
        horizontal, vertical = components[identity]
        blocks.extend([(tables[table >> 4], tables[16 + (table & 15)])]
                      * (horizontal*vertical if channels > 1 else 1))
    if len(blocks) > 10:
        return None
    mcu_width = 8 * max(h for h,_ in components.values()) if channels > 1 else 8
    mcu_height = 8 * max(v for _,v in components.values()) if channels > 1 else 8
    columns = (width + mcu_width-1)//mcu_width
    return height, mcu_height, columns, blocks


def _cropped_header(parts, rows):
    return b'\xff\xd8' + b''.join(
        segment[:5] + rows.to_bytes(2,'big') + segment[7:] if marker == 0xc0 else segment
        for marker, segment in parts)


def recover_baseline_jpeg(data, check=None):
    """Verify complete MCU rows before closing a baseline JPEG scan (ITU-T T.81, Annex F)."""
    if not data.startswith(b'\xff\xd8\xff') or data.endswith(b'\xff\xd9'):
        return None
    candidate = data + (b'\xd9' if data.endswith(b'\xff') else b'\xff\xd9')
    try:
        parts, scan_data = jpeg_parts(candidate)
        if scan_data is None or any(marker == 0xdd for marker,_ in parts):
            return None
    except (Unsupported, ValueError, IndexError, KeyError, struct.error):
        return None
    return _verify_baseline_prefix(parts, scan_data, candidate, check)


def _verify_baseline_prefix(parts, scan_data, candidate, check):
    try:
        parameters = _baseline_blocks(parts)
        if parameters is None:
            return None
        height, mcu_height, columns, blocks = parameters
    except (ValueError, IndexError, KeyError, struct.error):
        return None
    scan = _JpegScan(scan_data)
    complete_rows, last_complete = 0, 0
    while complete_rows < height:
        if check is not None:
            check()
        try:
            for _ in range(columns):
                for dc, ac in blocks:
                    scan.block(dc, ac)
        except (EOFError, ValueError):
            if not complete_rows:
                return None
            return JpegRecovery(_cropped_header(parts, complete_rows) + scan.prefix(last_complete) + b'\xff\xd9',
                                complete_rows, height)
        complete_rows += mcu_height
        last_complete = scan.position
    if scan.has_only_padding():
        if candidate is None:
            candidate = _cropped_header(parts, height) + scan.prefix(last_complete) + b'\xff\xd9'
        return JpegRecovery(candidate, height, height)


_RECOVERY_MARKERS = {0xc0, 0xc2, 0xc4, 0xdb, 0xdd, 0xda, 0xfe, *range(0xe0, 0xf0)}
_ENTROPY_MARKER = re.compile(rb'(?<!\xff)\xff++([^\x00\xff])')
_RESERVED_MARKER = re.compile(rb'\xff++[\x02-\xbf]')


def _recovery_scans(data):
    """Separate complete header segments, restart intervals and scan boundaries."""
    parts = []
    offset = 2
    while offset + 3 < len(data) and len(parts) < 4096:
        if data[offset] != 255:
            return
        while offset + 1 < len(data) and data[offset+1] == 255:
            offset += 1
        if offset+4 > len(data):
            return
        marker = data[offset+1]
        length = int.from_bytes(data[offset+2:offset+4], 'big')
        end = offset + 2 + length
        if marker not in _RECOVERY_MARKERS or length < 2 or end > len(data):
            return
        parts.append((marker, data[offset:end]))
        offset = end
        if marker != 0xda:
            continue
        intervals = []
        for found in _ENTROPY_MARKER.finditer(data, offset):
            following = found[1][0]
            if not 0xd0 <= following <= 0xd7:
                intervals.append((data[offset:found.start()], None))
                offset = found.start()
                yield parts[:], intervals, offset, following in _RECOVERY_MARKERS | {0xd9}
                break
            intervals.append((data[offset:found.start()], following))
            if len(intervals) > 262144:
                return
            offset = found.end()
        else:
            # An unfinished FF escape is not evidence of another entropy byte.
            entropy = data[offset:].rstrip(b'\xff')
            intervals.append((entropy, None))
            yield parts[:], intervals, offset + len(entropy), False
            return


def has_reserved_baseline_scan_marker(data):
    first_scan = next(_recovery_scans(data), None)
    if first_scan is None:
        return False
    parts, _, end, valid_boundary = first_scan
    return (not valid_boundary and any(marker == 0xc0 for marker, _ in parts)
            and _RESERVED_MARKER.match(data, end) is not None)


def _recover_restart_scan(parts, intervals, check):
    dri = [segment for marker, segment in parts if marker == 0xdd]
    parameters = _baseline_blocks(parts)
    if parameters is None or len(dri) != 1 or len(dri[0]) != 6:
        return None
    restart = int.from_bytes(dri[0][4:], 'big')
    if not restart:
        return None
    height, mcu_height, columns, blocks = parameters
    total = columns * ((height + mcu_height - 1)//mcu_height)
    validated = []
    cut = None
    done = 0
    for index, (entropy, marker) in enumerate(intervals):
        count = min(restart, total-done)
        if count <= 0 or marker is not None and (count != restart or marker != 0xd0 + index%8):
            break
        if marker is None:
            # Padding from a damaged file must not decode as extra MCU rows.
            entropy = entropy.rstrip(b'\x00')
        scan = _JpegScan(entropy)
        row = row_end = finished = 0
        try:
            for relative in range(1, count+1):
                if check is not None and (relative-1)%columns == 0:
                    check()
                for dc, ac in blocks:
                    scan.block(dc, ac)
                finished = relative
                if (done+relative)%columns == 0:
                    row, row_end = (done+relative)//columns, scan.position
        except EOFError:
            pass
        except ValueError:
            if marker is not None:
                break
        if marker is not None and (finished != count or not scan.has_only_padding()):
            break
        if row and (row*mcu_height < height or finished == count and scan.has_only_padding()):
            cut = min(row*mcu_height, height), len(validated), scan.prefix(row_end)
        if marker is None:
            break
        validated.append(entropy + bytes((255, marker)))
        done += count
    if cut is not None:
        rows, committed, final_chunk = cut
        return JpegRecovery(_cropped_header(parts, rows) + b''.join(validated[:committed]) + final_chunk + b'\xff\xd9',
                            rows, height)


def _progressive_frame(parts):
    frames = [segment for marker, segment in parts if marker == 0xc2]
    if len(frames) != 1:
        raise ValueError('Invalid progressive JPEG frame')
    frame = frames[0]
    height, width, channels = struct.unpack_from('>HHB', frame, 5)
    if frame[4] != 8 or not 0 < width*height <= 64_000_000 or channels not in (1,3) or len(frame) != 10+3*channels:
        raise ValueError('Unsupported progressive JPEG dimensions')
    sampling = {identity: (factor >> 4, factor & 15) for identity, factor in zip(frame[10::3],frame[11::3])}
    if (len(sampling) != channels or any(not 1 <= scale <= 4 for sizes in sampling.values() for scale in sizes) or
            sum(x*y for x,y in sampling.values()) > 10):
        raise ValueError('Invalid progressive JPEG sampling')
    return height, width, sampling


def _verify_progressive_scan(parts, entropy, height, width, sampling, levels, check):
    sos = parts[-1][1]
    channels = sos[4]
    first, last, change = sos[-3:]
    if not 1 <= channels <= len(sampling) or len(sos) != 8+2*channels or change > 13:
        raise ValueError('Unsupported progressive JPEG scan')
    if not (first == last == 0 or channels == 1 and 1 <= first <= last < 64):
        raise ValueError('Invalid progressive JPEG scan range')
    ids = sos[5:-3:2]
    if len(set(ids)) != channels or any(levels[identity][i] is not None for identity in ids for i in range(first,last+1)):
        raise ValueError('Unsupported progressive JPEG refinement')
    if first and levels[ids[0]][0] is None:
        raise ValueError('Progressive JPEG has no base scan')
    tables = _huffman_tables(segment for marker, segment in parts if marker == 0xc4)
    high_x, high_y = (8*max(size[i] for size in sampling.values()) for i in range(2))
    stride_x, stride_y = sampling[ids[0]] if channels == 1 else (1,1)
    columns = (width*stride_x + high_x-1)//high_x
    rows = (height*stride_y + high_y-1)//high_y
    scan = _JpegScan(entropy)
    if first == 0:
        dc_tables = []
        for identity, selector in zip(ids, sos[6:-3:2]):
            x, y = sampling[identity]
            dc_tables.extend([tables[selector >> 4]] * (x*y if channels > 1 else 1))
        for _ in range(rows):
            if check is not None:
                check()
            for _ in range(columns):
                for table in dc_tables:
                    count = scan.symbol(table)
                    if count > 11:
                        raise ValueError('Invalid progressive JPEG DC magnitude')
                    scan.skip(count)
    else:
        table = tables[16+(sos[6]&15)]
        remaining = 0
        for position in range(rows*columns):
            if check is not None and position%columns == 0:
                check()
            if remaining:
                remaining -= 1
                continue
            coefficient = first
            while coefficient <= last:
                symbol = scan.symbol(table)
                run, bits = symbol >> 4, symbol & 15
                if not bits and run < 15:
                    remaining = (1 << run) + scan.bits(run) - 1
                    break
                if not bits:
                    coefficient += 16
                    if coefficient > last+1:
                        raise ValueError('Invalid progressive JPEG zero run')
                    continue
                coefficient += run
                if coefficient > last or bits > 10:
                    raise ValueError('Invalid progressive JPEG coefficient')
                scan.skip(bits)
                coefficient += 1
        if remaining:
            raise ValueError('Progressive JPEG run exceeds image')
    if not scan.has_only_padding():
        raise ValueError('Incomplete progressive JPEG scan')
    for identity in ids:
        levels[identity][first:last+1] = [change]*(last-first+1)


def recover_jpeg(data, check=None):
    """Keep verified image rows or complete initial scans from a truncated JPEG."""
    result = recover_baseline_jpeg(data, check)
    if result is not None or not data.startswith(b'\xff\xd8\xff'):
        return result
    has_end_marker = data.endswith(b'\xff\xd9')

    def checkpoint():
        if check is not None:
            try:
                check()
            except Exception as error:
                raise _RecoveryInterrupted() from error

    levels = None
    scans = 0
    for parts, intervals, end, valid_boundary in _recovery_scans(data):
        try:
            if levels is None:
                if any(marker == 0xc0 for marker, _ in parts):
                    if not valid_boundary and len(intervals) == 1 and not any(marker == 0xdd for marker, _ in parts):
                        return _verify_baseline_prefix(parts, intervals[0][0], None, checkpoint)
                    if has_end_marker and valid_boundary:
                        return None
                    return _recover_restart_scan(parts, intervals, checkpoint)
                if has_end_marker:
                    return None
                height, width, sampling = _progressive_frame(parts)
                levels = {identity: [None]*64 for identity in sampling}
            if len(intervals) != 1 or any(marker == 0xdd for marker, _ in parts):
                break
            _verify_progressive_scan(parts, intervals[0][0], height, width, sampling, levels, checkpoint)
        except _RecoveryInterrupted as error:
            raise error.__cause__
        except (EOFError, ValueError, IndexError, KeyError, struct.error):
            break
        scans += 1
        if all(component[0] is not None for component in levels.values()):
            complete = all(level == 0 for component in levels.values() for level in component)
            result = JpegRecovery(data[:end] + b'\xff\xd9', height, height, 0 if complete else scans)
    return result


def plans(data):
    if len(data)<8 or data[:4] not in (b'II*\0',b'MM\0*'):return None
    endian='<' if data[:2]==b'II' else '>'
    def values(kind,count,value):
        size={1:1,3:2,4:4,7:1}.get(kind)
        if size is None:raise Unsupported()
        length=size*count
        if count>1000000:raise ValueError('Слишком большая таблица TIFF.')
        at=value if length>4 else None
        raw=data[at:at+length] if at is not None else struct.pack(endian+'I',value)[:length]
        if len(raw)!=length:raise ValueError('Обрезанная таблица TIFF.')
        if kind in {1,7}:return raw
        return struct.unpack(endian+str(count)+('H' if kind==3 else 'I'),raw)
    def field(tags,key,default=None):
        if key not in tags:
            if default is None:raise Unsupported()
            return default
        result=values(*tags[key])
        if len(result)!=1:raise Unsupported()
        return result[0]
    offset=struct.unpack_from(endian+'I',data,4)[0];seen=set();result=[]
    try:
        while offset:
            if offset<8 or offset+2>len(data) or offset in seen or len(seen)>=5000:
                raise ValueError('Повреждена цепочка страниц TIFF.')
            seen.add(offset);count=struct.unpack_from(endian+'H',data,offset)[0]
            end=offset+2+12*count
            if end+4>len(data):raise ValueError('Обрезана таблица страницы TIFF.')
            tags={}
            for at in range(offset+2,end,12):
                tag,kind,n,value=struct.unpack_from(endian+'HHII',data,at)
                if tag in tags:raise ValueError('Повторный тег страницы TIFF.')
                tags[tag]=(kind,n,value)
            offset=struct.unpack_from(endian+'I',data,end)[0]
            if field(tags,259,1)!=7:raise Unsupported()
            width,height=field(tags,256),field(tags,257)
            if not 0<width<=16384 or not 0<height<=16384 or width*height>16777216:
                raise ValueError('Размер страницы TIFF превышает предел чтения.')
            if field(tags,284,1)!=1 or field(tags,274,1)!=1 or 34675 in tags:raise Unsupported()
            components=field(tags,277,1);photo=field(tags,262)
            if (components,photo) not in {(1,1),(3,6)} or field(tags,531,1)!=1:raise Unsupported()
            if 258 not in tags or tuple(values(*tags[258]))!=(8,)*components:raise Unsupported()
            if 273 not in tags or 279 not in tags:raise Unsupported()
            rows=field(tags,278);offsets=values(*tags[273]);sizes=values(*tags[279])
            if rows<=0 or len(offsets)!=len(sizes) or len(offsets)!=(height+rows-1)//rows:raise Unsupported()
            shared=[]
            if 347 in tags:
                shared,scan=jpeg_parts(bytes(values(*tags[347])))
                if scan is not None or any(m not in {0xdb,0xc4} for m,_ in shared):raise Unsupported()
            table_bytes=b''.join(segment for _,segment in shared)
            template=None;scan_header=None;local_tables=None;scans=[];restart=0
            for index,(start,size) in enumerate(zip(offsets,sizes)):
                if start<8 or size<4 or start+size>len(data):raise ValueError('Обрезана полоса JPEG в TIFF.')
                parts,scan=jpeg_parts(data[start:start+size])
                if scan is None:raise ValueError('В полосе TIFF нет данных JPEG.')
                frames=[segment for m,segment in parts if m==0xc0]
                sos=[segment for m,segment in parts if m==0xda]
                if len(frames)!=1 or len(sos)!=1 or any(m==0xdd for m,_ in parts):raise Unsupported()
                frame=bytearray(frames[0]);channels=frame[9] if len(frame)>=10 else 0
                if len(frame)!=10+3*channels or frame[4]!=8 or channels!=components:raise Unsupported()
                h,w=struct.unpack_from('>HH',frame,5)
                if w!=width or h<min(rows,height-index*rows) or h>rows:raise Unsupported()
                sampling=[frame[11+3*c] for c in range(channels)]
                if any(not 1<=v>>4<=4 or not 1<=v&15<=4 for v in sampling):raise Unsupported()
                mcu_h=8*max(v&15 for v in sampling);mcu_w=8*max(v>>4 for v in sampling)
                if len(offsets)>1 and rows%mcu_h:raise Unsupported()
                interval=((width+mcu_w-1)//mcu_w)*(rows//mcu_h)
                if len(offsets)>1 and not 1<=interval<=65535:raise Unsupported()
                frame[5:7]=height.to_bytes(2,'big')
                tables=b''.join(segment for m,segment in parts if m in {0xdb,0xc4})
                header=sos[0]
                if len(header)!=8+2*channels or header[4]!=channels or header[-3:]!=b'\x00\x3f\x00':raise Unsupported()
                if template is None:
                    template=bytes(frame);scan_header=header;local_tables=tables;restart=interval
                elif bytes(frame)!=template or header!=scan_header or tables!=local_tables:raise Unsupported()
                # Store offsets, not copies of every compressed strip.
                scans.append((start+size-2-len(scan),len(scan)))
            complete_tables=table_bytes+local_tables
            if not any(m==0xdb for m,_ in shared) and not b'\xff\xdb' in local_tables:raise Unsupported()
            if not any(m==0xc4 for m,_ in shared) and not b'\xff\xc4' in local_tables:raise Unsupported()
            dri=b'\xff\xdd\x00\x04'+restart.to_bytes(2,'big') if len(scans)>1 else b''
            result.append((b'\xff\xd8'+complete_tables+template+dri+scan_header,scans))
        if not result:raise ValueError('В TIFF нет страниц.')
        return result
    except Unsupported:
        return None


def pages(source, maximum):
    data=Path(source).read_bytes();layout=plans(data)
    if layout is None:return None
    def generate():
        total=0
        for prefix,scans in layout:
            parts=[prefix]
            for index,(at,size) in enumerate(scans):
                if index:parts.append(b'\xff'+bytes([0xd0+(index-1)%8]))
                parts.append(data[at:at+size])
            parts.append(b'\xff\xd9');image=b''.join(parts);total+=len(image)
            if len(image)>16*1024*1024 or total>maximum:raise ValueError('Страницы TIFF превышают предел чтения.')
            yield image
    return len(layout),generate()


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 4 or sys.argv[1] != 'recover':
        sys.exit(2)
    source, destination = map(Path, sys.argv[2:])
    if not 0 < source.stat().st_size <= 16*1024*1024:
        sys.exit(2)
    recovery = recover_jpeg(source.read_bytes())
    if recovery is None:
        sys.exit(1)
    with destination.open('xb') as output:
        output.write(recovery.data)
    print(recovery.rows, recovery.original_rows, recovery.preview_scans)
