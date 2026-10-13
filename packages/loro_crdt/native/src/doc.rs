use std::borrow::Cow;
use std::cmp::Ordering;
use std::ops::ControlFlow;

use loro::cursor::Cursor;
use loro::{
    CommitOptions, Container, ExpandType, ExportMode, IdSpan, Index, LoroDoc, StyleConfig, StyleConfigMap,
};

use crate::codec::{container_type_from_code, encode, parse_container_id, parse_peer, Reader, Writer};
use crate::util::{
    bytes, err_msg, free_handle, guard, handle, into_handle, str, ErrSlot, FfiError, FfiResult,
};

pub struct LoroDocHandle(pub LoroDoc);
pub struct LoroContainerHandle(pub Container);

pub unsafe fn doc<'a>(p: *const LoroDocHandle) -> FfiResult<&'a LoroDoc> {
    Ok(&handle(p)?.0)
}

pub fn new_doc(doc: LoroDoc) -> *mut LoroDocHandle {
    into_handle(LoroDocHandle(doc))
}

pub fn new_container(c: Container) -> *mut LoroContainerHandle {
    into_handle(LoroContainerHandle(c))
}

unsafe fn reader<'a>(ptr: *const u8, len: u32) -> Reader<'a> {
    Reader::new(bytes(ptr, len))
}

fn ordering_code(o: Ordering) -> i32 {
    match o {
        Ordering::Less => -1,
        Ordering::Equal => 0,
        Ordering::Greater => 1,
    }
}

pub fn write_index(w: &mut Writer, index: &Index) {
    match index {
        Index::Key(k) => {
            w.u8(0);
            w.str(k);
        }
        Index::Seq(i) => {
            w.u8(1);
            w.len(*i);
        }
        Index::Node(id) => {
            w.u8(2);
            w.tree_id(*id);
        }
    }
}

// ---------------------------------------------------------------------------
// Lifecycle

