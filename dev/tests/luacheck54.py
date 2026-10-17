"""Compile-check Lua via liblua5.4. Uses luaL_loadfilex: luaL_loadfile is a macro in
5.4 and has no exported symbol, which is what breaks the supplied run_tests.py."""
import ctypes, sys
lua = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/liblua5.4.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lua.luaL_loadfilex.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]
fail = 0
for p in sys.argv[1:]:
    L = lua.luaL_newstate()
    rc = lua.luaL_loadfilex(L, p.encode(), b't')
    if rc != 0:
        print('FAIL %s\n     %s' % (p.split('/')[-1], lua.lua_tolstring(L, -1, None).decode('utf-8','replace')))
        fail += 1
    else:
        print('ok   %s' % p.split('/')[-1])
    lua.lua_close(L)
print('\n%d checked, %d failed' % (len(sys.argv)-1, fail))
