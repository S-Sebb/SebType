# SebType's Linux input method (#190): one Fcitx5 add-on over SebType's core (core/, linux/), which hosts
# librime for 中文 and Mozc for 日本語 (engines/mozc, as libsebtype-mozc.so in the add-on's process, #233), and
# 中文's model around Rime (core/src/chinese.cpp on llama.cpp, engines/sebtype-lm/chinese.gguf, #495).
# With it, what setup's user part installs into each account (#421), in %{_libexecdir}/sebtype: setup itself
# (sebtype-setup), the Configurator (pc/configurator) and SebType's Chinese data (data/rime), so a PC with
# this package needs no checkout or build tools.
# SebType's librime (engines/librime, #101) with librime-lua and librime-octagram is built into the add-on
# (linux/CMakeLists.txt), so Fedora's librime stays installed for other apps and system updates, which sync
# Fedora's packages to the repositories (#527), leave SebType's alone.
# build.sh sets the version, release, Bazel and its folders (cache_root keeps the crates and data's sources).

# Private libraries: the add-on finds Mozc's by its RUNPATH ($ORIGIN/../sebtype), and nothing else may link it.
%global __provides_exclude_from ^%{_libdir}/(fcitx5|sebtype)/.*\\.so$
%global __requires_exclude ^libsebtype-mozc\\.so

Name:           sebtype
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        SebType: English, 中文 and 日本語 in one Fcitx5 input method
# SebType's code MIT; core/src/rime.cpp and the tray LGPL-2.1-or-later (fcitx5-rime's, Fcitx5's); core/src/mozc.cpp
# and Mozc BSD-3-Clause, with the licences of Mozc's data and third-party code (core/README.md); the Chinese data GPL-3.0-only
# (rime-ice, 白霜) with OpenCC's Apache-2.0 (data/rime/build.sh's SOURCE.txt), the Configurator's crates their own;
# llama.cpp MIT, the Chinese model CC-BY-SA-4.0 (engines/sebtype-lm/README.md); SebType's librime, librime-lua and
# librime-octagram in the add-on BSD-3-Clause.
License:        MIT and GPL-3.0-only and LGPL-2.1-or-later and BSD-3-Clause and UCD and Public Domain and mecab-ipadic and MS-PL and Apache-2.0 and CC-BY-SA-4.0
URL:            https://github.com/S-Sebb/SebType

# versions.sh's SEBTYPE_SOURCES and engines/mozc, packed by build.sh
Source0:        sebtype.tar.gz
Source1:        mozc.tar.gz
# llama.cpp at engines/sebtype-lm/fetch-llama.sh's pin, packed by build.sh
Source2:        llama.tar.gz
# The Rime plugins SebType's librime builds in: Fedora's librime-lua, octagram at versions.sh's OCTAGRAM_COMMIT
Source3:        librime-lua.tar.gz
Source4:        librime-octagram.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  pkgconf-pkg-config
BuildRequires:  fcitx5-devel
# The tray's pixmaps (PNG)
BuildRequires:  pkgconfig(libpng)
BuildRequires:  librime-devel
# SebType's librime
BuildRequires:  boost-devel >= 1.46
BuildRequires:  glog-devel
BuildRequires:  gflags-devel
BuildRequires:  yaml-cpp-devel
BuildRequires:  leveldb-devel
BuildRequires:  marisa-devel
BuildRequires:  lua-devel
BuildRequires:  zlib-devel
# 中文's model: OpenCC for its 繁 (core/src/chinese.cpp)
BuildRequires:  opencc-devel
BuildRequires:  protobuf-devel
BuildRequires:  protobuf-compiler
BuildRequires:  gtest-devel
BuildRequires:  python3
BuildRequires:  git-core
BuildRequires:  unzip
# The Configurator
BuildRequires:  cargo
BuildRequires:  rust
BuildRequires:  fontconfig-devel
# The Chinese data, compiled with Fedora's librime and OpenCC
BuildRequires:  gcc
BuildRequires:  opencc
BuildRequires:  zip
BuildRequires:  curl

Requires:       fcitx5
Requires:       fcitx5-data
# What setup's first step installs, so an update installs a new one with this package: Fcitx5's modules for
# XWayland and older apps.
Requires:       fcitx5-autostart fcitx5-qt fcitx5-qt5 fcitx5-qt6 fcitx5-gtk fcitx5-gtk2 fcitx5-gtk3 fcitx5-gtk4
# setup's user part
Requires:       python3 unzip
# The tray icons' folders; its file trigger updates hicolor's icon cache.
Requires:       hicolor-icon-theme

