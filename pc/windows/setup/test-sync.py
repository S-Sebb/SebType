"""The made-up words and the server's side of test.ps1's sync check (-Only sync, #180), run with the
Python that SebType's installer packs. Next to sebtype_sync.py (sync-server/), whose own code reads and
writes Rime's and Mozc's files here. The throwaway login's password comes on stdin.

    test-sync.py seed-rime RIME_DIR           a word of this PC's, as its own snapshot, for Rime to take in
    test-sync.py add-mozc DB READING WORD     a word in this PC's Mozc dictionary
    test-sync.py put-phone URL USER           another device's words on the server
    test-sync.py device RIME_DIR              this PC's Rime installation id, its device on the server
    test-sync.py server-has URL USER DEVICE NAME WORD...   the device's file NAME on the server has the words
    test-sync.py server-files URL USER        how many files the server keeps
    test-sync.py pc-has RIME_DIR DB           the other device's words in this PC's Rime and Mozc

Exits 1 with the reason when a check fails.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sebtype_sync as s

PHONE = "sebtype-test-phone"
PC_RIME, PHONE_RIME = "莫福姬", "普噜莫"
PHONE_MOZC = "プルモ試験語"


def snapshot(device, line):
    return (
        "# Rime user dictionary\n#@/db_name\trime_ice\n#@/db_type\tuserdb\n#@/rime_version\t1.16.1\n"
        f"#@/tick\t3\n#@/user_id\t{device}\n{line}\n"
    ).encode()


def own(rime_dir):
    device, sync_dir = s.rime_installation(rime_dir)
    return device, os.path.join(sync_dir, device)


def client(url, user):
    return s.Client(url, user, sys.stdin.readline().rstrip("\n"))


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "seed-rime":
        # Rime takes in every folder's snapshot, its own too, into the learned words it lists (any
        # *.userdb, an empty one included), and writes its own from them.
        os.makedirs(os.path.join(args[0], "rime_ice.userdb"), exist_ok=True)
        device, folder = own(args[0])
        s.write_file(
            os.path.join(folder, "rime_ice.userdb.txt"),
            snapshot(device, f"mo fu ji \t{PC_RIME}\tc=3 d=1 t=3"),
        )
        print(folder)
    elif command == "add-mozc":
        db, reading, word = args
        s.write_file(db, s.mozc_add(s.read_mozc(db), [(reading, word, s.NOUN)]))
    elif command == "put-phone":
        c = client(*args)
        c.request(
            "PUT",
            f"/v1/files/{PHONE}/rime_ice.userdb.txt",
            snapshot(PHONE, f"pu lu mo \t{PHONE_RIME}\tc=2 d=1 t=3"),
        )
        c.request(
            "PUT",
            f"/v1/files/{PHONE}/mozc_dictionary.txt",
            f"ぷるもて\t{PHONE_MOZC}\t名詞\n".encode(),
        )
    elif command == "device":
        print(own(args[0])[0])
    elif command == "server-has":
        url, user, device, name, *words = args
        text = client(url, user).request("GET", f"/v1/files/{device}/{name}").decode()
        missing = [w for w in words if w not in text]
        if missing:
            sys.exit(f"{device}/{name} on the server lacks {', '.join(missing)}")
        print(f"{device}/{name} has {', '.join(words)}")
    elif command == "server-files":
        print(len(client(*args).files()))
    elif command == "pc-has":
        rime_dir, db = args
        _, folder = own(rime_dir)
        with open(os.path.join(folder, "rime_ice.userdb.txt"), encoding="utf-8") as f:
            if PHONE_RIME not in f.read():
                sys.exit(f"Rime's snapshot lacks the other device's {PHONE_RIME}")
        if PHONE_MOZC not in {w for _, w, _, _ in s.mozc_words(s.read_mozc(db))}:
            sys.exit(f"Mozc's dictionary lacks the other device's {PHONE_MOZC}")
        print(f"Rime merged {PHONE_RIME}, Mozc has {PHONE_MOZC}")
    else:
        sys.exit(f"unknown command {command}")


if __name__ == "__main__":
    main()
