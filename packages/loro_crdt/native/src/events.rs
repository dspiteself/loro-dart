//! Subscriptions without callbacks.
//!
//! `wasm_ffi` cannot call back into Dart, and on native platforms a
//! synchronous callback from inside a Loro commit would re-enter the library.
//! Instead every subscription owns a queue: Loro's callback encodes the event
//! and pushes it, and Dart drains the queue right after any call that can emit
//! events (commit, import, checkout, undo, ...). [`loro_events_pending`] is a
//! cheap global check so Dart only polls when something was queued.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use loro::awareness::EphemeralStoreEvent;
use loro::event::{Diff, DiffBatch, DiffEvent, ListDiffItem};
use loro::{ContainerID, EventTriggerKind, Index, Subscription, TreeExternalDiff};

use crate::codec::{parse_container_id, Reader, Writer};
use crate::doc::{doc, write_index, LoroContainerHandle, LoroDocHandle};
use crate::ephemeral::{store, LoroEphemeralHandle};
use crate::util::{bytes, free_handle, guard, handle, into_handle, str, ErrSlot};

static PENDING: AtomicU32 = AtomicU32::new(0);

/// An encoded event plus the container handles embedded in it.
type Item = (Box<[u8]>, Vec<usize>);

#[derive(Default)]
pub struct Queue(Mutex<VecDeque<Item>>);

impl Queue {
    fn push(&self, item: Item) {
        self.0.lock().unwrap_or_else(|p| p.into_inner()).push_back(item);
        PENDING.fetch_add(1, Ordering::Relaxed);
    }

    fn pop(&self) -> Option<Item> {
        let item = self.0.lock().unwrap_or_else(|p| p.into_inner()).pop_front();
        if item.is_some() {
            PENDING.fetch_sub(1, Ordering::Relaxed);
        }
        item
    }
}

pub struct LoroSubscriptionHandle {
    sub: Option<Subscription>,
    queue: Arc<Queue>,
}

impl Drop for LoroSubscriptionHandle {
    fn drop(&mut self) {
        // Unsubscribe first so nothing is pushed while the queue is emptied.
        drop(self.sub.take());
        while let Some((_, handles)) = self.queue.pop() {
            for h in handles {
                unsafe { free_handle(h as *mut LoroContainerHandle) };
            }
        }
    }
}

fn subscription(make: impl FnOnce(Arc<Queue>) -> Subscription) -> *mut LoroSubscriptionHandle {
    let queue = Arc::new(Queue::default());
    let sub = make(queue.clone());
    into_handle(LoroSubscriptionHandle {
        sub: Some(sub),
        queue,
    })
}

fn bytes_item(data: &[u8]) -> Item {
    let mut w = Writer::new();
    w.bytes(data);
    w.finish_boxed()
}

/// Number of queued events across all subscriptions.
#[no_mangle]
pub extern "C" fn loro_events_pending() -> u32 {
    PENDING.load(Ordering::Relaxed)
}

/// Pops the oldest queued event of `sub` as an owned buffer, or null.
#[no_mangle]
pub unsafe extern "C" fn loro_subscription_poll(sub: *const LoroSubscriptionHandle) -> *mut u8 {
    match sub.as_ref().and_then(|s| s.queue.pop()) {
        // Ownership of the embedded handles passes to the caller with the buffer.
        Some((buf, _handles)) => Box::into_raw(buf) as *mut u8,
        None => std::ptr::null_mut(),
    }
}

/// Unsubscribes and discards any queued events.
#[no_mangle]
pub unsafe extern "C" fn loro_subscription_free(sub: *mut LoroSubscriptionHandle) {
    free_handle(sub)
}

// ---------------------------------------------------------------------------
// Document events

fn trigger_code(t: EventTriggerKind) -> u8 {
    match t {
        EventTriggerKind::Local => 0,
        EventTriggerKind::Import => 1,
        EventTriggerKind::Checkout => 2,
    }
}

