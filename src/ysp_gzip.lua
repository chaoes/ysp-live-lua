-- Gzip in-process using libz already required by bundled liblove.
local ffi=require('ffi')
ffi.cdef[[
typedef struct z_stream_s {
  unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
  unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
  char *msg; void *state; void *zalloc; void *zfree; void *opaque;
  int data_type; unsigned long adler; unsigned long reserved;
} z_stream;
const char *zlibVersion(void);
int deflateInit2_(z_stream *, int, int, int, int, int, const char *, int);
int deflate(z_stream *, int);
int deflateEnd(z_stream *);
int inflateInit2_(z_stream *, int, const char *, int);
int inflate(z_stream *, int);
int inflateEnd(z_stream *);
]]
local z=ffi.load('z')
local M={}
local function run(data,decompress)
 local stream=ffi.new('z_stream[1]')
 stream[0].next_in=ffi.cast('unsigned char *',data)
 stream[0].avail_in=#data
 local ver=z.zlibVersion()
 local rc
 if decompress then rc=z.inflateInit2_(stream,31,ver,ffi.sizeof('z_stream'))
 else rc=z.deflateInit2_(stream,-1,8,31,8,0,ver,ffi.sizeof('z_stream')) end
 if rc~=0 then error('zlib init '..rc) end
 local chunks={}
 repeat
  local out=ffi.new('unsigned char[32768]')
  stream[0].next_out=out;stream[0].avail_out=32768
  rc=decompress and z.inflate(stream,0) or z.deflate(stream,4)
  local n=32768-stream[0].avail_out
  if n>0 then chunks[#chunks+1]=ffi.string(out,n) end
  if rc~=0 and rc~=1 then
   if decompress then z.inflateEnd(stream) else z.deflateEnd(stream) end
   error('zlib stream '..rc)
  end
 until rc==1
 if decompress then z.inflateEnd(stream) else z.deflateEnd(stream) end
 return table.concat(chunks)
end
function M.compress(data)return run(data,false)end
function M.decompress(data)return run(data,true)end
return M
