# SebType's fcitx5-mozc (#66): SebType's Mozc in pc/fcitx5-mozc, packaged as Fedora 44 packages
# fcitx5-mozc 2.30.5618.102^20250124gitc0ed34e-6 (this is Fedora's spec, MIT licence, with its
# bundled-protobuf choices fixed). build.sh sets the version and release from versions.sh and fetches
# the third-party sources, Fedora's own copies.

%global __provides_exclude_from ^%{_libdir}/fcitx5/.*\\.so$

# Fedora: "as of 2025.1.1, build with gcc failed due to errors with LOG(DFATAL)".
%global toolchain clang

%global server_dir %{_libexecdir}/fcitx5-mozc

Name:           fcitx5-mozc
Version:        %{sebtype_version}
Release:        %{sebtype_release}
Summary:        A wrapper of mozc for fcitx5
License:        BSD and UCD and Public Domain and mecab-ipadic and LGPLv2+ and MS-PL and ASL-2.0
URL:            https://github.com/S-Sebb/SebType

# pc/fcitx5-mozc, packed by build.sh
Source0:        fcitx5-mozc.tar.gz
# BSD 2-Clause; src/third_party/japanese_usage_dictionary
Source1:        japanese-usage-dictionary-e5b3425575734c323e1d947009dd74709437b684.tar.gz
# BSD 3-Clause; bundled because Fedora's protobuf is older than Mozc needs
Source2:        protobuf-3.29.1.tar.gz
# Apache-2.0; bundled because the bundled protobuf needs this version
Source4:        abseil-cpp-20240722.0.tar.gz
# Public Domain: Japan Post's postal codes, as of Fedora's build
Source5:        ken_all.zip
Source6:        jigyosyo.zip

BuildRequires:  python3-devel
BuildRequires:  gettext
BuildRequires:  gtk2-devel
BuildRequires:  qt5-qtbase-devel
BuildRequires:  zinnia-devel
BuildRequires:  clang
BuildRequires:  ninja-build
BuildRequires:  gyp >= 0.1-0.4.840svn
BuildRequires:  fcitx5-devel
BuildRequires:  libappstream-glib
BuildRequires:  %{py3_dist six}
BuildRequires:  gmock-devel
BuildRequires:  jsoncpp-devel
BuildRequires:  binutils

Requires:       hicolor-icon-theme
Requires:       fcitx5
Requires:       fcitx5-data

Provides:       bundled(protobuf) = v3.29.1
Provides:       bundled(abseil-cpp) = 20240722.0

ExcludeArch:    ppc ppc64 sparcv9 sparc64 s390x %{ix86}

%description
A wrapper of mozc for fcitx5.

%prep
%setup -q -n fcitx5-mozc -a 5 -a 6
mkdir -p src/third_party
%setup -q -n fcitx5-mozc -T -D -a 1
mv japanese-usage-dictionary-e5b3425575734c323e1d947009dd74709437b684 src/third_party/japanese_usage_dictionary
%setup -q -n fcitx5-mozc -T -D -a 2
mv protobuf-3.29.1 src/third_party/protobuf
rm src/third_party/protobuf/src/google/protobuf/lazy_repeated_field.cc
rm src/third_party/protobuf/src/google/protobuf/lazy_repeated_field_heavy.cc
%setup -q -n fcitx5-mozc -T -D -a 4
mv abseil-cpp-20240722.0 src/third_party/abseil-cpp

(cd src/data/dictionary_oss;
PYTHONPATH="${PYTHONPATH}:../../" python3 ../../dictionary/gen_zip_code_seed.py \
    --zip_code=../../../KEN_ALL.CSV --jigyosyo=../../../JIGYOSYO.CSV >> dictionary09.txt;
)

%build
%set_build_flags
pushd src
# The server files go in their own folder, so this can sit next to ibus-mozc.
QTDIR=%{_prefix} \
GYP_DEFINES="document_dir=%{_datadir}/licenses/%{name} \
    use_libzinnia=1 use_libprotobuf=0 \
    zinnia_model_file=%{_datadir}/zinnia/model/tomoe/handwriting-ja.model" \
python3 build_mozc.py gyp --gypdir=%{_bindir} --server_dir=%{server_dir} --target_platform=Linux

# Fedora: genproto_commands_proto can race its dependents, so it builds first.
python3 build_mozc.py build -c Release  protocol/protocol.gyp:genproto_commands_proto
python3 build_mozc.py build -c Release  server/server.gyp:mozc_server \
                                        gui/gui.gyp:mozc_tool \
                                        unix/fcitx5/fcitx5.gyp:fcitx5-mozc
popd

%install
pushd src
export _bldtype=Release
install -D -pm 755 "out_linux/${_bldtype}/mozc_server" "%{buildroot}%{server_dir}/mozc_server"
install -D -pm 755 "out_linux/${_bldtype}/mozc_tool"   "%{buildroot}%{server_dir}/mozc_tool"
# The install scripts' hardcoded folders, as Fedora's macros name them.
sed "s|\${PREFIX}/share/metainfo|%{buildroot}%{_metainfodir}|g" -i  ../scripts/install_fcitx5 ../scripts/install_fcitx5_data
sed "s|\${PREFIX}/share|%{buildroot}%{_datadir}|g"              -i  ../scripts/install_fcitx5 ../scripts/install_fcitx5_icons ../scripts/install_fcitx5_data
sed "s|\${PREFIX}/lib|%{buildroot}%{_libdir}|g"                 -i  ../scripts/install_fcitx5
../scripts/install_fcitx5
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
