open Core
open Async
open Backtest_shared
open Protocol
module Conn = Rayforce_ipc_async.Conn

type work =
  { request : request
  ; cancelled : unit Ivar.t
  }

type t =
  { host : string
  ; port : int
  ; user : string option
  ; password : string option
  ; capacity : int
  ; timeout : Time_ns.Span.t
  ; pending : work Queue.t
  ; responses : response Queue.t
  ; seen : Int64.Hash_set.t
  ; active : work Int64.Table.t
  ; mutable connection : Conn.t option
  ; mutable running : bool
  ; mutable stopping : bool
  ; mutable closing : int
  ; mutable inflight : int
  }

let close_connection ?(cancel = false) t =
  match t.connection with
  | None -> Deferred.unit
  | Some connection ->
    t.connection <- None;
    t.closing <- t.closing + 1;
    Monitor.protect
      (fun () ->
         if cancel
         then Conn.cancel_and_close connection >>| fun _ -> ()
         else Conn.close connection)
      ~finally:(fun () ->
        t.closing <- t.closing - 1;
        Deferred.unit)
;;

let connection t abandoned =
  match t.connection with
  | Some connection when not (Conn.is_closed connection) -> return (Ok connection)
  | _ ->
    close_connection t
    >>= fun () ->
    Conn.connect
      ?user:t.user
      ?password:t.password
      ~timeout:t.timeout
      ~host:t.host
      ~port:t.port
      ()
    >>= (function
     | Error error -> return (Error error)
     | Ok connection ->
       if !abandoned
       then Conn.close connection >>| fun () -> Or_error.error_string "request abandoned"
       else (
         t.connection <- Some connection;
         return (Ok connection)))
;;

let roundtrip t request abandoned =
  connection t abandoned
  >>= function
  | Error error -> return (Error (Io_error (Error.to_string_hum error)))
  | Ok conn ->
    if !abandoned
    then return (Error Cancelled)
    else
      Conn.send_sync conn (Codec.encode request)
      >>| (function
       | Error error -> Error (Io_error (Error.to_string_hum error))
       | Ok value -> Codec.decode request value)
;;

let execute t work =
  if Ivar.is_full work.cancelled
  then return (Error Cancelled)
  else (
    let abandoned = ref false in
    t.inflight <- t.inflight + 1;
    let operation =
      Monitor.try_with (fun () ->
        Monitor.protect
          (fun () -> roundtrip t work.request abandoned)
          ~finally:(fun () ->
            t.inflight <- t.inflight - 1;
            Deferred.unit))
    in
    let timed = Clock_ns.with_timeout t.timeout operation in
    Deferred.choose
      [ Deferred.choice (Ivar.read work.cancelled) (fun () -> `Cancelled)
      ; Deferred.choice timed (fun result -> `Result result)
      ]
    >>= fun outcome ->
    let result =
      match outcome with
      | `Cancelled -> Error Cancelled
      | `Result `Timeout -> Error (Io_error "Rayforce request timed out")
      | `Result (`Result (Error exn)) -> Error (Io_error (Exn.to_string exn))
      | `Result (`Result (Ok result)) -> result
    in
    abandoned := true;
    match result with
    | Error (Cancelled | Io_error _) ->
      close_connection ~cancel:true t >>| fun () -> result
    | Error (Invalid_output _) -> close_connection t >>| fun () -> result
    | _ -> return result)
;;

let rec pump t =
  match Queue.dequeue t.pending with
  | None ->
    t.running <- false;
    if t.stopping then close_connection t else Deferred.unit
  | Some work ->
    execute t work
    >>= fun result ->
    let result = if Ivar.is_full work.cancelled then Error Cancelled else result in
    Queue.enqueue
      t.responses
      { id = work.request.id; generation = work.request.generation; result };
    pump t
;;

let create
      ?user
      ?password
      ?(capacity = 32)
      ?(timeout = Time_ns.Span.of_int_sec 5)
      ~host
      ~port
      ()
  =
  if
    capacity < 1
    || String.is_empty host
    || port < 1
    || port > 65535
    || Time_ns.Span.(timeout <= zero)
  then invalid_arg "invalid workbench reader configuration";
  { host
  ; port
  ; user
  ; password
  ; capacity
  ; timeout
  ; pending = Queue.create ()
  ; responses = Queue.create ()
  ; seen = Hash_set.create (module Int64)
  ; active = Hashtbl.create (module Int64)
  ; connection = None
  ; running = false
  ; stopping = false
  ; closing = 0
  ; inflight = 0
  }
;;

let submit t (request : request) =
  match validate request.operation with
  | Error error -> Error error
  | Ok () ->
    if t.stopping
    then Error (Unavailable "reader is shutting down")
    else if Hash_set.mem t.seen request.id
    then Error (Invalid_request "duplicate request ID")
    else if Hashtbl.length t.active >= t.capacity
    then Error Busy
    else if
      match request.operation with
      | Rows q -> List.length q.sort > 64
      | _ -> false
    then Error (Invalid_request "IPC backend supports at most 64 sort keys")
    else (
      let work = { request; cancelled = Ivar.create () } in
      Hash_set.add t.seen request.id;
      Hashtbl.set t.active ~key:request.id ~data:work;
      Queue.enqueue t.pending work;
      if not t.running
      then (
        t.running <- true;
        don't_wait_for (pump t));
      Ok ())
;;

let cancel t ~id =
  Option.iter (Hashtbl.find t.active id) ~f:(fun work ->
    Ivar.fill_if_empty work.cancelled ())
;;

let poll t ~max_events =
  if max_events < 1 then invalid_arg "max_events must be positive";
  let rec take remaining acc =
    if remaining = 0
    then List.rev acc
    else (
      match Queue.dequeue t.responses with
      | None -> List.rev acc
      | Some response ->
        Hashtbl.remove t.active response.id;
        take (remaining - 1) (response :: acc))
  in
  take max_events []
;;

let shutdown t =
  t.stopping <- true;
  Hashtbl.iter t.active ~f:(fun work -> Ivar.fill_if_empty work.cancelled ());
  if not t.running then don't_wait_for (close_connection t)
;;

let is_closed t =
  t.stopping
  && (not t.running)
  && t.closing = 0
  && t.inflight = 0
  && Hashtbl.is_empty t.active
  && Option.is_none t.connection
;;