/// `[u8 trigger][str origin][u8 has][str current target][u32 n](container diff)*`.
fn write_event(w: &mut Writer, e: &DiffEvent) {
    w.u8(trigger_code(e.triggered_by));
    w.str(e.origin);
    match &e.current_target {
        Some(cid) => {
            w.u8(1);
            w.container_id(cid);
        }
        None => w.u8(0),
    }
    w.len(e.events.len());
    for cd in &e.events {
        write_container_diff(w, cd.target, cd.path, cd.is_unknown, &cd.diff);
    }
}

/// `[str target][u32 n]([str container][index])*[u8 is unknown][diff]`.
fn write_container_diff(
    w: &mut Writer,
    target: &ContainerID,
    path: &[(ContainerID, Index)],
    is_unknown: bool,
    diff: &Diff,
) {
    w.container_id(target);
    w.len(path.len());
    for (cid, index) in path {
        w.container_id(cid);
        write_index(w, index);
    }
    w.bool(is_unknown);
    write_diff(w, diff);
}

/// `[u8 kind]` then: 0 list, 1 text, 2 map, 3 tree, 4 counter, 5 unknown.
fn write_diff(w: &mut Writer, diff: &Diff) {
    match diff {
        Diff::List(items) => {
            w.u8(0);
            w.len(items.len());
            for item in items {
                match item {
                    ListDiffItem::Insert { insert, is_move } => {
                        w.u8(0);
                        w.len(insert.len());
                        for v in insert {
                            w.value_or_container(v.clone());
                        }
                        w.bool(*is_move);
                    }
                    ListDiffItem::Delete { delete } => {
                        w.u8(1);
                        w.len(*delete);
                    }
                    ListDiffItem::Retain { retain } => {
                        w.u8(2);
                        w.len(*retain);
                    }
                }
            }
        }
        Diff::Text(deltas) => {
            w.u8(1);
            w.text_deltas(deltas);
        }
        Diff::Map(m) => {
            w.u8(2);
            let mut entries: Vec<_> = m.updated.iter().collect();
            entries.sort_unstable_by(|a, b| a.0.cmp(b.0));
            w.len(entries.len());
            for (k, v) in entries {
                w.str(k);
                w.opt_value_or_container(v.clone());
            }
        }
        Diff::Tree(t) => {
            w.u8(3);
            w.len(t.diff.len());
            for item in &t.diff {
                w.tree_id(item.target);
                match &item.action {
                    TreeExternalDiff::Create {
                        parent,
                        index,
                        position,
                    } => {
                        w.u8(0);
                        w.tree_parent(*parent);
                        w.len(*index);
                        w.str(&position.to_string());
                    }
                    TreeExternalDiff::Move {
                        parent,
                        index,
                        position,
                        old_parent,
                        old_index,
                    } => {
                        w.u8(1);
                        w.tree_parent(*parent);
                        w.len(*index);
                        w.str(&position.to_string());
                        w.tree_parent(*old_parent);
                        w.len(*old_index);
                    }
                    TreeExternalDiff::Delete {
                        old_parent,
                        old_index,
                    } => {
                        w.u8(2);
                        w.tree_parent(*old_parent);
                        w.len(*old_index);
                    }
                }
            }
        }
        Diff::Counter(v) => {
            w.u8(4);
            w.f64(*v);
        }
        Diff::Unknown => w.u8(5),
    }
}

fn event_item(e: &DiffEvent) -> Item {
    let mut w = Writer::new();
    write_event(&mut w, e);
    w.finish_boxed()
}

/// Subscribes to every change of the document.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_subscribe_root(
    d: *const LoroDocHandle,
    err: ErrSlot,
) -> *mut LoroSubscriptionHandle {
    guard(err, || {
        let doc = doc(d)?;
        Ok(subscription(|q| {
            doc.subscribe_root(Arc::new(move |e| q.push(event_item(&e))))
        }))
    })
}

/// Subscribes to changes of one container (and its descendants).
#[no_mangle]
pub unsafe extern "C" fn loro_doc_subscribe(
    d: *const LoroDocHandle,
    cid_ptr: *const u8,
    cid_len: u32,
    err: ErrSlot,
) -> *mut LoroSubscriptionHandle {
    guard(err, || {
        let doc = doc(d)?;
        let cid = parse_container_id(str(cid_ptr, cid_len)?)?;
        Ok(subscription(|q| {
            doc.subscribe(&cid, Arc::new(move |e| q.push(event_item(&e))))
        }))
    })
}

