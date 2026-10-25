open Core
open Backtest_shared

(** Typed values only; no executable source is constructed. *)
val encode : Protocol.request -> Rayforce_ipc.Value.t

(** Validate correlation, schema, bounds and exact source values. *)
val decode
  :  Protocol.request
  -> Rayforce_ipc.Value.t
  -> (Protocol.reply, Protocol.error) Result.t

(** Shared validation for IPC describe replies and native bundle metadata. *)
val decode_run_info
  :  run:Model.run_id
  -> Rayforce_ipc.Value.t
  -> (Model.run_info * Model.completion, Protocol.error) Result.t
