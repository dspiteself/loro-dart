//! Compact little-endian binary encoding shared with `lib/src/codec.dart`.
//!
//! Scalars: `u8`, `u32`, `i32`, `f64` and `i64` (8 bytes LE). Strings and byte
//! arrays are `[u32 len][bytes]`. Peer ids are written as decimal strings
//! because dart2js cannot represent every `u64`.
//!
//! Values are tag-prefixed, see the `TAG_*` constants.

use loro::cursor::{Cursor, Side};
use loro::{
    ChangeMeta, Container, ContainerID, ContainerType, Frontiers, ImportStatus, LoroValue, PeerID, TextDelta,
    TreeID, TreeParentId, ValueOrContainer, VersionRange, VersionVector, ID,
};
use rustc_hash::FxHashMap;

use crate::doc::LoroContainerHandle;
use crate::util::{err_msg, FfiResult};

pub(crate) const TAG_NULL: u8 = 0;
pub(crate) const TAG_FALSE: u8 = 1;
pub(crate) const TAG_TRUE: u8 = 2;
pub(crate) const TAG_I64: u8 = 3;
pub(crate) const TAG_F64: u8 = 4;
pub(crate) const TAG_STRING: u8 = 5;
pub(crate) const TAG_BINARY: u8 = 6;
pub(crate) const TAG_LIST: u8 = 7;
pub(crate) const TAG_MAP: u8 = 8;
/// A container referenced by id inside a plain value (`[str container id]`).
pub(crate) const TAG_CONTAINER_ID: u8 = 9;
/// A live container handle (`[u8 type][u32 lo][u32 hi]` address). The reader
/// takes ownership and must free it with `loro_container_free`.
pub(crate) const TAG_CONTAINER: u8 = 10;
/// Marks a missing value (`Option::None`), distinct from `null`.
pub(crate) const TAG_ABSENT: u8 = 11;

pub struct Writer {
    buf: Vec<u8>,
    /// Container handles written into `buf`, owned by whoever decodes it.
    handles: Vec<usize>,
}

impl Writer {
    pub fn new() -> Self {
        Self {
            buf: vec![0; 4],
            handles: Vec::new(),
        }
    }

    pub fn u8(&mut self, v: u8) {
        self.buf.push(v);
    }

    pub fn bool(&mut self, v: bool) {
        self.buf.push(v as u8);
    }

