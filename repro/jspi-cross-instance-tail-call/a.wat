;; Module A: calls a JSPI Suspending import.
(module
  (import "js" "suspend" (func $suspend (param externref) (result externref)))
  (func (export "g") (param externref) (result externref)
    (call $suspend (local.get 0))))
