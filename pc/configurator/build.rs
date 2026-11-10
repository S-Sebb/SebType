fn main() {
    slint_build::compile_with_config(
        "ui/app.slint",
        slint_build::CompilerConfiguration::new().with_style("fluent-light".into()),
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
