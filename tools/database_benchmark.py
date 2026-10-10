"""Isolated full-INPX database benchmark. Never opens a HomeLib user database.

Preparation writes a portable, deliberately reduced catalogue schema. Engine
timings include all rows/relationships, not COUNT-only substitutes. This is an
engine comparison, not a promise about production importer or VCL rendering.
"""
from __future__ import annotations
import argparse, csv, hashlib, io, json, os, pathlib, platform, statistics
import sqlite3, subprocess, sys, time, zipfile, ctypes, itertools, threading

csv.field_size_limit(16 * 1024 * 1024)
TABLES = {
 'books': [('id','INTEGER'),('title','TEXT'),('search_title','TEXT'),('deleted','INTEGER'),
           ('added','TEXT'),('lang','TEXT'),('size','BIGINT'),('file_ref','TEXT')],
 'authors': [('id','INTEGER'),('name','TEXT')],
 'author_books': [('book_id','INTEGER'),('author_id','INTEGER')],
 'genres': [('book_id','INTEGER'),('genre','TEXT')],
 'series': [('id','INTEGER'),('name','TEXT')],
 'series_books': [('book_id','INTEGER'),('series_id','INTEGER'),('seq','INTEGER')],
}
INDEXES = [
 'CREATE INDEX idx_deleted ON books(deleted,id)',
 'CREATE INDEX idx_added ON books(added,id)',
 'CREATE INDEX idx_author ON author_books(author_id,book_id)',
 'CREATE INDEX idx_author_book ON author_books(book_id,author_id)',
 'CREATE INDEX idx_genre ON genres(genre,book_id)',
 'CREATE INDEX idx_genre_book ON genres(book_id,genre)',
 'CREATE INDEX idx_series ON series_books(series_id,book_id)',
 'CREATE INDEX idx_series_book ON series_books(book_id,series_id)',
]
def log(*args): print(*args, flush=True)
def save(path, value):
 path.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf-8')