/// Queues `[bytes update]` for every local commit, to send to other peers.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_subscribe_local_update(
    d: *const LoroDocHandle,
    err: ErrSlot,
) -> *mut LoroSubscriptionHandle {
    guard(err, || {
        let doc = doc(d)?;
        Ok(subscription(|q| {
            doc.subscribe_local_update(Box::new(move |update| {
                q.push(bytes_item(update));
                true
            }))
        }))
    })
}

// ---------------------------------------------------------------------------
// Diff batches

pub struct LoroDiffBatchHandle(DiffBatch);

/// `pair`: `[frontiers from][frontiers to]`.
#[no_mangle]
pub unsafe extern "C" fn loro_doc_diff(
    d: *const LoroDocHandle,
    pair_ptr: *const u8,
    pair_len: u32,
    err: ErrSlot,
) -> *mut LoroDiffBatchHandle {
    guard(err, || {
        let mut r = Reader::new(bytes(pair_ptr, pair_len));
        let a = r.frontiers()?;
        let b = r.frontiers()?;
        Ok(into_handle(LoroDiffBatchHandle(doc(d)?.diff(&a, &b)?)))
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_doc_apply_diff(
    d: *const LoroDocHandle,
    batch: *const LoroDiffBatchHandle,
    err: ErrSlot,
) {
    guard(err, || {
        let batch = handle(batch)?.0.clone();
        doc(d)?.apply_diff(batch)?;
        Ok(())
    })
}

/// Returns `[u32 n]([str container][diff])*` in application order.
#[no_mangle]
pub unsafe extern "C" fn loro_diff_batch_entries(batch: *const LoroDiffBatchHandle, err: ErrSlot) -> *mut u8 {
    guard(err, || {
        let batch = &handle(batch)?.0;
        let entries: Vec<_> = batch.iter().collect();
        let mut w = Writer::new();
        w.len(entries.len());
        for (cid, diff) in entries {
            w.container_id(cid);
            write_diff(&mut w, diff);
        }
        Ok(w.finish())
    })
}

#[no_mangle]
pub unsafe extern "C" fn loro_diff_batch_free(batch: *mut LoroDiffBatchHandle) {
    free_handle(batch)
}

// ---------------------------------------------------------------------------
// Ephemeral store events

fn write_strings(w: &mut Writer, items: &[String]) {
    w.len(items.len());
    for s in items {
        w.str(s);
    }
}

/// Queues `[u8 by][keys added][keys updated][keys removed]` with `by` 0
/// local, 1 import, 2 timeout.
#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_subscribe(
    e: *const LoroEphemeralHandle,
    err: ErrSlot,
) -> *mut LoroSubscriptionHandle {
    guard(err, || {
        let store = store(e)?;
        Ok(subscription(|q| {
            store.subscribe(Box::new(move |ev: &EphemeralStoreEvent| {
                let mut w = Writer::new();
                w.u8(match ev.by {
                    loro::awareness::EphemeralEventTrigger::Local => 0,
                    loro::awareness::EphemeralEventTrigger::Import => 1,
                    loro::awareness::EphemeralEventTrigger::Timeout => 2,
                });
                write_strings(&mut w, &ev.added);
                write_strings(&mut w, &ev.updated);
                write_strings(&mut w, &ev.removed);
                q.push(w.finish_boxed());
                true
            }))
        }))
    })
}

/// Queues `[bytes update]` for every local change, to send to other peers.
#[no_mangle]
pub unsafe extern "C" fn loro_ephemeral_subscribe_local_updates(
    e: *const LoroEphemeralHandle,
    err: ErrSlot,
) -> *mut LoroSubscriptionHandle {
    guard(err, || {
        let store = store(e)?;
        Ok(subscription(|q| {
            store.subscribe_local_updates(Box::new(move |update| {
                q.push(bytes_item(update));
                true
            }))
        }))
    })
}
