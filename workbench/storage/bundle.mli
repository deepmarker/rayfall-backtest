open! Core
open Async
open Backtest_shared

(** Splayed record tables plus native metadata, checksums and a completion seal.
    All filesystem/process operations run through Async. *)
val verify : directory:string -> Model.run_info Deferred.Or_error.t

(** [write] must finish all output into the supplied private sibling directory
    and stop its writers before returning. Native schemas/values are checked
    by a fresh Rayforce process before sealing, syncing and atomic publication.
    Existing destinations are never replaced. Parent directory must exist.
    Controlled failure removes staging output; abrupt death can leave hidden
    staging directories, never a partially published destination. *)
val publish
  :  directory:string
  -> rayforce:string
  -> service_directory:string
  -> write:(directory:string -> unit Deferred.Or_error.t)
  -> Model.run_info Deferred.Or_error.t

(** Start the native check/reopen bootstrap. Serving additionally requires
    prior [verify]; this function does not perform a checksum scan. *)
val native_args
  :  service_directory:string
  -> directory:string
  -> staged:bool
  -> string list

(** Cancellation is checked before producer startup and before atomic publication.
    The producer owns cancellation and reaping of its child processes. Once the
    atomic rename begins, successful publication wins a concurrent cancellation. *)
val publish_cancellable
  :  cancelled:(unit -> bool)
  -> directory:string
  -> rayforce:string
  -> service_directory:string
  -> write:(directory:string -> unit Deferred.Or_error.t)
  -> Model.run_info Deferred.Or_error.t