ExcludeArch:    ppc ppc64 sparcv9 sparc64 s390x %{ix86}

%description
SebType's input method: English, Chinese (Rime) and Japanese (Mozc) in one Fcitx5 add-on, with
SebType's tray menu.

%prep
%setup -q -c -n sebtype -a 1 -a 2
mkdir -p engines && mv mozc engines/
tar -C engines/librime/plugins -xf %{SOURCE3} && mv engines/librime/plugins/{librime-lua-master,lua}
tar -C engines/librime/plugins -xf %{SOURCE4} && mv engines/librime/plugins/librime-octagram-* engines/librime/plugins/octagram
# The licences of what the add-on carries, by name in one folder
cp engines/librime/LICENSE librime-LICENSE
cp engines/librime/plugins/lua/LICENSE librime-lua-LICENSE
cp engines/librime/plugins/octagram/LICENSE librime-octagram-LICENSE
cp llama/LICENSE llama.cpp-LICENSE

%build
# Mozc as a library, with Bazel (its caches are kept between builds), before the add-on that links it.
# Bazel downloads nothing: build.sh fetched it and all it needs, capped, into mozc_downloads (#361).
pushd engines/mozc/src
%{bazel} --output_user_root=%{bazel_root} build --disk_cache=%{bazel_root}/disk-cache \
  --registry=file://%{mozc_downloads}/registry --repository_cache=%{mozc_downloads}/repos \
  --repository_disable_download --jobs=%{_smp_build_ncpus} --show_progress_rate_limit=60 \
  -c opt --config oss_linux --config release_build //sebtype:libsebtype-mozc.so
install -pm 755 bazel-bin/sebtype/libsebtype-mozc.so ../../../libsebtype-mozc.so
popd
cmake -S linux -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_INSTALL_LIBDIR=%{_lib} -DSEBTYPE_MOZC_LIB=$PWD/libsebtype-mozc.so -DLLAMA_DIR=$PWD/llama
ninja -C build -j %{_smp_build_ncpus}
# The crates download once into cache_root; the build folder stays there too, so a rebuild compiles what changed.
# The sources' hash, built in (sebtype-configurator --sources), makes Cargo rebuild what changed: their times are 0.
# No debug info: build.sh packs none (debug_package is nil), and with it the fat-LTO link runs out of memory (#496).
RUSTFLAGS="${RUSTFLAGS:-} -Cdebuginfo=0" SEBTYPE_SOURCES=$(source linux/versions.sh && configurator_sources .) CARGO_HOME=%{cache_root}/cargo cargo build --release --locked --jobs %{_smp_build_ncpus} \
  --manifest-path pc/configurator/Cargo.toml --target-dir %{cache_root}/configurator-target
HOME=%{cache_root}/home data/rime/build.sh chinese-data >/dev/null

%check
ctest --test-dir build/core --output-on-failure

%install
# Not librime's component (linux/CMakeLists.txt)
DESTDIR=%{buildroot} cmake --install build --component Unspecified
# setup's user part, run from here: it finds these beside it (pc/linux/setup-ime.sh), and SebType's version in
# versions.sh, which in the checkout reads it from VERSION.
d=%{buildroot}%{_libexecdir}/sebtype
install -Dpm 755 pc/linux/setup-ime.sh $d/setup-ime.sh
install -pm 644 pc/linux/mozc-keymap.tsv $d/
sed 's|^SEBTYPE_VERSION=.*|SEBTYPE_VERSION=%{version}|' linux/versions.sh > $d/versions.sh
install -pm 755 %{cache_root}/configurator-target/release/sebtype-configurator $d/
install -pm 644 android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_round.png $d/sebtype-configurator.png
install -pm 644 chinese-data/rime/rime-data.zip $d/
mkdir -p %{buildroot}%{_bindir}
ln -s ../libexec/sebtype/setup-ime.sh %{buildroot}%{_bindir}/sebtype-setup

%files
%license engines/mozc/LICENSE librime-LICENSE librime-lua-LICENSE librime-octagram-LICENSE llama.cpp-LICENSE
%{_libdir}/fcitx5/sebtype.so
%{_datadir}/fcitx5/addon/sebtype.conf
%{_datadir}/sebtype/fcitx5/addon/notificationitem.conf
%{_datadir}/sebtype/tray
%{_datadir}/sebtype/chinese.gguf
%{_libdir}/sebtype
%{_datadir}/icons/hicolor/*/status/sebtype-*.png
%{_datadir}/icons/hicolor/scalable/status/sebtype-*.svg
%{_bindir}/sebtype-setup
%{_libexecdir}/sebtype
