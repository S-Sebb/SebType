# SebType's Linux input method (#190): one Fcitx5 add-on over SebType's core (core/, linux/), which hosts
# librime for 中文 and Mozc's server for 日本語 (engines/mozc), in place of fcitx5-rime and fcitx5-mozc.
# build.sh sets the version, release and Bazel's folders.

%global __provides_exclude_from ^%{_libdir}/fcitx5/.*\\.so$

Name:           sebtype
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        SebType: English, 中文 and 日本語 in one Fcitx5 input method
# SebType's code MIT; core/src/rime.cpp and the tray LGPL-2.1-or-later (fcitx5-rime's, Fcitx5's); core/src/mozc.cpp
# and Mozc's server as fcitx5-mozc.spec (core/README.md).
License:        MIT and LGPL-2.1-or-later and BSD-3-Clause and UCD and Public Domain and mecab-ipadic and MS-PL and Apache-2.0
URL:            https://github.com/S-Sebb/SebType

# core/ and linux/, and engines/mozc, packed by build.sh
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

ExcludeArch:    ppc ppc64 sparcv9 sparc64 s390x %{ix86}

%description
SebType's input method: English, Chinese (Rime) and Japanese (Mozc) in one Fcitx5 add-on, with
SebType's tray menu.

%prep
%setup -q -c -n sebtype -a 1
mkdir -p engines && mv mozc engines/

%build
cmake -S linux -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=%{_prefix} \
  -DCMAKE_INSTALL_LIBDIR=%{_lib}
ninja -C build -j %{_smp_build_ncpus}
# Mozc's server, as fcitx5-mozc.spec builds it (its caches are shared).
pushd engines/mozc/src
bazel --output_user_root=%{bazel_root} build --disk_cache=%{bazel_root}/disk-cache \
  --repository_cache=%{bazel_root}/repository-cache --jobs=%{_smp_build_ncpus} --show_progress_rate_limit=60 \
  -c opt --config oss_linux --config release_build server:mozc_server
cp bazel-bin/server/mozc_server ../../../mozc_server
popd

%check
ctest --test-dir build/core --output-on-failure

%install
DESTDIR=%{buildroot} ninja -C build install
install -D -pm 755 mozc_server %{buildroot}%{_libexecdir}/sebtype/mozc_server

%files
%license engines/mozc/LICENSE
%{_libdir}/fcitx5/sebtype.so
%{_datadir}/fcitx5/addon/sebtype.conf
%{_datadir}/sebtype/fcitx5/addon/notificationitem.conf
%{_libexecdir}/sebtype