    pub fn u32(&mut self, v: u32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn len(&mut self, v: usize) {
        self.u32(v as u32);
    }

    pub fn i32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn f64(&mut self, v: f64) {
        self.buf.extend_from_slice(&v.to_le_bytes());
    }

    pub fn bytes(&mut self, v: &[u8]) {
        self.len(v.len());
        self.buf.extend_from_slice(v);
    }

    pub fn str(&mut self, v: &str) {
        self.bytes(v.as_bytes());
    }

    pub fn opt_str(&mut self, v: Option<&str>) {
        match v {
            Some(s) => {
                self.u8(1);
                self.str(s);
            }
            None => self.u8(0),
        }
    }

    pub fn peer(&mut self, peer: PeerID) {
        self.str(&peer.to_string());
    }

    pub fn id(&mut self, id: ID) {
        self.peer(id.peer);
        self.i32(id.counter);
    }

    pub fn frontiers(&mut self, f: &Frontiers) {
        self.len(f.len());
        for id in f.iter() {
            self.id(id);
        }
    }

    pub fn version_vector(&mut self, vv: &VersionVector) {
        let mut entries: Vec<_> = vv.iter().map(|(p, c)| (*p, *c)).collect();
        entries.sort_unstable();
        self.len(entries.len());
        for (peer, counter) in entries {
            self.peer(peer);
            self.i32(counter);
        }
    }

    pub fn container_id(&mut self, cid: &ContainerID) {
        self.str(&cid.to_string());
    }

    pub fn value(&mut self, v: &LoroValue) {
        match v {
            LoroValue::Null => self.u8(TAG_NULL),
            LoroValue::Bool(false) => self.u8(TAG_FALSE),
            LoroValue::Bool(true) => self.u8(TAG_TRUE),
            LoroValue::I64(i) => {
                self.u8(TAG_I64);
                self.i64(*i);
            }
            LoroValue::Double(d) => {
                self.u8(TAG_F64);
                self.f64(*d);
            }
            LoroValue::String(s) => {
                self.u8(TAG_STRING);
                self.str(s);
            }
            LoroValue::Binary(b) => {
                self.u8(TAG_BINARY);
                self.bytes(b);
            }
            LoroValue::List(list) => {
                self.u8(TAG_LIST);
                self.len(list.len());
                for item in list.iter() {
                    self.value(item);
                }
            }
            LoroValue::Map(map) => {
                self.u8(TAG_MAP);
                let mut entries: Vec<_> = map.iter().collect();
                entries.sort_unstable_by(|a, b| a.0.cmp(b.0));
                self.len(entries.len());
                for (k, v) in entries {
                    self.str(k);
                    self.value(v);
                }
            }
            LoroValue::Container(cid) => {
                self.u8(TAG_CONTAINER_ID);
                self.container_id(cid);
            }
        }
    }

    pub fn container(&mut self, c: Container) {
        self.u8(TAG_CONTAINER);
        self.u8(container_type_code(c.get_type()));
        let addr = crate::util::into_handle(LoroContainerHandle(c)) as usize;
        self.handles.push(addr);
        let addr = addr as u64;
        self.u32(addr as u32);
        self.u32((addr >> 32) as u32);
    }

    pub fn value_or_container(&mut self, v: ValueOrContainer) {
        match v {
            ValueOrContainer::Value(v) => self.value(&v),
            ValueOrContainer::Container(c) => self.container(c),
        }
    }

    pub fn opt_value_or_container(&mut self, v: Option<ValueOrContainer>) {
        match v {
            Some(v) => self.value_or_container(v),
            None => self.u8(TAG_ABSENT),
        }
    }

    pub fn opt_peer(&mut self, peer: Option<PeerID>) {
        match peer {
            Some(p) => {
                self.u8(1);
                self.peer(p);
            }
            None => self.u8(0),
        }
    }

    pub fn opt_id(&mut self, id: Option<ID>) {
        match id {
            Some(id) => {
                self.u8(1);
                self.id(id);
            }
            None => self.u8(0),
        }
    }

    pub fn tree_id(&mut self, id: TreeID) {
        self.peer(id.peer);
        self.i32(id.counter);
    }

    /// `[u8 kind]` then the node id for `kind == 0`. Kinds: 0 node, 1 root,
    /// 2 deleted, 3 nonexistent.
    pub fn tree_parent(&mut self, p: TreeParentId) {
        match p {
            TreeParentId::Node(id) => {
                self.u8(0);
                self.tree_id(id);
            }
            TreeParentId::Root => self.u8(1),
            TreeParentId::Deleted => self.u8(2),
            TreeParentId::Unexist => self.u8(3),
        }
    }

    pub fn attributes(&mut self, attrs: &Option<FxHashMap<String, LoroValue>>) {
        match attrs {
            None => self.u8(0),
            Some(map) => {
                self.u8(1);
                let mut entries: Vec<_> = map.iter().collect();
                entries.sort_unstable_by(|a, b| a.0.cmp(b.0));
                self.len(entries.len());
                for (k, v) in entries {
                    self.str(k);
                    self.value(v);
                }
            }
        }
    }

    /// `[u8 kind]`: 0 insert `[str][attrs]`, 1 delete `[u32]`, 2 retain
    /// `[u32][attrs]`. Lengths are UTF-16 code units.
    pub fn text_delta(&mut self, d: &TextDelta) {
        match d {
            TextDelta::Insert { insert, attributes } => {
                self.u8(0);
                self.str(insert);
                self.attributes(attributes);
            }
            TextDelta::Delete { delete } => {
                self.u8(1);
                self.len(*delete);
            }
            TextDelta::Retain { retain, attributes } => {
                self.u8(2);
                self.len(*retain);
                self.attributes(attributes);
            }
        }
    }

    pub fn text_deltas(&mut self, deltas: &[TextDelta]) {
        self.len(deltas.len());
        for d in deltas {
            self.text_delta(d);
        }
    }

    pub fn change_meta(&mut self, c: &ChangeMeta) {
        self.u32(c.lamport);
        self.id(c.id);
        self.f64(c.timestamp as f64);
        self.opt_str(c.message.as_deref());
        self.frontiers(&c.deps);
        self.len(c.len);
    }

    pub fn version_range(&mut self, r: &VersionRange) {
        let mut entries: Vec<_> = r.iter().map(|(p, span)| (*p, *span)).collect();
        entries.sort_unstable();
        self.len(entries.len());
        for (peer, (start, end)) in entries {
            self.peer(peer);
            self.i32(start);
            self.i32(end);
        }
    }

    pub fn import_status(&mut self, s: &ImportStatus) {
        self.version_range(&s.success);
        match &s.pending {
            Some(p) => {
                self.u8(1);
                self.version_range(p);
            }
            None => self.u8(0),
        }
    }

    /// `[bytes encoded][str container][i32 side][opt id]`.
    pub fn cursor(&mut self, c: &Cursor) {
        self.bytes(&c.encode());
        self.container_id(&c.container);
        self.i32(c.side as i32);
        self.opt_id(c.id);
    }

    /// Converts into an owned `[u32 len][payload]` buffer for the caller.
    pub fn finish(self) -> *mut u8 {
        Box::into_raw(self.finish_boxed().0) as *mut u8
    }

    /// Like [`Writer::finish`], keeping the buffer on the Rust side for now.
    /// Also returns the container handles embedded in it, which must be freed
    /// if the buffer is discarded instead of handed to the caller.
    pub fn finish_boxed(mut self) -> (Box<[u8]>, Vec<usize>) {
        let len = (self.buf.len() - 4) as u32;
        self.buf[..4].copy_from_slice(&len.to_le_bytes());
        (self.buf.into_boxed_slice(), self.handles)
    }
}

pub fn container_type_code(t: ContainerType) -> u8 {
    match t {
        ContainerType::Text => 0,
        ContainerType::Map => 1,
        ContainerType::List => 2,
        ContainerType::MovableList => 3,
        ContainerType::Tree => 4,
        ContainerType::Counter => 5,
        ContainerType::Unknown(_) => 6,
    }
}

pub fn container_type_from_code(code: u32) -> FfiResult<ContainerType> {
    Ok(match code {
        0 => ContainerType::Text,
        1 => ContainerType::Map,
        2 => ContainerType::List,
        3 => ContainerType::MovableList,
        4 => ContainerType::Tree,
        5 => ContainerType::Counter,
        _ => return Err(err_msg(format!("unknown container type {code}"))),
    })
}

/// Encodes a whole buffer with a single closure, the common case for outputs.
pub fn encode(f: impl FnOnce(&mut Writer)) -> *mut u8 {
    let mut w = Writer::new();
    f(&mut w);
    w.finish()
}

pub struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }

    fn take(&mut self, n: usize) -> FfiResult<&'a [u8]> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|end| *end <= self.buf.len())
            .ok_or_else(|| err_msg("truncated input"))?;
        let out = &self.buf[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    pub fn u8(&mut self) -> FfiResult<u8> {
        Ok(self.take(1)?[0])
    }

    pub fn bool(&mut self) -> FfiResult<bool> {
        Ok(self.u8()? != 0)
    }

    pub fn u32(&mut self) -> FfiResult<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn len(&mut self) -> FfiResult<usize> {
        Ok(self.u32()? as usize)
    }

    pub fn i32(&mut self) -> FfiResult<i32> {
        Ok(i32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn i64(&mut self) -> FfiResult<i64> {
        Ok(i64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    pub fn f64(&mut self) -> FfiResult<f64> {
        Ok(f64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    pub fn bytes(&mut self) -> FfiResult<&'a [u8]> {
        let n = self.len()?;
        self.take(n)
    }

    pub fn str(&mut self) -> FfiResult<&'a str> {
        std::str::from_utf8(self.bytes()?).map_err(err_msg)
    }

    pub fn opt_str(&mut self) -> FfiResult<Option<&'a str>> {
        Ok(if self.bool()? { Some(self.str()?) } else { None })
    }

    pub fn peer(&mut self) -> FfiResult<PeerID> {
        parse_peer(self.str()?)
    }

    pub fn id(&mut self) -> FfiResult<ID> {
        let peer = self.peer()?;
        let counter = self.i32()?;
        Ok(ID::new(peer, counter))
    }

    pub fn frontiers(&mut self) -> FfiResult<Frontiers> {
        let n = self.len()?;
        let mut ids = Vec::with_capacity(n);
        for _ in 0..n {
            ids.push(self.id()?);
        }
        Ok(Frontiers::from(ids))
    }

    pub fn version_vector(&mut self) -> FfiResult<VersionVector> {
        let n = self.len()?;
        let mut vv = VersionVector::new();
        for _ in 0..n {
            let peer = self.peer()?;
            let counter = self.i32()?;
            vv.insert(peer, counter);
        }
        Ok(vv)
    }

    pub fn container_id(&mut self) -> FfiResult<ContainerID> {
        parse_container_id(self.str()?)
    }

    pub fn value(&mut self) -> FfiResult<LoroValue> {
        Ok(match self.u8()? {
            TAG_NULL => LoroValue::Null,
            TAG_FALSE => LoroValue::Bool(false),
            TAG_TRUE => LoroValue::Bool(true),
            TAG_I64 => LoroValue::I64(self.i64()?),
            TAG_F64 => LoroValue::Double(self.f64()?),
            TAG_STRING => LoroValue::from(self.str()?),
            TAG_BINARY => LoroValue::from(self.bytes()?.to_vec()),
            TAG_LIST => {
                let n = self.len()?;
                let mut items = Vec::with_capacity(n);
                for _ in 0..n {
                    items.push(self.value()?);
                }
                LoroValue::List(items.into())
            }
            TAG_MAP => {
                let n = self.len()?;
                let mut entries = Vec::with_capacity(n);
                for _ in 0..n {
                    let k = self.str()?.to_string();
                    entries.push((k, self.value()?));
                }
                LoroValue::Map(entries.into())
            }
            TAG_CONTAINER_ID => LoroValue::Container(self.container_id()?),
            tag => return Err(err_msg(format!("unexpected value tag {tag}"))),
        })
    }
}

impl<'a> Reader<'a> {
    pub fn tree_id(&mut self) -> FfiResult<TreeID> {
        let peer = self.peer()?;
        let counter = self.i32()?;
        Ok(TreeID::new(peer, counter))
    }

    /// `[u8 has][tree id]`: `None` means the tree root.
    pub fn tree_parent(&mut self) -> FfiResult<Option<TreeID>> {
        Ok(if self.bool()? { Some(self.tree_id()?) } else { None })
    }

    pub fn attributes(&mut self) -> FfiResult<Option<FxHashMap<String, LoroValue>>> {
        if !self.bool()? {
            return Ok(None);
        }
        let n = self.len()?;
        let mut map = FxHashMap::default();
        for _ in 0..n {
            let k = self.str()?.to_string();
            map.insert(k, self.value()?);
        }
        Ok(Some(map))
    }

    pub fn text_deltas(&mut self) -> FfiResult<Vec<TextDelta>> {
        let n = self.len()?;
        let mut out = Vec::with_capacity(n);
        for _ in 0..n {
            out.push(match self.u8()? {
                0 => TextDelta::Insert {
                    insert: self.str()?.to_string(),
                    attributes: self.attributes()?,
                },
                1 => TextDelta::Delete { delete: self.len()? },
                2 => TextDelta::Retain {
                    retain: self.len()?,
                    attributes: self.attributes()?,
                },
                k => return Err(err_msg(format!("unknown text delta kind {k}"))),
            });
        }
        Ok(out)
    }
}

pub fn side_from_i32(side: i32) -> FfiResult<Side> {
    Side::from_i32(side).ok_or_else(|| err_msg(format!("invalid cursor side {side}")))
}

pub fn parse_peer(s: &str) -> FfiResult<PeerID> {
    s.parse::<u64>()
        .map_err(|_| err_msg(format!("invalid peer id {s:?}")))
}

pub fn parse_container_id(s: &str) -> FfiResult<ContainerID> {
    ContainerID::try_from(s).map_err(|_| err_msg(format!("invalid container id {s:?}")))
}
