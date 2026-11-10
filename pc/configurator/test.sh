#!/usr/bin/env bash
# Checks the SebType Configurator (#72) on Linux without touching the live desktop: unit tests, the
# release build, every screen opened in a nested virtual KWin (screenshots kept), a private Fcitx5 and
# Rime taking what the app writes, and its install by setup-ime.sh. Engine files are copies in a
# sandbox; learned words are never copied or forgotten. One line per check in
# /tmp/sebtype/configurator-test-results.txt; logs and screenshots next to it.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

out=/tmp/sebtype; mkdir -p "$out"
results=$out/configurator-test-results.txt; : > "$results"
result() { echo "$1 $2${3:+: $3}" | tee -a "$results"; }
check() { # name, timeout seconds, command or exported function...
  local name=$1 secs=$2; shift 2
  if timeout "$secs" bash -c '"$@"' _ "$@" > "$out/configurator-test-$name.log" 2>&1; then result PASS "$name"
  else result FAIL "$name" "see $out/configurator-test-$name.log"; fi
}

# Preflight
for c in cargo dbus-run-session kwin_wayland spectacle fcitx5 desktop-file-validate; do
  command -v "$c" >/dev/null || { echo "preflight: $c missing"; exit 1; }
done
[[ -f /usr/share/fcitx5/addon/rime.conf && -f ~/.local/share/fcitx5/rime/rime_ice.schema.yaml ]] ||
  { echo "preflight: fcitx5-rime and rime-ice (pc/linux/setup-ime.sh) needed"; exit 1; }

check unit-tests 900 cargo test --release
check release-build 900 cargo build --release
bin=$PWD/target/release/sebtype-configurator

# A sandbox account: copies of this account's engine settings, without Rime's and Mozc's learned words.
sb=$(mktemp -d "$out/configurator-sandbox.XXXX")
trap 'rm -rf "$sb"' EXIT
sandbox() {
  mkdir -p "$sb/config" "$sb/data/fcitx5"
  cp -r ~/.config/fcitx5 "$sb/config/"
  [[ -d ~/.config/mozc ]] && rsync -a --exclude='*history*' --exclude=segment.db --exclude=boundary.db --exclude=cform.db ~/.config/mozc "$sb/config/"
  rsync -a --exclude='*.userdb' --exclude='*.userdb.txt' --exclude=sync ~/.local/share/fcitx5/rime "$sb/data/fcitx5/"
  printf '[Groups/0]\nName=Default\nDefault Layout=us\nDefaultIM=keyboard-us\n\n[Groups/0/Items/0]\nName=keyboard-us\nLayout=\n\n[Groups/0/Items/1]\nName=rime\nLayout=\n\n[Groups/0/Items/2]\nName=mozc\nLayout=\n\n[GroupOrder]\n0=Default\n' \
    > "$sb/config/fcitx5/profile"
}
sandbox

# Every screen opens and stays open; the screenshots are kept for the eye.
shots() {
  local d=$out/configurator-shots
  rm -rf "$d"; mkdir -p "$d"
  cat > "$sb/shots.sh" <<'SH'
#!/usr/bin/env bash
bin=$1 d=$2; shift 2
exec >> "$d/status" 2>&1  # KWin doesn't pass its client's output on
for spec in "$@"; do
  name=${spec%%:*}; read -ra a <<<"${spec#*:}"
  "$bin" "${a[@]}" & pid=$!
  sleep 3
  kill -0 $pid 2>/dev/null || { echo "$name: the app exited"; exit 1; }
  spectacle -b -n -a -o "$d/$name.png" 2>/dev/null
  kill $pid; wait $pid 2>/dev/null
  [[ -s $d/$name.png ]] || { echo "$name: no screenshot"; exit 1; }
  echo "$name ok"
done
echo all-screens-ok
SH
  chmod +x "$sb/shots.sh"
  env -u WAYLAND_DISPLAY -u DISPLAY XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" dbus-run-session -- \
    kwin_wayland --virtual --no-lockscreen --socket "wl-sebtype-test-$$" --width 1000 --height 700 --exit-with-session \
    "$sb/shots.sh $bin $d 'langs:--page 0' 'keyboard:--page 1' 'theme:--page 2' 'privacy:--page 3' 'sync:--page 4' 'about:--page 5' 'fuzzy:--page 0 --sub 1' 'zhwords:--page 0 --sub 2' 'jawords:--page 0 --sub 3'" > "$sb/kwin.log" 2>&1
  cat "$d/status"; grep -qx all-screens-ok "$d/status"
}
export -f shots; export out sb bin
check every-screen-opens 150 shots

# Fcitx5 and Rime take the languages and Chinese settings the app writes (the ignored Rust test).
# shellcheck disable=SC2016  # the inner script gets its paths as arguments
private_fcitx5() {
  env -i PATH="$PATH" HOME="$sb" XDG_CONFIG_HOME="$sb/config" XDG_DATA_HOME="$sb/data" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR-}" \
    CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}" RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" CARGO_TARGET_DIR="$PWD/target" \
    dbus-run-session -- bash -c '
      fcitx5 -k --disable=all --enable=dbus,keyboard,rime,mozc > "$1/fcitx5.log" 2>&1 & f=$!
      for _ in $(seq 50); do busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.2; done
      cargo test --release --manifest-path "$2/Cargo.toml" -- --ignored --exact linux::tests::private_fcitx5_takes_languages_and_chinese_settings
      rc=$?; kill $f; wait $f; exit $rc' _ "$sb" "$PWD"
}
export -f private_fcitx5
check private-fcitx5-and-rime 300 private_fcitx5

check setup-ime 900 ../linux/test-setup-ime.sh

! grep -q '^FAIL' "$results"
