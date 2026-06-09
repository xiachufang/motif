//! Copy the frontend build product into `static/` so `rust-embed` can
//! include it in the motifd binary.

use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=../../apps/flutter/build/web");
    println!("cargo:rerun-if-changed=../../apps/flutter/web");
    println!("cargo:rerun-if-changed=../../apps/flutter/lib");

    let crate_root = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let static_dir = Path::new(&crate_root).join("static");
    let _ = std::fs::create_dir_all(&static_dir);

    if static_dir.is_dir() {
        for ent in std::fs::read_dir(&static_dir)
            .into_iter()
            .flatten()
            .flatten()
        {
            let _ = if ent.path().is_dir() {
                std::fs::remove_dir_all(ent.path())
            } else {
                std::fs::remove_file(ent.path())
            };
        }
    }

    let flutter_dir = Path::new(&crate_root)
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("apps")
        .join("flutter");
    let dist = flutter_dir.join("build").join("web");

    if dist.is_dir() {
        copy_tree(&dist, &static_dir);
    } else {
        let placeholder = b"<!doctype html><meta charset=utf-8><title>motif</title>\
            <h1>motif</h1><p>frontend not built. \
            Run <code>flutter build web</code> from <code>apps/flutter</code>, \
            then rebuild <code>motifd</code>.</p>";
        std::fs::write(static_dir.join("index.html"), placeholder).unwrap();
    }
}

fn copy_tree(src: &Path, dst: &Path) {
    if let Ok(entries) = std::fs::read_dir(src) {
        for ent in entries.flatten() {
            let path = ent.path();
            let name = ent.file_name();
            let n = name.to_string_lossy();
            if n == "node_modules" || n == ".git" || n.starts_with('.') {
                continue;
            }
            let target = dst.join(name);
            if path.is_dir() {
                std::fs::create_dir_all(&target).ok();
                copy_tree(&path, &target);
            } else if path.is_file() {
                std::fs::copy(&path, &target).ok();
            }
        }
    }
}
