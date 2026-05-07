//! Copy the frontend build product (or the placeholder) into `static/` so
//! `rust-embed` can pick it up.

use std::path::Path;

fn main() {
    println!("cargo:rerun-if-changed=../../web/dist");
    println!("cargo:rerun-if-changed=../../web/index.html");
    println!("cargo:rerun-if-changed=../../web/src");

    let crate_root = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let static_dir = Path::new(&crate_root).join("static");
    let _ = std::fs::create_dir_all(&static_dir);

    let web_dir = Path::new(&crate_root).parent().unwrap().parent().unwrap().join("web");
    let dist    = web_dir.join("dist");

    let source: Option<std::path::PathBuf> = if dist.is_dir() {
        Some(dist)
    } else if web_dir.join("index.html").is_file() {
        Some(web_dir)
    } else {
        None
    };

    // Wipe old static/.
    if static_dir.is_dir() {
        for ent in std::fs::read_dir(&static_dir).into_iter().flatten().flatten() {
            let _ = if ent.path().is_dir() { std::fs::remove_dir_all(ent.path()) }
                    else { std::fs::remove_file(ent.path()) };
        }
    }

    match source {
        Some(src) => {
            copy_tree(&src, &static_dir);
        }
        None => {
            // Last-resort placeholder.
            let placeholder = b"<!doctype html><meta charset=utf-8><title>motif-web</title>\
                <h1>motif-web</h1><p>frontend not built. \
                Run <code>pnpm build</code> in <code>web/</code>, \
                or place an <code>index.html</code> there.</p>";
            std::fs::write(static_dir.join("index.html"), placeholder).unwrap();
        }
    }
}

fn copy_tree(src: &Path, dst: &Path) {
    if let Ok(entries) = std::fs::read_dir(src) {
        for ent in entries.flatten() {
            let path = ent.path();
            // Skip frontend toolchain noise.
            let name = ent.file_name();
            let n = name.to_string_lossy();
            if n == "node_modules" || n == "src" || n == ".git" || n.starts_with('.') {
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
