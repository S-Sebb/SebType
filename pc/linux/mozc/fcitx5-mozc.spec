# SebType's fcitx5-mozc (#66): SebType's Mozc in engines/mozc, the same tree the Windows build uses, with
# fcitx/mozc's Fcitx 5 frontend (src/unix/fcitx5), packaged in place of Fedora 44's fcitx5-mozc (whose
# spec, MIT licence, this one follows). Mozc builds with Bazel, which fetches the third-party libraries
# MODULE.bazel pins. build.sh sets the version, release and Bazel's folders.

%global __provides_exclude_from ^%{_libdir}/fcitx5/.*\\.so$

%global server_dir %{_libexecdir}/fcitx5-mozc

Name:           fcitx5-mozc
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        A wrapper of mozc for fcitx5
License:        BSD and UCD and Public Domain and mecab-ipadic and LGPLv2+ and MS-PL and ASL-2.0
URL:            https://github.com/S-Sebb/SebType

# engines/mozc, packed by build.sh
Source0:        mozc.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  python3
BuildRequires:  gettext
BuildRequires:  pkgconf-pkg-config
BuildRequires:  qt6-qtbase-devel
BuildRequires:  fcitx5-devel
BuildRequires:  libappstream-glib
BuildRequires:  git-core
BuildRequires:  unzip

Requires:       hicolor-icon-theme
Requires:       fcitx5
Requires:       fcitx5-data

ExcludeArch:    ppc ppc64 sparcv9 sparc64 s390x %{ix86}

%description
A wrapper of mozc for fcitx5.

%prep
%setup -q -n mozc

%build
pushd src
# config.bzl has the server and document folders, %%{server_dir} and %%{_docdir}/%%{name}.
bazel --output_user_root=%{bazel_root} build --disk_cache=%{bazel_root}/disk-cache \
  --repository_cache=%{bazel_root}/repository-cache --jobs=%{_smp_build_ncpus} --show_progress_rate_limit=60 \
  -c opt --config oss_linux --config release_build \
  unix/fcitx5:fcitx5-mozc.so server:mozc_server gui/tool:mozc_tool
# Copies outside Bazel's output tree, which is a symlink into %%{bazel_root}.
mkdir -p ../out
cp bazel-bin/unix/fcitx5/fcitx5-mozc.so bazel-bin/server/mozc_server bazel-bin/gui/tool/mozc_tool ../out/
popd

%install
pushd src
install -D -pm 755 ../out/mozc_server "%{buildroot}%{server_dir}/mozc_server"
install -D -pm 755 ../out/mozc_tool   "%{buildroot}%{server_dir}/mozc_tool"
install -D -pm 755 ../out/fcitx5-mozc.so "%{buildroot}%{_libdir}/fcitx5/fcitx5-mozc.so"
# The install scripts' hardcoded folders, as Fedora's macros name them.
sed "s|\${PREFIX}/share/metainfo|%{buildroot}%{_metainfodir}|g" -i ../scripts/install_fcitx5_data
sed "s|\${PREFIX}/share|%{buildroot}%{_datadir}|g; s|install -D|install -Dp|" \
  -i ../scripts/install_fcitx5_icons ../scripts/install_fcitx5_data
../scripts/install_fcitx5_data
popd

appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/*.metainfo.xml

%find_lang %{name}

%files -f %{name}.lang
%license LICENSE
%doc README.md src/data/installer/*.html
%{server_dir}
%{_datadir}/fcitx5/*/mozc.conf
%{_datadir}/icons/hicolor/*/apps/*
%{_libdir}/fcitx5/fcitx5-mozc.so
%{_metainfodir}/org.fcitx.Fcitx5.Addon.Mozc.metainfo.xml
