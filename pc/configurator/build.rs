fn main() {
    slint_build::compile_with_config(
        "ui/app.slint",
        // English is in the .slint files; lang/ holds 中文 and 日本語, built into the exe (#118). One
        // translation per English string, whichever component shows it.
        slint_build::CompilerConfiguration::new()
            .with_style("fluent-light".into())
            .with_bundled_translations("lang")
            .with_default_translation_context(slint_build::DefaultTranslationContext::None),
    )
    .unwrap();
    // The .exe's icon: CI makes it from the phone's pig (.github/workflows/configurator.yml) and passes its path.
    #[cfg(windows)]
    if let Ok(ico) = std::env::var("SEBTYPE_ICO") {
        winresource::WindowsResource::new()
            .set_icon(&ico)
            .compile()
            .unwrap();
    }
    println!("cargo:rerun-if-env-changed=SEBTYPE_ICO");
}
