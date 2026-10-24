-- bkliveinfo cKey generation, adapted for LuaJIT from funwukong/ysp-live.
local bit=require('bit')
local M={}
local function u16(n)n=n%65536;return string.char(math.floor(n/256),n%256)end
local function u32(n)n=n%4294967296;return u16(math.floor(n/65536))..u16(n%65536)end
local function r32(s,p)local a,b,c,d=s:byte(p,p+3);return ((a*256+b)*256+c)*256+d end
local function rand(n)
 local f=assert(io.open('/dev/urandom','rb'));local s=f:read(n);f:close();return s
end
local function hex(s)return (s:gsub('.',function(c)return string.format('%02x',c:byte())end))end
local function xor_bytes(a,b)
 local out={};for i=1,#a do out[i]=string.char(bit.bxor(a:byte(i),b:byte((i-1)%#b+1)))end
 return table.concat(out)
end
local function tea_block(block,key)
 local y,z=r32(block,1),r32(block,5)
 local k={r32(key,1),r32(key,5),r32(key,9),r32(key,13)}
 local sum=0
 for _=1,16 do
  sum=(sum+0x9e3779b9)%4294967296
  local a=bit.bxor((bit.lshift(z,4)+k[1])%4294967296,(z+sum)%4294967296,(bit.rshift(z,5)+k[2])%4294967296)
  y=(y+a)%4294967296
  local b=bit.bxor((bit.lshift(y,4)+k[3])%4294967296,(y+sum)%4294967296,(bit.rshift(y,5)+k[4])%4294967296)
  z=(z+b)%4294967296
 end
 return u32(y)..u32(z)
end
local function cksum(buf)
 local v=0;for i=1,#buf do v=(131*v+buf:byte(i))%2147483648 end;return v
end
local function tea_packet(data,key)
 local pad=(8-((#data+10)%8))%8
 local plain=string.char(bit.band(rand(1):byte(),248)+pad)..rand(pad)..rand(2)..data..string.rep('\0',7)
 local out,pp,pc={},string.rep('\0',8),string.rep('\0',8)
 for off=1,#plain,8 do
  local mixed=xor_bytes(plain:sub(off,off+7),pc)
  local enc=tea_block(mixed,key)
  local cipher=xor_bytes(enc,pp)
  out[#out+1]=cipher;pp=mixed;pc=cipher
 end
 return table.concat(out)
end
local function lp(s)s=tostring(s);return u16(#s)..s end
local function guard(ts,guid)
 local function tail(v)local s=tostring(v);return #s>=5 and s:sub(-5) or '' end
 local body=u32(ts)..lp(tail(guid))..lp(tail('null'))..lp(tail('null'))..lp('-1')
 local plain=lp(body)
 local key=('110DBEC10C23E7D2E56A1CAD6914EF1B'):gsub('..',function(h)return string.char(tonumber(h,16))end)
 local enc=tea_packet(plain,key)..u32(cksum(plain))
 local gx=('b3c953a06913ad4d'):gsub('..',function(h)return string.char(tonumber(h,16))end)
 return hex(xor_bytes(enc,gx)):upper()
end
local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64(s)
 local out={}
 for i=1,#s,3 do
  local a,b,c=s:byte(i,i+2);b=b or 0;c=c or 0
  local n=a*65536+b*256+c
  out[#out+1]=alphabet:sub(math.floor(n/262144)%64+1,math.floor(n/262144)%64+1)
  out[#out+1]=alphabet:sub(math.floor(n/4096)%64+1,math.floor(n/4096)%64+1)
  if i+1<=#s then out[#out+1]=alphabet:sub(math.floor(n/64)%64+1,math.floor(n/64)%64+1)end
  if i+2<=#s then out[#out+1]=alphabet:sub(n%64+1,n%64+1)end
 end
 return table.concat(out)
end
local function urlenc(s)return (tostring(s):gsub('([^%w%-_%.~])',function(c)return string.format('%%%02X',c:byte())end))end
local function make_query(fields)
 local out={};for _,kv in ipairs(fields) do out[#out+1]=urlenc(kv[1])..'='..urlenc(kv[2]) end
 return table.concat(out,'&')
end
function M.query(channel_id,live_pid,defn)
 local platform=4330403
 local ts=os.time()
 local guid=hex(rand(16))
 local g=guard(ts,guid)
 local uid=hex(rand(4)):upper()
 local body=string.char(0,0,0,66,0,0,0,4,0,0,4,210)..u32(platform)..u32(0)..u32(ts)
  ..lp('dcgh')..lp('_zj1A5Gh6QYcxWjIUGos2w==')..lp('V8.22.1035.3031')..lp(channel_id)
  ..lp(guid)..u32(1)..u32(1)..lp(uid)..lp('nil')
  ..lp('57eab0c4-2c58-44c6-8ae9-dd2757525dc5')..lp('nil')..lp('v0.1.000')
  ..lp('com.cctv.yangshipin.app.iphone')..lp(platform)..lp('ex_json_bus')..lp('ex_json_vs')..lp(g)
 local pkt=u16(#body)..body
 pkt=pkt:sub(1,18)..u32(cksum(pkt))..pkt:sub(23)
 local key=('59b2f7cf725ef43c34fdd7c123411ed3'):gsub('..',function(h)return string.char(tonumber(h,16))end)
 local xor=('842eed08f066e6ea48b4caa991ed6ff3'):gsub('..',function(h)return string.char(tonumber(h,16))end)
 local enc=xor_bytes(tea_packet(pkt,key)..u32(cksum(pkt)),xor)
 local ckey='--01'..b64(enc):gsub('%+','_'):gsub('/','-')
 local flow=hex(rand(16)):upper()..'_'..platform
 local height=defn=='fhd' and 1080 or (defn=='hd' and 540 or 720)
 local h264=b64(string.format('H(30:%d,60:%d|30:%d,60:%d)',height,height,height,height))
 return make_query({
  {'atime','120'},{'livepid',live_pid},{'cnlid',channel_id},{'appVer','V8.22.1035.3031'},
  {'app_version','300090'},{'caplv','1'},{'cmd','2'},{'defn',defn or 'fhd'},
  {'device','iPhone'},{'encryptVer','4.2'},{'getpreviewinfo','0'},{'hevclv','0'},
  {'lang','zh-Hans_CN'},{'livequeue','0'},{'logintype','1'},{'nettype','1'},
  {'newnettype','1'},{'newplatform',platform},{'platform',platform},
  {'sdtfrom','v3021'},{'spacode','23'},{'spaudio','1'},{'spdemuxer','6'},
  {'spdrm','2'},{'spdynamicrange','1'},{'spflv','1'},{'spflvaudio','1'},
  {'sphdrfps','60'},{'sphttps','1'},{'spvcode',h264},{'spvideo','4'},
  {'stream','1'},{'system','1'},{'sysver','ios18.2.1'},{'uhd_flag','0'},
  {'cKey',ckey},{'guid',guid},{'fntick',ts},{'flowid',flow},{'playbacktime','0'},
 })
end
return M