def prepare(inpx, out):
 if (out/'dataset.json').exists(): raise RuntimeError('Dataset already exists; use a fresh directory.')
 out.mkdir(parents=True,exist_ok=True)
 t=time.perf_counter(); handles={}; writers={}; counts={k:0 for k in TABLES}
 authors={}; series={}; genre_counts={}; author_counts={}; series_counts={}; ignored=0; deleted=0; maximum={}
 registry=pathlib.Path(__file__).resolve().parents[1]/'Program/Out/Bin64/genres_fb2.glst'
 known=set(); fantasy=set()
 for line in registry.read_text(encoding='utf-8-sig').splitlines():
  code,sep,value=line.partition(' ')
  if sep and ';' in value:
   tag=value.partition(';')[0]; known.add(tag)
   if code.startswith('0.1.'):fantasy.add(tag)
 for k in TABLES:
  handles[k]=(out/(k+'.csv')).open('w',encoding='utf-8',newline='')
  writers[k]=csv.writer(handles[k],lineterminator='\n')
 def row(table, values):
  writers[table].writerow(values); counts[table]+=1
  for (name,typ),val in zip(TABLES[table],values):
   if typ=='TEXT': maximum[table+'.'+name]=max(maximum.get(table+'.'+name,0),len(val))
 try:
  with zipfile.ZipFile(inpx) as z:
   default='AUTHOR;GENRE;TITLE;SERIES;SERNO;FILE;SIZE;LIBID;DEL;EXT;DATE;LANG;LIBRATE;KEYWORDS;INSNO;FOLDER'
   structure=z.read('structure.info').decode('utf-8-sig').strip() if 'structure.info' in z.namelist() else default
   fields=structure.rstrip(';').split(';'); names={name.upper():i for i,name in enumerate(fields)}
   for entry in z.namelist():
    if not entry.lower().endswith('.inp'):continue
    with z.open(entry) as stream:
     for line in io.TextIOWrapper(stream,encoding='utf-8-sig',errors='strict'):
      parts=line.rstrip('\r\n').split('\x04')
      def get(name, default=''):
       index=names.get(name);return parts[index] if index is not None and index<len(parts) else default
      if not get('TITLE'):ignored+=1;continue
      bid=counts['books']+1; title=get('TITLE'); removed=int(get('DEL','0') not in ('','0'));deleted+=removed
      row('books',[bid,title,title.casefold(),removed,get('DATE')[:10],get('LANG'),int(get('SIZE','0') or 0),
          (get('FOLDER') or entry[:-4]+'.zip')+'|'+get('FILE')+'.'+get('EXT')])
      for author in sorted(set(a for a in get('AUTHOR').split(':') if a)):
       if author not in authors:
        authors[author]=len(authors)+1;row('authors',[authors[author],author])
       row('author_books',[bid,authors[author]])
       author_counts[authors[author]]=author_counts.get(authors[author],0)+1
      genres=sorted(set(g for g in get('GENRE').split(':') if g)) or ['unsorted']
      for genre in genres:
       row('genres',[bid,genre]);genre_counts[genre]=genre_counts.get(genre,0)+1
      # A meaningful fallback workload, not a fabricated zero-row query. Source
      # tags remain intact. This auxiliary bucket models tags absent from the
      # bundled registry; native source-genre registration is measured separately.
      if 'unsorted' not in genres and any(g not in known for g in genres):
       row('genres',[bid,'unsorted']);genre_counts['unsorted']=genre_counts.get('unsorted',0)+1
      seq=get('SERIES')
      if seq:
       if seq not in series:series[seq]=len(series)+1;row('series',[series[seq],seq])
       try:number=int(float(get('SERNO','0') or 0))
       except ValueError:number=0
       row('series_books',[bid,series[seq],number])
       series_counts[series[seq]]=series_counts.get(series[seq],0)+1
      if bid%100000==0:log('PREPARE books',bid)
 finally:
  for h in handles.values():h.close()
 metadata={'source':str(inpx.resolve()),'source_sha256':hashlib.file_digest(inpx.open('rb'),'sha256').hexdigest(),
  'rows':counts,'deleted':deleted,'ignored_empty_title':ignored,'prepare_seconds':time.perf_counter()-t,
  'largest_genres':sorted(genre_counts.items(),key=lambda x:-x[1])[:12], 'max_text_lengths':maximum,
  'largest_authors':sorted(author_counts.items(),key=lambda x:-x[1])[:3],
  'largest_series':sorted(series_counts.items(),key=lambda x:-x[1])[:3],
  'fallback_genre_rows':genre_counts.get('unsorted',0),
  'fallback_definition':'At least one raw genre tag absent from bundled genres_fb2.glst; not the native registered-source bucket',
  'fantasy_genres':sorted(fantasy), 'genre_registry_sha256':hashlib.sha256(registry.read_bytes()).hexdigest(),
  'schema':TABLES,'machine':{'platform':platform.platform(),'python':sys.version,'cpu':platform.processor()},
  'files':{k:hashlib.file_digest((out/(k+'.csv')).open('rb'),'sha256').hexdigest() for k in TABLES}}
 save(out/'dataset.json',metadata);log('PREPARED',metadata['rows'],metadata['prepare_seconds'])
def rows(out,table):
 with (out/(table+'.csv')).open(encoding='utf-8',newline='') as f:
  for r in csv.reader(f):yield tuple(int(v) if typ!='TEXT' else v for v,(_,typ) in zip(r,TABLES[table]))
def schema(engine):
 result=[]
 for table, cols in TABLES.items():
  defs=[]
  for name,typ in cols:
   if engine=='firebird' and typ=='TEXT':
    typ='VARCHAR(128)' if name=='genre' else 'VARCHAR(16)' if name in ('lang','added') else 'VARCHAR(4096)'
   defs.append(name+' '+typ+(' PRIMARY KEY' if name=='id' else ' NOT NULL'))
  result.append('CREATE TABLE '+table+'('+','.join(defs)+')')
 return result
