"""Find globals that the mod's Lua scripts read but nothing ever defines (typos, use before
a local exists, broken edits). Usage: python globals_check.py <scripts dir>"""
import sys, os
from luaparser import ast, astnodes as N

BUILTIN = set('''_G _ENV _VERSION assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall
print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type xpcall coroutine debug io math os
package string table utf8 sdk re imgui json fs log draw Vector2f Vector3f Vector4f Quaternion Matrix4x4f ValueType
reframework d2d vrmod thread'''.split())

class Scope:
    def __init__(self, parent=None): self.names, self.parent = set(), parent
    def has(self, n):
        s = self
        while s:
            if n in s.names: return True
            s = s.parent
        return False

def walk(node, scope, reads, writes):
    if node is None: return
    if isinstance(node, list):
        for x in node: walk(x, scope, reads, writes)
        return
    t = type(node)
    if t is N.LocalAssign:
        walk(node.values, scope, reads, writes)
        for tg in node.targets: scope.names.add(tg.id)
        return
    if t is N.LocalFunction:
        scope.names.add(node.name.id)
        inner = Scope(scope)
        for a in node.args:
            if isinstance(a, N.Name): inner.names.add(a.id)
        walk(node.body, inner, reads, writes)
        return
    if t in (N.Function, N.Method):
        nm = node.name
        if isinstance(nm, N.Name):
            if not scope.has(nm.id): writes.add(nm.id)
        else:
            walk(nm, scope, reads, writes)
        inner = Scope(scope)
        if t is N.Method: inner.names.add('self')
        for a in node.args:
            if isinstance(a, N.Name): inner.names.add(a.id)
        walk(node.body, inner, reads, writes)
        return
    if t is N.AnonymousFunction:
        inner = Scope(scope)
        for a in node.args:
            if isinstance(a, N.Name): inner.names.add(a.id)
        walk(node.body, inner, reads, writes)
        return
    if t is N.Assign:
        walk(node.values, scope, reads, writes)
        for tg in node.targets:
            if isinstance(tg, N.Name):
                if not scope.has(tg.id): writes.add(tg.id)
            else: walk(tg, scope, reads, writes)
        return
    if t is N.Fornum:
        walk([node.start, node.stop, node.step], scope, reads, writes)
        inner = Scope(scope); inner.names.add(node.target.id)
        walk(node.body, inner, reads, writes)
        return
    if t is N.Forin:
        walk(node.iter, scope, reads, writes)
        inner = Scope(scope)
        for tg in node.targets: inner.names.add(tg.id)
        walk(node.body, inner, reads, writes)
        return
    if t in (N.Block,):
        inner = Scope(scope)
        walk(node.body, inner, reads, writes)
        return
    if t in (N.While, N.Repeat, N.Do):
        if t is N.Repeat:
            inner = Scope(scope); walk(node.body, inner, reads, writes); walk(node.test, inner, reads, writes)
        else:
            walk(getattr(node, 'test', None), scope, reads, writes)
            walk(node.body, Scope(scope), reads, writes)
        return
    if t in (N.If, N.ElseIf):
        walk(node.test, scope, reads, writes)
        walk(node.body, Scope(scope), reads, writes)
        walk(node.orelse, Scope(scope), reads, writes)
        return
    if t is N.Name:
        if not scope.has(node.id): reads.setdefault(node.id, node)
        return
    if t is N.Index:
        walk(node.value, scope, reads, writes)
        if node.notation == N.IndexNotation.SQUARE: walk(node.idx, scope, reads, writes)
        return
    if t is N.Invoke:
        walk(node.source, scope, reads, writes); walk(node.args, scope, reads, writes)
        return
    if t is N.Table:
        for f in node.fields:
            if isinstance(f.key, N.Name) and not getattr(f, 'between_brackets', False): pass
            else: walk(f.key, scope, reads, writes)
            walk(f.value, scope, reads, writes)
        return
    # generic: visit child nodes
    if not hasattr(node, "__dict__"): return
    for k, v in vars(node).items():
        if k.startswith('_') or k in ('comments', 'line', 'start_char', 'stop_char', 'first_token', 'last_token'): continue
        if isinstance(v, (N.Node, list)): walk(v, scope, reads, writes)

d = sys.argv[1]
files = sys.argv[2:] or [f for f in os.listdir(d) if f.startswith('coop_') and f.endswith('.lua')]
all_reads, all_writes = {}, set()
for f in files:
    src = open(os.path.join(d, f), encoding='utf-8').read()
    try:
        tree = ast.parse(src)
    except Exception as e:
        print('PARSE FAIL', f, str(e)[:200]); continue
    reads, writes = {}, set()
    walk(tree.body, Scope(), reads, writes)
    for n in reads: all_reads.setdefault(n, set()).add(f)
    all_writes |= writes
for n, fs in sorted(all_reads.items()):
    if n not in all_writes and n not in BUILTIN:
        print('UNDEFINED', n, sorted(fs))
