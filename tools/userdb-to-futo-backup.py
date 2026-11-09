#!/usr/bin/env python3
"""Puts a PC Rime userdb into a FUTO Keyboard settings backup, so its learned words carry over.

    tools/userdb-to-futo-backup.py FUTO_BACKUP USERDB_DIR OUT_BACKUP

FUTO_BACKUP is a backup exported from the phone (Settings > Misc > Export configuration), USERDB_DIR
the PC's rime_ice.userdb directory (read from a temporary copy, never changed). Import OUT_BACKUP on
the phone with Settings > Misc > Import configuration.

FUTO's librime is built without snappy, so it can't read the PC's (snappy-compressed) LevelDB; this
rewrites every record into an uncompressed one. Needs the host's libleveldb (Fedora: leveldb).
"""

import ctypes
import pathlib
import shutil
import sys
import tempfile
import zipfile

L = ctypes.CDLL("libleveldb.so.1")
P, S, B = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ubyte
ERR = ctypes.POINTER(ctypes.c_char_p)
for name, res, args in [
    ("leveldb_options_create", P, []),
    ("leveldb_options_set_create_if_missing", None, [P, B]),
    ("leveldb_options_set_compression", None, [P, ctypes.c_int]),
    ("leveldb_open", P, [P, ctypes.c_char_p, ERR]),
    ("leveldb_close", None, [P]),
    ("leveldb_readoptions_create", P, []),
    ("leveldb_writeoptions_create", P, []),
    ("leveldb_put", None, [P, P, ctypes.c_char_p, S, ctypes.c_char_p, S, ERR]),
    ("leveldb_create_iterator", P, [P, P]),
    ("leveldb_iter_seek_to_first", None, [P]),
    ("leveldb_iter_valid", B, [P]),
    ("leveldb_iter_next", None, [P]),
    ("leveldb_iter_key", P, [P, ctypes.POINTER(S)]),
    ("leveldb_iter_value", P, [P, ctypes.POINTER(S)]),
    ("leveldb_iter_destroy", None, [P]),
]:
    getattr(L, name).restype, getattr(L, name).argtypes = res, args


def open_db(path, create=False):
    opt = L.leveldb_options_create()
    L.leveldb_options_set_create_if_missing(opt, create)
    L.leveldb_options_set_compression(opt, 0)
    err = ctypes.c_char_p()
    db = L.leveldb_open(opt, str(path).encode(), ctypes.byref(err))
    if err.value:
        sys.exit(f"{path}: {err.value.decode()}")
    return db


def copy_uncompressed(src, dst):
    sdb, ddb = open_db(src), open_db(dst, create=True)
    it, wo, err, n = (
        L.leveldb_create_iterator(sdb, L.leveldb_readoptions_create()),
        L.leveldb_writeoptions_create(),
        ctypes.c_char_p(),
        0,
    )
    L.leveldb_iter_seek_to_first(it)
    while L.leveldb_iter_valid(it):
        kl, vl = S(), S()
        k = ctypes.string_at(L.leveldb_iter_key(it, ctypes.byref(kl)), kl.value)
        v = ctypes.string_at(L.leveldb_iter_value(it, ctypes.byref(vl)), vl.value)
        L.leveldb_put(ddb, wo, k, len(k), v, len(v), ctypes.byref(err))
        if err.value:
            sys.exit(err.value.decode())
        n += 1
        L.leveldb_iter_next(it)
    L.leveldb_iter_destroy(it)
    L.leveldb_close(sdb)
    L.leveldb_close(ddb)
    return n


def main(backup, userdb, out):
    prefix = "rime/user/rime_ice.userdb/"
    with tempfile.TemporaryDirectory() as tmp:
        src = pathlib.Path(tmp, "src")
        shutil.copytree(userdb, src, ignore=shutil.ignore_patterns("LOCK"))
        dst = pathlib.Path(tmp, "rime_ice.userdb")
        n = copy_uncompressed(src, dst)
        with (
            zipfile.ZipFile(backup) as zin,
            zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout,
        ):
            for item in zin.infolist():
                if not item.filename.startswith(prefix):
                    zout.writestr(item, zin.read(item.filename))
            for f in sorted(dst.iterdir()):
                if f.name not in ("LOCK", "LOG", "LOG.old"):
                    zout.write(f, prefix + f.name)
    print(f"{out}: {n} userdb records")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