def queries(meta):
 genre=next(g for g,c in meta['largest_genres'] if g!='unsorted')
 fantasy=','.join("'"+g.replace("'","''")+"'" for g in meta['fantasy_genres'])
 author=meta['largest_authors'][0][0]; series=meta['largest_series'][0][0]
 return {
  'hide_deleted_all':"SELECT id,title,added,lang,size,file_ref FROM books WHERE deleted=0 ORDER BY id",
  'heavy_genre':"SELECT b.id,b.title,b.added,b.lang,b.size,b.file_ref FROM books b WHERE b.deleted=0 AND b.id IN (SELECT book_id FROM genres WHERE genre='"+genre+"') ORDER BY b.id",
  'fantasy_group':"SELECT b.id,b.title,b.added,b.lang,b.size,b.file_ref FROM books b WHERE b.deleted=0 AND b.id IN (SELECT book_id FROM genres WHERE genre IN ("+fantasy+")) ORDER BY b.id",
  'unsorted':"SELECT b.id,b.title,b.added,b.lang,b.size,b.file_ref FROM books b WHERE b.deleted=0 AND b.id IN (SELECT book_id FROM genres WHERE genre='unsorted') ORDER BY b.id",
  'author':f"SELECT b.id,b.title,b.added,b.lang,b.size,b.file_ref FROM books b WHERE b.id IN (SELECT book_id FROM author_books WHERE author_id={author}) ORDER BY b.id",
  'series':f"SELECT b.id,b.title,b.added,b.lang,b.size,b.file_ref FROM books b WHERE b.id IN (SELECT book_id FROM series_books WHERE series_id={series}) ORDER BY b.id",
  'date':"SELECT id,title,added,lang,size,file_ref FROM books WHERE deleted=0 AND added>='2026-09-01' ORDER BY id",
  'substring':"SELECT id,title,added,lang,size,file_ref FROM books WHERE deleted=0 AND search_title LIKE '%поттер%' ORDER BY id",
  'genre_authors':"SELECT ab.book_id,a.id,a.name FROM author_books ab JOIN authors a ON a.id=ab.author_id WHERE ab.book_id IN (SELECT b.id FROM books b WHERE b.deleted=0 AND b.id IN (SELECT book_id FROM genres WHERE genre='"+genre+"')) ORDER BY ab.book_id,a.id",
  'genre_genres':"SELECT g.book_id,g.genre FROM genres g WHERE g.book_id IN (SELECT b.id FROM books b WHERE b.deleted=0 AND b.id IN (SELECT book_id FROM genres WHERE genre='"+genre+"')) ORDER BY g.book_id,g.genre",
 }
def digest(cursor):
 n=0;h=hashlib.sha256()
 def stream():
  if hasattr(cursor,'fetchmany'):
   while batch:=cursor.fetchmany(4096):yield from batch
  else:yield from cursor
 for r in stream():
  h.update(json.dumps(tuple(r),ensure_ascii=False,separators=(',',':')).encode('utf-8'));h.update(b'\n');n+=1
 return {'rows':n,'sha256':h.hexdigest()}

class DLLCursor:
 def __init__(self, db, stmt, code):self.db=db;self.stmt=stmt;self.code=code
 def __iter__(self):return self
 def __next__(self):
  if self.code==101:self.close();raise StopIteration
  self.db.check(self.code,100)
  result=[]; api=self.db.api
  for i in range(api.sqlite3_column_count(self.stmt)):
   kind=api.sqlite3_column_type(self.stmt,i)
   if kind==1:value=api.sqlite3_column_int64(self.stmt,i)
   elif kind==2:value=api.sqlite3_column_double(self.stmt,i)
   elif kind==5:value=None
   else:value=ctypes.string_at(api.sqlite3_column_text(self.stmt,i),api.sqlite3_column_bytes(self.stmt,i)).decode('utf-8')
   result.append(value)
  self.code=api.sqlite3_step(self.stmt);return tuple(result)
 def fetchone(self):return next(self,None)
 def close(self):
  if self.stmt:self.db.api.sqlite3_finalize(self.stmt);self.stmt=None
  self.code=101
 def __del__(self):self.close()

