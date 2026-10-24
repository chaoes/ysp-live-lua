-- JCE PidTimeShift wire format, adapted for LuaJIT from funwukong/ysp-live.
local M = {}
local function u16(n) n=n%65536; return string.char(math.floor(n/256),n%256) end
local function u32(n) n=n%4294967296; return u16(math.floor(n/65536))..u16(n%65536) end
local function u64(n) return u32(math.floor(n/4294967296))..u32(n%4294967296) end
local function read_u32(s,p) local a,b,c,d=s:byte(p,p+3); if not d then error('short u32') end; return ((a*256+b)*256+c)*256+d end
local zlib=require('src.ysp_gzip')
local function gzip(data,decompress)
    return decompress and zlib.decompress(data) or zlib.compress(data)
end
M.gzip = gzip

local W={}; W.__index=W
function W.new() return setmetatable({b={}},W) end
function W:add(s) self.b[#self.b+1]=s end
function W:head(t,tag)
    if tag<15 then self:add(string.char(tag*16+t)) else self:add(string.char(240+t,tag)) end
end
function W:byte(v,tag)
    if v==0 then self:head(12,tag) else self:head(0,tag); self:add(string.char(v%256)) end
end
function W:short(v,tag)
    if v>=-128 and v<=127 then self:byte(v,tag) else self:head(1,tag);self:add(u16(v)) end
end
function W:int(v,tag)
    if v>=-32768 and v<=32767 then self:short(v,tag) else self:head(2,tag);self:add(u32(v)) end
end
function W:long(v,tag)
    if v>=-2147483648 and v<=2147483647 then self:int(v,tag) else self:head(3,tag);self:add(u64(v)) end
end
function W:string(s,tag)
    if s==nil then return end
    s=tostring(s)
    if #s>255 then self:head(7,tag);self:add(u32(#s)) else self:head(6,tag);self:add(string.char(#s)) end
    self:add(s)
end
function W:bytes(s,tag) self:head(13,tag);self:head(0,0);self:int(#s,0);self:add(s) end
function W:struct(fn,tag) self:head(10,tag);fn(self);self:head(11,0) end
function W:list_empty(tag) self:head(9,tag);self:int(0,0) end
function W:out() return table.concat(self.b) end

local R={};R.__index=R
function R.new(s) return setmetatable({s=s,p=1},R) end
function R:get(n) if self.p+n-1>#self.s then error('short JCE') end;local s=self.s:sub(self.p,self.p+n-1);self.p=self.p+n;return s end
function R:u8() return self:get(1):byte() end
function R:head() local b=self:u8();local t=b%16;local tag=math.floor(b/16);if tag==15 then tag=self:u8() end;return t,tag end
function R:field() local t=self:head();return self:value(t) end
function R:number(n,signed)
    local v=0;for i=1,n do v=v*256+self:u8() end
    if signed and v>=2^(8*n-1) then v=v-2^(8*n) end
    return v
end
function R:value(t)
    if t==0 then return self:number(1,true) end
    if t==1 then return self:number(2,true) end
    if t==2 then return self:number(4,true) end
    if t==3 then return self:number(8,true) end
    if t==4 then self:get(4);return 0 end
    if t==5 then self:get(8);return 0 end
    if t==6 then return self:get(self:u8()) end
    if t==7 then return self:get(self:number(4)) end
    if t==8 then local n=self:field();local m={};for _=1,n do local k=self:field();m[k]=self:field() end;return m end
    if t==9 then local n=self:field();local a={};for i=1,n do a[i]=self:field() end;return a end
    if t==10 then return self:struct() end
    if t==11 then return nil end
    if t==12 then return 0 end
    if t==13 then self:head();return self:get(self:field()) end
    error('JCE type '..t)
end
function R:struct()
    local m={}
    while self.p<=#self.s do
        local t,tag=self:head()
        if t==11 then break end
        m[tag]=self:value(t)
    end
    return m
end

local guid = nil
local function get_guid()
    if guid then return guid end
    local f=io.open('/dev/urandom','rb')
    local seed=f and f:read(16) or nil
    if f then f:close() end
    if seed and #seed==16 then guid=(seed:gsub('.',function(c)return string.format('%02x',c:byte())end))
    else math.randomseed(os.time());guid=string.format('%032x',math.random(1,2^30)) end
    return guid
end
local function qua(w)
    local g=get_guid()
    w:string('3.2.7.26212',0);w:string('302070',1)
    w:int(1080,2);w:int(2400,3);w:int(3,4);w:string('12',5)
    w:int(1,6);w:int(1,7);w:int(420,8);w:string('10070',9)
    for i=10,14 do w:string('',i) end
    w:struct(function(x)x:int(0,0);x:byte(0,1);x:string('',2)end,15)
    w:string('',16);w:string('',17);w:string('',18)
    w:struct(function(x)x:int(0,0);x:head(4,1);x:add(string.rep('\0',4));x:head(4,2);x:add(string.rep('\0',4));x:head(5,3);x:add(string.rep('\0',8))end,19)
    w:string(g:sub(1,16),20);w:string('Pixel 6',21)
    w:int(1,22)
    for i=23,26 do w:int(0,i) end
    w:string('',27);w:string('',28);w:string(g,29)
end
local function wrap(body,reqid)
    local cmd=25312
    local w=W.new()
    w:struct(function(x)
        x:int(reqid,0);x:int(cmd,1);x:struct(qua,2)
        x:string('1200013',3);x:string(get_guid(),4)
        x:list_empty(5);x:struct(function()end,6);x:list_empty(7)
        x:int(0,8);x:int(0,9);x:int(0,10)
    end,0)
    w:bytes(body,1)
    local reqcmd=w:out()
    local inner=string.char(38)..u32(#reqcmd+17)..string.char(1)..string.rep('\0',10)..reqcmd..string.char(40)
    local packet=string.char(19)..u32(0)..u16(2)..u16(65281)..u16(cmd)..u16(0)..u64(reqid)
        ..u32(531)..u32(10012)..u64(0)..get_guid()..string.char(1)..u32(302070)
        ..string.rep('\0',6)..string.char(0)..u16(0)..u16(0)..u32(#inner)..gzip(inner,false)..string.char(3)
    return packet:sub(1,1)..u32(#packet)..packet:sub(6)
end
function M.request(pid,sid,start_ts,end_ts,stream)
    local w=W.new()
    w:string(pid,0);w:string(sid,1);w:long(start_ts,2);w:long(end_ts,3);w:string(stream or 'fhd',4)
    return wrap(w:out(),math.floor(os.time()*1000)%2147483648)
end
function M.response(data)
    if not data or data:byte(1)~=19 or #data<90 then return nil,'bad response' end
    local flags=read_u32(data,22)
    local payload=data:sub(90,-2)
    if flags%4>=2 then payload=gzip(payload,true) end
    if payload:sub(1,1)~='&' or payload:sub(-1)~='(' then return nil,'bad payload' end
    local rc=R.new(payload:sub(17,-2)):struct()
    local body=rc[1]
    if not body or body=='' then return nil,'empty body' end
    local m=R.new(body):struct()
    if m[0] and m[0]~=0 then return nil,tostring(m[1] or m[0]) end
    local url=m[2]
    if not url or url=='' then return nil,'empty m3u8' end
    if url:find('liverecord.video.cloud.cctv.com',1,true) then return nil,'dead host' end
    return url
end
return M
