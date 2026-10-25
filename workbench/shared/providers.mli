open Core

(** Backend contracts. The Async IPC Reader is implemented separately; the
    Runner remains a contract. *)
module type Reader = sig
  type t

  (** Nonblocking enqueue. Duplicate IDs, invalid requests or a full queue are
      rejected immediately. Each accepted request emits exactly one response,
      echoing ID and generation; responses may finish out of order. *)
  val submit : t -> Protocol.request -> (unit, Protocol.error) Result.t

  (** Best effort; an already completed request may still return its result.
      Accepted requests cancelled before completion respond Cancelled. *)
  val cancel : t -> id:int64 -> unit

  (** Nonblocking, at most max_events responses; max_events must be positive.
      Returned arrays belong to the response and are never mutated by provider. *)
  val poll : t -> max_events:int -> Protocol.response list

  (** Stop accepting work and request cleanup without blocking rendering.
      Pending requests still reach one terminal response. *)
  val shutdown : t -> unit

  (** True only once resources are closed and all responses have been drained. *)
  val is_closed : t -> bool
end

type stream =
  | Stdout
  | Stderr

type job_update =
  | Started
  | Log of stream * string
  | Progress of
      { phase : string
      ; completed : int64
      ; total : int64 option
      }
  | Completed of Model.run_info
  | Failed of
      { message : string
      ; exit_code : int option
      }
  | Cancelled

type job_event =
  { job_id : string
  ; update : job_update
  }

module type Runner = sig
  type t

  (** Nonblocking enqueue; run_spec.id is the job ID. Reject duplicate IDs and
      pre-existing output paths. Semantic validation stays with the engine. *)
  val start : t -> Model.run_spec -> (unit, Protocol.error) Result.t

  (** Request cancellation. Cancelled is emitted only after the child exits
      and is reaped; requesting cancellation alone is not completion. *)
  val cancel : t -> job_id:string -> unit

  (** Nonblocking bounded delivery. Per-job order is preserved. Exactly one
      terminal Completed/Failed/Cancelled event follows an accepted start.
      Completed requires successful checks and published complete artifacts.
      Bounded logs may be summarized; terminal events must never be dropped. *)
  val poll : t -> max_events:int -> job_event list

  val shutdown : t -> unit

  (** Closed only after active children are reaped and events drained. *)
  val is_closed : t -> bool
end
