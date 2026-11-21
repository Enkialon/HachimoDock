//! Actual status and mode-14 clients over loopback, with a paired fixture receiver.
use super::*;
use crate::lan_agent::{confirmation_tests::accept, nonce, session_key, DEVICE_STATUS};
use crate::usb_serial::center_thumb;
use std::{
    collections::BTreeMap,
    io::Read,
    net::TcpListener,
    sync::atomic::{AtomicU64, Ordering},
    sync::Arc,
};
use zeroize::Zeroizing;

const TOKEN: [u8; 16] = [0x58; 16];
const BOOT: &str = "ca1100fe00000001";
const BOARD: &str = "p4-010203040506";

fn hello(
    listener: &TcpListener,
    mode: u8,
    body: &[u8],
    reply: &[u8],
) -> (TcpStream, aead::LessSafeKey) {
    let mut socket = accept(listener);
    socket.set_nodelay(true).unwrap();
    let mut client = [0; 16];
    socket.read_exact(&mut client).unwrap();
    let server = [mode; 16];
    socket.write_all(&server).unwrap();
    let key = session_key(&TOKEN, &client, &server);
    let mut header = [0; 3];
    socket.read_exact(&mut header).unwrap();
    assert_eq!(header, [mode, 0, body.len() as u8]);
    let mut incoming = vec![0; body.len() + 16];
    socket.read_exact(&mut incoming).unwrap();
    assert_eq!(
        key.open_in_place(nonce(0), aead::Aad::from(header), &mut incoming)
            .unwrap(),
        body
    );
    let length = (reply.len() as u16).to_be_bytes();
    let mut ack = reply.to_vec();
    let aad = [mode, header[1], header[2], length[0], length[1]];
    key.seal_in_place_append_tag(nonce(1), aead::Aad::from(aad), &mut ack)
        .unwrap();
    socket.write_all(&length).unwrap();
    socket.write_all(&ack).unwrap();
    (socket, key)
}

fn status_reply(listener: &TcpListener, thumbnail: bool) {
    let status = serde_json::json!({"firmware":"fixture","boardDeviceId":BOARD,"bootId":BOOT,
        "wifiConnected":true,"clockSynchronized":true,"httpsSuccesses":0,"httpsFailures":0,
        "controlTrusted":true,"componentDelivery":true,"componentBundle":true,"ops":true,
        "rtcKey":if thumbnail {32} else {0}});
    hello(listener, DEVICE_STATUS, &[1], status.to_string().as_bytes());
}

type Files = BTreeMap<String, Vec<u8>>;

// Parse the records on the receiving socket independently of the sender's builders.
// Cap every socket read at 512 bytes, including the 1,568-byte thumbnail.
fn receive(
    listener: &TcpListener,
    opcode: u8,
    id: &str,
    stop: Option<&AtomicU64>,
) -> Option<Files> {
    let (mut socket, key) = hello(listener, MODE, BOOT.as_bytes(), &[1]);
    let mut files = Files::new();
    let mut digest = [0; 32];
    let mut file_count = 0;
    let mut total = 0;
    let mut active_path = String::new();
    let mut expected_offset = 0;
    let mut expected_index = 0;
    for sequence in 0..MAX_RECORDS {
        let mut length = [0; 2];
        socket.read_exact(&mut length).unwrap();
        let size = u16::from_be_bytes(length) as usize;
        assert!((1..=4096 + 107).contains(&size));
        let mut encrypted = vec![0; size + 16];
        for part in encrypted.chunks_mut(512) {
            socket.read_exact(part).unwrap();
        }
        let record = key
            .open_in_place(
                record_nonce(2, sequence),
                aead::Aad::from(length),
                &mut encrypted,
            )
            .unwrap();
        if sequence == 0 {
            assert_eq!(record[0], opcode);
            assert_eq!(record[1] as usize, id.len());
            assert_eq!(&record[39..], id.as_bytes());
            file_count = record[2] as usize;
            total = u32::from_be_bytes(record[3..7].try_into().unwrap()) as usize;
            digest.copy_from_slice(&record[7..39]);
            if opcode == 6 {
                assert_eq!((file_count, total), (2, 1600));
            }
        } else if record == [3] {
            assert_eq!(expected_offset, 0);
            assert_eq!(files.len(), file_count);
            assert_eq!(files.values().map(Vec::len).sum::<usize>(), total);
            let mut hash = Sha256::new();
            for (name, bytes) in &files {
                hash.update(name.as_bytes());
                hash.update([0]);
                hash.update((bytes.len() as u32).to_le_bytes());
                hash.update(bytes);
            }
            assert_eq!(hash.finalize()[..], digest);
        } else {
            assert_eq!(record[0], 2);
            assert_eq!(record[1] as usize, expected_index);
            let offset = u32::from_be_bytes(record[2..6].try_into().unwrap()) as usize;
            let file_bytes = u32::from_be_bytes(record[6..10].try_into().unwrap()) as usize;
            let end = 11 + record[10] as usize;
            let path = std::str::from_utf8(&record[11..end]).unwrap();
            let bytes = &record[end..];
            assert_eq!(offset, expected_offset);
            assert_eq!(bytes.len(), (file_bytes - offset).min(4096));
            if offset == 0 {
                assert!(path > active_path.as_str());
                active_path = path.to_owned();
            } else {
                assert_eq!(path, active_path);
            }
            files
                .entry(path.to_owned())
                .or_default()
                .extend_from_slice(bytes);
            expected_offset += bytes.len();
            if expected_offset == file_bytes {
                expected_index += 1;
                expected_offset = 0;
            }
            if path == center_thumb::PATH {
                assert_eq!((offset, bytes.len(), file_bytes), (0, 1568, 1568));
                if let Some(revision) = stop {
                    revision.fetch_add(1, Ordering::Release);
                }
            }
        }
        let mut ack = vec![1];
        key.seal_in_place_append_tag(record_nonce(3, sequence), aead::Aad::from([0, 1]), &mut ack)
            .unwrap();
        socket.write_all(&[0, 1]).unwrap();
        socket.write_all(&ack).unwrap();
        if stop.is_some_and(|rev| rev.load(Ordering::Acquire) != 1) {
            assert_eq!(
                socket.read(&mut [0]).unwrap(),
                0,
                "must close before commit"
            );
            return None;
        }
        if record == [3] {
            return Some(files);
        }
    }
    panic!("transaction did not terminate")
}

