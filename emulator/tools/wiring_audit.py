import re, sys, json
from collections import Counter

if len(sys.argv)<2:
    sys.exit('usage: wiring_audit.py emulator.html')
path=sys.argv[1]
h=open(path).read()
js_raw=re.search(r'<script>([\s\S]*)</script>',h).group(1)
# strip comments and string/template literals: English prose in comments was being
# matched as function calls ("flags (bit 0)" -> a call to `flags`)
def strip_code(t):
    t=re.sub(r'/\*[\s\S]*?\*/',' ',t)
    t=re.sub(r'(?<![:/])//[^\n]*',' ',t)
    t=re.sub(r'`(?:\\.|[^`\\])*`','""',t)
    t=re.sub(r"'(?:\\.|[^'\\\n])*'","''",t)
    t=re.sub(r'"(?:\\.|[^"\\\n])*"','""',t)
    return t
js=strip_code(js_raw)
html=h[:h.index('<script>')]+h[h.rindex('</script>')+9:]

problems=[]
def bad(cat,items,note=''):
    if items: problems.append((cat,sorted(set(items)),note))

# ---------- 1. duplicate HTML ids ----------
ids=re.findall(r'id="([A-Za-z0-9_-]+)"',h)
dups=[k for k,v in Counter(ids).items() if v>1]
bad('duplicate HTML ids',dups)
idset=set(ids)

# ---------- 2. JS -> HTML ----------
refs=set(re.findall(r"\$\('([A-Za-z0-9_-]+)'\)",js_raw))
refs|=set(re.findall(r"getElementById\('([A-Za-z0-9_-]+)'\)",js_raw))
loopfix=set(re.findall(r"\$\('([A-Za-z0-9_-]+)'\+",js_raw))
bad('JS references a missing HTML id',refs-idset)

# ---------- 3. HTML -> JS ----------
controls=set(re.findall(r'<(?:button|select|input|textarea)[^>]*id="([A-Za-z0-9_-]+)"',h))
unwired=[c for c in controls if c not in refs and not any(c.startswith(p) for p in loopfix)]
bad('interactive control with no JS handler',unwired)

# ---------- 4. tabs <-> panes ----------
tabs=set(re.findall(r'data-t="([a-z0-9]+)"',h))
panes=set(re.findall(r'id="p-([a-z0-9]+)"',h))
bad('tab button with no pane',tabs-panes)
bad('pane with no tab button',panes-tabs)

