mod drawings;

use std::error::Error;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use docboss_model::Severity;

const MAX_BYTES: u64 = 64 * 1024 * 1024;

fn convert(source: &Path, destination: &Path) -> Result<(), Box<dyn Error>> {
    let mut bytes = Vec::new();
    File::open(source)?
        .take(MAX_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_BYTES {
        return Err("Document is too large".into());
    }
    let compound = docboss_cfb::CompoundFile::parse(&bytes)?;
    let word = compound.open_stream("WordDocument")?;
    let header = word.get(..12).ok_or("Incomplete Word header")?;
    let version = u16::from_le_bytes([header[2], header[3]]);
    let flags = u16::from_le_bytes([header[10], header[11]]);
    if !matches!(&header[..2], [0xdc, 0xa5] | [0x97, 0xa6] | [0xec, 0xa5])
        || !(0x0065..=0x0112).contains(&version)
    {
        return Err("Not a supported binary Word document".into());
    }
    if flags & 0x8100 != 0 {
        println!("ERROR PASSWORD");
        return Err("Password-protected Word document".into());
    }

    if version < 0x00c0 {
        println!("LEGACY DOC");
    }
    std::io::stdout().flush()?;
    let mut document = docboss_doc::read(&bytes)?;
    if document.blocks().next().is_none() {
        return Err("No document content was recovered".into());
    }
    let figures = drawings::preserve_groups(&mut document, MAX_BYTES as usize);
    if figures.rasterized > 0 {
        println!("DOC RASTERIZED {}", figures.rasterized);
    }
    if figures.incomplete > 0 {
        println!("DOC RASTERIZED_PARTIAL {}", figures.incomplete);
    }
    if !document.diagnostics.is_empty() || (flags & 0x0008 != 0 && document.media.is_empty()) {
        println!("DOC APPROXIMATED");
    }
    let (mut equations, mut images, mut other) = (0, figures.dropped, 0);
    for diagnostic in &document.diagnostics {
        if diagnostic.severity != Severity::Dropped {
            continue;
        }
        if diagnostic.message.ends_with("its picture stays") {
            continue;
        }
        if diagnostic.location.ends_with("/Equation Native") {
            equations += 1;
        } else if diagnostic.message.contains("picture") || diagnostic.message.contains("image") {
            images += 1;
        } else {
            other += 1;
        }
    }
    if equations + images + other > 0 {
        println!("DOC DROPPED {equations} {images} {other}");
    }
    let converted = docboss_write::to_bytes(&document)?;
    if converted.is_empty() || converted.len() as u64 > MAX_BYTES {
        return Err("Invalid DOCX output size".into());
    }
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?
        .write_all(&converted)?;
    Ok(())
}

fn main() {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if let [source, destination] = &args[..] {
        if let Err(error) = convert(Path::new(source), Path::new(destination)) {
            eprintln!("{error}");
            std::process::exit(1);
        }
    } else {
        std::process::exit(2);
    }
}
