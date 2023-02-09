/* qem-unzip
 *
 * (c) 2023 Graeme Gregory
 *
 * SPDX: Zlib
 */

use std::fs;
use std::io;
use std::io::Write;
use std::path::Path;
use packed_struct::prelude::*;
use zip::read::ZipFile;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Args {
    /// directory to extract to
    #[arg(short = 'd')]
    directory: String,

    /// escpae the filenames sQLux/Q-Emulator style
    #[arg(short = 'e')]
    escape: bool,

    file: String
}

#[derive(PackedStruct)]
pub struct QdosHeader {
    #[packed_field(endian="msb")]
    f_length: i32,
    f_access: u8,
    f_type: u8,
    #[packed_field(endian="msb")]
    f_datalen: i32,
    #[packed_field(endian="msb")]
    f_reserved: i32,
    #[packed_field(endian="msb")]
    f_szname: i16,
    f_name: [u8; 36],
    #[packed_field(endian="msb")]
    f_update: i32,
    #[packed_field(endian="msb")]
    f_refdate: i32,
    #[packed_field(endian="msb")]
    f_backup: i32
}

#[derive(PackedStruct)]
pub struct QemuHeader {
    h_header: [u8; 18],
    h_res: u8,
    h_wordlen: u8,
    f_access: u8,
    f_type: u8,
    #[packed_field(endian="msb")]
    f_datalen: i32,
    #[packed_field(endian="msb")]
    f_res: u32,
}

fn main() {
    std::process::exit(real_main());
}

fn escape_filename(name: &mut String) {
        let mut l = name.len();

        if l > 36 {
                name.truncate(36);
                l = 36;
        }

        /* if there is no name */
        if l == 0 {
            name.insert_str(0, "-noname-");
            return;
        }

        let name_und = name.replace(".", "_");
        name.clear();
        name.insert_str(0, &name_und);

        /* Check for invalid char */
        let mut escape: bool = false;
        for c in name.chars() {
            let c_val = c as u32;
            if (c_val < 34) || (c == ':') || (c_val > 127) {
                escape = true;
            }
        }

        if !escape {
            return;
        }
        
        /* if we get here, there is a incompatible char are we encode */
        let mut i: usize = 0;
        let mut newname: String = String::from("-noASCII-");
        let mut last_ascii: bool = false;
        loop {
            let c = name.chars().nth(i).unwrap();
            let c_val = c as u32;

            if (c_val < 34) || (c == ':') || (c_val > 127) {
                if i > 0 {
                    newname.push(' ');
                }

                newname.push_str(&*format!("{:X}", c_val));

                last_ascii = false;
            } else {
                if !last_ascii {
                    newname.push('!');
                    last_ascii = true;
                }
                newname.push(c);
            }

            i += 1;

            /* at the end */
            if i == l {
                break;
            }
        }

        name.clear();
        name.insert_str(0, &newname);
}

fn find_header(file: &ZipFile) -> Option<QdosHeader> {
    let extra_info = file.extra_data();
    if !extra_info.is_empty() {
        if extra_info[0] == 0x4A && extra_info[1] == 0xFB {
            let size: i32 = i32::from(extra_info[2]) |
                i32::from(extra_info[3]) << 8;
            if size != 72 {
                println!("WARNING: Invalid QDOS Header size: {}", size);
                None
            } else {
                let header_raw = &extra_info[12..76];
                Some(QdosHeader::unpack_from_slice(header_raw).unwrap())
            }
        } else {
            None
        }
    } else {
        None
    }
}

fn real_main() -> i32 {
    let args = Args::parse();

    let file = fs::File::open(args.file).unwrap();
    let mut archive = zip::ZipArchive::new(file).unwrap();

    if !args.directory.is_empty() {
        let path = Path::new(&args.directory);
        fs::create_dir_all(&path).unwrap();
    }

    for i in 0..archive.len() {
        let mut file = archive.by_index(i).unwrap();

        let qdos_header_opt = find_header(&file);
        let mut qdos_datalen: i32 = 0;
        let mut qdos_access: u8 = 0;
        let mut qdos_type: u8 = 0;

        if qdos_header_opt.is_some() {
            let qdos_header = qdos_header_opt.unwrap();

            qdos_datalen = qdos_header.f_datalen;
            qdos_access = qdos_header.f_access;
            qdos_type = qdos_header.f_type;

            if file.size() != u64::try_from(qdos_header.f_length).unwrap() {
                println!("  WARNING: qdos/zip file size mismatch zip: {} qdos: {}",
                         file.size(), qdos_header.f_length);
            }
        }

        if (*file.name()).ends_with('/') {
            println!("WARNING: No directory support: {}", file.name());
        } else {
            let mut name = file.name().replace("/", "_");

            if args.escape {
                escape_filename(&mut name);
            }

            if !args.directory.is_empty() {
                name.insert(0, '/');
                name.insert_str(0, &args.directory);
            }

            println!("Extracting: {}", name);

            let outpath = Path::new(&name);
            let mut outfile = fs::File::create(&outpath).unwrap();

            if (qdos_datalen > 0) || (qdos_access > 0) || (qdos_type > 0) {
                let qemu_header = QemuHeader {
                    h_header: "]!QDOS File Header".as_bytes().try_into().unwrap(),
                    h_res: 0,
                    h_wordlen: 15,
                    f_access: qdos_access,
                    f_type: qdos_type,
                    f_datalen: qdos_datalen,
                    f_res: 0,
                };

                let res = outfile.write(&qemu_header.pack().unwrap());
                let written = match res {
                    Ok(number)  => number,
                    Err(_e) => 0,
                };
                if written != 30 {
                    println!("WARNING: error writing header to file");
                }
            }

            io::copy(&mut file, &mut outfile).unwrap();
        }
    }

    0
}
