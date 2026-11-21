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
as `userdictionary.json`, FUTO Keyboard's format, which only phones have, and its Chinese **My words**
as `zh_my_words.userdb.txt` (#272). The PCs also put there the conversions you picked in Mozc, as
`mozc_learned.txt` (#409, below). The rest of what Mozc or the English keyboard learned from your typing
isn't synced.

Japanese words sync both ways, deletions and edits too (#273). Each line of `mozc_dictionary.txt` also
has the time the word last changed on that device, and the words deleted there are kept as `#-` lines;
a device keeps its own file as the record of what it had at its last sync, so it can tell what you
changed since. A word is its reading and spelling, and its newest change wins:

- Deleted on one device: it goes on the others at their next sync.
- Deleted on one device and added again (or edited) later on another: whichever happened last wins,
  whichever device syncs first. The devices' clocks decide, so keep them right.
- Edited on two devices (another part of speech): the later edit wins.
- Words from before this version carry no time. One of them comes to a device only when the other
  device's file gained it, as before, so a word you deleted earlier doesn't come back.

Chinese My words sync by the same rules (#272). There a word is its pinyin and spelling, and each line of
`zh_my_words.userdb.txt` is `pinyin<TAB>word<TAB>名詞<TAB><TAB>time` (the part of speech only fills
Mozc's column) or a `#-` line. Its name is one of Rime's snapshot names, so a server or device from before
#272 stores it and passes it on unchanged; Rime itself only reads its own user dictionaries' snapshots, so
it never takes it for learned words. A device from before #272 doesn't sync My words: it keeps a copy of
the other devices' files without taking their words in. Once it is updated, its first sync takes them in
all the same, and its own words go up. Deleting learned words keeps these files.

A device from before #273 still syncs: the new file's words keep Mozc's export columns, and it skips the
`#-` lines. It takes in the words other devices add but not their deletions; what it still has doesn't
come back to the others, and what it deletes stays deleted only there.

### Learned conversions (Mozc)

When you convert a reading in Japanese and pick another candidate than the first, Mozc learns it and puts
it first next time. Mozc's own files keep only hashes of what it learned, so SebType's Mozc also keeps a
record of your picks, `mozc_learned.txt` in Mozc's folder: a `# SebType mozc_learned 1` line, then one
`reading<TAB>written<TAB>time` line per pick, at most its most recent 5,000. The sync uploads it when it changed
and puts the other devices' records in `mozc_learned/<device>.txt` beside it (none over 1 MB); when Mozc next starts it learns
each reading another device picked something for since, every pick known for it in time order, so the
latest pick comes first on every device. Only the pick is learned, not the words around it, which Mozc
also learns from on the device you typed on.

- Learning off: nothing new is recorded, and other devices' picks are still learned, as from a private field.
- Forget (Japanese): empties this device's record, which the next sync uploads so, and keeps when you forgot:
  no pick from before it, on any device, is learned here again, only what is picked after.
- A server from before #409 refuses the file; the PC syncs the rest without it.

English words sync as before: a device takes in only the words another device's file gained since it
last took that file, so a word you delete stays deleted on that device, even while another device still
has it, and to remove one everywhere, delete it on each phone.

`sebtype_sync.py` is that server, and a small client for the PCs. It stores only these files
(`*.userdb.txt`, `mozc_dictionary.txt`, `userdictionary.json`, `mozc_learned.txt`), one folder per device under each user,
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
learned words; read them there. `deluser` deletes them too, "Delete learned words and dictionaries on the server" does not.

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
| `PUT /v1/files/<device>/<name>` | Stores one (a `*.userdb.txt`, `mozc_dictionary.txt`, `userdictionary.json` or `mozc_learned.txt`, up to 64 MB) |
| `DELETE /v1/files` | Deletes all of the user's files |
| `PUT /v1/crashes/<name>` | Stores a crash report (`crash-YYYYMMDD-HHMMSS-xxxxxx.txt`, up to 256 KB) in `crashes/<user>/` |

## On the phone

Settings › Sync & backup › Server and login: the server's address (`sync.example.com`, or with a port
or path), the username and the password. Saving a first login turns "Sync learned words and dictionaries" on and syncs
at once; its line then shows when the last sync was, or why it failed. The login is encrypted with a
key in the Android Keystore and kept out of backups, settings exports and logs.

Save first checks the address and the login with one `GET /v1/files` to that address (no redirect is
followed), and says what's wrong if they don't work: wrong username or password, the server can't be
reached, the address isn't a SebType sync server (another answer, or a redirect), or its HTTPS certificate
isn't trusted. It then offers Save anyway, as a server down today syncs later. Opening Sync & backup checks
the saved login the same way, and so does its Refresh status row (#452), with a green tick or a berry X; a failed check shows only there,
never while typing.

"Delete learned words and dictionaries on the server" deletes every device's files on the server:
learned words and dictionaries. It turns sync off. The words on the phone and on your other devices stay; turning sync on again
uploads the phone's own.

Words from other devices go into the personal dictionaries: Japanese ones into 日本語's **My words**,
English ones into English's, Chinese ones into 中文's My words. A Japanese or Chinese word deleted on
another device goes from My words too. Japanese words with a part of speech the phone doesn't know come in as
nouns, without their comments.

## On a PC (SebType Configurator)

Sync & backup in the SebType Configurator, on Linux and Windows, has the phone's sync rows (#180). Server
and login takes the same address, username and password as the phone (an `https://` address; plain
`http://` only to the PC itself, such as `http://127.0.0.1:8740`). Saving a first login turns "Sync
learned words and dictionaries" on and syncs at once; its line then shows when the last sync was, or
why it failed. Save, the Linux Setup's Account sync step and the Windows Setup's check the login first, and Sync &
backup checks it as it opens and with Refresh status, as on the phone (#452, the client's `check`). The password is kept only in the system's keyring: Secret Service (KWallet, GNOME
Keyring) on Linux, Credential Manager on Windows, as "SebType sync". The address and username are in
SebType's folder (`~/.local/share/sebtype/sync.json`, `%LOCALAPPDATA%\SebType\sync.json`), with the last
sync's outcome.

While sync is on, `sebtype-configurator --sync` runs every half hour, as on the phone: a systemd user
timer (`sebtype-sync.timer`, also two minutes after login) on Linux, a Task Scheduler task
("SebType sync", while you're logged on) on Windows. Each run is the three steps below with this
`sebtype_sync.py`, built into the Configurator: `pull`, Rime's sync (Fcitx5's save on Linux,
`sebtype-server.exe /sync` on Windows), `push`, with the password on the client's stdin
(`--password-stdin`) and the Mozc dictionary included. When Japanese words came in or went, or
another device's learned conversions came in, Mozc restarts, once typing is idle, to read them. On Windows the Configurator runs it with the Python that Setup installs next to it.

"Delete learned words and dictionaries on the server" runs the client's `delete` and turns sync off; the
words on the PC stay. Uninstalling SebType, or leaving a language out in Setup, never deletes anything on
the server: if sync was ever on, Setup syncs first (Decisions #2), then removes the schedule and the login.

## By hand on a Linux PC

This is what the Configurator does; without it, the client runs like this.

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
(`install -m 600 /dev/null ~/.config/sebtype-sync-password`, then write it in), or give it on stdin with
`--password-stdin` instead of `--password-file`, and run:

```sh
R=~/.local/share/fcitx5/rime
python3 sebtype_sync.py pull --server https://sync.example.com --user alice \
    --password-file ~/.config/sebtype-sync-password --rime-dir "$R"
# fcitx5 saves its addons' data on this call, and SebType's input method saves Rime's with Rime's sync
gdbus call --session --dest org.fcitx.Fcitx5 --object-path /controller \
    --method org.fcitx.Fcitx.Controller1.Save
sleep 5   # Rime merges in the background
python3 sebtype_sync.py push --server https://sync.example.com --user alice \
    --password-file ~/.config/sebtype-sync-password --rime-dir "$R"
```

fcitx5 also saves, and so syncs, when it quits (at logout). To sync regularly, run the three steps
from a systemd user timer or cron. `pull` and `push` send only files that changed, and only the PC's
own snapshot goes up. A Save while Rime is still busy (deploying after fcitx5 starts) is skipped: if
the PC's snapshot didn't change, save again. `delete` (with the same login options, no Rime dir) deletes
every device's files on the server. The client exits with 3 when the server refuses the login.

On Windows the user dir is `%APPDATA%\Rime`; the same `pull` and `push` work with
`--rime-dir "%APPDATA%\Rime"`.

## Japanese on a PC (Mozc)

With `--mozc-db`, `push` also uploads the PC's Mozc user dictionary (its enabled dictionaries' words),
and `pull` takes in the other devices' changes: their new words go into the dictionary "SebType", which
the Configurator shows as My words, and the words they deleted go from every enabled dictionary. Words
an older version put in a dictionary of their own, "SebType sync", show in My words too, and move into
"SebType" when you next add or delete a word there. The PC keeps its own file, with the times, as
`mozc_dictionary.txt` in its folder in Rime's sync folder. The PC still needs Rime, for its device id.

## Chinese My words on a PC

`push` and `pull` always sync the Configurator's 中文 My words, the lines after `# SebType: My words` in
`custom_phrase.txt` in the Rime dir: `pull` puts the other devices' words there (after rime-ice's own
phrases) and removes the ones they deleted, and the Configurator deploys Rime after. The PC keeps its own
file, with the times, as `zh_my_words.userdb.txt` in its folder in Rime's sync folder. A
`custom_phrase.txt` without that line (My words never saved) has nothing to tell, so it never reads as all
words deleted. English words stay on the phones: a PC has no English
personal dictionary to put them in.

On Linux the dictionary is `~/.config/mozc/user_dictionary.db` (`~/.mozc/user_dictionary.db` if an older
Mozc made that folder; Mozc uses it then). Add the option to both
commands above:

```sh
python3 sebtype_sync.py pull ... --rime-dir "$R" --mozc-db ~/.config/mozc/user_dictionary.db
python3 sebtype_sync.py push ... --rime-dir "$R" --mozc-db ~/.config/mozc/user_dictionary.db
```

If Mozc's dictionary tool is open, `pull` stops without changing anything and says so. Before it changes the dictionary it keeps the old one as `user_dictionary.db.sebtype-backup`.
Mozc reads its dictionary when it starts, so new words come up once it restarts: the Configurator's sync
restarts it, and by hand `busctl --user call org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1 SetConfig
sv fcitx://config/addon/sebtype/mozc s ''` (Linux) or `sebtype-server.exe /mozc` (Windows) does.

On Windows, Google 日本語入力 is the same engine with the same dictionary file,
`%USERPROFILE%\AppData\LocalLow\Google\Google Japanese Input\user_dictionary.db`. Close its
dictionary tool before `pull`, which can't check that on Windows. Neither is tested on Windows yet.
Microsoft IME keeps no file this can sync.

## Tests

`python3 -I sync-server/test_sebtype_sync.py`: the server on a local port with a made-up user, two
made-up devices syncing through it, made-up Mozc dictionaries (adding, deleting and adding again,
conflicts, and a client from before #273), a crash report, and the command line with the password on
stdin. The phone's side of the same rules is in `android/build.sh unit-tests`. The Configurator's sync is checked by `SEBTYPE_CHECKS=private-sync
pc/configurator/test.sh`: this server on the PC with a throwaway login, a private keyring, Fcitx5, Rime
and Mozc in a sandbox, made-up words both ways, and delete. The phone side is
checked on the emulator by `SEBTYPE_CHECKS=first-install,sync android/test/emulator.sh`
(`sync-crash-report` crashes SebType and finds the report in the crash folder)
([docs/development.md](../docs/development.md)).