class SQLiteDLL:
 """Use the actual shipped DLL, not Python's separately linked SQLite."""
 def __init__(self, file, library):
  self.api=ctypes.CDLL(str(library));p=ctypes.c_void_p;i=ctypes.c_int;s=ctypes.c_char_p
  signatures={
   'sqlite3_open':([s,ctypes.POINTER(p)],i),'sqlite3_close':([p],i),
   'sqlite3_prepare_v2':([p,s,i,ctypes.POINTER(p),ctypes.POINTER(s)],i),
   'sqlite3_step':([p],i),'sqlite3_finalize':([p],i),'sqlite3_reset':([p],i),
   'sqlite3_clear_bindings':([p],i),'sqlite3_bind_int64':([p,i,ctypes.c_int64],i),
   'sqlite3_bind_text':([p,i,s,i,p],i),'sqlite3_errmsg':([p],s),
   'sqlite3_column_count':([p],i),'sqlite3_column_type':([p,i],i),
   'sqlite3_column_int64':([p,i],ctypes.c_int64),'sqlite3_column_double':([p,i],ctypes.c_double),
   'sqlite3_column_text':([p,i],p),'sqlite3_column_bytes':([p,i],i),
  }
  for name,(args,result) in signatures.items():
   fn=getattr(self.api,name);fn.argtypes=args;fn.restype=result
  self.handle=p();self.check(self.api.sqlite3_open(str(file).encode('utf-8'),ctypes.byref(self.handle)))
 def check(self,code,expected=0):
  if code!=expected:raise RuntimeError(self.api.sqlite3_errmsg(self.handle).decode('utf-8'))
 def prepare(self,sql):
  stmt=ctypes.c_void_p();self.check(self.api.sqlite3_prepare_v2(self.handle,sql.encode('utf-8'),-1,ctypes.byref(stmt),None));return stmt
 def execute(self,sql):
  stmt=self.prepare(sql)
  try:
   code=self.api.sqlite3_step(stmt)
   if code not in (100,101):self.check(code)
   return DLLCursor(self,stmt,code)
  except:self.api.sqlite3_finalize(stmt);raise
 def executemany(self,sql,data):
  stmt=self.prepare(sql)
  try:
   for row in data:
    for idx,value in enumerate(row,1):
     if isinstance(value,int):self.check(self.api.sqlite3_bind_int64(stmt,idx,value))
     else:self.check(self.api.sqlite3_bind_text(stmt,idx,str(value).encode('utf-8'),-1,ctypes.c_void_p(-1)))
    self.check(self.api.sqlite3_step(stmt),101);self.check(self.api.sqlite3_reset(stmt))
   self.check(self.api.sqlite3_clear_bindings(stmt))
  finally:self.api.sqlite3_finalize(stmt)
 def commit(self):self.execute('COMMIT').close()
 def close(self):
  if self.handle:self.check(self.api.sqlite3_close(self.handle));self.handle=None

def scalar(db,sql):
 cursor=db.execute(sql)
 try:return cursor.fetchone()[0]
 finally:
  if cursor is not db and hasattr(cursor,'close'):cursor.close()

def hidden_run(args, **kwargs):
 return subprocess.run([str(x) for x in args],creationflags=subprocess.CREATE_NO_WINDOW,check=True,**kwargs)

def batches(data,n=2500):
 iterator=iter(data)
 while batch:=list(itertools.islice(iterator,n)):yield batch

