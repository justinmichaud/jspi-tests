;; Module B: *tail-calls* A.g, a function imported from another instance.
;; JSC inserts a RestoreFrame (RestoreInstanceCallee) for cross-instance
;; tail calls; its JSPI stack scanner does not accept that frame.
(module
  (import "a" "g" (func $g (param externref) (result externref)))
  (func $h (param externref) (result externref)
    (return_call $g (local.get 0)))
  (func (export "f") (param externref) (result externref)
    ;; non-tail call into $h so the restore frame sits between Wasm frames
    (call $h (local.get 0))))