#[test]
fn center_thumb_authenticated_install_repair_legacy_and_pairing_change() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../builtin-clawpkgs/wasm-2046");
    let pkg = Package::read(&root).unwrap();
    let id = pkg.preview.id.as_str();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let peer = Peer {
        address: listener.local_addr().unwrap(),
        key: Zeroizing::new(TOKEN),
    };
    let revision = Arc::new(AtomicU64::new(1));
    let revoked = revision.clone();
    let worker = std::thread::spawn(move || {
        status_reply(&listener, true);
        let mut installed = receive(&listener, 1, "wasm-2046", None).unwrap();
        assert!(installed["runtime/app.wasm"].len() > 4096);
        assert!(installed.contains_key("runtime/center-title.rle"));
        let cover = installed.remove(center_thumb::PATH).unwrap();
        let prior = installed.clone();
        let repair = receive(&listener, 6, "wasm-2046", None).unwrap();
        assert_eq!(
            repair.keys().map(String::as_str).collect::<Vec<_>>(),
            [center_thumb::MATCH, center_thumb::PATH]
        );
        assert_eq!(
            repair[center_thumb::MATCH],
            Sha256::digest(&installed["runtime/widget.json"])[..]
        );
        assert_eq!(repair[center_thumb::PATH], cover);
        assert_eq!(installed, prior);
        assert!(receive(&listener, 6, "wasm-2046", Some(&revoked)).is_none());
        status_reply(&listener, false);
        let old = receive(&listener, 1, "wasm-2046", None).unwrap();
        assert_eq!(old, prior);
        assert_eq!(
            listener.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    });
    let binding = ComponentPairing::bind(&peer, Some(&peer), 1).unwrap();
    let current = || binding.current(revision.load(Ordering::Acquire));
    let status = query_status(&peer).unwrap();
    require_thumbnail_target(&status, BOARD, BOOT).unwrap();
    assert!(require_thumbnail_target(&status, BOARD, "different").is_err());
    assert!(require_thumbnail_target(&status, "different", BOOT).is_err());
    let title: ComponentCenterTitle =
        serde_json::from_value(serde_json::json!({"text":"2046","data":"AQIDBA=="})).unwrap();
    let full = pkg
        .prepare(
            &HashMap::new(),
            Some(&title),
            status.component_bundle && status.center_thumb,
        )
        .unwrap();
    install_bundle(&peer, BOOT, id, &full, None, current).unwrap();
    let repair = center_thumb::repair_files(&pkg.stage.path().join("package"), &root, id).unwrap();
    install_bundle(&peer, BOOT, id, &repair, None, current).unwrap();
    assert!(install_bundle(&peer, BOOT, id, &repair, None, current)
        .unwrap_err()
        .contains("配对已变化"));
    let old_status = query_status(&peer).unwrap();
    assert!(require_thumbnail_target(&old_status, BOARD, BOOT).is_err());
    let old = pkg
        .prepare(
            &HashMap::new(),
            Some(&title),
            old_status.component_bundle && old_status.center_thumb,
        )
        .unwrap();
    let next = ComponentPairing::bind(&peer, Some(&peer), 2).unwrap();
    install_bundle(&peer, BOOT, id, &old, None, || {
        next.current(revision.load(Ordering::Acquire))
    })
    .unwrap();
    for changed in [
        Peer {
            key: Zeroizing::new([0x95; 16]),
            ..peer.clone()
        },
        Peer {
            address: "127.0.0.1:1".parse().unwrap(),
            ..peer.clone()
        },
    ] {
        assert!(ComponentPairing::bind(&peer, Some(&changed), 2).is_err());
    }
    assert!(ComponentPairing::bind(&peer, None, 2).is_err());
    assert_eq!(peer.key.as_ref(), TOKEN);
    worker.join().unwrap();
}
