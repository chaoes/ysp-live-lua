-- Loopback-only HLS manifest service. Video segments go directly to CCTV CDN.
-- Protocol behavior adapted from funwukong/ysp-live (commit 1530741).
package.path = './?.lua;./?/init.lua;' .. package.path
local json=require('src.json')
local jce=require('src.ysp_jce')
local ckey=require('src.ysp_ckey')
local rows=require('src.ysp_channels')
local M={}
local channels={}
-- YSP's shd stream is 1280x720; the RG CubeXX does not benefit from fhd's 1080p decode cost.
local default_defn=os.getenv('YSP_SOURCE_QUALITY') or 'shd'
if default_defn~='shd' and default_defn~='fhd' and default_defn~='hd' then default_defn='shd' end
local first='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
local force_bk={cctv11=true,cctv12=true,cctv14=true,cctv15=true,cctv16=true,cctv164k=true,cctv17=true,cctv4k=true,cctvfyjc=true,cctvdyjc=true,cctvhjjc=true}
local function quote(s)return "'"..tostring(s):gsub("'",[['"'"']]).."'"end
local function fetch(url, opts)
 opts=opts or {}
 local output=os.tmpname()
 local input=nil
 local args={'curl','-fsSL','--compressed','--connect-timeout','5','--max-time','20'}
 local function add(...)for i=1,select('#',...)do args[#args+1]=quote(select(i,...))end end
 add('-A',opts.ua or first)
 if opts.referer then add('-e',opts.referer) end
 if opts.accept then add('-H','Accept: '..opts.accept) end
 if opts.data then
  input=os.tmpname();local f=assert(io.open(input,'wb'));f:write(opts.data);f:close()
  add('-H','Content-Type: application/octet-stream','--data-binary','@'..input)
 end
 add('-o',output,'-w','%{url_effective}',url)
 local p=io.popen(table.concat(args,' ')..' 2>/dev/null')
 local final=p and p:read('*a') or ''
 local ok=p and p:close()
 if input then os.remove(input) end
 local f=io.open(output,'rb')
 local body=f and f:read('*a') or nil
 if f then f:close() end
 os.remove(output)
 if not ok or not body or #body==0 then return nil,'network request failed' end
 return body,nil,final
end
local function absolute(base,url)
 if url:match('^%a[%w+%.%-]*://') then return url end
 local scheme,host=base:match('^(https?)://([^/]+)')
 if not scheme then return url end
 if url:sub(1,2)=='//' then return scheme..':'..url end
 if url:sub(1,1)=='/' then return scheme..'://'..host..url end
 local path=base:match('^https?://[^/]+([^?#]*)') or '/'
 local dir=path:match('^(.*)/') or ''
 return scheme..'://'..host..dir..'/'..url
end
local function url_key(url,pdt)
 if pdt~='' then return 'pdt:'..pdt end
 return (url:match('^([^?]+)') or url)
end
local function parse_segments(text,base)
 local segs,duration,pdt={},6,''
 for raw in text:gmatch('[^\r\n]+') do
  local line=raw:gsub('^%s+',''):gsub('%s+$','')
  if line:find('^#EXTINF:') then duration=tonumber(line:match('^#EXTINF:([%d%.]+)')) or 6
  elseif line:find('^#EXT%-X%-PROGRAM%-DATE%-TIME:') then pdt=line:match('^#EXT%-X%-PROGRAM%-DATE%-TIME:(.*)') or ''
  elseif line~='' and line:sub(1,1)~='#' then segs[#segs+1]={duration,pdt,absolute(base,line)};pdt='' end
 end
 return segs
end
local function fetch_abs_playlist(url,depth)
 depth=depth or 0
 local text,err,final=fetch(url,{ua='qqlive',referer='https://live.cctv.cn/',accept='application/vnd.apple.mpegurl,application/json,*/*'})
 if not text then return nil,err end
 if depth<2 and text:find('#EXT%-X%-STREAM%-INF') then
  local after=false
  for line in text:gmatch('[^\r\n]+') do
   local s=line:gsub('^%s+',''):gsub('%s+$','')
   if after and s~='' and s:sub(1,1)~='#' then return fetch_abs_playlist(absolute(final,s),depth+1) end
   if s:find('^#EXT%-X%-STREAM%-INF') then after=true end
  end
 end
 local lines={}
 for line in text:gmatch('[^\r\n]+') do
  local s=line:gsub('^%s+',''):gsub('%s+$','')
  lines[#lines+1]=(s~='' and s:sub(1,1)~='#') and absolute(final,s) or line
 end
 return table.concat(lines,'\n')..'\n'
end
local function jce_refresh(ch)
 local now=os.time()
 local packet=jce.request(ch.pid,ch.sid,now-300,now,ch.defn)
 local raw,err=fetch('https://jacc.ysp.cctv.cn',{data=packet})
 if not raw then return nil,err end
 local url;url,err=jce.response(raw)
 if not url then return nil,err end
 local text; text,err=fetch(url)
 if not text then return nil,err end
 local segs=parse_segments(text,url)
 if #segs==0 then return nil,'empty playlist' end
 local added=0
 for _,item in ipairs(segs) do
  local key=url_key(item[3],item[2])
  local old=ch.segments[key]
  if old then old[4]=item[3]
  else
   ch.seq=ch.seq+1
   ch.segments[key]={ch.seq,item[1],item[2],item[3]}
   ch.order[#ch.order+1]=key
   added=added+1
  end
 end
 while #ch.order>60 do ch.segments[table.remove(ch.order,1)]=nil end
 return true
end
local function bk_urls(ch)
 local q=ckey.query(ch.sid,ch.pid,ch.defn)
 local body,err=fetch('https://bkliveinfo.ysp.cctv.cn/?'..q,{ua='qqlive',accept='application/json'})
 if not body then return nil,err end
 local ok,data=pcall(json.decode,body)
 if not ok or type(data)~='table' then return nil,'invalid bk response' end
 if tonumber(data.iretcode)~=0 then return nil,'bk error '..tostring(data.iretcode) end
 local urls,seen={},{}
 local function add(url)
  if type(url)=='string' and url:find('.cctv.',1,true) and not seen[url] then urls[#urls+1]=url;seen[url]=true end
 end
 add(data.playurl)
 local backups=data.backurl_list or data.backurlList or data.backurl
 if type(backups)=='table' then
  for _,item in ipairs(backups) do if type(item)=='table' then add(item.url or item.playurl) else add(item) end end
 elseif type(backups)=='string' then for u in backups:gmatch('[^;,]+') do add(u) end end
 table.sort(urls,function(a,b)
  local ap=a:find('bklive%-') and 0 or 1
  local bp=b:find('bklive%-') and 0 or 1
  if ap~=bp then return ap<bp end
  return a<b
 end)
 if #urls==0 then return nil,'no bk URL' end
 return urls
end
local function bk_refresh(ch)
 if os.time()-ch.bk_urls_time>600 or #ch.bk_urls==0 then
  local urls,err=bk_urls(ch)
  if not urls then return nil,err end
  ch.bk_urls=urls;ch.bk_urls_time=os.time()
 end
 local last='bk playlist failed'
 for _,url in ipairs(ch.bk_urls) do
  local body,err=fetch_abs_playlist(url)
  if body and body:find('#EXTM3U',1,true) then ch.bk_playlist=body;return true end
  last=err or last
 end
 ch.bk_urls_time=0
 return nil,last
end
local function refresh(ch)
 local ok,err
 if ch.mode=='bk' then ok,err=bk_refresh(ch)
 else
  ok,err=jce_refresh(ch)
  if not ok and (err=='dead host' or ch.failures>=2) then
   ch.mode='bk';ok,err=bk_refresh(ch)
  end
 end
 ch.last_fetch=os.time()
 if ok then ch.failures=0;ch.last_error='';return true end
 ch.failures=ch.failures+1;ch.last_error=tostring(err or 'unknown')
 return false
end
local function build(ch)
 if ch.mode=='bk' then return ch.bk_playlist end
 local count=#ch.order
 if count==0 then return nil end
 local start=math.max(1,count-29)
 local firstseg=ch.segments[ch.order[start]]
 if not firstseg then return nil end
 local target=6
 for i=start,count do local s=ch.segments[ch.order[i]];if s then target=math.max(target,math.floor(s[2]+0.5)) end end
 local lines={'#EXTM3U','#EXT-X-VERSION:3','#EXT-X-TARGETDURATION:'..target,'#EXT-X-MEDIA-SEQUENCE:'..firstseg[1]}
 for i=start,count do
  local s=ch.segments[ch.order[i]]
  if s then
   if s[3]~='' then lines[#lines+1]='#EXT-X-PROGRAM-DATE-TIME:'..s[3] end
   lines[#lines+1]=string.format('#EXTINF:%.3f,',s[2]);lines[#lines+1]=s[4]
  end
 end
 return table.concat(lines,'\n')..'\n'
end
for _,r in ipairs(rows) do
 channels[r[1]]={slug=r[1],name=r[2],sid=r[3],pid=r[4],defn=default_defn,mode=force_bk[r[1]] and 'bk' or 'jce',
  segments={},order={},seq=0,last_fetch=0,failures=0,last_error='',bk_urls={},bk_urls_time=0}
end
local function all_m3u()
 local lines={'#EXTM3U'}
 for _,r in ipairs(rows) do
  lines[#lines+1]='#EXTINF:-1,'..r[2]
  lines[#lines+1]='http://127.0.0.1:18766/'..r[1]..'.m3u8'
 end
 return table.concat(lines,'\n')..'\n'
end
function M.handle(path)
 if path=='/health' then return 200,'text/plain; charset=utf-8','ok' end
 if path=='/all.m3u' then return 200,'application/vnd.apple.mpegurl',all_m3u() end
 if path=='/diag' then
  local lines={};for _,r in ipairs(rows) do local c=channels[r[1]];lines[#lines+1]=r[1]..' mode='..c.mode..' quality='..c.defn..' err='..c.last_error end
  return 200,'text/plain; charset=utf-8',table.concat(lines,'\n')..'\n'
 end
 local slug=path:match('^/([%w_]+)%.m3u8$')
 local ch=slug and channels[slug]
 if not ch then return 404,'text/plain; charset=utf-8','unknown channel\n' end
 local interval=ch.failures>=3 and 60 or 15
 if os.time()-ch.last_fetch>=interval or ch.last_fetch==0 then refresh(ch) end
 local body=build(ch)
 if not body then return 503,'text/plain; charset=utf-8','channel unavailable: '..ch.last_error..'\n' end
 return 200,'application/vnd.apple.mpegurl',body
end
_G.handle_request=M.handle
return M