# ---------- 5. functions called but never defined ----------
defs=set(re.findall(r'function\s+([A-Za-z_$][\w$]*)\s*\(',js))
defs|=set(re.findall(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function|\()',js))
defs|=set(re.findall(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$]*\s*=>',js))
defs|=set(re.findall(r'class\s+([A-Za-z_$][\w$]*)',js))
defs|=set(re.findall(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*[A-Za-z_$][\w$.]*\.bind',js))
defs|=set(re.findall(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)',js))
# comma-separated declarations: const a=..., b=..., c=...  — only the first name
# was being seen, so later ones looked like calls to undefined functions
for grp in re.findall(r'(?:const|let|var)\s+([^;\n]+)',js):
    for part in grp.split(','):
        mm=re.match(r'\s*([A-Za-z_$][\w$]*)\s*=',part)
        if mm: defs.add(mm.group(1))
defs|=set(re.findall(r'(?:const|let|var)\s*\{([^}]*)\}\s*=',js))
defs|=set(x.strip() for grp in re.findall(r'(?:const|let|var)\s*\{([^}]*)\}\s*=',js) for x in grp.split(','))
defs|=set(re.findall(r'^\s*([A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{',js,re.M))   # class methods
BUILTIN={'if','for','while','switch','catch','return','function','typeof','new','do','else',
 'Math','Number','String','Object','Array','JSON','parseInt','parseFloat','isNaN','Uint8Array',
 'Uint16Array','Uint32Array','Int16Array','Int8Array','Float32Array','Set','Map','Promise','Date',
 'requestAnimationFrame','cancelAnimationFrame','setTimeout','setInterval','clearInterval','alert',
 'confirm','prompt','addEventListener','removeEventListener','fetch','Blob','URL','btoa','atob',
 'encodeURIComponent','decodeURIComponent','Error','TextEncoder','TextDecoder','ArrayBuffer',
 'AudioContext','webkitAudioContext','DataView','Boolean','RegExp','Symbol','BigInt','structuredClone',
 'queueMicrotask','performance','console','document','window','navigator','localStorage','$',
 'isFinite','isInteger','Infinity','NaN','undefined','globalThis','Function','Uint8ClampedArray'}
# function parameters and arrow-function args are locals, not missing functions
params=set()
for grp in re.findall(r'function[^(]*\(([^)]*)\)',js): params|={p.strip().split('=')[0].strip() for p in grp.split(',')}
for grp in re.findall(r'\(([^()]*)\)\s*=>',js):        params|={p.strip().split('=')[0].strip() for p in grp.split(',')}
for grp in re.findall(r'([A-Za-z_$][\w$]*)\s*=>',js):   params.add(grp.strip())
for grp in re.findall(r'catch\s*\(([^)]*)\)',js):      params.add(grp.strip())
params|={'async','await'}
params.discard('')
calls=set(re.findall(r'\b([A-Za-z_$][\w$]*)\s*\(',js))
# strip anything that is a property access (obj.method) or a declaration
propcalls=set(re.findall(r'\.\s*([A-Za-z_$][\w$]*)\s*\(',js))
undef=[c for c in calls-defs-BUILTIN-propcalls-params if not c[0].isupper()]
bad('function called but never defined',undef)

# ---------- 6. project functions defined but never called ----------
# only consider names genuinely declared AS FUNCTIONS — plain locals and words
# that leaked in from prose are not features and cannot be "unwired"
funcdefs=set(re.findall(r'function\s+([A-Za-z_$][\w$]*)\s*\(',js))
funcdefs|=set(re.findall(r'(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)',js))
proj=[d for d in funcdefs if re.match(r'^(lab|msx|card|cart|bat|game|ns|snap|shutdown|generic|romNote|dl)',d)]
def usage_count(name):
    # every `name(` occurrence, less the one in its own `function name(` definition.
    # Arrow declarations (`const name=a=>`) contain no `name(`, so nothing is
    # wrongly subtracted for them.
    calls=len(re.findall(r'\b'+re.escape(name)+r'\s*\(',js))
    own=len(re.findall(r'function\s+'+re.escape(name)+r'\s*\(',js))
    return calls-own
uncalled=[d for d in proj if usage_count(d)<1]
bad('project function defined but never called',uncalled,'dead code, or a feature that was never wired')

# ---------- 7. named subsystems present ----------
expect={
 'Z80 core':'class Z80','VDP':'renderLine','Machine':'class Machine',
 'MSX2 machine':'function makeMSX','V9938 command engine':'execCmd',
 'MSX-MUSIC detection':'makeMsxMusicRom','AY to PSG':'makeAY2PSG',
 'MSX converter':'function msxConvert','stage tileset':'msxStageTileset',
 'object tracker':'function msxTrackObjects','genre profiles':'GENRE_PROFILES',
 'sprite dump':'msxBuildSpriteDump','scene detection':'function msxScenes',
 'save card format':'function cardFormat','save profiles':'function cardProfiles',
 'icon capture':'captureIcon','sprite gallery':'collectGallery',
 'cartridge snapshot':'function cartSnapshot','standby shutdown':'function shutdownSequence',
 'ROM wait states':'romWaitStates','Super Sega Lab':'function labMakeLive',
 'live composite':'function labCompositeLive','engine match':'function labEngineMatch',
 'IPS builder':'function labBuildIPS','hack lab':'HACK','sound lab':'chUse',
}
missing=[k for k,v in expect.items() if v not in js_raw]
bad('declared subsystem missing from the build',missing)

# ---------- report ----------
print('WIRING AUDIT — supersega-emulator.html  (%.1f KB, %d lines)'%(len(h)/1024,h.count('\n')+1))
print('='*68)
print('  HTML ids %d · interactive controls %d · JS refs %d'%(len(idset),len(controls),len(refs)))
print('  functions defined %d · tabs %d · panes %d'%(len(defs),len(tabs),len(panes)))
print('  subsystems verified present: %d of %d'%(len(expect)-len(missing),len(expect)))
print()
if not problems:
    print('  RESULT: clean — no wiring problems found')
else:
    print('  RESULT: %d problem categor%s'%(len(problems),'y' if len(problems)==1 else 'ies'))
    for cat,items,note in problems:
        print()
        print('  [%s]%s'%(cat,('  — '+note) if note else ''))
        for i in items[:24]: print('     '+i)
        if len(items)>24: print('     ... and %d more'%(len(items)-24))
sys.exit(1 if problems else 0)
