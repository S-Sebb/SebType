# SebType sync server

Syncs the words SebType learned in 中文, and your Japanese and English personal dictionaries, between
your phone and your PCs, through a server you run yourself (#12, #14). There is no SebType cloud: the phone talks only to the address you enter, with a
username and password that belong to this server alone.

## How it works

Rime keeps learned words in a database and syncs them through a folder, `sync/<installation id>/`.
On a sync, every device writes a text snapshot of its learned words into its own folder and merges in
the snapshots in everyone else's. Since each device writes only its own folder, a server that keeps
one copy of each device's folder is enough, and two devices never overwrite each other.

The same folders carry the personal dictionaries: each device puts its whole Japanese dictionary there
as `mozc_dictionary.txt`, in the format of Mozc's own dictionary export, and its other (English) words
as `userdictionary.json`, FUTO Keyboard's format, which only phones have. A device takes in only the
words another device's file gained since it last took that file. A word you delete stays deleted on
that device, even while another device still has it. A sync only ever adds words. To remove a word
everywhere, delete it on each device. Learning history (what Mozc or the English keyboard learned
from your typing) isn't synced.

`sebtype_sync.py` is that server, and a small client for the PCs. It stores only these files
(`*.userdb.txt`, `mozc_dictionary.txt`, `userdictionary.json`), one folder per device under each user,
and the phone's crash reports (below). Passwords are stored as scrypt hashes in
`users.json`. Python 3.9 or newer, standard library only.

The phone syncs in the background while the keyboard is hidden: when it hides (at most once a minute)
and every half hour while SebType runs. Offline, Rime keeps learning as usual, and the next sync that
reaches the server takes everything along. The phone sends nothing but these files and its crash
reports: no clipboard, no typed text.

## Crash reports

When SebType crashes while sync is on, the phone keeps a report of the crash (at most the last 10)
and the next sync uploads it, then deletes it on the phone. The server keeps each one as a text file
in `<data>/crashes/<user>/crash-<UTC date>-<time>-<random>.txt`, next to `files/` and apart from the
learned words; read them there. `deluser` deletes them too, "Delete learned words on the server" does not.

A report holds the stack trace (exception classes and code lines, without the exceptions' messages),
SebType's version, Android's version, the phone's maker and model, and SebType's last 200 warnings
and errors with their messages removed (stack frames and SebType's own sync messages stay). Messages
are removed because any of them could quote typed text; settings and the login are never read into it.

While sync is off nothing is sent and a crash leaves no report. Reports kept from before sync was
turned off stay on the phone (no-backup storage, out of backups and exports) and go up with the first
sync after it is turned on again.

## Running the server

1. Give the server a system user and a data folder, and create a sync user in it. The password is
   asked for and stored hashed:

   ```sh
   sudo useradd --system --create-home --home-dir /var/lib/sebtype-sync sebtype-sync
   sudo -u sebtype-sync python3 /opt/sebtype-sync/sebtype_sync.py adduser --data /var/lib/sebtype-sync alice
   ```

   `deluser` removes a sync user and all their files; `adduser` on an existing one changes its password.

2. Start it. It listens on `127.0.0.1:8740` by default. As a systemd service,
   `/etc/systemd/system/sebtype-sync.service`:

   ```ini
   [Unit]
   Description=SebType sync server
   After=network.target

   [Service]
   User=sebtype-sync
   ExecStart=/usr/bin/python3 /opt/sebtype-sync/sebtype_sync.py serve --data /var/lib/sebtype-sync
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```

   then `sudo systemctl enable --now sebtype-sync`.

3. Put HTTPS in front of it. The phone refuses plain HTTP, and accepts only certificates from the
   authorities Android trusts (a Let's Encrypt certificate works; a self-signed one does not).
   With [Caddy](https://caddyserver.com), which gets the certificate itself:

   ```
   sync.example.com {
       reverse_proxy 127.0.0.1:8740
   }
   ```

   With nginx, inside a `server` block that already has a certificate:

   ```nginx
   location / {
       proxy_pass http://127.0.0.1:8740;
       client_max_body_size 64m;
   }
   ```

   Without a proxy, the server can serve HTTPS itself:
   `serve --host 0.0.0.0 --port 443 --tls-cert fullchain.pem --tls-key privkey.pem`.

Its log lists each request's method, path and status: device ids and file names, never the words or
the login. A wrong password waits a second before the answer, to slow down guessing.

### API

All requests use HTTP Basic auth with a user from `users.json`.

| Request | Does |
|---|---|
| `GET /v1/files` | Lists the user's files: `{"files": [{"device", "name", "size", "sha256"}]}` |
| `GET /v1/files/<device>/<name>` | Downloads one |
| `PUT /v1/files/<device>/<name>` | Stores one (a `*.userdb.txt`, `mozc_dictionary.txt` or `userdictionary.json`, up to 64 MB) |
| `DELETE /v1/files` | Deletes all of the user's files |
| `PUT /v1/crashes/<name>` | Stores a crash report (`crash-YYYYMMDD-HHMMSS-xxxxxx.txt`, up to 256 KB) in `crashes/<user>/` |

## On the phone

Settings › Sync & backup › Server and login: the server's address (`sync.example.com`, or with a port
or path), the username and the password. Saving a first login turns "Sync learned words" on and syncs
at once; its line then shows when the last sync was, or why it failed. The login is encrypted with a
key in the Android Keystore and kept out of backups, settings exports and logs.

"Delete learned words on the server" deletes every device's files on the server, dictionaries included,
and turns sync off. The words on the phone and on your other devices stay; turning sync on again
uploads the phone's own.

Words from other devices go into the personal dictionaries: Japanese ones into 日本語's **My words**,
English ones into English's. Japanese words with a part of speech the phone doesn't know come in as
nouns, without their comments.

## On a Linux PC (fcitx5-rime)

Rime's user dir is `~/.local/share/fcitx5/rime`. Its sync folder is `sync/` inside it unless
`installation.yaml` there names another one with `sync_dir`. To keep it elsewhere, for example in a
folder another tool backs up, add to `installation.yaml`:

```yaml
sync_dir: "/home/alice/rime-sync"
```

and restart fcitx5. The PC's own folder is `sync_dir/<installation_id>`, with the `installation_id`
from the same file.

One sync on the PC has three steps: download the other devices' snapshots, let Rime merge them and
write the PC's own, upload that. Put the password in a file only you can read
(`install -m 600 /dev/null ~/.config/sebtype-sync-password`, then write it in), and run:

```sh
R=~/.local/share/fcitx5/rime
python3 sebtype_sync.py pull --server https://sync.example.com --user alice \
    --password-file ~/.config/sebtype-sync-password --rime-dir "$R"
# fcitx5 saves its addons' data on this call, and fcitx5-rime's save is Rime's sync
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.Save
sleep 5   # Rime merges in the background
python3 sebtype_sync.py push --server https://sync.example.com --user alice \
    --password-file ~/.config/sebtype-sync-password --rime-dir "$R"
```

fcitx5 also saves, and so syncs, when it quits (at logout). To sync regularly, run the three steps
from a systemd user timer or cron. `pull` and `push` send only files that changed, and only the PC's
own snapshot goes up.

On Windows (Weasel) the user dir is `%APPDATA%\Rime`, and the menu's 用户资料同步 is Rime's sync; the
same `pull` and `push` work with `--rime-dir "%APPDATA%\Rime"`.

## Japanese on a PC (Mozc)

With `--mozc-db`, `push` also uploads the PC's Mozc user dictionary, and `pull` adds the other devices'
new Japanese words to it. They go into a dictionary of their own, "SebType sync", in Mozc's dictionary
tool. The PC still needs Rime, for its device id. English words stay on the phones: a PC has no English
personal dictionary to put them in.

On Linux (fcitx5-mozc) the dictionary is `~/.config/mozc/user_dictionary.db`. Add the option to both
commands above:

```sh
python3 sebtype_sync.py pull ... --rime-dir "$R" --mozc-db ~/.config/mozc/user_dictionary.db
python3 sebtype_sync.py push ... --rime-dir "$R" --mozc-db ~/.config/mozc/user_dictionary.db
```

If Mozc's dictionary tool is open, `pull` stops without changing anything and says so. Before it changes the dictionary it keeps the old one as `user_dictionary.db.sebtype-backup`.
Mozc reads its dictionary when it starts, so new words come up once `mozc_server` restarts, at the
next login or after `kill $(pidof mozc_server)` (fcitx5 starts it again at the next key).

On Windows, Google 日本語入力 is the same engine with the same dictionary file,
`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\user_dictionary.db`. Close its
dictionary tool before `pull`, which can't check that on Windows. Neither is tested on Windows yet.
Microsoft IME keeps no file this can sync.

## Tests

`python3 -I sync-server/test_sebtype_sync.py`: the server on a local port with a made-up user, two
made-up devices syncing through it, a made-up Mozc dictionary, and a crash report. The phone side is
checked on the emulator by `SEBTYPE_CHECKS=first-install,sync sebtype/test-emulator.sh`
(`sync-crash-report` crashes SebType and finds the report in the crash folder)
([docs/testing.md](../docs/testing.md)).