def run_engine(engine,out,runtime,library_override=None,result_name=None):
 if not engine:raise RuntimeError('Choose --engine.')
 # Everything writable lives next to the prepared CSVs, never in a user profile.
 meta=json.loads((out/'dataset.json').read_text(encoding='utf-8'))
 for table,expected in meta['files'].items():
  with (out/(table+'.csv')).open('rb') as f:
   if hashlib.file_digest(f,'sha256').hexdigest()!=expected:raise RuntimeError('Dataset changed: '+table)
 if result_name and (pathlib.Path(result_name).name!=result_name or result_name in ('.','..')):raise ValueError('Invalid result directory name')
 folder=out/(result_name or engine)
 if folder.exists():raise RuntimeError('Engine output exists; retain it and choose a fresh dataset/output copy.')
 folder.mkdir();(folder/'benchmark.marker').write_text('HomeLib Ru isolated DB benchmark v1',encoding='utf-8')
 sys.path.insert(0,str(runtime/'python'))
 import psutil
 report={'engine':engine,'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
         'source_sha256':meta['source_sha256'],'schema':TABLES,'queries':{},'row_counts':{},
         'settings':{},'driver_import_seconds':{},'status':'running'}
 db=None;pg=None;server_log=None;monitor_stop=threading.Event();peak=[0]
 def memory():
  while not monitor_stop.wait(.2):
   try:
    root=psutil.Process();processes=[root]+root.children(recursive=True)
    peak[0]=max(peak[0],sum(p.memory_info().rss for p in processes if p.is_running()))
   except psutil.Error:pass
 watcher=threading.Thread(target=memory,daemon=True);watcher.start()
 try:
  if engine in ('sqlite','sqlite-dll','sqlite-fts5'):
   if engine=='sqlite':db=sqlite3.connect(folder/'catalog.db');report['driver']='Python sqlite3'
   else:
    library=library_override or pathlib.Path(__file__).resolve().parents[1]/'Program/Out/Bin64/sqlite3.dll'
    db=SQLiteDLL(folder/'catalog.db',library);report['driver']='Python ctypes / actual HomeLib Ru Win64 DLL'
    with library.open('rb') as f:report['library_sha256']=hashlib.file_digest(f,'sha256').hexdigest()
   report['version']=scalar(db,'SELECT sqlite_version()')
   scalar(db,'PRAGMA journal_mode=WAL');db.execute('PRAGMA synchronous=FULL');db.execute('PRAGMA cache_size=-131072')
   report['settings']={'journal_mode':'WAL','synchronous':'FULL','cache_mib':128}
  elif engine=='duckdb':
   import duckdb
   db=duckdb.connect(str(folder/'catalog.duckdb'));report['version']=duckdb.__version__;report['driver']='duckdb Python / COPY CSV'
   db.execute("SET threads=1");db.execute("SET memory_limit='512MB'")
   report['settings']={'threads':1,'memory_limit_mib':512}
  elif engine=='firebird':
   from firebird.driver import create_database,driver_config
   driver_config.fb_client_library.value=str(runtime/'firebird/fbclient.dll')
   connection=create_database(str(folder/'catalog.fdb'),user='SYSDBA',password='masterkey',charset='UTF8')
   db=connection.cursor();report['version']=connection.info.engine_version;report['driver']='firebird-driver / embedded fbclient'
   report['settings']={'embedded':True,'charset':'UTF8','forced_writes':True}
  elif engine=='postgresql':
   import psycopg
   bindir=runtime/'postgresql/pgsql/bin';cluster=folder/'cluster'
   hidden_run([bindir/'initdb.exe','-D',cluster,'-U','homelib_benchmark','--encoding=UTF8','--locale=C','--auth-local=trust','--auth-host=trust'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   # A separate temporary loopback-only server; no Windows service is installed.
   with (cluster/'postgresql.conf').open('a',encoding='utf-8') as config:
    config.write("\nlisten_addresses='127.0.0.1'\nport=58741\nshared_buffers='128MB'\nmax_parallel_workers_per_gather=0\n")
   server_log=(folder/'server.log').open('wb')
   pg=subprocess.Popen([str(bindir/'postgres.exe'),'-D',str(cluster)],stdout=server_log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
   for attempt in range(100):
    try:connection=psycopg.connect('host=127.0.0.1 port=58741 user=homelib_benchmark dbname=postgres connect_timeout=1');break
    except psycopg.OperationalError:
     if pg.poll() is not None:raise RuntimeError('Isolated PostgreSQL stopped; see server.log')
     time.sleep(.2)
   else:raise RuntimeError('Isolated PostgreSQL did not start.')
   db=connection.cursor();report['version']=scalar(db,'SELECT version()');report['driver']='psycopg / COPY CSV'
   report['settings']={'loopback_only':True,'shared_buffers_mib':128,'query_parallel_workers':0,'fsync':True}
  elif engine=='turso':
   run_turso(out,folder,runtime,meta,report);return
  else:raise RuntimeError('Unknown engine.')
  begin=time.perf_counter()
  for statement in schema(engine):db.execute(statement)
  if engine in ('firebird','postgresql'):connection.commit()
  if engine in ('sqlite-dll','sqlite-fts5','duckdb'):db.execute('BEGIN TRANSACTION')
  for table,columns in TABLES.items():
   start=time.perf_counter();data=out/(table+'.csv')
   if engine=='duckdb':
    db.execute('COPY '+table+" FROM '"+str(data).replace("'","''")+"' (FORMAT CSV, HEADER false, NULL '__homelib_no_null_v1__')")
   elif engine=='postgresql':
    with db.copy('COPY '+table+" FROM STDIN WITH (FORMAT CSV, ENCODING 'UTF8', NULL '__homelib_no_null_v1__')") as copy:
     with data.open('rb') as stream:
      while chunk:=stream.read(1024*1024):copy.write(chunk)
   else:
    sql='INSERT INTO '+table+' VALUES ('+','.join(['?']*len(columns))+')'
    for batch in batches(rows(out,table)):db.executemany(sql,batch)
   report['driver_import_seconds'][table]=time.perf_counter()-start;log(engine,'IMPORTED',table,meta['rows'][table])
  if engine in ('firebird','postgresql'):connection.commit()
  else:db.commit()
  report['import_seconds']=time.perf_counter()-begin
  start=time.perf_counter()
  for statement in INDEXES:db.execute(statement)
  if engine in ('firebird','postgresql'):connection.commit()
  elif engine=='sqlite':db.commit()
  if engine.startswith('sqlite'):db.execute('ANALYZE')
  elif engine=='postgresql':db.execute('ANALYZE');connection.commit()
  elif engine=='duckdb':db.execute('CHECKPOINT')
  report['indexes_seconds']=time.perf_counter()-start
  if engine=='sqlite-fts5':
   start=time.perf_counter();db.execute("CREATE VIRTUAL TABLE books_fts USING fts5(search_title,content='books',content_rowid='id',tokenize='trigram')")
   db.execute("INSERT INTO books_fts(books_fts) VALUES ('rebuild')")
   report['fts_build_seconds']=time.perf_counter()-start
  for table,expected in meta['rows'].items():
   actual=scalar(db,'SELECT COUNT(*) FROM '+table);report['row_counts'][table]=actual
   if actual!=expected:raise RuntimeError('Incomplete import: '+table)
  sqls=queries(meta)
  if engine=='sqlite-fts5':sqls['substring']=sqls['substring'].replace("search_title LIKE '%поттер%'","id IN (SELECT rowid FROM books_fts WHERE search_title LIKE '%поттер%')")
  report['query_sql']=sqls
  for name,sql in sqls.items():
   measurements=[];expected=None
   for repeat in range(3):
    start=time.perf_counter();cursor=db.execute(sql);ready=time.perf_counter()-start
    value=digest(cursor);elapsed=time.perf_counter()-start
    if hasattr(cursor,'close') and engine!='duckdb' and engine not in ('firebird','postgresql'):cursor.close()
    if expected is None:expected=value
    elif expected!=value:raise RuntimeError('Unstable rows: '+name)
    measurements.append({'execute_seconds':ready,'all_rows_with_hash_seconds':elapsed})
   report['queries'][name]={**expected,'runs':measurements,'median_seconds':statistics.median(m['all_rows_with_hash_seconds'] for m in measurements)}
   log(engine,'QUERY',name,expected['rows'],report['queries'][name]['median_seconds']);save(folder/'result.json',report)
  if engine.startswith('sqlite'):report['integrity']=scalar(db,'PRAGMA integrity_check')
  else:report['integrity']='row counts and stable hashes verified; no equivalent cross-engine integrity pragma'
  report['status']='pass'
 except Exception as error:
  report['status']='failed';report['error']=repr(error);raise
 finally:
  if db is not None:
   if engine in ('firebird','postgresql'):db.close();connection.close()
   else:db.close()
  if pg is not None:
   hidden_run([runtime/'postgresql/pgsql/bin/pg_ctl.exe','-D',folder/'cluster','stop','-m','fast','-w'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   pg.wait(timeout=30)
  if server_log:server_log.close()
  monitor_stop.set();watcher.join(timeout=2);report['peak_process_tree_rss_bytes']=peak[0]
  report['disk_bytes']=sum(p.stat().st_size for p in folder.rglob('*') if p.is_file())
  save(folder/'result.json',report);log(engine,report['status'])

def run_turso(out,folder,runtime,meta,report):
 """The Windows CLI is separately timed; no unsupported Python wheel is used."""
 tool=runtime/'turso/tursodb.exe';database=folder/'catalog.db'
 report['version']=hidden_run([tool,'--version'],capture_output=True,text=True).stdout.strip()
 statements=schema('turso')+['BEGIN TRANSACTION;']
 for table in TABLES:statements.append('.import --csv "'+str(out/(table+'.csv')).replace('\\','/')+'" '+table)
 statements+=['COMMIT;']+INDEXES+['.quit']
 script='\n'.join(s if s.startswith('.') else s.rstrip(';')+';' for s in statements)+'\n'
 (folder/'import.sql').write_text(script,encoding='utf-8')
 start=time.perf_counter()
 process=hidden_run([tool,database],input=script,text=True,encoding='utf-8',capture_output=True,timeout=1800)
 (folder/'import.log').write_text(process.stdout+process.stderr,encoding='utf-8')
 report['import_and_indexes_seconds']=time.perf_counter()-start
 # Any parser/engine error is recorded, rather than being passed as a fast import.
 if 'error' in (process.stdout+process.stderr).lower():raise RuntimeError('Turso import reported an error; see import.log')
 def cli(sql):
  value=hidden_run([tool,database],input='.mode list\n.headers off\n'+sql.rstrip(';')+';\n.quit\n',
                   text=True,encoding='utf-8',capture_output=True,timeout=1800)
  if value.stderr.strip():raise RuntimeError('Turso query error: '+value.stderr)
  return [line for line in value.stdout.splitlines() if line!='Exiting Turso SQL Shell.']
 report['driver']='official Windows CLI; process startup, text output and parsing included'
 report['settings']={'portable_cli':True,'default_durability':True}
 for table,expected in meta['rows'].items():
  actual=int(cli('SELECT COUNT(*) FROM '+table)[0]);report['row_counts'][table]=actual
  if actual!=expected:raise RuntimeError('Incomplete Turso import: '+table)
 report['query_sql']=queries(meta)
 for name,sql in report['query_sql'].items():
  columns=[('book_id',False),('id',False),('name',True)] if name=='genre_authors' else \
          [('book_id',False),('genre',True)] if name=='genre_genres' else \
          [('id',False),('title',True),('added',True),('lang',True),('size',False),('file_ref',True)]
  # Hex preserves empty strings, separators, line breaks and all Unicode. No
  # COUNT-only surrogate is used for the large result workloads.
  expression="||'|'||".join('hex('+c+')' if text else 'CAST('+c+' AS TEXT)' for c,text in columns)
  wrapped='SELECT '+expression+' FROM ('+sql+') AS q'
  measurements=[];expected=None
  for repeat in range(3):
   start=time.perf_counter();lines=cli(wrapped)
   converted=(tuple(bytes.fromhex(v).decode('utf-8') if kind else int(v)
                   for v,(_,kind) in zip(line.split('|'),columns)) for line in lines)
   value=digest(converted);elapsed=time.perf_counter()-start
   if expected is None:expected=value
   elif expected!=value:raise RuntimeError('Unstable Turso rows: '+name)
   measurements.append({'all_rows_with_hash_seconds':elapsed,'includes_cli_startup':True})
  report['queries'][name]={**expected,'runs':measurements,'median_seconds':statistics.median(m['all_rows_with_hash_seconds'] for m in measurements)}
  log('turso','QUERY',name,expected['rows'],report['queries'][name]['median_seconds']);save(folder/'result.json',report)
 report['status']='pass';report['integrity']='all table counts and repeated full-row hashes verified'

def main():
 p=argparse.ArgumentParser();p.add_argument('operation',choices=['prepare','run']);p.add_argument('--inpx',type=pathlib.Path)
 p.add_argument('--out',type=pathlib.Path,required=True);p.add_argument('--runtime',type=pathlib.Path)
 p.add_argument('--library',type=pathlib.Path);p.add_argument('--result-name')
 p.add_argument('--engine',choices=['sqlite','sqlite-dll','sqlite-fts5','duckdb','firebird','postgresql','turso']);args=p.parse_args()
 args.out=args.out.resolve()
 if args.operation=='prepare':prepare(args.inpx,args.out)
 else:run_engine(args.engine,args.out,args.runtime.resolve(),args.library.resolve() if args.library else None,args.result_name)
if __name__=='__main__':main()