#[no_mangle]
pub extern "C" fn loro_doc_new(err: ErrSlot) -> *mut LoroDocHandle {
    guard(err, || Ok(new_doc(LoroDoc::new())))
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_from_snapshot(
    data_ptr: *const u8,
    data_len: u32,
    err: ErrSlot,
) -> *mut LoroDocHandle {
    guard(err, || {
        Ok(new_doc(LoroDoc::from_snapshot(bytes(data_ptr, data_len))?))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_free(doc: *mut LoroDocHandle) {
    free_handle(doc)
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_fork(d: *const LoroDocHandle, err: ErrSlot) -> *mut LoroDocHandle {
    guard(err, || Ok(new_doc(doc(d)?.fork())))
}

/// `frontiers`: encoded frontiers.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_fork_at(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) -> *mut LoroDocHandle {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        Ok(new_doc(doc(d)?.fork_at(&f)?))
    })
}

#[no_mangle]
pub extern "C" fn loro_version(err: ErrSlot) -> *mut u8 {
    guard(err, || Ok(encode(|w| w.str(loro::LORO_VERSION))))
}

// ---------------------------------------------------------------------------
// Configuration

#[no_mangle]
pub unsafe extern "C" fn loro_doc_peer_id(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let peer = doc(d)?.peer_id();
        Ok(encode(|w| w.peer(peer)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_peer_id(
    d: *const LoroDocHandle,
    peer_ptr: *const u8,
    peer_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_peer_id(parse_peer(str(peer_ptr, peer_len)?)?)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_record_timestamp(d: *const LoroDocHandle, record: i32, err: ErrSlot) {
    guard(err, || {
        doc(d)?.set_record_timestamp(record != 0);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_change_merge_interval(
    d: *const LoroDocHandle,
    seconds: f64,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_change_merge_interval(seconds as i64);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_detached_editing(d: *const LoroDocHandle, enable: i32, err: ErrSlot) {
    guard(err, || {
        doc(d)?.set_detached_editing(enable != 0);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_is_detached_editing_enabled(d: *const LoroDocHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(doc(d)?.is_detached_editing_enabled() as i32))
}

fn expand_from_code(code: u8) -> FfiResult<ExpandType> {
    Ok(match code {
        0 => ExpandType::Before,
        1 => ExpandType::After,
        2 => ExpandType::Both,
        3 => ExpandType::None,
        _ => return Err(err_msg(format!("invalid expand type {code}"))),
    })
}

/// `config`: `[u32 n]([str key][u8 expand])*[u8 has default][u8 expand]`,
/// expand codes 0 before, 1 after, 2 both, 3 none.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_config_text_style(
    d: *const LoroDocHandle,
    config_ptr: *const u8,
    config_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let doc = doc(d)?;
        let mut r = reader(config_ptr, config_len);
        let mut map = StyleConfigMap::new();
        for _ in 0..r.len()? {
            let key = r.str()?;
            let expand = expand_from_code(r.u8()?)?;
            map.insert(key.into(), StyleConfig { expand });
        }
        doc.config_text_style(map);
        if r.bool()? {
            let expand = expand_from_code(r.u8()?)?;
            doc.config_default_text_style(Some(StyleConfig { expand }));
        } else {
            doc.config_default_text_style(None);
        }
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_hide_empty_root_containers(
    d: *const LoroDocHandle,
    hide: i32,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_hide_empty_root_containers(hide != 0);
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// Containers

/// `kind`: container type code (see codec.rs).
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_root(
    d: *const LoroDocHandle,
    name_ptr: *const u8,
    name_len: u32,
    kind: u32,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let doc = doc(d)?;
        let name = str(name_ptr, name_len)?;
        if name.is_empty() || name.contains('/') || name.contains('\0') {
            return Err(err_msg(format!("invalid root container name {name:?}")));
        }
        let c = match container_type_from_code(kind)? {
            loro::ContainerType::Text => Container::Text(doc.get_text(name)),
            loro::ContainerType::Map => Container::Map(doc.get_map(name)),
            loro::ContainerType::List => Container::List(doc.get_list(name)),
            loro::ContainerType::MovableList => Container::MovableList(doc.get_movable_list(name)),
            loro::ContainerType::Tree => Container::Tree(doc.get_tree(name)),
            loro::ContainerType::Counter => Container::Counter(doc.get_counter(name)),
            loro::ContainerType::Unknown(_) => return Err(err_msg("unknown container type")),
        };
        Ok(new_container(c))
    })
}

/// Returns null if the container does not exist.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_container(
    d: *const LoroDocHandle,
    cid_ptr: *const u8,
    cid_len: u32,
    err: ErrSlot,
) -> *mut LoroContainerHandle {
    guard(err, || {
        let cid = parse_container_id(str(cid_ptr, cid_len)?)?;
        Ok(match doc(d)?.get_container(cid) {
            Some(c) => new_container(c),
            None => std::ptr::null_mut(),
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_has_container(
    d: *const LoroDocHandle,
    cid_ptr: *const u8,
    cid_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let cid = parse_container_id(str(cid_ptr, cid_len)?)?;
        Ok(doc(d)?.has_container(&cid) as i32)
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_delete_root_container(
    d: *const LoroDocHandle,
    cid_ptr: *const u8,
    cid_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let cid = parse_container_id(str(cid_ptr, cid_len)?)?;
        doc(d)?.delete_root_container(cid);
        Ok(())
    })
}

/// Returns `[u8 has][u32 n]([str container][index])*` from the root down.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_path_to_container(
    d: *const LoroDocHandle,
    cid_ptr: *const u8,
    cid_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let cid = parse_container_id(str(cid_ptr, cid_len)?)?;
        let path = doc(d)?.get_path_to_container(&cid);
        Ok(encode(|w| match path {
            None => w.u8(0),
            Some(path) => {
                w.u8(1);
                w.len(path.len());
                for (cid, index) in &path {
                    w.container_id(cid);
                    write_index(w, index);
                }
            }
        }))
    })
}

/// Returns a value-or-container, or the absent tag.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_by_path(
    d: *const LoroDocHandle,
    path_ptr: *const u8,
    path_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let v = doc(d)?.get_by_str_path(str(path_ptr, path_len)?);
        Ok(encode(|w| w.opt_value_or_container(v)))
    })
}

/// Returns `[u32 n](value-or-container)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_jsonpath(
    d: *const LoroDocHandle,
    path_ptr: *const u8,
    path_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let items = doc(d)?
            .jsonpath(str(path_ptr, path_len)?)
            .map_err(|e| FfiError::new("JsonPathError", e.to_string()))?;
        Ok(encode(|w| {
            w.len(items.len());
            for v in items {
                w.value_or_container(v);
            }
        }))
    })
}

// ---------------------------------------------------------------------------
// Values

#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_value(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = doc(d)?.get_value();
        Ok(encode(|w| w.value(&v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_deep_value(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = doc(d)?.get_deep_value();
        Ok(encode(|w| w.value(&v)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_deep_value_with_id(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let v = doc(d)?.get_deep_value_with_id();
        Ok(encode(|w| w.value(&v)))
    })
}

// ---------------------------------------------------------------------------
// Transactions

#[no_mangle]
pub unsafe extern "C" fn loro_doc_commit(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.commit();
        Ok(())
    })
}

/// `options`: `[opt str origin][opt str message][u8 has][f64 timestamp][u8 immediate_renew]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_commit_with(
    d: *const LoroDocHandle,
    options_ptr: *const u8,
    options_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let mut r = reader(options_ptr, options_len);
        let mut options = CommitOptions::new();
        if let Some(origin) = r.opt_str()? {
            options = options.origin(origin);
        }
        if let Some(msg) = r.opt_str()? {
            options = options.commit_msg(msg);
        }
        let has_timestamp = r.bool()?;
        let timestamp = r.f64()?;
        if has_timestamp {
            options = options.timestamp(timestamp as i64);
        }
        options = options.immediate_renew(r.bool()?);
        doc(d)?.commit_with(options);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_next_commit_message(
    d: *const LoroDocHandle,
    msg_ptr: *const u8,
    msg_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_next_commit_message(str(msg_ptr, msg_len)?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_next_commit_origin(
    d: *const LoroDocHandle,
    origin_ptr: *const u8,
    origin_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_next_commit_origin(str(origin_ptr, origin_len)?);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_set_next_commit_timestamp(
    d: *const LoroDocHandle,
    timestamp: f64,
    err: ErrSlot,
) {
    guard(err, || {
        doc(d)?.set_next_commit_timestamp(timestamp as i64);
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_clear_next_commit_options(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.clear_next_commit_options();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_pending_txn_len(d: *const LoroDocHandle, err: ErrSlot) -> u32 {
    guard(err, || Ok(doc(d)?.get_pending_txn_len() as u32))
}

// ---------------------------------------------------------------------------
// Import / export

#[no_mangle]
pub unsafe extern "C" fn loro_doc_import(
    d: *const LoroDocHandle,
    data_ptr: *const u8,
    data_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let status = doc(d)?.import(bytes(data_ptr, data_len))?;
        Ok(encode(|w| w.import_status(&status)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_import_with(
    d: *const LoroDocHandle,
    data_ptr: *const u8,
    data_len: u32,
    origin_ptr: *const u8,
    origin_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let status = doc(d)?.import_with(bytes(data_ptr, data_len), str(origin_ptr, origin_len)?)?;
        Ok(encode(|w| w.import_status(&status)))
    })
}

/// `batch`: `[u32 n]([bytes])*`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_import_batch(
    d: *const LoroDocHandle,
    batch_ptr: *const u8,
    batch_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let mut r = reader(batch_ptr, batch_len);
        let n = r.len()?;
        let mut blobs = Vec::with_capacity(n);
        for _ in 0..n {
            blobs.push(r.bytes()?.to_vec());
        }
        let status = doc(d)?.import_batch(&blobs)?;
        Ok(encode(|w| w.import_status(&status)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_import_json_updates(
    d: *const LoroDocHandle,
    json_ptr: *const u8,
    json_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let status = doc(d)?.import_json_updates(str(json_ptr, json_len)?)?;
        Ok(encode(|w| w.import_status(&status)))
    })
}

/// `range`: `[vv start][vv end]`. Returns the JSON string.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_export_json_updates(
    d: *const LoroDocHandle,
    range_ptr: *const u8,
    range_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let mut r = reader(range_ptr, range_len);
        let start = r.version_vector()?;
        let end = r.version_vector()?;
        let json = doc(d)?.export_json_updates(&start, &end);
        let s = serde_json::to_string(&json).map_err(|e| FfiError::new("JsonError", e.to_string()))?;
        Ok(encode(|w| w.str(&s)))
    })
}

/// `mode`: 0 snapshot, 1 updates `[vv from]`, 2 updates in range
/// `[u32 n]([peer][i32 start][i32 end])*`, 3 shallow snapshot `[frontiers]`,
/// 4 state only `[u8 has][frontiers]`, 5 snapshot at `[frontiers]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_export(
    d: *const LoroDocHandle,
    mode: u32,
    arg_ptr: *const u8,
    arg_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let mut r = reader(arg_ptr, arg_len);
        let mode = match mode {
            0 => ExportMode::Snapshot,
            1 => ExportMode::Updates {
                from: Cow::Owned(r.version_vector()?),
            },
            2 => {
                let n = r.len()?;
                let mut spans = Vec::with_capacity(n);
                for _ in 0..n {
                    let peer = r.peer()?;
                    let start = r.i32()?;
                    let end = r.i32()?;
                    spans.push(IdSpan::new(peer, start, end));
                }
                ExportMode::UpdatesInRange {
                    spans: Cow::Owned(spans),
                }
            }
            3 => ExportMode::ShallowSnapshot(Cow::Owned(r.frontiers()?)),
            4 => ExportMode::StateOnly(if r.bool()? {
                Some(Cow::Owned(r.frontiers()?))
            } else {
                None
            }),
            5 => ExportMode::SnapshotAt {
                version: Cow::Owned(r.frontiers()?),
            },
            m => return Err(err_msg(format!("invalid export mode {m}"))),
        };
        let data = doc(d)?.export(mode)?;
        Ok(encode(|w| w.bytes(&data)))
    })
}

/// Returns `[str mode][vv partial start][vv partial end][f64 start ts]
/// [frontiers start][f64 end ts][u32 change count]`.
#[no_mangle]
pub unsafe extern "C" fn loro_decode_import_blob_meta(
    data_ptr: *const u8,
    data_len: u32,
    check_checksum: i32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let meta = LoroDoc::decode_import_blob_meta(bytes(data_ptr, data_len), check_checksum != 0)?;
        Ok(encode(|w| {
            w.str(&format!("{:?}", meta.mode));
            w.version_vector(&meta.partial_start_vv);
            w.version_vector(&meta.partial_end_vv);
            w.f64(meta.start_timestamp as f64);
            w.frontiers(&meta.start_frontiers);
            w.f64(meta.end_timestamp as f64);
            w.u32(meta.change_num);
        }))
    })
}

// ---------------------------------------------------------------------------
// Versions

#[no_mangle]
pub unsafe extern "C" fn loro_doc_oplog_vv(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let vv = doc(d)?.oplog_vv();
        Ok(encode(|w| w.version_vector(&vv)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_state_vv(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let vv = doc(d)?.state_vv();
        Ok(encode(|w| w.version_vector(&vv)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_shallow_since_vv(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let vv = doc(d)?.shallow_since_vv().to_vv();
        Ok(encode(|w| w.version_vector(&vv)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_oplog_frontiers(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let f = doc(d)?.oplog_frontiers();
        Ok(encode(|w| w.frontiers(&f)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_state_frontiers(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let f = doc(d)?.state_frontiers();
        Ok(encode(|w| w.frontiers(&f)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_shallow_since_frontiers(d: *const LoroDocHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let f = doc(d)?.shallow_since_frontiers();
        Ok(encode(|w| w.frontiers(&f)))
    })
}

/// Returns `[u8 has][vv]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_frontiers_to_vv(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        let vv = doc(d)?.frontiers_to_vv(&f);
        Ok(encode(|w| match vv {
            Some(vv) => {
                w.u8(1);
                w.version_vector(&vv);
            }
            None => w.u8(0),
        }))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_vv_to_frontiers(
    d: *const LoroDocHandle,
    vv_ptr: *const u8,
    vv_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let vv = reader(vv_ptr, vv_len).version_vector()?;
        let f = doc(d)?.vv_to_frontiers(&vv);
        Ok(encode(|w| w.frontiers(&f)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_minimize_frontiers(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        let min = doc(d)?
            .minimize_frontiers(&f)
            .map_err(|id| FfiError::new("NotFound", format!("id {id} is not in the document")))?;
        Ok(encode(|w| w.frontiers(&min)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_cmp_with_frontiers(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        Ok(ordering_code(doc(d)?.cmp_with_frontiers(&f)))
    })
}

/// `pair`: `[frontiers a][frontiers b]`. Returns -1, 0, 1, or 2 if concurrent.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_cmp_frontiers(
    d: *const LoroDocHandle,
    pair_ptr: *const u8,
    pair_len: u32,
    err: ErrSlot,
) -> i32 {
    guard(err, || {
        let mut r = reader(pair_ptr, pair_len);
        let a = r.frontiers()?;
        let b = r.frontiers()?;
        let cmp = doc(d)?.cmp_frontiers(&a, &b).map_err(|_| {
            FfiError::new(
                "FrontiersNotIncluded",
                "frontiers are not included in the document",
            )
        })?;
        Ok(match cmp {
            Some(o) => ordering_code(o),
            None => 2,
        })
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_len_ops(d: *const LoroDocHandle, err: ErrSlot) -> u32 {
    guard(err, || Ok(doc(d)?.len_ops() as u32))
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_len_changes(d: *const LoroDocHandle, err: ErrSlot) -> u32 {
    guard(err, || Ok(doc(d)?.len_changes() as u32))
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_is_shallow(d: *const LoroDocHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(doc(d)?.is_shallow() as i32))
}

// ---------------------------------------------------------------------------
// Time travel

#[no_mangle]
pub unsafe extern "C" fn loro_doc_checkout(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        doc(d)?.checkout(&f)?;
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_checkout_to_latest(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.checkout_to_latest();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_attach(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.attach();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_detach(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.detach();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_is_detached(d: *const LoroDocHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(doc(d)?.is_detached() as i32))
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_revert_to(
    d: *const LoroDocHandle,
    frontiers_ptr: *const u8,
    frontiers_len: u32,
    err: ErrSlot,
) {
    guard(err, || {
        let f = reader(frontiers_ptr, frontiers_len).frontiers()?;
        doc(d)?.revert_to(&f)?;
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// History

/// `id`: encoded id. Returns `[u8 has][change meta]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_change(
    d: *const LoroDocHandle,
    id_ptr: *const u8,
    id_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let id = reader(id_ptr, id_len).id()?;
        let change = doc(d)?.get_change(id);
        Ok(encode(|w| match change {
            Some(c) => {
                w.u8(1);
                w.change_meta(&c);
            }
            None => w.u8(0),
        }))
    })
}

/// `ids`: `[u32 n](id)*`. Returns every ancestor change (including the
/// changes containing `ids`), newest first: `[u32 n](change meta)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_change_ancestors(
    d: *const LoroDocHandle,
    ids_ptr: *const u8,
    ids_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let mut r = reader(ids_ptr, ids_len);
        let n = r.len()?;
        let mut ids = Vec::with_capacity(n);
        for _ in 0..n {
            ids.push(r.id()?);
        }
        let mut changes = Vec::new();
        doc(d)?
            .travel_change_ancestors(&ids, &mut |meta| {
                changes.push(meta);
                ControlFlow::Continue(())
            })
            .map_err(|e| FfiError::new("ChangeTravelError", e.to_string()))?;
        Ok(encode(|w| {
            w.len(changes.len());
            for c in &changes {
                w.change_meta(c);
            }
        }))
    })
}

/// `id`: encoded id. Returns `[u32 n](str container id)*`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_changed_containers_in(
    d: *const LoroDocHandle,
    id_ptr: *const u8,
    id_len: u32,
    len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let id = reader(id_ptr, id_len).id()?;
        let mut cids: Vec<String> = doc(d)?
            .get_changed_containers_in(id, len as usize)
            .into_iter()
            .map(|c| c.to_string())
            .collect();
        cids.sort_unstable();
        Ok(encode(|w| {
            w.len(cids.len());
            for c in &cids {
                w.str(c);
            }
        }))
    })
}

// ---------------------------------------------------------------------------
// Cursors

/// `cursor`: bytes from `Cursor::encode`. Returns
/// `[u8 has update][cursor]?[u32 pos][i32 side]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_get_cursor_pos(
    d: *const LoroDocHandle,
    cursor_ptr: *const u8,
    cursor_len: u32,
    err: ErrSlot,
) -> *mut u8 {
    guard(err, || {
        let cursor = Cursor::decode(bytes(cursor_ptr, cursor_len))
            .map_err(|e| FfiError::new("DecodeError", e.to_string()))?;
        let res = doc(d)?.get_cursor_pos(&cursor)?;
        Ok(encode(|w| {
            match &res.update {
                Some(c) => {
                    w.u8(1);
                    w.cursor(c);
                }
                None => w.u8(0),
            }
            w.len(res.current.pos);
            w.i32(res.current.side as i32);
        }))
    })
}

/// Decodes `Cursor::encode` bytes into `[cursor]` (see `Writer::cursor`).
#[no_mangle]
pub unsafe extern "C" fn loro_cursor_decode(cursor_ptr: *const u8, cursor_len: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let cursor = Cursor::decode(bytes(cursor_ptr, cursor_len))
            .map_err(|e| FfiError::new("DecodeError", e.to_string()))?;
        Ok(encode(|w| w.cursor(&cursor)))
    })
}

// ---------------------------------------------------------------------------
// Maintenance

#[no_mangle]
pub unsafe extern "C" fn loro_doc_compact_change_store(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.compact_change_store();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_free_history_cache(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.free_history_cache();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_free_diff_calculator(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.free_diff_calculator();
        Ok(())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_has_history_cache(d: *const LoroDocHandle, err: ErrSlot) -> i32 {
    guard(err, || Ok(doc(d)?.has_history_cache() as i32))
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_check_state_correctness(d: *const LoroDocHandle, err: ErrSlot) {
    guard(err, || {
        doc(d)?.check_state_correctness_slow();
        Ok(())
    })
}

// ---------------------------------------------------------------------------
// Version encodings shared with other Loro bindings

#[no_mangle]
pub unsafe extern "C" fn loro_vv_encode(vv_ptr: *const u8, vv_len: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let vv = reader(vv_ptr, vv_len).version_vector()?;
        Ok(encode(|w| w.bytes(&vv.encode())))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_vv_decode(data_ptr: *const u8, data_len: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let vv = loro::VersionVector::decode(bytes(data_ptr, data_len))?;
        Ok(encode(|w| w.version_vector(&vv)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_frontiers_encode(f_ptr: *const u8, f_len: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let f = reader(f_ptr, f_len).frontiers()?;
        Ok(encode(|w| w.bytes(&f.encode())))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_frontiers_decode(data_ptr: *const u8, data_len: u32, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let f = loro::Frontiers::decode(bytes(data_ptr, data_len))?;
        Ok(encode(|w| w.frontiers(&f)))
    })
}
