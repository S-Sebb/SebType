# SebType's Linux input method (#190): one Fcitx5 add-on over SebType's core (core/, linux/), which hosts
# librime for 中文 and Mozc for 日本語 (engines/mozc, as libsebtype-mozc.so in the add-on's process, #233).
# build.sh sets the version, release and Bazel's folders.

# Private libraries: the add-on finds Mozc's by its RUNPATH ($ORIGIN/../sebtype), and nothing else may link it.
%global __provides_exclude_from ^%{_libdir}/(fcitx5|sebtype)/.*\\.so$
%global __requires_exclude ^libsebtype-mozc\\.so

Name:           sebtype
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        SebType: English, 中文 and 日本語 in one Fcitx5 input method
# SebType's code MIT; core/src/rime.cpp and the tray LGPL-2.1-or-later (fcitx5-rime's, Fcitx5's); core/src/mozc.cpp
# and Mozc BSD-3-Clause, with the licences of Mozc's data and third-party code (core/README.md).
License:        MIT and LGPL-2.1-or-later and BSD-3-Clause and UCD and Public Domain and mecab-ipadic and MS-PL and Apache-2.0
URL:            https://github.com/S-Sebb/SebType

# core/, linux/ and pc/icons, and engines/mozc, packed by build.sh
Source0:        sebtype.tar.gz
Source1:        mozc.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  cmake
BuildRequires:  ninja-build
BuildRequires:  pkgconf-pkg-config
BuildRequires:  fcitx5-devel
BuildRequires:  librime-devel
BuildRequires:  protobuf-devel
BuildRequires:  protobuf-compiler
BuildRequires:  gtest-devel
BuildRequires:  python3
BuildRequires:  git-core
BuildRequires:  unzip

Requires:       fcitx5
Requires:       fcitx5-data
Requires:       librime-lua
# The tray icons' folders; its file trigger updates hicolor's icon cache.
Requires:       hicolor-icon-theme

ExcludeArch:    ppc ppc64 sparcv9 sparc64 s390x %{ix86}

%description
SebType's input method: English, Chinese (Rime) and Japanese (Mozc) in one Fcitx5 add-on, with
SebType's tray menu.

%prep
%setup -q -c -n sebtype -a 1
mkdir -p engines && mv mozc engines/

%build
# Mozc as a library, with Bazel (its caches are kept between builds), before the add-on that links it.
pushd engines/mozc/src
bazel --output_user_root=%{bazel_root} build --disk_cache=%{bazel_root}/disk-cache \
  --repository_cache=%{bazel_root}/repository-cache --jobs=%{_smp_build_ncpus} --show_progress_rate_limit=60 \
  -c opt --config oss_linux --config release_build //sebtype:libsebtype-mozc.so
install -pm 755 bazel-bin/sebtype/libsebtype-mozc.so ../../../libsebtype-mozc.so
popd
cmake -S linux -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_INSTALL_LIBDIR=%{_lib} -DSEBTYPE_MOZC_LIB=$PWD/libsebtype-mozc.so
ninja -C build -j %{_smp_build_ncpus}

%check
ctest --test-dir build/core --output-on-failure

%install
DESTDIR=%{buildroot} ninja -C build install

%files
%license engines/mozc/LICENSE
%{_libdir}/fcitx5/sebtype.so
%{_datadir}/fcitx5/addon/sebtype.conf
%{_datadir}/sebtype/fcitx5/addon/notificationitem.conf
%{_libdir}/sebtype
%{_datadir}/icons/hicolor/*/status/sebtype-*.png
%{_datadir}/icons/hicolor/scalable/status/sebtype-*.svg
