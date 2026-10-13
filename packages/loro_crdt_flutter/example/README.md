# loro_crdt_flutter example

Two peers, Alice and Bob, edit the same Loro document side by side. Toggle
"Online" off to let them diverge, then back on to merge. Each peer has its
own undo/redo, and the like counter shows concurrent increments adding up.

```sh
flutter run -d chrome   # or any other device
```
