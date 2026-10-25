open Core
open Backtest_shared

(** All calls must run on the owning Async scheduler, including [poll]. The GUI
    must schedule frames cooperatively on that scheduler, or dispatch calls to
    it. No OS thread owns a blocking socket. One request runs per connection. *)
type t

(** No connection is made until a request is submitted. The timeout bounds the
    entire connect/request. Active cancellation/deadlines send the engine's POSIX
    urgent cancel byte, then close the connection. Subsequent work reconnects.
    Cancellation is best effort; byte-send failure still closes the connection.
    [capacity] bounds accepted work including undrained responses (default 32).
    [timeout] defaults to five seconds. Invalid configuration raises. *)
val create
  :  ?user:string
  -> ?password:string
  -> ?capacity:int
  -> ?timeout:Time_ns.Span.t
  -> host:string
  -> port:int
  -> unit
  -> t

include Providers.Reader with type t := t
