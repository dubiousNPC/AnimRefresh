"""Run a Lua file through liblua5.4 via ctypes (no interpreter installed here)."""
import ctypes, os, sys
lua = ctypes.CDLL('/usr/lib/x86_64-linux-gnu/liblua5.4.so.0')
lua.luaL_newstate.restype = ctypes.c_void_p
lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
lua.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
lua.luaL_loadfilex.restype = ctypes.c_int
lua.lua_pcallk.argtypes = [ctypes.c_void_p] + [ctypes.c_int]*3 + [ctypes.c_void_p]*2
lua.lua_pcallk.restype = ctypes.c_int
lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lua.lua_tolstring.restype = ctypes.c_char_p
lua.lua_close.argtypes = [ctypes.c_void_p]
lua.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
lua.lua_pushstring.restype = ctypes.c_void_p
path = sys.argv[1]
os.chdir(os.path.dirname(os.path.abspath(path)) or '.')
L = lua.luaL_newstate(); lua.luaL_openlibs(L)
if lua.luaL_loadfilex(L, os.path.basename(path).encode(), b't') != 0:
    print('load error:', lua.lua_tolstring(L, -1, None).decode('utf-8','replace')); sys.exit(1)
for extra in sys.argv[2:]:
    lua.lua_pushstring(L, extra.encode())
if lua.lua_pcallk(L, len(sys.argv) - 2, -1, 0, None, None) != 0:
    print('run error:', lua.lua_tolstring(L, -1, None).decode('utf-8','replace')); sys.exit(1)
lua.lua_close(L)
