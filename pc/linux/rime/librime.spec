# SebType's librime (#101): SebType's librime in engines/librime, packaged as Fedora 44 packages librime
# 1.16.1-2 (this is Fedora's spec, MIT licence). build.sh sets the version and release from
# versions.sh and fetches the plugins, Fedora's own copies.

Name:           librime
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        Rime Input Method Engine Library
License:        GPL-3.0-only
URL:            https://github.com/S-Sebb/SebType
# engines/librime, packed by build.sh
Source0:        librime.tar.gz
# The plugins, as Fedora's package has them: librime-lua needs librime's internal API, so it is built
# with librime.
Source1:        librime-lua.tar.gz
Source2:        librime-octagram.tar.gz
Source3:        librime-predict.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  cmake, opencc-devel
BuildRequires:  boost-devel >= 1.46
BuildRequires:  zlib-devel
BuildRequires:  glog-devel, gtest-devel
BuildRequires:  yaml-cpp-devel
BuildRequires:  gflags-devel
BuildRequires:  marisa-devel
BuildRequires:  leveldb-devel
BuildRequires:  lua-devel

%description
Rime Input Method Engine Library
Support for shape-based and phonetic-based input methods,
including those for Chinese dialects.
A selected dictionary in Traditional Chinese,
powered by opencc for Simplified Chinese output.

%package        devel
Summary:        Development files for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    devel
The %{name}-devel package contains libraries and header files for
developing applications that use %{name}.

%package        tools
Summary:        Tools for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    tools
The %{name}-tools package contains tools for %{name}.

%package        lua
Summary:        Lua plugin for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    lua
The %{name}-lua package contains the lua plugin from the community.

%package        octagram
Summary:        Octagram plugin for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    octagram
The %{name}-octagram package contains the octagram plugin from the community.

%package        predict
Summary:        Predict plugin for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}

%description    predict
The %{name}-predict package contains the predict plugin from the community.

%prep
%setup -q -n librime
pushd plugins
tar xf %{SOURCE1}
mv librime-lua-master lua
tar xf %{SOURCE2}
mv librime-octagram-master octagram
tar xf %{SOURCE3}
mv librime-predict-master predict
popd

%build
%cmake -DCMAKE_BUILD_TYPE=Release \
       -DBUILD_MERGED_PLUGINS=OFF \
       -DENABLE_EXTERNAL_PLUGINS=ON
%cmake_build

%install
%cmake_install

%ldconfig_scriptlets

%files
%doc README.md LICENSE
%{_libdir}/*.so.*

%files devel
%{_includedir}/*
%{_libdir}/*.so
%{_libdir}/pkgconfig/rime.pc
%dir %{_datadir}/cmake/rime
%{_datadir}/cmake/rime/RimeConfig.cmake

%files tools
%{_bindir}/rime_deployer
%{_bindir}/rime_dict_manager
%{_bindir}/rime_patch
%{_bindir}/rime_table_decompiler

%files lua
%{_libdir}/rime-plugins/librime-lua.so

%files octagram
%{_libdir}/rime-plugins/librime-octagram.so

%files predict
%{_libdir}/rime-plugins/librime-predict.so
