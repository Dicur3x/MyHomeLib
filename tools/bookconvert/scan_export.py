"""Bounded scan export: choose once, split before resizing, encode small batches (MIT)."""
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import zlib


def excluded_pages(value):
    import re
    if len(value)>256: raise ValueError('Слишком длинный список исключений сканов.')
    if not value.strip(): return set()
    result=set()
    for part in value.split(','):
        if not re.fullmatch(r'\s*\d{1,4}\s*(?:-\s*\d{1,4}\s*)?',part): raise ValueError('Неверные номера сканов.')
        numbers=[int(n) for n in part.split('-')]; first=numbers[0]; last=numbers[-1]
        if not 1<=first<=last<=5000: raise ValueError('Номера сканов должны быть от 1 до 5000.')
        result.update(range(first,last+1))
    return result


class ScanExport:
    def __init__(self, book, context):
        self.book, self.context = book, context
        spec = importlib.util.spec_from_file_location('homelib_scan_quality', Path(__file__).with_name('image_quality.py'))
        self.codec = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.codec)
        self.pending = []; self.done = 0; self.total = 0; self.chosen = False
        self.unsplit = set()
        self.profile = context['profile']; self.layout = context.get('layout', 'keep')
        try: self.excluded=excluded_pages(context.get('exclude',''))
        except ValueError as error: book.fail(str(error))
        self.tool = book.c.image_processor_path(book.tools_root)
        if not self.tool.is_file(): book.require('ImageProcessing', 'Для обработки сканов нужен модуль HomeLibre Images.')
        context['handled'] = True

    def add(self, data, number, total):
        section = self.book.el('section', id='page-'+str(number)); self.book.body.append(section)
        section.append(self.book.el('h2', 'Страница '+str(number)))
        self.pending.append((data, section, number)); self.total = max(self.total, total or number)
        # The first sample and each later batch fit within a small memory budget.
        maximum = 9 if not self.chosen else 12
        if len(self.pending) >= maximum or sum(len(item[0]) for item in self.pending) >= 32*1024*1024:
            self.flush()

    def choose(self, directory, complete):
        pictures = [item[0] for item in self.pending]
        if self.profile != 'ask':
            self.chosen = True; return None
        if not self.context.get('options') or not self.context.get('choice'):
            self.book.fail('Не указан канал выбора качества.')
        kept = self.codec.run(self.book.c,self.tool,pictures,directory,'estimate',self.book.progress,'keep')
        # The decoder has validated these PNGs. Portrait/square pages cannot
        # split in either mode, and PNG has no JPEG EXIF orientation here.
        # Reuse their exact results rather than encoding every profile thrice.
        unchanged = all(data.startswith(b'\x89PNG\r\n\x1a\n') and len(data)>=24 and
                        int.from_bytes(data[16:20],'big') <= int.from_bytes(data[20:24],'big')*1.10
                        for data in pictures)
        estimates = {'keep': kept}
        for layout in ('split','auto'):
            estimates[layout] = kept if unchanged else self.codec.run(
                self.book.c,self.tool,pictures,directory,'estimate',self.book.progress,layout)
        total = len(pictures) if complete else max(len(pictures),self.total)
        target = self.context['target']
        def size(pages):
            return sum(4*((len(data)+2)//3) if target=='.fb2' else len(zlib.compress(data)) for data in pages)
        sizes = {layout: {p: max(1,4096+round(sum(size(pages) for pages in encoded[p])*total/len(pictures))+total*160)
                          for p in self.codec.SCAN_PROFILES} for layout,encoded in estimates.items()}
        for values in sizes.values(): values['none'] = 0  # Page pictures contain the book itself.
        zip_sizes = {layout: {p: max(1,512+4096+round(sum(
            sum(self.codec.deflated_size(base64.b64encode(data)) if target=='.fb2'
                else len(zlib.compress(data)) for data in pages)
            for pages in encoded[p])*total/len(pictures))+total*160)
            for p in self.codec.SCAN_PROFILES} for layout,encoded in estimates.items()}
        for values in zip_sizes.values(): values['none'] = 0
        options, choice = Path(self.context['options']), Path(self.context['choice'])
        if options.exists() or choice.exists(): self.book.fail('Канал выбора качества уже занят.')
        payload = {'format':target[1:].upper(),'images':total,'sampled':len(pictures),
                   'sizes':sizes['keep'],'split_sizes':sizes['split'],'auto_sizes':sizes['auto'],
                   'zip_sizes':zip_sizes['keep'],'zip_split_sizes':zip_sizes['split'],'zip_auto_sizes':zip_sizes['auto'],
                   'scan_pages':True,'first_samples':True}
        staging = options.with_suffix('.new'); staging.write_text(json.dumps(payload,ensure_ascii=False),encoding='utf-8'); staging.rename(options)
        started=time.monotonic()
        while not choice.is_file():
            if time.monotonic()-started>21600: self.book.fail('Выбор качества не завершён. Экспорт отменён.')
            time.sleep(.1)
        if choice.stat().st_size>4096: self.book.fail('Некорректный выбор обработки сканов.')
        value=choice.read_text(encoding='utf-8-sig').strip()
        if value=='cancel': self.book.fail('Экспорт отменён.')
        parts=value.split('|')
        if len(parts)>3 or parts[0] not in self.codec.SCAN_PROFILES or (len(parts)>=2 and parts[1] not in ('split','auto')) or (len(parts)==3 and not parts[2].startswith('except=')):
            self.book.fail('Некорректный выбор обработки сканов.')
        self.profile=parts[0]; self.layout=parts[1] if len(parts)>=2 else 'keep'; self.chosen=True
        try: self.excluded=excluded_pages(parts[2][7:] if len(parts)==3 else '')
        except ValueError as error: self.book.fail(str(error))
        if self.layout=='auto':
            self.unsplit.update(self.pending[i][2] for i in estimates['auto']['_unsplit'] if self.pending[i][2] not in self.excluded)
        return [estimates['keep' if number in self.excluded else self.layout][self.profile][i]
                for i,(_data,_section,number) in enumerate(self.pending)]

    def flush(self, complete=False):
        if not self.pending: return
        with tempfile.TemporaryDirectory(prefix='homelib-scan-batch-',dir=self.book.work_root) as temporary:
            directory=Path(temporary); encoded=None
            if not self.chosen: encoded=self.choose(directory,complete)
            if encoded is None:
                encoded=[None]*len(self.pending)
                for layout in ('keep','split','auto'):
                    indices=[i for i,(_,_,number) in enumerate(self.pending) if ('keep' if number in self.excluded else self.layout)==layout]
                    if not indices: continue
                    result=self.codec.run(self.book.c,self.tool,[self.pending[i][0] for i in indices],directory,
                                          self.profile,lambda *_: None,layout)
                    self.unsplit.update(self.pending[indices[i]][2] for i in result['_unsplit'])
                    for i,pages in zip(indices,result[self.profile]): encoded[i]=pages
            for (_data,section,number),pages in zip(self.pending,encoded):
                for half,data in enumerate(pages):
                    paragraph=self.book.el('p'); section.append(paragraph)
                    image=self.book.image(data)
                    image.set('alt','Страница '+str(number)+(' · '+('левая' if half==0 else 'правая') if len(pages)==2 else ''))
                    paragraph.append(image)
            self.done+=len(self.pending); self.pending.clear()
            self.book.progress('scan-images',self.done,max(self.done,self.total))

    def finish(self):
        self.flush(True)
        self.book.warnings.add('Сканы обработаны небольшими порциями: '+{'original':'исходное разрешение изображений','high':'высокое качество','balanced':'сбалансированный режим','economy':'экономный режим'}[self.profile]+'. Исходная книга сохранена.')
        if self.layout=='split':
            self.book.warnings.add('Горизонтальные сканы разворотов разделены по центру: сначала левая, затем правая страница. Вертикальные страницы сохранены целиком.')
        elif self.layout=='auto':
            self.book.warnings.add('Автоматическое разделение: граница ищется отдельно на каждом развороте по сгибу или свободному промежутку между страницами; порядок — слева направо. Вертикальные страницы сохранены целиком.')
            if self.unsplit:
                self.book.warnings.add('Не найдена уверенная граница разворота: '+str(len(self.unsplit))+' сканов сохранены целиком (№ '+', '.join(map(str,sorted(self.unsplit)[:20]))+('…' if len(self.unsplit)>20 else '')+'). Можно выбрать разделение по центру.')
