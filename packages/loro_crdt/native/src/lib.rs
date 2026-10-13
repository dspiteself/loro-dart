//! C ABI over the `loro` crate for the `loro_crdt` Dart package.
//!
//! See `util.rs` for the calling conventions shared by every export.
#![allow(clippy::missing_safety_doc)]

mod codec;
mod containers;
mod doc;
mod ephemeral;
mod events;
mod undo;
mod util;
