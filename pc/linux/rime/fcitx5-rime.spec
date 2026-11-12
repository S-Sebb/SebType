# SebType's fcitx5-rime (#117): SebType's fcitx5-rime in pc/fcitx5-rime, packaged as Fedora 44 packages
# fcitx5-rime 5.1.15-1 (this is Fedora's spec, MIT licence). build.sh sets the version and release
# from versions.sh.

%global __provides_exclude_from ^%{_libdir}/fcitx5/.*\\.so$

Name:           fcitx5-rime
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        RIME support for Fcitx
License:        LicenseRef-Callaway-LGPLv2+
URL:            https://github.com/S-Sebb/SebType
# pc/fcitx5-rime, packed by build.sh
Source0:        fcitx5-rime.tar.gz

BuildRequires:  brise
BuildRequires:  cmake
BuildRequires:  extra-cmake-modules
BuildRequires:  gcc-c++
BuildRequires:  ninja-build
BuildRequires:  gettext
BuildRequires:  pkgconfig
BuildRequires:  pkgconfig(Fcitx5Core)
BuildRequires:  pkgconfig(Fcitx5Module)
BuildRequires:  pkgconfig(rime)
BuildRequires:  /usr/bin/appstream-util
Requires:       hicolor-icon-theme
Requires:       fcitx5-data
Requires:       brise

%description
RIME(中州韻輸入法引擎) is mainly a Traditional Chinese
input method engine.

%prep
%setup -q -n fcitx5-rime

%build
%cmake -GNinja
%cmake_build

%install
%cmake_install

# Fedora: symlinked icons become copies, which helps living next to fcitx4.
for iconfile in $(find %{buildroot}%{_datadir}/icons -type l)
do
  origicon=$(readlink -f ${iconfile})
  rm -f ${iconfile}
  cp ${origicon} ${iconfile}
done
appstream-util validate-relax --nonet %{buildroot}%{_metainfodir}/*.metainfo.xml
%find_lang %{name}

%check
%ctest

%files -f %{name}.lang
%license LICENSES/LGPL-2.1-or-later.txt
%doc README.md
%{_libdir}/fcitx5/librime.so
%{_datadir}/fcitx5/*/rime.conf
%{_datadir}/icons/hicolor/*/*/*
%{_datadir}/rime-data/fcitx5.yaml
%{_metainfodir}/org.fcitx.Fcitx5.Addon.Rime.metainfo.xml
