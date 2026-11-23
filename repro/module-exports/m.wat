;; A function export whose signature uses a GC reference type.
(module
  (func (export "f") (param (ref eq)) (result (ref eq)) (local.get 0)))
